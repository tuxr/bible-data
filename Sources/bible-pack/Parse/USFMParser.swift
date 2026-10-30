import BibleFormat
import Foundation

/// A USFM 3 token: a marker, with any `+` nesting prefix removed, or the text between markers.
enum USFMToken: Equatable {
    case marker(String, closing: Bool)
    case text(String)

    /// An opening marker owns the one whitespace character after it. A closing marker owns none.
    static func tokens(_ source: String) -> [USFMToken] {
        let scalars = Array(source.unicodeScalars)
        var tokens: [USFMToken] = []
        var text = String.UnicodeScalarView()
        var index = 0
        func isNameScalar(_ scalar: Unicode.Scalar) -> Bool {
            scalar.isASCII && (("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-")
        }
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "\\" else {
                text.append(scalar)
                index += 1
                continue
            }
            if !text.isEmpty {
                tokens.append(.text(String(text)))
                text = String.UnicodeScalarView()
            }
            index += 1
            if index < scalars.count, scalars[index] == "+" { index += 1 }
            var name = String.UnicodeScalarView()
            while index < scalars.count, isNameScalar(scalars[index]) {
                name.append(scalars[index])
                index += 1
            }
            if index < scalars.count, scalars[index] == "*" {
                tokens.append(.marker(String(name), closing: true))
                index += 1
            } else {
                tokens.append(.marker(String(name), closing: false))
                if index < scalars.count, scalars[index].properties.isWhitespace { index += 1 }
            }
        }
        if !text.isEmpty { tokens.append(.text(String(text))) }
        return tokens
    }
}

/// Reads one USFM book into the chapter stream through `ChapterBuilder`. Markers mean what `Markers` says.
/// A paragraph marker closes the previous paragraph and every character style left open in it, as USFM 3 says.
struct USFMParser {
    private var book: BookBuilder
    private var paragraph = Paragraph.ignored
    private var characters: [OpenCharacter] = []
    private var note: NoteState?
    private var argument: Argument?
    private var attributed: Attributed?

    fileprivate enum Paragraph {
        /// Text goes to the builder, which knows whether a block or a label is open.
        case content
        case label
        case parallelPassage
        case bookName(BookNameField, String)
        case ignored
    }

    private enum NoteState: Equatable {
        case reading(NotePartRole)
        /// A note where text is not kept, such as in a book title. Its content is dropped up to its closer.
        case dropped
    }

    /// A marker whose argument is the first word of the text after it.
    private enum Argument {
        case chapter
        case verse
        case caller(NoteKind)
    }

    private enum Attributed {
        case reference(String)
        case word(String)
    }

    private struct OpenCharacter {
        var name: String
        var role: CharacterRole
        var inNote: Bool
    }

    static func bookID(_ source: String) -> String? {
        for line in source.split(separator: "\n", omittingEmptySubsequences: true).prefix(5) {
            let words = line.split(separator: " ")
            if words.first == "\\id", words.count > 1 { return String(words[1]) }
        }
        return nil
    }

    static func parse(_ source: String, book: Book, scheme: VerseCounts? = nil) -> (book: ParsedBook, warnings: [String]) {
        var parser = USFMParser(book: BookBuilder(book: book, wordTagged: source.contains("\\w ")))
        for token in USFMToken.tokens(source) {
            switch token {
            case .text(let text): parser.read(text)
            case .marker(let name, let closing): parser.marker(name, closing: closing)
            }
        }
        parser.closeParagraph()
        let parsed = parser.book.finish(scheme: scheme)
        return (parsed, parser.book.warnings)
    }

    private init(book: BookBuilder) {
        self.book = book
    }

    private mutating func read(_ text: String) {
        guard let pending = argument else {
            if case .reference(let buffer) = attributed { attributed = .reference(buffer + text); return }
            if case .word(let buffer) = attributed { attributed = .word(buffer + text); return }
            return route(text)
        }
        let scalars = text.unicodeScalars
        guard let start = scalars.firstIndex(where: { !$0.properties.isWhitespace }) else { return }
        let end = scalars[start...].firstIndex(where: { $0.properties.isWhitespace }) ?? scalars.endIndex
        let word = String(scalars[start..<end])
        var rest = String(scalars[end...])
        if rest.unicodeScalars.first?.properties.isWhitespace == true { rest = String(rest.unicodeScalars.dropFirst()) }
        argument = nil
        switch pending {
        case .chapter:
            guard let number = Int(word), (1..<PackageSchema.rowIDPartLimit).contains(number) else {
                return book.warn("unreadable chapter number \(word)")
            }
            closeParagraph()
            paragraph = .ignored
            book.startChapter(number)
        case .verse:
            if let label = verseLabel(word) {
                book.chapter?.startVerse(label)
            } else {
                book.warn("unreadable verse number \(word)")
            }
        case .caller(let kind):
            if book.chapter == nil || isHidden || !paragraph.keepsText {
                note = .dropped
            } else {
                book.chapter?.startNote(kind, caller: word)
                note = .reading(.text)
            }
        }
        if !rest.isEmpty { read(rest) }
    }

    private var isHidden: Bool {
        characters.contains { $0.role == .hidden }
    }

    private mutating func route(_ text: String) {
        switch paragraph {
        case .ignored:
            return
        case .bookName(let field, let buffer):
            paragraph = .bookName(field, buffer + text)
            return
        case .content, .label, .parallelPassage:
            break
        }
        if isHidden || note == .reading(.hidden) || note == .dropped { return }
        book.chapter?.text(text)
    }

    private mutating func marker(_ name: String, closing: Bool) {
        if attributed != nil, Markers.role(name) != .reference, Markers.role(name) != .word {
            book.warn("\\\(name) inside an attributed span")
            finishAttributed(closing: false)
        }
        switch name {
        case "c" where !closing:
            argument = .chapter
            return
        case "v" where !closing:
            argument = .verse
            return
        default:
            break
        }
        guard let role = Markers.role(name) else {
            return book.warn("unknown marker \\\(name)\(closing ? "*" : "")")
        }
        switch role {
        case .paragraph(let role):
            if closing { return book.warn("closing paragraph marker \\\(name)*") }
            startParagraph(role)
        case .character(let role):
            if closing {
                guard let index = characters.lastIndex(where: { $0.name == name }) else {
                    return book.warn("\\\(name)* closes nothing")
                }
                characters.remove(at: index)
            } else {
                characters.append(OpenCharacter(name: name, role: role, inNote: note != nil))
            }
            updateStyle()
        case .note(let kind):
            if closing {
                guard note != nil else { return book.warn("\\\(name)* closes no note") }
                closeNote()
            } else {
                if note != nil { closeNote() }
                argument = .caller(kind)
            }
        case .notePart(let part):
            guard let state = note else { return book.warn("\\\(name) outside a note") }
            guard state != .dropped else { return }
            if closing {
                if part == .verseNumber { book.chapter?.text(" ") }
                note = .reading(.text)
            } else {
                note = .reading(part)
                if part == .paragraph || part == .verseNumber { book.chapter?.text(" ") }
            }
        case .reference:
            if closing { finishAttributed(closing: true) } else { attributed = .reference("") }
        case .word:
            if closing { finishAttributed(closing: true) } else { attributed = .word("") }
        }
    }

    private mutating func startParagraph(_ role: ParagraphRole) {
        closeParagraph()
        guard book.chapter != nil else {
            if case .bookName(let field) = role { paragraph = .bookName(field, "") } else { paragraph = .ignored }
            return
        }
        switch role {
        case .block(let kind):
            book.chapter?.startBlock(kind)
            paragraph = .content
        case .continuation:
            book.chapter?.continueBlock()
            paragraph = .content
        case .blankLine:
            book.chapter?.blankLine()
            paragraph = .content
        case .label(let kind):
            book.chapter?.startLabel(kind)
            paragraph = .label
        case .parallelPassage:
            book.chapter?.startNote(.crossReference, caller: "+")
            paragraph = .parallelPassage
        case .bookName(let field):
            paragraph = .bookName(field, "")
        case .ignored:
            paragraph = .ignored
        }
    }

    private mutating func closeParagraph() {
        if note != nil {
            book.warn("a note is not closed at the end of its paragraph")
            closeNote()
        }
        if attributed != nil { finishAttributed(closing: false) }
        characters.removeAll()
        updateStyle()
        switch paragraph {
        case .label:
            book.chapter?.endLabel()
        case .parallelPassage:
            book.chapter?.endNote()
        case .bookName(let field, let text):
            let name = PlainText.clean(text)
            if !name.isEmpty, book.names[field] == nil { book.names[field] = name }
        case .content, .ignored:
            break
        }
        paragraph = .ignored
    }

    private mutating func closeNote() {
        if case .reading = note { book.chapter?.endNote() }
        note = nil
        characters.removeAll { $0.inNote }
        updateStyle()
    }

    private mutating func updateStyle() {
        let style = characters.reduce(into: RunStyle()) { style, open in
            if !open.inNote, case .style(let bit) = open.role { style.formUnion(bit) }
        }
        book.chapter?.style = style
    }

    /// `\ref text|target\ref*` keeps the text and records the target; `\w text|attributes\w*` tags a word.
    private mutating func finishAttributed(closing: Bool) {
        guard let span = attributed else { return }
        attributed = nil
        switch span {
        case .reference(let buffer):
            let (text, target) = Self.splitAttributes(buffer)
            route(text)
            if let target, !target.isEmpty { addTarget(target) }
        case .word(let buffer):
            let (text, attributes) = Self.splitAttributes(buffer)
            let parsed = attributes.map(Self.wordAttributes) ?? [:]
            book.chapter?.startWord(strong: parsed["strong"], morph: parsed["x-morph"] ?? parsed["morph"])
            route(text)
            book.chapter?.endWord()
        }
    }

    private mutating func addTarget(_ target: String) {
        guard note != nil || paragraph.isParallelPassage else { return }
        switch TargetReference.parse(target) {
        case .range(let range): book.chapter?.addTarget(range)
        case .outsideCanon: break
        case .unreadable: book.warn("unreadable reference target \(target)")
        }
    }

    private static func splitAttributes(_ buffer: String) -> (String, String?) {
        guard let bar = buffer.lastIndex(of: "|") else { return (buffer, nil) }
        return (String(buffer[..<bar]), String(buffer[buffer.index(after: bar)...]))
    }

    /// `strong="H1234" x-morph="..."`, or a bare value, which USFM 3 makes the lemma.
    private static func wordAttributes(_ text: String) -> [String: String] {
        var attributes: [String: String] = [:]
        var rest = Substring(text)
        while let equals = rest.firstIndex(of: "=") {
            let key = rest[..<equals].trimmingCharacters(in: .whitespaces)
            let afterEquals = rest[rest.index(after: equals)...].drop { $0 == " " }
            guard afterEquals.first == "\"" else { break }
            let value = afterEquals.dropFirst()
            guard let close = value.firstIndex(of: "\"") else { break }
            attributes[key] = String(value[..<close])
            rest = value[value.index(after: close)...]
        }
        if attributes.isEmpty, !text.isEmpty { attributes["lemma"] = text }
        return attributes
    }
}

extension USFMParser.Paragraph {
    fileprivate var keepsText: Bool {
        switch self {
        case .content, .label, .parallelPassage: true
        case .bookName, .ignored: false
        }
    }

    fileprivate var isParallelPassage: Bool {
        if case .parallelPassage = self { true } else { false }
    }
}
