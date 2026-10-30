public struct Chapter: Codable, Hashable, Sendable {
    public let book: Book
    public let number: Int
    public let items: [ChapterItem]

    public init(book: Book, number: Int, items: [ChapterItem]) {
        self.book = book
        self.number = number
        self.items = items
    }
}

public enum ChapterItem: Codable, Hashable, Sendable {
    /// Starts a paragraph-level block. Text that follows belongs to it until the next block or heading.
    case block(BlockKind)
    case heading(level: Level, [Run])
    /// A Psalm superscription that the edition does not number as a verse.
    case title([Run])
    case speaker([Run])
    /// Starts a verse. Text that follows belongs to it until the next verse marker.
    case verse(VerseLabel)
    case text(Run)
    case noteCaller(NoteCaller)
}

public enum Level: Int, Codable, CaseIterable, Sendable {
    case one = 1
    case two
    case three
}

public enum BlockKind: Codable, Hashable, Sendable {
    case paragraph
    case flush
    case indented
    case poetry(level: Level)
    case rightAligned
    case centered
    case list(level: Level)
    case blankLine
}

public struct VerseLabel: Codable, Hashable, Sendable {
    public let number: Int
    /// The last verse of a bridge such as 1-2. Nil for a single verse.
    public let through: Int?

    public init(_ number: Int, through: Int? = nil) {
        precondition(through.map { $0 > number } ?? true, "a verse bridge ends after it starts")
        self.number = number
        self.through = through
    }
}

public struct Run: Codable, Hashable, Sendable {
    public let text: String
    public let style: RunStyle
    /// The 1-based position of the word in its verse, for word-tagged editions. Nil for untagged text,
    /// spaces, and punctuation. A word split across styles keeps one index on every piece.
    public let word: Int?

    public init(_ text: String, style: RunStyle = [], word: Int? = nil) {
        self.text = text
        self.style = style
        self.word = word
    }
}

public struct RunStyle: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let wordsOfJesus = RunStyle(rawValue: 1 << 0)
    public static let addedWords = RunStyle(rawValue: 1 << 1)
    public static let divineName = RunStyle(rawValue: 1 << 2)
    public static let transliteration = RunStyle(rawValue: 1 << 3)
    public static let quotedScripture = RunStyle(rawValue: 1 << 4)
    public static let selah = RunStyle(rawValue: 1 << 5)
}

public enum NoteKind: String, Codable, CaseIterable, Sendable {
    case footnote
    case crossReference
    case translatorNote
}

public struct NoteCaller: Codable, Hashable, Sendable {
    /// The note's `notes.number` within this chapter.
    public let number: Int
    public let kind: NoteKind
    public let glyph: String

    public init(number: Int, kind: NoteKind, glyph: String) {
        self.number = number
        self.kind = kind
        self.glyph = glyph
    }
}
