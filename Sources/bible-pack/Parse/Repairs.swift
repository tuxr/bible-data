import BibleFormat
import Foundation

/// `@unchecked` because NSRegularExpression is immutable and documented as safe to share across threads.
struct TextRule: @unchecked Sendable {
    let pattern: NSRegularExpression
    let template: String

    init(_ pattern: String, _ template: String, options: NSRegularExpression.Options = []) {
        self.pattern = try! NSRegularExpression(pattern: pattern, options: options)
        self.template = template
    }

    func apply(_ text: String) -> String {
        pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

/// Repairs to the BSB's USFM, which bsb2usfm builds from Bible Hub's tables. The generic USFM parser never sees
/// these rules; `Edition` applies them to the BSB alone.
enum BSBRepair {
    /// Markup bsb2usfm sets with markers that USFM 3 gives another meaning, rewritten to the USFM 3 markers:
    ///
    /// - `\d` outside the Psalms. Its one use is Zechariah 12:1's opening sentence, which is verse text in the BSB's
    ///   own text and in the `eng` scheme, so it becomes a paragraph, as Habakkuk 3:1's like sentence already is.
    /// - `\mr`, whose one use is Habakkuk 3:19's closing note "For the choirmaster.", USFM 3's `\qd`.
    /// - Selah on its own `\qr` line, which USFM 3 marks `\qs`.
    static func markup(_ usfm: String) -> String {
        var text = usfm
        if USFMParser.bookID(usfm) != Book.psalms.rawValue { text = descriptiveTitle.apply(text) }
        return markupRules.reduce(text) { $1.apply($0) }
    }

    private static let descriptiveTitle = TextRule(#"^\\d "#, #"\\p "#, options: .anchorsMatchLines)
    private static let markupRules = [
        TextRule(#"^\\mr "#, #"\\qd "#, options: .anchorsMatchLines),
        TextRule(#"^\\qr ((?:Higgaion )?Selah)"#, #"\\qr \\qs $1\\qs*"#, options: .anchorsMatchLines),
    ]

    /// Typesetting artifacts that the publisher's own text (bereanbible.com/bsb.txt) does not have: spaced em
    /// dashes, a "[’’]" closing a speech, bracketed supplied words, a stray "vvv", "..." before a number or a closing
    /// parenthesis, the typo "evenif" (Jeremiah 22:24), spaces inside parentheses and quotes, and a footnote set
    /// against the next word. Ported from bible-api's `bsbUsfmCleanup`, which was checked verse by verse against bsb.txt.
    static let textRules = [
        TextRule(#"\s*\x{2014}\s*"#, "\u{2014}"),
        TextRule(#"\[\x{2019}\x{2019}\]"#, ""),
        TextRule(#"[\[\]]"#, ""),
        TextRule(#"\bvvv "#, ""),
        TextRule(#"\.\.\.\s*(?=\))"#, ""),
        TextRule(#"\.\.\.\s*(?=\d)"#, " "),
        TextRule(#"\bevenif\b"#, "even if"),
        TextRule(#"([(\x{2018}\x{201C}])\s+"#, "$1"),
        TextRule(#"\s+([)\x{201D}\x{2019}])"#, "$1"),
        TextRule(#"([,.;:!?])(?=[A-Za-z\x{2018}\x{201C}])"#, "$1 "),
        TextRule(#" {2,}"#, " "),
    ]

    static func repair(_ text: String) -> String {
        PlainText.clean(textRules.reduce(text) { $1.apply($0) })
    }

    /// Repairs each stretch of text runs, with note callers between them, as one string, so a rule sees across a
    /// style change or a caller, as "Samuel,\f ...\f*saying" needs. Each character goes back to the run it came from.
    static func repair(_ chapter: ParsedChapter) -> ParsedChapter {
        var items: [ChapterItem] = []
        var span: [ChapterItem] = []
        func flushSpan() {
            items.append(contentsOf: repairSpan(span))
            span = []
        }
        for item in chapter.chapter.items {
            switch item {
            case .text, .noteCaller:
                span.append(item)
            case .heading(let level, let runs):
                flushSpan()
                items.append(.heading(level: level, repairRuns(runs)))
            case .title(let runs):
                flushSpan()
                items.append(.title(repairRuns(runs)))
            case .speaker(let runs):
                flushSpan()
                items.append(.speaker(repairRuns(runs)))
            case .block, .verse:
                flushSpan()
                items.append(item)
            }
        }
        flushSpan()
        let notes = chapter.notes.map { note in
            ParsedNote(
                verse: note.verse, number: note.number, kind: note.kind, caller: note.caller,
                text: repair(note.text), targets: note.targets
            )
        }
        return ParsedChapter(
            chapter: Chapter(book: chapter.chapter.book, number: chapter.chapter.number, items: items),
            notes: notes,
            words: chapter.words
        )
    }

    private static func repairRuns(_ runs: [Run]) -> [Run] {
        repairSpan(runs.map(ChapterItem.text)).compactMap { item in
            if case .text(let run) = item { run } else { nil }
        }
    }

    private static func repairSpan(_ span: [ChapterItem]) -> [ChapterItem] {
        guard span.contains(where: { if case .text = $0 { true } else { false } }) else { return span }
        var units: [UInt16] = []
        var owners: [Int] = []
        for (index, item) in span.enumerated() {
            guard case .text(let run) = item else { continue }
            units.append(contentsOf: run.text.utf16)
            owners.append(contentsOf: repeatElement(index, count: run.text.utf16.count))
        }
        for rule in textRules {
            let string = String(decoding: units, as: UTF16.self) as NSString
            let matches = rule.pattern.matches(in: string as String, range: NSRange(location: 0, length: string.length))
            for match in matches.reversed() {
                let replacement = rule.pattern.replacementString(for: match, in: string as String, offset: 0, template: rule.template)
                let range = match.range.location..<(match.range.location + match.range.length)
                let owner = owners[match.range.location]
                units.replaceSubrange(range, with: replacement.utf16)
                owners.replaceSubrange(range, with: repeatElement(owner, count: replacement.utf16.count))
            }
        }
        var texts: [Int: [UInt16]] = [:]
        for (unit, owner) in zip(units, owners) { texts[owner, default: []].append(unit) }
        var repaired: [ChapterItem] = []
        for (index, item) in span.enumerated() {
            switch item {
            case .text(let run):
                let text = String(decoding: texts[index] ?? [], as: UTF16.self)
                guard !text.isEmpty else { continue }
                let next = Run(text, style: run.style, word: run.word)
                if case .text(let previous) = repaired.last, previous.style == next.style, previous.word == next.word {
                    repaired[repaired.count - 1] = .text(Run(previous.text + next.text, style: next.style, word: next.word))
                } else {
                    repaired.append(.text(next))
                }
            default:
                repaired.append(item)
            }
        }
        return repaired
    }
}

/// eBible's WLC escapes the markup of eleven words into their text, as
/// `'l s="H8085"'שְׁמַ֖'seg type="x-large"'ע'seg''/l'` in Deuteronomy 6:4. Each becomes a tagged word again, with its
/// Strong's number padded to four digits like every other word's. The large, small, and suspended letter marks are
/// dropped, since the chapter model has no style for them; the letters stay.
enum WLCRepair {
    static func markup(_ xml: String) -> String {
        var text = rules.reduce(xml) { $1.apply($0) }
        let opener = try! NSRegularExpression(pattern: #"'l s="H(\d+)"'"#)
        for match in opener.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: text), let digits = Range(match.range(at: 1), in: text) else { continue }
            let padded = String(repeating: "0", count: max(0, 4 - text[digits].count)) + text[digits]
            text.replaceSubrange(whole, with: "<w s=\"H\(padded)\">")
        }
        return text
    }

    private static let rules = [
        TextRule(#"'seg(?: type="[^"]*")?'"#, ""),
        TextRule(#"'/l'"#, "</w>"),
    ]
}

/// eBible's TCGNT wraps one footnote, at John 8:10, in a stray `<ft>` in the verse text. The wrapper is removed and
/// the note kept.
enum TCGNTRepair {
    static func markup(_ xml: String) -> String {
        strayWrapper.apply(xml)
    }

    private static let strayWrapper = TextRule(#"<ft>(<f [^>]*>(?:(?!</f>).)*</f>)</ft>"#, "$1", options: .dotMatchesLineSeparators)
}
