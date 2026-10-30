import BibleFormat
import Foundation

typealias Download = @Sendable (URL) async throws -> Data

struct SourceRequest: Equatable {
    enum Spec: Equatable {
        case zip(SourceFormat, URL)
        case files(FileSetSpec)
    }

    var id: String
    var spec: Spec
}

extension LockedSource {
    /// What relocking this entry downloads: the same zip URL, or the same members at the same commit.
    func spec() throws -> SourceRequest.Spec {
        switch kind {
        case .zip(let format, _):
            return .zip(format, url)
        case .files(let set):
            guard let commit = GitHubCommit(treeURL: url) else { throw FileSetError.notACommitURL(url) }
            return .files(FileSetSpec(
                commit: commit,
                members: set.files.map { FileSetSpec.Member(name: $0.name, url: $0.url) },
                license: set.license,
                attribution: set.attribution,
                redistributable: archive != nil
            ))
        }
    }
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
            var detail = ""
            if case .zip(_, let was) = old.kind, case .zip(_, let now) = source.kind, was == now {
                detail = ", scripture identical"
            }
            if case .files(let was) = old.kind, case .files(let now) = source.kind {
                let changed = Set(was.files).symmetricDifference(now.files).map(\.name)
                detail = ", files changed: " + Set(changed).sorted().joined(separator: ", ")
            }
            status = "changed from \(old.revision) (\(old.sha256.prefix(8)))\(detail)"
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
        case .nothingLocked:
            "no sources are locked; add one with `bible-pack sources lock --add <id>:<format>:<url>` or `bible-pack sources add-files`"
        }
    }
}

extension SourcesLock {
    /// No ids and no additions selects every locked source; additions alone select only themselves.
    func requests(ids: [String], additions: [SourceRequest]) throws -> [SourceRequest] {
        let named = ids.isEmpty && additions.isEmpty ? sources.keys.sorted() : ids
        let existing = try named.map { id in
            guard let source = sources[id] else { throw SelectionError.unknownSource(id, known: sources.keys.sorted()) }
            return SourceRequest(id: id, spec: try source.spec())
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
            let source: LockedSource
            let bytes: Data
            switch request.spec {
            case .zip(let format, let url):
                bytes = try await download(url)
                source = try LockedSource.make(format: format, url: url, zipBytes: bytes)
            case .files(let spec):
                (source, bytes) = try await LockedSource.make(id: request.id, files: spec, download: download)
            }
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
