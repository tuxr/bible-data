import Compression
import Foundation
@testable import bible_pack

struct TestZipEntry {
    var path: String
    var bytes: Data
    var method: UInt16 = 0
    var dos = DOSTime(year: 2026, month: 1, day: 1, hour: 0, minute: 0, second: 0)
    var utc: Date?
    var zip64Sizes = false
}

struct DOSTime {
    var year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int

    var date: UInt16 { UInt16((year - 1980) << 9 | month << 5 | day) }
    var time: UInt16 { UInt16(hour << 11 | minute << 5 | second / 2) }
}

func utc(_ iso: String) -> Date {
    try! Date(iso, strategy: .iso8601)
}

func makeZip(_ entries: [TestZipEntry]) -> Data {
    var body = Data()
    var directory = Data()
    for entry in entries {
        let stored = entry.method == 8 ? deflate(entry.bytes) : entry.bytes
        let crc = CRC32.checksum(entry.bytes)
        let name = Data(entry.path.utf8)
        var extra = Data()
        if let utc = entry.utc {
            extra.le16(0x5455); extra.le16(5); extra.append(1)
            extra.le32(UInt32(bitPattern: Int32(utc.timeIntervalSince1970)))
        }
        if entry.zip64Sizes {
            extra.le16(0x0001); extra.le16(16)
            extra.le64(UInt64(entry.bytes.count)); extra.le64(UInt64(stored.count))
        }
        let compressedSize: UInt32 = entry.zip64Sizes ? 0xFFFF_FFFF : UInt32(stored.count)
        let uncompressedSize: UInt32 = entry.zip64Sizes ? 0xFFFF_FFFF : UInt32(entry.bytes.count)
        let offset = UInt32(body.count)

        body.le32(0x0403_4b50); body.le16(20); body.le16(0); body.le16(entry.method)
        body.le16(entry.dos.time); body.le16(entry.dos.date); body.le32(crc)
        body.le32(compressedSize); body.le32(uncompressedSize)
        body.le16(UInt16(name.count)); body.le16(UInt16(extra.count))
        body.append(name); body.append(extra); body.append(stored)

        directory.le32(0x0201_4b50); directory.le16(0x031E); directory.le16(20); directory.le16(0)
        directory.le16(entry.method); directory.le16(entry.dos.time); directory.le16(entry.dos.date)
        directory.le32(crc); directory.le32(compressedSize); directory.le32(uncompressedSize)
        directory.le16(UInt16(name.count)); directory.le16(UInt16(extra.count)); directory.le16(0)
        directory.le16(0); directory.le16(0); directory.le32(0); directory.le32(offset)
        directory.append(name); directory.append(extra)
    }
    var zip = body
    zip.append(directory)
    zip.le32(0x0605_4b50); zip.le16(0); zip.le16(0)
    zip.le16(UInt16(entries.count)); zip.le16(UInt16(entries.count))
    zip.le32(UInt32(directory.count)); zip.le32(UInt32(body.count)); zip.le16(0)
    return zip
}

private func deflate(_ data: Data) -> Data {
    let capacity = data.count + 1024
    var output = Data(count: capacity)
    let written = data.withUnsafeBytes { source in
        output.withUnsafeMutableBytes { destination in
            compression_encode_buffer(
                destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                nil, COMPRESSION_ZLIB
            )
        }
    }
    precondition(written > 0, "deflate failed")
    return output.prefix(written)
}

extension Data {
    mutating func le16(_ value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func le32(_ value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func le64(_ value: UInt64) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
}
