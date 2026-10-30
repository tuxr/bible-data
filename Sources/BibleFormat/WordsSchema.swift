import Foundation

/// The `<edition>-<yyyy.mm>.words` companion package: one row per word of a tagged edition, keyed by the
/// edition's own verse row id and the word's position, the same coordinates as `Run.word`.
public enum WordsSchema {
    public enum MetaKey: String, CaseIterable, Sendable {
        case formatVersion = "format_version"
        case formatMinor = "format_minor"
        case kind
        case builtAt = "built_at"
        case builderVersion = "builder_version"
        case edition
        case editionSourceSha256 = "edition_source_sha256"
        case attribution
        case sources
    }

    public static func fileName(edition: String, version: String) -> String { "\(edition)-\(version).words" }

    public static let ddl = """
        CREATE TABLE meta (
          key TEXT PRIMARY KEY NOT NULL,
          value TEXT NOT NULL
        ) WITHOUT ROWID;

        INSERT INTO meta (key, value) VALUES ('\(MetaKey.formatVersion.rawValue)', '\(PackageFormat.version)');
        INSERT INTO meta (key, value) VALUES ('\(MetaKey.formatMinor.rawValue)', '\(PackageFormat.minor)');
        INSERT INTO meta (key, value) VALUES ('\(MetaKey.kind.rawValue)', '\(PackageKind.words.rawValue)');

        CREATE TABLE words (
          verse_id INTEGER NOT NULL,
          position INTEGER NOT NULL CHECK (position >= 1),
          surface TEXT NOT NULL,
          strong TEXT,
          morph TEXT,
          lemma TEXT,
          gloss TEXT,
          parts TEXT,
          PRIMARY KEY (verse_id, position)
        ) WITHOUT ROWID;

        """
}

/// One piece of a word that its tagging source splits, such as a Hebrew prefix, stem, or suffix.
public struct WordPart: Codable, Sendable, Hashable {
    public var strong: String?
    public var morph: String?
    public var gloss: String?
    /// The piece of the edition's own surface, when the word's letters split cleanly into the pieces.
    public var surface: String?

    public init(strong: String? = nil, morph: String? = nil, gloss: String? = nil, surface: String? = nil) {
        self.strong = strong
        self.morph = morph
        self.gloss = gloss
        self.surface = surface
    }
}

/// The `words.parts` column: a JSON array of `WordPart` objects with sorted keys and absent fields left out.
public enum WordParts {
    public static func encode(_ parts: [WordPart]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(parts), as: UTF8.self)
    }

    /// Nil when the value is not a nonempty JSON array of parts.
    public static func decode(_ value: String) -> [WordPart]? {
        guard let parts = try? JSONDecoder().decode([WordPart].self, from: Data(value.utf8)), !parts.isEmpty else { return nil }
        return parts
    }
}
