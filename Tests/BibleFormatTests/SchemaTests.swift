import BibleFormat
import Foundation
import Testing

@Suite struct PackageSchemaTests {
    private func package() throws -> SQLiteDatabase {
        let database = try SQLiteDatabase()
        try database.execute(PackageSchema.ddl)
        return database
    }

    @Test func createsEveryTable() throws {
        let names = try package().rows("SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name")
            .compactMap(\.first).compactMap { $0 }
        for table in ["edition", "books", "chapters", "verses", "verses_fts", "notes", "meta"] {
            #expect(names.contains(table), "\(table)")
        }
        let fts = try package().rows("SELECT sql FROM sqlite_schema WHERE name = 'verses_fts'")
        #expect(fts.first?.first??.contains("USING fts5") == true)
    }

    @Test func declaresItsFormatVersion() throws {
        let rows = try package().rows("SELECT value FROM meta WHERE key = 'format_version'")
        #expect(rows == [["\(PackageFormat.version)"]])
    }

    @Test func searchFindsVersesWithoutDiacritics() throws {
        let database = try package()
        try database.execute("""
            INSERT INTO books (id, canon_order, name, short_name, chapters) VALUES ('GEN', 1, 'Genesis', 'Gen', 50);
            INSERT INTO verses (id, book, chapter, verse, text_plain)
              VALUES (\(PackageSchema.verseRowID(VerseRef(.genesis, 1, 1))), 'GEN', 1, 1, 'In the beginning God créated');
            INSERT INTO verses (id, book, chapter, verse, text_plain)
              VALUES (\(PackageSchema.verseRowID(VerseRef(.genesis, 1, 2))), 'GEN', 1, 2, 'Now the earth was formless');
            """)
        let match = "SELECT v.book, v.chapter, v.verse FROM verses_fts JOIN verses v ON v.id = verses_fts.rowid WHERE verses_fts MATCH ?"
        #expect(try database.rows(match, ["created"]) == [["GEN", "1", "1"]])
        #expect(try database.rows(match, ["FORMLESS"]) == [["GEN", "1", "2"]])
        try database.execute("DELETE FROM verses WHERE verse = 2")
        #expect(try database.rows(match, ["formless"]).isEmpty)
        try database.execute("UPDATE verses SET text_plain = 'In the beginning was the Word' WHERE verse = 1")
        #expect(try database.rows(match, ["created"]).isEmpty)
        #expect(try database.rows(match, ["word"]) == [["GEN", "1", "1"]])
    }

    @Test func rejectsVerseRowsWhoseIdDisagrees() throws {
        let database = try package()
        #expect(throws: (any Error).self) {
            try database.execute("INSERT INTO verses (id, book, chapter, verse, text_plain) VALUES (1001002, 'GEN', 1, 1, 'x')")
        }
    }

    @Test func holdsOneEditionRow() throws {
        let database = try package()
        let insert = """
            INSERT INTO edition VALUES ('bsb', 'Berean Standard Bible', 'BSB', 'en', 'Latn', 'ltr', 'eng', 'Public domain',
              'Berean', 'Bible Hub', 'https://example.org', '2026.10', 'abc', 1, 0, '2026-10-29T00:00:00Z', 'GEN EXO');
            """
        try database.execute(insert)
        #expect(throws: (any Error).self) { try database.execute(insert.replacingOccurrences(of: "'bsb'", with: "'kjv'")) }
    }

    @Test func rowIDsIncreaseInCanonicalOrderAndInvert() throws {
        let refs = try Versification.counts(for: .eng).verseRefs
        let ids = refs.map(PackageSchema.verseRowID)
        #expect(zip(ids, ids.dropFirst()).allSatisfy { $0 < $1 })
        #expect(refs.map { PackageSchema.verseRef(rowID: PackageSchema.verseRowID($0)) } == refs)
        #expect(PackageSchema.verseRowID(VerseRef(.revelation, 22, 21)) == 66_022_021)
        #expect(PackageSchema.verseRowID(order: 1, chapter: 1, verse: 1) == 1_001_001)
    }

    @Test(arguments: [Int64(0), 1_000_000, 1_001_000, 1_000_001, 87_001_001, -1_001_001])
    func rejectsRowIDsThatNameNoVerse(rowID: Int64) {
        #expect(PackageSchema.verseRef(rowID: rowID) == nil)
    }
}

@Suite struct CanonSchemaTests {
    @Test func createsEveryTable() throws {
        let database = try SQLiteDatabase()
        try database.execute(CanonSchema.ddl)
        let names = try database.rows("SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name")
            .compactMap(\.first).compactMap { $0 }
        #expect(names == ["aliases", "books", "mappings", "meta", "schemes", "sections", "verse_counts"])
        #expect(try database.rows("SELECT value FROM meta WHERE key = 'format_version'") == [["1"]])
    }

    @Test func aliasesAreUniqueIgnoringCase() throws {
        let database = try SQLiteDatabase()
        try database.execute(CanonSchema.ddl)
        try database.execute("INSERT INTO aliases (alias, book) VALUES ('Gen', 'GEN')")
        #expect(throws: (any Error).self) { try database.execute("INSERT INTO aliases (alias, book) VALUES ('GEN', 'GEN')") }
    }

    @Test func mappingRowsNameAtLeastOneWholeSide() throws {
        let database = try SQLiteDatabase()
        try database.execute(CanonSchema.ddl)
        let insert = "INSERT INTO mappings (source, target, book, kind, source_chapter, source_verse, target_chapter, target_verse) VALUES"
        try database.execute("\(insert) ('heb', 'eng', 'PSA', 'superscriptionAsVerse1', 3, 1, NULL, NULL)")
        #expect(throws: (any Error).self) { try database.execute("\(insert) ('heb', 'eng', 'PSA', 'extraVerse', NULL, NULL, NULL, NULL)") }
        #expect(throws: (any Error).self) { try database.execute("\(insert) ('heb', 'eng', 'PSA', 'extraVerse', 3, NULL, NULL, NULL)") }
        #expect(throws: (any Error).self) { try database.execute("\(insert) ('heb', 'eng', 'PSA', 'sourceOnly', 3, 1, NULL, NULL)") }
    }
}

@Suite struct FormatDocumentTests {
    private func formatDocument() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("FORMAT.md"), encoding: .utf8)
    }

    @Test func quotesThePackageSchemaVerbatim() throws {
        #expect(try formatDocument().contains(PackageSchema.ddl))
    }

    @Test func quotesTheCanonSchemaVerbatim() throws {
        #expect(try formatDocument().contains(CanonSchema.ddl))
    }
}
