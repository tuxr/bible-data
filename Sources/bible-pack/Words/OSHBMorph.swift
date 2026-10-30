/// The grammar of an OSHB morphology code, from hb.openscriptures.org/parsing/HebrewMorphologyCodes.html: a
/// language letter, `H` or `A`, then `/`-separated pieces, each a part-of-speech letter and its fields in order.
/// A piece may stop after any field, and `x` holds the place of a value only before a later one.
enum OSHBMorph {
    static func isValid(_ code: String) -> Bool {
        guard let language = code.first, let stems = verbStems[language] else { return false }
        return code.dropFirst().split(separator: "/", omittingEmptySubsequences: false).allSatisfy { isValid(piece: $0, stems: stems) }
    }

    private static func isValid(piece: Substring, stems: Set<Character>) -> Bool {
        guard let part = piece.first else { return false }
        let values = Array(piece.dropFirst())
        let layout: [Set<Character>]? = switch part {
        case "V" where values.count > 1: verbTails[values[1]].map { [stems, conjugations] + $0 }
        case "V": [stems, conjugations]
        default: fields[part]
        }
        guard let layout, values.count <= layout.count, values.last != "x" else { return false }
        return zip(values, layout).allSatisfy { $0 == "x" || $1.contains($0) }
    }

    private static let person = Set("123")
    private static let gender = Set("bcfm")
    private static let number = Set("dps")
    private static let state = Set("acd")

    private static let fields: [Character: [Set<Character>]] = [
        "A": [Set("acgo"), gender, number, state],
        "C": [],
        "D": [],
        "N": [Set("cgp"), gender, number, state],
        "P": [Set("dfipr"), person, gender, number],
        "R": [Set("d")],
        "S": [Set("dhnp"), person, gender, number],
        "T": [Set("adeijmnor")],
    ]

    private static let verbStems: [Character: Set<Character>] = [
        "H": Set("qNpPhHtoOrmMkKQlLfDjiucvwyz"),
        "A": Set("qQupPMahseHitvwozrfbcmlLOG"),
    ]

    private static let verbTails: [Character: [Set<Character>]] = [
        "p": [person, gender, number],
        "q": [person, gender, number],
        "i": [person, gender, number],
        "w": [person, gender, number],
        "h": [person, gender, number],
        "j": [person, gender, number],
        "v": [person, gender, number],
        "r": [gender, number, state],
        "s": [gender, number, state],
        "a": [],
        "c": [],
    ]

    private static let conjugations = Set(verbTails.keys)
}
