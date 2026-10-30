import Foundation

/// `lxx` is reserved for the Septuagint and is not defined until an edition needs it.
public enum VersificationScheme: String, Codable, CaseIterable, Sendable {
    case eng
    case heb
    case grc
}

public enum VersificationError: Error, Equatable, CustomStringConvertible {
    case missingResource(String)
    case malformed(file: String, reason: String)

    public var description: String {
        switch self {
        case .missingResource(let name): "versification resource \(name) is missing from the bundle"
        case .malformed(let file, let reason): "\(file): \(reason)"
        }
    }
}

public struct VerseCounts: Sendable, Hashable {
    public let scheme: VersificationScheme
    public let books: [Book]
    private let versesPerChapter: [Book: [Int]]

    public func chapters(in book: Book) -> Int? {
        versesPerChapter[book]?.count
    }

    public func verses(in book: Book, chapter: Int) -> Int? {
        guard let chapters = versesPerChapter[book], chapters.indices.contains(chapter - 1) else { return nil }
        return chapters[chapter - 1]
    }

    public func contains(_ ref: VerseRef) -> Bool {
        guard let count = verses(in: ref.book, chapter: ref.chapter) else { return false }
        return (1...count).contains(ref.verse)
    }

    public var chapterCount: Int { versesPerChapter.values.reduce(0) { $0 + $1.count } }
    public var verseCount: Int { versesPerChapter.values.reduce(0) { $0 + $1.reduce(0, +) } }

    /// Every verse of the scheme in canonical order.
    public var verseRefs: [VerseRef] {
        books.flatMap { book in
            versesPerChapter[book, default: []].enumerated().flatMap { index, count in
                (1...count).map { VerseRef(book, index + 1, $0) }
            }
        }
    }
}

extension VerseCounts {
    private struct File: Decodable {
        struct BookCounts: Decodable {
            let book: Book
            let verses: [Int]
        }

        let scheme: VersificationScheme
        let books: [BookCounts]
    }

    init(decoding data: Data, expected scheme: VersificationScheme) throws {
        let fileName = "\(scheme.rawValue).json"
        func fail(_ reason: String) -> VersificationError { .malformed(file: fileName, reason: reason) }

        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: data)
        } catch {
            throw fail("\(error)")
        }
        guard file.scheme == scheme else { throw fail("declares scheme \(file.scheme.rawValue)") }
        let books = file.books.map(\.book)
        guard books == books.sorted(), Set(books).count == books.count else {
            throw fail("books are not unique and in canonical order")
        }
        for entry in file.books {
            guard (1..<PackageSchema.rowIDPartLimit).contains(entry.verses.count),
                  entry.verses.allSatisfy({ (1..<PackageSchema.rowIDPartLimit).contains($0) })
            else {
                throw fail("\(entry.book.rawValue) has a chapter or verse count outside 1...\(PackageSchema.rowIDPartLimit - 1)")
            }
        }
        self.scheme = scheme
        self.books = books
        self.versesPerChapter = Dictionary(uniqueKeysWithValues: file.books.map { ($0.book, $0.verses) })
    }
}

public enum Versification {
    public static func counts(for scheme: VersificationScheme) throws -> VerseCounts {
        guard let loaded = loadedCounts[scheme] else { preconditionFailure("every scheme is loaded") }
        return try loaded.get()
    }

    /// The mapping from one scheme's numbering to another's, read from `<source>-<target>.json` or the reverse
    /// of `<target>-<source>.json`. Nil when no file relates the two schemes.
    public static func mapping(
        from source: VersificationScheme,
        to target: VersificationScheme
    ) throws -> VersificationMapping? {
        if source == target {
            return VersificationMapping(identity: try counts(for: source))
        }
        return try loadedMappings[SchemePair(source: source, target: target)]?.get()
    }

    private struct SchemePair: Hashable {
        let source: VersificationScheme
        let target: VersificationScheme
    }

    private static let loadedCounts: [VersificationScheme: Result<VerseCounts, any Error>] =
        Dictionary(uniqueKeysWithValues: VersificationScheme.allCases.map { scheme in
            (scheme, Result {
                try VerseCounts(decoding: resource(scheme.rawValue), expected: scheme)
            })
        })

    private static let loadedMappings: [SchemePair: Result<VersificationMapping, any Error>] = {
        var mappings: [SchemePair: Result<VersificationMapping, any Error>] = [:]
        for source in VersificationScheme.allCases {
            for target in VersificationScheme.allCases where target != source {
                let name = "\(source.rawValue)-\(target.rawValue)"
                guard let url = resourceURL(name) else { continue }
                let forward = Result {
                    try VersificationMapping(
                        decoding: read(url, name: name),
                        from: counts(for: source),
                        to: counts(for: target)
                    )
                }
                mappings[SchemePair(source: source, target: target)] = forward
                mappings[SchemePair(source: target, target: source)] = forward.map { $0.reversed() }
            }
        }
        return mappings
    }()

    private static func resourceURL(_ name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "versification")
    }

    private static func resource(_ name: String) throws -> Data {
        guard let url = resourceURL(name) else { throw VersificationError.missingResource("\(name).json") }
        return try read(url, name: name)
    }

    private static func read(_ url: URL, name: String) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw VersificationError.missingResource("\(name).json")
        }
    }
}
