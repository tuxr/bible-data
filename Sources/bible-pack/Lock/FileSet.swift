import BibleFormat
import CryptoKit
import Foundation

/// A commit on GitHub, parsed from `https://github.com/<owner>/<repo>/tree/<40-hex sha>`.
struct GitHubCommit: Equatable {
    var owner: String
    var repo: String
    var sha: String

    init?(treeURL: URL) {
        let parts = treeURL.pathComponents
        guard treeURL.scheme == "https", treeURL.host == "github.com", treeURL.query == nil, treeURL.fragment == nil,
              parts.count == 5, parts[3] == "tree", parts[4].count == 40,
              parts[4].allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) })
        else { return nil }
        (owner, repo, sha) = (parts[1], parts[2], parts[4])
    }

    var treeURL: URL { URL(string: "https://github.com/\(owner)/\(repo)/tree/\(sha)")! }
    var apiURL: URL { URL(string: "https://api.github.com/repos/\(owner)/\(repo)/commits/\(sha)")! }

    /// True for `https://raw.githubusercontent.com/<owner>/<repo>/<sha>/<path>`, a file at exactly this commit.
    func pins(_ raw: URL) -> Bool {
        let parts = raw.pathComponents
        return raw.scheme == "https" && raw.host == "raw.githubusercontent.com" && raw.query == nil && raw.fragment == nil
            && parts.count > 4 && parts[1] == owner && parts[2] == repo && parts[3] == sha
    }

    /// The committer date as YYYY-MM-DD, from the GitHub API.
    func revision(download: Download) async throws -> String {
        struct Commit: Decodable {
            struct Inner: Decodable { struct Person: Decodable { var date: String }; var committer: Person }
            var commit: Inner
        }
        let date = try JSONDecoder().decode(Commit.self, from: try await download(apiURL)).commit.committer.date
        let day = String(date.prefix(10))
        guard (try? midnightUTC(day)) != nil else { throw FileSetError.badCommitDate(date, url: apiURL) }
        return day
    }
}

/// What `add-files` asks for, and what relocking a file set reads back from the lock.
struct FileSetSpec: Equatable {
    struct Member: Equatable {
        var name: String
        var url: URL
    }

    var commit: GitHubCommit
    var members: [Member]
    var license: String
    var attribution: String
    /// False when the files' license asks that they not be redistributed, so the lock names no archive.
    var redistributable = true
}

enum FileSetError: Error, Equatable, CustomStringConvertible {
    case notACommitURL(URL)
    case badCommitDate(String, url: URL)
    case badRevision(String)
    case memberMismatch(name: String, sha256: String)
    case archiveSetMismatch(sha256: String)
    case rebuildMismatch(archiveSha256: String)

    var description: String {
        switch self {
        case .notACommitURL(let url): "\(url.absoluteString) is not https://github.com/<owner>/<repo>/tree/<commit sha>"
        case .badCommitDate(let date, let url): "commit date \(date) from \(url.absoluteString) is not ISO 8601"
        case .badRevision(let revision): "revision \(revision) is not YYYY-MM-DD"
        case .memberMismatch(let name, let sha256): "\(name) sha256 \(sha256.prefix(8)) does not match"
        case .archiveSetMismatch(let sha256): "the files hash to \(sha256.prefix(8)), not the locked sha256"
        case .rebuildMismatch(let sha256):
            "the members match but the rebuilt zip's sha256 \(sha256.prefix(8)) does not match archiveSha256; relock to record the new zip"
        }
    }
}

/// `2026-10-24` is 2026-10-24T00:00:00Z, the time every entry of a file set's zip carries.
func midnightUTC(_ revision: String) throws -> Date {
    let parts = revision.split(separator: "-").compactMap { Int($0) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    guard revision.count == 10, parts.count == 3,
          let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
          calendar.dateComponents([.year, .month, .day], from: date) == DateComponents(year: parts[0], month: parts[1], day: parts[2])
    else { throw FileSetError.badRevision(revision) }
    return date
}

extension LockedSource {
    /// Downloads every member and builds the file set's entry and zip. The revision is the commit's date.
    static func make(id: String, files spec: FileSetSpec, download: Download) async throws -> (source: LockedSource, zipBytes: Data) {
        let revision = try await spec.commit.revision(download: download)
        var members: [(name: String, url: URL, data: Data)] = []
        for member in spec.members {
            members.append((member.name, member.url, try await download(member.url)))
        }
        members.sort { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
        let entries = members.map { (path: $0.name, data: $0.data) }
        let zipBytes = try fileSetZip(entries, revision: revision)
        let sha256 = fileSetSha256(entries)
        let file = "\(id).zip"
        let source = LockedSource(
            file: file,
            url: spec.commit.treeURL,
            revision: revision,
            sha256: sha256,
            bytes: members.reduce(0) { $0 + $1.data.count },
            archive: spec.redistributable ? SourcesLock.archiveURL(file: file, revision: revision, sha256: sha256) : nil,
            kind: .files(FileSet(
                files: members.map { LockedFile(name: $0.name, url: $0.url, sha256: sha256Hex($0.data), bytes: $0.data.count) },
                archiveSha256: sha256Hex(zipBytes),
                license: spec.license,
                attribution: spec.attribution
            ))
        )
        return (source, zipBytes)
    }

    /// Entries in name order, each stamped with the revision at midnight UTC, so a rebuild gives the same bytes.
    static func fileSetZip(_ entries: [(path: String, data: Data)], revision: String) throws -> Data {
        try ZipWriter.write(entries.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }, modified: try midnightUTC(revision))
    }

    // The same rule as the USFM scripture hash: each name, a newline, then its bytes, in name order,
    // so renaming a member changes the hash even when no byte of it does.
    static func fileSetSha256(_ entries: [(path: String, data: Data)]) -> String {
        var hasher = SHA256()
        for entry in entries.sorted(by: { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }) {
            hasher.update(data: Data("\(entry.path)\n".utf8))
            hasher.update(data: entry.data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Checks a downloaded archive zip of a file set against the lock: its own bytes, then its members' set hash.
    static func checkFileSetArchive(_ bytes: Data, sha256: String) throws {
        let zip = try ZipArchive(bytes)
        let actual = fileSetSha256(try zip.entries.map { ($0.path, try zip.contents(of: $0)) })
        guard actual == sha256 else { throw FileSetError.archiveSetMismatch(sha256: actual) }
    }

    /// Downloads the members named in the lock, checks each, and rebuilds the zip, which must match `archiveSha256`.
    func rebuildFileSet(_ set: FileSet, download: Download) async throws -> Data {
        var entries: [(path: String, data: Data)] = []
        for file in set.files {
            let data = try await download(file.url)
            let actual = sha256Hex(data)
            guard actual == file.sha256 else { throw FileSetError.memberMismatch(name: file.name, sha256: actual) }
            entries.append((file.name, data))
        }
        let setSha256 = Self.fileSetSha256(entries)
        guard setSha256 == sha256 else { throw FileSetError.archiveSetMismatch(sha256: setSha256) }
        let zipBytes = try Self.fileSetZip(entries, revision: revision)
        guard sha256Hex(zipBytes) == set.archiveSha256 else { throw FileSetError.rebuildMismatch(archiveSha256: sha256Hex(zipBytes)) }
        return zipBytes
    }
}
