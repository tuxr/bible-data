import BibleFormat
import Foundation

struct ParseReport: Sendable, Equatable {
    var warnings: [String] = []
}

struct ParsedEdition: Sendable {
    let books: [ParsedBook]
    let report: ParseReport
}

/// An edition `bible-pack` builds: its locked source, the scheme it numbers verses in, and the repairs its
/// publisher's file needs. Repairs are per edition and never part of the generic parsers.
struct Edition: Sendable {
    let id: String
    let scheme: VersificationScheme
    let repair: EditionRepair

    static let all: [Edition] = [
        Edition(id: "bsb", scheme: .eng, repair: .bsb),
        Edition(id: "wlc", scheme: .heb, repair: .wlc),
        Edition(id: "tcgnt", scheme: .grc, repair: .tcgnt),
    ]

    static func named(_ id: String) -> Edition? {
        all.first { $0.id == id }
    }

    func parse(lock: SourcesLock, cache: SourceCache) throws -> ParsedEdition {
        guard let source = lock.sources[id] else { throw EditionError.notLocked(id) }
        return try EditionSource.load(source, id: id, cache: cache).parse(self)
    }

    /// Parses any zip in the layout of the edition's locked source, such as a revision the lock does not pin.
    func parse(zip bytes: Data, lock: SourcesLock, name: String) throws -> ParsedEdition {
        guard let source = lock.sources[id] else { throw EditionError.notLocked(id) }
        guard case .zip(let format, _) = source.kind else { throw EditionError.notAZip(id: id) }
        return try EditionSource.read(bytes, format: format, file: name).parse(self)
    }
}

enum EditionError: Error, Equatable, CustomStringConvertible {
    case notLocked(String)
    case missing(file: String, id: String)
    case hashMismatch(file: String, id: String)
    case notAZip(id: String)

    var description: String {
        switch self {
        case .notLocked(let id): "\(id) is not in the sources lock"
        case .missing(let file, let id): "\(file) is not in the sources directory; run `bible-pack sources fetch \(id)`"
        case .hashMismatch(let file, let id):
            "\(file) does not match its locked sha256; run `bible-pack sources fetch \(id)`"
        case .notAZip(let id): "\(id) is locked as a file set, not a publisher zip"
        }
    }
}

/// A publisher source as the parsers read it: one USFM file per book, or one USFX document.
enum EditionSource {
    case usfm(files: [(name: String, data: Data)])
    case usfx(Data)

    static func load(_ source: LockedSource, id: String, cache: SourceCache) throws -> EditionSource {
        guard case .zip(let format, _) = source.kind else { throw EditionError.notAZip(id: id) }
        guard let bytes = cache.contents(of: source.file) else { throw EditionError.missing(file: source.file, id: id) }
        guard sha256Hex(bytes) == source.sha256 else { throw EditionError.hashMismatch(file: source.file, id: id) }
        return try read(bytes, format: format, file: source.file)
    }

    static func read(_ bytes: Data, format: SourceFormat, file: String) throws -> EditionSource {
        let zip = try ZipArchive(bytes)
        switch format {
        case .usfm:
            let entries = zip.entries.filter { $0.path.hasSuffix(".usfm") }
            guard !entries.isEmpty else { throw ScriptureError.noUSFM(file: file) }
            return .usfm(files: try entries.map { ($0.path, try zip.contents(of: $0)) })
        case .usfx:
            let matches = zip.entries.filter { $0.path.hasSuffix("_usfx.xml") }
            guard let entry = matches.first else { throw ScriptureError.noUSFX(file: file) }
            guard matches.count == 1 else { throw ScriptureError.multipleUSFX(file: file, paths: matches.map(\.path)) }
            return .usfx(try zip.contents(of: entry))
        }
    }

    func parse(_ edition: Edition) -> ParsedEdition {
        let counts = try? Versification.counts(for: edition.scheme)
        var books: [ParsedBook] = []
        var warnings: [String] = []
        switch self {
        case .usfm(let files):
            for file in files {
                let text = edition.repair.source(String(decoding: file.data, as: UTF8.self))
                guard let id = USFMParser.bookID(text) else {
                    warnings.append("\(file.name): no \\id line, skipped")
                    continue
                }
                guard let book = Book(rawValue: id) else {
                    if !peripheralBookIDs.contains(id) { warnings.append("\(file.name): unknown book id \(id), skipped") }
                    continue
                }
                let parsed = USFMParser.parse(text, book: book, scheme: counts)
                warnings.append(contentsOf: parsed.warnings)
                books.append(parsed.book)
            }
        case .usfx(let data):
            let text = edition.repair.source(String(decoding: data, as: UTF8.self))
            let parsed = USFXParser.parse(Data(text.utf8), scheme: counts)
            warnings.append(contentsOf: parsed.warnings)
            books = parsed.books
        }
        let repaired = books.sorted { $0.book < $1.book }.map { book in
            ParsedBook(
                book: book.book,
                name: book.name,
                shortName: book.shortName,
                chapters: book.chapters.map(edition.repair.chapter),
                absentVerses: book.absentVerses
            )
        }
        for (book, next) in zip(repaired, repaired.dropFirst()) where book.book == next.book {
            warnings.append("\(book.book.rawValue): the book appears twice")
        }
        return ParsedEdition(books: repaired, report: ParseReport(warnings: warnings))
    }
}

enum EditionRepair: Sendable {
    case none
    case bsb
    case wlc
    case tcgnt

    func source(_ text: String) -> String {
        switch self {
        case .none: text
        case .bsb: BSBRepair.markup(text)
        case .wlc: WLCRepair.markup(text)
        case .tcgnt: TCGNTRepair.markup(text)
        }
    }

    func chapter(_ chapter: ParsedChapter) -> ParsedChapter {
        switch self {
        case .none, .wlc, .tcgnt: chapter
        case .bsb: BSBRepair.repair(chapter)
        }
    }
}
