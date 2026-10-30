import BibleFormat
import Testing

@Suite struct VerseCountTests {
    @Test(arguments: [
        (VersificationScheme.eng, 66, 1189, 31102),
        (.heb, 39, 929, 23213),
        (.grc, 27, 260, 7958),
    ])
    func totals(scheme: VersificationScheme, books: Int, chapters: Int, verses: Int) throws {
        let counts = try Versification.counts(for: scheme)
        #expect(counts.scheme == scheme)
        #expect(counts.books.count == books)
        #expect(counts.chapterCount == chapters)
        #expect(counts.verseCount == verses)
        #expect(counts.verseRefs.count == verses)
    }

    @Test func schemesDisagreeWhereTheTraditionsDo() throws {
        let eng = try Versification.counts(for: .eng)
        let heb = try Versification.counts(for: .heb)
        #expect(eng.verses(in: .psalms, chapter: 3) == 8)
        #expect(heb.verses(in: .psalms, chapter: 3) == 9)
        #expect(eng.chapters(in: .joel) == 3)
        #expect(heb.chapters(in: .joel) == 4)
        #expect(eng.chapters(in: .malachi) == 4)
        #expect(heb.chapters(in: .malachi) == 3)
    }

    @Test func containsOnlyRealVerses() throws {
        let eng = try Versification.counts(for: .eng)
        #expect(eng.contains(VerseRef(.genesis, 1, 1)))
        #expect(eng.contains(VerseRef(.genesis, 50, 26)))
        #expect(!eng.contains(VerseRef(.genesis, 50, 27)))
        #expect(!eng.contains(VerseRef(.genesis, 51, 1)))
        #expect(!eng.contains(VerseRef(.genesis, 1, 0)))
        #expect(!eng.contains(VerseRef(.tobit, 1, 1)))
        #expect(eng.chapters(in: .tobit) == nil)
        #expect(eng.verses(in: .genesis, chapter: 0) == nil)
    }

    @Test(arguments: VersificationScheme.allCases)
    func everyChapterAndVerseNumberIsBelowOneThousand(scheme: VersificationScheme) throws {
        let refs = try Versification.counts(for: scheme).verseRefs
        #expect(refs.allSatisfy { $0.chapter < 1000 && $0.verse < 1000 })
    }

    @Test(arguments: VersificationScheme.allCases)
    func verseRefsAreInCanonicalOrder(scheme: VersificationScheme) throws {
        let refs = try Versification.counts(for: scheme).verseRefs
        #expect(zip(refs, refs.dropFirst()).allSatisfy { $0 < $1 })
    }
}
