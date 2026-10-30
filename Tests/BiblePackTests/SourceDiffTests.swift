import ArgumentParser
import BibleFormat
import Foundation
import Testing
@testable import bible_pack

/// One chapter of John, each verse a paragraph with one run.
private func john(_ verses: [(Int, String)], notes: [ParsedNote] = [], absent: [VerseRef] = []) -> ParsedEdition {
    var items: [ChapterItem] = []
    for (number, text) in verses {
        items += [paragraph, verse(number), run(text)]
    }
    let chapter = ParsedChapter(chapter: Chapter(book: .john, number: 1, items: items), notes: notes, words: [])
    return edition(ParsedBook(book: .john, name: "John", shortName: "John", chapters: [chapter], absentVerses: absent))
}

private func edition(_ books: ParsedBook...) -> ParsedEdition {
    ParsedEdition(books: books, report: ParseReport())
}

private func diff(_ old: ParsedEdition, _ new: ParsedEdition, script: Script = .latin) -> EditionDiff {
    let side = EditionDiff.Side(file: "x.zip", revision: "2026-10-30", sha256: String(repeating: "0", count: 64), warnings: [])
    return EditionDiff(edition: "test", script: script, from: side, old: old, to: side, new: new)
}

private func kinds(_ diff: EditionDiff) -> [String] {
    diff.verses.map { "\($0.ref) \($0.kind.rawValue)" }
}

@Suite struct VerseClassifierTests {
    @Test func everyLatinKind() {
        let old = john([
            (1, "In the beginning was the Word."),
            (2, "He was with God in the beginning."),
            (3, "Through him all things were made."),
            (4, "In him was life."),
            (6, "There came a man sent from God."),
        ])
        var new = john([
            (1, "In the beginning was the Word;"),
            (2, "He was with God at the beginning."),
            (3, "Through him all things were made."),
            (5, "The light shines in the darkness."),
            (7, "There came a man sent from God."),
        ])
        // Verse 3 keeps its text but its run becomes words of Jesus.
        let styled = new.books[0].chapters[0].chapter.items.map { item -> ChapterItem in
            if case .text(let run) = item, run.text.hasPrefix("Through") { return .text(Run(run.text, style: .wordsOfJesus)) }
            return item
        }
        new = edition(ParsedBook(
            book: .john, name: "John", shortName: "John",
            chapters: [ParsedChapter(chapter: Chapter(book: .john, number: 1, items: styled), notes: [], words: [])],
            absentVerses: []
        ))

        let result = diff(old, new)
        #expect(kinds(result) == [
            "JHN 1:1 punctuation", "JHN 1:2 wording", "JHN 1:3 markup", "JHN 1:4 removed", "JHN 1:5 added", "JHN 1:7 moved",
        ])
        #expect(result.verses.last?.movedFrom == "JHN 1:6")
        #expect(result.verses[2].markup?.added == ["text «Through him all things were made.»{wj}"])
        #expect(!result.identical)
    }

    @Test func caseCountsAsWording() {
        #expect(kinds(diff(john([(1, "the Word")]), john([(1, "the word")]))) == ["JHN 1:1 wording"])
    }

    @Test func repeatedTextIsNotAMove() {
        let old = john([(1, "one gold dish"), (2, "one silver bowl")])
        let new = john([(1, "one gold dish"), (2, "one gold dish")])
        #expect(kinds(diff(old, new)) == ["JHN 1:2 wording"])
    }

    @Test func hebrewPointingAndPunctuation() {
        // Genesis 1:1 with its sof pasuq, then with one qamats changed to a patah, then with the sof pasuq dropped.
        let pointed = "בְּרֵאשִׁ֖ית בָּרָ֣א אֱלֹהִ֑ים אֵ֥ת הַשָּׁמַ֖יִם וְאֵ֥ת הָאָֽרֶץ׃"
        let repointed = "בְּרֵאשִׁ֖ית בַּרָ֣א אֱלֹהִ֑ים אֵ֥ת הַשָּׁמַ֖יִם וְאֵ֥ת הָאָֽרֶץ׃"
        let unpunctuated = "בְּרֵאשִׁ֖ית בָּרָ֣א אֱלֹהִ֑ים אֵ֥ת הַשָּׁמַ֖יִם וְאֵ֥ת הָאָֽרֶץ"
        let maqaf = "בְּרֵאשִׁ֖ית בָּרָ֣א אֱלֹהִ֑ים אֵ֥ת־הַשָּׁמַ֖יִם וְאֵ֥ת הָאָֽרֶץ׃"
        let reworded = "בְּרֵאשִׁ֖ית בָּרָ֣א אֱלֹהִ֑ים אֵ֥ת הַשָּׁמַ֖יִם וְאֵ֥ת הָאָֽדָם׃"
        let old = john([(1, pointed), (2, pointed), (3, pointed), (4, pointed)])
        let new = john([(1, repointed), (2, unpunctuated), (3, maqaf), (4, reworded)])
        #expect(kinds(diff(old, new, script: .hebrew)) == [
            "JHN 1:1 pointing", "JHN 1:2 punctuation", "JHN 1:3 punctuation", "JHN 1:4 wording",
        ])
    }

    @Test func greekAccentsAndPunctuation() {
        let old = john([
            (1, "ὁ μένων ἐν ἐμοί, κἀγὼ ἐν αὐτῷ"),
            (2, "τότε ἐξελθὼν. και εκειθεν μετὰ"),
            (3, "τίς ἐστιν"),
            (4, "τὸ Μικρόν; οὐκ οἴδαμεν"),
        ])
        let new = john([
            (1, "ὁ μένων ἐν ἐμοὶ κἀγὼ ἐν αὐτῷ"),
            (2, "τότε ἐξελθὼν. καὶ ἐκεῖθεν μετὰ"),
            (3, "τὶς ἐστιν"),
            (4, "τὸ μικρόν; οὐκ οἴδαμεν"),
        ])
        #expect(kinds(diff(old, new, script: .greek)) == [
            "JHN 1:1 punctuation", "JHN 1:2 pointing", "JHN 1:3 pointing", "JHN 1:4 wording",
        ])
    }

    @Test func notesBookNamesAndCounts() {
        func note(_ verse: Int, _ number: Int, _ text: String) -> ParsedNote {
            ParsedNote(verse: verse, number: number, kind: .footnote, caller: "a", text: text, targets: [])
        }
        let old = john(
            [(1, "a"), (2, "b")],
            notes: [note(2, 1, "ουν ʙ680 ᴏ11 ¦ δε ʙ364 ᴏ2"), note(2, 2, "πρωι ʙ543 ᴏ9 58.2% ¦ πρωια ʙ438 ᴏ2 ᴛʀ 36.4%")]
        )
        let new = john(
            [(1, "a")],
            notes: [note(2, 1, "πρωι 58.2% ¦ πρωια ᴛʀ 36.4%")],
            absent: [VerseRef(.john, 1, 2)]
        )
        let result = diff(old, new)
        #expect(result.notes.map(\.change) == [.removed, .changed])
        #expect(result.notes[1].to == "footnote: πρωι 58.2% ¦ πρωια ᴛʀ 36.4%")
        #expect(result.books.count == 1)
        #expect(result.books[0].verses?.from == 2 && result.books[0].verses?.to == 1)
        #expect(result.books[0].absentAdded == ["JHN 1:2"])
        #expect(result.books[0].chapters == nil)
    }

    @Test func aChapterAgainstItselfIsIdentical() {
        let same = john([(1, "In the beginning was the Word.")])
        #expect(diff(same, same).identical)
    }
}

@Suite struct DiffMarkerTests {
    @Test func textMarksChangedWordsOnBothLines() {
        let lines = DiffReport.changedText("ἀμὴν λέγω ὑμῖν, oὐκ ἔστι", "ἀμὴν λέγω ὑμῖν, οὐκ ἔστι", marks: .text)
        #expect(lines.map(\.text) == [
            "ἀμὴν λέγω ὑμῖν, [-oὐκ-] ἔστι",
            "ἀμὴν λέγω ὑμῖν, {+οὐκ+} ἔστι",
            "oὐκ to οὐκ: U+006F LATIN SMALL LETTER O to U+03BF GREEK SMALL LETTER OMICRON",
        ])
    }

    @Test func markdownMarksAndEscapes() {
        let lines = DiffReport.changedText("the *only* son, who is", "the only son who is", marks: .markdown)
        #expect(lines[0].text == "the ~~\\*only\\* son,~~ who is")
        #expect(lines[1].text == "the **only son** who is")
    }

    @Test func markdownCodeSpansOutrunTheirContentsBackticks() {
        #expect(DiffReport.Marks.markdown.code("plain") == "`plain`")
        #expect(DiffReport.Marks.markdown.code("a `b` c") == "`` a `b` c ``")
        #expect(DiffReport.Marks.markdown.code("x ``` y") == "```` x ``` y ````")
    }

    @Test func markdownCapsEachKind() {
        let old = john((1...5).map { ($0, "verse \($0) text") })
        let new = john((1...5).map { ($0, "verse \($0) words") })
        let markdown = DiffReport.markdown(diff(old, new), limit: 2)
        #expect(markdown.contains("#### Wording (5)"))
        #expect(markdown.contains("**JHN 1:2**"))
        #expect(!markdown.contains("**JHN 1:3**"))
        #expect(markdown.contains("And 3 more wording verses; the JSON diff lists every one."))
    }
}

/// The command against a lock and an edition file in a scratch directory, so its exit codes are what a workflow sees.
@Suite struct SourcesDiffCommandTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "bible-pack-diff-\(UUID().uuidString)")

    private func usfx(_ verse: String) -> Data {
        let xml = """
        <usfx><book id="3JN"><h>Γ΄ Ἰωάννου</h><c id="1" /><p><v id="1" />\(verse)</p></book></usfx>
        """
        return makeZip([TestZipEntry(path: "grctcgnt_usfx.xml", bytes: Data(xml.utf8), utc: utc("2026-10-28T12:00:00Z"))])
    }

    private func setUp(locked: Data) throws -> [String] {
        let editions = directory.appending(path: "editions")
        try FileManager.default.createDirectory(at: editions, withIntermediateDirectories: true)
        let source = try LockedSource.make(format: .usfx, url: URL(string: "https://ebible.org/Scriptures/grctcgnt_usfx.zip")!, zipBytes: locked)
        try SourcesLock(sources: ["tcgnt": source]).jsonData().write(to: directory.appending(path: "sources.lock.json"))
        try FileManager.default.copyItem(at: RealSources.repository.appending(path: "editions/tcgnt.json"), to: editions.appending(path: "tcgnt.json"))
        try SourceCache(directory: directory.appending(path: "sources")).store(locked, as: source.file)
        return ["--lock", directory.appending(path: "sources.lock.json").path, "--sources-dir", directory.appending(path: "sources").path,
                "--editions-dir", editions.path]
    }

    private func exitCode(_ arguments: [String]) async throws -> Int32 {
        let command = try SourcesCommand.Diff.parse(arguments)
        do {
            try await command.run()
            return 0
        } catch let exit as ExitCode {
            return exit.rawValue
        }
    }

    @Test func exitsZeroWhenIdenticalTwoWhenNotOneOnError() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let locked = usfx("ὁ πρεσβύτερος Γαΐῳ τῷ ἀγαπητῷ.")
        let options = try setUp(locked: locked)
        let same = directory.appending(path: "same.zip"), edited = directory.appending(path: "edited.zip")
        try locked.write(to: same)
        try usfx("ὁ πρεσβύτερος Γαΐῳ τῷ φίλῳ.").write(to: edited)

        #expect(try await exitCode(["tcgnt", "--to", same.path] + options) == 0)
        #expect(try await exitCode(["tcgnt", "--to", edited.path, "--format", "json"] + options) == 2)
        #expect(try await exitCode(["tcgnt", "--to", directory.appending(path: "missing.zip").path] + options) == 1)
        #expect(try await exitCode(["oshb", "--to", same.path] + options) == 1)
    }
}

/// The locked TCGNT against itself and against a copy with one word of John 11:35 changed.
@Suite(.enabled(if: RealSources.present, RealSources.skipMessage))
struct RealSourceDiffTests {
    private func lockedZip() throws -> (lock: SourcesLock, bytes: Data) {
        let lock = RealSources.lock!
        return (lock, RealSources.cache.contents(of: lock.sources["tcgnt"]!.file)!)
    }

    private func compare(_ old: Data, _ new: Data) throws -> EditionDiff {
        let (lock, _) = try lockedZip()
        let edition = Edition.named("tcgnt")!
        func side(_ bytes: Data) -> EditionDiff.Side {
            EditionDiff.Side(file: "grctcgnt_usfx.zip", revision: "", sha256: sha256Hex(bytes), warnings: [])
        }
        return EditionDiff(
            edition: "tcgnt", script: .greek,
            from: side(old), old: try edition.parse(zip: old, lock: lock, name: "old.zip"),
            to: side(new), new: try edition.parse(zip: new, lock: lock, name: "new.zip")
        )
    }

    @Test func lockedZipAgainstItselfIsIdentical() throws {
        let (_, bytes) = try lockedZip()
        #expect(try compare(bytes, bytes).identical)
    }

    @Test func oneEditedVerseIsTheOnlyChange() throws {
        let (_, bytes) = try lockedZip()
        let zip = try ZipArchive(bytes)
        let original = "<v id=\"35\" /><w s=\"G1145\">ἐδάκρυσεν</w> <w s=\"G3588\">ὁ</w> <w s=\"G2424\">Ἰησοῦς</w>."
        let entries = try zip.entries.map { entry -> (path: String, data: Data) in
            var data = try zip.contents(of: entry)
            if entry.path.hasSuffix("_usfx.xml") {
                let xml = String(decoding: data, as: UTF8.self)
                #expect(xml.components(separatedBy: original).count == 2, "John 11:35 appears once in the locked TCGNT")
                data = Data(xml.replacingOccurrences(of: original, with: original.replacingOccurrences(of: "ἐδάκρυσεν", with: "ἔκλαυσεν")).utf8)
            }
            return (entry.path, data)
        }
        let edited = try ZipWriter.write(entries, modified: utc("2026-10-30T00:00:00Z"))

        let result = try compare(bytes, edited)
        #expect(kinds(result) == ["JHN 11:35 wording"])
        #expect(result.notes.isEmpty && result.books.isEmpty)
        let verse = result.verses[0]
        let lines = DiffReport.changedText(verse.from!, verse.to!, marks: .text)
        #expect(lines[0].text == "[-ἐδάκρυσεν-] ὁ Ἰησοῦς.")
        #expect(lines[1].text == "{+ἔκλαυσεν+} ὁ Ἰησοῦς.")
        #expect(verse.markup?.added.contains("word 1 ἔκλαυσεν G1145 -") == true)
    }
}
