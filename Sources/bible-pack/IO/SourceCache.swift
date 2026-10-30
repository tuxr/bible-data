import BibleFormat
import Foundation

/// The local `<sources-dir>`: `<file>` holds the zip a build reads, and `archive/` keeps every other
/// revision that was ever in its place, so replacing a file never loses bytes.
struct SourceCache {
    let directory: URL

    func path(of file: String) -> URL {
        precondition(LockedSource.isValidFileName(file), "cache file names are validated when the lock is read")
        return directory.appending(path: file)
    }

    func contents(of file: String) -> Data? {
        try? Data(contentsOf: path(of: file))
    }

    func store(_ bytes: Data, as file: String) throws {
        if let existing = contents(of: file) {
            if existing == bytes { return }
            try preserve(existing, file: file)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: path(of: file), options: .atomic)
    }

    /// Moves whatever sits at `<file>` into `archive/` so it can no longer be mistaken for the locked bytes.
    func evict(_ file: String) throws {
        guard let existing = contents(of: file) else { return }
        try preserve(existing, file: file)
        try FileManager.default.removeItem(at: path(of: file))
    }

    /// Writes `archive/<archive name>` for a revision of `file`. Bytes that do not parse as a zip are not a source
    /// revision, so there is nothing to keep and the result is nil.
    @discardableResult
    func preserve(_ bytes: Data, file: String) throws -> URL? {
        guard let revision = try? ZipArchive(bytes).revisionDate() else { return nil }
        let archive = directory.appending(path: "archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let path = archive.appending(path: SourcesLock.archiveFileName(file: file, revision: revision, sha256: sha256Hex(bytes)))
        try bytes.write(to: path, options: .atomic)
        return path
    }
}
