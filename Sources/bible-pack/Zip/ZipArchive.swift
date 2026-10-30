import Compression
import Foundation

enum ZipError: Error, Equatable, CustomStringConvertible {
    case notAZip
    case noEntries
    case truncated
    case zip64Unsupported
    case multiDiskUnsupported
    case encryptedEntry(path: String)
    case unsupportedMethod(Int, path: String)
    case corruptEntry(path: String)

    var description: String {
        switch self {
        case .notAZip: "not a zip: no end of central directory record"
        case .noEntries: "zip has no entries"
        case .truncated: "zip is truncated or its central directory is malformed"
        case .zip64Unsupported: "zip64 archives are not supported"
        case .multiDiskUnsupported: "multi-disk zip archives are not supported"
        case .encryptedEntry(let path): "zip entry \(path) is encrypted, which is not supported"
        case .unsupportedMethod(let method, let path):
            "zip entry \(path) uses compression method \(method); only stored (0) and deflated (8) are supported"
        case .corruptEntry(let path): "zip entry \(path) failed to decompress or its CRC-32 does not match"
        }
    }
}

enum ZipMethod: Equatable {
    case stored
    case deflated
}

struct ZipEntry: Equatable {
    var path: String
    var method: ZipMethod
    var modified: Date
    var crc32: UInt32
    var compressedSize: Int
    var uncompressedSize: Int
    var localHeaderOffset: Int
}

struct ZipArchive {
    let entries: [ZipEntry]
    private let bytes: [UInt8]

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        self.bytes = bytes
        self.entries = try Self.readCentralDirectory(bytes)
    }

    func contents(of entry: ZipEntry) throws -> Data {
        let local = entry.localHeaderOffset
        guard try bytes.u32(local) == 0x0403_4b50 else { throw ZipError.truncated }
        // Local header: name length at +26, extra length at +28, data after the 30-byte fixed part.
        // Sizes come from the central directory because a data descriptor may zero them here.
        let start = local + 30 + Int(try bytes.u16(local + 26)) + Int(try bytes.u16(local + 28))
        let end = start + entry.compressedSize
        guard end <= bytes.count else { throw ZipError.truncated }
        let data: Data
        switch entry.method {
        case .stored:
            data = Data(bytes[start..<end])
        case .deflated:
            data = try Self.inflate(bytes[start..<end], size: entry.uncompressedSize, path: entry.path)
        }
        guard data.count == entry.uncompressedSize, CRC32.checksum(data) == entry.crc32 else {
            throw ZipError.corruptEntry(path: entry.path)
        }
        return data
    }

    /// The upstream's revision: the newest entry's modification date, YYYY-MM-DD in UTC.
    func revisionDate() throws -> String {
        guard let newest = entries.map(\.modified).max() else { throw ZipError.noEntries }
        let parts = Self.utc.dateComponents([.year, .month, .day], from: newest)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func readCentralDirectory(_ bytes: [UInt8]) throws -> [ZipEntry] {
        let eocd = try findEndOfCentralDirectory(bytes)
        // EOCD: disk numbers at +4/+6, total entries at +10, directory size at +12, offset at +16.
        if eocd >= 20, try bytes.u32(eocd - 20) == 0x0706_4b50 { throw ZipError.zip64Unsupported }
        let count = try bytes.u16(eocd + 10)
        let size = try bytes.u32(eocd + 12)
        var offset = Int(try bytes.u32(eocd + 16))
        if count == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF { throw ZipError.zip64Unsupported }
        if try bytes.u16(eocd + 4) != 0 || bytes.u16(eocd + 6) != 0 { throw ZipError.multiDiskUnsupported }

        var entries: [ZipEntry] = []
        for _ in 0..<count {
            guard try bytes.u32(offset) == 0x0201_4b50 else { throw ZipError.truncated }
            // Central directory header: flags +8, method +10, DOS time +12, DOS date +14, CRC +16,
            // sizes +20/+24, name/extra/comment lengths +28/+30/+32, local header offset +42, name at +46.
            let flags = try bytes.u16(offset + 8)
            let rawMethod = try bytes.u16(offset + 10)
            let dosTime = try bytes.u16(offset + 12)
            let dosDate = try bytes.u16(offset + 14)
            let crc = try bytes.u32(offset + 16)
            let compressedSize = try bytes.u32(offset + 20)
            let uncompressedSize = try bytes.u32(offset + 24)
            let nameLength = Int(try bytes.u16(offset + 28))
            let extraLength = Int(try bytes.u16(offset + 30))
            let commentLength = Int(try bytes.u16(offset + 32))
            let localOffset = try bytes.u32(offset + 42)
            let nameStart = offset + 46
            let extraStart = nameStart + nameLength
            let extraEnd = extraStart + extraLength
            guard extraEnd + commentLength <= bytes.count else { throw ZipError.truncated }
            let path = String(decoding: bytes[nameStart..<extraStart], as: UTF8.self)

            if compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                throw ZipError.zip64Unsupported
            }
            if flags & 1 != 0 { throw ZipError.encryptedEntry(path: path) }
            let method: ZipMethod
            switch rawMethod {
            case 0: method = .stored
            case 8: method = .deflated
            default: throw ZipError.unsupportedMethod(Int(rawMethod), path: path)
            }

            let extra = try ExtraFields(bytes[extraStart..<extraEnd])
            if extra.hasZip64 { throw ZipError.zip64Unsupported }
            entries.append(ZipEntry(
                path: path,
                method: method,
                modified: extra.utcModified ?? dosDateTime(date: dosDate, time: dosTime),
                crc32: crc,
                compressedSize: Int(compressedSize),
                uncompressedSize: Int(uncompressedSize),
                localHeaderOffset: Int(localOffset)
            ))
            offset = extraEnd + commentLength
        }
        return entries
    }

    private static func findEndOfCentralDirectory(_ bytes: [UInt8]) throws -> Int {
        // The 22-byte EOCD record ends the file, followed only by a comment of at most 0xFFFF bytes.
        guard bytes.count >= 22 else { throw ZipError.notAZip }
        let lowest = max(0, bytes.count - 22 - 0xFFFF)
        for index in stride(from: bytes.count - 22, through: lowest, by: -1) {
            if try bytes.u32(index) == 0x0605_4b50 { return index }
        }
        throw ZipError.notAZip
    }

    // Publishers' DOS times are in the packager's local zone, which is unknown; read as UTC like the
    // bible-api lock did, so revisions stay comparable with its history.
    private static func dosDateTime(date: UInt16, time: UInt16) -> Date {
        let components = DateComponents(
            year: Int(date >> 9) + 1980,
            month: Int((date >> 5) & 0x0F),
            day: Int(date & 0x1F),
            hour: Int(time >> 11),
            minute: Int((time >> 5) & 0x3F),
            second: Int(time & 0x1F) * 2
        )
        return utc.date(from: components)!
    }

    private static func inflate(_ compressed: ArraySlice<UInt8>, size: Int, path: String) throws -> Data {
        if size == 0 { return Data() }
        var output = Data(count: size)
        let written = compressed.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBytes { destination in
                // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), which is what zip stores.
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, size,
                    source.baseAddress!, source.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == size else { throw ZipError.corruptEntry(path: path) }
        return output
    }
}

private struct ExtraFields {
    var utcModified: Date?
    var hasZip64 = false

    init(_ bytes: ArraySlice<UInt8>) throws {
        var offset = bytes.startIndex
        while offset + 4 <= bytes.endIndex {
            let id = try bytes.u16(offset)
            let size = Int(try bytes.u16(offset + 2))
            let body = offset + 4
            guard body + size <= bytes.endIndex else { throw ZipError.truncated }
            switch id {
            case 0x0001:
                hasZip64 = true
            case 0x5455 where size >= 5 && bytes[body] & 1 != 0:
                // Extended timestamp: a flags byte, then mtime as signed 32-bit Unix seconds.
                let seconds = Int32(bitPattern: try bytes.u32(body + 1))
                utcModified = Date(timeIntervalSince1970: TimeInterval(seconds))
            default:
                break
            }
            offset = body + size
        }
    }
}

extension Collection where Element == UInt8, Index == Int {
    fileprivate func u16(_ offset: Int) throws -> UInt16 {
        guard offset >= startIndex, offset + 2 <= endIndex else { throw ZipError.truncated }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    fileprivate func u32(_ offset: Int) throws -> UInt32 {
        guard offset >= startIndex, offset + 4 <= endIndex else { throw ZipError.truncated }
        return UInt32(self[offset]) | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
