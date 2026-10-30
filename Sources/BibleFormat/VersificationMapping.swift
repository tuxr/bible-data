import Foundation

/// Why two schemes number a verse differently. Files spell each kind by its raw value, in either direction.
public enum MappingKind: String, Codable, CaseIterable, Sendable {
    /// One verse on each side, with different numbers.
    case renumbered
    /// A Psalm title that one scheme numbers as a verse and the other leaves unnumbered.
    case superscriptionAsVerse1
    /// One verse on one side holds the text of several on the other. Each piece is its own pair.
    case splitVerse
    /// The same text printed in a different place.
    case relocated
    /// A verse that only one scheme has, other than a Psalm title.
    case extraVerse

    /// Whether an entry of this kind names a verse on both sides, or on exactly one.
    var isPaired: Bool {
        switch self {
        case .renumbered, .splitVerse, .relocated: true
        case .superscriptionAsVerse1, .extraVerse: false
        }
    }
}

public enum MappingEntry: Hashable, Sendable {
    case pair(source: VerseRef, target: VerseRef, kind: MappingKind)
    case sourceOnly(VerseRef, kind: MappingKind)
    case targetOnly(VerseRef, kind: MappingKind)

    var reversed: MappingEntry {
        switch self {
        case .pair(let source, let target, let kind): .pair(source: target, target: source, kind: kind)
        case .sourceOnly(let ref, let kind): .targetOnly(ref, kind: kind)
        case .targetOnly(let ref, let kind): .sourceOnly(ref, kind: kind)
        }
    }
}

public enum MappedVerse: Hashable, Sendable {
    /// No entry covers the verse, so both schemes number it the same.
    case same(VerseRef)
    /// One or more counterparts in canonical order. More than one when a scheme splits the verse.
    case mapped([VerseRef], MappingKind)
    /// An entry says the verse has no counterpart in the target scheme.
    case absent(MappingKind)
    /// The target scheme does not contain the book.
    case bookAbsent
}

public struct VersificationMapping: Sendable {
    public let source: VersificationScheme
    public let target: VersificationScheme
    public let entries: [MappingEntry]
    private let sourceCounts: VerseCounts
    private let targetCounts: VerseCounts
    private let forward: [VerseRef: MappedVerse]
    private let backward: [VerseRef: MappedVerse]

    /// Nil when `ref` is not a verse of the source scheme.
    public func map(_ ref: VerseRef) -> MappedVerse? {
        guard sourceCounts.contains(ref) else { return nil }
        guard targetCounts.chapters(in: ref.book) != nil else { return .bookAbsent }
        return forward[ref] ?? .same(ref)
    }

    public func reversed() -> VersificationMapping {
        VersificationMapping(
            source: target,
            target: source,
            entries: entries.map(\.reversed),
            sourceCounts: targetCounts,
            targetCounts: sourceCounts,
            forward: backward,
            backward: forward
        )
    }

    private init(
        source: VersificationScheme,
        target: VersificationScheme,
        entries: [MappingEntry],
        sourceCounts: VerseCounts,
        targetCounts: VerseCounts,
        forward: [VerseRef: MappedVerse],
        backward: [VerseRef: MappedVerse]
    ) {
        self.source = source
        self.target = target
        self.entries = entries
        self.sourceCounts = sourceCounts
        self.targetCounts = targetCounts
        self.forward = forward
        self.backward = backward
    }

    init(identity counts: VerseCounts) {
        self.init(
            source: counts.scheme,
            target: counts.scheme,
            entries: [],
            sourceCounts: counts,
            targetCounts: counts,
            forward: [:],
            backward: [:]
        )
    }
}

extension VersificationMapping {
    private struct File: Decodable {
        struct Entry: Decodable {
            let book: Book
            let kind: String
            let source: [Int]?
            let target: [Int]?
        }

        let source: VersificationScheme
        let target: VersificationScheme
        let entries: [Entry]
    }

    init(decoding data: Data, from sourceCounts: VerseCounts, to targetCounts: VerseCounts) throws {
        let fileName = "\(sourceCounts.scheme.rawValue)-\(targetCounts.scheme.rawValue).json"
        func fail(_ reason: String) -> VersificationError { .malformed(file: fileName, reason: reason) }

        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: data)
        } catch {
            throw fail("\(error)")
        }
        guard file.source == sourceCounts.scheme, file.target == targetCounts.scheme else {
            throw fail("declares \(file.source.rawValue)-\(file.target.rawValue)")
        }

        func ref(_ pair: [Int]?, in book: Book, counts: VerseCounts) throws -> VerseRef? {
            guard let pair else { return nil }
            guard pair.count == 2 else { throw fail("\(book.rawValue) \(pair) is not [chapter, verse]") }
            let ref = VerseRef(book, pair[0], pair[1])
            guard counts.contains(ref) else { throw fail("\(ref) is not a verse of \(counts.scheme.rawValue)") }
            return ref
        }

        var entries: [MappingEntry] = []
        for raw in file.entries {
            guard let kind = MappingKind(rawValue: raw.kind) else {
                throw fail("\(raw.book.rawValue) has unknown kind \(raw.kind)")
            }
            let source = try ref(raw.source, in: raw.book, counts: sourceCounts)
            let target = try ref(raw.target, in: raw.book, counts: targetCounts)
            switch (source, target, kind.isPaired) {
            case let (source?, target?, true):
                guard kind != .renumbered || source != target else { throw fail("\(source) is renumbered to itself") }
                entries.append(.pair(source: source, target: target, kind: kind))
            case let (source?, nil, false):
                entries.append(.sourceOnly(source, kind: kind))
            case let (nil, target?, false):
                entries.append(.targetOnly(target, kind: kind))
            default:
                let sides = kind.isPaired ? "both sides" : "exactly one side"
                throw fail("\(raw.book.rawValue) \(kind.rawValue) entry must name \(sides)")
            }
        }

        let index: MappingIndex
        do {
            index = try MappingIndex(entries)
        } catch {
            throw fail("\(error)")
        }
        self.init(
            source: sourceCounts.scheme,
            target: targetCounts.scheme,
            entries: entries,
            sourceCounts: sourceCounts,
            targetCounts: targetCounts,
            forward: index.forward,
            backward: index.backward
        )
    }
}

/// On each side a verse is named by pairs that share one kind, or by a single one-sided entry, never both.
private struct MappingIndex {
    let forward: [VerseRef: MappedVerse]
    let backward: [VerseRef: MappedVerse]

    init(_ entries: [MappingEntry]) throws {
        var forward = Side()
        var backward = Side()
        for entry in entries {
            switch entry {
            case .pair(let source, let target, let kind):
                try forward.pair(source, with: target, kind: kind)
                try backward.pair(target, with: source, kind: kind)
            case .sourceOnly(let ref, let kind):
                try forward.unpaired(ref, kind: kind)
            case .targetOnly(let ref, let kind):
                try backward.unpaired(ref, kind: kind)
            }
        }
        self.forward = try forward.resolved()
        self.backward = try backward.resolved()
    }

    private struct Side {
        var pairs: [VerseRef: (kind: MappingKind, refs: Set<VerseRef>)] = [:]
        var absent: [VerseRef: MappingKind] = [:]

        mutating func pair(_ ref: VerseRef, with counterpart: VerseRef, kind: MappingKind) throws {
            let existing = pairs[ref, default: (kind, [])]
            guard existing.kind == kind else {
                throw MappingIndexError(ref: ref, problem: "has pairs of kinds \(existing.kind.rawValue) and \(kind.rawValue)")
            }
            pairs[ref] = (kind, existing.refs.union([counterpart]))
        }

        mutating func unpaired(_ ref: VerseRef, kind: MappingKind) throws {
            guard absent.updateValue(kind, forKey: ref) == nil else {
                throw MappingIndexError(ref: ref, problem: "is named by more than one one-sided entry")
            }
        }

        func resolved() throws -> [VerseRef: MappedVerse] {
            if let ref = Set(pairs.keys).intersection(absent.keys).min() {
                throw MappingIndexError(ref: ref, problem: "is named by a pair and a one-sided entry")
            }
            return absent.mapValues(MappedVerse.absent)
                .merging(pairs.mapValues { .mapped($0.refs.sorted(), $0.kind) }) { absent, _ in absent }
        }
    }
}

private struct MappingIndexError: Error, CustomStringConvertible {
    let ref: VerseRef
    let problem: String

    var description: String { "\(ref) \(problem)" }
}
