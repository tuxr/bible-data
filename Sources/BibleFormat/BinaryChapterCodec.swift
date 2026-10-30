import Foundation

/// Encoding id 1. FORMAT.md's Chapter encoding section owns the byte layout.
public struct BinaryChapterCodec: ChapterCodec {
    public static let encoding = ChapterEncoding.binary

    public init() {}

    public func encode(_ chapter: Chapter) throws -> Data {
        var writer = BinaryWriter()
        writer.bytes.reserveCapacity(chapter.items.count * 16)
        try writer.int(chapter.items.count)
        for item in chapter.items { try writer.item(item) }
        return Data(writer.bytes)
    }

    public func decode(_ data: Data, book: Book, number: Int) throws -> Chapter {
        let items = try data.withUnsafeBytes { raw in
            var reader = BinaryReader(raw.assumingMemoryBound(to: UInt8.self))
            return try reader.chapterItems()
        }
        return Chapter(book: book, number: number, items: items)
    }
}

public enum BinaryChapterCodecError: Error, Equatable, Sendable {
    /// The buffer ends inside an item, or holds fewer items than its count.
    case truncated(offset: Int)
    case unknownTag(UInt8, offset: Int)
    case invalidLevel(UInt8, offset: Int)
    case invalidUTF8(offset: Int)
    /// A varint longer than 10 bytes, or a value too large for its field.
    case overflow(offset: Int)
    /// A bridge whose `through` does not come after its `number`.
    case invalidVerseBridge(offset: Int)
    case trailingBytes(offset: Int)
    /// A negative number, or a `Run.word` or `VerseLabel.through` of 0, which the layout reserves for nil.
    case unencodable(String)
}

/// The tag byte: the high nibble is the item kind, the low nibble its variant.
private enum Tag {
    static let block: UInt8 = 0x10
    static let heading: UInt8 = 0x20
    static let title: UInt8 = 0x30
    static let speaker: UInt8 = 0x40
    static let verse: UInt8 = 0x50
    static let text: UInt8 = 0x60
    static let noteCaller: UInt8 = 0x70

    // Block variants. 0 to 5 are the kinds without a level. Poetry and list keep the level in the low two bits,
    // so 0x18 and 0x1C are level 0 and invalid.
    static let poetry: UInt8 = 0x08
    static let list: UInt8 = 0x0C

    static func block(_ kind: BlockKind) -> UInt8 {
        switch kind {
        case .paragraph: block | 0
        case .flush: block | 1
        case .indented: block | 2
        case .rightAligned: block | 3
        case .centered: block | 4
        case .blankLine: block | 5
        case .poetry(let level): block | poetry | UInt8(level.rawValue)
        case .list(let level): block | list | UInt8(level.rawValue)
        }
    }

    static func note(_ kind: NoteKind) -> UInt8 {
        switch kind {
        case .footnote: noteCaller | 0
        case .crossReference: noteCaller | 1
        case .translatorNote: noteCaller | 2
        }
    }
}

private struct BinaryWriter {
    var bytes: [UInt8] = []

    mutating func varint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: value) | 0x80)
            value >>= 7
        }
        bytes.append(UInt8(value))
    }

    mutating func int(_ value: Int) throws {
        guard value >= 0 else { throw BinaryChapterCodecError.unencodable("negative number \(value)") }
        varint(UInt64(value))
    }

    /// 0 is nil, so a present value must be positive.
    mutating func optionalPositive(_ value: Int?, _ field: String) throws {
        guard let value else { return varint(0) }
        guard value > 0 else { throw BinaryChapterCodecError.unencodable("\(field) \(value)") }
        varint(UInt64(value))
    }

    mutating func string(_ text: String) {
        let utf8 = text.utf8
        varint(UInt64(utf8.count))
        bytes.append(contentsOf: utf8)
    }

    mutating func run(_ run: Run) throws {
        string(run.text)
        varint(UInt64(run.style.rawValue))
        try optionalPositive(run.word, "word")
    }

    mutating func runs(_ runs: [Run]) throws {
        try int(runs.count)
        for item in runs { try run(item) }
    }

    mutating func item(_ item: ChapterItem) throws {
        switch item {
        case .block(let kind):
            bytes.append(Tag.block(kind))
        case .heading(let level, let items):
            bytes.append(Tag.heading | UInt8(level.rawValue))
            try runs(items)
        case .title(let items):
            bytes.append(Tag.title)
            try runs(items)
        case .speaker(let items):
            bytes.append(Tag.speaker)
            try runs(items)
        case .verse(let label):
            bytes.append(Tag.verse)
            try int(label.number)
            try optionalPositive(label.through, "through")
        case .text(let item):
            bytes.append(Tag.text)
            try run(item)
        case .noteCaller(let caller):
            bytes.append(Tag.note(caller.kind))
            try int(caller.number)
            string(caller.glyph)
        }
    }
}

private struct BinaryReader {
    let buffer: UnsafeBufferPointer<UInt8>
    var offset = 0

    init(_ buffer: UnsafeBufferPointer<UInt8>) {
        self.buffer = buffer
    }

    mutating func byte() throws -> UInt8 {
        guard offset < buffer.count else { throw BinaryChapterCodecError.truncated(offset: offset) }
        defer { offset += 1 }
        return buffer[offset]
    }

    mutating func varint() throws -> UInt64 {
        let start = offset
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try byte()
            // The tenth byte holds bit 63 only.
            if shift == 63, byte > 1 { throw BinaryChapterCodecError.overflow(offset: start) }
            value |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 { return value }
            shift += 7
            if shift > 63 { throw BinaryChapterCodecError.overflow(offset: start) }
        }
    }

    mutating func int() throws -> Int {
        let start = offset
        let value = try varint()
        guard value <= UInt64(Int.max) else { throw BinaryChapterCodecError.overflow(offset: start) }
        return Int(value)
    }

    /// A count of things that each take at least one byte, so a corrupt count cannot ask for a huge allocation.
    mutating func count() throws -> Int {
        let start = offset
        let value = try int()
        guard value <= buffer.count - offset else { throw BinaryChapterCodecError.truncated(offset: start) }
        return value
    }

    mutating func string() throws -> String {
        let length = try count()
        let start = offset
        guard let text = String(validatingUTF8Bytes: UnsafeBufferPointer(rebasing: buffer[start..<start + length])) else {
            throw BinaryChapterCodecError.invalidUTF8(offset: start)
        }
        offset += length
        return text
    }

    mutating func run() throws -> Run {
        let text = try string()
        let styleOffset = offset
        let style = try varint()
        guard style <= UInt64(UInt16.max) else { throw BinaryChapterCodecError.overflow(offset: styleOffset) }
        let word = try int()
        return Run(text, style: RunStyle(rawValue: UInt16(style)), word: word == 0 ? nil : word)
    }

    mutating func runs() throws -> [Run] {
        let count = try count()
        var runs: [Run] = []
        runs.reserveCapacity(count)
        for _ in 0..<count { runs.append(try run()) }
        return runs
    }

    func level(_ value: UInt8, tag: UInt8, at offset: Int) throws -> Level {
        guard let level = Level(rawValue: Int(value)) else { throw BinaryChapterCodecError.invalidLevel(tag, offset: offset) }
        return level
    }

    mutating func item() throws -> ChapterItem {
        let start = offset
        let tag = try byte()
        let variant = tag & 0x0F
        switch tag & 0xF0 {
        case Tag.block:
            switch variant {
            case 0: return .block(.paragraph)
            case 1: return .block(.flush)
            case 2: return .block(.indented)
            case 3: return .block(.rightAligned)
            case 4: return .block(.centered)
            case 5: return .block(.blankLine)
            case Tag.poetry...(Tag.poetry | 3): return .block(.poetry(level: try level(variant & 3, tag: tag, at: start)))
            case Tag.list...(Tag.list | 3): return .block(.list(level: try level(variant & 3, tag: tag, at: start)))
            default: throw BinaryChapterCodecError.unknownTag(tag, offset: start)
            }
        case Tag.heading:
            let level = try level(variant, tag: tag, at: start)
            return .heading(level: level, try runs())
        case Tag.title where variant == 0:
            return .title(try runs())
        case Tag.speaker where variant == 0:
            return .speaker(try runs())
        case Tag.verse where variant == 0:
            let number = try int()
            let throughOffset = offset
            let through = try int()
            if through == 0 { return .verse(VerseLabel(number)) }
            guard through > number else { throw BinaryChapterCodecError.invalidVerseBridge(offset: throughOffset) }
            return .verse(VerseLabel(number, through: through))
        case Tag.text where variant == 0:
            return .text(try run())
        case Tag.noteCaller:
            let kind: NoteKind
            switch variant {
            case 0: kind = .footnote
            case 1: kind = .crossReference
            case 2: kind = .translatorNote
            default: throw BinaryChapterCodecError.unknownTag(tag, offset: start)
            }
            let number = try int()
            return .noteCaller(NoteCaller(number: number, kind: kind, glyph: try string()))
        default:
            throw BinaryChapterCodecError.unknownTag(tag, offset: start)
        }
    }

    mutating func chapterItems() throws -> [ChapterItem] {
        let count = try count()
        var items: [ChapterItem] = []
        items.reserveCapacity(count)
        for _ in 0..<count { items.append(try item()) }
        guard offset == buffer.count else { throw BinaryChapterCodecError.trailingBytes(offset: offset) }
        return items
    }
}

extension String {
    /// `String(validating:as:)` runs unspecialized in the standard library and spent about 40% of a chapter decode
    /// looking up generic metadata. Decoding repairs invalid UTF-8, so the bytes come back unchanged only when they
    /// were valid.
    init?(validatingUTF8Bytes bytes: UnsafeBufferPointer<UInt8>) {
        var text = String(decoding: bytes, as: UTF8.self)
        let unchanged = text.withUTF8 { $0.count == bytes.count && (bytes.isEmpty || memcmp($0.baseAddress!, bytes.baseAddress!, bytes.count) == 0) }
        guard unchanged else { return nil }
        self = text
    }
}
