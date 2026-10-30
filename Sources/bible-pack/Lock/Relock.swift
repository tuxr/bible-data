import BibleFormat
import Foundation

typealias Download = @Sendable (URL) async throws -> Data

struct SourceRequest: Equatable {
    var id: String
    var format: SourceFormat
    var url: URL
}

enum LockChange: Equatable {
    case added
    case unchanged
    case changed(from: LockedSource)
}

struct RelockResult {
    var id: String
    var source: LockedSource
    var change: LockChange
    var zipBytes: Data

    var line: String {
        let status: String
        switch change {
        case .added:
            status = "added"
        case .unchanged:
            status = "unchanged"
        case .changed(let old):
            let scripture = old.scriptureSha256 == source.scriptureSha256 ? ", scripture identical" : ""
            status = "changed from \(old.revision) (\(old.sha256.prefix(8)))\(scripture)"
        }
        return "\(source.revision)  \(source.sha256.prefix(8))  \(status)"
    }
}

enum SelectionError: Error, Equatable, CustomStringConvertible {
    case unknownSource(String, known: [String])
    case alreadyLocked(String)
    case duplicate(String)
    case nothingLocked

    var description: String {
        switch self {
        case .unknownSource(let id, let known):
            known.isEmpty
                ? "unknown source \(id); the lock is empty"
                : "unknown source \(id); locked sources are \(known.joined(separator: ", "))"
        case .alreadyLocked(let id): "\(id) is already locked; relock it with `bible-pack sources lock \(id)`"
        case .duplicate(let id): "\(id) is named more than once"
        case .nothingLocked: "no sources are locked; add one with `bible-pack sources lock --add <id>:<format>:<url>`"
        }
    }
}

extension SourcesLock {
    /// No ids and no additions selects every locked source; additions alone select only themselves.
    func requests(ids: [String], additions: [SourceRequest]) throws -> [SourceRequest] {
        let named = ids.isEmpty && additions.isEmpty ? sources.keys.sorted() : ids
        let existing = try named.map { id in
            guard let source = sources[id] else { throw SelectionError.unknownSource(id, known: sources.keys.sorted()) }
            return SourceRequest(id: id, format: source.format, url: source.url)
        }
        for addition in additions where sources[addition.id] != nil {
            throw SelectionError.alreadyLocked(addition.id)
        }
        let all = existing + additions
        var seen = Set<String>()
        for request in all where !seen.insert(request.id).inserted {
            throw SelectionError.duplicate(request.id)
        }
        return all
    }

    func locked(ids: [String]) throws -> [(id: String, source: LockedSource)] {
        let named = ids.isEmpty ? sources.keys.sorted() : ids
        if named.isEmpty { throw SelectionError.nothingLocked }
        return try named.map { id in
            guard let source = sources[id] else { throw SelectionError.unknownSource(id, known: sources.keys.sorted()) }
            return (id, source)
        }
    }

    func relock(_ requests: [SourceRequest], download: Download) async throws -> [RelockResult] {
        var results: [RelockResult] = []
        for request in requests {
            let bytes = try await download(request.url)
            let source = try LockedSource.make(format: request.format, url: request.url, zipBytes: bytes)
            let change: LockChange
            if let old = sources[request.id] {
                change = old == source ? .unchanged : .changed(from: old)
            } else {
                change = .added
            }
            results.append(RelockResult(id: request.id, source: source, change: change, zipBytes: bytes))
        }
        return results
    }

    func applying(_ results: [RelockResult]) -> SourcesLock {
        var lock = self
        for result in results { lock.sources[result.id] = result.source }
        return lock
    }
}
