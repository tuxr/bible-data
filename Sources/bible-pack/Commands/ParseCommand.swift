import ArgumentParser
import BibleFormat
import Foundation

struct ParseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "parse",
        abstract: "Parse an edition from its locked source and print a census, or one book or chapter."
    )

    enum Output: String, EnumerableFlag {
        case json
        case text
        case plain

        static func help(for value: Output) -> ArgumentHelp? {
            switch value {
            case .json: "Print each chapter's items as JSONChapterCodec writes them, then its notes."
            case .text: "Print one line per item."
            case .plain: "Print each verse's verses.text_plain."
            }
        }
    }

    @OptionGroup var global: GlobalOptions

    @Argument(help: "The edition to parse, such as bsb.")
    var editionID: String

    @Option(help: "A book id, such as GEN. Without it, prints the census.")
    var book: String?

    @Option(help: "A chapter of --book. Without it, prints every chapter of the book.")
    var chapter: Int?

    @Flag var output: Output = .text

    @Flag(help: "Exit 0 from the census even when the parse warned.")
    var allowWarnings = false

    func run() throws {
        guard let edition = Edition.named(editionID) else {
            throw ValidationError("unknown edition \(editionID); known: \(Edition.all.map(\.id).joined(separator: ", "))")
        }
        let parsed = try edition.parse(lock: try global.readLock(), cache: global.cache)
        guard let bookID = book else {
            print(census(parsed, edition: edition))
            if !parsed.report.warnings.isEmpty, !allowWarnings { throw ExitCode.failure }
            return
        }
        guard let book = Book(rawValue: bookID.uppercased()), let parsedBook = parsed.books.first(where: { $0.book == book }) else {
            throw ValidationError("\(edition.id) has no book \(bookID)")
        }
        let chapters = parsedBook.chapters.filter { chapter == nil || $0.chapter.number == chapter }
        guard !chapters.isEmpty else { throw ValidationError("\(book.rawValue) has no chapter \(chapter ?? 0)") }
        for parsedChapter in chapters {
            print(try render(parsedChapter, as: output))
        }
    }

    func render(_ parsed: ParsedChapter, as output: Output) throws -> String {
        switch output {
        case .json:
            let items = String(decoding: try JSONChapterCodec().encode(parsed.chapter), as: UTF8.self)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let notes = String(decoding: try encoder.encode(parsed.notes), as: UTF8.self)
            return items + "\n" + notes
        case .text:
            return ChapterRendering.lines(parsed).joined(separator: "\n")
        case .plain:
            return PlainText.verses(of: parsed.chapter).map { "\(ChapterRendering.label($0.label)) \($0.text)" }.joined(separator: "\n")
        }
    }

    func census(_ parsed: ParsedEdition, edition: Edition) -> String {
        let chapters = parsed.books.flatMap(\.chapters)
        let verses = chapters.reduce(0) { $0 + PlainText.verses(of: $1.chapter).count }
        let notes = chapters.reduce(0) { $0 + $1.notes.count }
        let words = chapters.reduce(0) { total, chapter in total + chapter.words.reduce(0) { $0 + $1.words.count } }
        let absent = parsed.books.flatMap(\.absentVerses)
        var lines = [
            "edition   \(edition.id) (\(edition.scheme.rawValue))",
            "books     \(parsed.books.count)",
            "chapters  \(chapters.count)",
            "verses    \(verses)",
            "absent    \(absent.count)\(absent.isEmpty ? "" : "  " + absent.map(\.description).joined(separator: ", "))",
            "notes     \(notes)",
            "words     \(words)",
            "warnings  \(parsed.report.warnings.count)",
        ]
        lines += parsed.report.warnings.map { "  \($0)" }
        return lines.joined(separator: "\n")
    }
}

enum ChapterRendering {
    static func lines(_ parsed: ParsedChapter) -> [String] {
        var lines = parsed.chapter.items.map(line)
        lines += parsed.notes.map { note in
            let targets = note.targets.map { "\($0.start)-\($0.end.chapter):\($0.end.verse)" }.joined(separator: " ")
            return "note \(note.number) \(note.kind.rawValue) v\(note.verse) [\(note.caller)] \(note.text)\(targets.isEmpty ? "" : "  -> \(targets)")"
        }
        lines += parsed.words.map { verse in
            "words \(verse.ref.verse): " + verse.words.map { "\($0.index)=\($0.surface)\($0.strong.map { "/\($0)" } ?? "")" }.joined(separator: " ")
        }
        return lines
    }

    static func line(_ item: ChapterItem) -> String {
        switch item {
        case .block(let kind): "block \(block(kind))"
        case .heading(let level, let runs): "heading \(level.rawValue) \(text(runs))"
        case .title(let runs): "title \(text(runs))"
        case .speaker(let runs): "speaker \(text(runs))"
        case .verse(let verse): "verse \(label(verse))"
        case .text(let run): "text \(text([run]))"
        case .noteCaller(let caller): "caller \(caller.number) \(caller.kind.rawValue) [\(caller.glyph)]"
        }
    }

    static func block(_ kind: BlockKind) -> String {
        switch kind {
        case .paragraph: "paragraph"
        case .flush: "flush"
        case .indented: "indented"
        case .poetry(let level): "poetry \(level.rawValue)"
        case .rightAligned: "right"
        case .centered: "centered"
        case .list(let level): "list \(level.rawValue)"
        case .blankLine: "blank"
        }
    }

    static func label(_ label: VerseLabel) -> String {
        label.through.map { "\(label.number)-\($0)" } ?? "\(label.number)"
    }

    private static func text(_ runs: [Run]) -> String {
        runs.map { run in
            var marks: [String] = []
            if run.style.contains(.wordsOfJesus) { marks.append("wj") }
            if run.style.contains(.addedWords) { marks.append("add") }
            if run.style.contains(.divineName) { marks.append("nd") }
            if run.style.contains(.transliteration) { marks.append("tl") }
            if run.style.contains(.quotedScripture) { marks.append("qt") }
            if run.style.contains(.selah) { marks.append("qs") }
            if let word = run.word { marks.append("w\(word)") }
            return "«\(run.text)»" + (marks.isEmpty ? "" : "{\(marks.joined(separator: ","))}")
        }.joined()
    }
}
