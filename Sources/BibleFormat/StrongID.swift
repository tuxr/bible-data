/// The two Strong's numbering systems, named by the letter that leads an id.
public enum StrongLanguage: String, Sendable, Hashable, CaseIterable, Comparable {
    case greek = "G"
    case hebrew = "H"

    public static func < (lhs: StrongLanguage, rhs: StrongLanguage) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A Strong's number as a words package and a lexicon store it: `G3056`, `H0776`, or `H1254A`. The number is
/// zero-padded to four digits. A Hebrew id keeps an extended Strong's letter `A` to `F`, which splits one
/// Strong's number into homonyms. Every other trailing letter is a STEPBible disambiguation of one entry,
/// such as `H0430G` or `G3708H`, and is dropped, so the id names a dictionary entry.
public struct StrongID: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let language: StrongLanguage
    public let number: Int
    /// `A` to `F`, Hebrew only.
    public let letter: Character?

    public static let numbers = 1...99_999

    public init?(language: StrongLanguage, number: Int, letter: Character? = nil) {
        guard Self.numbers.contains(number) else { return nil }
        if let letter, language == .greek || !Self.homonymLetters.contains(letter) { return nil }
        self.language = language
        self.number = number
        self.letter = letter
    }

    /// Reads `G3056`, `G03056`, `3056` with a `language`, `H1254a`, `H0430G`, or `G3700H`. Nil for anything
    /// else, or when a leading letter disagrees with `language`.
    public init?(_ raw: some StringProtocol, language: StrongLanguage? = nil) {
        var scalars = Substring(raw.trimmingCharacters(in: .whitespaces)).unicodeScalars[...]
        var named = language
        if let first = scalars.first, let leading = StrongLanguage(rawValue: String(first)) {
            if let language, language != leading { return nil }
            named = leading
            scalars = scalars.dropFirst()
        }
        guard let named else { return nil }
        let digits = scalars.prefix { ("0"..."9").contains($0) }
        let rest = scalars.dropFirst(digits.count)
        guard (1...6).contains(digits.count), rest.count <= 1, let number = Int(String(String.UnicodeScalarView(digits))) else {
            return nil
        }
        var letter: Character?
        if let suffix = rest.first {
            guard ("A"..."Z").contains(suffix) || ("a"..."z").contains(suffix) else { return nil }
            let upper = Character(String(suffix).uppercased())
            if named == .hebrew, Self.homonymLetters.contains(upper) { letter = upper }
        }
        self.init(language: named, number: number, letter: letter)
    }

    /// True when `text` is already an id in the stored form, so a reader can trust it without rewriting it.
    public static func isCanonical(_ text: String) -> Bool {
        StrongID(text)?.description == text
    }

    public var description: String {
        let digits = String(number)
        return language.rawValue + String(repeating: "0", count: max(0, 4 - digits.count)) + digits + (letter.map(String.init) ?? "")
    }

    /// The id without its homonym letter, the level a dictionary with no letter splits, such as Strong's own, keys.
    public var base: StrongID {
        StrongID(language: language, number: number)!
    }

    public static func < (lhs: StrongID, rhs: StrongID) -> Bool {
        (lhs.language, lhs.number, lhs.letter.map(String.init) ?? "") < (rhs.language, rhs.number, rhs.letter.map(String.init) ?? "")
    }

    private static let homonymLetters: Set<Character> = ["A", "B", "C", "D", "E", "F"]
}
