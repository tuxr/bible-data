import BibleFormat

/// Builds one chapter's stream from parser events. This is the one place that knows FORMAT.md's stream rules,
/// so the USFM and USFX parsers only translate markup into events.
///
/// - A heading, title, or speaker closes the open block. Text after one reopens the interrupted block kind.
/// - A block item waits for content, so an empty paragraph or a trailing blank line leaves no item.
/// - Whitespace collapses to one space, never leads a block or a verse, and never ends a block.
/// - A verse marker inside a label takes effect when the label closes, because a label is not verse text.
/// - A note caller inside a label, or where no block is open, follows the label.
struct ChapterBuilder {
    let book: Book
    let number: Int
    /// In a tagged edition, text outside a tagged word is split into words, which get positions, and punctuation.
    let wordTagged: Bool
    /// The character style of the text that follows. The parser sets it from its open character markers.
    var style: RunStyle = []
    private(set) var warnings: [String] = []

    private var items: [ChapterItem] = []
    private var flowRuns = RunBuilder()
    private var flow = Flow.pending(Pending())
    private var mode = Mode.flow
    private var verse: VerseLabel?
    private var seenVerses: Set<Int> = []
    private var notes: [ParsedNote] = []
    private var words: [VerseWords] = []
    private var verseWords: [WordTag] = []
    private var openWord: OpenWord?

    init(book: Book, number: Int, wordTagged: Bool = false) {
        self.book = book
        self.number = number
        self.wordTagged = wordTagged
    }

    private enum Flow {
        /// No block item is open for the coming content; `Pending` holds what that content emits first.
        case pending(Pending)
        case open(BlockKind)
    }

    /// Items held until content arrives, so an empty paragraph, a trailing blank line, or a verse marker that
    /// precedes its paragraph never leaves an item in the wrong place.
    private struct Pending {
        var blankLines = 0
        /// The kind a paragraph marker asked for.
        var block: BlockKind?
        /// The kind a label or blank line interrupted, which content continues when no marker asks for another.
        var resume: BlockKind?
        var verse: VerseLabel?

        /// The kind to keep once the paragraph marker's own block is known to be empty.
        mutating func dropBlock() {
            resume = block ?? resume
            block = nil
        }
    }

    private indirect enum Mode {
        case flow
        case label(OpenLabel)
        case note(OpenNote, within: Mode)
    }

    private struct OpenLabel {
        var kind: LabelKind
        var runs = RunBuilder()
        var callers: [NoteCaller] = []
        var deferredVerse: VerseLabel?
    }

    private struct OpenNote {
        var number: Int
        var kind: NoteKind
        var caller: String
        var verse: Int
        var text = ""
        var targets: [VerseRange] = []
    }

    private struct OpenWord {
        var index: Int
        var surface = ""
        var strong: String?
        var morph: String?
    }

    var location: String { "\(book.rawValue) \(number):\(verse?.number ?? 0)" }

    mutating func startBlock(_ kind: BlockKind) {
        guard case .flow = mode else { return warn("a paragraph marker inside a label or note") }
        var pending = closeBlock()
        pending.block = kind
        flow = .pending(pending)
    }

    /// `nb`: the text continues the open block. With none open it continues the interrupted kind, or sets flush.
    mutating func continueBlock() {
        guard case .flow = mode else { return warn("a paragraph marker inside a label or note") }
        guard case .pending(var pending) = flow else { return }
        pending.block = pending.block ?? pending.resume ?? .flush
        flow = .pending(pending)
    }

    mutating func blankLine() {
        guard case .flow = mode else { return warn("a blank line inside a label or note") }
        var pending = closeBlock()
        pending.dropBlock()
        pending.blankLines += 1
        flow = .pending(pending)
    }

    mutating func endBlock() {
        guard case .flow = mode else { return }
        var pending = closeBlock()
        pending.dropBlock()
        flow = .pending(pending)
    }

    mutating func startLabel(_ kind: LabelKind) {
        guard case .flow = mode else { return warn("a heading, title, or speaker inside a label or note") }
        var pending = closeBlock()
        pending.dropBlock()
        items.append(contentsOf: repeatElement(.block(.blankLine), count: pending.blankLines))
        pending.blankLines = 0
        flow = .pending(pending)
        mode = .label(OpenLabel(kind: kind))
    }

    mutating func endLabel() {
        guard case .label(let label) = mode else { return }
        mode = .flow
        var runs = label.runs
        let finished = runs.take()
        if !finished.isEmpty {
            switch label.kind {
            case .heading(let level): items.append(.heading(level: level, finished))
            case .title: items.append(.title(finished))
            case .speaker: items.append(.speaker(finished))
            }
        }
        items.append(contentsOf: label.callers.map(ChapterItem.noteCaller))
        if let deferred = label.deferredVerse { startVerse(deferred) }
    }

    /// A second marker for the current verse, as `12b` after `12a`, continues it without a new item.
    mutating func startVerse(_ label: VerseLabel) {
        switch mode {
        case .label(var open):
            open.deferredVerse = label
            mode = .label(open)
            return
        case .note:
            return warn("a verse marker inside a note")
        case .flow:
            break
        }
        if label == verse { return }
        let numbers = label.number...(label.through ?? label.number)
        if !seenVerses.isDisjoint(with: numbers) { warn("verse \(label.number) starts a second time") }
        seenVerses.formUnion(numbers)
        finishVerseWords()
        verse = label
        if case .pending(var pending) = flow, pending.verse == nil {
            pending.verse = label
            flow = .pending(pending)
            return
        }
        // An empty verse is still a verse: the one before this marker gets its block now.
        openBlockIfNeeded()
        flowRuns.commitSpace()
        closeRuns()
        items.append(.verse(label))
        flowRuns.startLine()
    }

    mutating func startWord(strong: String?, morph: String?) {
        endWord()
        guard case .flow = mode, verse != nil else { return }
        openWord = OpenWord(index: verseWords.count + 1, strong: strong, morph: morph)
    }

    mutating func endWord() {
        guard let word = openWord else { return }
        openWord = nil
        if word.surface.isEmpty { return warn("an empty tagged word") }
        verseWords.append(WordTag(
            index: word.index, surface: PlainText.clean(word.surface), strong: word.strong, morph: word.morph
        ))
    }

    mutating func text(_ piece: String) {
        switch mode {
        case .note(var note, let within):
            note.text += piece
            mode = .note(note, within: within)
        case .label(var label):
            label.runs.append(piece, style: style, word: nil)
            mode = .label(label)
        case .flow:
            if piece.unicodeScalars.allSatisfy(\.properties.isWhitespace) {
                if case .open = flow { flowRuns.append(piece, style: style, word: nil) }
                return
            }
            openBlockIfNeeded()
            if var word = openWord {
                word.surface += piece
                openWord = word
                flowRuns.append(piece, style: style, word: word.index)
            } else if wordTagged, verse != nil {
                appendUntagged(piece)
            } else {
                flowRuns.append(piece, style: style, word: nil)
            }
        }
    }

    /// Splits text a tagged edition left outside its word elements. A word gets the next position; spaces,
    /// punctuation, and the Masoretic paragraph letters do not.
    private mutating func appendUntagged(_ piece: String) {
        for token in WordTokens(piece) {
            if token.isWord, !Self.paragraphLetters.contains(token.text) {
                let index = verseWords.count + 1
                verseWords.append(WordTag(index: index, surface: token.text))
                flowRuns.append(token.text, style: style, word: index)
            } else {
                flowRuns.append(token.text, style: style, word: nil)
            }
        }
    }

    private static let paragraphLetters: Set<String> = ["\u{05E4}", "\u{05E1}"]

    mutating func startNote(_ kind: NoteKind, caller glyph: String) {
        let number = notes.count + 1
        let caller = NoteCaller(number: number, kind: kind, glyph: Self.glyph(glyph, number: number))
        switch mode {
        case .note:
            return warn("a note inside a note")
        case .label(var label):
            label.callers.append(caller)
            mode = .label(label)
        case .flow:
            if case .pending(let pending) = flow, pending.block == nil, pending.verse == nil {
                items.append(.noteCaller(caller))
            } else {
                openBlockIfNeeded()
                flowRuns.commitSpace()
                closeRuns()
                items.append(.noteCaller(caller))
            }
        }
        mode = .note(OpenNote(number: number, kind: kind, caller: caller.glyph, verse: verse?.number ?? 0), within: mode)
    }

    mutating func addTarget(_ range: VerseRange) {
        guard case .note(var note, let within) = mode else { return }
        note.targets.append(range)
        mode = .note(note, within: within)
    }

    mutating func endNote() {
        guard case .note(let note, let within) = mode else { return warn("a note closes that was not open") }
        mode = within
        var text = PlainText.clean(note.text)
        if note.kind == .crossReference { text = Self.removingEnclosingParentheses(text) }
        notes.append(ParsedNote(
            verse: note.verse, number: note.number, kind: note.kind, caller: note.caller, text: text, targets: note.targets
        ))
    }

    /// USFM's `+` asks for a generated caller: letters in note order, `a` to `z`, then `aa`. `-` asks for none.
    static func glyph(_ caller: String, number: Int) -> String {
        switch caller {
        case "+": letters(number)
        case "-": ""
        default: caller
        }
    }

    private static func letters(_ number: Int) -> String {
        var remaining = number
        var scalars: [Unicode.Scalar] = []
        while remaining > 0 {
            remaining -= 1
            scalars.insert(Unicode.Scalar(UInt8(ascii: "a") + UInt8(remaining % 26)), at: 0)
            remaining /= 26
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// A parallel-passage line is printed in parentheses; the note shows only what is inside them.
    private static func removingEnclosingParentheses(_ text: String) -> String {
        guard text.first == "(", text.last == ")" else { return text }
        let inner = text.dropFirst().dropLast()
        var depth = 0
        for character in inner {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            if depth < 0 { return text }
        }
        return PlainText.clean(String(inner))
    }

    mutating func warn(_ message: String) {
        warnings.append("\(location): \(message)")
    }

    mutating func finish() -> ParsedChapter {
        while true {
            switch mode {
            case .flow:
                break
            case .label:
                warn("a heading, title, or speaker is not closed at the chapter end")
                endLabel()
                continue
            case .note:
                warn("a note is not closed at the chapter end")
                endNote()
                continue
            }
            break
        }
        if case .pending(let pending) = flow, pending.verse != nil { openBlockIfNeeded() }
        closeRuns()
        finishVerseWords()
        return ParsedChapter(chapter: Chapter(book: book, number: number, items: items), notes: notes, words: words)
    }

    private mutating func openBlockIfNeeded() {
        guard case .pending(let pending) = flow else { return }
        items.append(contentsOf: repeatElement(.block(.blankLine), count: pending.blankLines))
        let kind = pending.block ?? pending.resume ?? .paragraph
        items.append(.block(kind))
        flowRuns.startLine()
        flow = .open(kind)
        if let verse = pending.verse { items.append(.verse(verse)) }
    }

    private mutating func closeBlock() -> Pending {
        switch flow {
        case .open(let kind):
            closeRuns()
            return Pending(resume: kind)
        case .pending(let pending):
            return pending
        }
    }

    /// Moves the finished runs into the stream. A space still pending is dropped: nothing follows it here.
    private mutating func closeRuns() {
        items.append(contentsOf: flowRuns.take().map(ChapterItem.text))
    }

    private mutating func finishVerseWords() {
        endWord()
        if let verse, !verseWords.isEmpty {
            words.append(VerseWords(ref: VerseRef(book, number, verse.number), words: verseWords))
        }
        verseWords = []
    }
}

/// Runs built from text pieces. Whitespace collapses to one space that is written only when more text follows, so
/// it never leads a line and never trails one. Adjacent pieces with the same style and word share a run.
struct RunBuilder {
    private var runs: [Run] = []
    private var text = ""
    private var style: RunStyle = []
    private var word: Int?
    private var hasText = false
    private var pendingSpace: RunStyle?

    mutating func append(_ piece: String, style: RunStyle, word: Int?) {
        var segment = String.UnicodeScalarView()
        for scalar in piece.unicodeScalars {
            if scalar.properties.isWhitespace {
                if !segment.isEmpty {
                    add(String(segment), style: style, word: word)
                    segment = String.UnicodeScalarView()
                }
                if hasText, pendingSpace == nil { pendingSpace = style }
            } else {
                segment.append(scalar)
            }
        }
        if !segment.isEmpty { add(String(segment), style: style, word: word) }
    }

    /// Writes a pending space now, ahead of a verse marker or note caller that sits after it.
    mutating func commitSpace() {
        guard let spaceStyle = pendingSpace else { return }
        pendingSpace = nil
        extend(" ", style: spaceStyle, word: nil)
    }

    mutating func startLine() {
        pendingSpace = nil
        hasText = false
    }

    mutating func take() -> [Run] {
        pendingSpace = nil
        closeRun()
        defer { runs = [] }
        return runs
    }

    private mutating func add(_ segment: String, style: RunStyle, word: Int?) {
        commitSpace()
        extend(segment, style: style, word: word)
        hasText = true
    }

    private mutating func extend(_ segment: String, style: RunStyle, word: Int?) {
        if !text.isEmpty, style != self.style || word != self.word { closeRun() }
        if text.isEmpty {
            self.style = style
            self.word = word
        }
        text += segment
    }

    private mutating func closeRun() {
        guard !text.isEmpty else { return }
        runs.append(Run(text, style: style, word: word))
        text = ""
    }
}

struct WordTokens: Sequence {
    struct Token: Equatable {
        var text: String
        var isWord: Bool
    }

    private let tokens: [Token]

    init(_ text: String) {
        var tokens: [Token] = []
        var current = String.UnicodeScalarView()
        var currentIsWord = false
        for scalar in text.unicodeScalars {
            let isWord = Self.isWordScalar(scalar)
            if !current.isEmpty, isWord != currentIsWord {
                tokens.append(Token(text: String(current), isWord: currentIsWord))
                current = String.UnicodeScalarView()
            }
            current.append(scalar)
            currentIsWord = isWord
        }
        if !current.isEmpty { tokens.append(Token(text: String(current), isWord: currentIsWord)) }
        self.tokens = tokens
    }

    func makeIterator() -> IndexingIterator<[Token]> { tokens.makeIterator() }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark:
            true
        default:
            false
        }
    }
}
