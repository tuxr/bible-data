import BibleFormat
import Foundation

/// One `words` row before encoding: a word of the edition at its parser position, with what the sources say.
struct WordRow: Hashable {
    let ref: VerseRef
    let position: Int
    let surface: String
    var strong: StrongID?
    var morph: String?
    var lemma: String?
    var gloss: String?
    var parts: [WordPart]?

    var values: [SQLiteValue] {
        func text(_ value: String?) -> SQLiteValue { value.map { .text($0) } ?? .null }
        return [.integer(PackageSchema.verseRowID(ref)), .integer(position), .text(surface), text(strong?.description), text(morph),
                text(lemma), text(gloss), parts.map { .text(WordParts.encode($0)) } ?? .null]
    }

    static let columns = ["verse_id", "position", "surface", "strong", "morph", "lemma", "gloss", "parts"]
}

/// What a words build covered, printed as a table and checked against the coverage floor.
struct WordsCoverage {
    var words = 0
    var strong = 0
    var morph = 0
    var contextualGloss = 0
    var lexiconGloss = 0
    var parts = 0
    var fuzzyVerses = 0
    var unmatched = 0
    /// Counts particular to one edition's sources, such as Ketiv readings, in print order.
    var notes: [(label: String, count: Int)] = []
    var examples: [(label: String, lines: [String])] = []

    var gloss: Int { contextualGloss + lexiconGloss }

    var lines: [String] {
        func percent(_ count: Int) -> String { words == 0 ? "" : String(format: "%6.2f%%", Double(count) * 100 / Double(words)) }
        let rows: [(String, Int, Bool)] = [
            ("words", words, false),
            ("with strong", strong, true),
            ("with morph", morph, true),
            ("with gloss", gloss, true),
            ("  contextual", contextualGloss, true),
            ("  lexicon fallback", lexiconGloss, true),
            ("with parts", parts, true),
            ("verses needing fuzzy alignment", fuzzyVerses, false),
            ("words matched to no source word", unmatched, true),
        ] + notes.map { ($0.label, $0.count, false) }
        let width = rows.map(\.0.count).max() ?? 0
        var lines = rows.map { label, count, share in
            label.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + String(count).leftPadded(to: 7)
                + (share ? "  " + percent(count) : "")
        }
        for example in examples where !example.lines.isEmpty {
            lines.append(example.label)
            lines += example.lines.map { "  " + $0 }
        }
        return lines
    }

    /// The coverage floor: `morph` for an edition whose morphology is required, and `gloss` for every edition.
    func shortfalls(floor: Double, requireMorph: Bool) -> [String] {
        var short: [String] = []
        let required = [("gloss", gloss)] + (requireMorph ? [("morph", morph)] : [])
        for (name, count) in required where Double(count) < floor * Double(words) {
            short.append("\(name) covers \(count) of \(words) words, under \(Int(floor * 100)) percent")
        }
        return short
    }

    mutating func count(_ row: WordRow) {
        words += 1
        if row.strong != nil { strong += 1 }
        if row.morph != nil { morph += 1 }
        if row.parts != nil { parts += 1 }
    }
}

/// A count with its first ten examples.
struct Tally {
    private(set) var count = 0
    private(set) var examples: [String] = []

    mutating func add(_ example: @autoclosure () -> String) {
        count += 1
        if examples.count < 10 { examples.append(example()) }
    }
}

extension String {
    func leftPadded(to width: Int) -> String {
        String(repeating: " ", count: max(0, width - count)) + self
    }
}

/// A tagged edition `build-words` knows, with the sources its words come from, in the order `meta.sources`
/// lists them.
enum TaggedEdition: String, CaseIterable {
    case wlc
    case tcgnt

    var wordSources: [String] {
        switch self {
        case .wlc: ["tahot", "tbesh", "strongs"]
        case .tcgnt: ["byztxt", "tagnt", "tbesg", "strongs"]
        }
    }

    var lexicon: LexiconLanguage {
        switch self {
        case .wlc: .hebrew
        case .tcgnt: .greek
        }
    }

    /// The morphology floor applies where the brief requires it: TCGNT's morphology is the point of Byztxt.
    var requiresMorph: Bool { self == .tcgnt }

    /// The credit the OSHB README asks for, owed by any package that ships the WLC's lemma or morphology.
    static let oshbCredit = "Hebrew lemma and morphology from the Open Scriptures Hebrew Bible Project (github.com/openscriptures/morphhb), CC BY 4.0."

    func build(_ edition: EditionInput, lock: SourcesLock, cache: SourceCache) throws -> (rows: [WordRow], coverage: WordsCoverage) {
        switch self {
        case .wlc:
            let tahot = TAHOTWord.words(in: try FileSetFiles.text("tahot", lock: lock, cache: cache))
            let tbesh = TBESHEntry.entries(in: try FileSetFiles.text("tbesh", lock: lock, cache: cache))
            let strongs = try StrongsHebrew.entries(in: try FileSetFiles.member("strongs", "StrongHebrewG.xml", lock: lock, cache: cache))
            return HebrewWords.build(edition.books, tahot: tahot, lemmas: { tbesh[$0]?.lemma ?? strongs[$0]?.lemma })
        case .tcgnt:
            let files = try FileSetFiles.load("byztxt", lock: lock, cache: cache)
            var byztxt: [Book: [ByztxtWord]] = [:]
            for (name, data) in files {
                guard let book = ByztxtWord.books[String(name.dropLast(4))], name.hasSuffix(".csv") else { continue }
                byztxt[book] = ByztxtWord.words(in: String(decoding: data, as: UTF8.self))
            }
            let tagnt = TAGNTWord.words(in: try FileSetFiles.text("tagnt", lock: lock, cache: cache))
            let tbesg = TBESGEntry.entries(in: try FileSetFiles.text("tbesg", lock: lock, cache: cache))
            let strongs = try StrongsGreek.entries(in: try FileSetFiles.member("strongs", "strongsgreek.xml", lock: lock, cache: cache))
            var built = GreekWords.build(edition.books, byztxt: byztxt, tagnt: tagnt, tbesg: tbesg.entries, strongs: strongs)
            built.coverage.notes.append(("TBESG ids left out as Middle Liddell (ML)", tbesg.middleLiddell.count))
            return built
        }
    }
}

/// The attribution lines of the file sets a package used, from their lock entries, in the order given.
enum SourceCredits {
    static func lines(for ids: [String], lock: SourcesLock) -> [String] {
        ids.flatMap { id -> [String] in
            guard case .files(let set)? = lock.sources[id]?.kind else { return [] }
            switch id {
            case "tbesg": return [TBESGEntry.abbottSmithCredit, set.attribution]
            case "tbesh": return [TBESHEntry.credit, set.attribution]
            default: return [set.attribution]
            }
        }
    }
}

extension FileSetFiles {
    static func member(_ id: String, _ name: String, lock: SourcesLock, cache: SourceCache) throws -> Data {
        guard let data = try load(id, lock: lock, cache: cache)[name] else { throw PackageError(description: "\(id) has no file \(name)") }
        return data
    }
}

/// Everything a words package holds. `build-words` inserts these tables.
struct WordsContent {
    let edition: EditionInput
    let builtAt: String
    let sources: [String]
    let attribution: [String]
    let rows: [WordRow]

    init(edition: EditionInput, tagged: TaggedEdition, lock: SourcesLock, builtAt: String, rows: [WordRow]) {
        self.edition = edition
        self.builtAt = builtAt
        sources = [edition.edition.id] + tagged.wordSources
        attribution = [edition.metadata.attribution] + (tagged == .wlc ? [TaggedEdition.oshbCredit] : [])
            + SourceCredits.lines(for: tagged.wordSources, lock: lock)
        self.rows = rows.sorted { ($0.ref, $0.position) < ($1.ref, $1.position) }
    }

    func tables() -> [PackageTable] {
        let meta: [(WordsSchema.MetaKey, String)] = [
            (.builtAt, builtAt),
            (.builderVersion, BiblePackVersion.current),
            (.edition, edition.edition.id),
            (.editionSourceSha256, edition.source.sha256),
            (.attribution, MetaStrings.encode(attribution)),
            (.sources, MetaStrings.encode(sources)),
        ]
        return [
            PackageTable(name: "meta", columns: ["key", "value"], rows: meta.map { [.text($0.0.rawValue), .text($0.1)] }),
            PackageTable(name: "words", columns: WordRow.columns, rows: rows.map(\.values)),
        ]
    }
}
