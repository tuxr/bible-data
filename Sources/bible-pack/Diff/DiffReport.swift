import BibleFormat
import Foundation

/// Renders an `EditionDiff` for a terminal, a pull request body, or a program.
enum DiffReport {
    enum Format: String, CaseIterable, Sendable {
        case text
        case markdown
        case json
    }

    static func render(_ diff: EditionDiff, as format: Format, limit: Int = 200) -> String {
        switch format {
        case .text: text(diff)
        case .markdown: markdown(diff, limit: limit)
        case .json: json(diff)
        }
    }

    static func json(_ diff: EditionDiff) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(diff), as: UTF8.self)
    }

    static func text(_ diff: EditionDiff) -> String {
        var lines = [header(diff, code: { $0 })]
        if diff.identical { return lines[0] + "\nidentical: no verse, note, book name, or verse count differs" }
        lines += ["", table(summary(diff)).joined(separator: "\n")]
        lines += warnings(diff).map { "warning in the new revision: \($0)" }
        if !diff.books.isEmpty { lines += ["", "books"] + diff.books.map { "  " + bookLine($0) } }
        if !diff.verses.isEmpty { lines += ["", "verses"] }
        for verse in diff.verses {
            lines.append(verse.ref + "  " + verse.kind.rawValue + (verse.movedFrom.map { " from \($0)" } ?? ""))
            lines += verseBody(verse, marks: .text).map { "  " + $0.sign.rawValue + " " + $0.text }
        }
        if !diff.notes.isEmpty { lines += ["", "notes"] }
        for note in diff.notes {
            lines.append("\(note.ref)  note \(note.change.rawValue)")
            lines += noteBody(note, marks: .text).map { "  " + $0.sign.rawValue + " " + $0.text }
        }
        return lines.joined(separator: "\n")
    }

    static func markdown(_ diff: EditionDiff, limit: Int) -> String {
        var lines = [header(diff, code: { "`\($0)`" })]
        if diff.identical { return lines[0] + "\n\nThe scripture is identical: no verse, note, book name, or verse count differs." }
        let rows = summary(diff)
        lines += ["", "| " + rows[0].joined(separator: " | ") + " |", "|" + rows[0].indices.map { $0 == 0 ? "---|" : "---:|" }.joined()]
        lines += rows.dropFirst().map { "| " + $0.joined(separator: " | ") + " |" }
        let warned = warnings(diff)
        if !warned.isEmpty {
            lines += ["", "**The new revision parses with \(warned.count) warnings, so it cannot be built until they are fixed.**", ""]
            lines += warned.map { "- \(Marks.markdown.escape($0))" }
        }
        if !diff.books.isEmpty { lines += ["", "#### Books", ""] + diff.books.map { "- " + Marks.markdown.escape(bookLine($0)) } }
        for kind in VerseChangeKind.allCases {
            let verses = diff.verses.filter { $0.kind == kind }
            if verses.isEmpty { continue }
            lines += ["", "#### \(kind.rawValue.capitalized) (\(verses.count))"]
            for verse in verses.prefix(limit) {
                lines += ["", "**\(verse.ref)**" + (verse.movedFrom.map { " from \($0)" } ?? "")]
                lines += verseBody(verse, marks: .markdown).map { "- \($0.markdownLabel): \($0.text)" }
            }
            if verses.count > limit { lines += ["", "And \(verses.count - limit) more \(kind.rawValue) verses; the JSON diff lists every one."] }
        }
        if !diff.notes.isEmpty {
            lines += ["", "#### Notes (\(diff.notes.count))"]
            for note in diff.notes.prefix(limit) {
                lines += ["", "**\(note.ref)** note \(note.change.rawValue)"]
                lines += noteBody(note, marks: .markdown).map { "- \($0.markdownLabel): \($0.text)" }
            }
            if diff.notes.count > limit { lines += ["", "And \(diff.notes.count - limit) more notes; the JSON diff lists every one."] }
        }
        return lines.joined(separator: "\n")
    }

    private static func header(_ diff: EditionDiff, code: (String) -> String) -> String {
        func side(_ side: EditionDiff.Side) -> String { "\(code(side.file)) (\(side.revision), \(code(String(side.sha256.prefix(8)))))" }
        return "\(diff.edition): \(side(diff.from)) to \(side(diff.to))"
    }

    private static func warnings(_ diff: EditionDiff) -> [String] {
        let known = Set(diff.from.warnings)
        return diff.to.warnings.filter { !known.contains($0) }
    }

    /// The header row, one row per book with a change, and a total row. A kind with no verses has no column.
    static func summary(_ diff: EditionDiff) -> [[String]] {
        let kinds = VerseChangeKind.allCases.filter { kind in diff.verses.contains { $0.kind == kind } }
        let books = Set(diff.verses.map(\.book)).union(diff.notes.map(\.book)).sorted()
        func row(_ name: String, _ verses: [EditionDiff.Verse], _ notes: [EditionDiff.Note]) -> [String] {
            [name] + kinds.map { kind in String(verses.count { $0.kind == kind }) } + [String(notes.count), String(verses.count + notes.count)]
        }
        return [["book"] + kinds.map(\.rawValue) + ["notes", "total"]]
            + books.map { book in row(book.rawValue, diff.verses.filter { $0.book == book }, diff.notes.filter { $0.book == book }) }
            + [row("total", diff.verses, diff.notes)]
    }

    private static func table(_ rows: [[String]]) -> [String] {
        let widths = rows[0].indices.map { column in rows.map { $0[column].count }.max()! }
        return rows.map { row in
            row.indices.map { column in
                let pad = String(repeating: " ", count: widths[column] - row[column].count)
                return column == 0 ? row[column] + pad : pad + row[column]
            }.joined(separator: "  ")
        }
    }

    private static func bookLine(_ change: EditionDiff.BookChange) -> String {
        func describe<Value>(_ label: String, _ change: EditionDiff.Change<Value>?) -> String? {
            change.map { "\(label) \($0.from.map { "\($0)" } ?? "none") to \($0.to.map { "\($0)" } ?? "none")" }
        }
        let parts = [
            describe("name", change.name), describe("short name", change.shortName),
            describe("chapters", change.chapters), describe("verses", change.verses),
            change.absentAdded.isEmpty ? nil : "newly absent " + change.absentAdded.joined(separator: ", "),
            change.absentRemoved.isEmpty ? nil : "no longer absent " + change.absentRemoved.joined(separator: ", "),
        ]
        return change.book.rawValue + ": " + parts.compactMap { $0 }.joined(separator: "; ")
    }

    struct Line: Equatable {
        enum Sign: String {
            case old = "-"
            case new = "+"
            case same = "="
            case codePoints = "~"
        }

        let sign: Sign
        let text: String

        var markdownLabel: String {
            switch sign {
            case .old: "old"
            case .new: "new"
            case .same: "text"
            case .codePoints: "code points"
            }
        }
    }

    static func verseBody(_ verse: EditionDiff.Verse, marks: Marks) -> [Line] {
        switch verse.kind {
        case .added: return [Line(sign: .new, text: marks.plain(verse.to ?? ""))]
        case .removed: return [Line(sign: .old, text: marks.plain(verse.from ?? ""))]
        case .moved: return [Line(sign: .same, text: marks.plain(verse.to ?? ""))]
        case .markup:
            let lines = verse.markup ?? EditionDiff.Lines(removed: [], added: [])
            return [Line(sign: .same, text: marks.plain(verse.to ?? ""))]
                + lines.removed.map { Line(sign: .old, text: marks.code($0)) }
                + lines.added.map { Line(sign: .new, text: marks.code($0)) }
        case .wording, .pointing, .punctuation:
            return changedText(verse.from ?? "", verse.to ?? "", marks: marks)
        }
    }

    static func noteBody(_ note: EditionDiff.Note, marks: Marks) -> [Line] {
        switch note.change {
        case .added: [Line(sign: .new, text: marks.plain(note.to ?? ""))]
        case .removed: [Line(sign: .old, text: marks.plain(note.from ?? ""))]
        case .changed: changedText(note.from ?? "", note.to ?? "", marks: marks)
        }
    }

    /// The old and new text with the differing words marked, then the code points of up to three one-word changes,
    /// since a Latin `o` for a Greek omicron or a changed accent looks the same on both lines.
    static func changedText(_ old: String, _ new: String, marks: Marks) -> [Line] {
        var oldParts: [String] = [], newParts: [String] = [], codePoints: [String] = []
        let words = hunks(old.split(separator: " ").map(String.init), new.split(separator: " ").map(String.init))
        for hunk in words {
            switch hunk {
            case .same(let same):
                oldParts += same.map(marks.escape)
                newParts += same.map(marks.escape)
            case .changed(let removed, let added):
                if !removed.isEmpty { oldParts.append(marks.removed(removed.map(marks.escape).joined(separator: " "))) }
                if !added.isEmpty { newParts.append(marks.added(added.map(marks.escape).joined(separator: " "))) }
                if removed.count == 1, added.count == 1, codePoints.count < 3, let detail = scalarChange(removed[0], added[0], marks: marks) {
                    codePoints.append(detail)
                }
            }
        }
        return [Line(sign: .old, text: oldParts.joined(separator: " ")), Line(sign: .new, text: newParts.joined(separator: " "))]
            + codePoints.map { Line(sign: .codePoints, text: $0) }
    }

    /// `oὐκ` to `οὐκ`: U+006F LATIN SMALL LETTER O to U+03BF GREEK SMALL LETTER OMICRON. Nil when more than four
    /// code points differ on a side, where the marked words already say enough.
    static func scalarChange(_ old: String, _ new: String, marks: Marks) -> String? {
        let a = Array(old.unicodeScalars), b = Array(new.unicodeScalars)
        let prefix = zip(a, b).prefix { $0 == $1 }.count
        let suffix = zip(a.dropFirst(prefix).reversed(), b.dropFirst(prefix).reversed()).prefix { $0 == $1 }.count
        let removed = a[prefix..<(a.count - suffix)], added = b[prefix..<(b.count - suffix)]
        guard removed.count <= 4, added.count <= 4 else { return nil }
        func names(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
            scalars.isEmpty ? "nothing" : scalars.map { scalar in
                String(format: "U+%04X", scalar.value) + (scalar.properties.name.map { " \($0)" } ?? "")
            }.joined(separator: ", ")
        }
        return "\(marks.code(old)) to \(marks.code(new)): \(names(removed)) to \(names(added))"
    }

    struct Marks: Sendable {
        let removed: @Sendable (String) -> String
        let added: @Sendable (String) -> String
        let escape: @Sendable (String) -> String
        let code: @Sendable (String) -> String

        func plain(_ text: String) -> String {
            text.split(separator: " ").map { escape(String($0)) }.joined(separator: " ")
        }

        static let text = Marks(removed: { "[-\($0)-]" }, added: { "{+\($0)+}" }, escape: { $0 }, code: { $0 })

        /// Markers sit on whole words with a space or a line end on each side, so GitHub's emphasis rules always
        /// open and close them, even next to punctuation.
        static let markdown = Marks(
            removed: { "~~\($0)~~" },
            added: { "**\($0)**" },
            escape: { word in
                var out = ""
                for char in word {
                    if "\\`*_~[]<>|#".contains(char) { out.append("\\") }
                    out.append(char)
                }
                return out
            },
            code: { text in
                let longest = text.split(separator: "`", omittingEmptySubsequences: false)
                    .count - 1 > 0 ? text.ranges(of: /`+/).map { text[$0].count }.max() ?? 0 : 0
                let fence = String(repeating: "`", count: longest + 1)
                return longest == 0 ? "\(fence)\(text)\(fence)" : "\(fence) \(text) \(fence)"
            }
        )
    }
}
