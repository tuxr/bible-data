import BibleFormat
import Foundation
import Testing

@Suite struct ChapterCodecTests {
    static let everyStyle: RunStyle = [
        .wordsOfJesus, .addedWords, .divineName, .transliteration, .quotedScripture, .selah,
    ]

    static let fixture = Chapter(book: .psalms, number: 3, items: [
        .title([Run("A Psalm of David, when he fled from Absalom his son.")]),
        .heading(level: .one, [Run("Book One")]),
        .heading(level: .two, [Run("Trust in "), Run("the LORD", style: .divineName)]),
        .heading(level: .three, [Run("Morning Prayer")]),
        .speaker([Run("David")]),
        .block(.poetry(level: .one)),
        .verse(VerseLabel(1)),
        .text(Run("O ")),
        .text(Run("LORD", style: .divineName, word: 2)),
        .text(Run(", how many are my foes!")),
        .noteCaller(NoteCaller(number: 1, kind: .footnote, glyph: "a")),
        .block(.poetry(level: .two)),
        .verse(VerseLabel(2, through: 3)),
        .text(Run("Selah", style: .selah)),
        .noteCaller(NoteCaller(number: 2, kind: .crossReference, glyph: "b")),
        .block(.poetry(level: .three)),
        .text(Run("I tell you", style: [.wordsOfJesus, .addedWords])),
        .text(Run("“Abba”", style: [.transliteration, .quotedScripture])),
        .text(Run("all", style: everyStyle, word: 7)),
        .noteCaller(NoteCaller(number: 3, kind: .translatorNote, glyph: "c")),
        .block(.paragraph),
        .block(.flush),
        .block(.indented),
        .block(.rightAligned),
        .block(.centered),
        .block(.list(level: .one)),
        .block(.list(level: .two)),
        .block(.list(level: .three)),
        .block(.blankLine),
        .text(Run("בְּרֵאשִׁית / ἐν ἀρχῇ", word: 1)),
    ])

    @Test func fixtureUsesEveryItemKind() {
        var kinds = Set<String>()
        for item in Self.fixture.items {
            switch item {
            case .block(let kind):
                switch kind {
                case .paragraph, .flush, .indented, .rightAligned, .centered, .blankLine: kinds.insert("\(kind)")
                case .poetry(let level): kinds.insert("poetry\(level.rawValue)")
                case .list(let level): kinds.insert("list\(level.rawValue)")
                }
            case .heading(let level, _): kinds.insert("heading\(level.rawValue)")
            case .title: kinds.insert("title")
            case .speaker: kinds.insert("speaker")
            case .verse: kinds.insert("verse")
            case .text: kinds.insert("text")
            case .noteCaller(let caller): kinds.insert("note-\(caller.kind)")
            }
        }
        #expect(kinds.count == 6 + 3 + 3 + 3 + 4 + 3)
    }

    @Test func jsonRoundTripsByValue() throws {
        let codec = JSONChapterCodec()
        let decoded = try codec.decode(codec.encode(Self.fixture), book: .psalms, number: 3)
        #expect(decoded == Self.fixture)
    }

    @Test func jsonReencodesByteForByte() throws {
        let codec = JSONChapterCodec()
        let first = try codec.encode(Self.fixture)
        let second = try codec.encode(codec.decode(first, book: .psalms, number: 3))
        #expect(first == second)
    }

    @Test func styleFlagsAreDistinctBits() {
        let flags: [RunStyle] = [.wordsOfJesus, .addedWords, .divineName, .transliteration, .quotedScripture, .selah]
        #expect(flags.allSatisfy { $0.rawValue.nonzeroBitCount == 1 })
        #expect(Self.everyStyle.rawValue.nonzeroBitCount == flags.count)
    }

    @Test func eachEncodingNamesItsCodec() {
        for encoding in ChapterEncoding.allCases {
            #expect(type(of: encoding.codec).encoding == encoding)
        }
    }

    @Test func noteTargetsRoundTrip() throws {
        let ranges = [
            VerseRange(VerseRef(.genesis, 1, 1), through: VerseRef(.genesis, 1, 3)),
            VerseRange(VerseRef(.john, 3, 16), through: VerseRef(.john, 3, 16)),
        ]
        let column = try NoteTargets.encode(ranges)
        #expect(try NoteTargets.decode(column) == ranges)
        #expect(try NoteTargets.encode(NoteTargets.decode(column)) == column)
    }
}
