import BibleFormat
import Foundation
import Testing
@testable import bible_pack

private func id(_ text: String) -> StrongID { StrongID(text)! }

@Suite struct TAHOTReaderTests {
    @Test func readsPiecesStemAndGlossesButNoMorph() throws {
        let row = "Gen.1.2#01=L\tוְ/הָ/אָ֗רֶץ\tve./ha./'A.retz\tand/ the/ earth\tH9002/H9009/{H0776G}\tHC/Td/Ncfsa\t\t\tH0776G"
        let word = try #require(TAHOTWord.word(Substring(row)))
        #expect(word.reference.ref == VerseRef(.genesis, 1, 2))
        #expect(word.reference.parenthesized == nil)
        #expect(word.inLeningrad)
        #expect(word.reading.pieces.map(\.text) == ["וְ", "הָ", "אָ֗רֶץ"])
        #expect(word.reading.pieces.map(\.strong) == [id("H9002"), id("H9009"), id("H0776")])
        #expect(word.reading.pieces.map(\.gloss) == ["and", "the", "earth"])
        #expect(word.reading.main == 2)
        #expect(word.reading.gloss == "and the earth")
        #expect(word.ketiv == nil)
    }

    @Test func takesTheHebrewVerseFromParentheses() throws {
        let row = "Gen.31.55(32.1)#01=L\tוַ/יַּשְׁכֵּ֨ם\tva/i.yash.Kem\tand/ he rose early\tH9001/{H7925}\tHc/Vhw3ms"
        let word = try #require(TAHOTWord.word(Substring(row)))
        #expect(word.reference.ref == VerseRef(.genesis, 31, 55))
        #expect(word.reference.parenthesized == VerseRef(.genesis, 32, 1))
        #expect(HebrewWords.groupByHebrewVerse([word]).keys.first == VerseRef(.genesis, 32, 1))
    }

    @Test func readsTheKetivOfAQereRowWithoutItsPunctuation() throws {
        let row = "Gen.9.21#07=Q(K)\tאָהֳלֽ/וֹ\\׃\t'o.ho.L/o\ttent/ his\t{H0168G}/H9023\\H9016\tHNcmsc/Sp3ms\t"
            + "K= 'o.ho.Lo/h (אָהֳלֹ/ה\\׃) \"tent/ his\" (H0168G/H9023\\H9016=HNcbsc/Sp3ms)\tL= אָהֳלֹֽ/ה\\׃ ¦ ;"
        let word = try #require(TAHOTWord.word(Substring(row)))
        #expect(word.reading.text == "אָהֳלֽוֹ")
        let ketiv = try #require(word.ketiv)
        #expect(ketiv.pieces.map(\.text) == ["אָהֳלֹ", "ה"])
        #expect(ketiv.pieces.map(\.strong) == [id("H0168"), id("H9023")])
        #expect(ketiv.gloss == "tent his")
    }

    @Test func anXRowIsNotInTheLeningradCodex() throws {
        let row = "Gen.4.8#0501=X\tנֵלְכָה\tne.le.Khah\tlet us go\t{H1980G}\tHVqi1cp"
        #expect(try #require(TAHOTWord.word(Substring(row))).inLeningrad == false)
        #expect(HebrewWords.groupByHebrewVerse([TAHOTWord.word(Substring(row))!]).isEmpty)
    }

    @Test func skipsHeaderLines() {
        #expect(TAHOTWord.words(in: "TAHOT Gen-Deu - Translators\n\tData created by www.STEPBible.org\n").isEmpty)
    }
}

@Suite struct TAGNTReaderTests {
    @Test func readsAWordWithoutItsParsing() throws {
        let row = "Luk.9.31#02=NKO\tὀφθέντες (ophthentes)\thaving appeared\tG3700H=V-APP-NPM\tὁράω=to see\tNA28+NA27+Tyn+SBL+WH+Treg+TR+Byz"
        let word = try #require(TAGNTWord.word(Substring(row)))
        #expect(word.reference.ref == VerseRef(.luke, 9, 31))
        #expect(word.greek == "ὀφθέντες")
        #expect(word.gloss == "having appeared")
        #expect(word.strongs == [id("G3700")])
        #expect(word.lemmas == ["ὁράω"])
    }

    @Test func readsEveryIdOfACompound() throws {
        let row = "Rom.8.37#05=NKO\tὑπερνικῶμεν (hupernikōmen)\twe more than conquer\tG5228=PREP + G3029=ADV\tὑπέρ=above + λίαν=very\tNA28+Byz"
        let word = try #require(TAGNTWord.word(Substring(row)))
        #expect(word.strongs == [id("G5228"), id("G3029")])
        #expect(word.lemmas == ["ὑπέρ", "λίαν"])
    }

    @Test func readsTheFirstReferenceOfABracketedOne() throws {
        let row = "Act.2.11[2.10]#01=NKO\tἸουδαῖοί (Ioudaioi)\tJews\tG2453=N-NPM-PG\tἸουδαῖος=Jewish\tNA28"
        #expect(try #require(TAGNTWord.word(Substring(row))).reference.ref == VerseRef(.acts, 2, 11))
    }

    @Test func glossesLoseAngleBracketsAndCopiedPunctuation() {
        #expect(WordText.cleanGloss("<the>") == "the")
        #expect(WordText.cleanGloss("Word,") == "Word")
        #expect(WordText.cleanGloss(" ") == nil)
    }
}

@Suite struct ByztxtReaderTests {
    @Test func readsWordsWithEveryAnalysis() {
        let csv = "chapter,verse,text\n4,15,γη 1093 {N-NSF} 1093 {N-VSF} ζαβουλων 2194 {N-PRI}\n"
        let words = ByztxtWord.words(in: csv)
        #expect(words.map(\.form) == ["γη", "ζαβουλων"])
        #expect(words[0].analyses == [.init(strong: id("G1093"), morph: "N-NSF"), .init(strong: id("G1093"), morph: "N-VSF")])
        #expect(words[1].chapter == 4)
        #expect(words[1].verse == 15)
        #expect(words[1].analyses == [.init(strong: id("G2194"), morph: "N-PRI")])
    }

    @Test func namesItsBooksByFile() {
        #expect(ByztxtWord.books["JOH"] == .john)
        #expect(ByztxtWord.books["JAM"] == .james)
        #expect(ByztxtWord.books.count == 27)
    }
}

@Suite struct STEPLexiconReaderTests {
    @Test func tbesgLeavesOutMiddleLiddellEntries() {
        let text = [
            "G3056\tG3056 =\tG3056\tλόγος\tlogos\tG:N-M\tword\t <b>λόγος</b>, -ου, ὁ (AS)",
            "G3708\tG3708G = a Meaning of\tG1492H\tὁράω\thoraō\tG:V\tto see: see\t <b>ὁράω</b> (AS)",
            "G3708\tG3708H = a Meaning of\tG1492H\tὁράω\thoraō\tG:V\tto see: appear\t (AS)",
            "G0566\tG0566 =\tG0566\tἀπέχω\tapechō\tG:V\tto receive\t to receive in full (ML)",
            "G0566\tG0566G =\tG0566\tἀπέχω\tapechō\tG:V\tto be distant\t (AS)",
        ].joined(separator: "\n")
        let read = TBESGEntry.entries(in: text)
        #expect(read.entries[id("G3056")] == TBESGEntry(strong: id("G3056"), lemma: "λόγος", transliteration: "logos", partOfSpeech: "G:N-M", gloss: "word"))
        #expect(read.entries[id("G3708")]?.gloss == "to see")
        #expect(read.entries[id("G0566")] == nil)
        #expect(read.middleLiddell == [id("G0566")])
    }

    @Test func tbeshKeysAtStrongsLevelAndNeverShipsItsMeaning() {
        let text = [
            "H0430\tH0430G = a Name of\tH0430G\tאֱלֹהִים\te.lo.him\tH:N-M\tGod\tMEANING-SHOULD-NOT-SHIP",
            "H0430\tH0430H = a Part of\tH0430H\tאֱלֹהִים\te.lo.him\tH:N-M\t(LORD)-Elohe\tsecond row",
            "H1254a\tH1254A =\tH1254A\tבָּרָא\tba.ra\tH:V\tto create\tcreate",
            "H1254b\tH1254B =\tH1254B\tבָּרָא\tba.ra\tH:V\tto fatten\tfat",
        ].joined(separator: "\n")
        let entries = TBESHEntry.entries(in: text)
        #expect(entries[id("H0430")] == TBESHEntry(strong: id("H0430"), lemma: "אֱלֹהִים", transliteration: "e.lo.him", partOfSpeech: "H:N-M", gloss: "God"))
        #expect(entries[id("H1254")]?.gloss == "to create")
        #expect(!"\(entries)".contains("MEANING"))
    }
}

@Suite struct StrongsXMLReaderTests {
    private func greek(_ entries: String) throws -> [StrongID: StrongsEntry] {
        try StrongsGreek.entries(in: Data("<strongsdictionary><entries>\(entries)</entries></strongsdictionary>".utf8))
    }

    @Test func readsAGreekEntryAndRendersReferencesAsLemmas() throws {
        let entries = try greek("""
            <entry strongs="03004"><strongs>3004</strongs> <greek BETA="LE/GW" unicode="λέγω" translit="légō"/> <pronunciation strongs="leg'-o"/>
            <strongs_def> to say</strongs_def></entry>
            <entry strongs="03056"><strongs>3056</strongs> <greek BETA="LO/GOS" unicode="λόγος" translit="lógos"/> <pronunciation strongs="log'-os"/>
            <strongs_derivation>from <strongsref language="GREEK" strongs="3004"/>;</strongs_derivation><strongs_def> something said
             (including the thought)</strongs_def><kjv_def>:--account, word.</kjv_def></entry>
            """)
        let logos = try #require(entries[id("G3056")])
        #expect(logos.lemma == "λόγος")
        #expect(logos.transliteration == "lógos")
        #expect(logos.pronunciation == "log'-os")
        #expect(logos.definition == "something said (including the thought)")
    }

    /// The three shapes bible-api's cleanup was written for.
    @Test(arguments: [
        ("of uncertain affinity; a deity, especially (with ὁ) the supreme Divinity;", " figuratively, a magistrate; by Hebraism, very",
         "a deity, especially (with ὁ) the supreme Divinity; figuratively, a magistrate; by Hebraism, very"),
        ("from ἀνήρ and ὤψ (the countenance;", " from ὀπτάνομαι); man-faced, i.e. a human being", "man-faced, i.e. a human being"),
        ("a primary pronoun of the first person I (only expressed when emphatic)", "",
         "a primary pronoun of the first person I (only expressed when emphatic)"),
    ])
    func splitsDerivationFromDefinition(_ derivation: String, _ definition: String, _ expected: String) {
        #expect(StrongsDefinition.greek(derivation: derivation, definition: definition) == expected)
    }

    @Test func readsAHebrewEntryWithoutItsTWOTNumber() throws {
        let xml = """
            <osis><div type="entry" n="430">
            <w gloss="93c" lemma="אֱלֹהִים" morph="n-m" POS="el-o-heem'" xlit="ʼĕlôhîym" ID="H430" xml:lang="heb">אלהים</w>
            <list><item>1) (plural)</item></list>
            <note type="exegesis">plural of <w lemma="אֱלוֹהַּ" POS="el-o'-ah" src="433" xlit="ʼĕlôwahh"/>;</note>
            <note type="explanation"><hi>gods</hi> in the ordinary sense</note>
            <note type="translation">angels, God.</note>
            </div></osis>
            """
        let entry = try #require(try StrongsHebrew.entries(in: Data(xml.utf8))[id("H0430")])
        #expect(entry == StrongsEntry(strong: id("H0430"), lemma: "אֱלֹהִים", transliteration: "ʼĕlôhîym", pronunciation: "el-o-heem'",
                                      definition: "gods in the ordinary sense"))
        #expect(!"\(entry)".contains("93c"))
    }

    @Test func completesAHebrewClauseTheExegesisOpened() {
        #expect(StrongsDefinition.hebrew(exegesis: "from הָוָה (in the sense of eagerly coveting and rushing upon; by implication, of falling",
                                         explanation: "); desire; also ruin") == "desire; also ruin")
        #expect(StrongsDefinition.hebrew(exegesis: "", explanation: "{properly, to wander away}") == "properly, to wander away")
    }
}

@Suite struct AlignmentTests {
    private func keys(_ words: [String], _ script: Script) -> [WordKey] { words.map { WordKey(WordText.key($0, script: script)) } }

    @Test func greekScoresFollowBibleAPI() {
        func score(_ a: String, _ b: String) -> Int { GreekMatch.score(WordKey(WordText.key(a, script: .greek)), WordKey(WordText.key(b, script: .greek))) }
        #expect(score("λόγος,", "λογος") == GreekMatch.exact)
        #expect(score("ἔμελλε", "ἔμελλεν") == GreekMatch.movable)
        #expect(score("Δαυίδ", "Δαβίδ") == GreekMatch.fuzzy)
        #expect(score("καὶ", "ὁ") == 0)
    }

    @Test func alignsAroundAMissingWord() {
        let pairs = Alignment.align(keys(["ἐν", "ἀρχῇ", "ἦν", "λόγος"], .greek), keys(["εν", "αρχη", "ην", "ο", "λογος"], .greek), score: GreekMatch.score)
        #expect(pairs.map { $0?.index } == [0, 1, 2, 4])
    }

    @Test func aLongInsertionStaysInsideTheBand() {
        let a = (0..<400).map { WordKey("w\($0)") }
        let b = Array(a[..<100]) + (0..<300).map { WordKey("x\($0)") } + Array(a[100...])
        let pairs = Alignment.align(a, b) { $0 == $1 ? 4 : 0 }
        #expect(pairs.map { $0?.index } == Array(0..<100) + Array(400..<700))
    }

    @Test func splitsAHebrewWordByLetterCountsKeepingItsPoints() {
        #expect(HebrewWords.split("וְהָאָ֗רֶץ", letterCounts: [1, 1, 3]) == ["וְ", "הָ", "אָ֗רֶץ"])
        #expect(HebrewWords.split("וְהָאָ֗רֶץ", letterCounts: [1, 1]) == nil)
    }

    @Test func splitsAnOSHBCodeIntoPieces() {
        #expect(HebrewWords.pieces(of: "HC/Td/Ncfsa", count: 3) == ["HC", "HTd", "HNcfsa"])
        #expect(HebrewWords.pieces(of: "HVqw3ms", count: 2) == nil)
    }
}
