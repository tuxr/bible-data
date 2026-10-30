import BibleFormat
import Foundation

/// One `entries` row before encoding.
struct LexiconEntry: Hashable {
    let strong: StrongID
    let lemma: String
    var transliteration: String?
    var pronunciation: String?
    var partOfSpeech: String?
    var gloss: String?
    var definition: String?
    var occurrences: Int?

    var values: [SQLiteValue] {
        func text(_ value: String?) -> SQLiteValue { value.map { .text($0) } ?? .null }
        return [.text(strong.description), .text(lemma), text(transliteration), text(pronunciation), text(partOfSpeech), text(gloss),
                text(definition), .optional(occurrences)]
    }

    static let columns = ["strong", "lemma", "transliteration", "pronunciation", "part_of_speech", "gloss", "definition", "occurrences"]
}

/// How often a words package uses each Strong's id.
struct WordsUsage {
    let edition: TaggedEdition
    let occurrences: [StrongID: Int]

    static func read(_ url: URL) throws -> WordsUsage {
        let database = try SQLiteDatabase(path: url.path, mode: .readOnly)
        let meta = try PackageMeta.read(database)
        guard meta[WordsSchema.MetaKey.kind.rawValue] == PackageKind.words.rawValue,
              let edition = meta[WordsSchema.MetaKey.edition.rawValue].flatMap(TaggedEdition.init(rawValue:))
        else { throw PackageError(description: "\(url.path) is not a words package of a known tagged edition") }
        var occurrences: [StrongID: Int] = [:]
        for row in try database.rows("SELECT strong, count(*) FROM words WHERE strong IS NOT NULL GROUP BY strong") {
            guard let id = row[0].text.flatMap({ StrongID($0) }), case .integer(let count) = row[1] else {
                throw PackageError(description: "\(url.path) has a malformed strong \(row[0])")
            }
            occurrences[id] = Int(count)
        }
        return WordsUsage(edition: edition, occurrences: occurrences)
    }
}

extension SQLiteValue {
    var text: String? {
        if case .text(let value) = self { value } else { nil }
    }
}

enum PackageMeta {
    static func read(_ database: SQLiteDatabase) throws -> [String: String] {
        try Dictionary(database.rows("SELECT key, value FROM meta").compactMap { row in
            guard let key = row[0].text, let value = row[1].text else { return nil }
            return (key, value)
        }, uniquingKeysWith: { first, _ in first })
    }
}

/// A built lexicon: its entries in id order, the sources and credits it used, and what it could not cover.
struct LexiconBuild {
    let language: LexiconLanguage
    let entries: [LexiconEntry]
    let sources: [String]
    let attribution: [String]
    /// Ids the words package uses that no source defines.
    let missing: [StrongID]
    var notes: [(label: String, count: Int)] = []

    static func greek(lock: SourcesLock, cache: SourceCache, usage: WordsUsage?) throws -> LexiconBuild {
        let tbesg = TBESGEntry.entries(in: try FileSetFiles.text("tbesg", lock: lock, cache: cache))
        let strongs = try StrongsGreek.entries(in: try FileSetFiles.member("strongs", "strongsgreek.xml", lock: lock, cache: cache))
        let used = Set(usage?.occurrences.keys.map { $0 } ?? [])
        var entries: [LexiconEntry] = []
        var fromStrongsOnly = 0
        for id in Set(strongs.keys).union(used).sorted() {
            let step = tbesg.entries[id]
            let strong = strongs[id]
            guard let lemma = step?.lemma ?? strong?.lemma else { continue }
            if step == nil, tbesg.middleLiddell.contains(id) { fromStrongsOnly += 1 }
            entries.append(LexiconEntry(
                strong: id, lemma: lemma,
                transliteration: step?.transliteration ?? strong?.transliteration,
                pronunciation: strong?.pronunciation,
                partOfSpeech: step?.partOfSpeech,
                gloss: step?.gloss,
                definition: strong?.definition,
                occurrences: usage.map { $0.occurrences[id] ?? 0 }
            ))
        }
        let sources = ["tbesg", "strongs"]
        var build = LexiconBuild(
            language: .greek, entries: entries, sources: sources, attribution: SourceCredits.lines(for: sources, lock: lock),
            missing: used.subtracting(entries.map(\.strong)).sorted()
        )
        build.notes = [
            ("TBESG ids left out as Middle Liddell (ML)", tbesg.middleLiddell.count),
            ("  of those, entries from Strong's alone", fromStrongsOnly),
        ]
        return build
    }

    /// Lemma, transliteration, part of speech, and gloss from TBESH where it has the id; pronunciation and
    /// definition from Strong's Hebrew dictionary.
    static func hebrew(lock: SourcesLock, cache: SourceCache, usage: WordsUsage?) throws -> LexiconBuild {
        let tbesh = TBESHEntry.entries(in: try FileSetFiles.text("tbesh", lock: lock, cache: cache))
        let strongs = try StrongsHebrew.entries(in: try FileSetFiles.member("strongs", "StrongHebrewG.xml", lock: lock, cache: cache))
        let used = Set(usage?.occurrences.keys.map { $0 } ?? [])
        let entries = strongs.keys.sorted().map { id in
            let step = tbesh[id]
            let strong = strongs[id]!
            return LexiconEntry(
                strong: id, lemma: step?.lemma ?? strong.lemma, transliteration: step?.transliteration ?? strong.transliteration,
                pronunciation: strong.pronunciation, partOfSpeech: step?.partOfSpeech, gloss: step?.gloss, definition: strong.definition,
                occurrences: usage.map { $0.occurrences[id] ?? 0 }
            )
        }
        let sources = ["tbesh", "strongs"]
        var build = LexiconBuild(
            language: .hebrew, entries: entries, sources: sources, attribution: SourceCredits.lines(for: sources, lock: lock),
            missing: used.subtracting(entries.map(\.strong)).sorted()
        )
        build.notes = [
            ("entries with a TBESH gloss", entries.filter { $0.gloss != nil }.count),
            ("entries with a TBESH part of speech", entries.filter { $0.partOfSpeech != nil }.count),
            ("entries from Strong's alone", entries.filter { tbesh[$0.strong] == nil }.count),
        ]
        return build
    }

    func tables(version: PackageVersion, builtAt: String) -> [PackageTable] {
        let meta: [(LexiconSchema.MetaKey, String)] = [
            (.version, version.description),
            (.builtAt, builtAt),
            (.builderVersion, BiblePackVersion.current),
            (.language, language.code),
            (.attribution, MetaStrings.encode(attribution)),
            (.sources, MetaStrings.encode(sources)),
        ]
        return [
            PackageTable(name: "meta", columns: ["key", "value"], rows: meta.map { [.text($0.0.rawValue), .text($0.1)] }),
            PackageTable(name: "entries", columns: LexiconEntry.columns, rows: entries.map(\.values)),
        ]
    }
}
