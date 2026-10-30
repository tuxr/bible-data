import Foundation
import Testing
@testable import bible_pack

@Suite struct ZipWriterTests {
    private let entries: [(path: String, data: Data)] = [
        ("TAHOT_Gen-Deu_-_Translators_Amalgamated_Hebrew_OT_-_STEPBible.org_CC_BY.txt", Data("בְּרֵאשִׁית\tGen.1.1\n".utf8)),
        ("empty.txt", Data()),
        ("strongsgreek.xml", Data(repeating: 0x41, count: 70_000)),
    ]
    private let revision = utc("2026-10-24T00:00:00Z")

    @Test func readsBackThroughZipArchive() throws {
        let zip = try ZipArchive(ZipWriter.write(entries, modified: revision))

        #expect(zip.entries.map(\.path) == entries.map(\.path))
        #expect(zip.entries.allSatisfy { $0.method == .stored && $0.modified == revision })
        #expect(try zip.entries.map { try zip.contents(of: $0) } == entries.map(\.data))
        #expect(try zip.revisionDate() == "2026-10-24")
    }

    @Test func passesUnzipTest() throws {
        let unzip = URL(fileURLWithPath: "/usr/bin/unzip")
        guard FileManager.default.isExecutableFile(atPath: unzip.path) else { return }
        let file = FileManager.default.temporaryDirectory.appending(path: "zipwriter-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: file) }
        try ZipWriter.write(entries, modified: revision).write(to: file)

        let process = Process()
        process.executableURL = unzip
        process.arguments = ["-tq", file.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "unzip -t: \(text)")
        #expect(text.contains("No errors detected"))
    }

    @Test func sameEntriesAndTimeGiveIdenticalBytes() throws {
        let first = try ZipWriter.write(entries, modified: revision)
        #expect(try ZipWriter.write(entries, modified: revision) == first)
        #expect(try ZipWriter.write(entries, modified: utc("2026-10-25T00:00:00Z")) != first)
    }
}
