import BibleFormat
import Foundation

struct CanonBuildSummary {
    let rowCounts: [(table: String, rows: Int)]
    let bytes: Int
    let sha256: String
}

struct CanonPackageError: Error, CustomStringConvertible {
    /// The table the failure is about, or `database` for a whole-file check.
    let table: String
    let message: String

    var description: String { "\(table): \(message)" }
}

enum CanonPackage {
    /// Writes beside `destination` and renames into place, so `destination` is never a partial file.
    /// A `.partial` file left by a crashed run is removed by the next run.
    static func build(to destination: URL, builtAt: String) throws -> CanonBuildSummary {
        let tables = try CanonContent.tables()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.deletingLastPathComponent().appendingPathComponent(destination.lastPathComponent + ".partial")
        removeDatabase(at: partial)
        do {
            try write(tables, builtAt: builtAt, to: partial)
            guard rename(partial.path, destination.path) == 0 else {
                throw CanonPackageError(table: "database", message: "cannot move into \(destination.path): \(String(cString: strerror(errno)))")
            }
        } catch {
            removeDatabase(at: partial)
            throw error
        }

        let database = try SQLiteDatabase(path: destination.path, mode: .readOnly)
        let rowCounts = try (["meta"] + tables.map(\.name)).map { table in
            (table, try count(in: database, "SELECT count(*) FROM \(table)"))
        }
        let bytes = try Data(contentsOf: destination)
        return CanonBuildSummary(rowCounts: rowCounts, bytes: bytes.count, sha256: sha256Hex(bytes))
    }

    /// Reports each passing check to `pass` and throws on the first failure.
    static func validate(at url: URL, pass: (String) -> Void) throws {
        let database = try SQLiteDatabase(path: url.path, mode: .readOnly)
        func check(_ name: String, table: String = "database", failure: String?) throws {
            if let failure { throw CanonPackageError(table: table, message: failure) }
            pass(name)
        }

        let integrity = try database.pragma("integrity_check")
        try check("integrity_check", failure: integrity == [[.text("ok")]] ? nil : "integrity_check reported \(integrity.first.map(describe) ?? "nothing")")
        let foreignKeys = try database.pragma("foreign_key_check")
        try check("foreign_key_check", failure: foreignKeys.first.map { "foreign_key_check found \(foreignKeys.count) violations, first \(describe($0))" })

        let meta = try Dictionary(database.rows("SELECT key, value FROM meta").map { ($0[0], $0[1]) }, uniquingKeysWith: { first, _ in first })
        func metaValue(_ key: PackageSchema.MetaKey) -> String? {
            if case .text(let value)? = meta[.text(key.rawValue)] { value } else { nil }
        }
        let formatVersion = metaValue(.formatVersion)
        try check("meta format_version \(CanonSchema.version)", table: "meta", failure: formatVersion == "\(CanonSchema.version)"
            ? nil : "format_version is \(formatVersion ?? "missing"), expected \(CanonSchema.version)")
        let kind = metaValue(.kind)
        try check("meta kind canon", table: "meta", failure: kind == PackageKind.canon.rawValue
            ? nil : "kind is \(kind ?? "missing"), expected \(PackageKind.canon.rawValue)")
        let builtAt = metaValue(.builtAt)
        try check("meta built_at", table: "meta", failure: builtAt.flatMap(parseBuiltAt) != nil
            ? nil : "built_at is \(builtAt ?? "missing"), expected an ISO 8601 UTC time")
        try check("meta builder_version", table: "meta", failure: metaValue(.builderVersion)?.isEmpty == false ? nil : "builder_version is missing")

        for table in try CanonContent.tables() {
            let expected = table.rows.sorted { $0.lexicographicallyPrecedes($1) }
            let actual = try database.rows(table.selectSQL).sorted { $0.lexicographicallyPrecedes($1) }
            try check("\(table.name) \(expected.count) rows match", table: table.name, failure: difference(expected: expected, actual: actual))
        }

        let outOfRange = try database.rows("SELECT scheme, book, chapter, verses FROM verse_counts WHERE verses NOT BETWEEN 1 AND 999 LIMIT 1")
        try check("verse_counts within 1 to 999", table: "verse_counts", failure: outOfRange.first.map { "verse count outside 1 to 999 in \(describe($0))" })

        for scheme in VersificationScheme.allCases {
            let counts = try Versification.counts(for: scheme)
            let chapters = try count(in: database, "SELECT count(*) FROM verse_counts WHERE scheme = ?", [.text(scheme.rawValue)])
            let verses = try count(in: database, "SELECT coalesce(sum(verses), 0) FROM verse_counts WHERE scheme = ?", [.text(scheme.rawValue)])
            try check("verse_counts \(scheme.rawValue) totals \(counts.chapterCount) chapters, \(counts.verseCount) verses", table: "verse_counts",
                      failure: (chapters, verses) == (counts.chapterCount, counts.verseCount)
                          ? nil : "\(scheme.rawValue) totals \(chapters) chapters and \(verses) verses, expected \(counts.chapterCount) and \(counts.verseCount)")
        }
    }

    static func parseBuiltAt(_ text: String) -> Date? {
        try? Date.ISO8601FormatStyle().parse(text)
    }

    static func formatBuiltAt(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle())
    }

    private static func write(_ tables: [CanonTable], builtAt: String, to url: URL) throws {
        let database = try SQLiteDatabase(path: url.path, mode: .create)
        try database.pragma("page_size", "4096")
        try database.pragma("foreign_keys", "ON")
        try database.transaction {
            try database.exec(CanonSchema.ddl)
            let meta = CanonTable(name: "meta", columns: ["key", "value"], rows: CanonContent.meta(builtAt: builtAt).map { [.text($0.key), .text($0.value)] })
            for table in [meta] + tables {
                let insert = try database.prepare(table.insertSQL)
                for row in table.rows {
                    do {
                        try insert.bind(row)
                        while try insert.step() {}
                    } catch {
                        throw CanonPackageError(table: table.name, message: "cannot insert \(describe(row)): \(error)")
                    }
                }
            }
        }
        try database.exec("VACUUM")
        try database.pragma("journal_mode", "DELETE")
    }

    private static func removeDatabase(at url: URL) {
        for path in [url.path, url.path + "-journal"] {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private static func count(in database: SQLiteDatabase, _ sql: String, _ values: [SQLiteValue] = []) throws -> Int {
        guard case .integer(let count)? = try database.rows(sql, values).first?.first else {
            throw CanonPackageError(table: "database", message: "\(sql) returned no count")
        }
        return Int(count)
    }

    /// Nil when the sorted rows match, else the row counts and the first row where they part.
    private static func difference(expected: [[SQLiteValue]], actual: [[SQLiteValue]]) -> String? {
        func row(_ rows: [[SQLiteValue]], _ index: Int) -> [SQLiteValue]? { rows.indices.contains(index) ? rows[index] : nil }
        guard let index = (0..<max(expected.count, actual.count)).first(where: { row(expected, $0) != row(actual, $0) }) else { return nil }
        let counts = expected.count == actual.count ? "" : "\(actual.count) rows, expected \(expected.count); "
        return "\(counts)first differing row: expected \(row(expected, index).map(describe) ?? "no row"), found \(row(actual, index).map(describe) ?? "no row")"
    }

    private static func describe(_ row: [SQLiteValue]) -> String {
        "(" + row.map(\.description).joined(separator: ", ") + ")"
    }
}
