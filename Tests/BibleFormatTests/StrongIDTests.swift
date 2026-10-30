import BibleFormat
import Testing

@Suite struct StrongIDTests {
    @Test(arguments: [
        ("G3056", StrongLanguage?.none, "G3056"),
        ("G03056", nil, "G3056"),
        ("746", .greek, "G0746"),
        ("H259", nil, "H0259"),
        ("H0430G", nil, "H0430"),
        ("{H7225G}".trimmingCharacters(in: ["{", "}"]), nil, "H7225"),
        ("H1254A", nil, "H1254A"),
        ("H1254a", nil, "H1254A"),
        ("H5315K", nil, "H5315"),
        ("G3700H", nil, "G3700"),
        ("G3708G", nil, "G3708"),
        ("G10005", nil, "G10005"),
        (" H9003 ", nil, "H9003"),
    ])
    func normalizes(_ raw: String, _ language: StrongLanguage?, _ stored: String) {
        #expect(StrongID(raw, language: language)?.description == stored)
    }

    @Test(arguments: ["", "G", "3056", "X3056", "G30A6", "G3056AB", "G0", "G100000", "H12-3", "G3056=N"])
    func rejects(_ raw: String) {
        #expect(StrongID(raw) == nil)
    }

    @Test func aLeadingLetterMustMatchTheLanguageGiven() {
        #expect(StrongID("H0430", language: .greek) == nil)
        #expect(StrongID("0430", language: .hebrew)?.description == "H0430")
    }

    @Test func canonicalMeansAlreadyStored() {
        #expect(StrongID.isCanonical("H0430"))
        #expect(StrongID.isCanonical("H1254A"))
        #expect(!StrongID.isCanonical("H430"))
        #expect(!StrongID.isCanonical("H0430G"))
        #expect(!StrongID.isCanonical("H1254a"))
    }

    @Test func greekHasNoHomonymLetters() {
        #expect(StrongID(language: .greek, number: 3056, letter: "A") == nil)
        #expect(StrongID(language: .hebrew, number: 1254, letter: "G") == nil)
    }

    @Test func sortsByLanguageNumberThenLetter() {
        let ids = ["H1254B", "G5624", "H1254", "H1254A", "G0001", "H0001"].compactMap { StrongID($0) }
        #expect(ids.sorted().map(\.description) == ["G0001", "G5624", "H0001", "H1254", "H1254A", "H1254B"])
        #expect(StrongID("H1254A")!.base.description == "H1254")
    }
}
