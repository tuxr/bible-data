import Foundation

public protocol ChapterCodec: Sendable {
    static var encoding: ChapterEncoding { get }
    func encode(_ chapter: Chapter) throws -> Data
    func decode(_ data: Data, book: Book, number: Int) throws -> Chapter
}

/// The value of `edition.chapter_encoding`.
public enum ChapterEncoding: UInt8, Codable, CaseIterable, Sendable {
    /// A test and benchmark baseline. Never written to a released package.
    case json = 0

    public var codec: any ChapterCodec {
        switch self {
        case .json: JSONChapterCodec()
        }
    }
}

/// Encodes only the items. Book and chapter number live in the `chapters` row.
public struct JSONChapterCodec: ChapterCodec {
    public static let encoding = ChapterEncoding.json

    public init() {}

    public func encode(_ chapter: Chapter) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(chapter.items)
    }

    public func decode(_ data: Data, book: Book, number: Int) throws -> Chapter {
        Chapter(book: book, number: number, items: try JSONDecoder().decode([ChapterItem].self, from: data))
    }
}
