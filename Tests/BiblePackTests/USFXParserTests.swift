import BibleFormat
import Foundation
import Testing
@testable import bible_pack

private let wj = RunStyle.wordsOfJesus
private let flush = ChapterItem.block(.flush)

private func only(_ body: String) -> ParsedBook {
    let parsed = parseUSFX(body)
    #expect(parsed.warnings.isEmpty)
    return parsed.books[0]
}

@Suite struct USFXParserTests {
    @Test func aHeadingDoesNotJoinThePreviousVerse() {
        let luke = only(#"<book id="LUK"><c id="9"/><p><v id="27"/>τοῦ Θεοῦ.<ve/></p><s style="s">The Transfiguration"# + "\n" + #"</s><p><v id="28"/>Ἐγένετο δὲ</p></book>"#)
        let luke9 = chapter(luke, 9)
        #expect(luke9.chapter.items == [
            paragraph, verse(27), run("τοῦ Θεοῦ."),
            .heading(level: .two, [Run("The Transfiguration")]),
            paragraph, verse(28), run("Ἐγένετο δὲ"),
        ])
        #expect(plain(luke9) == ["τοῦ Θεοῦ.", "Ἐγένετο δὲ"])
    }

    @Test func aHeadingInTheMiddleOfAVerseKeepsItsFootnoteAsANoteAtThatVerse() {
        let mark = only(#"<book id="MRK"><c id="6"/><v id="6"/>καὶ ἐθαύμαζε. <s style="s">Jesus Sends<f>note</f> Out</s>Καὶ περιῆγε.</book>"#)
        let mark6 = chapter(mark, 6)
        #expect(mark6.chapter.items == [
            paragraph, verse(6), run("καὶ ἐθαύμαζε."),
            .heading(level: .two, [Run("Jesus Sends Out")]), caller(1),
            paragraph, run("Καὶ περιῆγε."),
        ])
        #expect(mark6.notes == [ParsedNote(verse: 6, number: 1, kind: .footnote, caller: "a", text: "note", targets: [])])
        #expect(plain(mark6) == ["καὶ ἐθαύμαζε. Καὶ περιῆγε."])
    }

    @Test func wordsOfJesusBeforeAHeadingStayInTheirVerse() {
        let mark = only(#"<book id="MRK"><c id="9"/><v id="1"/><wj>ἐν δυνάμει.</wj><s style="s">The Transfiguration</s></book>"#)
        #expect(chapter(mark, 9).chapter.items == [
            paragraph, verse(1), run("ἐν δυνάμει.", wj), .heading(level: .two, [Run("The Transfiguration")]),
        ])
    }

    @Test func wordsOfJesusAreARunStyle() {
        let john = only(#"<book id="JHN"><c id="3"/><v id="16"/><wj>For God so loved</wj> the world.</book>"#)
        let john3 = chapter(john, 3)
        #expect(john3.chapter.items == [paragraph, verse(16), run("For God so loved", wj), run(" the world.")])
        #expect(plain(john3) == ["For God so loved the world."])
    }

    @Test func wordsOfJesusContinueAcrossAFootnoteAndParagraphBreaks() {
        let john = only(#"<book id="JHN"><c id="1"/><v id="1"/><wj>Hello<f>note</f><p/>world</wj><q/> after.</book>"#)
        let john1 = chapter(john, 1)
        #expect(john1.chapter.items == [
            paragraph, verse(1), run("Hello", wj), caller(1), paragraph, run("world", wj), q1, run("after."),
        ])
        #expect(plain(john1) == ["Hello world after."])
    }

    @Test func aVerseWithNoMarkupHasNoStyles() {
        let genesis = only(#"<book id="GEN"><c id="1"/><v id="1"/>In the beginning.</book>"#)
        #expect(chapter(genesis, 1).chapter.items == [paragraph, verse(1), run("In the beginning.")])
    }

    @Test func anEmptyVerseAtABookBoundaryStaysEmptyAndTheNextBooksHeaderIsNotText() {
        let parsed = parseUSFX(#"<book id="MAT"><c id="1"/><v id="1"/></book><book id="1CO">46-1CO-web.sfm World English Bible</book>"#)
        #expect(parsed.books.map(\.book) == [.matthew])
        #expect(chapter(parsed.books[0], 1).chapter.items == [paragraph, verse(1)])
        #expect(plain(chapter(parsed.books[0], 1)) == [""])
        #expect(parsed.warnings == ["1CO: the book has no chapters, skipped"])
    }

    @Test func aPsalmTitleComesBeforeTheVerseItsLinesBelongTo() {
        let psalms = only(
            #"<book id="PSA"><c id="23"/><d style="d">A Psalm by David."# + "\n"
                + #"</d><q style="q1"><v id="1"/>The LORD is my shepherd;"# + "\n"
                + #"</q><q level="2" style="q2">I shall lack nothing."# + "\n" + #"<ve/></q></book>"#
        )
        let psalm = chapter(psalms, 23)
        #expect(psalm.chapter.items == [
            .title([Run("A Psalm by David.")]),
            q1, verse(1), run("The LORD is my shepherd;"),
            q2, run("I shall lack nothing."),
        ])
        #expect(plain(psalm) == ["The LORD is my shepherd; I shall lack nothing."])
    }

    @Test func aParagraphCanOpenInTheMiddleOfAVerse() {
        let genesis = only(
            #"<book id="GEN"><c id="1"/><p style="p"><v id="1"/>In the beginning. <v id="2"/>The earth was formless."# + "\n"
                + #"</p><p style="p">God said, “Let there be light.”</p></book>"#
        )
        let genesis1 = chapter(genesis, 1)
        #expect(genesis1.chapter.items == [
            paragraph, verse(1), run("In the beginning. "), verse(2), run("The earth was formless."),
            paragraph, run("God said, “Let there be light.”"),
        ])
        #expect(plain(genesis1) == ["In the beginning.", "The earth was formless. God said, “Let there be light.”"])
    }

    @Test func headingsFallBetweenVersesOrWithinOne() {
        let mark = only(
            #"<book id="MRK"><c id="6"/><p style="p"><v id="5"/>He could do no mighty work.</p>"#
                + #"<s style="s">Jesus Sends<f>note</f> Out the Twelve</s><p style="m"><v id="6"/>He marveled. "#
                + #"<s style="s">The Mission</s>He went around.</p></book>"#
        )
        let mark6 = chapter(mark, 6)
        #expect(mark6.chapter.items == [
            paragraph, verse(5), run("He could do no mighty work."),
            .heading(level: .two, [Run("Jesus Sends Out the Twelve")]), caller(1),
            flush, verse(6), run("He marveled."),
            .heading(level: .two, [Run("The Mission")]),
            flush, run("He went around."),
        ])
        #expect(mark6.notes.map(\.verse) == [5])
        #expect(plain(mark6) == ["He could do no mighty work.", "He marveled. He went around."])
    }

    @Test func blankLinesAndMajorSections() {
        let psalms = only(#"<book id="PSA"><c id="42"/><p sfm="ms" style="ms1">BOOK 2"# + "\n" + #"</p><b style="b"/><q style="q1"><v id="1"/>As the deer pants.</q></book>"#)
        #expect(chapter(psalms, 42).chapter.items == [
            .heading(level: .one, [Run("BOOK 2")]), blank, q1, verse(1), run("As the deer pants."),
        ])
    }

    @Test func psalm119LettersAreTitlesAndSongOfSongsSpeakersAreSpeakers() {
        let psalms = only(
            #"<book id="PSA"><c id="119"/><q style="q1"><v id="8"/>Don’t utterly forsake me."# + "\n"
                + #"</q><d style="d">BETH"# + "\n<ve/>\n" + #"</d><q style="q1"><v id="9"/>How can a young man keep his way pure?</q></book>"#
        )
        let psalm = chapter(psalms, 119)
        #expect(psalm.chapter.items == [
            q1, verse(8), run("Don’t utterly forsake me."),
            .title([Run("BETH")]),
            q1, verse(9), run("How can a young man keep his way pure?"),
        ])
        #expect(plain(psalm) == ["Don’t utterly forsake me.", "How can a young man keep his way pure?"])

        let song = only(
            #"<book id="SNG"><c id="1"/><q style="q1"><v id="4"/>The king has brought me into his rooms."# + "\n"
                + #"</q><p sfm="sp" style="sp">Friends"# + "\n" + #"</p><q style="q1">We will be glad.</q></book>"#
        )
        let song1 = chapter(song, 1)
        #expect(song1.chapter.items == [
            q1, verse(4), run("The king has brought me into his rooms."),
            .speaker([Run("Friends")]),
            q1, run("We will be glad."),
        ])
        #expect(plain(song1) == ["The king has brought me into his rooms. We will be glad."])
    }

    @Test func aRedLetterPoetryVerseSplitsByLineAndKeepsItsStyle() {
        let matthew = only(
            #"<book id="MAT"><c id="5"/><q style="q1"><v id="3"/><wj>“Blessed are the poor in spirit,"# + "\n"
                + #"</wj></q><q level="2" style="q2"><wj>for theirs is the Kingdom of Heaven.</wj></q></book>"#
        )
        let matthew5 = chapter(matthew, 5)
        #expect(matthew5.chapter.items == [
            q1, verse(3), run("“Blessed are the poor in spirit,", wj),
            q2, run("for theirs is the Kingdom of Heaven.", wj),
        ])
        #expect(plain(matthew5) == ["“Blessed are the poor in spirit, for theirs is the Kingdom of Heaven."])
    }

    @Test func aHeadingAfterTheLastVerseIsKeptAndIsNotVerseText() {
        let romans = only(#"<book id="ROM"><c id="16"/><p><v id="27"/>Amen.</p><s style="s">Written to the Romans.</s></book>"#)
        let romans16 = chapter(romans, 16)
        #expect(romans16.chapter.items == [
            paragraph, verse(27), run("Amen."), .heading(level: .two, [Run("Written to the Romans.")]),
        ])
        #expect(plain(romans16) == ["Amen."])
    }

    @Test func tcgntWordsOfJesusKeepTheirStyleAcrossAFootnote() {
        let john = only(
            #"<book id="JHN"><c id="8"/><p sfm="m" style="m"><v id="10"/><wj><w s="G4226">Ποῦ</w> <w s="G1510">εἰσιν</w>"# + "\n"
                + #"<f caller="+"><fr>8:10"# + "\n" + #"</fr><ft>εκεινοι ¦ — ᴡʜ"# + "\n"
                + #"</ft></f><w s="G1565">ἐκεῖνοι</w>;</wj>"# + "\n<ve />\n</p></book>"
        )
        let john8 = chapter(john, 8)
        #expect(john8.chapter.items == [
            flush, verse(10),
            run("Ποῦ", wj, word: 1), run(" ", wj), run("εἰσιν", wj, word: 2), run(" ", wj),
            caller(1),
            run("ἐκεῖνοι", wj, word: 3), run(";", wj),
        ])
        #expect(john8.notes == [ParsedNote(verse: 10, number: 1, kind: .footnote, caller: "a", text: "εκεινοι ¦ — ᴡʜ", targets: [])])
        #expect(john8.words == [VerseWords(ref: VerseRef(.john, 8, 10), words: [
            WordTag(index: 1, surface: "Ποῦ", strong: "G4226"),
            WordTag(index: 2, surface: "εἰσιν", strong: "G1510"),
            WordTag(index: 3, surface: "ἐκεῖνοι", strong: "G1565"),
        ])])
        #expect(plain(john8) == ["Ποῦ εἰσιν ἐκεῖνοι;"])
    }

    @Test func hebrewPunctuationStaysInThePlainTextAndOnlyWordsGetPositions() {
        let genesis = only(
            #"<book id="GEN"><c id="1"/><p style="p"><v id="5" bcv="GEN.1.5"/>"# + "\n"
                + #"<w s="H0430">אֱלֹהִ֤ים</w> ׀"# + "\n"
                + #"<w s="H1961">וַֽיְהִי</w>־<w s="H6153">עֶ֥רֶב</w>"# + "\n"
                + #"<w s="H0259">אֶחָֽד</w>׃ פ"# + "\n<ve />\n"
                + #"<v id="6" bcv="GEN.1.6"/>"# + "\n"
                + #"<w s="H3190">יִיטַ֣ב</w> לְךָ֔"# + "\n</p></book>"
        )
        let genesis1 = chapter(genesis, 1)
        #expect(genesis1.chapter.items == [
            paragraph, verse(5),
            run("אֱלֹהִ֤ים", word: 1), run(" ׀ "), run("וַֽיְהִי", word: 2), run("־"), run("עֶ֥רֶב", word: 3), run(" "),
            run("אֶחָֽד", word: 4), run("׃ פ "),
            verse(6), run("יִיטַ֣ב", word: 1), run(" "), run("לְךָ֔", word: 2),
        ])
        #expect(plain(genesis1) == ["אֱלֹהִ֤ים ׀ וַֽיְהִי־עֶ֥רֶב אֶחָֽד׃ פ", "יִיטַ֣ב לְךָ֔"])
        #expect(genesis1.words == [
            VerseWords(ref: VerseRef(.genesis, 1, 5), words: [
                WordTag(index: 1, surface: "אֱלֹהִ֤ים", strong: "H0430"),
                WordTag(index: 2, surface: "וַֽיְהִי", strong: "H1961"),
                WordTag(index: 3, surface: "עֶ֥רֶב", strong: "H6153"),
                WordTag(index: 4, surface: "אֶחָֽד", strong: "H0259"),
            ]),
            VerseWords(ref: VerseRef(.genesis, 1, 6), words: [
                WordTag(index: 1, surface: "יִיטַ֣ב", strong: "H3190"),
                WordTag(index: 2, surface: "לְךָ֔"),
            ]),
        ])
    }

    @Test func wlcEscapedMarkupBecomesTaggedWordsAgain() {
        let raw = #"<book id="DEU"><c id="6"/><p style="p"><v id="4"/> 'l s="H8085"'שְׁמַ֖'seg type="x-large"'ע'seg''/l' <w s="H3478">יִשְׂרָאֵ֑ל</w> ׀ 'l s="H259"'אֶחָֽ'seg type="x-large"'ד'seg''/l'׃</p></book>"#
        #expect(WLCRepair.markup(raw) == #"<book id="DEU"><c id="6"/><p style="p"><v id="4"/> <w s="H8085">שְׁמַ֖ע</w> <w s="H3478">יִשְׂרָאֵ֑ל</w> ׀ <w s="H0259">אֶחָֽד</w>׃</p></book>"#)
        let deuteronomy = only(WLCRepair.markup(raw))
        let deuteronomy6 = chapter(deuteronomy, 6)
        #expect(plain(deuteronomy6) == ["שְׁמַ֖ע יִשְׂרָאֵ֑ל ׀ אֶחָֽד׃"])
        #expect(deuteronomy6.words.first?.words.map(\.strong) == ["H8085", "H3478", "H0259"])
        #expect(WLCRepair.markup("the LORD's house") == "the LORD's house")
    }

    @Test func noteTextFlattensFormattingAndKeepsQuotedVerseNumbers() {
        let luke = only(
            #"<book id="LUK"><c id="16"/><p><v id="5"/>ἕνα"#
                + #"<f caller="+"><fr>16:5"# + "\n" + #"</fr><ft>χρεοφιλετων"# + "\n" + #"<bd>ᴏ</bd><sup>5</sup> ᴡʜ"# + "\n" + #"</ft></f>"#
                + #" ἕκαστον<f caller="-"><fr>17:35</fr><ft>αφεθησεται</ft><fv>36</fv> δυο εσονται</f>"#
                + #" τῶν<x caller="*"><xo>16:5</xo><xt>Mt 18:24</xt></x></p></book>"#
        )
        #expect(chapter(luke, 16).notes == [
            ParsedNote(verse: 5, number: 1, kind: .footnote, caller: "a", text: "χρεοφιλετων ᴏ5 ᴡʜ", targets: []),
            ParsedNote(verse: 5, number: 2, kind: .footnote, caller: "", text: "αφεθησεται 36 δυο εσονται", targets: []),
            ParsedNote(verse: 5, number: 3, kind: .crossReference, caller: "*", text: "Mt 18:24", targets: []),
        ])
    }

    @Test func tcgntStrayNotePartAroundAFootnoteIsRemoved() {
        let raw = #"<book id="JHN"><c id="8"/><p><v id="10"/><wj>Ποῦ</wj>"# + "\n"
            + #"<ft><f caller="+"><fr>8:10"# + "\n" + #"</fr><ft>note"# + "\n" + #"</ft></f></ft><wj>ἐκεῖνοι</wj></p></book>"#
        #expect(parseUSFX(raw).warnings == ["JHN 8:10: <ft> outside a note"])
        let repaired = parseUSFX(TCGNTRepair.markup(raw))
        #expect(repaired.warnings.isEmpty)
        #expect(chapter(repaired.books[0], 8).notes.map(\.text) == ["note"])
        #expect(plain(chapter(repaired.books[0], 8)) == ["Ποῦ ἐκεῖνοι"])
    }

    @Test func peripheralBooksAreSkippedQuietlyAndUnknownBooksWithAWarning() {
        let parsed = parseUSFX(#"<book id="FRT"><p>front</p></book><book id="XYZ"><c id="1"/></book><book id="GEN"><c id="1"/><v id="1"/>In.</book>"#)
        #expect(parsed.books.map(\.book) == [.genesis])
        #expect(parsed.warnings == ["XYZ: unknown book id, skipped"])
    }

    @Test func figuresAreDropped() {
        let john = only(
            #"<book id="JHN"><c id="13"/><p><v id="35"/>ἀλλήλοις.<fig><description /><catalog>04 John 13_34.png</catalog>"#
                + #"<caption>Ἐντολὴν καινὴν</caption><reference>13:34</reference></fig> <ve /></p></book>"#
        )
        #expect(plain(chapter(john, 13)) == ["ἀλλήλοις."])
    }

    @Test func bookNamesAndTitlesBeforeTheFirstChapter() {
        let matthew = only(
            #"<book id="MAT"><id id="MAT">- The Text-Critical Greek New Testament"# + "\n"
                + #"</id><h>ΚΑΤΑ ΜΑΤΘΑΙΟΝ"# + "\n" + #"</h><toc level="2">ΚΑΤΑ ΜΑΤΘΑΙΟΝ</toc><toc level="3">Μτ"# + "\n"
                + #"</toc><p sfm="mt" style="mt1">ΜΑΤΘΑΙΟΝ</p><c id="1"/><p><v id="1"/>Βίβλος.</p></book>"#
        )
        #expect(matthew.name == "ΚΑΤΑ ΜΑΤΘΑΙΟΝ")
        #expect(matthew.shortName == "Μτ")
        #expect(plain(chapter(matthew, 1)) == ["Βίβλος."])
        let genesis = only(#"<book id="GEN"><h>בראשית</h><c id="1"/><p><v id="1"/>x</p></book>"#)
        #expect(genesis.shortName == "Gen")
    }
}
