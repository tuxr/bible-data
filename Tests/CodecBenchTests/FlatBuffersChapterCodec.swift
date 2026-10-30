import BibleFormat
import FlatBuffers
import Foundation

/// The FlatBuffers side of the benchmark, laid out by `Benchmarks/chapter.fbs`. It has the shape of a
/// `ChapterCodec` but no `ChapterEncoding` id, because no package will carry it.
struct FlatBuffersChapterCodec {
    enum DecodeError: Error {
        case missingVector
        case malformed(item: Int)
        case invalidUTF8(item: Int)
    }

    func encode(_ chapter: Chapter) -> Data {
        var items: [BibleBench_Item] = []
        items.reserveCapacity(chapter.items.count)
        var text: [UInt8] = []

        func span(_ string: String) -> (offset: UInt32, length: UInt32) {
            let start = text.count
            text.append(contentsOf: string.utf8)
            return (UInt32(start), UInt32(text.count - start))
        }
        func run(_ run: Run, _ kind: BibleBench_ItemKind) {
            let (offset, length) = span(run.text)
            items.append(BibleBench_Item(kind: kind, variant: 0, style: run.style.rawValue, a: offset, b: length, c: UInt32(run.word ?? 0)))
        }
        func label(_ kind: BibleBench_ItemKind, level: UInt32, _ runs: [Run]) {
            items.append(BibleBench_Item(kind: kind, variant: 0, style: 0, a: UInt32(runs.count), b: level, c: 0))
            for item in runs { run(item, .labelrun) }
        }

        for item in chapter.items {
            switch item {
            case .block(let kind):
                let (variant, level) = Self.block(kind)
                items.append(BibleBench_Item(kind: .block, variant: variant.rawValue, style: 0, a: level, b: 0, c: 0))
            case .heading(let level, let runs): label(.heading, level: UInt32(level.rawValue), runs)
            case .title(let runs): label(.title, level: 0, runs)
            case .speaker(let runs): label(.speaker, level: 0, runs)
            case .verse(let verse):
                items.append(BibleBench_Item(kind: .verse, variant: 0, style: 0, a: UInt32(verse.number), b: UInt32(verse.through ?? 0), c: 0))
            case .text(let item): run(item, .text)
            case .noteCaller(let caller):
                let (offset, length) = span(caller.glyph)
                items.append(BibleBench_Item(kind: .notecaller, variant: Self.note(caller.kind).rawValue, style: 0, a: UInt32(caller.number), b: offset, c: length))
            }
        }

        var builder = FlatBufferBuilder(initialSize: Int32(text.count + items.count * 16 + 64))
        let textOffset = builder.createVector(bytes: text)
        let itemsOffset = builder.createVector(ofStructs: items)
        let root = BibleBench_Chapter.createChapter(&builder, itemsVectorOffset: itemsOffset, textVectorOffset: textOffset)
        builder.finish(offset: root)
        return builder.data
    }

    /// Full materialization into `[ChapterItem]`. `verify` runs the FlatBuffers verifier first, as a reader of
    /// untrusted bytes must; it checks offsets and bounds, not enum values or UTF-8.
    func decode(_ data: Data, book: Book, number: Int, verify: Bool) throws -> Chapter {
        try data.withUnsafeBytes { raw in
            var buffer = ByteBuffer(assumingMemoryBound: UnsafeMutableRawPointer(mutating: raw.baseAddress!), capacity: raw.count)
            let root: BibleBench_Chapter = verify ? try getCheckedRoot(byteBuffer: &buffer) : getRoot(byteBuffer: &buffer)
            let items = root.items
            let decoded = try root.withUnsafePointerToText { text, _ in
                try Self.materialize(items, text: text.assumingMemoryBound(to: UInt8.self))
            }
            guard let decoded else { throw DecodeError.missingVector }
            return Chapter(book: book, number: number, items: decoded)
        }
    }

    /// Zero-copy access: reads every field of every item and the first and last byte of every text span, and
    /// builds nothing. The floor for a reader that would draw straight from the buffer.
    func walk(_ data: Data) -> Int {
        data.withUnsafeBytes { raw in
            var buffer = ByteBuffer(assumingMemoryBound: UnsafeMutableRawPointer(mutating: raw.baseAddress!), capacity: raw.count)
            let root: BibleBench_Chapter = getRoot(byteBuffer: &buffer)
            let items = root.items
            return root.withUnsafePointerToText { text, _ in
                var sum = 0
                for item in items {
                    sum &+= Int(item.kind.rawValue) &+ Int(item.variant) &+ Int(item.style) &+ Int(item.a) &+ Int(item.b) &+ Int(item.c)
                    if item.kind == .text || item.kind == .labelrun, item.b > 0 {
                        sum &+= Int(text[Int(item.a)]) &+ Int(text[Int(item.a + item.b - 1)])
                    }
                }
                return sum
            } ?? 0
        }
    }

    private static func materialize(_ items: FlatbufferVector<BibleBench_Item>, text: UnsafeBufferPointer<UInt8>) throws -> [ChapterItem] {
        func string(_ offset: UInt32, _ length: UInt32, item: Int) throws -> String {
            let start = Int(offset)
            let end = start + Int(length)
            guard end <= text.count else { throw DecodeError.malformed(item: item) }
            guard let string = String(validatingUTF8Bytes: UnsafeBufferPointer(rebasing: text[start..<end])) else {
                throw DecodeError.invalidUTF8(item: item)
            }
            return string
        }
        func run(_ item: BibleBench_Item, at index: Int) throws -> Run {
            Run(try string(item.a, item.b, item: index), style: RunStyle(rawValue: item.style), word: item.c == 0 ? nil : Int(item.c))
        }
        func level(_ value: UInt32, at index: Int) throws -> Level {
            guard let level = Level(rawValue: Int(value)) else { throw DecodeError.malformed(item: index) }
            return level
        }

        var out: [ChapterItem] = []
        out.reserveCapacity(items.count)
        var index = 0
        while index < items.count {
            let item = items[index]
            let at = index
            index += 1
            switch item.kind {
            case .block:
                guard let kind = BibleBench_BlockKind(rawValue: item.variant) else { throw DecodeError.malformed(item: at) }
                switch kind {
                case .paragraph: out.append(.block(.paragraph))
                case .flush: out.append(.block(.flush))
                case .indented: out.append(.block(.indented))
                case .poetry: out.append(.block(.poetry(level: try level(item.a, at: at))))
                case .rightaligned: out.append(.block(.rightAligned))
                case .centered: out.append(.block(.centered))
                case .list: out.append(.block(.list(level: try level(item.a, at: at))))
                case .blankline: out.append(.block(.blankLine))
                }
            case .heading, .title, .speaker:
                let count = Int(item.a)
                guard count <= items.count - index else { throw DecodeError.malformed(item: at) }
                var runs: [Run] = []
                runs.reserveCapacity(count)
                for _ in 0..<count {
                    let piece = items[index]
                    guard piece.kind == .labelrun else { throw DecodeError.malformed(item: index) }
                    runs.append(try run(piece, at: index))
                    index += 1
                }
                switch item.kind {
                case .heading: out.append(.heading(level: try level(item.b, at: at), runs))
                case .title: out.append(.title(runs))
                default: out.append(.speaker(runs))
                }
            case .verse:
                if item.b == 0 {
                    out.append(.verse(VerseLabel(Int(item.a))))
                } else {
                    guard item.b > item.a else { throw DecodeError.malformed(item: at) }
                    out.append(.verse(VerseLabel(Int(item.a), through: Int(item.b))))
                }
            case .text:
                out.append(.text(try run(item, at: at)))
            case .notecaller:
                guard let kind = BibleBench_NoteKind(rawValue: item.variant) else { throw DecodeError.malformed(item: at) }
                let noteKind: NoteKind = switch kind {
                case .footnote: .footnote
                case .crossreference: .crossReference
                case .translatornote: .translatorNote
                }
                out.append(.noteCaller(NoteCaller(number: Int(item.a), kind: noteKind, glyph: try string(item.b, item.c, item: at))))
            case .labelrun:
                throw DecodeError.malformed(item: at)
            }
        }
        return out
    }

    private static func block(_ kind: BlockKind) -> (BibleBench_BlockKind, UInt32) {
        switch kind {
        case .paragraph: (.paragraph, 0)
        case .flush: (.flush, 0)
        case .indented: (.indented, 0)
        case .poetry(let level): (.poetry, UInt32(level.rawValue))
        case .rightAligned: (.rightaligned, 0)
        case .centered: (.centered, 0)
        case .list(let level): (.list, UInt32(level.rawValue))
        case .blankLine: (.blankline, 0)
        }
    }

    private static func note(_ kind: NoteKind) -> BibleBench_NoteKind {
        switch kind {
        case .footnote: .footnote
        case .crossReference: .crossreference
        case .translatorNote: .translatornote
        }
    }
}

extension String {
    /// The same validation as `BinaryChapterCodec`, so both sides pay the same for UTF-8.
    init?(validatingUTF8Bytes bytes: UnsafeBufferPointer<UInt8>) {
        var text = String(decoding: bytes, as: UTF8.self)
        let unchanged = text.withUTF8 { $0.count == bytes.count && (bytes.isEmpty || memcmp($0.baseAddress!, bytes.baseAddress!, bytes.count) == 0) }
        guard unchanged else { return nil }
        self = text
    }
}
