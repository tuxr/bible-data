import BibleFormat
import Foundation

/// Reads built packages into manifest entries, merges them with a published manifest, and checks a manifest
/// against the files in a directory.
enum ManifestBuilder {
    static let packageExtensions: Set<String> = ["bible", "words", "lexicon", "sqlite"]

    /// The package files directly in `directory`, by name. Downloads, partial files, and the manifest are skipped.
    static func packageFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { packageExtensions.contains($0.pathExtension) }
            .sorted { $0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8) }
    }

    /// Every field from the package's own `meta` and `edition` rows and the bytes of it and its `.xz`, except
    /// `min_app_version`, which comes from the policy. Refuses a file whose name is not the one its `meta` gives.
    static func entry(for url: URL, policy: ManifestPolicy) throws -> ManifestEntry {
        let name = url.lastPathComponent
        func failure(_ reason: String) -> PackageError { PackageError(description: "\(name): \(reason)") }
        let database = try SQLiteDatabase(path: url.path, mode: .readOnly)
        let meta = try PackageMeta.read(database)
        func value(_ key: String) throws -> String {
            guard let value = meta[key], !value.isEmpty else { throw failure("meta.\(key) is missing") }
            return value
        }
        func strings(_ key: String) throws -> [String] {
            guard let strings = MetaStrings.decode(try value(key)) else { throw failure("meta.\(key) is not a JSON array of strings") }
            return strings
        }

        guard let kind = PackageKind(rawValue: try value(PackageKind.metaKey)) else { throw failure("meta.kind \(meta["kind"]!) is unknown") }
        guard let version = PackageVersion(try value("version")) else { throw failure("meta.version \(meta["version"]!) is not yyyy.mm or yyyy.mm.n") }
        guard let formatVersion = Int(try value("format_version")) else { throw failure("meta.format_version is not an integer") }
        guard let released = ManifestEntry.released(builtAt: try value("built_at")) else { throw failure("meta.built_at is not an ISO 8601 UTC time") }
        guard let minAppVersion = policy.minAppVersion(kind: kind, formatVersion: formatVersion) else {
            throw failure("the manifest policy has no min_app_version for \(kind.rawValue) format \(formatVersion)")
        }

        let id: String
        let attribution: [String]
        let details: ManifestEntry.Details
        switch kind {
        case .canon:
            (id, attribution, details) = ("canon", [try value("versification_attribution")], .canon)
        case .edition:
            let rows = try database.rows("""
                SELECT id, name, abbreviation, language, script, direction, versification, license, attribution, publisher,
                       source_url, source_revision, source_sha256 FROM edition
                """)
            let columns = rows.count == 1 ? rows[0].compactMap(\.text) : []
            guard columns.count == 13, let script = Script(rawValue: columns[4]), let direction = TextDirection(rawValue: columns[5]),
                  let versification = VersificationScheme(rawValue: columns[6]) else {
                throw failure("the edition table does not hold one row with a known script, direction, and versification")
            }
            id = columns[0]
            attribution = [columns[8]]
            details = .edition(ManifestEdition(
                name: columns[1], abbreviation: columns[2], language: columns[3], script: script, direction: direction,
                versification: versification, license: columns[7], publisher: columns[9],
                source: .init(url: columns[10], revision: columns[11], sha256: columns[12])
            ))
        case .words:
            let edition = try value("edition")
            guard let tagged = TaggedEdition(rawValue: edition) else { throw failure("meta.edition \(edition) is not a tagged edition") }
            id = "\(edition)-words"
            attribution = try strings("attribution")
            details = .words(ManifestWords(
                edition: edition, language: tagged.lexicon.code, editionSourceSha256: try value("edition_source_sha256"), sources: try strings("sources")
            ))
        case .lexicon:
            guard let language = LexiconLanguage(code: try value("language")) else { throw failure("meta.language \(meta["language"]!) is not grc or hbo") }
            id = "lexicon-\(language.rawValue)"
            attribution = try strings("attribution")
            details = .lexicon(ManifestLexicon(language: language.code, sources: try strings("sources")))
        }

        let compressedURL = PackageWriter.compressedURL(for: url)
        guard FileManager.default.fileExists(atPath: compressedURL.path) else { throw failure("has no \(compressedURL.lastPathComponent) beside it") }
        let package = try PackageFile(url)
        let compressed = try PackageFile(compressedURL)
        let entry = ManifestEntry(
            id: id, version: version, formatVersion: formatVersion, minAppVersion: minAppVersion,
            size: package.bytes, compressedSize: compressed.bytes, sha256: package.sha256, compressedSha256: compressed.sha256,
            released: released, attribution: attribution, details: details
        )
        guard entry.file == name else { throw failure("its meta names it \(entry.file); rename it or rebuild it") }
        return entry
    }

    /// The built entries, plus every published entry whose file was not rebuilt, so old versions stay listed.
    /// A rebuilt file must have the published bytes, because a published package never changes.
    static func merge(_ built: [ManifestEntry], into published: Manifest, baseURL: String) throws -> (packages: [ManifestEntry], kept: [ManifestEntry]) {
        guard published.baseURL == baseURL else {
            throw PackageError(description: "the published manifest's base_url is \(published.baseURL), not \(baseURL); its entries' urls would move")
        }
        let builtFiles = Dictionary(uniqueKeysWithValues: built.map { ($0.file, $0) })
        for old in published.packages {
            if let new = builtFiles[old.file], new.sha256 != old.sha256 {
                throw PackageError(description: "\(old.file) is published with sha256 \(old.sha256) but rebuilt as \(new.sha256); "
                    + "a published package never changes, so release the change under a new version")
            }
        }
        let kept = published.packages.filter { builtFiles[$0.file] == nil }
        return (built + kept, kept)
    }

    /// Reads a manifest from a path or an `https` URL. Nil when the URL answers 404, as before the first release.
    static func load(_ location: String, download: Download = HTTP.download) async throws -> Manifest? {
        let data: Data
        if location.hasPrefix("https://"), let url = URL(string: location) {
            do {
                data = try await download(url)
            } catch DownloadError.status(404, _) {
                return nil
            }
        } else {
            data = try Data(contentsOf: URL(fileURLWithPath: location))
        }
        return try Manifest(jsonData: data)
    }
}

/// The checks `manifest validate --dist` runs against the files in a directory, after the manifest's own.
enum ManifestDistCheck: String, CaseIterable, Sendable {
    case listed = "every package in dist is listed"
    case pairs = "package and download both present"
    case size
    case sha256
    case compressedSize = "compressed_size"
    case compressedSha256 = "compressed_sha256"
    case decompresses = "download decompresses to sha256"
}

struct ManifestDistError: Error, CustomStringConvertible {
    let check: ManifestDistCheck
    let message: String

    var description: String { "\(check.rawValue): \(message)" }
}

extension ManifestBuilder {
    /// Checks every entry whose files are in `dist` against them, and that every package there is listed.
    /// Entries for files elsewhere, such as versions published by earlier releases, are skipped.
    static func verify(_ manifest: Manifest, dist: URL, pass: (ManifestDistCheck, String) -> Void) throws {
        func check(_ check: ManifestDistCheck, _ detail: String, _ failure: String?) throws {
            if let failure { throw ManifestDistError(check: check, message: failure) }
            pass(check, detail)
        }
        let listedFiles = Set(manifest.packages.map(\.file))
        let files = try packageFiles(in: dist)
        try check(.listed, "\(files.count) packages", files.first { !listedFiles.contains($0.lastPathComponent) }.map {
            "\($0.lastPathComponent) is in \(dist.path) but not in the manifest"
        })

        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: dist.appending(path: name).path) }
        let present = manifest.packages.filter { exists($0.file) || exists($0.url) }
        try check(.pairs, "\(present.count) of \(manifest.packages.count) entries in dist", present.first { !exists($0.file) || !exists($0.url) }.map {
            "\($0.file) and \($0.url) must both be in \(dist.path), but only \(exists($0.file) ? $0.file : $0.url) is"
        })

        struct Observed {
            let entry: ManifestEntry
            let package: Data
            let compressed: Data
        }
        let observed = try present.map {
            Observed(entry: $0, package: try Data(contentsOf: dist.appending(path: $0.file)), compressed: try Data(contentsOf: dist.appending(path: $0.url)))
        }
        func first(_ failure: (Observed) -> String?) -> String? {
            for item in observed {
                if let message = failure(item) { return message }
            }
            return nil
        }
        let count = "\(observed.count) files"
        try check(.size, count, first { $0.package.count == $0.entry.size ? nil : "\($0.entry.file) is \($0.package.count) bytes, the manifest says \($0.entry.size)" })
        try check(.sha256, count, first {
            let actual = sha256Hex($0.package)
            return actual == $0.entry.sha256 ? nil : "\($0.entry.file) has sha256 \(actual), the manifest says \($0.entry.sha256)"
        })
        try check(.compressedSize, count, first {
            $0.compressed.count == $0.entry.compressedSize ? nil : "\($0.entry.url) is \($0.compressed.count) bytes, the manifest says \($0.entry.compressedSize)"
        })
        try check(.compressedSha256, count, first {
            let actual = sha256Hex($0.compressed)
            return actual == $0.entry.compressedSha256 ? nil : "\($0.entry.url) has sha256 \(actual), the manifest says \($0.entry.compressedSha256)"
        })
        try check(.decompresses, count, first { item in
            guard let inflated = try? PackageWriter.decompress(item.compressed) else { return "\(item.entry.url) does not decompress" }
            let actual = sha256Hex(inflated)
            return actual == item.entry.sha256 ? nil : "\(item.entry.url) decompresses to sha256 \(actual), the manifest says \(item.entry.sha256)"
        })
    }
}
