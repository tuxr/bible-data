import Foundation

public enum PackageFormat {
    public static let version = 1
    /// Bumped for additive changes that a reader of the same `version` can ignore.
    public static let minor = 0
}

public enum PackageSchema {
    public enum MetaKey: String, CaseIterable, Sendable {
        case formatVersion = "format_version"
        case formatMinor = "format_minor"
        case builtAt = "built_at"
        case builderVersion = "builder_version"
        case sourceLock = "source_lock"
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
          UNIQUE (book, chapter, verse),
          CHECK (id % 1000 = verse AND id / 1000 % 1000 = chapter)
        );

        CREATE VIRTUAL TABLE verses_fts USING fts5 (
          text_plain,
          content = 'verses',
          content_rowid = 'id',
          tokenize = 'unicode61 remove_diacritics 2'
        );

        CREATE TRIGGER verses_fts_insert AFTER INSERT ON verses BEGIN
          INSERT INTO verses_fts (rowid, text_plain) VALUES (new.id, new.text_plain);
        END;

        CREATE TRIGGER verses_fts_delete AFTER DELETE ON verses BEGIN
          INSERT INTO verses_fts (verses_fts, rowid, text_plain) VALUES ('delete', old.id, old.text_plain);
        END;

        CREATE TRIGGER verses_fts_update AFTER UPDATE ON verses BEGIN
          INSERT INTO verses_fts (verses_fts, rowid, text_plain) VALUES ('delete', old.id, old.text_plain);
          INSERT INTO verses_fts (rowid, text_plain) VALUES (new.id, new.text_plain);
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

func sqlList<Value: RawRepresentable>(_ values: [Value]) -> String where Value.RawValue == String {
    values.map { "'\($0.rawValue)'" }.joined(separator: ", ")
}
