import BibleFormat
import Foundation

/// A locked file set's members, read from its zip in the sources directory.
enum FileSetFiles {
    static func load(_ id: String, lock: SourcesLock, cache: SourceCache) throws -> [String: Data] {
        guard let source = lock.sources[id] else { throw EditionError.notLocked(id) }
        guard case .files(let set) = source.kind else { throw PackageError(description: "\(id) is a publisher zip, not a file set") }
        guard let bytes = cache.contents(of: source.file) else { throw EditionError.missing(file: source.file, id: id) }
        guard sha256Hex(bytes) == set.archiveSha256 else { throw EditionError.hashMismatch(file: source.file, id: id) }
        let zip = try ZipArchive(bytes)
        return try Dictionary(uniqueKeysWithValues: zip.entries.map { ($0.path, try zip.contents(of: $0)) })
    }

    /// Every member's text in name order, joined, for the sources split across several files.
    static func text(_ id: String, lock: SourcesLock, cache: SourceCache) throws -> String {
        let files = try load(id, lock: lock, cache: cache)
        return files.keys.sorted().map { String(decoding: files[$0]!, as: UTF8.self) }.joined(separator: "\n")
    }
}

/// A STEPBible reference such as `Gen.31.55(32.1)#01=L` or `Act.2.11[2.10]#01=NKO`: the book, the chapter and
/// verse, the alternate numbering after it, and the row type after `=`.
struct StepReference: Hashable {
    let ref: VerseRef
    /// The verse in parentheses, which TAHOT gives when the Hebrew numbering differs from the English.
    let parenthesized: VerseRef?
    let type: Substring

    init?(_ field: Substring) {
        guard let hash = field.firstIndex(of: "#"), let equals = field[hash...].firstIndex(of: "=") else { return nil }
        let head = field[..<hash]
        let alternate = head.firstIndex { "([{".contains($0) } ?? head.endIndex
        guard let ref = Self.verse(head[..<alternate], book: nil) else { return nil }
        self.ref = ref
        if alternate < head.endIndex, head[alternate] == "(", head.last == ")" {
            parenthesized = Self.verse(head[head.index(after: alternate)..<head.index(before: head.endIndex)], book: ref.book)
        } else {
            parenthesized = nil
        }
        type = field[field.index(after: equals)...]
    }

    /// `Gen.1.1`, or `1.1` with the book given.
    private static func verse(_ text: Substring, book: Book?) -> VerseRef? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.suffix(2).compactMap { Int($0) }
        guard numbers.count == 2, numbers.allSatisfy({ (1..<1000).contains($0) }) else { return nil }
        if let book, parts.count == 2 { return VerseRef(book, numbers[0], numbers[1]) }
        guard parts.count == 3, let named = Book(rawValue: parts[0].uppercased()) else { return nil }
        return VerseRef(named, numbers[0], numbers[1])
    }
}

/// The split a TAHOT row makes of one Hebrew word: prefixes, the stem, and suffixes. TAHOT's morphology
/// column comes from ETCBC under CC BY-NC, so the reader never parses it.
struct TAHOTReading: Hashable {
    struct Piece: Hashable {
        let text: String
        let strong: StrongID?
        let gloss: String?
    }

    let pieces: [Piece]
    /// The stem, which TAHOT wraps in braces.
    let main: Int
    let gloss: String?

    var text: String { pieces.map(\.text).joined() }

    /// `texts` and `strongs` are `/`-separated as TAHOT writes them, with anything after a `\` (maqaf, sof
    /// pasuq, and their codes) already removed.
    init(texts: String, glosses: String, strongs: String) {
        let textPieces = texts.split(separator: "/", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let glossPieces = glosses.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let strongPieces = strongs.split(separator: "/", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        pieces = textPieces.indices.map { index in
            Piece(
                text: textPieces[index],
                strong: strongPieces.indices.contains(index)
                    ? StrongID(strongPieces[index].trimmingCharacters(in: CharacterSet(charactersIn: "{}")), language: .hebrew) : nil,
                gloss: glossPieces.count == textPieces.count ? WordText.cleanGloss(glossPieces[index]) : nil
            )
        }
        main = strongPieces.firstIndex { $0.hasPrefix("{") }
            ?? pieces.firstIndex { ($0.strong?.number ?? 9000) < 9000 }
            ?? 0
        gloss = WordText.cleanGloss(glossPieces.joined(separator: " "))
    }
}

/// A word row of STEPBible's TAHOT: `Gen.1.2#01=L <tab> וְ/הָ/אָ֗רֶץ <tab> translit <tab> and/ the/ earth <tab>
/// H9002/H9009/{H0776G} <tab> HC/Td/Ncfsa <tab> notes ...`.
struct TAHOTWord: Hashable {
    let reference: StepReference
    let reading: TAHOTReading
    /// The written form of a Qere row, from its `K=` note. The WLC prints this one.
    let ketiv: TAHOTReading?

    /// An `X` row is a word other manuscripts add, which the Leningrad Codex does not have.
    var inLeningrad: Bool { !reference.type.hasPrefix("X") }

    static func words(in text: String) -> [TAHOTWord] {
        text.split(whereSeparator: \.isNewline).compactMap(word)
    }

    static func word(_ line: Substring) -> TAHOTWord? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 6, let reference = StepReference(fields[0]) else { return nil }
        let texts = beforeBackslash(fields[1])
        guard !texts.isEmpty else { return nil }
        return TAHOTWord(
            reference: reference,
            reading: TAHOTReading(texts: texts, glosses: String(fields[3]), strongs: beforeBackslash(fields[4])),
            ketiv: fields.count > 6 ? ketiv(fields[6]) : nil
        )
    }

    /// `K= 'o.ho.Lo/h (אָהֳלֹ/ה\׃) "tent/ his" (H0168G/H9023\H9016=HNcbsc/Sp3ms)`.
    static func ketiv(_ note: Substring) -> TAHOTReading? {
        guard let start = note.range(of: "K=")?.upperBound,
              let textOpen = note[start...].firstIndex(of: "("), let textClose = note[textOpen...].firstIndex(of: ")"),
              let glossOpen = note[textClose...].firstIndex(of: "\""),
              let glossClose = note[note.index(after: glossOpen)...].firstIndex(of: "\""),
              let tagOpen = note[glossClose...].firstIndex(of: "("), let tagClose = note[tagOpen...].firstIndex(of: ")")
        else { return nil }
        let tags = note[note.index(after: tagOpen)..<tagClose].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard tags.count == 2 else { return nil }
        return TAHOTReading(
            texts: beforeBackslash(note[note.index(after: textOpen)..<textClose]),
            glosses: String(note[note.index(after: glossOpen)..<glossClose]),
            strongs: beforeBackslash(tags[0])
        )
    }

    private static func beforeBackslash(_ field: Substring) -> String {
        String(field.split(separator: "\\", maxSplits: 1, omittingEmptySubsequences: false)[0]).trimmingCharacters(in: .whitespaces)
    }
}

/// A word row of STEPBible's TAGNT: `Luk.9.31#02=NKO <tab> ὀφθέντες (ophthentes) <tab> having appeared <tab>
/// G3700H=V-APP-NPM <tab> ὁράω=to see <tab> editions ...`. A compound word is tagged as several words,
/// `G5228=PREP + G3029=ADV`. TAGNT's parsing comes from MorphGNT under CC BY-SA, so the reader keeps only the
/// Strong's ids of that column.
struct TAGNTWord: Hashable {
    let reference: StepReference
    let greek: String
    let gloss: String?
    let strongs: [StrongID]
    let lemmas: [String]

    static func words(in text: String) -> [TAGNTWord] {
        text.split(whereSeparator: \.isNewline).compactMap(word)
    }

    static func word(_ line: Substring) -> TAGNTWord? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 5, let reference = StepReference(fields[0]) else { return nil }
        let ids = fields[3].components(separatedBy: " + ").compactMap { $0.split(separator: "=", maxSplits: 1).first }
        return TAGNTWord(
            reference: reference,
            greek: String(fields[1].split(separator: "(", maxSplits: 1, omittingEmptySubsequences: false)[0]).trimmingCharacters(in: .whitespaces),
            gloss: WordText.cleanGloss(String(fields[2])),
            strongs: ids.compactMap { StrongID($0, language: .greek) },
            lemmas: fields[4].components(separatedBy: " + ").compactMap { lemma in
                let form = lemma.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) }
                return form?.isEmpty == false ? form : nil
            }
        )
    }
}

/// One Robinson-Pierpont word from a Byztxt CSV row, `chapter,verse,word 1841 {N-ASF} word 3739 {R-ASF} ...`.
/// An ambiguous form carries a second analysis: `γη 1093 {N-NSF} 1093 {N-VSF}`.
struct ByztxtWord: Hashable {
    struct Analysis: Hashable {
        let strong: StrongID
        let morph: String
    }

    let chapter: Int
    let verse: Int
    let form: String
    let analyses: [Analysis]

    /// `MAT.csv` and the other book files are named by these codes.
    static let books: [String: Book] = [
        "MAT": .matthew, "MAR": .mark, "LUK": .luke, "JOH": .john, "ACT": .acts, "ROM": .romans, "1CO": .firstCorinthians,
        "2CO": .secondCorinthians, "GAL": .galatians, "EPH": .ephesians, "PHP": .philippians, "COL": .colossians,
        "1TH": .firstThessalonians, "2TH": .secondThessalonians, "1TI": .firstTimothy, "2TI": .secondTimothy, "TIT": .titus,
        "PHM": .philemon, "HEB": .hebrews, "JAM": .james, "1PE": .firstPeter, "2PE": .secondPeter, "1JO": .firstJohn,
        "2JO": .secondJohn, "3JO": .thirdJohn, "JUD": .jude, "REV": .revelation,
    ]

    static func words(in csv: String) -> [ByztxtWord] {
        var words: [ByztxtWord] = []
        for line in csv.split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count == 3, let chapter = Int(columns[0]), let verse = Int(columns[1]) else { continue }
            var form: String?
            var analyses: [Analysis] = []
            var pending: StrongID?
            func finish() {
                if let form { words.append(ByztxtWord(chapter: chapter, verse: verse, form: form, analyses: analyses)) }
            }
            for token in columns[2].split(separator: " ") {
                if token.allSatisfy({ $0.isASCII && $0.isNumber }) {
                    pending = StrongID(token, language: .greek)
                } else if token.hasPrefix("{"), token.hasSuffix("}") {
                    if let strong = pending { analyses.append(Analysis(strong: strong, morph: String(token.dropFirst().dropLast()))) }
                    pending = nil
                } else {
                    finish()
                    form = String(token)
                    analyses = []
                    pending = nil
                }
            }
            finish()
        }
        return words
    }
}

/// A TBESG row: eStrong, dStrong, uStrong, Greek, transliteration, morph, gloss, meaning. The first row of each
/// eStrong is the lemma-level entry.
struct TBESGEntry: Hashable {
    let strong: StrongID
    let lemma: String
    let transliteration: String?
    /// The STEPBible morph summary as written, such as `G:N-M` or `N:N-M-P`.
    let partOfSpeech: String?
    let gloss: String?

    /// The marker that ends the meaning of an entry STEPBible took from Middle Liddell, which reached it through
    /// the Perseus Digital Library under CC BY-SA. Abbott-Smith entries end in `(AS)` and are public domain.
    static let middleLiddellMarker = "(ML)"

    /// The lemma-level entries a package may ship, and the ids left out because their row is Middle Liddell's.
    /// Nothing from a left-out row is returned, so no builder can ship it.
    static func entries(in text: String) -> (entries: [StrongID: TBESGEntry], middleLiddell: Set<StrongID>) {
        var entries: [StrongID: TBESGEntry] = [:]
        var middleLiddell = Set<StrongID>()
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 8, fields[0].hasPrefix("G"), fields[0].dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }),
                  let strong = StrongID(fields[0], language: .greek), entries[strong] == nil, !middleLiddell.contains(strong),
                  !fields[3].isEmpty
            else { continue }
            if fields[7].contains(middleLiddellMarker) {
                middleLiddell.insert(strong)
                continue
            }
            // A disambiguated row glosses as "to see: see"; the lemma-level gloss is the part before the colon.
            let gloss = fields[6].components(separatedBy: ": ")[0].trimmingCharacters(in: .whitespaces)
            entries[strong] = TBESGEntry(
                strong: strong,
                lemma: fields[3],
                transliteration: fields[4].isEmpty ? nil : fields[4],
                partOfSpeech: fields[5].isEmpty ? nil : fields[5],
                gloss: gloss.isEmpty ? nil : gloss
            )
        }
        return (entries, middleLiddell)
    }

    /// The credit for the Abbott-Smith entries, which a package shipping any TBESG field carries beside
    /// STEPBible's own.
    static let abbottSmithCredit = "Abbott-Smith, A Manual Greek Lexicon of the New Testament (1922), public domain, via STEPBible TBESG"
}

/// A TBESH row's lemma-level fields: eStrong, Hebrew, transliteration, morph, and gloss. Its last column,
/// Meaning, is Online Bible's abridged BDB, which needs Online Bible's permission, so the reader splits a row
/// into its first seven columns only and never parses it. The gloss and morph columns are Tyndale House's.
struct TBESHEntry: Hashable {
    let strong: StrongID
    let lemma: String
    let transliteration: String?
    /// The STEPBible morph summary as written, such as `H:N-M` or `A:V`.
    let partOfSpeech: String?
    let gloss: String?

    static let credit = "STEP Bible TBESH (Tyndale House Cambridge), CC BY 4.0, gloss and grammar fields only"

    /// Keyed at Strong's level, the level of the Strong's dictionary: a plain eStrong row such as `H0430`, else
    /// the first homonym of the number, so `H1254` is `H1254a`, "to create".
    static func entries(in text: String) -> [StrongID: TBESHEntry] {
        var entries: [StrongID: TBESHEntry] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 7, omittingEmptySubsequences: false).prefix(7)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 7, fields[0].hasPrefix("H"), let id = StrongID(fields[0], language: .hebrew), !fields[3].isEmpty else { continue }
            let key = id.base
            if let existing = entries[key], existing.strong.letter == nil || id.letter != nil { continue }
            let gloss = fields[6].components(separatedBy: ": ")[0].trimmingCharacters(in: .whitespaces)
            entries[key] = TBESHEntry(
                strong: id,
                lemma: fields[3],
                transliteration: fields[4].isEmpty ? nil : fields[4],
                partOfSpeech: fields[5].isEmpty ? nil : fields[5],
                gloss: gloss.isEmpty ? nil : gloss
            )
        }
        return entries
    }
}

/// A Strong's dictionary entry, Greek or Hebrew, from the Open Scriptures XML.
struct StrongsEntry: Hashable {
    let strong: StrongID
    let lemma: String
    let transliteration: String?
    /// Strong's own respelling, such as `log'-os` or `el-o-heem'`.
    let pronunciation: String?
    let definition: String?
}

enum StrongsGreek {
    /// `<entry strongs="03056">` with `<greek unicode translit>`, `<pronunciation strongs>`,
    /// `<strongs_derivation>`, and `<strongs_def>`. A `<strongsref>` inside the definition reads as the lemma it
    /// points at.
    static func entries(in data: Data) throws -> [StrongID: StrongsEntry] {
        let reader = GreekReader()
        try XMLReading.parse(data, with: reader)
        func render(_ parts: [GreekReader.Part]) -> String {
            parts.map { part in
                switch part {
                case .text(let text): text
                case .ref(let id): reader.raw[id]?.lemma ?? id.description
                }
            }.joined()
        }
        var entries: [StrongID: StrongsEntry] = [:]
        for (id, raw) in reader.raw {
            guard let lemma = raw.lemma, !lemma.isEmpty else { continue }
            entries[id] = StrongsEntry(
                strong: id, lemma: lemma, transliteration: raw.transliteration, pronunciation: raw.pronunciation,
                definition: StrongsDefinition.greek(derivation: render(raw.derivation), definition: render(raw.definition))
            )
        }
        return entries
    }

    private final class GreekReader: NSObject, XMLParserDelegate {
        enum Part { case text(String), ref(StrongID) }
        struct Raw {
            var lemma: String?
            var transliteration: String?
            var pronunciation: String?
            var derivation: [Part] = []
            var definition: [Part] = []
        }

        private enum Into { case derivation, definition }

        var raw: [StrongID: Raw] = [:]
        private var current: StrongID?
        private var into: Into?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            if name == "entry" {
                current = attributes["strongs"].flatMap { StrongID($0, language: .greek) }
                if let current { raw[current] = Raw() }
                return
            }
            guard let current else { return }
            switch name {
            case "strongs_derivation": into = .derivation
            case "strongs_def": into = .definition
            case "greek" where into == nil && raw[current]?.lemma == nil:
                raw[current]?.lemma = attributes["unicode"]
                raw[current]?.transliteration = attributes["translit"]
            case "greek" where into != nil:
                append(.text(attributes["unicode"] ?? ""))
            case "pronunciation" where into == nil && raw[current]?.pronunciation == nil:
                raw[current]?.pronunciation = attributes["strongs"]
            case "strongsref" where into != nil:
                let language: StrongLanguage = attributes["language"] == "HEBREW" ? .hebrew : .greek
                if let id = attributes["strongs"].flatMap({ StrongID($0, language: language) }) { append(.ref(id)) }
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "strongs_derivation", "strongs_def": into = nil
            case "entry": current = nil
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if into != nil { append(.text(string)) }
        }

        private func append(_ part: Part) {
            guard let current, let into else { return }
            switch into {
            case .derivation: raw[current]?.derivation.append(part)
            case .definition: raw[current]?.definition.append(part)
            }
        }
    }
}

enum StrongsHebrew {
    /// OSIS `<div type="entry">` whose first `<w ID lemma xlit POS>` names the entry, with `exegesis` and
    /// `explanation` notes. The `gloss` attribute holds TWOT numbers, which are not public domain, so nothing
    /// reads it.
    static func entries(in data: Data) throws -> [StrongID: StrongsEntry] {
        let reader = HebrewReader()
        try XMLReading.parse(data, with: reader)
        return reader.entries
    }

    private final class HebrewReader: NSObject, XMLParserDelegate {
        private enum Note { case exegesis, explanation }
        private struct Open {
            var id: StrongID?
            var lemma: String?
            var transliteration: String?
            var pronunciation: String?
            var exegesis = ""
            var explanation = ""
        }

        var entries: [StrongID: StrongsEntry] = [:]
        private var open: Open?
        private var note: Note?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            if name == "div", attributes["type"] == "entry" {
                open = Open()
                return
            }
            guard open != nil else { return }
            if name == "w", note == nil, open?.id == nil, let id = attributes["ID"].flatMap({ StrongID($0, language: .hebrew) }) {
                open?.id = id
                open?.lemma = attributes["lemma"]
                open?.transliteration = attributes["xlit"]
                open?.pronunciation = attributes["POS"]
            } else if name == "note" {
                note = switch attributes["type"] {
                case "exegesis": .exegesis
                case "explanation": .explanation
                default: nil
                }
            } else if name == "w", let lemma = attributes["lemma"] {
                // A word a note refers to is an empty element; its lemma stands in for it.
                append(lemma)
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "note" {
                note = nil
            } else if name == "div", let entry = open {
                open = nil
                guard let id = entry.id, let lemma = entry.lemma, !lemma.isEmpty else { return }
                entries[id] = StrongsEntry(
                    strong: id, lemma: lemma, transliteration: entry.transliteration, pronunciation: entry.pronunciation,
                    definition: StrongsDefinition.hebrew(exegesis: entry.exegesis, explanation: entry.explanation)
                )
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            append(string)
        }

        private func append(_ text: String) {
            switch note {
            case .exegesis: open?.exegesis += text
            case .explanation: open?.explanation += text
            case nil: break
            }
        }
    }
}

enum XMLReading {
    static func parse(_ data: Data, with delegate: some XMLParserDelegate) throws {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else {
            throw PackageError(description: "XML does not parse at line \(parser.lineNumber): \(parser.parserError.map { "\($0)" } ?? "unknown error")")
        }
    }
}

/// Text rules shared by the word sources.
enum WordText {
    /// A STEPBible contextual gloss for display: no `<>` around untranslated words, no punctuation copied from
    /// the Greek at either end, single spaces. Nil when nothing is left.
    static func cleanGloss(_ raw: String) -> String? {
        let edges = CharacterSet(charactersIn: " \t\"'\u{201C}\u{201D}\u{2018}\u{2019}.,;:!?\u{00B7}")
        let cleaned = PlainText.clean(raw.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: ""))
            .trimmingCharacters(in: edges)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The comparison key of a word: its search fold, then only its letters, so `λόγος,` and `λογοσ` agree and
    /// `הָ/אָֽרֶץ` and `הָאָֽרֶץ` agree.
    static func key(_ surface: String, script: Script) -> String {
        var letters = String.UnicodeScalarView()
        for scalar in SearchText.normalize(surface, script: script).unicodeScalars where scalar.isLetter {
            letters.append(scalar)
        }
        return String(letters)
    }
}

extension Unicode.Scalar {
    /// A letter by general category. `isAlphabetic` is no use here: it is also true of Hebrew points.
    var isLetter: Bool {
        switch properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }
}

/// The definition cleanup ported from bible-api, only as far as splitting Strong's etymology from its sense.
enum StrongsDefinition {
    /// The XML's split between `<strongs_derivation>` and `<strongs_def>` is unreliable: θεός keeps its main
    /// sense in the derivation, ἄνθρωπος splits inside a parenthesis, and ἐγώ has no definition element. So the
    /// derivation's own top-level `;` clauses are cut instead: the first, then any further clause that is still
    /// etymology. A derivation that leaves a parenthesis open runs on into the definition until it closes.
    static func greek(derivation: String, definition: String) -> String? {
        let deriv = tidy(derivation)
        let def = tidy(definition)
        if deriv.isEmpty { return def.isEmpty ? nil : def }
        if openParentheses(deriv) > 0 { return nonEmpty(dropEtymology(tidy(deriv + " " + def))) }
        guard let cut = topLevelSemicolon(deriv) else { return def.isEmpty ? deriv : def }
        let rest = tidy(String(deriv[deriv.index(after: cut)...]) + " " + def)
        if rest.isEmpty { return def.isEmpty ? nil : def }
        return nonEmpty(isEtymology(rest) ? dropEtymology(rest) : rest)
    }

    /// The explanation note is the definition, minus the braces some entries wrap it in. When it opens inside a
    /// parenthesis the exegesis started, the clause is completed from the exegesis and dropped as etymology.
    static func hebrew(exegesis: String, explanation: String) -> String? {
        var def = tidy(explanation)
        if def.hasPrefix("{"), def.hasSuffix("}") {
            def = String(def.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if !def.isEmpty, closesUnopened(def), !exegesis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let joined = tidy(exegesis + " " + def)
            if let cut = topLevelSemicolon(joined), joined.index(after: cut) < joined.endIndex {
                def = String(joined[joined.index(after: cut)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nonEmpty(def)
    }

    static func tidy(_ text: String) -> String {
        var out = PlainText.clean(text)
        for mark in [";", ",", ".", ")"] { out = out.replacingOccurrences(of: " " + mark, with: mark) }
        return out
    }

    private static func nonEmpty(_ text: String) -> String? { text.isEmpty ? nil : text }

    private static func topLevelSemicolon(_ text: String) -> String.Index? {
        var depth = 0
        for index in text.indices {
            switch text[index] {
            case "(": depth += 1
            case ")": depth = max(0, depth - 1)
            case ";" where depth == 0: return index
            default: break
            }
        }
        return nil
    }

    private static func openParentheses(_ text: String) -> Int {
        text.reduce(0) { depth, char in char == "(" ? depth + 1 : char == ")" ? max(0, depth - 1) : depth }
    }

    private static func closesUnopened(_ text: String) -> Bool {
        var depth = 0
        for char in text {
            if char == "(" { depth += 1 } else if char == ")" { depth -= 1; if depth < 0 { return true } }
        }
        return false
    }

    /// What an etymology clause opens with, as distinct from a sense such as "a deity" or "to regard".
    private static func isEtymology(_ text: String) -> Bool {
        let lower = text.lowercased()
        let starts = ["from", "akin to", "compare", "probably", "apparently", "prolonged", "perhaps", "by reduplication",
                      "corresponding to", "causative of", "including", "and other", "the same as", "a form of", "of uncertain"]
        func atWordEnd(_ prefix: String) -> Bool {
            guard lower.hasPrefix(prefix) else { return false }
            return lower.dropFirst(prefix.count).first.map { !$0.isLetter } ?? true
        }
        if starts.contains(where: atWordEnd) { return true }
        // "of Hebrew origin", "of Latin affinity", "of foreign derivation".
        let words = lower.split(separator: " ", maxSplits: 3)
        guard words.count >= 3, words[0] == "of" else { return false }
        let third = words[2].prefix { $0.isLetter }
        return ["origin", "affinity", "derivation"].contains(third)
    }

    private static func dropEtymology(_ text: String) -> String {
        var rest = text
        while true {
            guard let cut = topLevelSemicolon(rest) else { return rest }
            let next = String(rest[rest.index(after: cut)...]).trimmingCharacters(in: .whitespaces)
            if next.isEmpty { return rest }
            rest = next
            if !isEtymology(rest) { return rest }
        }
    }
}
