import ArgumentParser
import BibleFormat
import Foundation
import Testing
@testable import bible_pack

private let pinnedTime = "2026-10-30T00:00:00Z"

/// Words and lexicon packages built once per test run through the commands, from the real sources.
private enum BuiltWords {
    static let directory: URL = {
        let url = RealSources.repository.appending(path: ".build/words-tests", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: url)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let sourceArguments = [
        "--lock", RealSources.repository.appending(path: "sources.lock.json").path,
        "--sources-dir", RealSources.repository.appending(path: ".sources").path,
    ]

    static let wlc = words("wlc", out: "a")
    static let tcgnt = words("tcgnt", out: "a")
    static let tcgntAgain = words("tcgnt", out: "b")
    static let greek = lexicon("greek", from: tcgnt, out: "a")
    static let greekAgain = lexicon("greek", from: tcgntAgain, out: "b")
    static let hebrew = lexicon("hebrew", from: wlc, out: "a")

    static func words(_ edition: String, out: String) -> URL {
        let directory = directory.appending(path: out, directoryHint: .isDirectory)
        run(BuildWords.self, [edition, "--out", directory.path, "--built-at", pinnedTime, "--version", "2026.10",
                              "--editions-dir", RealSources.repository.appending(path: "editions").path])
        return directory.appending(path: "\(edition)-2026.10.words")
    }

    static func lexicon(_ language: String, from words: URL, out: String) -> URL {
        let directory = directory.appending(path: out, directoryHint: .isDirectory)
        run(BuildLexicon.self, [language, "--out", directory.path, "--built-at", pinnedTime, "--version", "2026.10", "--count-from", words.path])
        return directory.appending(path: "lexicon-\(language)-2026.10.lexicon")
    }

    private static func run(_ command: any ParsableCommand.Type, _ arguments: [String]) {
        do {
            var parsed = try command.parseAsRoot(arguments + sourceArguments)
            try parsed.run()
        } catch {
            preconditionFailure("\(command) \(arguments.joined(separator: " ")) failed: \(error)")
        }
    }
}

private func loadEdition(_ id: String) throws -> EditionInput {
    try EditionInput.load(id, editionsDirectory: RealSources.repository.appending(path: "editions"), lock: RealSources.lock!, cache: RealSources.cache)
}

private func validateWords(_ url: URL, lexicon: URL?, againstSource: Bool = true) throws -> [CompanionCheck] {
    var passed: [CompanionCheck] = []
    let source: ((String) throws -> EditionInput)? = againstSource ? { try loadEdition($0) } : nil
    try CompanionValidator.validateWords(at: url, lexicon: lexicon, source: source) { check, _ in passed.append(check) }
    return passed
}

private func rows(_ url: URL, _ sql: String) throws -> [[SQLiteValue]] {
    try SQLiteDatabase(path: url.path, mode: .readOnly).rows(sql)
}

private func word(_ url: URL, _ ref: VerseRef, _ position: Int) throws -> [SQLiteValue] {
    try #require(try rows(url, "SELECT surface, strong, morph, gloss, parts FROM words WHERE verse_id = \(PackageSchema.verseRowID(ref)) AND position = \(position)").first)
}

@Suite(.enabled(if: RealSources.present, RealSources.skipMessage))
struct WordsBuildTests {
    @Test(arguments: ["wlc", "tcgnt"])
    func everyWordsCheckPassesAgainstTheSourceAndTheLexicon(_ edition: String) throws {
        let (words, lexicon) = edition == "wlc" ? (BuiltWords.wlc, BuiltWords.hebrew) : (BuiltWords.tcgnt, BuiltWords.greek)
        #expect(try validateWords(words, lexicon: lexicon) == CompanionCheck.wordsChecks(for: TaggedEdition(rawValue: edition)!))
        var passed: [CompanionCheck] = []
        try CompanionValidator.validateLexicon(at: lexicon, words: words) { check, _ in passed.append(check) }
        #expect(passed == CompanionCheck.lexiconChecks)
    }

    @Test func buildsAreByteIdenticalForOnePinnedTime() throws {
        for (first, second) in [(BuiltWords.tcgnt, BuiltWords.tcgntAgain), (BuiltWords.greek, BuiltWords.greekAgain)] {
            #expect(try Data(contentsOf: first) == Data(contentsOf: second))
            #expect(try Data(contentsOf: PackageWriter.compressedURL(for: first)) == Data(contentsOf: PackageWriter.compressedURL(for: second)))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: BuiltWords.tcgnt.deletingLastPathComponent().path).sorted()
        #expect(!names.contains { $0.hasSuffix(".partial") })
    }

    @Test func wlcGenesis1v1Word1() throws {
        let row = try word(BuiltWords.wlc, VerseRef(.genesis, 1, 1), 1)
        #expect(row[0] == .text("בְּרֵאשִׁ֖ית"))
        #expect(row[1] == .text("H7225"))
        #expect(row[2] == .text("HR/Ncfsa"))
        #expect(row[3].text?.contains("beginning") == true)
        let parts = try #require(row[4].text.flatMap(WordParts.decode))
        #expect(parts == [WordPart(strong: "H9003", morph: "HR", gloss: "in", surface: "בְּ"),
                          WordPart(strong: "H7225", morph: "HNcfsa", gloss: "beginning", surface: "רֵאשִׁ֖ית")])
    }

    @Test func wlcGenesis1v1Word2() throws {
        let row = try word(BuiltWords.wlc, VerseRef(.genesis, 1, 1), 2)
        #expect(row[0] == .text("בָּרָ֣א"))
        #expect(row[1] == .text("H1254"))
        #expect(row[2] == .text("HVqp3ms"))
        #expect(row[4] == .null)
    }

    /// The WLC prints the Ketiv ולא, "and not", whose code differs from the Qere וְלוֹ's `HC/R/Sp3ms`.
    @Test func wlcMorphIsTheKetivsWhereTheTextPrintsIt() throws {
        let row = try word(BuiltWords.wlc, VerseRef(.psalms, 100, 3), 8)
        #expect(row[0] == .text("ולא"))
        #expect(row[1] == .text("H3808"))
        #expect(row[2] == .text("HC/Tn"))
        let parts = try #require(row[4].text.flatMap(WordParts.decode))
        #expect(parts.map(\.morph) == ["HC", "HTn"])
        #expect(parts.map(\.surface) == ["ו", "לא"])
    }

    /// OSHB tags this one WLC word as two, so each of its two stems carries its own id.
    @Test func aWordOSHBDividesKeepsBothStems() throws {
        let row = try word(BuiltWords.wlc, VerseRef(.firstChronicles, 15, 13), 2)
        #expect(row[0] == .text("לְמַבָּרִ֥אשׁוֹנָ֖ה"))
        #expect(row[2] == .text("HR/Ti/Rd/Aafsa"))
        let parts = try #require(row[4].text.flatMap(WordParts.decode))
        #expect(parts.map(\.strong) == ["H9005", "H4100", "H9003", "H7223"])
    }

    @Test func oshbGivesMorphToNearlyEveryWLCWord() throws {
        let counts = try rows(BuiltWords.wlc, "SELECT count(*), count(morph) FROM words")
        guard case .integer(let words) = counts.first?[0], case .integer(let tagged) = counts.first?[1] else {
            Issue.record("no counts")
            return
        }
        #expect(words == 305_495)
        #expect(Double(tagged) >= 0.99 * Double(words))
    }

    /// TAHOT's row is the Qere אָהֳלוֹ; the WLC prints the Ketiv אָהֳלֹה, which the row's `K=` note splits.
    @Test func wlcTakesTheKetivReadingTheTextPrints() throws {
        let row = try word(BuiltWords.wlc, VerseRef(.genesis, 9, 21), 7)
        #expect(row[0] == .text("אָהֳלֹֽה"))
        #expect(row[1] == .text("H0168"))
        let parts = try #require(row[4].text.flatMap(WordParts.decode))
        #expect(parts.map(\.surface) == ["אָהֳלֹֽ", "ה"])
        #expect(parts.map(\.strong) == ["H0168", "H9023"])
    }

    @Test(arguments: [
        (VerseRef(.john, 1, 1), 1, "Ἐν", "G1722", "PREP", "In [the]"),
        (VerseRef(.john, 1, 1), 2, "ἀρχῇ", "G0746", "N-DSF", "beginning"),
        (VerseRef(.john, 1, 1), 4, "ὁ", "G3588", "T-NSM", "the"),
        (VerseRef(.john, 1, 1), 12, "Θεόν", "G2316", "N-ASM", "God"),
        // The eBible tag is the article G3588; Byztxt's MAT.csv has `η 2228 {PRT}` and TAGNT `G2228=CONJ`, "than".
        (VerseRef(.matthew, 1, 18), 18, "ἢ", "G2228", "PRT", "than"),
    ])
    func tcgntWordsCarryByztxtMorphAndTAGNTGlosses(_ ref: VerseRef, _ position: Int, _ surface: String, _ strong: String, _ morph: String, _ gloss: String) throws {
        let row = try word(BuiltWords.tcgnt, ref, position)
        #expect(row[0] == .text(surface))
        #expect(row[1] == .text(strong))
        #expect(row[2] == .text(morph))
        #expect(row[3] == .text(gloss))
        #expect(row[4] == .null)
    }

    @Test func lexiconsHoldTheirEntries() throws {
        #expect(try rows(BuiltWords.greek, "SELECT lemma FROM entries WHERE strong = 'G3056'") == [[.text("λόγος")]])
        let elohim = try #require(try rows(BuiltWords.hebrew, "SELECT lemma, definition, gloss FROM entries WHERE strong = 'H0430'").first)
        #expect(elohim[0] == .text("אֱלֹהִים"))
        #expect(elohim[1].text?.isEmpty == false)
        #expect(elohim[2] == .text("God"))
        let used = try rows(BuiltWords.tcgnt, "SELECT count(*) FROM words WHERE strong = 'G3056'")
        #expect(try rows(BuiltWords.greek, "SELECT occurrences FROM entries WHERE strong = 'G3056'") == used)
    }

    /// TBESG's G0090 is a Middle Liddell entry (CC BY-SA), so its entry is Strong's alone.
    @Test func noMiddleLiddellFieldShips() throws {
        let entry = try #require(try rows(BuiltWords.greek, "SELECT lemma, gloss, part_of_speech, definition FROM entries WHERE strong = 'G0090'").first)
        #expect(entry[0] == .text("ἀδιαφθορία"))
        #expect(entry[1] == .null)
        #expect(entry[2] == .null)
        #expect(entry[3].text?.isEmpty == false)
    }

    @Test func everyPackageCreditsItsSources() throws {
        func meta(_ url: URL, _ key: String) throws -> [String] {
            try rows(url, "SELECT value FROM meta WHERE key = '\(key)'").first?.first?.text.flatMap(MetaStrings.decode) ?? []
        }
        #expect(try meta(BuiltWords.wlc, "sources") == ["wlc", "oshb", "tahot", "tbesh", "strongs"])
        #expect(try meta(BuiltWords.wlc, "attribution").contains("Open Scriptures Hebrew Bible Project, github.com/openscriptures/morphhb (CC BY 4.0)"))
        #expect(try meta(BuiltWords.tcgnt, "sources") == ["tcgnt", "byztxt", "tagnt", "tbesg", "strongs"])
        #expect(try meta(BuiltWords.tcgnt, "attribution").contains(TBESGEntry.abbottSmithCredit))
        #expect(try meta(BuiltWords.greek, "attribution").contains(TBESGEntry.abbottSmithCredit))
        #expect(try meta(BuiltWords.hebrew, "attribution").contains(TBESHEntry.credit))
        #expect(try meta(BuiltWords.hebrew, "sources") == ["tbesh", "strongs"])
    }

    @Test func aGapInPositionsFailsThePositionsCheck() throws {
        let copy = BuiltWords.directory.appending(path: "tampered-\(UUID().uuidString).words")
        try FileManager.default.copyItem(at: BuiltWords.tcgnt, to: copy)
        try SQLiteDatabase(path: copy.path, mode: .readWrite).exec("DELETE FROM words WHERE verse_id = 43001001 AND position = 3")
        let error = #expect(throws: CompanionValidationError.self) { try validateWords(copy, lexicon: nil, againstSource: false) }
        #expect(error?.check == .positions)
    }

    @Test func aCodeOutsideTheOSHBGrammarFailsTheMorphCheck() throws {
        let copy = BuiltWords.directory.appending(path: "tampered-\(UUID().uuidString).words")
        try FileManager.default.copyItem(at: BuiltWords.wlc, to: copy)
        try SQLiteDatabase(path: copy.path, mode: .readWrite).exec("UPDATE words SET morph = 'HQq' WHERE verse_id = 1001001 AND position = 2")
        let error = #expect(throws: CompanionValidationError.self) { try validateWords(copy, lexicon: nil, againstSource: false) }
        #expect(error?.check == .morph)
    }

    @Test func validateDispatchesOnTheKind() throws {
        #expect(try CompanionValidator.kind(of: BuiltWords.wlc) == .words)
        #expect(try CompanionValidator.kind(of: BuiltWords.hebrew) == .lexicon)
    }
}
