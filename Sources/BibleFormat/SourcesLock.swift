import Foundation

/// The layout of a publisher zip.
public enum SourceFormat: String, Codable, Sendable, Hashable, CaseIterable {
    case usfm
    case usfx
}

/// One plain file of a file set, downloaded from `url` and stored in the set's zip as `name`.
public struct LockedFile: Codable, Sendable, Hashable {
    public var name: String
    public var url: URL
    public var sha256: String
    public var bytes: Int

    public init(name: String, url: URL, sha256: String, bytes: Int) {
        self.name = name
        self.url = url
        self.sha256 = sha256
        self.bytes = bytes
    }

    // A member name becomes a zip entry path that a build extracts by name, so it is one component, never a path.
    public static func isValidName(_ name: String) -> Bool {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return !name.isEmpty && !name.hasPrefix(".") && name.allSatisfy(allowed.contains)
    }

    /// `.../TAHOT%20Gen-Deu%20-%20...%20CC%20BY.txt` is `TAHOT_Gen-Deu_-_..._CC_BY.txt`; nil when the result is not a valid name.
    public static func name(for url: URL) -> String? {
        let name = url.lastPathComponent.replacingOccurrences(of: " ", with: "_")
        return isValidName(name) ? name : nil
    }
}

/// Plain files pinned to one upstream commit, which `bible-pack` archives as one zip it builds itself.
public struct FileSet: Sendable, Hashable {
    /// Sorted by name in UTF-8 byte order.
    public var files: [LockedFile]
    /// The SHA-256 of the zip `bible-pack` builds from `files`, which is deterministic for a given set and revision.
    public var archiveSha256: String
    public var license: String
    public var attribution: String

    public init(files: [LockedFile], archiveSha256: String, license: String, attribution: String) {
        self.files = files
        self.archiveSha256 = archiveSha256
        self.license = license
        self.attribution = attribution
    }
}

/// A locked source. A publisher zip is pinned by its own bytes; a file set by the hash of its members,
/// with `file` naming the zip built from them.
public struct LockedSource: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case zip(SourceFormat, scriptureSha256: String)
        case files(FileSet)
    }

    public var file: String
    public var url: URL
    public var revision: String
    public var sha256: String
    public var bytes: Int
    public var archive: URL
    public var kind: Kind

    public init(file: String, url: URL, revision: String, sha256: String, bytes: Int, archive: URL, kind: Kind) {
        self.file = file
        self.url = url
        self.revision = revision
        self.sha256 = sha256
        self.bytes = bytes
        self.archive = archive
        self.kind = kind
    }

    /// The lock's `format` value: `usfm`, `usfx`, or `files`.
    public var formatName: String {
        switch kind {
        case .zip(let format, _): format.rawValue
        case .files: "files"
        }
    }
}

extension LockedSource: Codable {
    private enum CodingKeys: String, CodingKey {
        case format, file, url, revision, sha256, bytes, archive
        case scriptureSha256
        case files, archiveSha256, license, attribution
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let format = try container.decode(String.self, forKey: .format)
        let kind: Kind
        if format == "files" {
            kind = .files(FileSet(
                files: try container.decode([LockedFile].self, forKey: .files),
                archiveSha256: try container.decode(String.self, forKey: .archiveSha256),
                license: try container.decode(String.self, forKey: .license),
                attribution: try container.decode(String.self, forKey: .attribution)
            ))
        } else if let zipFormat = SourceFormat(rawValue: format) {
            kind = .zip(zipFormat, scriptureSha256: try container.decode(String.self, forKey: .scriptureSha256))
        } else {
            throw DecodingError.dataCorruptedError(forKey: .format, in: container, debugDescription: "unknown source format \(format)")
        }
        self.init(
            file: try container.decode(String.self, forKey: .file),
            url: try container.decode(URL.self, forKey: .url),
            revision: try container.decode(String.self, forKey: .revision),
            sha256: try container.decode(String.self, forKey: .sha256),
            bytes: try container.decode(Int.self, forKey: .bytes),
            archive: try container.decode(URL.self, forKey: .archive),
            kind: kind
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatName, forKey: .format)
        try container.encode(file, forKey: .file)
        try container.encode(url, forKey: .url)
        try container.encode(revision, forKey: .revision)
        try container.encode(sha256, forKey: .sha256)
        try container.encode(bytes, forKey: .bytes)
        try container.encode(archive, forKey: .archive)
        switch kind {
        case .zip(_, let scriptureSha256):
            try container.encode(scriptureSha256, forKey: .scriptureSha256)
        case .files(let set):
            try container.encode(set.files, forKey: .files)
            try container.encode(set.archiveSha256, forKey: .archiveSha256)
            try container.encode(set.license, forKey: .license)
            try container.encode(set.attribution, forKey: .attribution)
        }
    }
}

public enum SourcesLockError: Error, Equatable, CustomStringConvertible {
    case unsupportedVersion(Int)
    case invalidFileName(String)
    case invalidMemberName(String)
    case unsortedFileSet(String)

    public var description: String {
        switch self {
        case .unsupportedVersion(let version):
            "sources lock version \(version) is not supported (expected \(SourcesLock.currentVersion))"
        case .invalidFileName(let file):
            "source file name \(file) must be a plain .zip name with letters, digits, '.', '_', or '-'"
        case .invalidMemberName(let name):
            "file set member name \(name) must be one plain file name with letters, digits, '.', '_', or '-'"
        case .unsortedFileSet(let id):
            "\(id): file set members must be sorted by name with no duplicates"
        }
    }
}

extension LockedSource {
    // The lock names the path the cache writes to, so a name is one component with a safe alphabet, never a path.
    public static func isValidFileName(_ file: String) -> Bool {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return file.hasSuffix(".zip") && file.count > 4 && !file.hasPrefix(".") && file.allSatisfy(allowed.contains)
    }

    /// A zip's `file` is the URL's last component; a file set's is `<id>.zip`, since there is no upstream zip.
    func check(id: String) throws {
        guard Self.isValidFileName(file) else { throw SourcesLockError.invalidFileName(file) }
        switch kind {
        case .zip:
            guard url.lastPathComponent == file else { throw SourcesLockError.invalidFileName(file) }
        case .files(let set):
            guard file == "\(id).zip" else { throw SourcesLockError.invalidFileName(file) }
            if let bad = set.files.first(where: { !LockedFile.isValidName($0.name) }) {
                throw SourcesLockError.invalidMemberName(bad.name)
            }
            let names = set.files.map(\.name)
            guard zip(names, names.dropFirst()).allSatisfy({ $0.utf8.lexicographicallyPrecedes($1.utf8) }) else {
                throw SourcesLockError.unsortedFileSet(id)
            }
        }
    }
}

public struct SourcesLock: Codable, Sendable, Hashable {
    public static let currentVersion = 1
    public static let archiveBase = URL(string: "https://github.com/tuxr/bible-data/releases/download/source-archive")!

    public var version: Int
    public var sources: [String: LockedSource]

    public init(sources: [String: LockedSource] = [:]) {
        self.version = Self.currentVersion
        self.sources = sources
    }

    public init(jsonData: Data) throws {
        let lock = try JSONDecoder().decode(SourcesLock.self, from: jsonData)
        guard lock.version == Self.currentVersion else {
            throw SourcesLockError.unsupportedVersion(lock.version)
        }
        for id in lock.sources.keys.sorted() {
            try lock.sources[id]!.check(id: id)
        }
        self = lock
    }

    public func jsonData() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let compact = try! encoder.encode(self)
        return Data((Self.indent(String(decoding: compact, as: UTF8.self)) + "\n").utf8)
    }

    /// `engwebp_usfx.zip` at 2026-09-22 with sha256 `c883ea0b...` is `engwebp_usfx-2026-09-22-c883ea0b.zip`.
    public static func archiveFileName(file: String, revision: String, sha256: String) -> String {
        let stem = file.hasSuffix(".zip") ? String(file.dropLast(4)) : file
        return "\(stem)-\(revision)-\(sha256.prefix(8)).zip"
    }

    public static func archiveURL(file: String, revision: String, sha256: String) -> URL {
        archiveBase.appending(path: archiveFileName(file: file, revision: revision, sha256: sha256))
    }

    // JSONEncoder's pretty printer writes `"key" : value` and `{\n\n}` for empty objects, and the lock's
    // bytes should not hinge on that implementation detail, so compact output is re-indented here.
    private static func indent(_ compact: String) -> String {
        var out = ""
        var depth = 0
        var inString = false
        var escaped = false
        let chars = Array(compact)
        func newline() { out += "\n" + String(repeating: "  ", count: depth) }
        for (index, char) in chars.enumerated() {
            if inString {
                out.append(char)
                if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == "\"" { inString = false }
                continue
            }
            switch char {
            case "\"":
                inString = true
                out.append(char)
            case "{", "[":
                out.append(char)
                let next = index + 1 < chars.count ? chars[index + 1] : nil
                if next == "}" || next == "]" { continue }
                depth += 1
                newline()
            case "}", "]":
                let previous = index > 0 ? chars[index - 1] : nil
                if previous != "{" && previous != "[" {
                    depth -= 1
                    newline()
                }
                out.append(char)
            case ",":
                out.append(char)
                newline()
            case ":":
                out += ": "
            default:
                out.append(char)
            }
        }
        return out
    }
}
