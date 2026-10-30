import BibleFormat
import Foundation

/// One canon package table as the `BibleFormat` types define it. `canon build` inserts these rows in this
/// order and `canon validate` compares the file against them.
struct CanonTable {
    let name: String
    let columns: [String]
    let rows: [[SQLiteValue]]

    var insertSQL: String {
        "INSERT INTO \(name) (\(columns.joined(separator: ", "))) VALUES (\(columns.map { _ in "?" }.joined(separator: ", ")))"
    }

    var selectSQL: String { "SELECT \(columns.joined(separator: ", ")) FROM \(name)" }
}

enum CanonContent {
    /// Tables in insertion order, so every row's foreign keys already exist.
    static func tables() throws -> [CanonTable] {
        [sections, books, aliases, schemes, try verseCounts(), try mappings()]
    }

    /// The `meta` rows the builder adds. The schema inserts `format_version`.
    static func meta(builtAt: String) -> [(key: String, value: String)] {
        [
            (PackageSchema.MetaKey.builtAt.rawValue, builtAt),
            (PackageSchema.MetaKey.builderVersion.rawValue, BiblePackVersion.current),
            ("versification_attribution", Versification.attribution),
        ]
    }

    static let sections = CanonTable(
        name: "sections",
        columns: ["id", "position", "name"],
        rows: Section.allCases.enumerated().map { offset, section in
            [.text(section.rawValue), .integer(offset + 1), .text(section.name)]
        }
    )

    static let books = CanonTable(
        name: "books",
        columns: ["id", "canon_order", "testament", "section", "name", "short_name", "chapters"],
        rows: Canon.defined.map { info in
            [
                .text(info.id.rawValue), .integer(info.order), .text(info.testament.rawValue),
                .text(info.section.rawValue), .text(info.name), .text(info.shortName), .integer(info.chapters),
            ]
        }
    )

    static let aliases = CanonTable(
        name: "aliases",
        columns: ["alias", "book"],
        rows: Canon.defined.flatMap { info in
            info.lookupNames.map { [.text($0), .text(info.id.rawValue)] }
        }
    )

    static let schemes = CanonTable(
        name: "schemes",
        columns: ["id"],
        rows: VersificationScheme.allCases.map { [.text($0.rawValue)] }
    )

    static func verseCounts() throws -> CanonTable {
        let rows: [[SQLiteValue]] = try VersificationScheme.allCases.flatMap { scheme in
            let counts = try Versification.counts(for: scheme)
            return counts.books.flatMap { book in
                (1...(counts.chapters(in: book) ?? 0)).compactMap { chapter -> [SQLiteValue]? in
                    counts.verses(in: book, chapter: chapter).map { verses in
                        [.text(scheme.rawValue), .text(book.rawValue), .integer(chapter), .integer(verses)]
                    }
                }
            }
        }
        return CanonTable(name: "verse_counts", columns: ["scheme", "book", "chapter", "verses"], rows: rows)
    }

    static func mappings() throws -> CanonTable {
        let rows: [[SQLiteValue]] = try Versification.storedMappings().flatMap { mapping in
            mapping.entries.map { entry in
                let (book, source, target, kind): (Book, VerseRef?, VerseRef?, MappingKind) = switch entry {
                case .pair(let source, let target, let kind): (source.book, source, target, kind)
                case .sourceOnly(let source, let kind): (source.book, source, nil, kind)
                case .targetOnly(let target, let kind): (target.book, nil, target, kind)
                }
                return [
                    .text(mapping.source.rawValue), .text(mapping.target.rawValue), .text(book.rawValue), .text(kind.rawValue),
                    .optional(source?.chapter), .optional(source?.verse),
                    .optional(target?.chapter), .optional(target?.verse),
                ]
            }
        }
        return CanonTable(
            name: "mappings",
            columns: ["source", "target", "book", "kind", "source_chapter", "source_verse", "target_chapter", "target_verse"],
            rows: rows
        )
    }
}
