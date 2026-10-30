import BibleFormat
import Foundation

/// The checks `bible-pack validate` runs, in order. A failure names the check.
enum PackageCheck: String, CaseIterable, Sendable {
    case integrity = "integrity_check"
    case foreignKeys = "foreign_key_check"
    case formatVersion = "format version"
    case edition
    case books
    case chapters
    case chapterDecode = "chapter decode"
    case textRoundTrip = "text round trip"
    case verseNumbers = "verse numbers"
    case verseRowIDs = "verse row ids"
    case searchText = "search text"
    case ftsIntegrity = "fts integrity-check"
    case ftsQuery = "fts sample query"
    case noteCallers = "note callers"
    case compressed
    case againstSource = "against source"
}

struct PackageValidationError: Error, CustomStringConvertible {
    let check: PackageCheck
    let message: String

    var description: String { "\(check.rawValue): \(message)" }
}

private struct ChapterKey: Hashable, Comparable, CustomStringConvertible {
    let book: Book
    let chapter: Int

    static func < (lhs: ChapterKey, rhs: ChapterKey) -> Bool {
        (Canon.info(lhs.book).order, lhs.chapter) < (Canon.info(rhs.book).order, rhs.chapter)
    }

    var description: String { "\(book.rawValue) \(chapter)" }
}

private struct VerseRow {
    let id: Int64
    let ref: VerseRef
    let textPlain: String
    let textSearch: String?
}

/// The query each script's sample search runs, and the verses it must find. The first candidate verse the
/// package holds is the one checked.
private let sampleQueries: [Script: (query: String, candidates: [VerseRef])] = [
    .latin: ("beginning", [VerseRef(.genesis, 1, 1), VerseRef(.john, 1, 1)]),
    .hebrew: ("בראשית", [VerseRef(.genesis, 1, 1)]),
    .greek: ("αρχη", [VerseRef(.john, 1, 1), VerseRef(.genesis, 1, 1)]),
]

enum PackageValidator {
    /// Reports each passing check to `pass` and throws on the first failure. `source` loads the edition from
    /// its locked source for `--against-source`.
    static func validate(
        at url: URL,
        source: ((String) throws -> EditionInput)? = nil,
        pass: (PackageCheck, String) -> Void
    ) throws {
        let database = try SQLiteDatabase(path: url.path, mode: .readOnly)
        func check(_ check: PackageCheck, _ detail: String, failure: String?) throws {
            if let failure { throw PackageValidationError(check: check, message: failure) }
            pass(check, detail)
        }

        let integrity = try database.pragma("integrity_check")
        try check(.integrity, "ok", failure: integrity == [[.text("ok")]] ? nil : "reported \(describe(integrity.first ?? []))")
        let foreignKeys = try database.pragma("foreign_key_check")
        try check(.foreignKeys, "no violations", failure: foreignKeys.first.map { "\(foreignKeys.count) violations, first \(describe($0))" })

        let meta = try Dictionary(database.rows("SELECT key, value FROM meta").compactMap { row -> (String, String)? in
            guard case .text(let key) = row[0], case .text(let value) = row[1] else { return nil }
            return (key, value)
        }, uniquingKeysWith: { first, _ in first })
        let editionRows = try database.rows("""
            SELECT id, script, direction, versification, chapter_encoding, format_version, built_at, canon FROM edition
            """)
        let kind = meta[PackageSchema.MetaKey.kind.rawValue]
        if kind != PackageKind.edition.rawValue {
            throw PackageValidationError(check: .formatVersion, message: "meta.kind is \(kind ?? "missing"), expected \(PackageKind.edition.rawValue)")
        }
        let metaVersion = meta[PackageSchema.MetaKey.formatVersion.rawValue]
        let editionVersion = editionRows.first.map { $0[5] }
        try check(.formatVersion, "\(PackageFormat.version)", failure: metaVersion != "\(PackageFormat.version)"
            ? "meta.format_version is \(metaVersion ?? "missing"), expected \(PackageFormat.version)"
            : editionVersion != .integer(PackageFormat.version)
            ? "edition.format_version is \(editionVersion.map(\.description) ?? "missing"), expected \(PackageFormat.version)" : nil)

        guard editionRows.count == 1, let edition = editionRows.first else {
            throw PackageValidationError(check: .edition, message: "edition has \(editionRows.count) rows, expected 1")
        }
        guard case .text(let editionID) = edition[0],
              case .text(let scriptCode) = edition[1], let script = Script(rawValue: scriptCode),
              case .text(let directionCode) = edition[2], directionCode == script.direction.rawValue,
              case .text(let schemeID) = edition[3], let scheme = VersificationScheme(rawValue: schemeID),
              case .integer(let encodingID) = edition[4], let encodingByte = UInt8(exactly: encodingID),
              let encoding = ChapterEncoding(rawValue: encodingByte),
              case .text(let builtAt) = edition[6], builtAt == meta[PackageSchema.MetaKey.builtAt.rawValue],
              case .text(let canon) = edition[7]
        else {
            throw PackageValidationError(check: .edition, message: "edition row \(describe(edition)) names an unknown script, "
                + "direction, versification, or chapter encoding, or a built_at that differs from meta")
        }
        guard let version = meta[PackageSchema.MetaKey.version.rawValue].flatMap(PackageVersion.init) else {
            throw PackageValidationError(check: .edition, message: "meta.version is \(meta["version"] ?? "missing"), expected yyyy.mm or yyyy.mm.n")
        }
        let counts = try Versification.counts(for: scheme)
        try check(.edition, "\(editionID) \(version), \(script.rawValue), \(scheme.rawValue), chapter encoding \(encoding)", failure: nil)

        let books = try bookRows(database)
        try check(.books, "\(books.count) books in canonical order", failure: booksFailure(books, counts: counts, canon: canon))

        let expectedChapters = books.flatMap { book in (1...book.chapters).map { ChapterKey(book: book.id, chapter: $0) } }
        let chapterRows = try database.rows("SELECT book, chapter, content FROM chapters")
        let chapterKeys = chapterRows.compactMap(chapterKey).sorted()
        try check(.chapters, "\(chapterKeys.count) chapters", failure: chapterKeys == expectedChapters
            ? nil : firstDifference(expected: expectedChapters, actual: chapterKeys))

        let codec = encoding.codec
        var decoded: [ChapterKey: Chapter] = [:]
        for row in chapterRows {
            guard let key = chapterKey(row), case .blob(let content) = row[2] else {
                throw PackageValidationError(check: .chapterDecode, message: "chapter row \(describe(row)) has no blob")
            }
            do {
                decoded[key] = try codec.decode(content, book: key.book, number: key.chapter)
            } catch {
                throw PackageValidationError(check: .chapterDecode, message: "\(key) does not decode with \(encoding): \(error)")
            }
        }
        try check(.chapterDecode, "\(decoded.count) chapters with \(encoding)", failure: nil)

        let verses = try verseRows(database)
        let versesByChapter = Dictionary(grouping: verses) { ChapterKey(book: $0.ref.book, chapter: $0.ref.chapter) }
        try check(.textRoundTrip, "\(verses.count) verses equal PlainText of their chapters",
                  failure: roundTripFailure(decoded: decoded, verses: versesByChapter))

        let absentValue = meta[PackageSchema.MetaKey.absentVerses.rawValue]
        guard let absent = absentValue.flatMap(AbsentVerses.decode) else {
            throw PackageValidationError(check: .verseNumbers, message: "meta.absent_verses is \(absentValue ?? "missing"), expected a JSON array of BOOK C:V")
        }
        try check(.verseNumbers, "every \(scheme.rawValue) verse is printed or one of \(absent.count) absent",
                  failure: verseNumbersFailure(decoded: decoded, absent: absent, counts: counts))

        let badID = verses.first { $0.id != PackageSchema.verseRowID($0.ref) }
        try check(.verseRowIDs, "\(verses.count) ids", failure: badID.map { "\($0.ref) has id \($0.id), expected \(PackageSchema.verseRowID($0.ref))" })

        let badSearch = verses.first { $0.textSearch != SearchText.column(plain: $0.textPlain, script: script) }
        try check(.searchText, "\(verses.count) verses folded for \(script.rawValue)", failure: badSearch.map {
            "\($0.ref) text_search is \($0.textSearch.map { "\"\($0)\"" } ?? "NULL"), expected "
                + (SearchText.column(plain: $0.textPlain, script: script).map { "\"\($0)\"" } ?? "NULL")
        })

        let packageBytes = try Data(contentsOf: url)
        do {
            try SQLiteDatabase.inMemoryCopy(of: packageBytes).exec("INSERT INTO verses_fts (verses_fts) VALUES ('integrity-check')")
            try check(.ftsIntegrity, "ok", failure: nil)
        } catch let error as SQLiteError {
            throw PackageValidationError(check: .ftsIntegrity, message: error.description)
        }

        try ftsQuery(database, script: script, verses: Set(verses.map(\.ref)), check: check)

        let notes = try database.rows("SELECT book, chapter, number, kind, caller FROM notes")
        try check(.noteCallers, "\(notes.count) notes match their callers", failure: noteCallersFailure(decoded: decoded, notes: notes))

        switch PackageWriter.checkCompressed(beside: url, packageBytes: packageBytes) {
        case .absent: break
        case .matches(let detail): try check(.compressed, detail, failure: nil)
        case .fails(let failure): try check(.compressed, "", failure: failure)
        }

        if let source {
            let input: EditionInput
            do {
                input = try source(editionID)
            } catch {
                throw PackageValidationError(check: .againstSource, message: "\(error)")
            }
            let content = input.content(version: version, builtAt: builtAt, encoding: encoding)
            try check(.againstSource, "\(decoded.count) chapters and every row match \(input.source.file)",
                      failure: try againstSourceFailure(database, content: content, decoded: decoded, meta: meta))
        }
    }

    private struct BookRow {
        let id: Book
        let order: Int
        let chapters: Int
    }

    private static func bookRows(_ database: SQLiteDatabase) throws -> [BookRow] {
        try database.rows("SELECT id, canon_order, chapters FROM books ORDER BY canon_order").map { row in
            guard case .text(let id) = row[0], let book = Book(rawValue: id), case .integer(let order) = row[1],
                  case .integer(let chapters) = row[2]
            else {
                throw PackageValidationError(check: .books, message: "book row \(describe(row)) names no defined book")
            }
            return BookRow(id: book, order: Int(order), chapters: Int(chapters))
        }
    }

    private static func booksFailure(_ books: [BookRow], counts: VerseCounts, canon: String) -> String? {
        if books.isEmpty { return "books is empty" }
        for book in books {
            if book.order != Canon.info(book.id).order {
                return "\(book.id.rawValue) has canon_order \(book.order), expected \(Canon.info(book.id).order)"
            }
            guard let chapters = counts.chapters(in: book.id) else { return "\(book.id.rawValue) is not in the \(counts.scheme.rawValue) scheme" }
            if book.chapters != chapters { return "\(book.id.rawValue) has \(book.chapters) chapters, the scheme has \(chapters)" }
        }
        let ids = books.map(\.id.rawValue).joined(separator: " ")
        return canon == ids ? nil : "edition.canon is \"\(canon)\", the books are \"\(ids)\""
    }

    private static func chapterKey(_ row: [SQLiteValue]) -> ChapterKey? {
        guard case .text(let id) = row[0], let book = Book(rawValue: id), case .integer(let chapter) = row[1] else { return nil }
        return ChapterKey(book: book, chapter: Int(chapter))
    }

    private static func verseRows(_ database: SQLiteDatabase) throws -> [VerseRow] {
        try database.rows("SELECT id, book, chapter, verse, text_plain, text_search FROM verses ORDER BY id").map { row in
            guard case .integer(let id) = row[0], case .text(let bookID) = row[1], let book = Book(rawValue: bookID),
                  case .integer(let chapter) = row[2], case .integer(let verse) = row[3],
                  case .text(let plain) = row[4]
            else {
                throw PackageValidationError(check: .textRoundTrip, message: "verse row \(describe(row)) is malformed")
            }
            return VerseRow(id: id, ref: VerseRef(book, Int(chapter), Int(verse)), textPlain: plain, textSearch: { if case .text(let search) = row[5] { search } else { nil } }())
        }
    }

    private static func roundTripFailure(decoded: [ChapterKey: Chapter], verses: [ChapterKey: [VerseRow]]) -> String? {
        if let orphan = verses.keys.sorted().first(where: { decoded[$0] == nil }) { return "\(orphan) has verse rows but no chapter" }
        for key in decoded.keys.sorted() {
            let expected = PlainText.verses(of: decoded[key]!).map { "\(key.book.rawValue) \(key.chapter):\($0.label.number) \($0.text)" }
            let actual = (verses[key] ?? []).map { "\($0.ref) \($0.textPlain)" }
            if expected != actual { return "\(key): " + firstDifference(expected: expected, actual: actual) }
        }
        return nil
    }

    private static func verseNumbersFailure(decoded: [ChapterKey: Chapter], absent: [VerseRef], counts: VerseCounts) -> String? {
        if let stray = absent.first(where: { !counts.contains($0) || decoded[ChapterKey(book: $0.book, chapter: $0.chapter)] == nil }) {
            return "absent verse \(stray) is not a verse of a chapter in the package"
        }
        let absentByChapter = Dictionary(grouping: absent) { ChapterKey(book: $0.book, chapter: $0.chapter) }
        for key in decoded.keys.sorted() {
            let printed = PlainText.verses(of: decoded[key]!).flatMap { $0.label.number...($0.label.through ?? $0.label.number) }
            let missing = Set((absentByChapter[key] ?? []).map(\.verse))
            let expected = (1...(counts.verses(in: key.book, chapter: key.chapter) ?? 0)).filter { !missing.contains($0) }
            if printed != expected {
                return "\(key) prints verses \(printed.map(String.init).joined(separator: ",")), expected \(expected.map(String.init).joined(separator: ","))"
            }
        }
        return nil
    }

    private static func ftsQuery(
        _ database: SQLiteDatabase,
        script: Script,
        verses: Set<VerseRef>,
        check: (PackageCheck, String, String?) throws -> Void
    ) throws {
        let sample = sampleQueries[script]!
        guard let expected = sample.candidates.first(where: verses.contains) else {
            return try check(.ftsQuery, "", "the package holds none of \(sample.candidates.map(\.description).joined(separator: ", "))")
        }
        let query = SearchText.normalizeQuery(sample.query, script: script)
        let found = try PackageWriter.count(
            in: database,
            "SELECT count(*) FROM verses_fts WHERE verses_fts MATCH ? AND rowid = ?",
            [.text(query), .integer(PackageSchema.verseRowID(expected))]
        )
        try check(.ftsQuery, "\(query) finds \(expected)", found == 1 ? nil : "\(query) does not find \(expected)")
    }

    private static func noteCallersFailure(decoded: [ChapterKey: Chapter], notes: [[SQLiteValue]]) -> String? {
        var rows: [ChapterKey: [(number: Int64, caller: String)]] = [:]
        for row in notes {
            guard let key = chapterKey(row), case .integer(let number) = row[2], case .text(let kind) = row[3],
                  case .text(let caller) = row[4] else { return "note row \(describe(row)) is malformed" }
            rows[key, default: []].append((number, "\(number) \(kind) [\(caller)]"))
        }
        if let orphan = rows.keys.sorted().first(where: { decoded[$0] == nil }) { return "\(orphan) has notes but no chapter" }
        for key in decoded.keys.sorted() {
            let callers = decoded[key]!.items.compactMap { item -> String? in
                guard case .noteCaller(let caller) = item else { return nil }
                return "\(caller.number) \(caller.kind.rawValue) [\(caller.glyph)]"
            }
            let expected = (rows[key] ?? []).sorted { $0.number < $1.number }.map(\.caller)
            if callers != expected { return "\(key): callers in the stream against notes rows: " + firstDifference(expected: expected, actual: callers) }
        }
        return nil
    }

    private static func againstSourceFailure(
        _ database: SQLiteDatabase,
        content: PackageContent,
        decoded: [ChapterKey: Chapter],
        meta: [String: String]
    ) throws -> String? {
        for row in content.meta.rows {
            guard case .text(let key) = row[0], case .text(let value) = row[1], key != PackageSchema.MetaKey.builderVersion.rawValue else { continue }
            if meta[key] != value { return "meta.\(key) is \(meta[key] ?? "missing"), the source gives \(value)" }
        }
        let chapters = content.books.flatMap(\.chapters).map(\.chapter)
        if chapters.count != decoded.count { return "the package has \(decoded.count) chapters, the source \(chapters.count)" }
        for chapter in chapters {
            let key = ChapterKey(book: chapter.book, chapter: chapter.number)
            guard let packaged = decoded[key] else { return "\(key) is missing" }
            if packaged.items != chapter.items {
                return "\(key) items: " + firstDifference(expected: chapter.items.map { "\($0)" }, actual: packaged.items.map { "\($0)" })
            }
        }
        for table in [content.edition, content.bookRows, content.verses, try content.notes()] {
            let expected = table.rows.map(describe).sorted()
            let actual = try database.rows(table.selectSQL).map(describe).sorted()
            if expected != actual { return "\(table.name): " + firstDifference(expected: expected, actual: actual) }
        }
        return nil
    }

    private static func firstDifference<Element: Equatable & CustomStringConvertible>(expected: [Element], actual: [Element]) -> String {
        func at(_ rows: [Element], _ index: Int) -> String { rows.indices.contains(index) ? rows[index].description : "nothing" }
        let index = (0..<max(expected.count, actual.count)).first { index in
            !(expected.indices.contains(index) && actual.indices.contains(index) && expected[index] == actual[index])
        } ?? 0
        let counts = expected.count == actual.count ? "" : "\(actual.count) entries, expected \(expected.count); "
        return "\(counts)first difference at \(index): expected \(at(expected, index)), found \(at(actual, index))"
    }

    private static func describe(_ row: [SQLiteValue]) -> String {
        "(" + row.map(\.description).joined(separator: ", ") + ")"
    }
}
