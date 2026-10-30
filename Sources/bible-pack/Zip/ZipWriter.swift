import Foundation

/// Writes a zip of stored entries, in the order given, all stamped with one modification time. The same
/// entries and time always give the same bytes, which is what lets the lock pin a zip `bible-pack` builds.
enum ZipWriter {
    static func write(_ entries: [(path: String, data: Data)], modified: Date) throws -> Data {
        guard entries.count < 0xFFFF else { throw ZipError.zip64Unsupported }
        let (dosDate, dosTime) = dosDateTime(modified)
        let seconds = UInt32(bitPattern: Int32(modified.timeIntervalSince1970))
        // Extended timestamp (UT): flags byte 1 says mtime follows, as Unix seconds, so readers get UTC.
        var extra = Data()
        extra.le16(0x5455); extra.le16(5); extra.append(1); extra.le32(seconds)

        var body = Data()
        var directory = Data()
        for entry in entries {
            let name = Data(entry.path.utf8)
            let crc = CRC32.checksum(entry.data)
            guard entry.data.count < 0xFFFF_FFFF, body.count < 0xFFFF_FFFF, name.count <= 0xFFFF else {
                throw ZipError.zip64Unsupported
            }
            let size = UInt32(entry.data.count)
            let offset = UInt32(body.count)

            body.le32(0x0403_4b50); body.le16(10); body.le16(0); body.le16(0)
            body.le16(dosTime); body.le16(dosDate); body.le32(crc); body.le32(size); body.le32(size)
            body.le16(UInt16(name.count)); body.le16(UInt16(extra.count))
            body.append(name); body.append(extra); body.append(entry.data)

            // Made by Unix (3) zip 3.0, with external attributes 0o100644 so extracted files are plain and readable.
            directory.le32(0x0201_4b50); directory.le16(0x031E); directory.le16(10); directory.le16(0); directory.le16(0)
            directory.le16(dosTime); directory.le16(dosDate); directory.le32(crc); directory.le32(size); directory.le32(size)
            directory.le16(UInt16(name.count)); directory.le16(UInt16(extra.count)); directory.le16(0)
            directory.le16(0); directory.le16(0); directory.le32(0o100644 << 16); directory.le32(offset)
            directory.append(name); directory.append(extra)
        }
        guard body.count + directory.count < 0xFFFF_FFFF else { throw ZipError.zip64Unsupported }
        var zip = body
        zip.append(directory)
        zip.le32(0x0605_4b50); zip.le16(0); zip.le16(0)
        zip.le16(UInt16(entries.count)); zip.le16(UInt16(entries.count))
        zip.le32(UInt32(directory.count)); zip.le32(UInt32(body.count)); zip.le16(0)
        return zip
    }

    private static func dosDateTime(_ date: Date) -> (date: UInt16, time: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let day = (c.year! - 1980) << 9 | c.month! << 5 | c.day!
        let time = c.hour! << 11 | c.minute! << 5 | c.second! / 2
        return (UInt16(day), UInt16(time))
    }
}

extension Data {
    fileprivate mutating func le16(_ value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    fileprivate mutating func le32(_ value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
}
