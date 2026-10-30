import Foundation

public enum SourceFormat: String, Codable, Sendable, Hashable, CaseIterable {
    case usfm
    case usfx
}

public struct LockedSource: Codable, Sendable, Hashable {
    public var format: SourceFormat
    public var file: String
    public var url: URL
    public var revision: String
    public var sha256: String
    public var bytes: Int
    public var scriptureSha256: String
    public var archive: URL

    public init(
        format: SourceFormat,
        file: String,
        url: URL,
        revision: String,
        sha256: String,
        bytes: Int,
        scriptureSha256: String,
        archive: URL
    ) {
        self.format = format
        self.file = file
        self.url = url
        self.revision = revision
        self.sha256 = sha256
        self.bytes = bytes
        self.scriptureSha256 = scriptureSha256
        self.archive = archive
    }
}

public enum SourcesLockError: Error, Equatable, CustomStringConvertible {
    case unsupportedVersion(Int)
    case invalidFileName(String)

    public var description: String {
        switch self {
        case .unsupportedVersion(let version):
            "sources lock version \(version) is not supported (expected \(SourcesLock.currentVersion))"
        case .invalidFileName(let file):
            "source file name \(file) must be a plain .zip name with letters, digits, '.', '_', or '-'"
        }
    }
}

extension LockedSource {
    // The lock names the path the cache writes to, so a name is one component with a safe alphabet, never a path.
    public static func isValidFileName(_ file: String) -> Bool {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return file.hasSuffix(".zip") && file.count > 4 && !file.hasPrefix(".") && file.allSatisfy(allowed.contains)
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
        if let bad = lock.sources.values.first(where: { !LockedSource.isValidFileName($0.file) || $0.url.lastPathComponent != $0.file }) {
            throw SourcesLockError.invalidFileName(bad.file)
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
