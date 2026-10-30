import ArgumentParser
import BibleFormat
import Foundation
import Testing
@testable import bible_pack

private let pinnedTime = "2026-10-29T00:00:00Z"

/// Packages built once per test run through the `build` command, from the real sources. They go under
/// `.build`, which each run clears, so runs do not pile up packages in the temporary directory.
private enum Built {
    static let directory: URL = {
        let url = RealSources.repository.appending(path: ".build/package-tests", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: url)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let bsb = build("bsb")
    static let wlc = build("wlc")
    static let tcgnt = build("tcgnt")
    /// The BSB in the binary encoding, the size the app ships, built twice to prove determinism.
    static let bsbBinary = build("bsb", encoding: "binary", out: "binary-1")
    static let bsbBinaryAgain = build("bsb", encoding: "binary", out: "binary-2")

    static func package(_ id: String) -> URL {
        switch id {
        case "bsb": bsb
        case "wlc": wlc
        default: tcgnt
        }
    }

    static func build(_ id: String, encoding: String? = nil, out: String = "json") -> URL {
        let directory = directory.appendingPathComponent(out, isDirectory: true)
        var arguments = [id, "--out", directory.path, "--built-at", pinnedTime, "--version", "2026.10"] + sourceArguments
        if let encoding { arguments += ["--encoding", encoding] }
        do {
            try Build.parse(arguments).run()
        } catch {
            preconditionFailure("bible-pack build \(arguments.joined(separator: " ")) failed: \(error)")
        }
        return directory.appendingPathComponent("\(id)-2026.10.bible")
    }

    static let sourceArguments = [
        "--lock", RealSources.repository.appending(path: "sources.lock.json").path,
        "--sources-dir", RealSources.repository.appending(path: ".sources").path,
        "--editions-dir", RealSources.repository.appending(path: "editions").path,
    ]

    /// A copy without the `.xz` sibling, for a test that edits it.
    static func copy(_ package: URL) throws -> URL {
        let copy = directory.appendingPathComponent("tampered-\(UUID().uuidString).bible")
        try FileManager.default.copyItem(at: package, to: copy)
        return copy
    }
}

private func validate(_ package: URL, againstSource: Bool = false) throws -> [PackageCheck] {
    var passed: [PackageCheck] = []
    let source: ((String) throws -> EditionInput)? = againstSource ? { id in
        try EditionInput.load(
            id,
            editionsDirectory: RealSources.repository.appending(path: "editions"),
            lock: RealSources.lock!,
            cache: RealSources.cache
        )
    } : nil
    try PackageValidator.validate(at: package, source: source) { check, _ in passed.append(check) }
    return passed
}

private func scalar(_ package: URL, _ sql: String, _ values: [SQLiteValue] = []) throws -> SQLiteValue? {
    try SQLiteDatabase(path: package.path, mode: .readOnly).rows(sql, values).first?.first
}

@Suite(.enabled(if: RealSources.present, RealSources.skipMessage))
struct BuildPackageTests {
    @Test(arguments: ["bsb", "wlc", "tcgnt"])
    func everyCheckPassesAgainstTheSource(_ id: String) throws {
        #expect(try validate(Built.package(id), againstSource: true) == PackageCheck.allCases)
    }

    @Test func buildsAreByteIdenticalForOnePinnedTime() throws {
        let first = Built.bsbBinary
        let second = Built.bsbBinaryAgain
        #expect(try Data(contentsOf: first) == Data(contentsOf: second))
        #expect(try Data(contentsOf: PackageWriter.compressedURL(for: first)) == Data(contentsOf: PackageWriter.compressedURL(for: second)))
        let contents = try FileManager.default.contentsOfDirectory(atPath: first.deletingLastPathComponent().path).sorted()
        #expect(contents == ["bsb-2026.10.bible", "bsb-2026.10.bible.xz"])
        #expect(try validate(first) == PackageCheck.allCases.filter { $0 != .againstSource })
    }

    /// The plan targets about 10 MB on disk and 3 MB to download for an English edition.
    @Test func bsbFitsTheSizeBudget() throws {
        let package = try Data(contentsOf: Built.bsbBinary)
        let compressed = try Data(contentsOf: PackageWriter.compressedURL(for: Built.bsbBinary))
        #expect(package.count < 15_000_000)
        #expect(compressed.count < 5_000_000)
        #expect(compressed.prefix(6) == Data([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]), "an xz stream")
    }

    @Test func aTamperedPlainTextFailsTheRoundTrip() throws {
        let package = try Built.copy(Built.bsbBinary)
        try SQLiteDatabase(path: package.path, mode: .readWrite).exec("UPDATE verses SET text_plain = 'In the beginning' WHERE id = 1001001")
        let error = #expect(throws: PackageValidationError.self) { try validate(package) }
        #expect(error?.check == .textRoundTrip)
        #expect(error?.description.contains("GEN 1:1") == true)
    }

    @Test func aTamperedSearchTextFailsTheSearchTextCheck() throws {
        let package = try Built.copy(Built.bsbBinary)
        try SQLiteDatabase(path: package.path, mode: .readWrite).exec("UPDATE verses SET text_search = 'in the start' WHERE id = 1001001")
        let error = #expect(throws: PackageValidationError.self) { try validate(package) }
        #expect(error?.check == .searchText)
        #expect(Validate.exitCode(for: error!) == .failure)
    }

    @Test(arguments: [
        ("bsb", Script.latin, "beginning", VerseRef(.genesis, 1, 1)),
        ("wlc", .hebrew, "בְּרֵאשִׁית", VerseRef(.genesis, 1, 1)),
        ("wlc", .hebrew, "בראשית", VerseRef(.genesis, 1, 1)),
        ("tcgnt", .greek, "ἀρχῇ", VerseRef(.john, 1, 1)),
        ("tcgnt", .greek, "αρχη", VerseRef(.john, 1, 1)),
    ])
    func searchFindsTheVerseWithOrWithoutMarks(_ id: String, _ script: Script, _ query: String, _ expected: VerseRef) throws {
        let found = try SQLiteDatabase(path: Built.package(id).path, mode: .readOnly).rows(
            "SELECT rowid FROM verses_fts WHERE verses_fts MATCH ? ORDER BY rowid",
            [.text(SearchText.normalizeQuery(query, script: script))]
        )
        #expect(found.contains([.integer(PackageSchema.verseRowID(expected))]))
    }

    @Test func knownRowsHoldTheirText() throws {
        #expect(try scalar(Built.bsb, "SELECT text_plain FROM verses WHERE id = 1001001")
            == .text("In the beginning God created the heavens and the earth."))
        #expect(try scalar(Built.bsb, "SELECT text_search FROM verses WHERE id = 1001001") == .null)
        #expect(try scalar(Built.wlc, "SELECT text_search FROM verses WHERE id = 1001001") == .text("בראשית ברא אלהים את השמים ואת הארץ׃"))
        #expect(try scalar(Built.tcgnt, "SELECT value FROM meta WHERE key = 'absent_verses'")
            == .text(#"["LUK 17:36","ACT 8:37","ACT 15:34","ACT 24:7"]"#))
        #expect(try scalar(Built.wlc, "SELECT value FROM meta WHERE key = 'absent_verses'") == .text("[]"))
        #expect(try scalar(Built.bsb, "SELECT canon FROM edition")?.description.hasPrefix("'GEN EXO LEV") == true)
        #expect(try scalar(Built.bsb, "PRAGMA page_size") == .integer(4096))
        #expect(try scalar(Built.bsb, "PRAGMA journal_mode") == .text("delete"))
    }
}

@Suite struct EditionMetadataTests {
    private let lock = RealSources.lock!

    private func json(_ changes: [String: String] = [:]) -> Data {
        var fields = [
            "id": "bsb", "name": "Berean Standard Bible", "abbreviation": "BSB", "language": "en", "script": "Latn",
            "direction": "ltr", "versification": "eng", "license": "Public domain",
            "attribution": "Berean Standard Bible, Public Domain, bereanbible.com", "publisher": "Bible Hub", "source": "bsb",
        ]
        fields.merge(changes) { $1 }
        return try! JSONEncoder().encode(fields)
    }

    @Test(arguments: [("bsb", Script.latin, VersificationScheme.eng), ("wlc", .hebrew, .heb), ("tcgnt", .greek, .grc)])
    func everyEditionFileDecodesAgainstTheLock(_ id: String, _ script: Script, _ scheme: VersificationScheme) throws {
        let data = try Data(contentsOf: RealSources.repository.appending(path: "editions/\(id).json"))
        let metadata = try EditionMetadata(jsonData: data, lock: lock)
        #expect(metadata.id == id)
        #expect(metadata.source == id)
        #expect(metadata.script == script)
        #expect(metadata.direction == script.direction)
        #expect(metadata.versification == scheme)
        #expect(metadata.versification == Edition.named(id)?.scheme)
    }

    @Test func rejectsMetadataThatDisagreesWithItselfOrTheLock() {
        #expect(throws: EditionMetadataError.sourceNotLocked(id: "bsb", source: "kjv")) {
            try EditionMetadata(jsonData: json(["source": "kjv"]), lock: lock)
        }
        #expect(throws: EditionMetadataError.directionMismatch(id: "bsb", script: .latin, direction: .rtl)) {
            try EditionMetadata(jsonData: json(["direction": "rtl"]), lock: lock)
        }
        #expect(throws: EditionMetadataError.invalidID("BSB")) { try EditionMetadata(jsonData: json(["id": "BSB"]), lock: lock) }
        #expect(throws: EditionMetadataError.emptyField(id: "bsb", field: "attribution")) {
            try EditionMetadata(jsonData: json(["attribution": " "]), lock: lock)
        }
        #expect(throws: EditionMetadataError.self) { try EditionMetadata(jsonData: json(["versification": "lxx"]), lock: lock) }
        #expect(throws: EditionMetadataError.self) { try EditionMetadata(jsonData: json(["script": "Cyrl"]), lock: lock) }
    }

    @Test func buildRejectsBadOptions() throws {
        #expect(throws: (any Error).self) { try Build.parse(["bsb", "--version", "2026.13"]) }
        #expect(throws: (any Error).self) { try Build.parse(["bsb", "--built-at", "yesterday"]) }
        #expect(throws: (any Error).self) { try Build.parse(["bsb", "--encoding", "protobuf"]) }
        #expect(throws: (any Error).self) { try Build.parse(["bsb", "--version", "2026.10.01"]) }
        #expect(try Build.parse(["bsb", "--version", "2026.10.1"]).output.stamp.packageVersion.description == "2026.10.1")
        #expect(try Build.parse(["bsb", "--built-at", "2026-10-31T23:59:59Z"]).output.stamp.packageVersion.description == "2026.10")
    }
}
