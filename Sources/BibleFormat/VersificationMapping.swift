import Foundation

public enum MappingKind: String, Codable, CaseIterable, Sendable {
    case superscriptionAsVerse1
    case chapterBoundarySplit
    case relocated
    case splitVerse
    /// A verse one scheme numbers and the other does not. Files spell it `sourceOnly` or `targetOnly`.
    case extraVerse
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
            let source = try ref(raw.source, in: raw.book, counts: sourceCounts)
            let target = try ref(raw.target, in: raw.book, counts: targetCounts)
            switch (raw.kind, source, target) {
            case ("sourceOnly", let source?, nil):
                entries.append(.sourceOnly(source, kind: .extraVerse))
            case ("targetOnly", nil, let target?):
                entries.append(.targetOnly(target, kind: .extraVerse))
            case (let name, let source, let target):
                guard let kind = MappingKind(rawValue: name), kind != .extraVerse else {
                    throw fail("\(raw.book.rawValue) has unknown or misplaced kind \(name)")
                }
                switch (source, target) {
                case let (source?, target?): entries.append(.pair(source: source, target: target, kind: kind))
                case let (source?, nil): entries.append(.sourceOnly(source, kind: kind))
                case let (nil, target?): entries.append(.targetOnly(target, kind: kind))
                case (nil, nil): throw fail("\(raw.book.rawValue) \(name) entry names neither side")
                }
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

/// Applies the resolution rule: a pair beats a one-sided entry for the same verse.
private struct MappingIndex {
    var forward: [VerseRef: MappedVerse] = [:]
    var backward: [VerseRef: MappedVerse] = [:]

    init(_ entries: [MappingEntry]) throws {
        var pairs = (forward: [VerseRef: Side](), backward: [VerseRef: Side]())
        var unpaired = (forward: [VerseRef: MappingKind](), backward: [VerseRef: MappingKind]())
        for entry in entries {
            switch entry {
            case .pair(let source, let target, let kind):
                try pairs.forward[source, default: Side(kind: kind)].add(target, kind: kind, at: source)
                try pairs.backward[target, default: Side(kind: kind)].add(source, kind: kind, at: target)
            case .sourceOnly(let ref, let kind):
                try Self.record(ref, kind, in: &unpaired.forward)
            case .targetOnly(let ref, let kind):
                try Self.record(ref, kind, in: &unpaired.backward)
            }
        }
        forward = unpaired.forward.mapValues(MappedVerse.absent)
            .merging(pairs.forward.mapValues(\.mapped)) { _, pair in pair }
        backward = unpaired.backward.mapValues(MappedVerse.absent)
            .merging(pairs.backward.mapValues(\.mapped)) { _, pair in pair }
    }

    private static func record(_ ref: VerseRef, _ kind: MappingKind, in table: inout [VerseRef: MappingKind]) throws {
        if let existing = table[ref], existing != kind {
            throw MappingIndexError(ref: ref, kinds: [existing, kind])
        }
        table[ref] = kind
    }

    private struct Side {
        let kind: MappingKind
        var refs: Set<VerseRef> = []

        mutating func add(_ ref: VerseRef, kind: MappingKind, at key: VerseRef) throws {
            guard kind == self.kind else { throw MappingIndexError(ref: key, kinds: [self.kind, kind]) }
            refs.insert(ref)
        }

        var mapped: MappedVerse { .mapped(refs.sorted(), kind) }
    }
}

private struct MappingIndexError: Error, CustomStringConvertible {
    let ref: VerseRef
    let kinds: [MappingKind]

    var description: String {
        "\(ref) has entries of different kinds: \(kinds.map(\.rawValue).joined(separator: ", "))"
    }
}
