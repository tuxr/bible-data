import Foundation

/// `manifest.json`: every published package with its sizes and hashes. `bible-pack manifest build` derives each
/// entry from the package file itself, and the app's Library reads it to list, download, and verify packages.
public struct Manifest: Sendable, Hashable {
    public static let currentVersion = 1
    public static let defaultBaseURL = "https://bible.dws-cloud.com/data/"
    /// Entries list the canon first, then editions, then what the editions point into.
    public static let kindOrder: [PackageKind] = [.canon, .edition, .words, .lexicon]

    public var manifestVersion: Int
    /// ISO 8601 in UTC.
    public var generatedAt: String
    /// Absolute, ending in `/`. Every entry's `url` is relative to it.
    public var baseURL: String
    /// In `listOrder`.
    public var packages: [ManifestEntry]
    /// Kinds this build does not know, skipped when decoding so an older app keeps reading a newer manifest.
    public var unknownKinds: [String] = []

    public init(generatedAt: String, baseURL: String = defaultBaseURL, packages: [ManifestEntry]) {
        self.manifestVersion = Self.currentVersion
        self.generatedAt = generatedAt
        self.baseURL = baseURL
        self.packages = packages.sorted(by: Self.listOrder)
    }

    /// Kind in `kindOrder`, then id, then the newest version first, so the app's pick for an id is the first
    /// entry it supports.
    public static func listOrder(_ lhs: ManifestEntry, _ rhs: ManifestEntry) -> Bool {
        let (left, right) = (kindOrder.firstIndex(of: lhs.kind)!, kindOrder.firstIndex(of: rhs.kind)!)
        if left != right { return left < right }
        if lhs.id != rhs.id { return lhs.id.utf8.lexicographicallyPrecedes(rhs.id.utf8) }
        return lhs.version > rhs.version
    }

    /// Decodes a manifest and runs every check, so a manifest that exists as a value is a valid one.
    public init(jsonData: Data) throws {
        self = try Self.decode(jsonData)
        try check { _, _ in }
    }

    /// Decodes the shape alone: every field each kind requires, with its JSON type. `check` runs the rest.
    public static func decode(_ jsonData: Data) throws -> Manifest {
        do {
            return try JSONDecoder().decode(Manifest.self, from: jsonData)
        } catch let error as DecodingError {
            throw ManifestError(check: .schema, message: Self.describe(error))
        } catch {
            throw ManifestError(check: .schema, message: "\(error)")
        }
    }

    /// Sorted keys, two-space indents, and a trailing newline, so one manifest has one byte form.
    public func jsonData() -> Data {
        CanonicalJSON.data(self)
    }

    /// Reports each passing check to `pass` and throws the first failure, named by its check.
    public func check(pass: (ManifestCheck, String) -> Void) throws {
        func check(_ check: ManifestCheck, _ detail: String, _ failure: String?) throws {
            if let failure { throw ManifestError(check: check, message: failure) }
            pass(check, detail)
        }
        func first(_ failure: (ManifestEntry) -> String?) -> String? {
            for entry in packages {
                if let message = failure(entry) { return "\(entry.id) \(entry.version): \(message)" }
            }
            return nil
        }

        try check(.manifestVersion, "\(manifestVersion)", manifestVersion == Self.currentVersion
            ? nil : "manifest_version is \(manifestVersion), expected \(Self.currentVersion)")
        try check(.generatedAt, generatedAt, ISO8601.isUTCTime(generatedAt)
            ? nil : "generated_at is \(generatedAt), expected an ISO 8601 UTC time such as 2026-10-30T12:00:00Z")
        try check(.baseURL, baseURL, Self.isBaseURL(baseURL)
            ? nil : "base_url is \(baseURL), expected an absolute https URL ending in /")
        try check(.ids, "\(packages.count) entries", first(\.idFailure))
        try check(.files, "every url is its file with .xz, relative to base_url", first(\.fileFailure))
        try check(.released, "every released is a yyyy-mm-dd date", first { ISO8601.isDate($0.released) ? nil : "released is \($0.released), expected yyyy-mm-dd" })
        try check(.sizes, "every size and compressed_size is positive", first { entry in
            entry.size > 0 && entry.compressedSize > 0 ? nil : "size \(entry.size) and compressed_size \(entry.compressedSize) must be positive"
        })
        try check(.hashes, "every hash is 64 lowercase hex digits", first(\.hashFailure))
        try check(.attribution, "every entry credits its sources", first { entry in
            !entry.attribution.isEmpty && !entry.attribution.contains(where: \.isEmpty) ? nil : "attribution must be a nonempty array of nonempty strings"
        })
        try check(.minAppVersion, "every min_app_version is a dotted app version", first { entry in
            Self.isAppVersion(entry.minAppVersion) ? nil : "min_app_version is \(entry.minAppVersion), expected an app version such as 1.0 or 1.2.3"
        })

        var seen: Set<String> = []
        let duplicate = packages.first { !seen.insert("\($0.id) \($0.version)").inserted }
        try check(.unique, "one entry per id and version", duplicate.map { "\($0.id) \($0.version) is listed twice" })
        let unordered = zip(packages, packages.dropFirst()).first { !Self.listOrder($0, $1) }
        try check(.order, "by kind, id, then newest version", unordered.map {
            "\($1.id) \($1.version) is listed after \($0.id) \($0.version); entries go by kind (\(Self.kindOrder.map(\.rawValue).joined(separator: ", "))), id, then newest version"
        })

        let newest = Dictionary(packages.map { ($0.id, $0) }, uniquingKeysWith: { $0.version >= $1.version ? $0 : $1 })
        let unsupported = newest.values.sorted(by: Self.listOrder).first { !(1...$0.kind.formatVersion).contains($0.formatVersion) }
        try check(.formatVersion, "the newest version of every id is a format this builder writes", unsupported.map {
            "\($0.id) \($0.version) has format_version \($0.formatVersion), expected 1 to \($0.kind.formatVersion)"
        })
    }

    static func isBaseURL(_ text: String) -> Bool {
        guard let url = URL(string: text), url.scheme == "https", url.host?.isEmpty == false else { return false }
        return text.hasSuffix("/") && url.query == nil && url.fragment == nil
    }

    /// One to three dot-separated decimal numbers with no leading zeros, such as `1.0` or `1.2.3`.
    public static func isAppVersion(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return (1...3).contains(parts.count) && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber } && (part == "0" || part.first != "0")
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let path = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
            return path.isEmpty ? "" : "\(path.hasPrefix(".") ? String(path.dropFirst()) : path): "
        }
        switch error {
        case .keyNotFound(let key, let context): return "\(path(context))\(key.stringValue) is missing"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(path(context))\(context.debugDescription)"
        @unknown default: return "\(error)"
        }
    }
}

extension Manifest: Codable {
    private enum CodingKeys: String, CodingKey {
        case manifestVersion = "manifest_version"
        case generatedAt = "generated_at"
        case baseURL = "base_url"
        case packages
    }

    private struct KindProbe: Decodable {
        let kind: String
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        manifestVersion = try container.decode(Int.self, forKey: .manifestVersion)
        generatedAt = try container.decode(String.self, forKey: .generatedAt)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        var list = try container.nestedUnkeyedContainer(forKey: .packages)
        var entries: [ManifestEntry] = []
        var unknown: [String] = []
        while !list.isAtEnd {
            let element = try list.superDecoder()
            let kind = try KindProbe(from: element).kind
            if PackageKind(rawValue: kind) == nil {
                unknown.append(kind)
            } else {
                entries.append(try ManifestEntry(from: element))
            }
        }
        packages = entries
        unknownKinds = unknown
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(manifestVersion, forKey: .manifestVersion)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(packages, forKey: .packages)
    }
}

/// The checks `Manifest.check` runs, in order, and the name a failure carries.
public enum ManifestCheck: String, CaseIterable, Sendable {
    case schema
    case manifestVersion = "manifest_version"
    case generatedAt = "generated_at"
    case baseURL = "base_url"
    case ids
    case files
    case released
    case sizes
    case hashes
    case attribution
    case minAppVersion = "min_app_version"
    case unique
    case order
    case formatVersion = "format_version"
}

public struct ManifestError: Error, Equatable, CustomStringConvertible {
    public let check: ManifestCheck
    public let message: String

    public init(check: ManifestCheck, message: String) {
        self.check = check
        self.message = message
    }

    public var description: String { "\(check.rawValue): \(message)" }
}

/// One package version in the manifest. The fields every kind shares are stored here, and `details` holds the
/// fields of its kind, which the JSON carries at the same level.
public struct ManifestEntry: Sendable, Hashable {
    public var id: String
    public var version: PackageVersion
    public var formatVersion: Int
    public var minAppVersion: String
    /// The package's file name.
    public var file: String
    /// The `.xz` download, relative to the manifest's `base_url`.
    public var url: String
    /// The package's size in bytes.
    public var size: Int
    public var compressedSize: Int
    /// The SHA-256 of the package, which the app checks after decompressing the download.
    public var sha256: String
    public var compressedSha256: String
    /// The UTC date of the package's `meta.built_at`, `yyyy-mm-dd`.
    public var released: String
    public var attribution: [String]
    public var details: Details

    public enum Details: Sendable, Hashable {
        case canon
        case edition(ManifestEdition)
        case words(ManifestWords)
        case lexicon(ManifestLexicon)

        public var kind: PackageKind {
            switch self {
            case .canon: .canon
            case .edition: .edition
            case .words: .words
            case .lexicon: .lexicon
            }
        }
    }

    public var kind: PackageKind { details.kind }

    /// `file` and `url` follow from the kind, the id, and the version.
    public init(
        id: String, version: PackageVersion, formatVersion: Int, minAppVersion: String,
        size: Int, compressedSize: Int, sha256: String, compressedSha256: String,
        released: String, attribution: [String], details: Details
    ) {
        self.id = id
        self.version = version
        self.formatVersion = formatVersion
        self.minAppVersion = minAppVersion
        self.size = size
        self.compressedSize = compressedSize
        self.sha256 = sha256
        self.compressedSha256 = compressedSha256
        self.released = released
        self.attribution = attribution
        self.details = details
        self.file = Self.fileName(id: id, version: version, details: details) ?? ""
        self.url = Self.downloadName(file)
    }

    public static func downloadName(_ file: String) -> String { file + ".xz" }

    /// The `released` date of a package built at `builtAt`, an ISO 8601 UTC time. Nil when it is not one.
    public static func released(builtAt: String) -> String? {
        ISO8601.date(of: builtAt)
    }

    /// The id the kind gives: `canon`, the edition id, `<edition>-words`, or `lexicon-<greek|hebrew>`. Nil when
    /// the details name no valid edition or language.
    public var expectedID: String? {
        switch details {
        case .canon: "canon"
        case .edition: EditionMetadata.isValidID(id) ? id : nil
        case .words(let words): EditionMetadata.isValidID(words.edition) ? "\(words.edition)-words" : nil
        case .lexicon(let lexicon): LexiconLanguage(code: lexicon.language).map { "lexicon-\($0.rawValue)" }
        }
    }

    /// The package file name, as `bible-pack` writes it. See FORMAT.md, File names.
    public var expectedFile: String? { Self.fileName(id: id, version: version, details: details) }

    private static func fileName(id: String, version: PackageVersion, details: Details) -> String? {
        let version = version.description
        return switch details {
        case .canon: CanonSchema.fileName(version: version)
        case .edition: PackageSchema.fileName(id: id, version: version)
        case .words(let words): WordsSchema.fileName(edition: words.edition, version: version)
        case .lexicon(let lexicon): LexiconLanguage(code: lexicon.language)?.fileName(version: version)
        }
    }

    var idFailure: String? {
        guard let expected = expectedID else { return "\(kind.rawValue) details name no valid edition id or lexicon language" }
        return id == expected ? nil : "id must be \(expected) for this \(kind.rawValue)"
    }

    var fileFailure: String? {
        guard let expected = expectedFile, file == expected else { return "file is \(file), expected \(expectedFile ?? "a package file name")" }
        return url == Self.downloadName(file) ? nil : "url is \(url), expected \(Self.downloadName(file)), relative to base_url"
    }

    var hashFailure: String? {
        var hashes = [("sha256", sha256), ("compressed_sha256", compressedSha256)]
        switch details {
        case .edition(let edition): hashes.append(("source.sha256", edition.source.sha256))
        case .words(let words): hashes.append(("edition_source_sha256", words.editionSourceSha256))
        case .canon, .lexicon: break
        }
        return hashes.first { !isSHA256Hex($0.1) }.map { "\($0.0) is \($0.1), expected 64 lowercase hex digits" }
    }
}

extension ManifestEntry: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, version, file, url, size, sha256, released, attribution
        case formatVersion = "format_version"
        case minAppVersion = "min_app_version"
        case compressedSize = "compressed_size"
        case compressedSha256 = "compressed_sha256"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kindName = try container.decode(String.self, forKey: .kind)
        guard let kind = PackageKind(rawValue: kindName) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown kind \(kindName)")
        }
        details = switch kind {
        case .canon: .canon
        case .edition: .edition(try ManifestEdition(from: decoder))
        case .words: .words(try ManifestWords(from: decoder))
        case .lexicon: .lexicon(try ManifestLexicon(from: decoder))
        }
        id = try container.decode(String.self, forKey: .id)
        version = try container.decode(PackageVersion.self, forKey: .version)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        minAppVersion = try container.decode(String.self, forKey: .minAppVersion)
        file = try container.decode(String.self, forKey: .file)
        url = try container.decode(String.self, forKey: .url)
        size = try container.decode(Int.self, forKey: .size)
        compressedSize = try container.decode(Int.self, forKey: .compressedSize)
        sha256 = try container.decode(String.self, forKey: .sha256)
        compressedSha256 = try container.decode(String.self, forKey: .compressedSha256)
        released = try container.decode(String.self, forKey: .released)
        attribution = try container.decode([String].self, forKey: .attribution)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind.rawValue, forKey: .kind)
        try container.encode(version, forKey: .version)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(minAppVersion, forKey: .minAppVersion)
        try container.encode(file, forKey: .file)
        try container.encode(url, forKey: .url)
        try container.encode(size, forKey: .size)
        try container.encode(compressedSize, forKey: .compressedSize)
        try container.encode(sha256, forKey: .sha256)
        try container.encode(compressedSha256, forKey: .compressedSha256)
        try container.encode(released, forKey: .released)
        try container.encode(attribution, forKey: .attribution)
        switch details {
        case .canon: break
        case .edition(let edition): try edition.encode(to: encoder)
        case .words(let words): try words.encode(to: encoder)
        case .lexicon(let lexicon): try lexicon.encode(to: encoder)
        }
    }
}

/// An edition entry's fields, from the package's `edition` row.
public struct ManifestEdition: Codable, Sendable, Hashable {
    public var name: String
    public var abbreviation: String
    public var language: String
    public var script: Script
    public var direction: TextDirection
    public var versification: VersificationScheme
    public var license: String
    public var publisher: String
    public var source: Source

    /// The locked publisher source the package was built from.
    public struct Source: Codable, Sendable, Hashable {
        public var url: String
        public var revision: String
        public var sha256: String

        public init(url: String, revision: String, sha256: String) {
            self.url = url
            self.revision = revision
            self.sha256 = sha256
        }
    }

    public init(
        name: String, abbreviation: String, language: String, script: Script, direction: TextDirection,
        versification: VersificationScheme, license: String, publisher: String, source: Source
    ) {
        self.name = name
        self.abbreviation = abbreviation
        self.language = language
        self.script = script
        self.direction = direction
        self.versification = versification
        self.license = license
        self.publisher = publisher
        self.source = source
    }
}

/// A words entry's fields, from the package's `meta`. The app installs a words package only beside the
/// edition whose `source.sha256` is its `edition_source_sha256`.
public struct ManifestWords: Codable, Sendable, Hashable {
    public var edition: String
    /// The language of the edition's words, `hbo` or `grc`, which names the lexicon they point into.
    public var language: String
    public var editionSourceSha256: String
    public var sources: [String]

    private enum CodingKeys: String, CodingKey {
        case edition, language, sources
        case editionSourceSha256 = "edition_source_sha256"
    }

    public init(edition: String, language: String, editionSourceSha256: String, sources: [String]) {
        self.edition = edition
        self.language = language
        self.editionSourceSha256 = editionSourceSha256
        self.sources = sources
    }
}

/// A lexicon entry's fields, from the package's `meta`.
public struct ManifestLexicon: Codable, Sendable, Hashable {
    /// `grc` or `hbo`.
    public var language: String
    public var sources: [String]

    public init(language: String, sources: [String]) {
        self.language = language
        self.sources = sources
    }
}

/// `manifest/policy.json`: the oldest app version that opens each kind at each format version, the one manifest
/// field a package file cannot say about itself.
public struct ManifestPolicy: Sendable, Hashable {
    public let minAppVersions: [PackageKind: [Int: String]]

    public init(minAppVersions: [PackageKind: [Int: String]]) {
        self.minAppVersions = minAppVersions
    }

    /// Decodes `{"min_app_version": {<kind>: {<format version>: <app version>}}}`.
    public init(jsonData: Data) throws {
        let raw: [String: [String: [String: String]]]
        do {
            raw = try JSONDecoder().decode([String: [String: [String: String]]].self, from: jsonData)
        } catch {
            throw ManifestPolicyError("does not decode as {\"min_app_version\": {kind: {format version: app version}}}: \(error)")
        }
        guard raw.keys.sorted() == ["min_app_version"], let table = raw["min_app_version"] else {
            throw ManifestPolicyError("holds keys \(raw.keys.sorted()), expected only min_app_version")
        }
        var versions: [PackageKind: [Int: String]] = [:]
        for (kindName, byFormat) in table {
            guard let kind = PackageKind(rawValue: kindName) else { throw ManifestPolicyError("names unknown kind \(kindName)") }
            for (formatName, appVersion) in byFormat {
                guard let format = Int(formatName), format >= 1, "\(format)" == formatName else {
                    throw ManifestPolicyError("\(kindName) names format version \(formatName), expected a positive integer")
                }
                guard Manifest.isAppVersion(appVersion) else {
                    throw ManifestPolicyError("\(kindName) format \(format) names app version \(appVersion), expected one such as 1.0")
                }
                versions[kind, default: [:]][format] = appVersion
            }
        }
        self.minAppVersions = versions
    }

    public func minAppVersion(kind: PackageKind, formatVersion: Int) -> String? {
        minAppVersions[kind]?[formatVersion]
    }
}

public struct ManifestPolicyError: Error, Equatable, CustomStringConvertible {
    public let reason: String

    init(_ reason: String) { self.reason = reason }

    public var description: String { "manifest policy \(reason)" }
}

extension PackageKind {
    /// The newest format version of the kind. The canon numbers its schema apart from the other packages.
    public var formatVersion: Int {
        self == .canon ? CanonSchema.version : PackageFormat.version
    }
}

func isSHA256Hex(_ text: String) -> Bool {
    text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

/// The two time forms the manifest uses, both in UTC.
enum ISO8601 {
    static func isUTCTime(_ text: String) -> Bool {
        guard let date = try? Date.ISO8601FormatStyle().parse(text) else { return false }
        return date.formatted(Date.ISO8601FormatStyle()) == text
    }

    static func isDate(_ text: String) -> Bool {
        let style = Date.ISO8601FormatStyle().year().month().day()
        guard let date = try? style.parse(text) else { return false }
        return date.formatted(style) == text
    }

    static func date(of time: String) -> String? {
        guard let date = try? Date.ISO8601FormatStyle().parse(time) else { return nil }
        return date.formatted(Date.ISO8601FormatStyle().year().month().day())
    }
}
