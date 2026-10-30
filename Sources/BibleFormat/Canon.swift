public enum Testament: String, CaseIterable, Codable, Sendable {
    case oldTestament = "OT"
    case newTestament = "NT"
    case apocrypha = "AP"
}

public enum Section: String, CaseIterable, Codable, Sendable {
    case law
    case history
    case wisdomAndPoetry
    case majorProphets
    case minorProphets
    case gospelsAndActs
    case paulsLetters
    case generalLetters
    case prophecy
    case apocrypha

    public var name: String {
        switch self {
        case .law: "Law"
        case .history: "History"
        case .wisdomAndPoetry: "Wisdom and Poetry"
        case .majorProphets: "Major Prophets"
        case .minorProphets: "Minor Prophets"
        case .gospelsAndActs: "Gospels and Acts"
        case .paulsLetters: "Paul's Letters"
        case .generalLetters: "General Letters"
        case .prophecy: "Prophecy"
        case .apocrypha: "Apocrypha"
        }
    }
}

public struct BookInfo: Sendable, Hashable {
    public let id: Book
    public let order: Int
    public let testament: Testament
    public let section: Section
    public let name: String
    public let shortName: String
    public let aliases: [String]
    public let chapters: Int

    public init(
        id: Book,
        order: Int,
        testament: Testament,
        section: Section,
        name: String,
        shortName: String,
        aliases: [String],
        chapters: Int
    ) {
        self.id = id
        self.order = order
        self.testament = testament
        self.section = section
        self.name = name
        self.shortName = shortName
        self.aliases = aliases
        self.chapters = chapters
    }

    /// Every string that names this book: id, name, short name, then aliases, deduplicated case-insensitively.
    public var lookupNames: [String] {
        var seen = Set<String>()
        return ([id.rawValue, name, shortName] + aliases).filter { seen.insert($0.lowercased()).inserted }
    }
}

public enum Canon {
    public static let defined: [BookInfo] = canonTable

    /// Decision 17: packages carry only the 66-book canon; the Apocrypha rows stay defined.
    public static let shipped: [BookInfo] = defined.filter { $0.testament != .apocrypha }

    public static func info(_ book: Book) -> BookInfo {
        guard let info = byBook[book] else {
            preconditionFailure("\(book.rawValue) has no row in the canon table")
        }
        return info
    }

    public static func book(matching alias: String) -> Book? {
        byLookupName[alias.lowercased()]
    }

    private static let byBook: [Book: BookInfo] = Dictionary(
        uniqueKeysWithValues: defined.map { ($0.id, $0) }
    )

    private static let byLookupName: [String: Book] = Dictionary(
        defined.flatMap { info in info.lookupNames.map { ($0.lowercased(), info.id) } },
        uniquingKeysWith: { first, _ in first }
    )
}

extension Book: Comparable {
    public static func < (lhs: Book, rhs: Book) -> Bool {
        Canon.info(lhs).order < Canon.info(rhs).order
    }
}
