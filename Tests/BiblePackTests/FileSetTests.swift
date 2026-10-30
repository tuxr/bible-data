import BibleFormat
import CryptoKit
import Foundation
import Testing
@testable import bible_pack

private let sha = "be4191f0082aeedddb0eff0c02c966292b2bd641"
private let tree = "https://github.com/STEPBible/STEPBible-Data/tree/\(sha)"
private let raw = "https://raw.githubusercontent.com/STEPBible/STEPBible-Data/\(sha)"
private let api = URL(string: "https://api.github.com/repos/STEPBible/STEPBible-Data/commits/\(sha)")!
private let tahotName = "TAHOT_Gen-Deu_-_Translators_Amalgamated_Hebrew_OT_-_STEPBible.org_CC_BY.txt"
private let tahotURL = URL(string: "\(raw)/Translators%20Amalgamated%20OT%2BNT/TAHOT%20Gen-Deu%20-%20Translators%20Amalgamated%20Hebrew%20OT%20-%20STEPBible.org%20CC%20BY.txt")!
private let tbeshURL = URL(string: "\(raw)/Lexicons/TBESH.txt")!

private func hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func serving(_ files: [URL: Data]) -> Download {
    { url in
        guard let data = files[url] else { throw DownloadError.status(404, url: url) }
        return data
    }
}

private let upstream: [URL: Data] = [
    api: Data(#"{"sha": "\#(sha)", "commit": {"committer": {"date": "2026-10-24T10:54:54Z"}}}"#.utf8),
    tahotURL: Data("Gen.1.1\tבְּרֵאשִׁית\n".utf8),
    tbeshURL: Data("H0001\tאָב\tfather\n".utf8),
]

private func addition() throws -> SourceRequest {
    try SourceRequest.parseFiles(
        id: "step", repo: tree, urls: [tbeshURL.absoluteString, tahotURL.absoluteString],
        license: "CC BY 4.0", attribution: "STEPBible.org, Tyndale House Cambridge"
    )
}

private func locked() async throws -> (source: LockedSource, zipBytes: Data) {
    let empty = SourcesLock()
    let results = try await empty.relock(empty.requests(ids: [], additions: [addition()]), download: serving(upstream))
    return (results[0].source, results[0].zipBytes)
}

@Suite struct FileSetLockTests {
    @Test func setHashPrefixesEachNameInNameOrder() async throws {
        let (source, _) = try await locked()

        var expected = Data("TAHOT_Gen-Deu_-_Translators_Amalgamated_Hebrew_OT_-_STEPBible.org_CC_BY.txt\n".utf8)
        expected.append(upstream[tahotURL]!)
        expected.append(Data("TBESH.txt\n".utf8))
        expected.append(upstream[tbeshURL]!)
        #expect(source.sha256 == hex(expected))
        #expect(source.bytes == upstream[tahotURL]!.count + upstream[tbeshURL]!.count)
    }

    @Test func entryRecordsCommitRevisionMembersAndTheBuiltZip() async throws {
        let (source, zipBytes) = try await locked()

        #expect(source.file == "step.zip")
        #expect(source.url.absoluteString == tree)
        #expect(source.revision == "2026-10-24")
        #expect(source.archive?.lastPathComponent == "step-2026-10-24-\(source.sha256.prefix(8)).zip")
        guard case .files(let set) = source.kind else { Issue.record("expected a file set"); return }
        #expect(set.files == [
            LockedFile(name: tahotName, url: tahotURL, sha256: hex(upstream[tahotURL]!), bytes: upstream[tahotURL]!.count),
            LockedFile(name: "TBESH.txt", url: tbeshURL, sha256: hex(upstream[tbeshURL]!), bytes: upstream[tbeshURL]!.count),
        ])
        #expect(set.archiveSha256 == hex(zipBytes))
        let zip = try ZipArchive(zipBytes)
        #expect(zip.entries.map(\.path) == [tahotName, "TBESH.txt"])
        #expect(try zip.revisionDate() == "2026-10-24")
    }

    @Test func encodesWithSortedKeysAndRoundTrips() async throws {
        let (source, zipBytes) = try await locked()
        let lock = SourcesLock(sources: ["step": source])
        let json = String(decoding: lock.jsonData(), as: UTF8.self)

        #expect(json == """
        {
          "sources": {
            "step": {
              "archive": "https://github.com/tuxr/bible-data/releases/download/source-archive/step-2026-10-24-\(source.sha256.prefix(8)).zip",
              "archiveSha256": "\(hex(zipBytes))",
              "attribution": "STEPBible.org, Tyndale House Cambridge",
              "bytes": \(source.bytes),
              "file": "step.zip",
              "files": [
                {
                  "bytes": \(upstream[tahotURL]!.count),
                  "name": "\(tahotName)",
                  "sha256": "\(hex(upstream[tahotURL]!))",
                  "url": "\(tahotURL.absoluteString)"
                },
                {
                  "bytes": \(upstream[tbeshURL]!.count),
                  "name": "TBESH.txt",
                  "sha256": "\(hex(upstream[tbeshURL]!))",
                  "url": "\(tbeshURL.absoluteString)"
                }
              ],
              "format": "files",
              "license": "CC BY 4.0",
              "revision": "2026-10-24",
              "sha256": "\(source.sha256)",
              "url": "\(tree)"
            }
          },
          "version": 1
        }

        """)
        let decoded = try SourcesLock(jsonData: lock.jsonData())
        #expect(decoded == lock)
        #expect(decoded.jsonData() == lock.jsonData())
    }

    @Test func relockOfAPinnedSetIsUnchanged() async throws {
        let (source, _) = try await locked()
        let lock = SourcesLock(sources: ["step": source])

        let again = try await lock.relock(lock.requests(ids: [], additions: []), download: serving(upstream))
        #expect(again.map(\.change) == [.unchanged])
    }

    @Test func additionRejectsFilesFromAnotherCommitOrRepo() {
        let otherCommit = "https://raw.githubusercontent.com/STEPBible/STEPBible-Data/\(String(repeating: "0", count: 40))/Lexicons/TBESH.txt"
        let otherRepo = "https://raw.githubusercontent.com/openscriptures/strongs/\(sha)/hebrew/StrongHebrewG.xml"
        for url in [otherCommit, otherRepo, "https://github.com/STEPBible/STEPBible-Data/blob/\(sha)/Lexicons/TBESH.txt"] {
            #expect(throws: (any Error).self) {
                try SourceRequest.parseFiles(id: "step", repo: tree, urls: [url], license: "l", attribution: "a")
            }
        }
        #expect(throws: (any Error).self) {
            try SourceRequest.parseFiles(id: "step", repo: "https://github.com/STEPBible/STEPBible-Data/tree/master", urls: [tbeshURL.absoluteString], license: "l", attribution: "a")
        }
        #expect(throws: (any Error).self) {
            try SourceRequest.parseFiles(id: "step", repo: tree, urls: [tbeshURL.absoluteString, tbeshURL.absoluteString], license: "l", attribution: "a")
        }
    }
}

@Suite struct FileSetNameTests {
    @Test(arguments: [
        "TAHOT_Gen-Deu_-_Translators_Amalgamated_Hebrew_OT_-_STEPBible.org_CC_BY.txt",
        "TAGNT_Mat-Jhn_-_Translators_Amalgamated_Greek_NT_-_STEPBible.org_CC-BY.txt",
        "TBESG_-_Translators_Brief_lexicon_of_Extended_Strongs_for_Greek_-_STEPBible.org_CC_BY.txt",
        "1CO.csv",
    ])
    func acceptsPlainNames(name: String) {
        #expect(LockedFile.isValidName(name))
    }

    @Test(arguments: ["../x.txt", "dir/x.txt", "dir\\x.txt", ".hidden", "", "a b.txt", "a:b.txt"])
    func rejectsSeparatorsAndUnsafeNames(name: String) {
        #expect(!LockedFile.isValidName(name))
    }

    @Test func nameComesFromTheDecodedLastComponentWithUnderscores() {
        #expect(LockedFile.name(for: tahotURL) == tahotName)
        #expect(LockedFile.name(for: URL(string: "\(raw)/Lexicons/a%2Fb.txt")!) == nil)
    }

    private func lockJSON(id: String = "step", file: String = "step.zip", names: [String]) -> Data {
        let members = names.map { #"{"bytes": 1, "name": "\#($0)", "sha256": "00", "url": "https://raw.githubusercontent.com/o/r/x/\#($0)"}"# }
        return Data("""
        {"sources": {"\(id)": {"archive": "https://a/x.zip", "archiveSha256": "00", "attribution": "a", "bytes": 1, "file": "\(file)", \
        "files": [\(members.joined(separator: ", "))], "format": "files", "license": "l", "revision": "2026-01-01", \
        "sha256": "00", "url": "https://github.com/o/r/tree/x"}}, "version": 1}
        """.utf8)
    }

    @Test func lockAcceptsAWellFormedSet() throws {
        let lock = try SourcesLock(jsonData: lockJSON(names: [tahotName, "TBESH.txt"]))
        #expect(lock.sources["step"]?.formatName == "files")
    }

    @Test func lockRejectsAFileOtherThanIdDotZip() {
        #expect(throws: SourcesLockError.invalidFileName("other.zip")) {
            try SourcesLock(jsonData: lockJSON(file: "other.zip", names: ["a.txt"]))
        }
    }

    @Test func lockRejectsMemberNamesWithSeparators() {
        #expect(throws: SourcesLockError.invalidMemberName("../a.txt")) {
            try SourcesLock(jsonData: lockJSON(names: ["../a.txt"]))
        }
    }

    @Test func lockRejectsUnsortedOrDuplicateMembers() {
        #expect(throws: SourcesLockError.unsortedFileSet("step")) {
            try SourcesLock(jsonData: lockJSON(names: ["b.txt", "a.txt"]))
        }
        #expect(throws: SourcesLockError.unsortedFileSet("step")) {
            try SourcesLock(jsonData: lockJSON(names: ["a.txt", "a.txt"]))
        }
    }
}

@Suite struct FileSetFetchTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "bible-pack-tests-\(UUID().uuidString)")
    private var cache: SourceCache { SourceCache(directory: directory) }

    @Test func rebuildsFromMembersWhenTheArchiveIsMissing() async throws {
        let (source, zipBytes) = try await locked()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try await cache.fetch(source, download: serving(upstream)) == .fetched(from: .members))
        #expect(cache.contents(of: "step.zip") == zipBytes)
        #expect(try await cache.fetch(source, download: serving([:])) == .present)
    }

    @Test func rebuildDoesNotDependOnWhereTheArchiveLives() async throws {
        var (source, zipBytes) = try await locked()
        source.archive = URL(string: "https://example.org/elsewhere/step.zip")!
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try await cache.fetch(source, download: serving(upstream)) == .fetched(from: .members))
        #expect(cache.contents(of: "step.zip") == zipBytes)
    }

    @Test func prefersTheArchive() async throws {
        let (source, zipBytes) = try await locked()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try await cache.fetch(source, download: serving([source.archive!: zipBytes])) == .fetched(from: .archive))
        #expect(cache.contents(of: "step.zip") == zipBytes)
    }

    @Test func aChangedMemberFailsAndNamesIt() async throws {
        let (source, _) = try await locked()
        defer { try? FileManager.default.removeItem(at: directory) }
        var moved = upstream
        moved[tbeshURL] = Data("H0001\tאָב\tfather (revised)\n".utf8)

        let outcome = try await cache.fetch(source, download: serving(moved))

        guard case .failed(let problems) = outcome else { Issue.record("expected failure, got \(outcome)"); return }
        #expect(problems.count == 2)
        #expect(problems[1].hasPrefix("members: TBESH.txt sha256"))
        #expect(cache.contents(of: "step.zip") == nil)
    }

    @Test func anArchiveWithOtherBytesIsRejected() async throws {
        let (source, _) = try await locked()
        defer { try? FileManager.default.removeItem(at: directory) }
        let other = try ZipWriter.write([("TBESH.txt", Data("x".utf8))], modified: utc("2026-10-24T00:00:00Z"))

        let outcome = try await cache.fetch(source, download: serving([source.archive!: other]))

        guard case .failed(let problems) = outcome else { Issue.record("expected failure, got \(outcome)"); return }
        #expect(problems[0].hasPrefix("archive: sha256"))
    }
}

@Suite struct NotRedistributableTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "bible-pack-tests-\(UUID().uuidString)")

    private func lockedWithoutArchive() async throws -> (source: LockedSource, zipBytes: Data) {
        let request = try SourceRequest.parseFiles(
            id: "step", repo: tree, urls: [tbeshURL.absoluteString, tahotURL.absoluteString],
            license: "CC BY 4.0", attribution: "STEPBible.org, Tyndale House Cambridge", redistributable: false
        )
        let empty = SourcesLock()
        let results = try await empty.relock(empty.requests(ids: [], additions: [request]), download: serving(upstream))
        return (results[0].source, results[0].zipBytes)
    }

    @Test func locksNoArchiveAndSaysSoInTheJSON() async throws {
        let (source, _) = try await lockedWithoutArchive()
        #expect(source.archive == nil)
        let json = String(decoding: SourcesLock(sources: ["step": source]).jsonData(), as: UTF8.self)
        #expect(json.contains(#""redistributable": false,"#))
        #expect(!json.contains(#""archive":"#))
        #expect(try SourcesLock(jsonData: Data(json.utf8)).sources["step"] == source)
    }

    @Test func relockingKeepsTheSetUnarchived() async throws {
        let (source, _) = try await lockedWithoutArchive()
        let lock = SourcesLock(sources: ["step": source])
        let results = try await lock.relock(lock.requests(ids: ["step"], additions: []), download: serving(upstream))
        #expect(results[0].change == .unchanged)
        #expect(results[0].source.archive == nil)
    }

    @Test func fetchGoesStraightToTheMembers() async throws {
        let (source, zipBytes) = try await lockedWithoutArchive()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SourceCache(directory: directory)
        #expect(try await cache.fetch(source, download: serving(upstream)) == .fetched(from: .members))
        #expect(cache.contents(of: "step.zip") == zipBytes)

        try? FileManager.default.removeItem(at: directory)
        guard case .failed(let problems) = try await cache.fetch(source, download: serving([:])) else {
            Issue.record("expected a failure with no upstream")
            return
        }
        #expect(problems.count == 1)
        #expect(problems[0].hasPrefix("members:"))
    }

    @Test func theLockedSTEPBibleSetsAreNotRedistributable() throws {
        let lock = try #require(RealSources.lock)
        for id in ["tahot", "tagnt", "tbesg", "tbesh"] {
            #expect(lock.sources[id]?.archive == nil, "\(id)")
        }
        for id in ["byztxt", "strongs", "bsb", "wlc", "tcgnt"] {
            #expect(lock.sources[id]?.archive != nil, "\(id)")
        }
    }
}
