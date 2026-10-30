import BibleFormat
import Foundation
import Testing

@Suite struct SourcesLockTests {
    private let bsb = LockedSource(
        format: .usfm,
        file: "bsb_usfm.zip",
        url: URL(string: "https://bereanbible.com/bsb_usfm.zip")!,
        revision: "2026-10-02",
        sha256: "f0c56438eb89c98e8f62c5c00461e25cc35b098ad5b179bc350cede759ee5f87",
        bytes: 1_598_038,
        scriptureSha256: "0bf20107f064fcb96c1a01dda6c1c39f6f6de06cd8ceaef39f6ff9af52aa216e",
        archive: URL(string: "https://github.com/tuxr/bible-data/releases/download/source-archive/bsb_usfm-2026-10-02-f0c56438.zip")!
    )

    @Test func writesSortedKeysTwoSpaceIndentAndTrailingNewline() {
        let json = String(decoding: SourcesLock(sources: ["bsb": bsb]).jsonData(), as: UTF8.self)
        #expect(json == """
        {
          "sources": {
            "bsb": {
              "archive": "https://github.com/tuxr/bible-data/releases/download/source-archive/bsb_usfm-2026-10-02-f0c56438.zip",
              "bytes": 1598038,
              "file": "bsb_usfm.zip",
              "format": "usfm",
              "revision": "2026-10-02",
              "scriptureSha256": "0bf20107f064fcb96c1a01dda6c1c39f6f6de06cd8ceaef39f6ff9af52aa216e",
              "sha256": "f0c56438eb89c98e8f62c5c00461e25cc35b098ad5b179bc350cede759ee5f87",
              "url": "https://bereanbible.com/bsb_usfm.zip"
            }
          },
          "version": 1
        }

        """)
    }

    @Test func roundTripIsByteIdentical() throws {
        var wlc = bsb
        wlc.format = .usfx
        wlc.file = "hboWLC_usfx.zip"
        let lock = SourcesLock(sources: ["wlc": wlc, "bsb": bsb])

        let first = lock.jsonData()
        let decoded = try SourcesLock(jsonData: first)
        #expect(decoded == lock)
        #expect(decoded.jsonData() == first)
    }

    @Test func emptyLockIsCompact() throws {
        let json = SourcesLock().jsonData()
        #expect(String(decoding: json, as: UTF8.self) == "{\n  \"sources\": {},\n  \"version\": 1\n}\n")
        #expect(try SourcesLock(jsonData: json) == SourcesLock())
    }

    @Test func rejectsAnotherVersion() {
        #expect(throws: SourcesLockError.unsupportedVersion(2)) {
            try SourcesLock(jsonData: Data(#"{"sources": {}, "version": 2}"#.utf8))
        }
    }

    @Test func archiveNameCarriesRevisionAndShaPrefix() {
        #expect(SourcesLock.archiveFileName(
            file: "engwebp_usfx.zip",
            revision: "2026-09-22",
            sha256: "c883ea0b8c9bdff4509ec5161f4380f947b94f742c84ffd0e76fa681f38cfa6b"
        ) == "engwebp_usfx-2026-09-22-c883ea0b.zip")
        #expect(SourcesLock.archiveURL(
            file: "engwebp_usfx.zip",
            revision: "2026-09-22",
            sha256: "c883ea0b8c9bdff4509ec5161f4380f947b94f742c84ffd0e76fa681f38cfa6b"
        ).absoluteString == "https://github.com/tuxr/bible-data/releases/download/source-archive/engwebp_usfx-2026-09-22-c883ea0b.zip")
    }
}
