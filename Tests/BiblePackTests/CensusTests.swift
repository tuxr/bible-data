import BibleFormat
import Foundation
import Testing
@testable import bible_pack

private struct Census: Equatable, CustomStringConvertible {
    var books = 0
    var chapters = 0
    var verses = 0

    init(_ edition: ParsedEdition) {
        books = edition.books.count
        chapters = edition.books.reduce(0) { $0 + $1.chapters.count }
        verses = edition.books.flatMap(\.chapters).reduce(0) { $0 + PlainText.verses(of: $1.chapter).count }
    }

    init(books: Int, chapters: Int, verses: Int) {
        self.books = books
        self.chapters = chapters
        self.verses = verses
    }

    var description: String { "\(books) books, \(chapters) chapters, \(verses) verses" }
}

private func plainText(_ edition: ParsedEdition, _ book: Book, _ chapter: Int, _ verse: Int) -> String? {
    edition.books.first { $0.book == book }?.chapters.first { $0.chapter.number == chapter }
        .flatMap { PlainText.verses(of: $0.chapter).first { $0.label.number == verse }?.text }
}

@Suite(.enabled(if: RealSources.present, RealSources.skipMessage))
struct CensusTests {
    static let editions: [(id: String, scheme: VersificationScheme)] = [("bsb", .eng), ("wlc", .heb), ("tcgnt", .grc)]

    @Test(arguments: ["bsb", "wlc", "tcgnt"])
    func everyEditionParsesWithNoWarnings(_ id: String) {
        #expect(RealSources.edition(id).report.warnings == [])
    }

    /// The BSB, like the TCGNT, does not print verses the critical text omits; it gives them in footnotes.
    @Test func editionCountsAndAbsentVerses() {
        #expect(Census(RealSources.bsb) == Census(books: 66, chapters: 1189, verses: 31086))
        #expect(Census(RealSources.wlc) == Census(books: 39, chapters: 929, verses: 23213))
        #expect(Census(RealSources.tcgnt) == Census(books: 27, chapters: 260, verses: 7954))
        #expect(RealSources.bsb.books.flatMap(\.absentVerses).map(\.description) == [
            "MAT 17:21", "MAT 18:11", "MAT 23:14", "MRK 7:16", "MRK 9:44", "MRK 9:46", "MRK 11:26", "MRK 15:28",
            "LUK 17:36", "LUK 23:17", "JHN 5:4", "ACT 8:37", "ACT 15:34", "ACT 24:7", "ACT 28:29", "ROM 16:24",
        ])
        #expect(RealSources.wlc.books.flatMap(\.absentVerses) == [])
        #expect(RealSources.tcgnt.books.flatMap(\.absentVerses).map(\.description) == ["LUK 17:36", "ACT 8:37", "ACT 15:34", "ACT 24:7"])
    }

    @Test(arguments: [("bsb", VersificationScheme.eng), ("wlc", .heb), ("tcgnt", .grc)])
    func everyVerseIsInTheSchemeAndEverySchemeVerseIsPrintedOrAbsent(_ id: String, _ scheme: VersificationScheme) throws {
        let edition = RealSources.edition(id)
        var printed: [VerseRef] = []
        for book in edition.books {
            for chapter in book.chapters {
                for verse in PlainText.verses(of: chapter.chapter) {
                    for number in verse.label.number...(verse.label.through ?? verse.label.number) {
                        printed.append(VerseRef(book.book, chapter.chapter.number, number))
                    }
                }
            }
        }
        let absent = edition.books.flatMap(\.absentVerses)
        #expect(Set(printed).count == printed.count)
        #expect(Set(printed).isDisjoint(with: absent))
        #expect((printed + absent).sorted() == (try Versification.counts(for: scheme)).verseRefs)
    }

    @Test(arguments: ["bsb", "wlc", "tcgnt"])
    func everyChapterKeepsTheStreamRulesAndEveryVerseHasText(_ id: String) {
        var problems: [String] = []
        for book in RealSources.edition(id).books {
            for chapter in book.chapters {
                problems += streamViolations(chapter)
                for verse in PlainText.verses(of: chapter.chapter) where verse.text.isEmpty {
                    problems.append("\(book.book.rawValue) \(chapter.chapter.number):\(verse.label.number) is empty")
                }
            }
        }
        #expect(problems == [])
    }

    @Test func bsbNotesAreKeptAndTargetsParsed() {
        let notes = RealSources.bsb.books.flatMap(\.chapters).flatMap(\.notes)
        #expect(notes.count > 4000)
        #expect(notes.filter { $0.kind == .crossReference }.count > 1000)
        #expect(notes.reduce(0) { $0 + $1.targets.count } > 3000)
        #expect(notes.allSatisfy { !$0.text.isEmpty })
    }

    @Test func wlcWordPositionsRunOneToNInEveryVerse() {
        var problems: [String] = []
        for book in RealSources.wlc.books {
            for chapter in book.chapters {
                var runWords: [Int: [Int: String]] = [:]
                var verse = 0
                for item in chapter.chapter.items {
                    if case .verse(let label) = item { verse = label.number }
                    if case .text(let run) = item, let word = run.word { runWords[verse, default: [:]][word, default: ""] += run.text }
                }
                let tagged = Dictionary(uniqueKeysWithValues: chapter.words.map { ($0.ref.verse, $0.words) })
                for label in PlainText.verses(of: chapter.chapter).map(\.label.number) {
                    let words = tagged[label] ?? []
                    let place = "\(book.book.rawValue) \(chapter.chapter.number):\(label)"
                    if words.isEmpty { problems.append("\(place) has no words") }
                    if words.map(\.index) != Array(stride(from: 1, through: words.count, by: 1)) { problems.append("\(place) word tags are not 1...n") }
                    if runWords[label]?.keys.sorted() != words.map(\.index) { problems.append("\(place) run words disagree with its tags") }
                    if words.contains(where: { runWords[label]?[$0.index] != $0.surface }) { problems.append("\(place) a surface disagrees with its runs") }
                }
            }
        }
        #expect(problems == [])
        let words = RealSources.wlc.books.flatMap(\.chapters).flatMap(\.words).flatMap(\.words)
        // The WLC has 299,878 `<w>` elements, 82 of them with morphology and no Strong's number, and 11 escaped words.
        #expect(words.filter { $0.strong != nil || $0.morph != nil }.count == 299_878 + 11)
        #expect(words.filter { $0.strong != nil }.count == 299_878 - 82 + 11)
    }

    @Test func plainTextOfKnownVerses() {
        #expect(plainText(RealSources.bsb, .genesis, 1, 1) == "In the beginning God created the heavens and the earth.")
        #expect(plainText(RealSources.wlc, .genesis, 1, 1) == "בְּרֵאשִׁ֖ית בָּרָ֣א אֱלֹהִ֑ים אֵ֥ת הַשָּׁמַ֖יִם וְאֵ֥ת הָאָֽרֶץ׃")
        #expect(plainText(RealSources.tcgnt, .john, 1, 1)?.hasPrefix("Ἐν ἀρχῇ ἦν ὁ λόγος") == true)
        #expect(plainText(RealSources.wlc, .deuteronomy, 6, 4) == "שְׁמַ֖ע יִשְׂרָאֵ֑ל יְהוָ֥ה אֱלֹהֵ֖ינוּ יְהוָ֥ה ׀ אֶחָֽד׃")
    }

    /// Matthew 3:15's words of Jesus open before its verse marker; the style crosses it and the plain text does not care.
    @Test func wordsOfJesusAcrossAVerseMarkerLeavePlainTextPerVerse() throws {
        let matthew3 = try #require(RealSources.bsb.books.first { $0.book == .matthew }?.chapters.first { $0.chapter.number == 3 })
        #expect(plainText(RealSources.bsb, .matthew, 3, 14) == "But John tried to prevent Him, saying, “I need to be baptized by You, and do You come to me?”")
        #expect(plainText(RealSources.bsb, .matthew, 3, 15) == "“Let it be so now,” Jesus replied. “It is fitting for us to fulfill all righteousness in this way.” Then John permitted Him.")
        let fifteen = try #require(matthew3.chapter.items.firstIndex(of: .verse(VerseLabel(15))))
        #expect(matthew3.chapter.items[fifteen + 1] == .text(Run("“Let it be so now,”", style: .wordsOfJesus)))
    }
}
