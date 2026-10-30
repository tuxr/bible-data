import ArgumentParser
import BibleFormat
import Foundation
import Testing
@testable import bible_pack

private let pinnedTime = "2026-10-30T00:00:00Z"
private let generatedAt = "2026-10-30T12:00:00Z"
private let policy = RealSources.repository.appending(path: "manifest/policy.json").path

/// The canon, the three editions, and the TCGNT words, built once per test run through the commands.
private enum Dist {
    static let root: URL = {
        let url = RealSources.repository.appending(path: ".build/manifest-tests", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: url)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let directory: URL = {
        let dist = root.appending(path: "dist", directoryHint: .isDirectory)
        let stamp = ["--built-at", pinnedTime, "--version", "2026.10"]
        let sources = [
            "--lock", RealSources.repository.appending(path: "sources.lock.json").path,
            "--sources-dir", RealSources.repository.appending(path: ".sources").path,
        ]
        let editions = ["--editions-dir", RealSources.repository.appending(path: "editions").path]
        do {
            try CanonCommand.Build.parse(["--out", dist.appending(path: "canon-2026.10.sqlite").path] + stamp).run()
            for edition in ["bsb", "wlc", "tcgnt"] {
                try Build.parse([edition, "--out", dist.path] + stamp + sources + editions).run()
            }
            try BuildWords.parse(["tcgnt", "--out", dist.path] + stamp + sources + editions).run()
        } catch {
            preconditionFailure("building the manifest test packages failed: \(error)")
        }
        return dist
    }()

    static let files = ["canon-2026.10.sqlite", "bsb-2026.10.bible", "tcgnt-2026.10.bible", "wlc-2026.10.bible", "tcgnt-2026.10.words"]

    static func scratch(_ name: String) -> URL {
        let url = root.appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Copies packages and their downloads from the built directory.
    static func copy(_ files: [String], to directory: URL) throws {
        for file in files {
            for name in [file, file + ".xz"] {
                try FileManager.default.copyItem(at: Dist.directory.appending(path: name), to: directory.appending(path: name))
            }
        }
    }
}

private func buildManifest(dist: URL, out: URL, merge: URL? = nil) async throws -> Manifest {
    var arguments = ["--dist", dist.path, "--out", out.path, "--generated-at", generatedAt, "--policy", policy]
    if let merge { arguments += ["--merge", merge.path] }
    try await ManifestCommand.Build.parse(arguments).run()
    return try Manifest(jsonData: try Data(contentsOf: out))
}

private func meta(_ url: URL) throws -> [String: String] {
    try PackageMeta.read(try SQLiteDatabase(path: url.path, mode: .readOnly))
}

private func strings(_ value: String?) -> [String]? { value.flatMap(MetaStrings.decode) }

@Suite(.enabled(if: RealSources.present, RealSources.skipMessage))
struct ManifestBuildTests {
    @Test func everyEntryIsWhatItsPackageFileSays() async throws {
        let manifest = try await buildManifest(dist: Dist.directory, out: Dist.scratch("fields").appending(path: "manifest.json"))
        #expect(manifest.packages.map(\.file) == Dist.files)
        #expect(manifest.packages.map(\.id) == ["canon", "bsb", "tcgnt", "wlc", "tcgnt-words"])
        #expect(manifest.generatedAt == generatedAt)
        #expect(manifest.baseURL == "https://bible.dws-cloud.com/data/")

        for entry in manifest.packages {
            let url = Dist.directory.appending(path: entry.file)
            let bytes = try Data(contentsOf: url)
            let compressed = try Data(contentsOf: Dist.directory.appending(path: entry.file + ".xz"))
            let meta = try meta(url)
            #expect(entry.url == entry.file + ".xz")
            #expect(entry.size == bytes.count)
            #expect(entry.sha256 == sha256Hex(bytes))
            #expect(entry.compressedSize == compressed.count)
            #expect(entry.compressedSha256 == sha256Hex(compressed))
            #expect(entry.kind.rawValue == meta["kind"])
            #expect(entry.version.description == meta["version"])
            #expect("\(entry.formatVersion)" == meta["format_version"])
            #expect(entry.released == String(meta["built_at"]!.prefix(10)))
            #expect(entry.minAppVersion == "1.0")

            switch entry.details {
            case .canon:
                #expect(entry.attribution == [meta["versification_attribution"]!])
            case .edition(let edition):
                let row = try #require(try SQLiteDatabase(path: url.path, mode: .readOnly).rows("""
                    SELECT id, name, abbreviation, language, script, direction, versification, license, attribution, publisher,
                           source_url, source_revision, source_sha256 FROM edition
                    """).first?.map(\.text))
                let fields: [String?] = [
                    entry.id, edition.name, edition.abbreviation, edition.language, edition.script.rawValue, edition.direction.rawValue,
                    edition.versification.rawValue, edition.license, entry.attribution.first, edition.publisher,
                    edition.source.url, edition.source.revision, edition.source.sha256,
                ]
                #expect(fields == row)
                #expect(entry.attribution.count == 1)
            case .words(let words):
                #expect(words.edition == meta["edition"])
                #expect(words.language == "grc")
                #expect(words.editionSourceSha256 == meta["edition_source_sha256"])
                #expect(words.sources == strings(meta["sources"]))
                #expect(entry.attribution == strings(meta["attribution"]))
            case .lexicon:
                Issue.record("no lexicon was built")
            }
        }

        let bsb = try #require(manifest.packages.first { $0.id == "bsb" })
        guard case .edition(let edition) = bsb.details else { Issue.record("bsb is not an edition"); return }
        #expect(edition.name == "Berean Standard Bible")
        #expect(edition.source.sha256 == RealSources.lock!.sources["bsb"]!.sha256)
    }

    @Test func isByteIdenticalForOnePinnedTime() async throws {
        let scratch = Dist.scratch("determinism")
        _ = try await buildManifest(dist: Dist.directory, out: scratch.appending(path: "a.json"))
        _ = try await buildManifest(dist: Dist.directory, out: scratch.appending(path: "b.json"))
        #expect(try Data(contentsOf: scratch.appending(path: "a.json")) == Data(contentsOf: scratch.appending(path: "b.json")))
    }

    @Test func mergeKeepsOldVersionsAndReplacesRebuiltOnes() async throws {
        let scratch = Dist.scratch("merge")
        let built = try await buildManifest(dist: Dist.directory, out: scratch.appending(path: "built.json"))
        let rebuilt = try #require(built.packages.first { $0.id == "bsb" })
        var stale = rebuilt
        stale.minAppVersion = "0.9"
        let old = ManifestEntry(
            id: "bsb", version: PackageVersion("2026.09")!, formatVersion: 1, minAppVersion: "1.0",
            size: 100, compressedSize: 50, sha256: String(repeating: "c", count: 64), compressedSha256: String(repeating: "d", count: 64),
            released: "2026-09-30", attribution: rebuilt.attribution, details: rebuilt.details
        )
        let published = Manifest(generatedAt: "2026-09-30T00:00:00Z", packages: [old, stale])
        let publishedURL = scratch.appending(path: "published.json")
        try published.jsonData().write(to: publishedURL)

        let merged = try await buildManifest(dist: Dist.directory, out: scratch.appending(path: "merged.json"), merge: publishedURL)
        #expect(merged.packages.count == built.packages.count + 1)
        #expect(merged.packages.contains(old))
        #expect(merged.packages.filter { $0.id == "bsb" }.map(\.version.description) == ["2026.10", "2026.09"])
        #expect(merged.packages.first { $0.file == rebuilt.file }?.minAppVersion == "1.0")

        var changed = rebuilt
        changed.sha256 = String(repeating: "e", count: 64)
        try Manifest(generatedAt: "2026-09-30T00:00:00Z", packages: [changed]).jsonData().write(to: publishedURL)
        await #expect(throws: PackageError.self) {
            _ = try await buildManifest(dist: Dist.directory, out: scratch.appending(path: "refused.json"), merge: publishedURL)
        }
    }

    @Test func refusesAFileNamedOtherThanItsMetaSays() async throws {
        let scratch = Dist.scratch("renamed")
        for name in ["bsb-2026.10.bible", "bsb-2026.10.bible.xz"] {
            try FileManager.default.copyItem(at: Dist.directory.appending(path: name), to: scratch.appending(path: name.replacingOccurrences(of: "2026.10", with: "2026.11")))
        }
        await #expect(throws: PackageError.self) { _ = try await buildManifest(dist: scratch, out: scratch.appending(path: "manifest.json")) }
    }

    @Test func validateDistPassesAndFailsByName() async throws {
        let full = Dist.scratch("validate")
        let manifestURL = full.appending(path: "manifest.json")
        let manifest = try await buildManifest(dist: Dist.directory, out: manifestURL)
        var passed: [ManifestDistCheck] = []
        try ManifestBuilder.verify(manifest, dist: Dist.directory) { check, _ in passed.append(check) }
        #expect(passed == ManifestDistCheck.allCases)
        try ManifestCommand.Validate.parse([manifestURL.path, "--dist", Dist.directory.path]).run()

        func failure(_ directory: URL) -> ManifestDistCheck? {
            do {
                try ManifestBuilder.verify(manifest, dist: directory) { _, _ in }
                return nil
            } catch {
                return (error as? ManifestDistError)?.check
            }
        }

        let partial = Dist.scratch("partial")
        try Dist.copy(["bsb-2026.10.bible"], to: partial)
        #expect(failure(partial) == nil)

        let truncated = Dist.scratch("truncated")
        try Dist.copy(["bsb-2026.10.bible"], to: truncated)
        let bsb = truncated.appending(path: "bsb-2026.10.bible")
        try Data(contentsOf: bsb).prefix(4096).write(to: bsb)
        #expect(failure(truncated) == .size)
        #expect(throws: ManifestDistError.self) { try ManifestCommand.Validate.parse([manifestURL.path, "--dist", truncated.path]).run() }

        let corrupt = Dist.scratch("corrupt")
        try Dist.copy(["bsb-2026.10.bible"], to: corrupt)
        let download = corrupt.appending(path: "bsb-2026.10.bible.xz")
        var bytes = try Data(contentsOf: download)
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: download)
        #expect(failure(corrupt) == .compressedSha256)

        let unpaired = Dist.scratch("unpaired")
        try Dist.copy(["bsb-2026.10.bible"], to: unpaired)
        try FileManager.default.removeItem(at: unpaired.appending(path: "bsb-2026.10.bible.xz"))
        #expect(failure(unpaired) == .pairs)

        let unlisted = Dist.scratch("unlisted")
        try Dist.copy(["bsb-2026.10.bible"], to: unlisted)
        let bsbOnly = Manifest(generatedAt: generatedAt, packages: manifest.packages.filter { $0.id == "bsb" })
        try Dist.copy(["canon-2026.10.sqlite"], to: unlisted)
        #expect(throws: ManifestDistError.self) { try ManifestBuilder.verify(bsbOnly, dist: unlisted) { _, _ in } }
    }
}
