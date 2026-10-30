import BibleFormat
import Foundation

/// How a verse differs between two revisions, in the order a report lists them. `VerseChange.classify` decides
/// which applies.
enum VerseChangeKind: String, Codable, CaseIterable, Sendable {
    /// In the new revision only.
    case added
    /// In the old revision only.
    case removed
    /// The same text at another verse of the same chapter.
    case moved
    /// Any other change to the letters.
    case wording
    /// Hebrew or Greek whose letters, and their case, are equal once points, accents, and breathings are folded away.
    case pointing
    /// Equal once punctuation is removed and whitespace collapsed, case included. In Greek, a word whose punctuation
    /// changed may also swap a final acute and grave accent.
    case punctuation
    /// The same plain text in a different stream: a style, a block, a heading, a note caller, or a word tag.
    case markup
}

enum NoteChangeKind: String, Codable, Sendable {
    case added
    case removed
    case changed
}

/// Two revisions of one edition compared verse by verse, with their notes, book names, and verse counts.
struct EditionDiff: Encodable, Sendable {
    struct Side: Encodable, Sendable {
        let file: String
        let revision: String
        let sha256: String
        let warnings: [String]
    }

    struct Verse: Encodable, Sendable {
        let ref: String
        let book: Book
        let kind: VerseChangeKind
        /// The verse whose old text a moved verse holds.
        let movedFrom: String?
        let from: String?
        let to: String?
        /// The stream and word tag lines that differ, as `bible-pack parse` prints them, when any do.
        let markup: Lines?
    }

    struct Lines: Encodable, Sendable {
        let removed: [String]
        let added: [String]
    }

    struct Note: Encodable, Sendable {
        /// The verse that holds the note's caller; verse 0 is before verse 1.
        let ref: String
        let book: Book
        let change: NoteChangeKind
        let from: String?
        let to: String?
    }

    struct Change<Value: Encodable & Equatable & Sendable>: Encodable, Sendable {
        let from: Value?
        let to: Value?

        static func of(_ from: Value?, _ to: Value?) -> Change? {
            from == to ? nil : Change(from: from, to: to)
        }
    }

    struct BookChange: Encodable, Sendable {
        let book: Book
        let name: Change<String>?
        let shortName: Change<String>?
        let chapters: Change<Int>?
        let verses: Change<Int>?
        let absentAdded: [String]
        let absentRemoved: [String]
    }

    let edition: String
    let from: Side
    let to: Side
    let identical: Bool
    let books: [BookChange]
    let verses: [Verse]
    let notes: [Note]

    init(edition: String, script: Script, from: Side, old: ParsedEdition, to: Side, new: ParsedEdition) {
        let oldBooks = Dictionary(old.books.map { ($0.book, $0) }, uniquingKeysWith: { first, _ in first })
        let newBooks = Dictionary(new.books.map { ($0.book, $0) }, uniquingKeysWith: { first, _ in first })
        var books: [BookChange] = []
        var verses: [Verse] = []
        var notes: [Note] = []
        for book in Set(oldBooks.keys).union(newBooks.keys).sorted() {
            let a = oldBooks[book], b = newBooks[book]
            let oldChapters = Dictionary((a?.chapters ?? []).map { ($0.chapter.number, $0) }, uniquingKeysWith: { first, _ in first })
            let newChapters = Dictionary((b?.chapters ?? []).map { ($0.chapter.number, $0) }, uniquingKeysWith: { first, _ in first })
            var verseCounts = (old: 0, new: 0)
            for number in Set(oldChapters.keys).union(newChapters.keys).sorted() {
                let was = oldChapters[number].map(VerseState.all) ?? []
                let now = newChapters[number].map(VerseState.all) ?? []
                verseCounts.old += was.count
                verseCounts.new += now.count
                verses += Self.verses(book: book, chapter: number, old: was, new: now, script: script)
                notes += Self.notes(book: book, chapter: number, old: oldChapters[number]?.notes ?? [], new: newChapters[number]?.notes ?? [])
            }
            let oldAbsent = Set(a?.absentVerses ?? []), newAbsent = Set(b?.absentVerses ?? [])
            let change = BookChange(
                book: book,
                name: .of(a?.name, b?.name),
                shortName: .of(a?.shortName, b?.shortName),
                chapters: .of(a?.chapters.count, b?.chapters.count),
                verses: .of(a.map { _ in verseCounts.old }, b.map { _ in verseCounts.new }),
                absentAdded: newAbsent.subtracting(oldAbsent).sorted().map(\.description),
                absentRemoved: oldAbsent.subtracting(newAbsent).sorted().map(\.description)
            )
            if change.name != nil || change.shortName != nil || change.chapters != nil || change.verses != nil
                || !change.absentAdded.isEmpty || !change.absentRemoved.isEmpty {
                books.append(change)
            }
        }
        self.edition = edition
        self.from = from
        self.to = to
        self.books = books
        self.verses = verses
        self.notes = notes
        identical = books.isEmpty && verses.isEmpty && notes.isEmpty
    }

    /// The precedence is moved, then added and removed, then the text kinds, then markup. A verse is moved only from
    /// a verse whose old text the new revision no longer has there, so repeated text such as Numbers 7 never pairs.
    static func verses(book: Book, chapter: Int, old: [VerseState], new: [VerseState], script: Script) -> [Verse] {
        let oldByLabel = Dictionary(old.map { ($0.label, $0) }, uniquingKeysWith: { first, _ in first })
        let newByLabel = Dictionary(new.map { ($0.label, $0) }, uniquingKeysWith: { first, _ in first })
        func ref(_ label: VerseLabel) -> String { "\(book.rawValue) \(chapter):\(ChapterRendering.label(label))" }

        var movedFrom: [VerseLabel: VerseState] = [:]
        var sources = Set<VerseLabel>()
        for verse in new where !verse.plain.isEmpty && oldByLabel[verse.label]?.plain != verse.plain {
            let source = old.first { candidate in
                candidate.label != verse.label && candidate.plain == verse.plain
                    && newByLabel[candidate.label]?.plain != candidate.plain && !sources.contains(candidate.label)
            }
            if let source {
                movedFrom[verse.label] = source
                sources.insert(source.label)
            }
        }

        var changes: [(label: VerseLabel, change: Verse)] = []
        for verse in new {
            let was = oldByLabel[verse.label]
            let kind: VerseChangeKind
            let previous: VerseState?
            if let source = movedFrom[verse.label] {
                (kind, previous) = (.moved, source)
            } else if let was {
                guard let textKind = VerseChange.classify(was, verse, script: script) else { continue }
                (kind, previous) = (textKind, was)
            } else {
                (kind, previous) = (.added, nil)
            }
            changes.append((verse.label, Verse(
                ref: ref(verse.label), book: book, kind: kind,
                movedFrom: kind == .moved ? ref(previous!.label) : nil,
                from: previous?.plain, to: verse.plain,
                markup: previous.flatMap { Lines.between($0.markup, verse.markup) }
            )))
        }
        for verse in old where newByLabel[verse.label] == nil && !sources.contains(verse.label) {
            changes.append((verse.label, Verse(
                ref: ref(verse.label), book: book, kind: .removed, movedFrom: nil, from: verse.plain, to: nil, markup: nil
            )))
        }
        return changes.sorted { ($0.label.number, $0.label.through ?? 0) < ($1.label.number, $1.label.through ?? 0) }.map(\.change)
    }

    static func notes(book: Book, chapter: Int, old: [ParsedNote], new: [ParsedNote]) -> [Note] {
        let oldByVerse = Dictionary(grouping: old, by: \.verse), newByVerse = Dictionary(grouping: new, by: \.verse)
        var changes: [Note] = []
        for verse in Set(oldByVerse.keys).union(newByVerse.keys).sorted() {
            let ref = "\(book.rawValue) \(chapter):\(verse)"
            let was = (oldByVerse[verse] ?? []).map(noteLine), now = (newByVerse[verse] ?? []).map(noteLine)
            for case .changed(let removed, let added) in hunks(was, now) {
                for (from, to) in pair(removed, added) {
                    let change: NoteChangeKind = from == nil ? .added : to == nil ? .removed : .changed
                    changes.append(Note(ref: ref, book: book, change: change, from: from, to: to))
                }
            }
        }
        return changes
    }

    /// Pairs each new note with the next old one that shares at least half its words, keeping their order, so an
    /// edited note reads as changed and a dropped one as removed rather than pairing by position.
    static func pair(_ removed: [String], _ added: [String]) -> [(from: String?, to: String?)] {
        func similarity(_ a: String, _ b: String) -> Double {
            let x = a.split(separator: " "), y = b.split(separator: " ")
            let common = hunks(x, y).reduce(0) { total, hunk in if case .same(let run) = hunk { total + run.count } else { total } }
            return Double(2 * common) / Double(max(1, x.count + y.count))
        }
        var pairs: [(from: String?, to: String?)] = []
        var next = 0
        for note in added {
            guard let match = (next..<removed.count).first(where: { similarity(removed[$0], note) >= 0.5 }) else {
                pairs.append((nil, note))
                continue
            }
            pairs += removed[next..<match].map { ($0, nil) }
            pairs.append((removed[match], note))
            next = match + 1
        }
        return pairs + removed[next...].map { ($0, nil) }
    }

    private static func noteLine(_ note: ParsedNote) -> String {
        let targets = note.targets.map { "\($0.start)-\($0.end.chapter):\($0.end.verse)" }.joined(separator: " ")
        return "\(note.kind.rawValue): \(note.text)\(targets.isEmpty ? "" : "  -> \(targets)")"
    }
}

extension EditionDiff.Lines {
    static func between(_ old: [String], _ new: [String]) -> Self? {
        var removed: [String] = [], added: [String] = []
        for case .changed(let o, let n) in hunks(old, new) {
            removed += o
            added += n
        }
        return removed.isEmpty && added.isEmpty ? nil : Self(removed: removed, added: added)
    }
}

/// One verse as the diff compares it: its plain text, and its markup as the lines `bible-pack parse` prints for its
/// stream items and word tags.
struct VerseState: Equatable, Sendable {
    let label: VerseLabel
    let plain: String
    let markup: [String]

    static func all(_ parsed: ParsedChapter) -> [VerseState] {
        let words = Dictionary(grouping: parsed.words, by: \.ref.verse)
        return zip(PlainText.verses(of: parsed.chapter), slices(parsed.chapter.items)).map { verse, items in
            let tags = (words[verse.label.number] ?? []).flatMap(\.words).map { tag in
                "word \(tag.index) \(tag.surface) \(tag.strong ?? "-") \(tag.morph ?? "-")"
            }
            return VerseState(label: verse.label, plain: verse.text, markup: items.map(line) + tags)
        }
    }

    /// Each verse's items after its marker. A block, heading, title, or speaker after a verse's last text, and what
    /// follows it, opens the next verse, so a new heading is a change to the verse it introduces. Items before the
    /// first verse go with it.
    static func slices(_ items: [ChapterItem]) -> [[ChapterItem]] {
        var slices: [[ChapterItem]] = []
        var leading: [ChapterItem] = []
        for item in items {
            guard case .verse = item else {
                if slices.isEmpty { leading.append(item) } else { slices[slices.count - 1].append(item) }
                continue
            }
            if var last = slices.popLast() {
                let afterText = (last.lastIndex { if case .text = $0 { true } else { false } } ?? -1) + 1
                if let cut = last[afterText...].firstIndex(where: opensVerse) {
                    leading = Array(last[cut...])
                    last.removeSubrange(cut...)
                }
                slices.append(last)
            }
            slices.append(leading)
            leading = []
        }
        return slices
    }

    private static func opensVerse(_ item: ChapterItem) -> Bool {
        switch item {
        case .block, .heading, .title, .speaker: true
        case .verse, .text, .noteCaller: false
        }
    }

    // A caller's number and glyph count notes from the start of the chapter, so one new note would renumber every
    // later caller; the notes diff reports the note itself.
    private static func line(_ item: ChapterItem) -> String {
        if case .noteCaller(let caller) = item { return "caller \(caller.kind.rawValue)" }
        return ChapterRendering.line(item)
    }
}

enum VerseChange {
    /// The kind of change between two verses at one reference, or nil when they are the same.
    static func classify(_ old: VerseState, _ new: VerseState, script: Script) -> VerseChangeKind? {
        if old.plain == new.plain { return old.markup == new.markup ? nil : .markup }
        let a = withoutPunctuation(old.plain), b = withoutPunctuation(new.plain)
        if a == b || (script == .greek && onlyPunctuationAndItsAccent(old.plain, new.plain)) { return .punctuation }
        if script != .latin, SearchText.normalize(a, script: script) == SearchText.normalize(b, script: script),
           a.map(\.isUppercase) == b.map(\.isUppercase) {
            return .pointing
        }
        return .wording
    }

    /// A Greek word's final acute is written grave when another word follows with no punctuation between, so
    /// removing a comma after `αὐτό,` makes it `αὐτὸ`. A word whose punctuation changed may swap the two accents and
    /// still be a punctuation change; the same swap with no punctuation change is pointing.
    static func onlyPunctuationAndItsAccent(_ old: String, _ new: String) -> Bool {
        let a = old.split(separator: " "), b = new.split(separator: " ")
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { x, y in
            let bareX = withoutPunctuation(String(x)), bareY = withoutPunctuation(String(y))
            if bareX == bareY { return true }
            return trailingPunctuation(x) != trailingPunctuation(y) && acute(bareX) == acute(bareY)
        }
    }

    private static func trailingPunctuation(_ word: Substring) -> [Unicode.Scalar] {
        Array(word.unicodeScalars.reversed().prefix(while: isPunctuation))
    }

    private static func acute(_ word: String) -> [Unicode.Scalar] {
        word.decomposedStringWithCanonicalMapping.unicodeScalars.map { $0 == "\u{0300}" ? "\u{0301}" : $0 }
    }

    /// Each Unicode punctuation mark becomes a space, then whitespace collapses. Maqaf, sof pasuq, paseq, and the
    /// Greek ano teleia are punctuation; Hebrew points and accents and Greek diacritics are not.
    static func withoutPunctuation(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            out.append(isPunctuation(scalar) ? " " : scalar)
        }
        return String(out).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation: true
        default: false
        }
    }
}
