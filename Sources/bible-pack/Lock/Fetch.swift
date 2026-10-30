import BibleFormat
import Foundation

enum FetchOrigin: String, Equatable {
    case archive
    case url
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

extension SourceCache {
    /// Archive first because it holds exactly the locked bytes; the upstream URL only does until it moves.
    func fetch(_ source: LockedSource, download: Download) async throws -> FetchOutcome {
        if let existing = contents(of: source.file), sha256Hex(existing) == source.sha256 { return .present }
        var problems: [String] = []
        for (origin, url) in [(FetchOrigin.archive, source.archive), (.url, source.url)] {
            let bytes: Data
            do {
                bytes = try await download(url)
            } catch {
                problems.append("\(origin.rawValue): \(error)")
                continue
            }
            let sha256 = sha256Hex(bytes)
            guard sha256 == source.sha256 else {
                problems.append("\(origin.rawValue): sha256 \(sha256.prefix(8)) does not match")
                continue
            }
            try store(bytes, as: source.file)
            return .fetched(from: origin)
        }
        try evict(source.file)
        return .failed(problems: problems)
    }
}
