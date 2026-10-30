import BibleFormat
import CryptoKit
import Foundation

enum ScriptureError: Error, Equatable, CustomStringConvertible {
    case noUSFX(file: String)
    case multipleUSFX(file: String, paths: [String])
    case noUSFM(file: String)

    var description: String {
        switch self {
        case .noUSFX(let file): "\(file) has no *_usfx.xml entry"
        case .multipleUSFX(let file, let paths): "\(file) has more than one *_usfx.xml entry: \(paths.joined(separator: ", "))"
        case .noUSFM(let file): "\(file) has no .usfm entries"
        }
    }
}

extension LockedSource {
    static func make(format: SourceFormat, url: URL, zipBytes: Data) throws -> LockedSource {
        let file = url.lastPathComponent
        let zip = try ZipArchive(zipBytes)
        let revision = try zip.revisionDate()
        let sha256 = sha256Hex(zipBytes)
        return LockedSource(
            format: format,
            file: file,
            url: url,
            revision: revision,
            sha256: sha256,
            bytes: zipBytes.count,
            scriptureSha256: try scriptureSha256(format: format, zip: zip, file: file),
            archive: SourcesLock.archiveURL(file: file, revision: revision, sha256: sha256)
        )
    }

    // The scripture hash tells a re-zip apart from a text change. The USFM rule prefixes each path so
    // a renamed book changes the hash; both rules match bible-api's lock so its history stays comparable.
    static func scriptureSha256(format: SourceFormat, zip: ZipArchive, file: String) throws -> String {
        switch format {
        case .usfx:
            let matches = zip.entries.filter { $0.path.hasSuffix("_usfx.xml") }
            guard let entry = matches.first else { throw ScriptureError.noUSFX(file: file) }
            guard matches.count == 1 else { throw ScriptureError.multipleUSFX(file: file, paths: matches.map(\.path)) }
            return sha256Hex(try zip.contents(of: entry))
        case .usfm:
            let books = zip.entries
                .filter { $0.path.hasSuffix(".usfm") }
                .sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
            guard !books.isEmpty else { throw ScriptureError.noUSFM(file: file) }
            var hasher = SHA256()
            for book in books {
                hasher.update(data: Data("\(book.path)\n".utf8))
                hasher.update(data: try zip.contents(of: book))
            }
            return hex(hasher.finalize())
        }
    }
}

func sha256Hex(_ data: Data) -> String {
    hex(SHA256.hash(data: data))
}

private func hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
}
