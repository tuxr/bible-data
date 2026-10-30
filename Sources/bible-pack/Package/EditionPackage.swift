import BibleFormat
import Foundation

/// An edition ready to package: its metadata, its locked source, and its parse.
struct EditionInput {
    let edition: Edition
    let metadata: EditionMetadata
    let source: LockedSource
    let books: [ParsedBook]

    /// Reads `editions/<id>.json`, checks it against the lock and the edition's scheme, and parses the
    /// source. A parse with warnings is refused, so a package never holds text a parser was unsure of.
    static func load(_ id: String, editionsDirectory: URL, lock: SourcesLock, cache: SourceCache) throws -> EditionInput {
        guard let edition = Edition.named(id) else {
            throw PackageError(description: "unknown edition \(id); known: \(Edition.all.map(\.id).joined(separator: ", "))")
        }
        let file = editionsDirectory.appendingPathComponent("\(id).json")
        guard let data = FileManager.default.contents(atPath: file.path) else {
            throw PackageError(description: "\(file.path) does not exist")
        }
        let metadata = try EditionMetadata(jsonData: data, lock: lock)
        guard metadata.id == id, metadata.source == edition.id, let source = lock.sources[metadata.source] else {
            throw PackageError(description: "\(file.path) names edition \(metadata.id) and source \(metadata.source), expected \(id)")
        }
        guard metadata.versification == edition.scheme else {
            throw PackageError(description: "\(file.path) names versification \(metadata.versification.rawValue), but \(id) parses in \(edition.scheme.rawValue)")
        }
        let parsed = try edition.parse(lock: lock, cache: cache)
        guard parsed.report.warnings.isEmpty else {
            throw PackageError(description: "\(id) parsed with \(parsed.report.warnings.count) warnings, first: \(parsed.report.warnings[0]); run `bible-pack parse \(id)`")
        }
        return EditionInput(edition: edition, metadata: metadata, source: source, books: parsed.books)
    }

    func content(version: PackageVersion, builtAt: String, encoding: ChapterEncoding) -> PackageContent {
        PackageContent(metadata: metadata, source: source, books: books, version: version, builtAt: builtAt, encoding: encoding)
    }
}

enum EditionPackage {
    /// The encoding `build` writes when `--encoding` is not given.
    static let defaultEncoding = ChapterEncoding.binary

    static func build(_ content: PackageContent, to destination: URL) throws -> PackageBuildSummary {
        try PackageWriter.build(ddl: PackageSchema.ddl, tables: try content.tables(), to: destination) { database in
            try database.exec("INSERT INTO verses_fts (verses_fts) VALUES ('optimize')")
        }
    }
}
