import BibleFormat
import Foundation

/// Reads a USFX document, eBible's XML form of USFM, into chapter streams through `ChapterBuilder`. Elements mean
/// what the USFM marker of the same name means in `Markers`; `p`, `q`, and `s` take the marker from their style.
enum USFXParser {
    static func parse(_ data: Data, scheme: VerseCounts? = nil) -> (books: [ParsedBook], warnings: [String]) {
        let reader = USFXReader(wordTagged: data.range(of: Data("<w ".utf8)) != nil, scheme: scheme)
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldProcessNamespaces = false
        if !parser.parse() {
            let error = parser.parserError.map { "\($0)" } ?? "unknown error"
            reader.warnings.append("XML error at line \(parser.lineNumber): \(error)")
        }
        return (reader.books, reader.warnings)
    }
}

/// USFM book ids that hold no scripture: front and back matter, introductions, glossaries, and appendices.
let peripheralBookIDs: Set<String> = [
    "FRT", "BAK", "OTH", "INT", "CNC", "GLO", "TDX", "NDX", "XXA", "XXB", "XXC", "XXD", "XXE", "XXF", "XXG",
]

private final class USFXReader: NSObject, XMLParserDelegate {
    let wordTagged: Bool
    let scheme: VerseCounts?
    var books: [ParsedBook] = []
    var warnings: [String] = []

    private var book: BookBuilder?
    private var frames: [Frame] = []
    private var characters = ""
    private var name = ""

    /// What an open element did, so its end can undo it.
    private enum Frame {
        case book
        case block
        case label
        case parallelPassage
        case bookName(BookNameField)
        /// Text inside is not chapter content: identification, book titles, introductions, figures.
        case ignored
        case character(CharacterRole)
        case note
        case notePart(NotePartRole)
        case reference(target: String?)
        case word
        case structure
    }

    init(wordTagged: Bool, scheme: VerseCounts?) {
        self.wordTagged = wordTagged
        self.scheme = scheme
    }

    private var dropsText: Bool {
        frames.contains { frame in
            switch frame {
            case .ignored, .character(.hidden), .notePart(.hidden): true
            default: false
            }
        }
    }

    private var namesBook: BookNameField? {
        for frame in frames.reversed() { if case .bookName(let field) = frame { return field } }
        return nil
    }

    private var inNote: Bool {
        frames.contains { if case .note = $0 { true } else { false } }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        characters += string
    }

    func parser(
        _ parser: XMLParser,
        didStartElement element: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        flushCharacters()
        if dropsText {
            frames.append(.ignored)
            return
        }
        let frame = open(element, attributes)
        frames.append(frame)
        if case .character = frame { updateStyle() }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        flushCharacters()
        guard let frame = frames.popLast() else { return }
        close(frame)
    }

    private func flushCharacters() {
        defer { characters = "" }
        guard !characters.isEmpty, book != nil, !dropsText else { return }
        if namesBook != nil {
            name += characters
        } else {
            book?.chapter?.text(characters)
        }
    }

    private func open(_ element: String, _ attributes: [String: String]) -> Frame {
        switch element {
        case "usfx":
            return .structure
        case "languageCode", "id", "rem":
            return .ignored
        case "book":
            startBook(attributes["id"] ?? "")
            return .book
        case "c":
            if let number = attributes["id"].flatMap(Int.init), (1..<PackageSchema.rowIDPartLimit).contains(number) {
                book?.startChapter(number)
            } else {
                book?.warn("unreadable chapter id \(attributes["id"] ?? "")")
            }
            return .structure
        case "v":
            if let label = attributes["id"].flatMap(verseLabel) {
                book?.chapter?.startVerse(label)
            } else {
                book?.warn("unreadable verse id \(attributes["id"] ?? "")")
            }
            return .structure
        case "ve":
            return .structure
        case "h":
            name = ""
            return .bookName(.header)
        case "toc":
            name = ""
            switch attributes["level"] {
            case "1": return .bookName(.longTitle)
            case "2": return .bookName(.shortTitle)
            case "3": return .bookName(.abbreviation)
            default: return .ignored
            }
        case "p", "q", "s", "d", "b", "sp":
            return paragraph(Self.marker(element, attributes))
        case "w":
            book?.chapter?.startWord(strong: attributes["s"], morph: attributes["m"])
            return .word
        case "ref":
            return .reference(target: attributes["tgt"])
        case "table", "tr", "tc", "th", "tcr", "thr":
            book?.chapter?.text(" ")
            return .structure
        case "cs":
            return markerElement(attributes["sfm"] ?? "", attributes)
        default:
            return markerElement(element, attributes)
        }
    }

    private func markerElement(_ marker: String, _ attributes: [String: String]) -> Frame {
        switch Markers.role(marker) {
        case .character(let role):
            return .character(role)
        case .note(let kind):
            guard book?.chapter != nil else { return .ignored }
            book?.chapter?.startNote(kind, caller: attributes["caller"] ?? "+")
            return .note
        case .notePart(let part):
            guard inNote else {
                book?.warn("<\(marker)> outside a note")
                return .structure
            }
            if part == .paragraph || part == .verseNumber { book?.chapter?.text(" ") }
            return .notePart(part)
        case .paragraph:
            return paragraph(marker)
        case .reference, .word, nil:
            book?.warn("unknown element <\(marker)>")
            return .structure
        }
    }

    /// `p` names its marker in `style` (or `sfm`); `q` and `s` may give only a `level`.
    private static func marker(_ element: String, _ attributes: [String: String]) -> String {
        let style = attributes["style"] ?? attributes["sfm"] ?? element
        if (element == "q" || element == "s"), style == element, let level = attributes["level"] { return element + level }
        return style
    }

    private func paragraph(_ marker: String) -> Frame {
        guard case .paragraph(let role) = Markers.role(marker) else {
            book?.warn("unknown paragraph style \(marker)")
            book?.chapter?.startBlock(.paragraph)
            return .block
        }
        guard book?.chapter != nil else {
            if case .bookName(let field) = role {
                name = ""
                return .bookName(field)
            }
            return .ignored
        }
        switch role {
        case .block(let kind):
            book?.chapter?.startBlock(kind)
            return .block
        case .continuation:
            book?.chapter?.continueBlock()
            return .block
        case .blankLine:
            book?.chapter?.blankLine()
            return .structure
        case .label(let kind):
            book?.chapter?.startLabel(kind)
            return .label
        case .parallelPassage:
            book?.chapter?.startNote(.crossReference, caller: "+")
            return .parallelPassage
        case .bookName(let field):
            name = ""
            return .bookName(field)
        case .ignored:
            return .ignored
        }
    }

    private func close(_ frame: Frame) {
        switch frame {
        case .book:
            finishBook()
        case .block:
            book?.chapter?.endBlock()
        case .label:
            book?.chapter?.endLabel()
        case .parallelPassage, .note:
            book?.chapter?.endNote()
        case .bookName(let field):
            let text = PlainText.clean(name)
            if !text.isEmpty, book?.names[field] == nil { book?.names[field] = text }
            name = ""
        case .character:
            updateStyle()
        case .notePart(.verseNumber):
            book?.chapter?.text(" ")
        case .reference(let target):
            guard let target, inNote else { return }
            switch TargetReference.parse(target) {
            case .range(let range): book?.chapter?.addTarget(range)
            case .outsideCanon: break
            case .unreadable: book?.warn("unreadable reference target \(target)")
            }
        case .word:
            book?.chapter?.endWord()
        case .ignored, .notePart, .structure:
            break
        }
    }

    /// Character styles inside a note style only the note, which keeps no styles.
    private func updateStyle() {
        var style = RunStyle()
        for frame in frames {
            if case .note = frame { break }
            if case .character(.style(let bit)) = frame { style.formUnion(bit) }
        }
        book?.chapter?.style = style
    }

    private func startBook(_ id: String) {
        finishBook()
        if let parsed = Book(rawValue: id) {
            book = BookBuilder(book: parsed, wordTagged: wordTagged)
        } else if !peripheralBookIDs.contains(id) {
            warnings.append("\(id): unknown book id, skipped")
        }
    }

    private func finishBook() {
        guard var current = book else { return }
        book = nil
        let parsed = current.finish(scheme: scheme)
        warnings.append(contentsOf: current.warnings)
        if parsed.chapters.isEmpty {
            warnings.append("\(parsed.book.rawValue): the book has no chapters, skipped")
        } else {
            books.append(parsed)
        }
    }
}
