/// One book as a parser read it from a publisher source: the chapter streams, the rows of the `notes`
/// table, and the word tags, ready for the packager to encode.
public struct ParsedBook: Sendable, Hashable {
    public let book: Book
    public let name: String
    public let shortName: String
    public let chapters: [ParsedChapter]
    /// Verses of the edition's scheme that the edition does not print, such as TCGNT's Luke 17:36.
    public let absentVerses: [VerseRef]

    public init(book: Book, name: String, shortName: String, chapters: [ParsedChapter], absentVerses: [VerseRef]) {
        self.book = book
        self.name = name
        self.shortName = shortName
        self.chapters = chapters
        self.absentVerses = absentVerses
    }
}

public struct ParsedChapter: Sendable, Hashable {
    public let chapter: Chapter
    /// In `number` order, which is the order of the note callers in the stream.
    public let notes: [ParsedNote]
    /// One entry per verse with words, in stream order. Empty for an untagged edition.
    public let words: [VerseWords]

    public init(chapter: Chapter, notes: [ParsedNote], words: [VerseWords]) {
        self.chapter = chapter
        self.notes = notes
        self.words = words
    }
}

/// A row of the `notes` table, less the book and chapter its `ParsedChapter` already names.
public struct ParsedNote: Codable, Sendable, Hashable {
    /// The verse that holds the caller, or 0 before verse 1.
    public let verse: Int
    /// Matches the `NoteCaller.number` of the caller in the stream.
    public let number: Int
    public let kind: NoteKind
    public let caller: String
    public let text: String
    public let targets: [VerseRange]

    public init(verse: Int, number: Int, kind: NoteKind, caller: String, text: String, targets: [VerseRange]) {
        self.verse = verse
        self.number = number
        self.kind = kind
        self.caller = caller
        self.text = text
        self.targets = targets
    }
}

public struct VerseWords: Codable, Sendable, Hashable {
    public let ref: VerseRef
    public let words: [WordTag]

    public init(ref: VerseRef, words: [WordTag]) {
        self.ref = ref
        self.words = words
    }
}

/// A word of a tagged edition. A word the source leaves untagged keeps its place with no `strong` or `morph`.
public struct WordTag: Codable, Sendable, Hashable {
    /// The 1-based position in the verse, equal to `Run.word` on the word's runs.
    public let index: Int
    public let surface: String
    public let strong: String?
    public let morph: String?

    public init(index: Int, surface: String, strong: String? = nil, morph: String? = nil) {
        self.index = index
        self.surface = surface
        self.strong = strong
        self.morph = morph
    }
}

public struct PlainVerse: Codable, Sendable, Hashable {
    public let label: VerseLabel
    public let text: String

    public init(label: VerseLabel, text: String) {
        self.label = label
        self.text = text
    }
}

/// The `verses.text_plain` rule. The packager and the app both derive plain text here, so search, copy, and
/// anchoring agree with what the reader shows.
public enum PlainText {
    /// Every verse in stream order, with its text runs joined. Headings, titles, speakers, and note callers are
    /// not verse text. Text before the first verse belongs to no verse.
    public static func verses(of chapter: Chapter) -> [PlainVerse] {
        var verses: [PlainVerse] = []
        var label: VerseLabel?
        var text = ""
        var atBoundary = false

        func finishVerse() {
            if let label { verses.append(PlainVerse(label: label, text: clean(text))) }
        }

        for item in chapter.items {
            switch item {
            case .verse(let next):
                finishVerse()
                label = next
                text = ""
                atBoundary = false
            case .block, .heading, .title, .speaker:
                atBoundary = true
            case .noteCaller:
                break
            case .text(let run):
                guard label != nil else { continue }
                // A line that ends in an em dash runs on into the next with no space, as the publishers print it.
                if atBoundary, !text.isEmpty, text.last != "\u{2014}" { text += " " }
                text += run.text
                atBoundary = false
            }
        }
        finishVerse()
        return verses
    }

    /// Collapses whitespace to single spaces, removes a space before `.`, `,`, `;`, `:`, `!`, and `?`, and trims.
    /// Applies no Unicode normalization: NFC would reorder Hebrew points and accents.
    public static func clean(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace, !spaceRemovedBefore.contains(scalar) { out.append(" ") }
            pendingSpace = false
            out.append(scalar)
        }
        return String(out)
    }

    private static let spaceRemovedBefore: Set<Unicode.Scalar> = [".", ",", ";", ":", "!", "?"]
}
