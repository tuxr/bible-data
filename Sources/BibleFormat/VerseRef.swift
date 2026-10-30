public struct VerseRef: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let book: Book
    public let chapter: Int
    public let verse: Int

    public init(_ book: Book, _ chapter: Int, _ verse: Int) {
        self.book = book
        self.chapter = chapter
        self.verse = verse
    }

    public static func < (lhs: VerseRef, rhs: VerseRef) -> Bool {
        if lhs.book != rhs.book { return lhs.book < rhs.book }
        if lhs.chapter != rhs.chapter { return lhs.chapter < rhs.chapter }
        return lhs.verse < rhs.verse
    }

    public var description: String { "\(book.rawValue) \(chapter):\(verse)" }
}

public struct VerseRange: Hashable, Codable, Sendable {
    public let start: VerseRef
    public let end: VerseRef

    public init(_ start: VerseRef, through end: VerseRef) {
        precondition(start <= end, "a verse range runs forward")
        self.start = start
        self.end = end
    }
}
