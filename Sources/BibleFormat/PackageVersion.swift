import Foundation

/// A package's version: `yyyy.mm`, the year and month of the build, then `.n` for the nth rebuild released in
/// the same month, as in `2026.10` and `2026.10.1`. It is part of the file name and of `meta.version`.
public struct PackageVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    /// Nil for the first release of the month.
    public let rebuild: Int?

    /// Nil unless the text is `yyyy.mm` or `yyyy.mm.n`, with a month from 01 to 12 and `n` from 1 to 999
    /// with no leading zero.
    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              parts[0].count == 4, parts[1].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), (1...12).contains(month) else { return nil }
        var rebuild: Int?
        if parts.count == 3 {
            guard parts[2].count <= 3, parts[2].first != "0", let number = Int(parts[2]) else { return nil }
            rebuild = number
        }
        self.year = year
        self.month = month
        self.rebuild = rebuild
    }

    /// The year and month of `date` in UTC.
    public init(date: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month], from: date)
        self.year = parts.year!
        self.month = parts.month!
        self.rebuild = nil
    }

    public var description: String {
        String(format: "%04d.%02d", year, month) + (rebuild.map { ".\($0)" } ?? "")
    }

    public static func < (lhs: PackageVersion, rhs: PackageVersion) -> Bool {
        (lhs.year, lhs.month, lhs.rebuild ?? 0) < (rhs.year, rhs.month, rhs.rebuild ?? 0)
    }
}

extension PackageVersion: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let version = PackageVersion(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "version \(text) is not yyyy.mm or yyyy.mm.n")
        }
        self = version
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
