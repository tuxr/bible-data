@testable import BibleFormat
import Foundation
import Testing

@Suite struct MappingTests {
    private func mapping(_ source: VersificationScheme, _ target: VersificationScheme) throws -> VersificationMapping {
        try #require(try Versification.mapping(from: source, to: target))
    }

    private func counterparts(_ mapped: MappedVerse?) -> [VerseRef] {
        switch mapped {
        case .same(let ref): [ref]
        case .mapped(let refs, _): refs
        case .absent, .bookAbsent, nil: []
        }
    }

    @Test(arguments: [(VersificationScheme.heb, VersificationScheme.eng), (.grc, .eng)])
    func everyEntryNamesRealVerses(source: VersificationScheme, target: VersificationScheme) throws {
        let mapping = try mapping(source, target)
        let sourceCounts = try Versification.counts(for: source)
        let targetCounts = try Versification.counts(for: target)
        #expect(!mapping.entries.isEmpty)
        for entry in mapping.entries {
            switch entry {
            case .pair(let from, let to, _):
                #expect(sourceCounts.contains(from), "\(from)")
                #expect(targetCounts.contains(to), "\(to)")
            case .sourceOnly(let ref, _):
                #expect(sourceCounts.contains(ref), "\(ref)")
            case .targetOnly(let ref, _):
                #expect(targetCounts.contains(ref), "\(ref)")
            }
        }
    }

    @Test(arguments: [
        (VersificationScheme.heb, VersificationScheme.eng),
        (.eng, .heb),
        (.grc, .eng),
        (.eng, .grc),
    ])
    func everyVerseLandsOnRealVersesOrIsExplainedAbsent(
        source: VersificationScheme,
        target: VersificationScheme
    ) throws {
        let mapping = try mapping(source, target)
        let targetCounts = try Versification.counts(for: target)
        for ref in try Versification.counts(for: source).verseRefs {
            switch try #require(mapping.map(ref)) {
            case .same(let same): #expect(targetCounts.contains(same), "\(ref) maps to itself, which \(target) lacks")
            case .mapped(let refs, _): #expect(!refs.isEmpty && refs.allSatisfy(targetCounts.contains), "\(ref)")
            case .absent, .bookAbsent: break
            }
        }
    }

    @Test(arguments: [
        (VersificationScheme.heb, VersificationScheme.eng),
        (.eng, .heb),
        (.grc, .eng),
        (.eng, .grc),
    ])
    func everyVerseRoundTrips(source: VersificationScheme, target: VersificationScheme) throws {
        let there = try mapping(source, target)
        let back = there.reversed()
        for ref in try Versification.counts(for: source).verseRefs {
            for counterpart in counterparts(there.map(ref)) {
                #expect(counterparts(back.map(counterpart)).contains(ref), "\(ref) -> \(counterpart) does not lead back")
            }
        }
    }

    @Test(arguments: [(VersificationScheme.heb, VersificationScheme.eng), (.grc, .eng)])
    func eachTargetVerseIsReachedOnceUnlessSplit(source: VersificationScheme, target: VersificationScheme) throws {
        let mapping = try mapping(source, target)
        let reverse = mapping.reversed()
        var sources: [VerseRef: [VerseRef]] = [:]
        for ref in try Versification.counts(for: source).verseRefs {
            for counterpart in counterparts(mapping.map(ref)) {
                sources[counterpart, default: []].append(ref)
            }
        }
        for ref in try Versification.counts(for: target).verseRefs {
            let reached = sources[ref, default: []]
            switch reverse.map(ref) {
            case .bookAbsent:
                continue
            case .absent:
                #expect(reached.isEmpty, "\(ref) is marked absent but \(reached) reach it")
            case .mapped(let pieces, .splitVerse):
                #expect(reached.sorted() == pieces, "\(ref) is split into \(pieces) but reached by \(reached)")
            default:
                #expect(reached.count == 1, "\(ref) is reached by \(reached)")
            }
        }
    }

    @Test func hebrewAndEnglishTotalsDifferOnlyWhereTheMappingSaysSo() throws {
        let expected: [Book: Int] = [
            .numbers: 1, .firstSamuel: 1, .firstKings: 1, .firstChronicles: 1, .nehemiah: -1, .psalms: 66, .isaiah: -1,
        ]
        let heb = try Versification.counts(for: .heb)
        let eng = try Versification.counts(for: .eng)
        let hebToEng = try mapping(.heb, .eng)
        let engToHeb = hebToEng.reversed()

        func unmatched(_ mapped: MappedVerse?) -> Bool {
            switch mapped {
            case .absent, .mapped(_, .splitVerse): true
            default: false
            }
        }
        var net: [Book: Int] = [:]
        for ref in heb.verseRefs where unmatched(hebToEng.map(ref)) {
            net[ref.book, default: 0] += 1
        }
        for ref in eng.verseRefs where unmatched(engToHeb.map(ref)) {
            net[ref.book, default: 0] -= 1
        }
        #expect(net.filter { $0.value != 0 } == expected)

        func total(_ counts: VerseCounts, _ book: Book) -> Int {
            (1...(counts.chapters(in: book) ?? 0)).reduce(0) { $0 + (counts.verses(in: book, chapter: $1) ?? 0) }
        }
        for book in heb.books {
            #expect(total(heb, book) - total(eng, book) == expected[book, default: 0], "\(book)")
        }
    }

    @Test(arguments: [
        (VerseRef(.exodus, 8, 1), MappedVerse.mapped([VerseRef(.exodus, 8, 5)], .renumbered)),
        (VerseRef(.exodus, 7, 26), .mapped([VerseRef(.exodus, 8, 1)], .renumbered)),
        (VerseRef(.psalms, 3, 1), .absent(.superscriptionAsVerse1)),
        (VerseRef(.psalms, 3, 2), .mapped([VerseRef(.psalms, 3, 1)], .renumbered)),
        (VerseRef(.psalms, 51, 1), .absent(.superscriptionAsVerse1)),
        (VerseRef(.psalms, 51, 2), .absent(.superscriptionAsVerse1)),
        (VerseRef(.psalms, 51, 3), .mapped([VerseRef(.psalms, 51, 1)], .renumbered)),
        (VerseRef(.psalms, 13, 6), .mapped([VerseRef(.psalms, 13, 5), VerseRef(.psalms, 13, 6)], .splitVerse)),
        (VerseRef(.genesis, 32, 1), .mapped([VerseRef(.genesis, 31, 55)], .renumbered)),
        (VerseRef(.genesis, 32, 33), .mapped([VerseRef(.genesis, 32, 32)], .renumbered)),
        (VerseRef(.numbers, 17, 14), .mapped([VerseRef(.numbers, 16, 49)], .renumbered)),
        (VerseRef(.numbers, 25, 19), .mapped([VerseRef(.numbers, 26, 1)], .splitVerse)),
        (VerseRef(.firstSamuel, 20, 42), .mapped([VerseRef(.firstSamuel, 20, 42)], .splitVerse)),
        (VerseRef(.firstSamuel, 21, 1), .mapped([VerseRef(.firstSamuel, 20, 42)], .splitVerse)),
        (VerseRef(.isaiah, 63, 19), .mapped([VerseRef(.isaiah, 63, 19), VerseRef(.isaiah, 64, 1)], .splitVerse)),
        (VerseRef(.nehemiah, 7, 68), .mapped([VerseRef(.nehemiah, 7, 69)], .renumbered)),
        (VerseRef(.joel, 3, 1), .mapped([VerseRef(.joel, 2, 28)], .renumbered)),
        (VerseRef(.malachi, 3, 19), .mapped([VerseRef(.malachi, 4, 1)], .renumbered)),
        (VerseRef(.job, 40, 25), .mapped([VerseRef(.job, 41, 1)], .renumbered)),
        (VerseRef(.daniel, 3, 31), .mapped([VerseRef(.daniel, 4, 1)], .renumbered)),
        (VerseRef(.genesis, 1, 1), .same(VerseRef(.genesis, 1, 1))),
        (VerseRef(.isaiah, 53, 5), .same(VerseRef(.isaiah, 53, 5))),
        (VerseRef(.psalms, 1, 1), .same(VerseRef(.psalms, 1, 1))),
        (VerseRef(.psalms, 23, 1), .same(VerseRef(.psalms, 23, 1))),
    ])
    func hebrewToEnglish(ref: VerseRef, expected: MappedVerse) throws {
        #expect(try mapping(.heb, .eng).map(ref) == expected)
    }

    @Test(arguments: [
        (VerseRef(.genesis, 31, 55), MappedVerse.mapped([VerseRef(.genesis, 32, 1)], .renumbered)),
        (VerseRef(.psalms, 3, 1), .mapped([VerseRef(.psalms, 3, 2)], .renumbered)),
        (VerseRef(.firstSamuel, 20, 42), .mapped([VerseRef(.firstSamuel, 20, 42), VerseRef(.firstSamuel, 21, 1)], .splitVerse)),
        (VerseRef(.isaiah, 64, 1), .mapped([VerseRef(.isaiah, 63, 19)], .splitVerse)),
        (VerseRef(.nehemiah, 7, 68), .absent(.extraVerse)),
        (VerseRef(.nehemiah, 7, 69), .mapped([VerseRef(.nehemiah, 7, 68)], .renumbered)),
        (VerseRef(.genesis, 1, 1), .same(VerseRef(.genesis, 1, 1))),
        (VerseRef(.matthew, 1, 1), .bookAbsent),
    ])
    func englishToHebrew(ref: VerseRef, expected: MappedVerse) throws {
        #expect(try mapping(.eng, .heb).map(ref) == expected)
    }

    @Test func greekRelocatesTheRomansDoxology() throws {
        let grcToEng = try mapping(.grc, .eng)
        let engToGrc = try mapping(.eng, .grc)
        #expect(grcToEng.map(VerseRef(.romans, 14, 24)) == .mapped([VerseRef(.romans, 16, 25)], .relocated))
        #expect(engToGrc.map(VerseRef(.romans, 16, 25)) == .mapped([VerseRef(.romans, 14, 24)], .relocated))
        #expect(engToGrc.map(VerseRef(.romans, 16, 27)) == .mapped([VerseRef(.romans, 14, 26)], .relocated))
    }

    @Test func oneEnglishVerseSplitsIntoTwoGreekVerses() throws {
        let engToGrc = try mapping(.eng, .grc)
        let grcToEng = try mapping(.grc, .eng)
        #expect(
            engToGrc.map(VerseRef(.thirdJohn, 1, 14))
                == .mapped([VerseRef(.thirdJohn, 1, 14), VerseRef(.thirdJohn, 1, 15)], .splitVerse)
        )
        #expect(grcToEng.map(VerseRef(.thirdJohn, 1, 15)) == .mapped([VerseRef(.thirdJohn, 1, 14)], .splitVerse))
    }

    @Test func englishOldTestamentHasNoGreekCounterpart() throws {
        #expect(try mapping(.eng, .grc).map(VerseRef(.genesis, 1, 1)) == .bookAbsent)
    }

    @Test func refsOutsideTheSourceSchemeDoNotMap() throws {
        #expect(try mapping(.heb, .eng).map(VerseRef(.malachi, 4, 1)) == nil)
        #expect(try mapping(.heb, .eng).map(VerseRef(.matthew, 1, 1)) == nil)
    }

    @Test func reversingTwiceRestoresTheMapping() throws {
        let hebToEng = try mapping(.heb, .eng)
        let roundTrip = hebToEng.reversed().reversed()
        #expect(roundTrip.source == .heb && roundTrip.target == .eng)
        #expect(roundTrip.entries == hebToEng.entries)
        #expect(roundTrip.map(VerseRef(.joel, 3, 1)) == hebToEng.map(VerseRef(.joel, 3, 1)))
    }

    @Test func aSchemeMapsToItselfUnchanged() throws {
        let engToEng = try mapping(.eng, .eng)
        #expect(engToEng.map(VerseRef(.genesis, 31, 55)) == .same(VerseRef(.genesis, 31, 55)))
    }

    @Test func schemesWithNoFileHaveNoMapping() throws {
        #expect(try Versification.mapping(from: .heb, to: .grc) == nil)
        #expect(try Versification.mapping(from: .grc, to: .heb) == nil)
    }

    @Test(arguments: [
        #"{"book": "PSA", "kind": "chapterBoundarySplit", "source": [3, 2], "target": [3, 1]}"#,
        #"{"book": "PSA", "kind": "renumbered", "source": [3, 2]}"#,
        #"{"book": "PSA", "kind": "superscriptionAsVerse1", "source": [3, 1], "target": [3, 1]}"#,
        #"{"book": "PSA", "kind": "renumbered", "source": [3, 1], "target": [3, 1]}"#,
        #"{"book": "PSA", "kind": "renumbered", "source": [3, 8], "target": [3, 9]}"#,
        #"{"book": "PSA", "kind": "extraVerse", "source": [3, 1]}, {"book": "PSA", "kind": "extraVerse", "source": [3, 1]}"#,
        #"{"book": "PSA", "kind": "renumbered", "source": [3, 2], "target": [3, 1]}, {"book": "PSA", "kind": "superscriptionAsVerse1", "source": [3, 2]}"#,
        #"{"book": "PSA", "kind": "splitVerse", "source": [3, 2], "target": [3, 1]}, {"book": "PSA", "kind": "relocated", "source": [3, 2], "target": [3, 2]}"#,
    ])
    func malformedFilesAreRejected(entries: String) throws {
        let file = Data(#"{"source": "heb", "target": "eng", "entries": [\#(entries)]}"#.utf8)
        let heb = try Versification.counts(for: .heb)
        let eng = try Versification.counts(for: .eng)
        #expect(throws: VersificationError.self) { try VersificationMapping(decoding: file, from: heb, to: eng) }
    }
}
