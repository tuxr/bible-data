import BibleFormat
import Testing

@Suite struct SearchTextTests {
    @Test func hebrewDropsPointsAndCantillationAndKeepsPunctuation() {
        let genesis1v1 = "בְּרֵאשִׁ֖ית בָּרָ֣א אֱלֹהִ֑ים אֵ֥ת הַשָּׁמַ֖יִם וְאֵ֥ת הָאָֽרֶץ׃"
        #expect(SearchText.normalize(genesis1v1, script: .hebrew) == "בראשית ברא אלהים את השמים ואת הארץ׃")
        #expect(SearchText.normalize("יְהוָ֥ה ׀ אֶחָֽד׃", script: .hebrew) == "יהוה ׀ אחד׃")
        #expect(SearchText.normalize("עַל־פְּנֵ֣י", script: .hebrew) == "על־פני")
    }

    @Test func greekDropsMarksLowercasesAndFoldsEverySigma() {
        #expect(SearchText.normalize("ἀρχῇ", script: .greek) == "αρχη")
        #expect(SearchText.normalize("λόγος", script: .greek) == "λογοσ")
        #expect(SearchText.normalize("Ἐν ἀρχῇ ἦν ὁ λόγος,", script: .greek) == "εν αρχη ην ο λογοσ,")
        #expect(SearchText.normalize("ΛΟΓΟΣ", script: .greek) == "λογοσ")
        #expect(SearchText.normalize("Ϲ ϲ", script: .greek) == "σ σ")
    }

    @Test func latinIsLeftToTheTokenizer() {
        let text = "In the beginning God créated the heavens and the earth."
        #expect(SearchText.normalize(text, script: .latin) == text)
        #expect(SearchText.column(plain: text, script: .latin) == nil)
    }

    @Test func theColumnIsNilOnlyWhenFoldingChangesNothing() {
        #expect(SearchText.column(plain: "ἀρχῇ", script: .greek) == "αρχη")
        #expect(SearchText.column(plain: "αρχη", script: .greek) == nil)
        #expect(SearchText.column(plain: "בראשית", script: .hebrew) == nil)
    }

    @Test func aQueryFoldsLikeTheText() {
        #expect(SearchText.normalizeQuery("בְּרֵאשִׁית", script: .hebrew) == "בראשית")
        #expect(SearchText.normalizeQuery("Λόγος", script: .greek) == "λογοσ")
        #expect(SearchText.normalizeQuery("Beginning", script: .latin) == "Beginning")
    }
}
