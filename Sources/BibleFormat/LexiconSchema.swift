/// The language a lexicon package defines words of, and the Strong's ids it keys them by.
public enum LexiconLanguage: String, Sendable, Hashable, CaseIterable {
    case greek
    case hebrew

    /// The BCP 47 tag `meta.language` holds.
    public var code: String {
        switch self {
        case .greek: "grc"
        case .hebrew: "hbo"
        }
    }

    public var strongLanguage: StrongLanguage {
        switch self {
        case .greek: .greek
        case .hebrew: .hebrew
        }
    }

    public init?(code: String) {
        guard let match = Self.allCases.first(where: { $0.code == code }) else { return nil }
        self = match
    }

    public func fileName(version: String) -> String { "lexicon-\(rawValue)-\(version).lexicon" }
}

/// The `lexicon-<greek|hebrew>-<yyyy.mm>.lexicon` package: one dictionary entry per Strong's id, shared by
/// every words package in the language.
public enum LexiconSchema {
    public enum MetaKey: String, CaseIterable, Sendable {
        case formatVersion = "format_version"
        case formatMinor = "format_minor"
        case kind
        case version
        case builtAt = "built_at"
        case builderVersion = "builder_version"
        case language
        case attribution
        case sources
    }

    public static let ddl = """
        CREATE TABLE meta (
          key TEXT PRIMARY KEY NOT NULL,
          value TEXT NOT NULL
        ) WITHOUT ROWID;

        INSERT INTO meta (key, value) VALUES ('\(MetaKey.formatVersion.rawValue)', '\(PackageFormat.version)');
        INSERT INTO meta (key, value) VALUES ('\(MetaKey.formatMinor.rawValue)', '\(PackageFormat.minor)');
        INSERT INTO meta (key, value) VALUES ('\(MetaKey.kind.rawValue)', '\(PackageKind.lexicon.rawValue)');

        CREATE TABLE entries (
          strong TEXT PRIMARY KEY NOT NULL,
          lemma TEXT NOT NULL CHECK (lemma <> ''),
          transliteration TEXT,
          pronunciation TEXT,
          part_of_speech TEXT,
          gloss TEXT,
          definition TEXT,
          occurrences INTEGER CHECK (occurrences >= 0)
        ) WITHOUT ROWID;

        """
}
