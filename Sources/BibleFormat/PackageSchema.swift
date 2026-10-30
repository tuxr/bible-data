import Foundation

public enum PackageFormat {
    public static let version = 1
    /// Bumped for additive changes that a reader of the same `version` can ignore.
    public static let minor = 0
}

/// The `meta.kind` value every package's schema inserts, so a reader knows what a file is before it reads
/// any other table.
public enum PackageKind: String, Sendable, Hashable, CaseIterable {
    case edition
    case words
    case lexicon
    case canon

    public static let metaKey = "kind"
}

public enum PackageSchema {
    public enum MetaKey: String, CaseIterable, Sendable {
        case formatVersion = "format_version"
        case formatMinor = "format_minor"
        case kind
        case builtAt = "built_at"
        case builderVersion = "builder_version"
        case sourceLock = "source_lock"
        case absentVerses = "absent_verses"
    }

    /// Every chapter and verse number is below this, so the parts of a verse row id never overlap.
    public static let rowIDPartLimit = 1000

    public static func verseRowID(order: Int, chapter: Int, verse: Int) -> Int64 {
        precondition((1..<rowIDPartLimit).contains(chapter) && (1..<rowIDPartLimit).contains(verse))
        let limit = Int64(rowIDPartLimit)
        return Int64(order) * limit * limit + Int64(chapter) * limit + Int64(verse)
    }

    public static func verseRowID(_ ref: VerseRef) -> Int64 {
        verseRowID(order: Canon.info(ref.book).order, chapter: ref.chapter, verse: ref.verse)
    }

    /// Nil when the id does not decode to a defined book and nonzero chapter and verse.
    public static func verseRef(rowID: Int64) -> VerseRef? {
        let limit = Int64(rowIDPartLimit)
        let order = Int(rowID / (limit * limit))
        let chapter = Int(rowID / limit % limit)
        let verse = Int(rowID % limit)
        guard rowID > 0, Canon.defined.indices.contains(order - 1), chapter > 0, verse > 0 else { return nil }
        return VerseRef(Canon.defined[order - 1].id, chapter, verse)
    }

    public static let ddl = """
        CREATE TABLE meta (
          key TEXT PRIMARY KEY NOT NULL,
          value TEXT NOT NULL
        ) WITHOUT ROWID;

        INSERT INTO meta (key, value) VALUES ('\(MetaKey.formatVersion.rawValue)', '\(PackageFormat.version)');
        INSERT INTO meta (key, value) VALUES ('\(MetaKey.formatMinor.rawValue)', '\(PackageFormat.minor)');
        INSERT INTO meta (key, value) VALUES ('\(MetaKey.kind.rawValue)', '\(PackageKind.edition.rawValue)');

        CREATE TABLE edition (
          id TEXT PRIMARY KEY NOT NULL,
          name TEXT NOT NULL,
          abbreviation TEXT NOT NULL,
          language TEXT NOT NULL,
          script TEXT NOT NULL,
          direction TEXT NOT NULL CHECK (direction IN ('ltr', 'rtl')),
          versification TEXT NOT NULL CHECK (versification IN (\(sqlList(VersificationScheme.allCases)))),
          license TEXT NOT NULL,
          attribution TEXT NOT NULL,
          publisher TEXT NOT NULL,
          source_url TEXT NOT NULL,
          source_revision TEXT NOT NULL,
          source_sha256 TEXT NOT NULL,
          format_version INTEGER NOT NULL,
          chapter_encoding INTEGER NOT NULL,
          built_at TEXT NOT NULL,
          canon TEXT NOT NULL
        );

        CREATE TRIGGER edition_one_row BEFORE INSERT ON edition
        WHEN (SELECT count(*) FROM edition) > 0
        BEGIN
          SELECT RAISE(ABORT, 'edition holds one row');
        END;

        CREATE TABLE books (
          id TEXT PRIMARY KEY NOT NULL,
          canon_order INTEGER NOT NULL UNIQUE,
          name TEXT NOT NULL,
          short_name TEXT NOT NULL,
          chapters INTEGER NOT NULL CHECK (chapters BETWEEN 1 AND 999)
        );

        CREATE TABLE chapters (
          book TEXT NOT NULL REFERENCES books (id),
          chapter INTEGER NOT NULL CHECK (chapter BETWEEN 1 AND 999),
          content BLOB NOT NULL,
          PRIMARY KEY (book, chapter)
        );

        CREATE TABLE verses (
          id INTEGER PRIMARY KEY,
          book TEXT NOT NULL REFERENCES books (id),
          chapter INTEGER NOT NULL CHECK (chapter BETWEEN 1 AND 999),
          verse INTEGER NOT NULL CHECK (verse BETWEEN 1 AND 999),
          text_plain TEXT NOT NULL,
          text_search TEXT,
          UNIQUE (book, chapter, verse),
          CHECK (id % 1000 = verse AND id / 1000 % 1000 = chapter),
          CHECK (text_search IS NULL OR text_search <> text_plain)
        );

        CREATE VIEW verses_search AS
        SELECT id, coalesce(text_search, text_plain) AS text_search FROM verses;

        CREATE VIRTUAL TABLE verses_fts USING fts5 (
          text_search,
          content = 'verses_search',
          content_rowid = 'id',
          tokenize = 'unicode61 remove_diacritics 2'
        );

        CREATE TRIGGER verses_fts_insert AFTER INSERT ON verses BEGIN
          INSERT INTO verses_fts (rowid, text_search) VALUES (new.id, coalesce(new.text_search, new.text_plain));
        END;

        CREATE TRIGGER verses_fts_delete AFTER DELETE ON verses BEGIN
          INSERT INTO verses_fts (verses_fts, rowid, text_search) VALUES ('delete', old.id, coalesce(old.text_search, old.text_plain));
        END;

        CREATE TRIGGER verses_fts_update AFTER UPDATE ON verses BEGIN
          INSERT INTO verses_fts (verses_fts, rowid, text_search) VALUES ('delete', old.id, coalesce(old.text_search, old.text_plain));
          INSERT INTO verses_fts (rowid, text_search) VALUES (new.id, coalesce(new.text_search, new.text_plain));
        END;

        CREATE TABLE notes (
          book TEXT NOT NULL REFERENCES books (id),
          chapter INTEGER NOT NULL CHECK (chapter BETWEEN 1 AND 999),
          verse INTEGER NOT NULL CHECK (verse BETWEEN 0 AND 999),
          number INTEGER NOT NULL CHECK (number >= 1),
          kind TEXT NOT NULL CHECK (kind IN (\(sqlList(NoteKind.allCases)))),
          caller TEXT NOT NULL,
          text TEXT NOT NULL,
          targets TEXT,
          PRIMARY KEY (book, chapter, number)
        );

        """
}

/// The `notes.targets` column: a JSON array of verse ranges, in the edition's versification.
public enum NoteTargets {
    public static func encode(_ ranges: [VerseRange]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(ranges), as: UTF8.self)
    }

    public static func decode(_ column: String) throws -> [VerseRange] {
        try JSONDecoder().decode([VerseRange].self, from: Data(column.utf8))
    }
}

/// The `meta.absent_verses` value: a JSON array of `BOOK C:V` strings in canonical order, such as
/// `["LUK 17:36"]`. Validation allows exactly these verses of the scheme to have no row.
public enum AbsentVerses {
    public static func encode(_ refs: [VerseRef]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(refs.sorted().map(\.description)), as: UTF8.self)
    }

    /// Nil when the value is not a JSON array of `BOOK C:V` strings with defined books.
    public static func decode(_ value: String) -> [VerseRef]? {
        guard let strings = try? JSONDecoder().decode([String].self, from: Data(value.utf8)) else { return nil }
        var refs: [VerseRef] = []
        for string in strings {
            let parts = string.split(separator: " ")
            guard parts.count == 2, let book = Book(rawValue: String(parts[0])) else { return nil }
            let numbers = parts[1].split(separator: ":")
            guard numbers.count == 2, let chapter = Int(numbers[0]), let verse = Int(numbers[1]) else { return nil }
            refs.append(VerseRef(book, chapter, verse))
        }
        return refs
    }
}

/// A `meta` value that holds a JSON array of strings, such as a words package's `attribution`.
public enum MetaStrings {
    public static func encode(_ strings: [String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(strings), as: UTF8.self)
    }

    public static func decode(_ value: String) -> [String]? {
        try? JSONDecoder().decode([String].self, from: Data(value.utf8))
    }
}

func sqlList<Value: RawRepresentable>(_ values: [Value]) -> String where Value.RawValue == String {
    values.map { "'\($0.rawValue)'" }.joined(separator: ", ")
}
