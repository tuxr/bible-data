import BibleFormat
import Foundation
import Testing
@testable import bible_pack

struct GoldenCase: Sendable, CustomTestStringConvertible {
    let edition: String
    let book: Book
    let chapter: Int

    var testDescription: String { "\(edition) \(book.rawValue) \(chapter)" }
    var url: URL { RealSources.goldens.appending(path: "\(edition)/\(book.rawValue)-\(chapter).json") }
}

/// A committed golden: the chapter's items as `JSONChapterCodec` encodes them, then its notes, plain text, and word
/// tags. One element per line, so a change reads as a line diff.
struct Golden: Codable, Equatable {
    let book: Book
    let chapter: Int
    let items: [ChapterItem]
    let notes: [ParsedNote]
    let plain: [PlainVerse]
    let words: [VerseWords]

    init(_ parsed: ParsedChapter) {
        book = parsed.chapter.book
        chapter = parsed.chapter.number
        items = parsed.chapter.items
        notes = parsed.notes
        plain = PlainText.verses(of: parsed.chapter)
        words = parsed.words
    }

    func rendered() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func line(_ value: some Encodable) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
        func array(_ values: [some Encodable]) throws -> String {
            values.isEmpty ? "[]" : "[\n" + (try values.map { "    " + (try line($0)) }.joined(separator: ",\n")) + "\n  ]"
        }
        return """
        {
          "book" : \(try line(book)),
          "chapter" : \(chapter),
          "items" : \(try array(items)),
          "notes" : \(try array(notes)),
          "plain" : \(try array(plain)),
          "words" : \(try array(words))
        }

        """
    }
}

private func firstDifference(_ expected: String, _ actual: String) -> String {
    let old = expected.components(separatedBy: "\n")
    let new = actual.components(separatedBy: "\n")
    let differing = old.indices.first { !new.indices.contains($0) || old[$0] != new[$0] }
    guard let index = differing ?? (old.count == new.count ? nil : old.count) else { return "no difference" }
    let window = max(0, index - 2)..<(index + 3)
    func excerpt(_ lines: [String]) -> String {
        window.filter(lines.indices.contains).map { "\($0 + 1)\($0 == index ? ">" : " ") \(lines[$0])" }.joined(separator: "\n")
    }
    return "first difference at line \(index + 1) (golden has \(old.count) lines, parse has \(new.count))\n"
        + "golden:\n\(excerpt(old))\nparse:\n\(excerpt(new))"
}

@Suite(.enabled(if: RealSources.present, RealSources.skipMessage))
struct GoldenTests {
    static let cases: [GoldenCase] =
        [
            (Book.psalms, 3), (.psalms, 23), (.psalms, 51), (.psalms, 119), (.songOfSolomon, 1), (.obadiah, 1),
            (.philemon, 1), (.jude, 1), (.matthew, 3), (.matthew, 5), (.john, 8), (.mark, 16), (.habakkuk, 3),
            (.zechariah, 12), (.genesis, 1), (.isaiah, 53),
        ].map { GoldenCase(edition: "bsb", book: $0.0, chapter: $0.1) }
        + [(Book.genesis, 1), (.psalms, 3), (.psalms, 119), (.deuteronomy, 6), (.songOfSolomon, 1), (.obadiah, 1)]
            .map { GoldenCase(edition: "wlc", book: $0.0, chapter: $0.1) }
        + [
            (Book.matthew, 3), (.romans, 14), (.romans, 16), (.thirdJohn, 1), (.john, 8), (.luke, 17), (.acts, 8),
            (.revelation, 22),
        ].map { GoldenCase(edition: "tcgnt", book: $0.0, chapter: $0.1) }

    static func parsed(_ golden: GoldenCase) throws -> ParsedChapter {
        let book = try #require(RealSources.edition(golden.edition).books.first { $0.book == golden.book })
        return try #require(book.chapters.first { $0.chapter.number == golden.chapter })
    }

    /// `UPDATE_GOLDENS=1 swift test` rewrites every golden from a fresh parse.
    @Test(arguments: cases)
    func aFreshParseMatchesTheCommittedGolden(_ golden: GoldenCase) throws {
        let rendered = try Golden(Self.parsed(golden)).rendered()
        if ProcessInfo.processInfo.environment["UPDATE_GOLDENS"] == "1" {
            try FileManager.default.createDirectory(at: golden.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(rendered.utf8).write(to: golden.url, options: .atomic)
        }
        let committed = try String(contentsOf: golden.url, encoding: .utf8)
        #expect(committed == rendered, "\(golden.testDescription): \(firstDifference(committed, rendered))")
        let decoded = try JSONDecoder().decode(Golden.self, from: Data(committed.utf8))
        #expect(decoded == Golden(try Self.parsed(golden)))
    }

    @Test(arguments: cases)
    func theChapterRoundTripsThroughTheJSONCodec(_ golden: GoldenCase) throws {
        let chapter = try Self.parsed(golden).chapter
        let codec = JSONChapterCodec()
        let first = try codec.encode(chapter)
        #expect(try codec.encode(chapter) == first)
        #expect(try codec.decode(first, book: chapter.book, number: chapter.number) == chapter)
    }

    @Test(arguments: cases)
    func theChapterKeepsTheStreamRules(_ golden: GoldenCase) throws {
        #expect(streamViolations(try Self.parsed(golden)) == [])
    }
}
