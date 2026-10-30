import BibleFormat
import Foundation
import Testing
@testable import bible_pack

/// Parses one USFM book with the generic parser and no edition repairs.
func parseUSFM(_ lines: [String], book: Book) -> (book: ParsedBook, warnings: [String]) {
    USFMParser.parse(lines.joined(separator: "\n"), book: book)
}

/// Parses USFM files as the BSB edition does: markup repairs, the generic parser, then the text repairs.
func parseBSB(_ files: [(name: String, lines: [String])]) -> ParsedEdition {
    EditionSource.usfm(files: files.map { ($0.name, Data($0.lines.joined(separator: "\n").utf8)) })
        .parse(Edition.named("bsb")!)
}

func parseUSFX(_ body: String) -> (books: [ParsedBook], warnings: [String]) {
    USFXParser.parse(Data("<usfx>\(body)</usfx>".utf8))
}

func plain(_ chapter: ParsedChapter) -> [String] {
    PlainText.verses(of: chapter.chapter).map(\.text)
}

func chapter(_ book: ParsedBook, _ number: Int) -> ParsedChapter {
    book.chapters.first { $0.chapter.number == number }!
}

func run(_ text: String, _ style: RunStyle = [], word: Int? = nil) -> ChapterItem {
    .text(Run(text, style: style, word: word))
}

func verse(_ number: Int, through: Int? = nil) -> ChapterItem {
    .verse(VerseLabel(number, through: through))
}

func caller(_ number: Int, _ kind: NoteKind = .footnote, _ glyph: String? = nil) -> ChapterItem {
    .noteCaller(NoteCaller(number: number, kind: kind, glyph: glyph ?? ChapterBuilder.glyph("+", number: number)))
}

let q1 = ChapterItem.block(.poetry(level: .one))
let q2 = ChapterItem.block(.poetry(level: .two))
let paragraph = ChapterItem.block(.paragraph)
let blank = ChapterItem.block(.blankLine)

/// FORMAT.md's stream rules, checked over any chapter. Returns one line per broken rule.
func streamViolations(_ parsed: ParsedChapter) -> [String] {
    let chapter = parsed.chapter
    let place = "\(chapter.book.rawValue) \(chapter.number)"
    var problems: [String] = []
    var inBlock = false
    var previous: ChapterItem?
    var lastVerse = 0
    var callerNumbers: [Int] = []
    func checkLabel(_ runs: [Run], _ index: Int) {
        if runs.isEmpty || runs.contains(where: \.text.isEmpty) { problems.append("\(place) item \(index): an empty label run") }
        inBlock = false
    }
    for (index, item) in chapter.items.enumerated() {
        switch item {
        case .block(let kind):
            inBlock = kind != .blankLine
        case .heading(_, let runs), .title(let runs), .speaker(let runs):
            checkLabel(runs, index)
        case .verse(let label):
            lastVerse = label.through ?? label.number
            if !inBlock { problems.append("\(place) item \(index): verse \(label.number) outside a block") }
        case .text(let run):
            if !inBlock { problems.append("\(place) item \(index): text outside a block") }
            if run.text.isEmpty { problems.append("\(place) item \(index): an empty run") }
            if case .text(let before) = previous, before.style == run.style, before.word == run.word {
                problems.append("\(place) item \(index): two runs that should be one")
            }
            if case .block = previous, run.text.first?.isWhitespace == true {
                problems.append("\(place) item \(index): a block starts with a space")
            }
            if case .verse = previous, run.text.first?.isWhitespace == true {
                problems.append("\(place) item \(index): a verse starts with a space")
            }
        case .noteCaller(let noteCaller):
            callerNumbers.append(noteCaller.number)
            guard let note = parsed.notes.first(where: { $0.number == noteCaller.number }) else {
                problems.append("\(place) item \(index): caller \(noteCaller.number) has no note")
                break
            }
            if note.kind != noteCaller.kind || note.caller != noteCaller.glyph {
                problems.append("\(place) item \(index): caller \(noteCaller.number) disagrees with its note")
            }
            if note.verse > lastVerse { problems.append("\(place) note \(note.number) is anchored after its caller") }
        }
        if case .text(let run) = item, index + 1 < chapter.items.count, run.text.last?.isWhitespace == true {
            switch chapter.items[index + 1] {
            case .block, .heading, .title, .speaker: problems.append("\(place) item \(index): a block ends with a space")
            default: break
            }
        }
        previous = item
    }
    let expected = Array(stride(from: 1, through: parsed.notes.count, by: 1))
    if callerNumbers != expected { problems.append("\(place): note callers are not 1...\(parsed.notes.count) in order") }
    if parsed.notes.map(\.number) != expected { problems.append("\(place): notes are not numbered 1...\(parsed.notes.count)") }
    return problems
}

/// The real publisher sources in `.sources/`. Tests that need them are skipped when they are absent; CI runs
/// `swift run bible-pack sources fetch` first.
enum RealSources {
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let goldens = repository.appending(path: "Tests/Goldens")

    static let lock: SourcesLock? = {
        guard let data = try? Data(contentsOf: repository.appending(path: "sources.lock.json")) else { return nil }
        return try? SourcesLock(jsonData: data)
    }()

    static let cache = SourceCache(directory: repository.appending(path: ".sources", directoryHint: .isDirectory))

    static let present: Bool = {
        guard let lock else { return false }
        return lock.sources.values.allSatisfy { cache.contents(of: $0.file) != nil }
    }()

    static let skipMessage: Comment = "the publisher sources are not in .sources; run `swift run bible-pack sources fetch`"

    static let bsb = parse("bsb")
    static let wlc = parse("wlc")
    static let tcgnt = parse("tcgnt")

    static func edition(_ id: String) -> ParsedEdition {
        switch id {
        case "bsb": bsb
        case "wlc": wlc
        default: tcgnt
        }
    }

    private static func parse(_ id: String) -> ParsedEdition {
        do {
            return try Edition.named(id)!.parse(lock: lock!, cache: cache)
        } catch {
            preconditionFailure("\(id) does not parse: \(error)")
        }
    }
}
