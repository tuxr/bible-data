import BibleFormat
import Foundation

struct PackageFile {
    let url: URL
    let bytes: Int
    let sha256: String

    init(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        self.url = url
        self.bytes = data.count
        self.sha256 = sha256Hex(data)
    }
}

struct PackageBuildSummary {
    let rowCounts: [(table: String, rows: Int)]
    let package: PackageFile
    let compressed: PackageFile

    /// The row counts, then each file's path, size, and SHA-256, as `build` commands print them.
    var lines: [String] {
        let width = rowCounts.map(\.table.count).max() ?? 0
        return rowCounts.map { $0.table.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + String($0.rows) }
            + [package, compressed].map { "\($0.url.path)  \($0.bytes) bytes  sha256 \($0.sha256)" }
    }
}

struct PackageError: Error, CustomStringConvertible {
    let description: String
}

/// The steps every SQLite package shares: a fresh file with a 4096-byte page size, the schema and every row in
/// one transaction, `VACUUM`, rollback journal mode, an `.xz` sibling, and a rename into place.
enum PackageWriter {
    /// Writes the package and its compressed sibling beside their destinations and renames each into place,
    /// so neither name ever holds a partial file. A `.partial` left by a crashed run is removed by the next.
    /// `finish` runs after the rows are in and before `VACUUM`.
    static func build(
        ddl: String,
        tables: [PackageTable],
        to destination: URL,
        finish: (SQLiteDatabase) throws -> Void = { _ in }
    ) throws -> PackageBuildSummary {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeAtomically(to: destination) { url in
            let database = try SQLiteDatabase(path: url.path, mode: .create)
            try database.pragma("page_size", "4096")
            try database.pragma("foreign_keys", "ON")
            try database.transaction {
                try database.exec(ddl)
                for table in tables {
                    try database.insert(into: table.name, columns: table.columns, rows: table.rows)
                }
            }
            try finish(database)
            try database.exec("VACUUM")
            try database.pragma("journal_mode", "DELETE")
        }

        let compressed = try writeCompressed(beside: destination)

        let database = try SQLiteDatabase(path: destination.path, mode: .readOnly)
        let rowCounts = try tables.map { table in
            (table.name, try count(in: database, "SELECT count(*) FROM \(table.name)"))
        }
        return PackageBuildSummary(rowCounts: rowCounts, package: try PackageFile(destination), compressed: compressed)
    }

    /// Writes the `.xz` download beside a finished package and renames it into place.
    static func writeCompressed(beside package: URL) throws -> PackageFile {
        let compressed = compressedURL(for: package)
        let bytes = try Data(contentsOf: package)
        try writeAtomically(to: compressed) { try compress(bytes).write(to: $0) }
        return try PackageFile(compressed)
    }

    /// The download artifact beside a package. Apple's `COMPRESSION_LZMA` writes an xz container, which
    /// `xz -t` accepts, so the name says xz.
    static func compressedURL(for package: URL) -> URL {
        package.deletingLastPathComponent().appendingPathComponent(package.lastPathComponent + ".xz")
    }

    static func compress(_ data: Data) throws -> Data {
        try (data as NSData).compressed(using: .lzma) as Data
    }

    static func decompress(_ data: Data) throws -> Data {
        try (data as NSData).decompressed(using: .lzma) as Data
    }

    static func count(in database: SQLiteDatabase, _ sql: String, _ values: [SQLiteValue] = []) throws -> Int {
        guard case .integer(let count)? = try database.rows(sql, values).first?.first else {
            throw PackageError(description: "\(sql) returned no count")
        }
        return Int(count)
    }

    enum CompressedCheck {
        case absent
        case matches(String)
        case fails(String)
    }

    /// Whether the `.xz` beside a package decompresses to the package's bytes.
    static func checkCompressed(beside url: URL, packageBytes: Data) -> CompressedCheck {
        let compressed = compressedURL(for: url)
        guard FileManager.default.fileExists(atPath: compressed.path) else { return .absent }
        let name = compressed.lastPathComponent
        let inflated: Data
        do {
            inflated = try decompress(try Data(contentsOf: compressed))
        } catch {
            return .fails("\(name) does not decompress: \(error)")
        }
        let expected = sha256Hex(packageBytes)
        let actual = sha256Hex(inflated)
        return actual == expected ? .matches("\(name) decompresses to sha256 \(expected)")
            : .fails("\(name) decompresses to sha256 \(actual), expected \(expected)")
    }

    private static func writeAtomically(to destination: URL, _ body: (URL) throws -> Void) throws {
        let partial = destination.deletingLastPathComponent().appendingPathComponent(destination.lastPathComponent + ".partial")
        removeFile(at: partial)
        do {
            try body(partial)
            guard rename(partial.path, destination.path) == 0 else {
                throw PackageError(description: "cannot move into \(destination.path): \(String(cString: strerror(errno)))")
            }
        } catch {
            removeFile(at: partial)
            throw error
        }
    }

    private static func removeFile(at url: URL) {
        for path in [url.path, url.path + "-journal"] {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}
