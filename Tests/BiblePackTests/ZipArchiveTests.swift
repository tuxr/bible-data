import CryptoKit
import Foundation
import Testing
@testable import bible_pack

@Suite struct ZipArchiveTests {
    @Test func extractsStoredAndDeflatedEntries() throws {
        let text = Data(String(repeating: "In the beginning God created the heavens and the earth. ", count: 200).utf8)
        let zip = try ZipArchive(makeZip([
            TestZipEntry(path: "stored.txt", bytes: Data("stored bytes".utf8), method: 0),
            TestZipEntry(path: "book/GEN.usfm", bytes: text, method: 8),
            TestZipEntry(path: "empty.txt", bytes: Data(), method: 8),
        ]))

        #expect(zip.entries.map(\.path) == ["stored.txt", "book/GEN.usfm", "empty.txt"])
        #expect(try zip.contents(of: zip.entries[0]) == Data("stored bytes".utf8))
        #expect(try zip.contents(of: zip.entries[1]) == text)
        #expect(try zip.contents(of: zip.entries[2]) == Data())
    }

    @Test func revisionPrefersExtendedTimestampOverDOSTime() throws {
        let later = TestZipEntry(
            path: "a.xml", bytes: Data("a".utf8),
            dos: DOSTime(year: 2026, month: 10, day: 1, hour: 23, minute: 30, second: 0),
            utc: utc("2026-10-02T05:30:00Z")
        )
        let earlier = TestZipEntry(
            path: "b.xml", bytes: Data("b".utf8),
            dos: DOSTime(year: 2026, month: 10, day: 2, hour: 1, minute: 0, second: 0),
            utc: utc("2026-10-01T18:00:00Z")
        )
        #expect(try ZipArchive(makeZip([later])).revisionDate() == "2026-10-02")
        #expect(try ZipArchive(makeZip([earlier])).revisionDate() == "2026-10-01")
    }

    @Test func revisionFallsBackToDOSTimeAsUTC() throws {
        let entry = TestZipEntry(
            path: "a.xml", bytes: Data("a".utf8),
            dos: DOSTime(year: 2026, month: 3, day: 8, hour: 23, minute: 59, second: 58)
        )
        #expect(try ZipArchive(makeZip([entry])).revisionDate() == "2026-03-08")
    }

    @Test func revisionIsTheNewestEntry() throws {
        let zip = try ZipArchive(makeZip([
            TestZipEntry(path: "old.usfm", bytes: Data("1".utf8), dos: DOSTime(year: 2026, month: 3, day: 8, hour: 12, minute: 42, second: 0)),
            TestZipEntry(path: "new.usfm", bytes: Data("2".utf8), utc: utc("2026-10-02T16:00:00Z")),
            TestZipEntry(path: "mid.usfm", bytes: Data("3".utf8), utc: utc("2026-07-31T16:25:35Z")),
        ]))
        #expect(try zip.revisionDate() == "2026-10-02")
    }

    @Test func rejectsZip64() {
        let zip = makeZip([TestZipEntry(path: "big.xml", bytes: Data("x".utf8), zip64Sizes: true)])
        #expect(throws: ZipError.zip64Unsupported) { try ZipArchive(zip) }
    }

    @Test func rejectsUnsupportedCompressionMethod() {
        let zip = makeZip([TestZipEntry(path: "bzip2.xml", bytes: Data("x".utf8), method: 12)])
        #expect(throws: ZipError.unsupportedMethod(12, path: "bzip2.xml")) { try ZipArchive(zip) }
        #expect(ZipError.unsupportedMethod(12, path: "bzip2.xml").description.contains("bzip2.xml"))
    }

    @Test func rejectsBytesThatAreNotAZip() {
        #expect(throws: ZipError.notAZip) { try ZipArchive(Data("<html>Not Found</html>".utf8)) }
    }
}
