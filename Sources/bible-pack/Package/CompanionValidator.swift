import BibleFormat
import Foundation

/// The checks `bible-pack validate` runs on a words or lexicon package, in order. A failure names the check.
enum CompanionCheck: String, CaseIterable, Sendable {
    case integrity = "integrity_check"
    case meta
    case verseIDs = "verse ids"
    case positions
    case strongIDs = "strong ids"
    case parts
    case morph = "morph codes"
    case sorted = "sorted ids"
    case lemmas
    case lexicon = "every strong in the lexicon"
    case words = "every id the words package uses"
    case compressed
    case againstSource = "against source"

    static func wordsChecks(for edition: TaggedEdition) -> [CompanionCheck] {
        [.integrity, .meta, .verseIDs, .positions, .strongIDs, .parts] + (edition.morphGrammar == nil ? [] : [.morph])
            + [.lexicon, .compressed, .againstSource]
    }
    static let lexiconChecks: [CompanionCheck] = [.integrity, .meta, .strongIDs, .sorted, .lemmas, .words, .compressed]
}

struct CompanionValidationError: Error, CustomStringConvertible {
    let check: CompanionCheck
    let message: String

    var description: String { "\(check.rawValue): \(message)" }
}

enum CompanionValidator {
    typealias Pass = (CompanionCheck, String) -> Void

    private static func check(_ check: CompanionCheck, _ detail: String, failure: String?, pass: Pass) throws {
        if let failure { throw CompanionValidationError(check: check, message: failure) }
        pass(check, detail)
    }

    private static func integrity(_ database: SQLiteDatabase, pass: Pass) throws {
        let integrity = try database.pragma("integrity_check")
        try check(.integrity, "ok", failure: integrity == [[.text("ok")]] ? nil : "reported \(integrity.first.map { "\($0)" } ?? "nothing")", pass: pass)
    }

    /// The `meta` keys every companion package shares: kind, format version, build time, and its credits.
    private static func sharedMeta(_ meta: [String: String], kind: PackageKind) -> String? {
        if meta[PackageKind.metaKey] != kind.rawValue { return "kind is \(meta[PackageKind.metaKey] ?? "missing"), expected \(kind.rawValue)" }
        if meta["format_version"] != "\(PackageFormat.version)" { return "format_version is \(meta["format_version"] ?? "missing"), expected \(PackageFormat.version)" }
        if meta["version"].flatMap(PackageVersion.init) == nil { return "version is \(meta["version"] ?? "missing"), expected yyyy.mm or yyyy.mm.n" }
        if meta["built_at"].flatMap(CanonPackage.parseBuiltAt) == nil { return "built_at is \(meta["built_at"] ?? "missing"), expected an ISO 8601 UTC time" }
        if meta["builder_version"]?.isEmpty != false { return "builder_version is missing" }
        for key in ["attribution", "sources"] where meta[key].flatMap(MetaStrings.decode).map({ $0.isEmpty || $0.contains("") }) != false {
            return "\(key) is \(meta[key] ?? "missing"), expected a nonempty JSON array of nonempty strings"
        }
        return nil
    }

    private static func compressed(_ url: URL, pass: Pass) throws {
        switch PackageWriter.checkCompressed(beside: url, packageBytes: try Data(contentsOf: url)) {
        case .absent: break
        case .matches(let detail): try check(.compressed, detail, failure: nil, pass: pass)
        case .fails(let failure): try check(.compressed, "", failure: failure, pass: pass)
        }
    }

    /// `source` parses the edition again for `--against-source`; `lexicon` is a lexicon package to check every
    /// Strong's id against.
    static func validateWords(at url: URL, lexicon: URL?, source: ((String) throws -> EditionInput)?, pass: Pass) throws {
        let database = try SQLiteDatabase(path: url.path, mode: .readOnly)
        try integrity(database, pass: pass)

        let meta = try PackageMeta.read(database)
        let tagged = meta[WordsSchema.MetaKey.edition.rawValue].flatMap(TaggedEdition.init(rawValue:))
        let sha = meta[WordsSchema.MetaKey.editionSourceSha256.rawValue] ?? ""
        let metaFailure = sharedMeta(meta, kind: .words)
            ?? (tagged == nil ? "edition is \(meta["edition"] ?? "missing"), expected one of \(TaggedEdition.allCases.map(\.rawValue).joined(separator: ", "))" : nil)
            ?? (sha.count == 64 && sha.allSatisfy(\.isHexDigit) ? nil : "edition_source_sha256 is \(sha), expected 64 hex digits")
        try check(.meta, "\(tagged?.rawValue ?? "") words", failure: metaFailure, pass: pass)
        let edition = tagged!
        let scheme = Edition.named(edition.rawValue)!.scheme
        let counts = try Versification.counts(for: scheme)

        let verses = try database.rows("SELECT verse_id, count(*), min(position), max(position) FROM words GROUP BY verse_id ORDER BY verse_id")
        var badVerse: String?
        var badPositions: String?
        for row in verses {
            guard case .integer(let id) = row[0], case .integer(let count) = row[1], case .integer(let low) = row[2], case .integer(let high) = row[3] else {
                badVerse = "row \(row) is malformed"
                break
            }
            if badVerse == nil, PackageSchema.verseRef(rowID: id).map({ !counts.contains($0) || PackageSchema.verseRowID($0) != id }) ?? true {
                badVerse = "verse_id \(id) is not a verse of the \(scheme.rawValue) scheme"
            }
            if badPositions == nil, low != 1 || high != count {
                badPositions = "verse_id \(id) has positions \(low) to \(high) in \(count) rows, expected 1 to \(count)"
            }
        }
        try check(.verseIDs, "\(verses.count) verses of \(scheme.rawValue)", failure: badVerse, pass: pass)
        try check(.positions, "1 to n in every verse", failure: badPositions, pass: pass)

        let strongs = try database.rows("SELECT DISTINCT strong FROM words WHERE strong IS NOT NULL").compactMap { $0[0].text }
        let language = edition.lexicon.strongLanguage
        let badStrong = strongs.first { !StrongID.isCanonical($0) || StrongID($0)?.language != language }
        try check(.strongIDs, "\(strongs.count) distinct ids", failure: badStrong.map { "\($0) is not a \(language.rawValue) id in the stored form" }, pass: pass)

        var partRows = 0
        var badParts: String?
        for row in try database.rows("SELECT verse_id, position, parts FROM words WHERE parts IS NOT NULL") {
            partRows += 1
            guard let value = row[2].text, let parts = WordParts.decode(value) else {
                badParts = "verse_id \(row[0]) position \(row[1]) parts do not decode"
                break
            }
            if let bad = parts.compactMap(\.strong).first(where: { !StrongID.isCanonical($0) }) {
                badParts = "verse_id \(row[0]) position \(row[1]) has a part with strong \(bad)"
                break
            }
        }
        try check(.parts, "\(partRows) rows decode", failure: badParts, pass: pass)

        if let grammar = edition.morphGrammar {
            var codes = 0
            var invalid: [String] = []
            for row in try database.rows("SELECT verse_id, position, morph, parts FROM words WHERE morph IS NOT NULL OR parts IS NOT NULL") {
                let pieces = row[3].text.flatMap(WordParts.decode)?.compactMap(\.morph) ?? []
                for code in [row[2].text].compactMap({ $0 }) + pieces {
                    codes += 1
                    if !grammar(code) { invalid.append("verse_id \(row[0]) position \(row[1]) \(code)") }
                }
            }
            let failure = invalid.isEmpty ? nil : "\(invalid.count) of \(codes) codes break the grammar, first \(invalid.prefix(5).joined(separator: ", "))"
            try check(.morph, "\(codes) codes, 0 invalid", failure: failure, pass: pass)
        }

        if let lexicon {
            let lexiconDatabase = try SQLiteDatabase(path: lexicon.path, mode: .readOnly)
            let lexiconMeta = try PackageMeta.read(lexiconDatabase)
            let defined = Set(try lexiconDatabase.rows("SELECT strong FROM entries").compactMap { $0[0].text })
            let missing = strongs.filter { !defined.contains($0) }.sorted()
            let failure = lexiconMeta[PackageKind.metaKey] != PackageKind.lexicon.rawValue
                || lexiconMeta[LexiconSchema.MetaKey.language.rawValue] != edition.lexicon.code
                ? "\(lexicon.lastPathComponent) is not the \(edition.lexicon.rawValue) lexicon"
                : missing.isEmpty ? nil : "\(missing.count) ids are not in \(lexicon.lastPathComponent), first \(missing.prefix(10).joined(separator: " "))"
            try check(.lexicon, "\(strongs.count) ids in \(lexicon.lastPathComponent)", failure: failure, pass: pass)
        }

        try compressed(url, pass: pass)

        if let source {
            let input: EditionInput
            do {
                input = try source(edition.rawValue)
            } catch {
                throw CompanionValidationError(check: .againstSource, message: "\(error)")
            }
            let expected = input.books.flatMap(\.chapters).flatMap(\.words).flatMap { verse in
                verse.words.map { "\(PackageSchema.verseRowID(verse.ref)) \($0.index) \($0.surface)" }
            }.sorted()
            let actual = try database.rows("SELECT verse_id, position, surface FROM words").map { "\($0[0]) \($0[1]) \($0[2].text ?? "")" }.sorted()
            let failure: String? = if input.source.sha256 != sha {
                "edition_source_sha256 is \(sha), the locked source is \(input.source.sha256)"
            } else if expected != actual {
                "\(actual.count) words, the parser gives \(expected.count); first difference: "
                    + (zip(expected, actual).first { $0 != $1 }.map { "expected \($0.0), found \($0.1)" } ?? "at the end")
            } else { nil }
            try check(.againstSource, "\(expected.count) surfaces and positions match \(input.source.file)", failure: failure, pass: pass)
        }
    }

    /// `words` is a words package of the same language whose every Strong's id must have an entry.
    static func validateLexicon(at url: URL, words: URL?, pass: Pass) throws {
        let database = try SQLiteDatabase(path: url.path, mode: .readOnly)
        try integrity(database, pass: pass)

        let meta = try PackageMeta.read(database)
        let language = meta[LexiconSchema.MetaKey.language.rawValue].flatMap(LexiconLanguage.init(code:))
        try check(.meta, "\(language?.rawValue ?? "") lexicon", failure: sharedMeta(meta, kind: .lexicon)
            ?? (language == nil ? "language is \(meta["language"] ?? "missing"), expected grc or hbo" : nil), pass: pass)

        let rows = try database.rows("SELECT strong, lemma FROM entries ORDER BY strong")
        let ids = rows.compactMap { $0[0].text }
        let prefix = language!.strongLanguage
        let bad = ids.first { !StrongID.isCanonical($0) || StrongID($0)?.language != prefix }
        try check(.strongIDs, "\(ids.count) entries", failure: bad.map { "\($0) is not a \(prefix.rawValue) id in the stored form" }, pass: pass)
        let parsed = ids.compactMap { StrongID($0) }
        // Text order is the stored order; it matches numeric order only while every id has the same digit count.
        let outOfOrder = zip(parsed, parsed.dropFirst()).first { !($0 < $1) }
        try check(.sorted, "text order is numeric order", failure: outOfOrder.map { "\($0.0) sorts before \($0.1) as text but not by number" }, pass: pass)
        let blank = rows.first { $0[1].text?.isEmpty != false }
        try check(.lemmas, "every lemma nonempty", failure: blank.map { "\($0[0]) has no lemma" }, pass: pass)

        if let words {
            let usage = try WordsUsage.read(words)
            let defined = Set(ids)
            let missing = usage.occurrences.keys.map(\.description).filter { !defined.contains($0) }.sorted()
            let failure = usage.edition.lexicon != language
                ? "\(words.lastPathComponent) is \(usage.edition.rawValue) words, not \(language!.rawValue)"
                : missing.isEmpty ? nil : "\(missing.count) ids are missing, first \(missing.prefix(10).joined(separator: " "))"
            try check(.words, "\(usage.occurrences.count) ids of \(words.lastPathComponent)", failure: failure, pass: pass)
        }

        try compressed(url, pass: pass)
    }

    /// The `meta.kind` of a package file, read before anything else.
    static func kind(of url: URL) throws -> PackageKind {
        let meta = try PackageMeta.read(try SQLiteDatabase(path: url.path, mode: .readOnly))
        guard let kind = meta[PackageKind.metaKey].flatMap(PackageKind.init(rawValue:)) else {
            throw PackageError(description: "\(url.path) has meta.kind \(meta[PackageKind.metaKey] ?? "missing"), expected one of "
                + PackageKind.allCases.map(\.rawValue).joined(separator: ", "))
        }
        return kind
    }
}
