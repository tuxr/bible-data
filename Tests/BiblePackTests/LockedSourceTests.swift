import BibleFormat
import CryptoKit
import Foundation
import Testing
@testable import bible_pack

private func hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

@Suite struct LockedSourceTests {
    @Test func usfxScriptureHashCoversOnlyTheUSFXEntry() throws {
        let usfx = Data("<usfx><book id=\"MAT\"/></usfx>".utf8)
        let first = try ZipArchive(makeZip([
            TestZipEntry(path: "grctcgntmetadata.xml", bytes: Data("v1".utf8), method: 8),
            TestZipEntry(path: "grctcgnt_usfx.xml", bytes: usfx, method: 8),
        ]))
        let rezipped = try ZipArchive(makeZip([
            TestZipEntry(path: "grctcgntmetadata.xml", bytes: Data("v2".utf8)),
            TestZipEntry(path: "grctcgnt_usfx.xml", bytes: usfx),
        ]))

        let hash = try LockedSource.scriptureSha256(format: .usfx, zip: first, file: "grctcgnt_usfx.zip")
        #expect(hash == hex(usfx))
        #expect(try LockedSource.scriptureSha256(format: .usfx, zip: rezipped, file: "grctcgnt_usfx.zip") == hash)
    }

    @Test func usfxScriptureHashNeedsExactlyOneUSFXEntry() throws {
        let none = try ZipArchive(makeZip([TestZipEntry(path: "copr.htm", bytes: Data("c".utf8))]))
        let two = try ZipArchive(makeZip([
            TestZipEntry(path: "a_usfx.xml", bytes: Data("a".utf8)),
            TestZipEntry(path: "b_usfx.xml", bytes: Data("b".utf8)),
        ]))
        #expect(throws: ScriptureError.noUSFX(file: "x.zip")) {
            try LockedSource.scriptureSha256(format: .usfx, zip: none, file: "x.zip")
        }
        #expect(throws: ScriptureError.multipleUSFX(file: "x.zip", paths: ["a_usfx.xml", "b_usfx.xml"])) {
            try LockedSource.scriptureSha256(format: .usfx, zip: two, file: "x.zip")
        }
    }

    @Test func usfmScriptureHashPrefixesEachPathInSortedOrder() throws {
        let genesis = Data("\\id GEN\n\\c 1\n".utf8)
        let chronicles = Data("\\id 1CH\n\\c 1\n".utf8)
        let zip = try ZipArchive(makeZip([
            TestZipEntry(path: "bsb_usfm/", bytes: Data()),
            TestZipEntry(path: "bsb_usfm/GEN.usfm", bytes: genesis, method: 8),
            TestZipEntry(path: "bsb_usfm/1CH.usfm", bytes: chronicles, method: 8),
            TestZipEntry(path: "bsb_usfm/readme.txt", bytes: Data("not scripture".utf8)),
        ]))

        var expected = Data("bsb_usfm/1CH.usfm\n".utf8)
        expected.append(chronicles)
        expected.append(Data("bsb_usfm/GEN.usfm\n".utf8))
        expected.append(genesis)
        #expect(try LockedSource.scriptureSha256(format: .usfm, zip: zip, file: "bsb_usfm.zip") == hex(expected))
    }

    @Test func makeDerivesEveryFieldFromTheZip() throws {
        let usfx = Data("<usfx/>".utf8)
        let bytes = makeZip([TestZipEntry(path: "hboWLC_usfx.xml", bytes: usfx, method: 8, utc: utc("2026-08-08T10:00:00Z"))])
        let url = URL(string: "https://ebible.org/Scriptures/hboWLC_usfx.zip")!

        let source = try LockedSource.make(format: .usfx, url: url, zipBytes: bytes)

        let sha = hex(bytes)
        #expect(source == LockedSource(
            format: .usfx,
            file: "hboWLC_usfx.zip",
            url: url,
            revision: "2026-08-08",
            sha256: sha,
            bytes: bytes.count,
            scriptureSha256: hex(usfx),
            archive: URL(string: "https://github.com/tuxr/bible-data/releases/download/source-archive/hboWLC_usfx-2026-08-08-\(sha.prefix(8)).zip")!
        ))
    }
}
