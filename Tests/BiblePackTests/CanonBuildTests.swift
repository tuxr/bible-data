import ArgumentParser
import BibleFormat
import Foundation
import Testing
@testable import bible_pack

private let pinnedTime = "2026-10-29T00:00:00Z"

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("canon-build-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func build(in directory: URL, name: String = "canon.sqlite") throws -> URL {
    let out = directory.appendingPathComponent(name)
    var command = try CanonCommand.Build.parse(["--out", out.path, "--built-at", pinnedTime])
    try command.run()
    return out
}

private func scalar(_ database: SQLiteDatabase, _ sql: String, _ values: [SQLiteValue] = []) throws -> SQLiteValue? {
    try database.rows(sql, values).first?.first
}

@Suite struct CanonBuildTests {
    @Test func writesEveryTableFromTheBibleFormatTypes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLiteDatabase(path: try build(in: directory).path, mode: .readOnly)

        func rows(_ table: String) throws -> SQLiteValue? { try scalar(database, "SELECT count(*) FROM \(table)") }
        #expect(try rows("books") == .integer(86))
        #expect(try rows("sections") == .integer(10))
        #expect(try rows("schemes") == .integer(3))
        #expect(try rows("verse_counts") == .integer(1189 + 929 + 260))

        let names = Set(Canon.defined.flatMap { $0.lookupNames.map { $0.lowercased() } })
        #expect(try rows("aliases") == .integer(names.count))

        let schemes = VersificationScheme.allCases
        let entries = try schemes.indices.flatMap { first in
            try schemes[(first + 1)...].map { second in
                try Versification.mapping(from: schemes[first], to: second)?.entries.count ?? 0
            }
        }.reduce(0, +)
        #expect(entries > 0)
        #expect(try rows("mappings") == .integer(entries))

        #expect(try scalar(database, "SELECT verses FROM verse_counts WHERE scheme = 'eng' AND book = 'GEN' AND chapter = 1") == .integer(31))
        #expect(try scalar(database, "SELECT book FROM aliases WHERE alias = ?", [.text("1 sam")]) == .text("1SA"))
        #expect(try scalar(database, "SELECT value FROM meta WHERE key = 'built_at'") == .text(pinnedTime))
        #expect(try scalar(database, "SELECT value FROM meta WHERE key = 'builder_version'") == .text(BiblePackVersion.current))
        #expect(try scalar(database, "PRAGMA journal_mode") == .text("delete"))
        #expect(throws: (any Error).self) { try database.exec("DELETE FROM books") }
    }

    @Test func buildsAreByteIdenticalForOnePinnedTime() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try Data(contentsOf: build(in: directory, name: "first.sqlite"))
        let second = try Data(contentsOf: build(in: directory, name: "second.sqlite"))
        #expect(first == second)
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(contents == ["first.sqlite", "second.sqlite"])
    }

    @Test func validatePassesAFreshBuildAndNamesATamperedTable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let out = try build(in: directory)
        var validate = try CanonCommand.Validate.parse([out.path])
        try validate.run()

        try SQLiteDatabase(path: out.path, mode: .readWrite)
            .exec("UPDATE verse_counts SET verses = verses + 1 WHERE scheme = 'eng' AND book = 'GEN' AND chapter = 1")
        let error = #expect(throws: CanonPackageError.self) { try validate.run() }
        #expect(error?.table == "verse_counts")
        #expect(error?.description.contains("expected ('eng', 'GEN', 1, 31), found ('eng', 'GEN', 1, 32)") == true)
        #expect(CanonCommand.exitCode(for: error!) == .failure)
    }

    @Test func rejectsAnUnparseableBuildTime() {
        #expect(throws: (any Error).self) { try CanonCommand.Build.parse(["--built-at", "yesterday"]) }
    }
}
