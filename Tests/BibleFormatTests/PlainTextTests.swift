import BibleFormat
import Testing

@Suite struct PlainTextTests {
    @Test func versesJoinTheirTextRunsAndSkipEverythingElse() {
        let chapter = Chapter(book: .psalms, number: 3, items: [
            .heading(level: .two, [Run("Deliver Me")]),
            .title([Run("A Psalm of David.")]),
            .block(.poetry(level: .one)),
            .text(Run("Before any verse.")),
            .verse(VerseLabel(1)),
            .text(Run("O ")),
            .text(Run("LORD", style: .divineName)),
            .noteCaller(NoteCaller(number: 1, kind: .footnote, glyph: "a")),
            .text(Run(", how many")),
            .block(.poetry(level: .two)),
            .text(Run("rise up")),
            .speaker([Run("Friends")]),
            .block(.poetry(level: .one)),
            .text(Run("against me !")),
            .verse(VerseLabel(2, through: 3)),
            .text(Run("Many say  of\nme.")),
        ])
        #expect(PlainText.verses(of: chapter) == [
            PlainVerse(label: VerseLabel(1), text: "O LORD, how many rise up against me!"),
            PlainVerse(label: VerseLabel(2, through: 3), text: "Many say of me."),
        ])
    }

    @Test func aLineEndingInAnEmDashRunsOnWithNoSpace() {
        let chapter = Chapter(book: .isaiah, number: 1, items: [
            .block(.poetry(level: .one)), .verse(VerseLabel(1)), .text(Run("forsaken the LORD\u{2014}")),
            .block(.poetry(level: .two)), .text(Run("they have turned away.")),
        ])
        #expect(PlainText.verses(of: chapter).map(\.text) == ["forsaken the LORD\u{2014}they have turned away."])
    }

    @Test func cleanAppliesNoUnicodeNormalization() {
        let decomposed = "cre\u{0301}ated"
        #expect(Array(PlainText.clean(decomposed).unicodeScalars) == Array(decomposed.unicodeScalars))
        let hebrew = "\u{05D5}\u{05B7}\u{05BD}\u{05D9}\u{05B0}\u{05D4}\u{05B4}\u{05D9}\u{05BE}\u{05E2}"
        #expect(Array(PlainText.clean(hebrew).unicodeScalars) == Array(hebrew.unicodeScalars))
    }

    @Test func cleanCollapsesWhitespaceAndRemovesSpaceBeforePunctuation() {
        #expect(PlainText.clean("  Greek  Aram , a variant ; also\n in verse 4 . ") == "Greek Aram, a variant; also in verse 4.")
        #expect(PlainText.clean("Who ? Me !  Yes : no") == "Who? Me! Yes: no")
    }
}
