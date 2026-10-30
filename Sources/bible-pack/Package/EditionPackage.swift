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
}

struct EditionPackageError: Error, CustomStringConvertible {
    let description: String
}

/// An edition ready to package: its metadata, its locked source, and its parse.
struct EditionInput {
    let edition: Edition
    let metadata: EditionMetadata
    let source: LockedSource
    let books: [ParsedBook]

    /// Reads `editions/<id>.json`, checks it against the lock and the edition's scheme, and parses the
    /// source. A parse with warnings is refused, so a package never holds text a parser was unsure of.
    static func load(_ id: String, editionsDirectory: URL, lock: SourcesLock, cache: SourceCache) throws -> EditionInput {
        guard let edition = Edition.named(id) else {
            throw EditionPackageError(description: "unknown edition \(id); known: \(Edition.all.map(\.id).joined(separator: ", "))")
        }
        let file = editionsDirectory.appendingPathComponent("\(id).json")
        guard let data = FileManager.default.contents(atPath: file.path) else {
            throw EditionPackageError(description: "\(file.path) does not exist")
        }
        let metadata = try EditionMetadata(jsonData: data, lock: lock)
        guard metadata.id == id, metadata.source == edition.id, let source = lock.sources[metadata.source] else {
            throw EditionPackageError(description: "\(file.path) names edition \(metadata.id) and source \(metadata.source), expected \(id)")
        }
        guard metadata.versification == edition.scheme else {
            throw EditionPackageError(description: "\(file.path) names versification \(metadata.versification.rawValue), but \(id) parses in \(edition.scheme.rawValue)")
        }
        let parsed = try edition.parse(lock: lock, cache: cache)
        guard parsed.report.warnings.isEmpty else {
            throw EditionPackageError(description: "\(id) parsed with \(parsed.report.warnings.count) warnings, first: \(parsed.report.warnings[0]); run `bible-pack parse \(id)`")
        }
        return EditionInput(edition: edition, metadata: metadata, source: source, books: parsed.books)
    }

    func content(builtAt: String, encoding: ChapterEncoding) -> PackageContent {
        PackageContent(metadata: metadata, source: source, books: books, builtAt: builtAt, encoding: encoding)
    }
}

enum EditionPackage {
    /// The encoding `build` writes when `--encoding` is not given.
    static let defaultEncoding = ChapterEncoding.binary

    static func fileName(id: String, version: String) -> String { "\(id)-\(version).bible" }

    /// The download artifact beside a package. Apple's `COMPRESSION_LZMA` writes an xz container, which
    /// `xz -t` accepts, so the name says xz.
    static func compressedURL(for package: URL) -> URL {
        package.deletingLastPathComponent().appendingPathComponent(package.lastPathComponent + ".xz")
    }

    /// `yyyy.mm` in UTC, such as `2026.10`.
    static func version(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d.%02d", parts.year!, parts.month!)
    }

    static func isValidVersion(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 4, parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let month = Int(parts[1]) else { return false }
        return (1...12).contains(month)
    }

    /// Writes the package and its compressed sibling beside their destinations and renames each into place,
    /// so neither name ever holds a partial file. A `.partial` left by a crashed run is removed by the next.
    static func build(_ content: PackageContent, to destination: URL) throws -> PackageBuildSummary {
        let tables = try content.tables()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeAtomically(to: destination) { try write(tables, to: $0) }

        let compressed = compressedURL(for: destination)
        let bytes = try Data(contentsOf: destination)
        try writeAtomically(to: compressed) { try compress(bytes).write(to: $0) }

        let database = try SQLiteDatabase(path: destination.path, mode: .readOnly)
        let rowCounts = try tables.map { table in
            (table.name, try count(in: database, "SELECT count(*) FROM \(table.name)"))
        }
        return PackageBuildSummary(rowCounts: rowCounts, package: try PackageFile(destination), compressed: try PackageFile(compressed))
    }

    static func compress(_ data: Data) throws -> Data {
        try (data as NSData).compressed(using: .lzma) as Data
    }

    static func decompress(_ data: Data) throws -> Data {
        try (data as NSData).decompressed(using: .lzma) as Data
    }

    private static func write(_ tables: [PackageTable], to url: URL) throws {
        let database = try SQLiteDatabase(path: url.path, mode: .create)
        try database.pragma("page_size", "4096")
        try database.pragma("foreign_keys", "ON")
        try database.transaction {
            try database.exec(PackageSchema.ddl)
            for table in tables {
                try database.insert(into: table.name, columns: table.columns, rows: table.rows)
            }
        }
        try database.exec("INSERT INTO verses_fts (verses_fts) VALUES ('optimize')")
        try database.exec("VACUUM")
        try database.pragma("journal_mode", "DELETE")
    }

    private static func writeAtomically(to destination: URL, _ body: (URL) throws -> Void) throws {
        let partial = destination.deletingLastPathComponent().appendingPathComponent(destination.lastPathComponent + ".partial")
        removeFile(at: partial)
        do {
            try body(partial)
            guard rename(partial.path, destination.path) == 0 else {
                throw EditionPackageError(description: "cannot move into \(destination.path): \(String(cString: strerror(errno)))")
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

    static func count(in database: SQLiteDatabase, _ sql: String, _ values: [SQLiteValue] = []) throws -> Int {
        guard case .integer(let count)? = try database.rows(sql, values).first?.first else {
            throw EditionPackageError(description: "\(sql) returned no count")
        }
        return Int(count)
    }
}
