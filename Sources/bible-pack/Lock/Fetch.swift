import BibleFormat
import Foundation

enum FetchOrigin: String, Equatable {
    case archive
    case url
    case members
}

enum FetchOutcome: Equatable {
    case present
    case fetched(from: FetchOrigin)
    case failed(problems: [String])

    var status: String {
        switch self {
        case .present: "present"
        case .fetched(let origin): "fetched from \(origin.rawValue)"
        case .failed(let problems): "failed: \(problems.joined(separator: "; "))"
        }
    }
}

struct HashMismatch: Error, CustomStringConvertible {
    var sha256: String
    var description: String { "sha256 \(sha256.prefix(8)) does not match" }
}

extension LockedSource {
    /// The SHA-256 of the zip at `<sources-dir>/<file>`: the publisher's zip, or the one built from a file set.
    var zipSha256: String {
        switch kind {
        case .zip: sha256
        case .files(let set): set.archiveSha256
        }
    }

    // Archive first because it holds exactly the locked bytes; the upstream only does until it moves.
    // A file set's upstream is its members, which are rebuilt into the zip the lock names.
    fileprivate func origins(_ download: @escaping Download) -> [(FetchOrigin, () async throws -> Data)] {
        let archived: () async throws -> Data = {
            let bytes = try await download(archive)
            guard sha256Hex(bytes) == zipSha256 else { throw HashMismatch(sha256: sha256Hex(bytes)) }
            if case .files = kind { try Self.checkFileSetArchive(bytes, sha256: sha256) }
            return bytes
        }
        switch kind {
        case .zip:
            return [(.archive, archived), (.url, {
                let bytes = try await download(url)
                guard sha256Hex(bytes) == sha256 else { throw HashMismatch(sha256: sha256Hex(bytes)) }
                return bytes
            })]
        case .files(let set):
            return [(.archive, archived), (.members, { try await rebuildFileSet(set, download: download) })]
        }
    }
}

extension SourceCache {
    func fetch(_ source: LockedSource, download: @escaping Download) async throws -> FetchOutcome {
        if let existing = contents(of: source.file), sha256Hex(existing) == source.zipSha256 { return .present }
        var problems: [String] = []
        for (origin, attempt) in source.origins(download) {
            let bytes: Data
            do {
                bytes = try await attempt()
            } catch {
                problems.append("\(origin.rawValue): \(error)")
                continue
            }
            try store(bytes, as: source.file)
            return .fetched(from: origin)
        }
        try evict(source.file)
        return .failed(problems: problems)
    }
}
