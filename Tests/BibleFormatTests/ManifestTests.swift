import BibleFormat
import Foundation
import Testing

private let hashA = String(repeating: "a", count: 64)
private let hashB = String(repeating: "b", count: 64)

private func entry(_ details: ManifestEntry.Details, id: String, version: String = "2026.10", formatVersion: Int = 1) -> ManifestEntry {
    ManifestEntry(
        id: id, version: PackageVersion(version)!, formatVersion: formatVersion, minAppVersion: "1.0",
        size: 4096, compressedSize: 1024, sha256: hashA, compressedSha256: hashB,
        released: "2026-10-30", attribution: ["Credit"], details: details
    )
}

private func edition(_ id: String, version: String = "2026.10") -> ManifestEntry {
    entry(.edition(ManifestEdition(
        name: id.uppercased(), abbreviation: id.uppercased(), language: "en", script: .latin, direction: .ltr,
        versification: .eng, license: "Public domain", publisher: "Publisher",
        source: .init(url: "https://example.org/\(id).zip", revision: "2026-10-02", sha256: hashA)
    )), id: id, version: version)
}

private let canon = entry(.canon, id: "canon")
private let words = entry(.words(ManifestWords(edition: "wlc", language: "hbo", editionSourceSha256: hashB, sources: ["wlc", "oshb"])), id: "wlc-words")
private let lexicon = entry(.lexicon(ManifestLexicon(language: "grc", sources: ["tbesg", "strongs"])), id: "lexicon-greek")

private func manifest(_ packages: [ManifestEntry]) -> Manifest {
    Manifest(generatedAt: "2026-10-30T12:00:00Z", packages: packages)
}

/// The manifest as JSON objects, edited by `edit`, then decoded and checked.
private func decodeEdited(_ packages: [ManifestEntry], _ edit: (inout [String: Any]) -> Void) throws -> Manifest {
    var object = try JSONSerialization.jsonObject(with: manifest(packages).jsonData()) as! [String: Any]
    edit(&object)
    return try Manifest(jsonData: try JSONSerialization.data(withJSONObject: object))
}

private func failedCheck(_ packages: [ManifestEntry], _ edit: (inout [String: Any]) -> Void) -> ManifestCheck? {
    do {
        _ = try decodeEdited(packages, edit)
        return nil
    } catch let error as ManifestError {
        return error.check
    } catch {
        return nil
    }
}

private func editEntry(_ index: Int, _ edit: @escaping (inout [String: Any]) -> Void) -> (inout [String: Any]) -> Void {
    { object in
        var packages = object["packages"] as! [[String: Any]]
        edit(&packages[index])
        object["packages"] = packages
    }
}

@Suite struct ManifestTests {
    @Test func skipsEntriesOfAnUnknownKind() throws {
        let decoded = try decodeEdited([canon, edition("bsb")]) { object in
            var packages = object["packages"] as! [[String: Any]]
            packages.append(["id": "crossrefs", "kind": "crossrefs", "version": "2027.01", "file": "x", "url": "x.xz"])
            object["packages"] = packages
        }
        #expect(decoded.packages.map(\.id) == ["canon", "bsb"])
        #expect(decoded.unknownKinds == ["crossrefs"])
    }

    @Test func encodesAndDecodesEveryKind() throws {
        let original = manifest([lexicon, words, edition("bsb"), canon])
        let decoded = try Manifest(jsonData: original.jsonData())
        #expect(decoded == original)
        #expect(decoded.jsonData() == original.jsonData())
    }

    @Test func writesOneCanonicalByteForm() throws {
        let text = String(decoding: manifest([canon]).jsonData(), as: UTF8.self)
        #expect(text == """
            {
              "base_url": "https://bible.dws-cloud.com/data/",
              "generated_at": "2026-10-30T12:00:00Z",
              "manifest_version": 1,
              "packages": [
                {
                  "attribution": [
                    "Credit"
                  ],
                  "compressed_sha256": "\(hashB)",
                  "compressed_size": 1024,
                  "file": "canon-2026.10.sqlite",
                  "format_version": 1,
                  "id": "canon",
                  "kind": "canon",
                  "min_app_version": "1.0",
                  "released": "2026-10-30",
                  "sha256": "\(hashA)",
                  "size": 4096,
                  "url": "canon-2026.10.sqlite.xz",
                  "version": "2026.10"
                }
              ]
            }

            """)
    }

    @Test func flattensKindFieldsIntoTheEntryWithSortedKeys() throws {
        let object = try JSONSerialization.jsonObject(with: manifest([words]).jsonData()) as! [String: Any]
        let entry = (object["packages"] as! [[String: Any]])[0]
        #expect(entry["edition"] as? String == "wlc")
        #expect(entry["language"] as? String == "hbo")
        #expect(entry["edition_source_sha256"] as? String == hashB)
        #expect(entry["file"] as? String == "wlc-2026.10.words")
        let text = String(decoding: manifest([edition("bsb")]).jsonData(), as: UTF8.self)
        let keys = text.split(separator: "\n").filter { $0.hasPrefix("      \"") }.map { $0.split(separator: "\"")[1] }
        #expect(keys == keys.sorted())
        #expect(keys.contains("abbreviation") && keys.contains("versification") && keys.contains("source"))
    }

    @Test func listsByKindThenIdThenNewestVersion() {
        let listed = manifest([
            lexicon, words, edition("wlc"), edition("bsb", version: "2026.10"), edition("bsb", version: "2026.11"),
            edition("bsb", version: "2026.10.1"), canon,
        ]).packages
        #expect(listed.map { "\($0.id) \($0.version)" } == [
            "canon 2026.10", "bsb 2026.11", "bsb 2026.10.1", "bsb 2026.10", "wlc 2026.10", "wlc-words 2026.10", "lexicon-greek 2026.10",
        ])
    }

    @Test func derivesFileAndURLFromKindIdAndVersion() {
        #expect(edition("bsb", version: "2026.10.2").file == "bsb-2026.10.2.bible")
        #expect(edition("bsb").url == "bsb-2026.10.bible.xz")
        #expect(lexicon.file == "lexicon-greek-2026.10.lexicon")
        #expect(canon.url == "canon-2026.10.sqlite.xz")
    }

    @Test func parsesPackageVersions() {
        #expect(PackageVersion("2026.10")?.description == "2026.10")
        #expect(PackageVersion("2026.10.1")?.rebuild == 1)
        for bad in ["2026.13", "2026.1", "26.10", "2026.10.0", "2026.10.01", "2026.10.1000", "2026.10.", "v2026.10", "2026-10"] {
            #expect(PackageVersion(bad) == nil, "\(bad)")
        }
        #expect(PackageVersion("2026.10")! < PackageVersion("2026.10.1")!)
        #expect(PackageVersion("2026.10.9")! < PackageVersion("2026.10.10")!)
        #expect(PackageVersion("2026.12.3")! < PackageVersion("2027.01")!)
    }

    @Test func parsesThePolicy() throws {
        let policy = try ManifestPolicy(jsonData: Data(#"{"min_app_version": {"edition": {"1": "1.0", "2": "1.4.2"}, "canon": {"1": "1.0"}}}"#.utf8))
        #expect(policy.minAppVersion(kind: .edition, formatVersion: 2) == "1.4.2")
        #expect(policy.minAppVersion(kind: .canon, formatVersion: 1) == "1.0")
        #expect(policy.minAppVersion(kind: .words, formatVersion: 1) == nil)
        for bad in [
            #"{"min_app_version": {"audio": {"1": "1.0"}}}"#,
            #"{"min_app_version": {"edition": {"01": "1.0"}}}"#,
            #"{"min_app_version": {"edition": {"1": "1.0-beta"}}}"#,
            #"{"min_app_version": {"edition": {"1": "1.0"}}, "extra": {}}"#,
            #"{"min_app_version": {"edition": {"1": 1}}}"#,
        ] {
            #expect(throws: ManifestPolicyError.self, "\(bad)") { try ManifestPolicy(jsonData: Data(bad.utf8)) }
        }
    }

    @Test func theRepositoryPolicyCoversEveryKindAtTheCurrentFormat() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "manifest/policy.json")
        let policy = try ManifestPolicy(jsonData: try Data(contentsOf: url))
        for kind in PackageKind.allCases {
            #expect(policy.minAppVersion(kind: kind, formatVersion: kind.formatVersion) != nil, "\(kind)")
        }
    }

    @Test func rejectsAMalformedManifestByCheck() {
        let packages = [canon, edition("bsb"), words, lexicon]
        #expect(failedCheck(packages) { _ in } == nil)
        #expect(failedCheck(packages, editEntry(1) { $0["name"] = nil }) == .schema)
        #expect(failedCheck(packages, editEntry(2) { $0["edition_source_sha256"] = nil }) == .schema)
        #expect(failedCheck(packages, editEntry(1) { $0["version"] = "2026.1" }) == .schema)
        #expect(failedCheck(packages, editEntry(1) { $0["size"] = "4096" }) == .schema)
        #expect(failedCheck(packages) { $0["manifest_version"] = 2 } == .manifestVersion)
        #expect(failedCheck(packages) { $0["generated_at"] = "2026-10-30 12:00" } == .generatedAt)
        #expect(failedCheck(packages) { $0["base_url"] = "http://bible.dws-cloud.com/data/" } == .baseURL)
        #expect(failedCheck(packages) { $0["base_url"] = "https://bible.dws-cloud.com/data" } == .baseURL)
        #expect(failedCheck(packages, editEntry(1) { $0["id"] = "BSB" }) == .ids)
        #expect(failedCheck(packages, editEntry(2) { $0["id"] = "wlc" }) == .ids)
        #expect(failedCheck(packages, editEntry(3) { $0["language"] = "la" }) == .ids)
        #expect(failedCheck(packages, editEntry(1) { $0["url"] = "https://elsewhere.example/bsb-2026.10.bible.xz" }) == .files)
        #expect(failedCheck(packages, editEntry(1) { $0["url"] = "/bsb-2026.10.bible.xz" }) == .files)
        #expect(failedCheck(packages, editEntry(1) { $0["file"] = "bsb.bible" }) == .files)
        #expect(failedCheck(packages, editEntry(1) { $0["released"] = "2026-02-30" }) == .released)
        #expect(failedCheck(packages, editEntry(1) { $0["compressed_size"] = 0 }) == .sizes)
        #expect(failedCheck(packages, editEntry(1) { $0["sha256"] = hashA.uppercased() }) == .hashes)
        #expect(failedCheck(packages, editEntry(2) { $0["edition_source_sha256"] = "abc" }) == .hashes)
        #expect(failedCheck(packages, editEntry(0) { $0["attribution"] = [String]() }) == .attribution)
        #expect(failedCheck(packages, editEntry(0) { $0["min_app_version"] = "1.0-beta" }) == .minAppVersion)
        #expect(failedCheck(packages) { object in
            var entries = object["packages"] as! [[String: Any]]
            entries.swapAt(0, 1)
            object["packages"] = entries
        } == .order)
        #expect(failedCheck(packages) { object in
            var entries = object["packages"] as! [[String: Any]]
            entries.insert(entries[1], at: 1)
            object["packages"] = entries
        } == .unique)
    }

    @Test func requiresTheNewestVersionOfEachIdInASupportedFormat() {
        let future = entry(edition("bsb", version: "2026.11").details, id: "bsb", version: "2026.11", formatVersion: PackageFormat.version + 1)
        #expect(throws: ManifestError(check: .formatVersion, message: "bsb 2026.11 has format_version \(PackageFormat.version + 1), expected 1 to \(PackageFormat.version)")) {
            try manifest([future, edition("bsb")]).check { _, _ in }
        }
        let older = entry(edition("bsb", version: "2026.09").details, id: "bsb", version: "2026.09", formatVersion: PackageFormat.version + 1)
        #expect(throws: Never.self) { try manifest([older, edition("bsb")]).check { _, _ in } }
    }

    @Test func passesEveryCheckInOrder() throws {
        var passed: [ManifestCheck] = []
        try manifest([canon, edition("bsb"), words, lexicon]).check { check, _ in passed.append(check) }
        #expect(passed == Array(ManifestCheck.allCases.dropFirst()))
    }
}
