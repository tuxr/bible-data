import BibleFormat
import Foundation
import Testing

private struct GoldenItems: Decodable {
    let book: Book
    let chapter: Int
    let items: [ChapterItem]

    var chapterValue: Chapter { Chapter(book: book, number: chapter, items: items) }
}

/// The committed parser goldens, read through their JSON items so these tests need no publisher sources.
private enum Goldens {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Goldens")

    static let chapters: [Chapter] = {
        let editions = ["bsb", "wlc", "tcgnt"]
        return editions.flatMap { edition -> [Chapter] in
            let folder = directory.appending(path: edition)
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.map { url in
                (try! JSONDecoder().decode(GoldenItems.self, from: Data(contentsOf: url))).chapterValue
            }
        }
    }()
}

/// SplitMix64, so a failing fuzz case reproduces.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct BinaryChapterCodecTests {
    let codec = BinaryChapterCodec()

    private func decode(_ bytes: [UInt8]) throws -> [ChapterItem] {
        try codec.decode(Data(bytes), book: .genesis, number: 1).items
    }

    private func decodeError(_ bytes: [UInt8]) -> BinaryChapterCodecError? {
        do {
            _ = try decode(bytes)
            return nil
        } catch {
            return error as? BinaryChapterCodecError
        }
    }

    @Test func goldensAreLoaded() {
        #expect(Goldens.chapters.count == 30)
    }

    @Test func fixtureRoundTripsByValue() throws {
        let fixture = ChapterCodecTests.fixture
        #expect(try codec.decode(codec.encode(fixture), book: fixture.book, number: fixture.number) == fixture)
    }

    @Test func everyGoldenRoundTripsAndEncodesDeterministically() throws {
        for chapter in Goldens.chapters {
            let first = try codec.encode(chapter)
            #expect(try codec.decode(first, book: chapter.book, number: chapter.number) == chapter)
            #expect(try codec.encode(chapter) == first)
        }
    }

    @Test func everyGoldenIsSmallerThanItsJSON() throws {
        for chapter in Goldens.chapters {
            #expect(try codec.encode(chapter).count < JSONChapterCodec().encode(chapter).count)
        }
    }

    /// FORMAT.md's worked example: the first five items of BSB Genesis 1.
    @Test func genesisOneOpeningMatchesTheDocumentedBytes() throws {
        let chapter = Chapter(book: .genesis, number: 1, items: [
            .heading(level: .two, [Run("The Creation")]),
            .noteCaller(NoteCaller(number: 1, kind: .crossReference, glyph: "a")),
            .block(.paragraph),
            .verse(VerseLabel(1)),
            .text(Run("In the beginning God created the heavens and the earth.")),
        ])
        let expected: [UInt8] = [0x05]
            + [0x22, 0x01, 0x0C] + Array("The Creation".utf8) + [0x00, 0x00]
            + [0x71, 0x01, 0x01, 0x61]
            + [0x10]
            + [0x50, 0x01, 0x00]
            + [0x60, 0x37] + Array("In the beginning God created the heavens and the earth.".utf8) + [0x00, 0x00]
        #expect(Array(try codec.encode(chapter)) == expected)
    }

    @Test func blockKindsLevelsAndOptionalsHaveTheirDocumentedBytes() throws {
        let chapter = Chapter(book: .psalms, number: 1, items: [
            .block(.poetry(level: .three)),
            .block(.list(level: .one)),
            .block(.blankLine),
            .verse(VerseLabel(2, through: 3)),
            .text(Run("x", style: [.wordsOfJesus, .selah], word: 200)),
        ])
        let expected: [UInt8] = [0x05, 0x1B, 0x1D, 0x15, 0x50, 0x02, 0x03, 0x60, 0x01, 0x78, 0x21, 0xC8, 0x01]
        #expect(Array(try codec.encode(chapter)) == expected)
    }

    @Test func everyStrictPrefixIsTruncated() throws {
        for chapter in Goldens.chapters.prefix(4) {
            let bytes = Array(try codec.encode(chapter))
            for length in 0..<bytes.count {
                guard case .truncated = decodeError(Array(bytes[..<length])) else {
                    Issue.record("\(chapter.book.rawValue) \(chapter.number) prefix \(length) did not throw truncated")
                    return
                }
            }
        }
    }

    @Test func flippedBytesDecodeOrThrowTheTypedError() throws {
        var generator = SeededGenerator(state: 0xB1B1E)
        for chapter in Goldens.chapters {
            let original = Array(try codec.encode(chapter))
            for _ in 0..<300 {
                var bytes = original
                for _ in 0..<Int.random(in: 1...4, using: &generator) {
                    bytes[Int.random(in: 0..<bytes.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
                }
                do {
                    _ = try decode(bytes)
                } catch is BinaryChapterCodecError {
                } catch {
                    Issue.record("an untyped error: \(error)")
                }
            }
        }
    }

    @Test func malformedBuffersThrowTheirError() {
        #expect(decodeError([0x01, 0x80]) == .unknownTag(0x80, offset: 1))
        #expect(decodeError([0x01, 0x16]) == .unknownTag(0x16, offset: 1))
        #expect(decodeError([0x01, 0x31, 0x00]) == .unknownTag(0x31, offset: 1))
        #expect(decodeError([0x01, 0x73, 0x01, 0x00]) == .unknownTag(0x73, offset: 1))
        #expect(decodeError([0x01, 0x18]) == .invalidLevel(0x18, offset: 1))
        #expect(decodeError([0x01, 0x20, 0x00]) == .invalidLevel(0x20, offset: 1))
        #expect(decodeError([0x01, 0x24, 0x00]) == .invalidLevel(0x24, offset: 1))
        #expect(decodeError([0x01, 0x60, 0x02, 0xC3, 0x28, 0x00, 0x00]) == .invalidUTF8(offset: 3))
        #expect(decodeError([0x01, 0x50, 0x03, 0x02]) == .invalidVerseBridge(offset: 3))
        #expect(decodeError([0x01, 0x50, 0x03, 0x03]) == .invalidVerseBridge(offset: 3))
        #expect(decodeError([0x01, 0x60, 0x00, 0x80, 0x80, 0x04, 0x00]) == .overflow(offset: 3))
        #expect(decodeError([0x01, 0x50] + Array(repeating: 0xFF, count: 10) + [0x01, 0x00]) == .overflow(offset: 2))
        #expect(decodeError([0x01, 0x60, 0x05, 0x41]) == .truncated(offset: 2))
        #expect(decodeError([0x7F, 0x10]) == .truncated(offset: 0))
        #expect(decodeError([0x01, 0x10, 0x10]) == .trailingBytes(offset: 2))
        #expect(decodeError([]) == .truncated(offset: 0))
    }

    @Test func valuesTheLayoutReservesAreNotEncodable() {
        for item in [ChapterItem.text(Run("x", word: 0)), .verse(VerseLabel(-1)), .noteCaller(NoteCaller(number: -2, kind: .footnote, glyph: "a"))] {
            #expect(throws: BinaryChapterCodecError.self) { try codec.encode(Chapter(book: .genesis, number: 1, items: [item])) }
        }
    }

    @Test func emptyChapterIsOneByte() throws {
        let empty = Chapter(book: .genesis, number: 1, items: [])
        #expect(Array(try codec.encode(empty)) == [0x00])
        #expect(try codec.decode(Data([0x00]), book: .genesis, number: 1) == empty)
    }
}
