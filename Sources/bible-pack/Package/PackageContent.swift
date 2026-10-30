import BibleFormat
import Foundation

/// One edition package table's rows, in insertion order.
struct PackageTable {
    let name: String
    let columns: [String]
    let rows: [[SQLiteValue]]

    var selectSQL: String { "SELECT \(columns.joined(separator: ", ")) FROM \(name)" }
}

/// Everything an edition package holds, derived from the parse. `build` inserts these tables and
/// `validate --against-source` compares a package to them.
struct PackageContent {
    let metadata: EditionMetadata
    let source: LockedSource
    let books: [ParsedBook]
    let version: PackageVersion
    let builtAt: String
    let encoding: ChapterEncoding

    /// In insertion order, so every row's foreign keys already exist. The schema inserts `format_version`
    /// and `format_minor` into `meta`.
    func tables() throws -> [PackageTable] {
        [meta, edition, bookRows, try chapters(), verses, try notes()]
    }

    var meta: PackageTable {
        let rows: [(PackageSchema.MetaKey, String)] = [
            (.version, version.description),
            (.builtAt, builtAt),
            (.builderVersion, BiblePackVersion.current),
            (.sourceLock, Self.json(source)),
            (.absentVerses, AbsentVerses.encode(books.flatMap(\.absentVerses))),
        ]
        return PackageTable(name: "meta", columns: ["key", "value"], rows: rows.map { [.text($0.0.rawValue), .text($0.1)] })
    }

    var edition: PackageTable {
        PackageTable(
            name: "edition",
            columns: ["id", "name", "abbreviation", "language", "script", "direction", "versification", "license",
                      "attribution", "publisher", "source_url", "source_revision", "source_sha256", "format_version",
                      "chapter_encoding", "built_at", "canon"],
            rows: [[
                .text(metadata.id), .text(metadata.name), .text(metadata.abbreviation), .text(metadata.language),
                .text(metadata.script.rawValue), .text(metadata.direction.rawValue), .text(metadata.versification.rawValue),
                .text(metadata.license), .text(metadata.attribution), .text(metadata.publisher),
                .text(source.url.absoluteString), .text(source.revision), .text(source.sha256),
                .integer(PackageFormat.version), .integer(Int(encoding.rawValue)), .text(builtAt),
                .text(books.map(\.book.rawValue).joined(separator: " ")),
            ]]
        )
    }

    var bookRows: PackageTable {
        PackageTable(
            name: "books",
            columns: ["id", "canon_order", "name", "short_name", "chapters"],
            rows: books.map { book in
                [.text(book.book.rawValue), .integer(Canon.info(book.book).order), .text(book.name), .text(book.shortName),
                 .integer(book.chapters.count)]
            }
        )
    }

    func chapters() throws -> PackageTable {
        let codec = encoding.codec
        return PackageTable(
            name: "chapters",
            columns: ["book", "chapter", "content"],
            rows: try books.flatMap(\.chapters).map { parsed in
                [.text(parsed.chapter.book.rawValue), .integer(parsed.chapter.number), .blob(try codec.encode(parsed.chapter))]
            }
        )
    }

    /// One row per verse label. A bridge such as 1-2 is one row at its first verse.
    var verses: PackageTable {
        PackageTable(
            name: "verses",
            columns: ["id", "book", "chapter", "verse", "text_plain", "text_search"],
            rows: books.flatMap(\.chapters).flatMap { parsed in
                PlainText.verses(of: parsed.chapter).map { verse in
                    let ref = VerseRef(parsed.chapter.book, parsed.chapter.number, verse.label.number)
                    return [.integer(PackageSchema.verseRowID(ref)), .text(ref.book.rawValue), .integer(ref.chapter),
                            .integer(ref.verse), .text(verse.text),
                            SearchText.column(plain: verse.text, script: metadata.script).map { .text($0) } ?? .null]
                }
            }
        )
    }

    func notes() throws -> PackageTable {
        PackageTable(
            name: "notes",
            columns: ["book", "chapter", "verse", "number", "kind", "caller", "text", "targets"],
            rows: try books.flatMap(\.chapters).flatMap { parsed in
                try parsed.notes.map { note in
                    [.text(parsed.chapter.book.rawValue), .integer(parsed.chapter.number), .integer(note.verse),
                     .integer(note.number), .text(note.kind.rawValue), .text(note.caller), .text(note.text),
                     note.targets.isEmpty ? .null : .text(try NoteTargets.encode(note.targets))]
                }
            }
        )
    }

    private static func json(_ source: LockedSource) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(source), as: UTF8.self)
    }
}
