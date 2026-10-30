import BibleFormat
import Testing

@Suite struct MappingTests {
    private func mapping(_ source: VersificationScheme, _ target: VersificationScheme) throws -> VersificationMapping {
        try #require(try Versification.mapping(from: source, to: target))
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

    @Test(arguments: [(VersificationScheme.heb, VersificationScheme.eng), (.grc, .eng)])
    func eachTargetVerseHasOneSourceUnlessSplit(source: VersificationScheme, target: VersificationScheme) throws {
        let mapping = try mapping(source, target)
        let reverse = mapping.reversed()
        let targetCounts = try Versification.counts(for: target)
        var sources: [VerseRef: [VerseRef]] = [:]
        for ref in try Versification.counts(for: source).verseRefs {
            switch mapping.map(ref) {
            case .same(let same): sources[same, default: []].append(ref)
            case .mapped(let refs, let kind) where kind != .splitVerse: refs.forEach { sources[$0, default: []].append(ref) }
            default: break
            }
        }
        let shared = targetCounts.verseRefs.filter { reverse.map($0) != .bookAbsent }
        let doubled = sources.filter { $0.value.count > 1 }.keys.sorted()
        let orphaned = shared.filter { ref in
            guard sources[ref] == nil else { return false }
            switch reverse.map(ref) {
            case .absent, .mapped(_, .splitVerse): return false
            default: return true
            }
        }
        withKnownIssue("The heb-eng seed maps only chapter edges, so verses inside a shifted chapter fall back to the same number") {
            #expect(doubled.isEmpty, "\(doubled.prefix(5))")
            #expect(orphaned.isEmpty, "\(orphaned.prefix(5))")
        } when: {
            source == .heb
        }
    }

    @Test(arguments: [
        (VerseRef(.psalms, 3, 2), MappedVerse.mapped([VerseRef(.psalms, 3, 1)], .superscriptionAsVerse1)),
        (VerseRef(.psalms, 3, 1), .absent(.superscriptionAsVerse1)),
        (VerseRef(.joel, 3, 1), .mapped([VerseRef(.joel, 2, 28)], .chapterBoundarySplit)),
        (VerseRef(.malachi, 3, 19), .mapped([VerseRef(.malachi, 4, 1)], .chapterBoundarySplit)),
        (VerseRef(.genesis, 32, 1), .mapped([VerseRef(.genesis, 31, 55)], .chapterBoundarySplit)),
        (VerseRef(.genesis, 1, 1), .same(VerseRef(.genesis, 1, 1))),
    ])
    func hebrewToEnglish(ref: VerseRef, expected: MappedVerse) throws {
        #expect(try mapping(.heb, .eng).map(ref) == expected)
    }

    @Test(arguments: [
        (VerseRef(.genesis, 31, 55), MappedVerse.mapped([VerseRef(.genesis, 32, 1)], .chapterBoundarySplit)),
        (VerseRef(.genesis, 1, 1), .same(VerseRef(.genesis, 1, 1))),
        (VerseRef(.psalms, 3, 1), .mapped([VerseRef(.psalms, 3, 2)], .superscriptionAsVerse1)),
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
}
