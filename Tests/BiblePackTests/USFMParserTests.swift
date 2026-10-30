import BibleFormat
import Foundation
import Testing
@testable import bible_pack

private let wj = RunStyle.wordsOfJesus

@Suite struct USFMParserTests {
    @Test func wordsOfJesusCrossAVerseMarkerWithinAParagraph() {
        let parsed = parseUSFM([
            "\\id JHN",
            "\\c 3",
            "\\p \\wj \\v 10 “You are Israel’s teacher,”\\wj* said Jesus, \\wj “and you do not understand? \\v 11 Truly, I tell you.”\\wj*",
        ], book: .john)
        let john3 = chapter(parsed.book, 3)
        #expect(john3.chapter.items == [
            paragraph,
            verse(10),
            run("“You are Israel’s teacher,”", wj),
            run(" said Jesus, "),
            run("“and you do not understand? ", wj),
            verse(11),
            run("Truly, I tell you.”", wj),
        ])
        #expect(plain(john3) == ["“You are Israel’s teacher,” said Jesus, “and you do not understand?", "Truly, I tell you.”"])
        #expect(parsed.warnings.isEmpty)
    }

    @Test func aParagraphEndsWordsOfJesus() {
        let parsed = parseUSFM(["\\id MAT", "\\c 1", "\\p \\v 1 He said, \\wj “Come.", "\\p \\v 2 And they came."], book: .matthew)
        #expect(chapter(parsed.book, 1).chapter.items == [
            paragraph, verse(1), run("He said, "), run("“Come.", wj),
            paragraph, verse(2), run("And they came."),
        ])
    }

    @Test func headingsTitlesParallelPassagesFootnotesAndSelahAreNotVerseText() {
        let parsed = parseUSFM([
            "\\id PSA",
            "\\c 3",
            "\\ms BOOK I",
            "\\s1 Deliver Me, O LORD!",
            "\\r (\\ref 2 Samuel 15:13–29|2SA 15:13-29\\ref*)",
            "\\d \\v 1 A Psalm of David, when he fled from his son Absalom.",
            "\\b ",
            "\\q1 O LORD, how my foes have increased!",
            "\\q2 How many rise up against me!",
            "\\q1 \\v 2 Many say of me,",
            "\\q2 “God will not deliver him.”",
            "\\qr Selah\\f + \\fr 3:2 \\fqa Selah \\ft or \\fqa Interlude\\f*",
            "\\qa ALEPH",
            "\\q1 \\v 3 But You, O LORD, are a shield around me.",
        ], book: .psalms)
        let psalm = chapter(parsed.book, 3)
        #expect(plain(psalm) == [
            "O LORD, how my foes have increased! How many rise up against me!",
            "Many say of me, “God will not deliver him.” Selah",
            "But You, O LORD, are a shield around me.",
        ])
        #expect(psalm.chapter.items == [
            .heading(level: .one, [Run("BOOK I")]),
            .heading(level: .two, [Run("Deliver Me, O LORD!")]),
            caller(1, .crossReference),
            .title([Run("A Psalm of David, when he fled from his son Absalom.")]),
            blank, q1, verse(1), run("O LORD, how my foes have increased!"),
            q2, run("How many rise up against me!"),
            q1, verse(2), run("Many say of me,"),
            q2, run("“God will not deliver him.”"),
            .block(.rightAligned), run("Selah"), caller(2),
            .title([Run("ALEPH")]),
            q1, verse(3), run("But You, O LORD, are a shield around me."),
        ])
        #expect(psalm.notes == [
            ParsedNote(
                verse: 0, number: 1, kind: .crossReference, caller: "a", text: "2 Samuel 15:13–29",
                targets: [VerseRange(VerseRef(.secondSamuel, 15, 13), through: VerseRef(.secondSamuel, 15, 29))]
            ),
            ParsedNote(verse: 2, number: 2, kind: .footnote, caller: "b", text: "Selah or Interlude", targets: []),
        ])
    }

    /// USFM 3 makes `\d` a title in any book. The BSB's one `\d` outside the Psalms is Zechariah 12:1's opening
    /// sentence, verse text in the BSB's own text, so the BSB repairs make it a paragraph.
    @Test func descriptiveTitleOutsideThePsalmsIsATitleExceptInTheBSB() {
        let zechariah = [
            "\\id ZEC", "\\c 12", "\\s1 The Coming Deliverance",
            "\\d \\v 1 This is the burden of the word of the LORD.", "\\p Thus declares the LORD.",
        ]
        let habakkuk = ["\\id HAB", "\\c 3", "\\q1 \\v 19 He makes me walk upon the heights!", "\\mr For the choirmaster."]

        let generic = parseUSFM(zechariah, book: .zechariah).book
        #expect(chapter(generic, 12).chapter.items == [
            .heading(level: .two, [Run("The Coming Deliverance")]),
            .title([Run("This is the burden of the word of the LORD.")]),
            paragraph, verse(1), run("Thus declares the LORD."),
        ])
        #expect(plain(chapter(parseUSFM(habakkuk, book: .habakkuk).book, 3)) == ["He makes me walk upon the heights!"])

        let bsb = parseBSB([("ZEC.usfm", zechariah), ("HAB.usfm", habakkuk)])
        #expect(bsb.books.map(\.book) == [.habakkuk, .zechariah])
        let habakkuk3 = chapter(bsb.books[0], 3)
        #expect(habakkuk3.chapter.items == [
            q1, verse(19), run("He makes me walk upon the heights!"),
            .block(.rightAligned), run("For the choirmaster."),
        ])
        #expect(plain(habakkuk3) == ["He makes me walk upon the heights! For the choirmaster."])
        let zechariah12 = chapter(bsb.books[1], 12)
        #expect(zechariah12.chapter.items == [
            .heading(level: .two, [Run("The Coming Deliverance")]),
            paragraph, verse(1), run("This is the burden of the word of the LORD."),
            paragraph, run("Thus declares the LORD."),
        ])
        #expect(plain(zechariah12) == ["This is the burden of the word of the LORD. Thus declares the LORD."])
        #expect(bsb.report.warnings.isEmpty)
    }

    @Test func bsbSelahLinesCarryTheSelahStyle() {
        let bsb = parseBSB([("PSA.usfm", [
            "\\id PSA", "\\c 9",
            "\\q1 \\v 16 The wicked are ensnared by the work of their hands.",
            "\\qr Higgaion Selah",
            "\\q1 \\v 17 The wicked return to Sheol.",
            "\\qr Selah\\f + \\fr 9:17 \\fqa Selah \\ft or \\fqa Interlude\\f*",
        ])])
        let psalm = chapter(bsb.books[0], 9)
        #expect(psalm.chapter.items == [
            q1, verse(16), run("The wicked are ensnared by the work of their hands."),
            .block(.rightAligned), run("Higgaion Selah", .selah),
            q1, verse(17), run("The wicked return to Sheol."),
            .block(.rightAligned), run("Selah", .selah), caller(1),
        ])
    }

    @Test func aFileWithNoBookIDIsSkippedWithAWarning() {
        let parsed = parseBSB([("X.usfm", ["\\c 1", "\\p \\v 1 Text."])])
        #expect(parsed.books.isEmpty)
        #expect(parsed.report.warnings == ["X.usfm: no \\id line, skipped"])
    }

    @Test func psalm23HasAHeadingAParallelPassageATitleLinesAndAStanzaBreak() {
        let parsed = parseBSB([("PSA.usfm", [
            "\\id PSA",
            "\\c 23",
            "\\s1 The LORD Is My Shepherd",
            "\\r (\\ref Ezekiel 34:11–24|EZK 34:11-24\\ref*)",
            "\\d \\v 1 A Psalm of David.",
            "\\q1 The LORD is my shepherd;\\f + \\fr 23:1 \\ft See \\ref Revelation 7:17|REV 7:17\\ref*.\\f*",
            "\\q2 I shall not want.",
            "\\b ",
            "\\q1 \\v 2 He makes me lie down in green pastures;",
        ])])
        let psalm = chapter(parsed.books[0], 23)
        #expect(psalm.chapter.items == [
            .heading(level: .two, [Run("The LORD Is My Shepherd")]),
            caller(1, .crossReference),
            .title([Run("A Psalm of David.")]),
            q1, verse(1), run("The LORD is my shepherd;"), caller(2),
            q2, run("I shall not want."),
            blank, q1, verse(2), run("He makes me lie down in green pastures;"),
        ])
        #expect(psalm.notes == [
            ParsedNote(
                verse: 0, number: 1, kind: .crossReference, caller: "a", text: "Ezekiel 34:11–24",
                targets: [VerseRange(VerseRef(.ezekiel, 34, 11), through: VerseRef(.ezekiel, 34, 24))]
            ),
            ParsedNote(
                verse: 1, number: 2, kind: .footnote, caller: "b", text: "See Revelation 7:17.",
                targets: [VerseRange(VerseRef(.revelation, 7, 17), through: VerseRef(.revelation, 7, 17))]
            ),
        ])
        #expect(plain(psalm) == ["The LORD is my shepherd; I shall not want.", "He makes me lie down in green pastures;"])
    }

    @Test func acrosticLettersAreTitlesSelahIsSetRightSubsectionsAreLevelThreeAndListsHaveLevels() {
        let parsed = parseUSFM([
            "\\id PSA", "\\c 119",
            "\\qa BETH",
            "\\q1 \\v 9 How can a young man keep his way pure?",
            "\\qr Selah",
            "\\s2 The Sons",
            "\\li1 \\v 10 Of the sons of Phinehas,",
            "\\li2 Gershom.",
            "\\nb and Daniel.",
        ], book: .psalms)
        let psalm = chapter(parsed.book, 119)
        #expect(psalm.chapter.items == [
            .title([Run("BETH")]),
            q1, verse(9), run("How can a young man keep his way pure?"),
            .block(.rightAligned), run("Selah"),
            .heading(level: .three, [Run("The Sons")]),
            .block(.list(level: .one)), verse(10), run("Of the sons of Phinehas,"),
            .block(.list(level: .two)), run("Gershom. and Daniel."),
        ])
        #expect(plain(psalm) == ["How can a young man keep his way pure? Selah", "Of the sons of Phinehas, Gershom. and Daniel."])
    }

    @Test func aHeadingWithinAVerseStaysWhereItFalls() {
        let parsed = parseUSFM([
            "\\id DEU", "\\c 7",
            "\\p \\v 11 So keep the commandments.",
            "\\s1 The Promises of God",
            "\\p Then the LORD will keep His covenant.",
        ], book: .deuteronomy)
        let deuteronomy7 = chapter(parsed.book, 7)
        #expect(deuteronomy7.chapter.items == [
            paragraph, verse(11), run("So keep the commandments."),
            .heading(level: .two, [Run("The Promises of God")]),
            paragraph, run("Then the LORD will keep His covenant."),
        ])
        #expect(plain(deuteronomy7) == ["So keep the commandments. Then the LORD will keep His covenant."])
    }

    @Test func aMidVerseHeadingKeepsItsFootnoteAtThatVerse() {
        let parsed = parseUSFM([
            "\\id MRK", "\\c 6",
            "\\p \\v 6 And He was amazed. ",
            "\\s1 Jesus Sends\\f + \\fr 6:7 \\ft A note.\\f* Out the Twelve",
            "\\p He went around.",
        ], book: .mark)
        let mark6 = chapter(parsed.book, 6)
        #expect(mark6.chapter.items == [
            paragraph, verse(6), run("And He was amazed."),
            .heading(level: .two, [Run("Jesus Sends Out the Twelve")]), caller(1),
            paragraph, run("He went around."),
        ])
        #expect(mark6.notes == [ParsedNote(verse: 6, number: 1, kind: .footnote, caller: "a", text: "A note.", targets: [])])
        #expect(plain(mark6) == ["And He was amazed. He went around."])
    }

    @Test func emDashAtALineEndJoinsTheNextLineWithNoSpace() {
        let parsed = parseBSB([("ISA.usfm", ["\\id ISA", "\\c 1", "\\q1 \\v 1 They have forsaken the LORD —", "\\q2 they have turned away."])])
        let isaiah1 = chapter(parsed.books[0], 1)
        #expect(isaiah1.chapter.items == [q1, verse(1), run("They have forsaken the LORD—"), q2, run("they have turned away.")])
        #expect(plain(isaiah1) == ["They have forsaken the LORD—they have turned away."])
    }

    @Test func bridgesKeepBothNumbersAndALetterSuffixContinuesTheVerse() {
        let parsed = parseUSFM([
            "\\id GEN", "\\c 1",
            "\\p \\v 1-2 In the beginning, the earth.",
            "\\p \\v 3a God said,",
            "\\q1 \\v 3b “Let there be light.”",
            "\\p \\v 4 And it was good.",
        ], book: .genesis)
        let genesis1 = chapter(parsed.book, 1)
        #expect(genesis1.chapter.items == [
            paragraph, verse(1, through: 2), run("In the beginning, the earth."),
            paragraph, verse(3), run("God said,"),
            q1, run("“Let there be light.”"),
            paragraph, verse(4), run("And it was good."),
        ])
        #expect(PlainText.verses(of: genesis1.chapter) == [
            PlainVerse(label: VerseLabel(1, through: 2), text: "In the beginning, the earth."),
            PlainVerse(label: VerseLabel(3), text: "God said, “Let there be light.”"),
            PlainVerse(label: VerseLabel(4), text: "And it was good."),
        ])
        #expect(parsed.warnings.isEmpty)
    }

    @Test func footnotesDropTheirReferenceKeepQuotedWordsAndRecordTargets() {
        let parsed = parseUSFM([
            "\\id RUT", "\\c 4",
            "\\p \\v 19 Hezron was the father of Ram,\\f + \\fr 4:19 \\ft Greek \\fqa Aram\\ft , a variant of \\fqa Ram\\ft ; also in verse 20; see \\ref 1 Chronicles 2:9–10|1CH 2:9-10\\ref*.\\f* and Ram was the father of Amminadab.",
            "\\p \\v 20 X.\\f + \\fr 4:20 \\ft BYZ and TR include \\fqa \\fv 21\\fv*But this kind\\ft ; see \\ref Jude 1:14|JUD 14\\ref*.\\f*",
        ], book: .ruth)
        let ruth4 = chapter(parsed.book, 4)
        #expect(ruth4.chapter.items == [
            paragraph, verse(19), run("Hezron was the father of Ram,"), caller(1), run(" and Ram was the father of Amminadab."),
            paragraph, verse(20), run("X."), caller(2),
        ])
        #expect(ruth4.notes == [
            ParsedNote(
                verse: 19, number: 1, kind: .footnote, caller: "a",
                text: "Greek Aram, a variant of Ram; also in verse 20; see 1 Chronicles 2:9–10.",
                targets: [VerseRange(VerseRef(.firstChronicles, 2, 9), through: VerseRef(.firstChronicles, 2, 10))]
            ),
            ParsedNote(
                verse: 20, number: 2, kind: .footnote, caller: "b", text: "BYZ and TR include 21 But this kind; see Jude 1:14.",
                targets: [VerseRange(VerseRef(.jude, 1, 14), through: VerseRef(.jude, 1, 14))]
            ),
        ])
    }

    @Test func referenceTargets() {
        func range(_ book: Book, _ c1: Int, _ v1: Int, _ c2: Int, _ v2: Int) -> TargetReference.Outcome {
            .range(VerseRange(VerseRef(book, c1, v1), through: VerseRef(book, c2, v2)))
        }
        #expect(TargetReference.parse("1CH 2:9-10") == range(.firstChronicles, 2, 9, 2, 10))
        #expect(TargetReference.parse("PSA 23:1") == range(.psalms, 23, 1, 23, 1))
        #expect(TargetReference.parse("LUK 3:23-4:2") == range(.luke, 3, 23, 4, 2))
        #expect(TargetReference.parse("3JN 1-4") == range(.thirdJohn, 1, 1, 1, 4))
        #expect(TargetReference.parse("JUD 18") == range(.jude, 1, 18, 1, 18))
        #expect(TargetReference.parse("MAT.3.15") == range(.matthew, 3, 15, 3, 15))
        #expect(TargetReference.parse("1:9") == .outsideCanon)
        #expect(TargetReference.parse("13:1-11") == .outsideCanon)
        #expect(TargetReference.parse("GEN 4") == .unreadable)
        #expect(TargetReference.parse("GEN 9:9-1") == .unreadable)
        #expect(TargetReference.parse("XYZ 1:1") == .unreadable)
        #expect(TargetReference.parse("GEN 1:0") == .unreadable)
    }

    @Test func anUnreadableTargetIsDroppedWithAWarningAndABooklessOneSilently() {
        let parsed = parseUSFM([
            "\\id JUD", "\\c 1",
            "\\p \\v 14 Enoch prophesied.\\f + \\fr 1:14 \\ft See \\ref 1 Enoch 1:9|1:9\\ref* and \\ref Genesis 9|GEN 9:9-1\\ref*.\\f*",
        ], book: .jude)
        #expect(chapter(parsed.book, 1).notes == [
            ParsedNote(verse: 14, number: 1, kind: .footnote, caller: "a", text: "See 1 Enoch 1:9 and Genesis 9.", targets: []),
        ])
        #expect(parsed.warnings == ["JUD 1:14: unreadable reference target GEN 9:9-1"])
    }

    @Test func characterStylesNestAndMapToRunStyles() {
        let parsed = parseUSFM([
            "\\id MRK", "\\c 5",
            "\\p \\v 41 \\add supplied\\add* \\nd Lord\\nd* \\tl Talitha\\tl* \\qt quoted\\qt* \\qs Selah\\qs* \\wj Jesus \\+nd Lord\\+nd*\\wj*",
        ], book: .mark)
        #expect(chapter(parsed.book, 5).chapter.items == [
            paragraph, verse(41),
            run("supplied", .addedWords), run(" "), run("Lord", .divineName), run(" "), run("Talitha", .transliteration),
            run(" "), run("quoted", .quotedScripture), run(" "), run("Selah", .selah), run(" "),
            run("Jesus ", wj), run("Lord", [wj, .divineName]),
        ])
        #expect(parsed.warnings.isEmpty)
    }

    @Test func anUnknownMarkerWarnsAndKeepsItsText() {
        let parsed = parseUSFM(["\\id GEN", "\\c 1", "\\p \\v 1 Some \\zzz odd\\zzz* text."], book: .genesis)
        #expect(plain(chapter(parsed.book, 1)) == ["Some odd text."])
        #expect(parsed.warnings == ["GEN 1:1: unknown marker \\zzz", "GEN 1:1: unknown marker \\zzz*"])
    }

    @Test func taggedWordsGetPositionsAndTags() {
        let parsed = parseUSFM([
            "\\id GEN", "\\c 1",
            "\\p \\v 1 \\w In|strong=\"H7225\" x-morph=\"HR\"\\w* \\w beginning|strong=\"H1254\"\\w*.",
        ], book: .genesis)
        let genesis1 = chapter(parsed.book, 1)
        #expect(genesis1.chapter.items == [
            paragraph, verse(1), run("In", word: 1), run(" "), run("beginning", word: 2), run("."),
        ])
        #expect(genesis1.words == [VerseWords(ref: VerseRef(.genesis, 1, 1), words: [
            WordTag(index: 1, surface: "In", strong: "H7225", morph: "HR"),
            WordTag(index: 2, surface: "beginning", strong: "H1254"),
        ])])
    }

    @Test func bookNamesComeFromTheHeaderAndAnAbbreviationThatIsOnlyTheIDFallsBack() {
        let psalms = parseUSFM(["\\id PSA", "\\h Psalm", "\\toc2 Psalms", "\\toc3 PSA", "\\c 1", "\\p \\v 1 Blessed."], book: .psalms)
        #expect(psalms.book.name == "Psalm")
        #expect(psalms.book.shortName == "Ps")
        let john = parseUSFM(["\\id JHN", "\\toc2 John", "\\toc3 Jhn", "\\c 1", "\\p \\v 1 In."], book: .john)
        #expect(john.book.name == "John")
        #expect(john.book.shortName == "John")
        let matthew = parseUSFM(["\\id MAT", "\\h ΚΑΤΑ ΜΑΤΘΑΙΟΝ", "\\toc3 Μτ", "\\c 1", "\\p \\v 1 Βίβλος."], book: .matthew)
        #expect(matthew.book.name == "ΚΑΤΑ ΜΑΤΘΑΙΟΝ")
        #expect(matthew.book.shortName == "Μτ")
    }

    @Test func theStreamCheckerReportsBrokenRules() {
        let broken = ParsedChapter(chapter: Chapter(book: .genesis, number: 1, items: [
            verse(1), run("outside"), paragraph, run(" leading"), run(" twin"), caller(2),
        ]), notes: [], words: [])
        #expect(streamViolations(broken) == [
            "GEN 1 item 0: verse 1 outside a block",
            "GEN 1 item 1: text outside a block",
            "GEN 1 item 3: a block starts with a space",
            "GEN 1 item 4: two runs that should be one",
            "GEN 1 item 5: caller 2 has no note",
            "GEN 1: note callers are not 1...0 in order",
        ])
    }

    @Test func aDuplicateVerseWarns() {
        let parsed = parseUSFM(["\\id GEN", "\\c 1", "\\p \\v 1 One. \\v 2 Two. \\v 1 Again."], book: .genesis)
        #expect(parsed.warnings == ["GEN 1:2: verse 1 starts a second time"])
    }
}

/// bible-api's `bsbUsfmCleanup` cases, now `BSBRepair`.
@Suite struct BSBRepairTests {
    @Test(arguments: [
        ("morning — the first day", "morning—the first day"),
        ("one to help him.[’’]", "one to help him."),
        ("the 1,775 shekels [of silver] he made", "the 1,775 shekels of silver he made"),
        ("she named vvv him Ben-oni.", "she named him Ben-oni."),
        ("their registration numbered... 40,500.", "their registration numbered 40,500."),
        ("(for he had removed it... ) and jumped", "(for he had removed it) and jumped"),
        ("the brothers ( a gathering of about a hundred and twenty ) and said,", "the brothers (a gathering of about a hundred and twenty) and said,"),
        ("of whom we can inquire? ”", "of whom we can inquire?”"),
        ("saying, ‘ I never saw you.’", "saying, ‘I never saw you.’"),
        ("She named him Samuel,saying, “Because", "She named him Samuel, saying, “Because"),
        ("in Hebrew,‘Saul, Saul", "in Hebrew, ‘Saul, Saul"),
        ("“evenif you, Coniah", "“even if you, Coniah"),
    ])
    func repairs(artifact: String, repaired: String) {
        #expect(BSBRepair.repair(artifact) == repaired)
    }

    @Test(arguments: ["forgive their sin.... But if not,", "to forgive sins...” Then He said", "the 1,775 shekels", "3:16"])
    func leavesThePublishersOwnEllipsesAndNumbersAlone(text: String) {
        #expect(BSBRepair.repair(text) == text)
    }

    @Test func repairsAVerseWithoutLosingItsWordsOfJesus() {
        let parsed = parseBSB([("JHN.usfm", [
            "\\id JHN", "\\c 13",
            "\\p \\v 38 Jesus replied. \\wj “Before the rooster crows, you will deny Me three times.[’’]\\wj*",
        ])])
        let john13 = chapter(parsed.books[0], 13)
        #expect(john13.chapter.items == [
            paragraph, verse(38), run("Jesus replied. "),
            run("“Before the rooster crows, you will deny Me three times.", wj),
        ])
        #expect(plain(john13) == ["Jesus replied. “Before the rooster crows, you will deny Me three times."])
    }

    @Test func aRepairSeesAcrossAFootnoteCallerAndGivesEachCharacterBackToItsRun() {
        let parsed = parseBSB([("1SA.usfm", [
            "\\id 1SA", "\\c 1",
            "\\p \\v 20 She named him Samuel,\\f + \\fr 1:20 \\fqa Samuel \\ft sounds like the Hebrew for \\fqa heard by God\\ft .\\f*saying, “Because I have asked the LORD for him.”",
        ])])
        let samuel1 = chapter(parsed.books[0], 1)
        #expect(samuel1.chapter.items == [
            paragraph, verse(20), run("She named him Samuel, "), caller(1), run("saying, “Because I have asked the LORD for him.”"),
        ])
        #expect(samuel1.notes.map(\.text) == ["Samuel sounds like the Hebrew for heard by God."])
    }
}
