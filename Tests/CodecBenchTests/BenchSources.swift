import BibleFormat
import Foundation
import Testing
@testable import bible_pack

/// The three real editions from `.sources/`, parsed once per test process. Suites that need them are skipped when
/// the sources are absent, as in `BiblePackTests`.
enum BenchSources {
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

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

    static let ids = ["bsb", "wlc", "tcgnt"]

    static let chapters: [String: [Chapter]] = Dictionary(uniqueKeysWithValues: ids.map { id in
        do {
            let parsed = try Edition.named(id)!.parse(lock: lock!, cache: cache)
            return (id, parsed.books.flatMap(\.chapters).map(\.chapter))
        } catch {
            preconditionFailure("\(id) does not parse: \(error)")
        }
    })

    static func chapter(_ id: String, _ book: Book, _ number: Int) -> Chapter {
        chapters[id]!.first { $0.book == book && $0.number == number }!
    }
}
