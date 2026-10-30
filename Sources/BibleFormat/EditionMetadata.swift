import Foundation

/// An ISO 15924 script code, the value of `edition.script`. It decides how `SearchText` folds the edition.
public enum Script: String, Codable, CaseIterable, Sendable {
    case latin = "Latn"
    case hebrew = "Hebr"
    case greek = "Grek"

    public var direction: TextDirection {
        switch self {
        case .latin, .greek: .ltr
        case .hebrew: .rtl
        }
    }
}

public enum TextDirection: String, Codable, CaseIterable, Sendable {
    case ltr
    case rtl
}

/// What an edition is, from `editions/<id>.json`. It fills the `edition` row with the locked source's
/// provenance and the build's encoding.
public struct EditionMetadata: Codable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let abbreviation: String
    /// A BCP 47 language tag, such as `en`, `hbo`, or `grc`.
    public let language: String
    public let script: Script
    public let direction: TextDirection
    public let versification: VersificationScheme
    public let license: String
    public let attribution: String
    public let publisher: String
    /// The `sources.lock.json` key of the edition's source.
    public let source: String

    public init(
        id: String,
        name: String,
        abbreviation: String,
        language: String,
        script: Script,
        direction: TextDirection,
        versification: VersificationScheme,
        license: String,
        attribution: String,
        publisher: String,
        source: String
    ) {
        self.id = id
        self.name = name
        self.abbreviation = abbreviation
        self.language = language
        self.script = script
        self.direction = direction
        self.versification = versification
        self.license = license
        self.attribution = attribution
        self.publisher = publisher
        self.source = source
    }

    /// Decodes `editions/<id>.json` and checks it against the lock it builds from.
    public init(jsonData: Data, lock: SourcesLock) throws {
        let metadata: EditionMetadata
        do {
            metadata = try JSONDecoder().decode(EditionMetadata.self, from: jsonData)
        } catch {
            throw EditionMetadataError.malformed("\(error)")
        }
        try metadata.check(lock: lock)
        self = metadata
    }

    private func check(lock: SourcesLock) throws {
        guard Self.isValidID(id) else { throw EditionMetadataError.invalidID(id) }
        let fields = [("name", name), ("abbreviation", abbreviation), ("language", language), ("license", license),
                      ("attribution", attribution), ("publisher", publisher)]
        if let empty = fields.first(where: { $0.1.trimmingCharacters(in: .whitespaces).isEmpty }) {
            throw EditionMetadataError.emptyField(id: id, field: empty.0)
        }
        guard direction == script.direction else {
            throw EditionMetadataError.directionMismatch(id: id, script: script, direction: direction)
        }
        guard lock.sources[source] != nil else { throw EditionMetadataError.sourceNotLocked(id: id, source: source) }
    }

    /// The id is the first part of the package file name, so it is lowercase letters and digits only.
    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }
}

public enum EditionMetadataError: Error, Equatable, CustomStringConvertible {
    case malformed(String)
    case invalidID(String)
    case emptyField(id: String, field: String)
    case directionMismatch(id: String, script: Script, direction: TextDirection)
    case sourceNotLocked(id: String, source: String)

    public var description: String {
        switch self {
        case .malformed(let reason): "edition metadata does not decode: \(reason)"
        case .invalidID(let id): "edition id \(id) must be lowercase letters and digits"
        case .emptyField(let id, let field): "\(id): \(field) is empty"
        case .directionMismatch(let id, let script, let direction):
            "\(id): direction \(direction.rawValue) does not match script \(script.rawValue), which is \(script.direction.rawValue)"
        case .sourceNotLocked(let id, let source): "\(id): source \(source) is not in the sources lock"
        }
    }
}
