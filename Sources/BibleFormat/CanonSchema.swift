public enum CanonSchema {
    public static let version = 1

    public static let ddl = """
        CREATE TABLE meta (
          key TEXT PRIMARY KEY NOT NULL,
          value TEXT NOT NULL
        ) WITHOUT ROWID;

        INSERT INTO meta (key, value) VALUES ('format_version', '\(version)');
        INSERT INTO meta (key, value) VALUES ('\(PackageKind.metaKey)', '\(PackageKind.canon.rawValue)');

        CREATE TABLE sections (
          id TEXT PRIMARY KEY NOT NULL,
          position INTEGER NOT NULL UNIQUE,
          name TEXT NOT NULL
        );

        CREATE TABLE books (
          id TEXT PRIMARY KEY NOT NULL,
          canon_order INTEGER NOT NULL UNIQUE,
          testament TEXT NOT NULL CHECK (testament IN (\(sqlList(Testament.allCases)))),
          section TEXT NOT NULL REFERENCES sections (id),
          name TEXT NOT NULL,
          short_name TEXT NOT NULL,
          chapters INTEGER NOT NULL CHECK (chapters BETWEEN 1 AND 999)
        );

        CREATE TABLE aliases (
          alias TEXT PRIMARY KEY NOT NULL COLLATE NOCASE,
          book TEXT NOT NULL REFERENCES books (id)
        );

        CREATE TABLE schemes (
          id TEXT PRIMARY KEY NOT NULL
        );

        CREATE TABLE verse_counts (
          scheme TEXT NOT NULL REFERENCES schemes (id),
          book TEXT NOT NULL REFERENCES books (id),
          chapter INTEGER NOT NULL CHECK (chapter BETWEEN 1 AND 999),
          verses INTEGER NOT NULL CHECK (verses BETWEEN 1 AND 999),
          PRIMARY KEY (scheme, book, chapter)
        ) WITHOUT ROWID;

        CREATE TABLE mappings (
          source TEXT NOT NULL REFERENCES schemes (id),
          target TEXT NOT NULL REFERENCES schemes (id),
          book TEXT NOT NULL REFERENCES books (id),
          kind TEXT NOT NULL CHECK (kind IN (\(sqlList(MappingKind.allCases)))),
          source_chapter INTEGER,
          source_verse INTEGER,
          target_chapter INTEGER,
          target_verse INTEGER,
          CHECK ((source_chapter IS NULL) = (source_verse IS NULL)),
          CHECK ((target_chapter IS NULL) = (target_verse IS NULL)),
          CHECK (source_chapter IS NOT NULL OR target_chapter IS NOT NULL)
        );

        CREATE INDEX mappings_by_source ON mappings (source, target, book, source_chapter, source_verse);
        CREATE INDEX mappings_by_target ON mappings (source, target, book, target_chapter, target_verse);

        """
}
