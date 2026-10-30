import BibleFormat
import Foundation
import Testing
@testable import bible_pack

private let upstream = URL(string: "https://ebible.org/Scriptures/grctcgnt_usfx.zip")!

private func tcgnt(_ text: String, on day: String, metadata: String = "m") -> Data {
    makeZip([
        TestZipEntry(path: "grctcgntmetadata.xml", bytes: Data(metadata.utf8)),
        TestZipEntry(path: "grctcgnt_usfx.xml", bytes: Data(text.utf8), method: 8, utc: utc("\(day)T12:00:00Z")),
    ])
}

private func serving(_ files: [URL: Data]) -> Download {
    { url in
        guard let data = files[url] else { throw DownloadError.status(404, url: url) }
        return data
    }
}

@Suite struct RelockTests {
    @Test func addThenRelockUnchangedThenChanged() async throws {
        let first = tcgnt("<usfx>v1</usfx>", on: "2026-09-24")
        let addition = try SourceRequest.parseAddition("tcgnt:usfx:\(upstream.absoluteString)")

        let empty = SourcesLock()
        let added = try await empty.relock(empty.requests(ids: [], additions: [addition]), download: serving([upstream: first]))
        #expect(added.map(\.change) == [.added])
        let lock = empty.applying(added)

        let again = try await lock.relock(lock.requests(ids: [], additions: []), download: serving([upstream: first]))
        #expect(again.map(\.change) == [.unchanged])
        #expect(lock.applying(again).jsonData() == lock.jsonData())

        let second = tcgnt("<usfx>v2</usfx>", on: "2026-10-28")
        let changed = try await lock.relock(lock.requests(ids: ["tcgnt"], additions: []), download: serving([upstream: second]))
        #expect(changed.map(\.change) == [.changed(from: lock.sources["tcgnt"]!)])
        #expect(lock.applying(changed).sources["tcgnt"]?.revision == "2026-10-28")
        #expect(changed[0].line.hasPrefix("2026-10-28"))
        #expect(changed[0].line.contains("changed from 2026-09-24"))
    }

    @Test func selectionRejectsUnknownAndAlreadyLockedIds() throws {
        let lock = SourcesLock(sources: ["tcgnt": try LockedSource.make(format: .usfx, url: upstream, zipBytes: tcgnt("t", on: "2026-09-24"))])
        let duplicate = SourceRequest(id: "tcgnt", spec: .zip(.usfx, upstream))

        #expect(throws: SelectionError.unknownSource("kjv", known: ["tcgnt"])) { try lock.requests(ids: ["kjv"], additions: []) }
        #expect(throws: SelectionError.alreadyLocked("tcgnt")) { try lock.requests(ids: [], additions: [duplicate]) }
        #expect(throws: SelectionError.nothingLocked) { try SourcesLock().locked(ids: []) }
    }

    @Test func additionParsesURLsContainingColons() throws {
        let request = try SourceRequest.parseAddition("bsb:usfm:https://bereanbible.com:443/bsb_usfm.zip")
        #expect(request == SourceRequest(id: "bsb", spec: .zip(.usfm, URL(string: "https://bereanbible.com:443/bsb_usfm.zip")!)))
        #expect(throws: (any Error).self) { try SourceRequest.parseAddition("bsb:osis:https://bereanbible.com/bsb_usfm.zip") }
        #expect(throws: (any Error).self) { try SourceRequest.parseAddition("BSB:usfm:https://bereanbible.com/bsb_usfm.zip") }
        #expect(throws: (any Error).self) { try SourceRequest.parseAddition("bsb:usfm:https://bereanbible.com/download") }
    }
}

@Suite struct FetchTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "bible-pack-tests-\(UUID().uuidString)")
    private var cache: SourceCache { SourceCache(directory: directory) }

    @Test func fallsBackToUpstreamWhenArchiveIsMissing() async throws {
        let zip = tcgnt("<usfx/>", on: "2026-09-24")
        let source = try LockedSource.make(format: .usfx, url: upstream, zipBytes: zip)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try await cache.fetch(source, download: serving([upstream: zip])) == .fetched(from: .url))
        #expect(cache.contents(of: source.file) == zip)
        #expect(try await cache.fetch(source, download: serving([:])) == .present)
    }

    @Test func prefersTheArchive() async throws {
        let zip = tcgnt("<usfx/>", on: "2026-09-24")
        let source = try LockedSource.make(format: .usfx, url: upstream, zipBytes: zip)
        defer { try? FileManager.default.removeItem(at: directory) }

        let moved = tcgnt("<usfx>newer</usfx>", on: "2026-10-28")
        #expect(try await cache.fetch(source, download: serving([source.archive: zip, upstream: moved])) == .fetched(from: .archive))
        #expect(cache.contents(of: source.file) == zip)
    }

    @Test func mismatchFailsAndLeavesNoBadFileButKeepsItsBytes() async throws {
        let locked = tcgnt("<usfx>locked</usfx>", on: "2026-09-24")
        let source = try LockedSource.make(format: .usfx, url: upstream, zipBytes: locked)
        let moved = tcgnt("<usfx>newer</usfx>", on: "2026-10-28")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try moved.write(to: cache.path(of: source.file))

        let outcome = try await cache.fetch(source, download: serving([upstream: moved]))

        guard case .failed(let problems) = outcome else { Issue.record("expected failure, got \(outcome)"); return }
        #expect(problems.count == 2)
        #expect(cache.contents(of: source.file) == nil)
        let kept = directory.appending(path: "archive/grctcgnt_usfx-2026-10-28-\(sha256Hex(moved).prefix(8)).zip")
        #expect(try Data(contentsOf: kept) == moved)
    }

    @Test func storingANewRevisionArchivesTheOldOne() throws {
        let old = tcgnt("<usfx>old</usfx>", on: "2026-09-24")
        let new = tcgnt("<usfx>new</usfx>", on: "2026-10-28")
        defer { try? FileManager.default.removeItem(at: directory) }

        try cache.store(old, as: "grctcgnt_usfx.zip")
        try cache.store(new, as: "grctcgnt_usfx.zip")

        #expect(cache.contents(of: "grctcgnt_usfx.zip") == new)
        let archived = directory.appending(path: "archive/grctcgnt_usfx-2026-09-24-\(sha256Hex(old).prefix(8)).zip")
        #expect(try Data(contentsOf: archived) == old)
    }
}
