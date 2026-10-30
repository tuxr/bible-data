import BibleFormat
import Foundation

/// A word of the WLC as the Open Scriptures Hebrew Bible tags it: the pieces its `/` marks, in reading order.
struct OSHBWord: Hashable {
    struct Piece: Hashable {
        let surface: String
        /// The piece's own code, with the word's language letter: `HR`, `HNcfsa`.
        let morph: String
        /// A prefix's letter, such as `b`, or the stem's number, such as `1254 a`. Nil for a suffix, and for
        /// every piece of a word whose lemma names a different number of prefixes and stems.
        let lemma: String?

        var isSuffix: Bool { morph.dropFirst().first == "S" }
    }

    let surface: String
    /// Empty when the word's code does not split into as many pieces as its text.
    let pieces: [Piece]
    /// The stem's Strong's number, at the level of a dictionary without homonym letters.
    let strong: StrongID?
    /// A Ketiv the WLC prints, whose Qere OSHB keeps in a note.
    let isKetiv: Bool

    /// The code as OSHB writes it, with one language letter: `HC/Td/Ncbsa`.
    var morph: String? {
        guard let first = pieces.first else { return nil }
        return ([first.morph] + pieces.dropFirst().map { String($0.morph.dropFirst()) }).joined(separator: "/")
    }

    /// `text` is the element's text, `/` between pieces, as in `lemma="c/1121 a" morph="HC/Ncmpc/Sp3ms"`
    /// with `וּ/בָנָ֛י/ו`, whose suffix has no lemma.
    init(text: String, lemma: String, morph: String, isKetiv: Bool) {
        let texts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let codes = morph.split(separator: "/", omittingEmptySubsequences: false)
        surface = texts.joined()
        self.isKetiv = isKetiv
        let lemmas = lemma.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        strong = lemmas.reversed().lazy.compactMap(Self.strong).first
        guard let language = codes.first?.first, codes.count == texts.count, codes.allSatisfy({ !$0.isEmpty }) else {
            pieces = []
            return
        }
        let morphs = codes.enumerated().map { $0.offset == 0 ? String($0.element) : String(language) + $0.element }
        let lemmaSlots = morphs.indices.filter { $0 == 0 || morphs[$0].dropFirst().first != "S" }
        var lemmaAt: [Int: String] = [:]
        if lemmaSlots.count == lemmas.count {
            for (slot, value) in zip(lemmaSlots, lemmas) { lemmaAt[slot] = value }
        }
        pieces = morphs.indices.map { Piece(surface: texts[$0], morph: morphs[$0], lemma: lemmaAt[$0]) }
    }

    private init(surface: String, pieces: [Piece], strong: StrongID?, isKetiv: Bool) {
        (self.surface, self.pieces, self.strong, self.isKetiv) = (surface, pieces, strong, isKetiv)
    }

    /// One WLC word that OSHB tags as two elements with nothing between them, as it does where it divides a
    /// word for exegesis: `<w>לְ/מַ</w><w>בָּ/רִ֥אשׁוֹנָ֖ה</w>` is the WLC's `לְמַבָּרִ֥אשׁוֹנָ֖ה`.
    func joined(with next: OSHBWord) -> OSHBWord {
        let sameLanguage = pieces.first?.morph.first == next.pieces.first?.morph.first
        return OSHBWord(
            surface: surface + next.surface,
            pieces: pieces.isEmpty || next.pieces.isEmpty || !sameLanguage ? [] : pieces + next.pieces,
            strong: next.strong ?? strong,
            isKetiv: isKetiv || next.isKetiv
        )
    }

    /// `7225`, `1254 a`, and `1035+` are numbers; a prefix letter such as `b` is not.
    static func strong(_ lemma: String) -> StrongID? {
        let digits = lemma.prefix { ("0"..."9").contains($0) }
        let rest = lemma.dropFirst(digits.count)
        let homonym = rest.count == 2 && rest.first == " " && rest.last.map { ("a"..."f").contains($0) } == true
        guard !digits.isEmpty, rest.isEmpty || rest == "+" || homonym, let number = Int(digits) else { return nil }
        return StrongID(language: .hebrew, number: number)
    }

    /// Every verse's words in reading order, from one OSIS book file. A note's contents are not the WLC's
    /// text: the Qere of a Ketiv, a Qere with no Ketiv, and alternative accents all live in notes.
    static func verses(in data: Data) throws -> [VerseRef: [OSHBWord]] {
        let reader = Reader()
        try XMLReading.parse(data, with: reader)
        return reader.verses
    }

    static let books: [String: Book] = Dictionary(uniqueKeysWithValues: zip(
        ["Gen", "Exod", "Lev", "Num", "Deut", "Josh", "Judg", "Ruth", "1Sam", "2Sam", "1Kgs", "2Kgs", "1Chr", "2Chr",
         "Ezra", "Neh", "Esth", "Job", "Ps", "Prov", "Eccl", "Song", "Isa", "Jer", "Lam", "Ezek", "Dan", "Hos", "Joel",
         "Amos", "Obad", "Jonah", "Mic", "Nah", "Hab", "Zeph", "Hag", "Zech", "Mal"],
        Book.allCases.prefix(39)
    ))

    /// `Gen.1.1`.
    static func verse(_ osisID: String) -> VerseRef? {
        let parts = osisID.split(separator: ".")
        guard parts.count == 3, let book = books[String(parts[0])], let chapter = Int(parts[1]), let verse = Int(parts[2]),
              (1..<1000).contains(chapter), (1..<1000).contains(verse) else { return nil }
        return VerseRef(book, chapter, verse)
    }

    private final class Reader: NSObject, XMLParserDelegate {
        private struct Open {
            var attributes: [String: String]
            var text = ""
            let joinsPrevious: Bool
        }

        var verses: [VerseRef: [OSHBWord]] = [:]
        private var verse: VerseRef?
        private var noteDepth = 0
        private var open: Open?
        /// True right after a word's end tag, until any text or other element comes between.
        private var touchingWord = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            let touching = touchingWord
            if open == nil { touchingWord = false }
            if name == "note" { noteDepth += 1 }
            guard noteDepth == 0, open == nil else { return }
            if name == "verse" {
                verse = attributes["osisID"].flatMap(OSHBWord.verse)
            } else if name == "w", verse != nil {
                open = Open(attributes: attributes, joinsPrevious: touching)
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "note" {
                noteDepth = max(0, noteDepth - 1)
                return
            }
            guard noteDepth == 0 else { return }
            if name == "w", let word = open, let verse {
                open = nil
                let tagged = OSHBWord(
                    text: word.text, lemma: word.attributes["lemma"] ?? "", morph: word.attributes["morph"] ?? "",
                    isKetiv: word.attributes["type"] == "x-ketiv"
                )
                if word.joinsPrevious, let previous = verses[verse]?.popLast() {
                    verses[verse]!.append(previous.joined(with: tagged))
                } else {
                    verses[verse, default: []].append(tagged)
                }
                touchingWord = true
            } else if name == "verse" {
                verse = nil
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard noteDepth == 0 else { return }
            if open != nil {
                open!.text += string
            } else {
                touchingWord = false
            }
        }
    }
}
