import BibleFormat
import Foundation

/// Collects one book's chapters and names while a parser reads it, then checks the verses against the edition's
/// scheme: a scheme verse the source never prints is recorded as absent, and a printed verse outside the scheme
/// is a warning.
struct BookBuilder {
    let book: Book
    let wordTagged: Bool
    var names: [BookNameField: String] = [:]
    /// The chapter being read. Nil before the first chapter marker, where only names and introductions sit.
    var chapter: ChapterBuilder?
    private(set) var warnings: [String] = []
    private var chapters: [ParsedChapter] = []

    init(book: Book, wordTagged: Bool) {
        self.book = book
        self.wordTagged = wordTagged
    }

    mutating func startChapter(_ number: Int) {
        finishChapter()
        if chapters.contains(where: { $0.chapter.number == number }) {
            warnings.append("\(book.rawValue) \(number): chapter \(number) starts a second time")
        }
        chapter = ChapterBuilder(book: book, number: number, wordTagged: wordTagged)
    }

    mutating func warn(_ message: String) {
        if chapter != nil {
            chapter?.warn(message)
        } else {
            warnings.append("\(book.rawValue): \(message)")
        }
    }

    mutating func finish(scheme counts: VerseCounts?) -> ParsedBook {
        finishChapter()
        let info = Canon.info(book)
        let absent = counts.map { absentVerses($0) } ?? []
        let abbreviation = names[.abbreviation].flatMap { $0.uppercased() == book.rawValue ? nil : $0 }
        return ParsedBook(
            book: book,
            name: names[.header] ?? names[.shortTitle] ?? names[.longTitle] ?? info.name,
            shortName: abbreviation ?? info.shortName,
            chapters: chapters,
            absentVerses: absent
        )
    }

    private mutating func finishChapter() {
        guard var current = chapter else { return }
        chapter = nil
        let parsed = current.finish()
        warnings.append(contentsOf: current.warnings)
        chapters.append(parsed)
    }

    private mutating func absentVerses(_ counts: VerseCounts) -> [VerseRef] {
        guard let chapterCount = counts.chapters(in: book) else {
            warnings.append("\(book.rawValue): the book is not in the \(counts.scheme.rawValue) scheme")
            return []
        }
        var printed: Set<VerseRef> = []
        for parsed in chapters {
            for item in parsed.chapter.items {
                guard case .verse(let label) = item else { continue }
                for verse in label.number...(label.through ?? label.number) {
                    let ref = VerseRef(book, parsed.chapter.number, verse)
                    if !counts.contains(ref) {
                        warnings.append("\(ref): the verse is not in the \(counts.scheme.rawValue) scheme")
                    }
                    printed.insert(ref)
                }
            }
        }
        var absent: [VerseRef] = []
        for chapter in 1...chapterCount {
            for verse in 1...(counts.verses(in: book, chapter: chapter) ?? 0) {
                let ref = VerseRef(book, chapter, verse)
                if !printed.contains(ref) { absent.append(ref) }
            }
        }
        return absent
    }
}

/// The `BOOK C:V`-style targets that `\ref` and `<ref tgt>` carry.
enum TargetReference {
    enum Outcome: Equatable {
        case range(VerseRange)
        /// A target with no book id names a book outside the canon, such as 1 Enoch. It records no target.
        case outsideCanon
        case unreadable
    }

    /// Reads `BOOK C:V`, `BOOK C:V-V`, `BOOK C:V-C:V`, and, in a one-chapter book, `BOOK V` and `BOOK V-V`.
    /// USFX's `BOOK.C.V` spelling is accepted too.
    static func parse(_ target: String) -> Outcome {
        let trimmed = PlainText.clean(target)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            if let dotted = dottedForm(trimmed) { return parse(dotted) }
            return trimmed.first?.isNumber == true ? .outsideCanon : .unreadable
        }
        guard let book = Book(rawValue: parts[0].uppercased()) else {
            return parts[0].first?.isNumber == true && parts[0].contains(":") ? .outsideCanon : .unreadable
        }
        let ends = parts[1].replacingOccurrences(of: "\u{2013}", with: "-").split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(ends.count), let start = point(ends[0], book: book, chapter: nil) else { return .unreadable }
        let end = ends.count == 2 ? point(ends[1], book: book, chapter: start.chapter) : start
        guard let end, start <= end else { return .unreadable }
        return .range(VerseRange(start, through: end))
    }

    private static func point(_ text: Substring, book: Book, chapter: Int?) -> VerseRef? {
        let numbers = text.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        let limit = 1..<PackageSchema.rowIDPartLimit
        switch numbers.count {
        case 2:
            guard let chapter = numbers[0], let verse = numbers[1], limit.contains(chapter), limit.contains(verse) else { return nil }
            return VerseRef(book, chapter, verse)
        case 1:
            guard let verse = numbers[0], limit.contains(verse) else { return nil }
            if let chapter { return VerseRef(book, chapter, verse) }
            return Canon.info(book).chapters == 1 ? VerseRef(book, 1, verse) : nil
        default:
            return nil
        }
    }

    private static func dottedForm(_ text: String) -> String? {
        let pieces = text.split(separator: ".")
        guard pieces.count == 3 else { return nil }
        return "\(pieces[0]) \(pieces[1]):\(pieces[2])"
    }
}

/// A USFM verse id: `1`, a bridge `1-2`, or `12a`, whose letter is dropped so `12a` and `12b` are both verse 12.
func verseLabel(_ id: String) -> VerseLabel? {
    let parts = id.split(separator: "-", omittingEmptySubsequences: false)
    func number(_ part: Substring) -> Int? {
        let digits = part.prefix(while: \.isASCIIDigitCharacter)
        guard let value = Int(digits), (1..<PackageSchema.rowIDPartLimit).contains(value),
              part.dropFirst(digits.count).allSatisfy(\.isLetter)
        else { return nil }
        return value
    }
    guard (1...2).contains(parts.count), let first = number(parts[0]) else { return nil }
    guard parts.count == 2 else { return VerseLabel(first) }
    guard let last = number(parts[1]), last >= first else { return nil }
    return last == first ? VerseLabel(first) : VerseLabel(first, through: last)
}

extension Character {
    var isASCIIDigitCharacter: Bool { isASCII && isNumber }
}
