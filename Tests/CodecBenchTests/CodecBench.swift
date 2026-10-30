import BibleFormat
import Compression
import Foundation
import Testing

#if DEBUG
private let releaseBuild = false
#else
private let releaseBuild = true
#endif

private func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

private enum Side: CaseIterable {
    case json
    case binary
    case flatBuffersWalk
    case flatBuffersVerified
    case flatBuffersUnverified

    var name: String {
        switch self {
        case .json: "JSON"
        case .binary: "binary"
        case .flatBuffersWalk: "FlatBuffers walk"
        case .flatBuffersVerified: "FlatBuffers materialize, verified"
        case .flatBuffersUnverified: "FlatBuffers materialize, unverified"
        }
    }
}

private struct Encoded {
    let chapter: Chapter
    let json: Data
    let binary: Data
    let flatBuffers: Data

    init(_ chapter: Chapter) throws {
        self.chapter = chapter
        json = try JSONChapterCodec().encode(chapter)
        binary = try BinaryChapterCodec().encode(chapter)
        flatBuffers = FlatBuffersChapterCodec().encode(chapter)
    }

    /// The decoded item count, or the walk's checksum, so the caller uses every result.
    func decode(_ side: Side) throws -> Int {
        let book = chapter.book
        let number = chapter.number
        return switch side {
        case .json: try JSONChapterCodec().decode(json, book: book, number: number).items.count
        case .binary: try BinaryChapterCodec().decode(binary, book: book, number: number).items.count
        case .flatBuffersWalk: FlatBuffersChapterCodec().walk(flatBuffers)
        case .flatBuffersVerified: try FlatBuffersChapterCodec().decode(flatBuffers, book: book, number: number, verify: true).items.count
        case .flatBuffersUnverified: try FlatBuffersChapterCodec().decode(flatBuffers, book: book, number: number, verify: false).items.count
        }
    }
}

private struct Timing {
    var samples: [UInt64] = []
    var roundMedians: [UInt64] = []

    static func percentile(_ values: [UInt64], _ fraction: Double) -> UInt64 {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
    }

    var median: UInt64 { Self.percentile(samples, 0.5) }
    var p95: UInt64 { Self.percentile(samples, 0.95) }
    var range: (UInt64, UInt64) { (roundMedians.min()!, roundMedians.max()!) }
}

private func micros(_ nanoseconds: UInt64) -> String { String(format: "%.1f", Double(nanoseconds) / 1000) }
private func millis(_ nanoseconds: UInt64) -> String { String(format: "%.2f", Double(nanoseconds) / 1_000_000) }
private func kilobytes(_ bytes: Int) -> String { String(format: "%.1f", Double(bytes) / 1024) }
private func megabytes(_ bytes: Int) -> String { String(format: "%.2f", Double(bytes) / 1_048_576) }

private func lzma(_ data: Data) -> Int {
    let capacity = data.count + 1_048_576
    let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
    defer { destination.deallocate() }
    let size = data.withUnsafeBytes { source in
        compression_encode_buffer(destination, capacity, source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_LZMA)
    }
    precondition(size > 0, "LZMA failed")
    return size
}

private func shell(_ command: String) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.currentDirectoryURL = BenchSources.repository
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try? process.run()
    process.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Every string a chapter stores: run texts and note glyphs.
private func strings(_ chapter: Chapter) -> [String] {
    chapter.items.flatMap { item -> [String] in
        switch item {
        case .heading(_, let runs), .title(let runs), .speaker(let runs): runs.map(\.text)
        case .text(let run): [run.text]
        case .noteCaller(let caller): [caller.glyph]
        case .block, .verse: []
        }
    }
}

private func varintSize(_ value: Int) -> Int {
    var value = value
    var size = 1
    while value >= 0x80 {
        value >>= 7
        size += 1
    }
    return size
}

/// The exact size of the binary layout with a per-chapter string table: the table (a count, then each distinct
/// string once) and a varint index in place of every inline string.
private func stringTableSize(_ chapter: Chapter, binary: Int) -> Int {
    let all = strings(chapter)
    var index: [String: Int] = [:]
    var size = binary
    for string in all {
        size -= varintSize(string.utf8.count) + string.utf8.count
        let next = index.count
        let position = index[string] ?? next
        if position == next {
            index[string] = next
            size += varintSize(string.utf8.count) + string.utf8.count
        }
        size += varintSize(position)
    }
    return size + varintSize(index.count)
}

/// A rough stand-in for the reader's page build: one attributed run per text run, with a style attribute.
private func attributedString(_ chapter: Chapter) -> Int {
    let result = NSMutableAttributedString()
    let key = NSAttributedString.Key("bible.style")
    for item in chapter.items {
        switch item {
        case .heading(_, let runs), .title(let runs), .speaker(let runs):
            for run in runs { result.append(NSAttributedString(string: run.text, attributes: [key: run.style.rawValue])) }
            result.append(NSAttributedString(string: "\n"))
        case .text(let run):
            result.append(NSAttributedString(string: run.text, attributes: [key: run.style.rawValue]))
        case .block:
            result.append(NSAttributedString(string: "\n"))
        case .verse(let label):
            result.append(NSAttributedString(string: "\(label.number) "))
        case .noteCaller(let caller):
            result.append(NSAttributedString(string: caller.glyph))
        }
    }
    return result.length
}

extension CodecBenchTests {
    @Suite(.enabled(if: releaseBuild, "a debug build; run `swift test -c release --filter CodecBenchTests`"))
    struct Bench {
        static let rounds = 5
        static let warmup = 20
        static let iterations = 200

        @Test func chapterCodecs() throws {
            var out: [String] = []
            var checksum = 0
            let loadBefore = shell("uptime")

            let editions = try BenchSources.ids.map { id in (id, try BenchSources.chapters[id]!.map(Encoded.init)) }
            let sides = Side.allCases

            for (_, encoded) in editions {
                for chapter in encoded {
                    #expect(try BinaryChapterCodec().decode(chapter.binary, book: chapter.chapter.book, number: chapter.chapter.number) == chapter.chapter)
                    #expect(try FlatBuffersChapterCodec().decode(chapter.flatBuffers, book: chapter.chapter.book, number: chapter.chapter.number, verify: true) == chapter.chapter)
                }
            }

            out.append("## Sizes\n")
            out.append("Bytes of `chapters.content` summed over every chapter, then the same blobs concatenated per edition and compressed with `COMPRESSION_LZMA`.\n")
            out.append("| Edition | Chapters | JSON | binary | FlatBuffers | JSON LZMA | binary LZMA | FlatBuffers LZMA |")
            out.append("|---|---:|---:|---:|---:|---:|---:|---:|")
            var tableRows: [String] = []
            for (id, encoded) in editions {
                let json = encoded.reduce(Data()) { $0 + $1.json }
                let binary = encoded.reduce(Data()) { $0 + $1.binary }
                let flat = encoded.reduce(Data()) { $0 + $1.flatBuffers }
                out.append("| \(id) | \(encoded.count) | \(json.count) | \(binary.count) | \(flat.count) | \(lzma(json)) | \(lzma(binary)) | \(lzma(flat)) |")
                let text = encoded.reduce(0) { $0 + strings($1.chapter).reduce(0) { $0 + $1.utf8.count } }
                let table = encoded.reduce(0) { $0 + stringTableSize($1.chapter, binary: $1.binary.count) }
                tableRows.append("| \(id) | \(binary.count) | \(text) | \(String(format: "%.1f%%", 100 * Double(text) / Double(binary.count))) | \(table) | \(String(format: "%+.1f%%", 100 * (Double(table) / Double(binary.count) - 1))) |")
            }
            out.append("")
            out.append("| Chapter | JSON | binary | FlatBuffers |")
            out.append("|---|---:|---:|---:|")
            for (book, number) in [(Book.psalms, 119), (.john, 3)] {
                let chapter = try Encoded(BenchSources.chapter("bsb", book, number))
                out.append("| bsb \(book.rawValue) \(number) | \(chapter.json.count) | \(chapter.binary.count) | \(chapter.flatBuffers.count) |")
            }
            out.append("\nThe binary layout's string bytes and an exact count of the same layout with a per-chapter string table (each distinct run text and glyph stored once, referenced by a varint index):\n")
            out.append("| Edition | binary | UTF-8 string bytes | strings share | with string table | change |")
            out.append("|---|---:|---:|---:|---:|---:|")
            out += tableRows

            out.append("\n## Decode one chapter\n")
            out.append("Microseconds per decode. \(Self.rounds) rounds of \(Self.warmup) warm-up and \(Self.iterations) timed iterations; every iteration decodes once with each side, rotating the order. Median and p95 are over all \(Self.rounds * Self.iterations) samples; the range is the lowest and highest round median.\n")
            out.append("| Chapter | Items | Side | Median µs | p95 µs | Round medians µs |")
            out.append("|---|---:|---|---:|---:|---:|")
            let cases: [(String, Book, Int)] = [("bsb", .psalms, 119), ("bsb", .psalms, 117), ("bsb", .john, 3), ("wlc", .psalms, 119), ("tcgnt", .luke, 1)]
            for (id, book, number) in cases {
                let encoded = try Encoded(BenchSources.chapter(id, book, number))
                var timings = Dictionary(uniqueKeysWithValues: sides.map { ($0, Timing()) })
                for _ in 0..<Self.rounds {
                    for _ in 0..<Self.warmup {
                        for side in sides { checksum &+= try encoded.decode(side) }
                    }
                    var round = Dictionary(uniqueKeysWithValues: sides.map { ($0, [UInt64]()) })
                    for iteration in 0..<Self.iterations {
                        for offset in sides.indices {
                            let side = sides[(iteration + offset) % sides.count]
                            let start = now()
                            checksum &+= try encoded.decode(side)
                            round[side]!.append(now() - start)
                        }
                    }
                    for side in sides {
                        timings[side]!.samples += round[side]!
                        timings[side]!.roundMedians.append(Timing.percentile(round[side]!, 0.5))
                    }
                }
                for side in sides {
                    let timing = timings[side]!
                    out.append("| \(id) \(book.rawValue) \(number) | \(encoded.chapter.items.count) | \(side.name) | \(micros(timing.median)) | \(micros(timing.p95)) | \(micros(timing.range.0)) to \(micros(timing.range.1)) |")
                }
                if id == "bsb", book == .psalms, number == 119 {
                    var build = Timing()
                    for _ in 0..<Self.warmup { checksum &+= attributedString(encoded.chapter) }
                    for _ in 0..<Self.rounds {
                        var round: [UInt64] = []
                        for _ in 0..<Self.iterations {
                            let start = now()
                            checksum &+= attributedString(encoded.chapter)
                            round.append(now() - start)
                        }
                        build.samples += round
                        build.roundMedians.append(Timing.percentile(round, 0.5))
                    }
                    out.append("| bsb PSA 119, context | | items to NSMutableAttributedString | \(micros(build.median)) | \(micros(build.p95)) | \(micros(build.range.0)) to \(micros(build.range.1)) |")
                }
            }

            out.append("\n## Decode every BSB chapter\n")
            let bsb = editions[0].1
            out.append("Milliseconds to decode all \(bsb.count) chapters once. 2 warm-up passes, then 11 timed passes, rotating the side order each pass.\n")
            out.append("| Side | Median ms | Min ms | Max ms |")
            out.append("|---|---:|---:|---:|")
            var passes = Dictionary(uniqueKeysWithValues: sides.map { ($0, [UInt64]()) })
            for pass in 0..<13 {
                for offset in sides.indices {
                    let side = sides[(pass + offset) % sides.count]
                    let start = now()
                    for chapter in bsb { checksum &+= try chapter.decode(side) }
                    if pass >= 2 { passes[side]!.append(now() - start) }
                }
            }
            for side in sides {
                let values = passes[side]!
                out.append("| \(side.name) | \(millis(Timing.percentile(values, 0.5))) | \(millis(values.min()!)) | \(millis(values.max()!)) |")
            }

            out.append("\n## Encode every chapter\n")
            out.append("Milliseconds to encode each edition's chapters, median of 3 passes.\n")
            out.append("| Edition | JSON ms | binary ms | FlatBuffers ms |")
            out.append("|---|---:|---:|---:|")
            for id in BenchSources.ids {
                let chapters = BenchSources.chapters[id]!
                func time(_ body: (Chapter) throws -> Int) rethrows -> String {
                    var values: [UInt64] = []
                    for _ in 0..<3 {
                        let start = now()
                        for chapter in chapters { checksum &+= try body(chapter) }
                        values.append(now() - start)
                    }
                    return millis(Timing.percentile(values, 0.5))
                }
                let json = try time { try JSONChapterCodec().encode($0).count }
                let binary = try time { try BinaryChapterCodec().encode($0).count }
                let flat = time { FlatBuffersChapterCodec().encode($0).count }
                out.append("| \(id) | \(json) | \(binary) | \(flat) |")
            }

            #expect(checksum != 0)
            let loadAfter = shell("uptime")
            let lock = BenchSources.lock!.sources.keys.sorted().map { "\($0) \(BenchSources.lock!.sources[$0]!.revision) (sha256 \(BenchSources.lock!.sources[$0]!.sha256.prefix(12)))" }
            let header = [
                "# Chapter codec benchmark, 2026-10-30",
                "",
                "Phase 0 step 4: the hand-rolled binary codec (encoding id 1) against FlatBuffers and the JSON reference, on every chapter of the three parsed editions. Regenerate with `swift test -c release --filter CodecBenchTests`.",
                "",
                "## Method",
                "",
                "- Machine: \(shell("sysctl -n machdep.cpu.brand_string")), \(shell("sysctl -n hw.ncpu")) cores, macOS \(shell("sw_vers -productVersion")).",
                "- Toolchain: \(shell("xcrun swift --version 2>&1 | head -1")); \(shell("xcodebuild -version | tr '\\n' ' '")).",
                "- Build: `swift test -c release` (optimized, with testable imports). FlatBuffers Swift 25.12.19, schema `Benchmarks/chapter.fbs`.",
                "- Tree: `\(shell("git describe --always --dirty --tags"))`. Sources: \(lock.joined(separator: "; ")).",
                "- Load before: `\(loadBefore)`. Load after: `\(loadAfter)`.",
                "- Clock: `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` around each single decode. The timed region is the codec's decode from an in-memory `Data` to a `Chapter` (or the walk); parsing, encoding, and SQLite reads are outside it. Every result feeds a checksum that the test asserts on, and every chapter of every edition is checked to round-trip in binary and FlatBuffers before timing.",
                "- Limiter: a `sample` profile of the binary decode of WLC Psalm 119, taken outside the reported runs, puts the time in UTF-8 validation, `String` allocation and release, and varint reads. An earlier profile found about 40% of samples in generic metadata lookups under `String(validating:as:)`, so both the binary and FlatBuffers decoders validate through `String(decoding:)` plus a byte comparison instead.",
                "- Not measured: an iPhone. These are M3 Pro numbers; the 5 ms Psalm 119 budget is for an iPhone 16.",
                "- Sides. JSON is `JSONChapterCodec` (Foundation `JSONDecoder`). Binary is `BinaryChapterCodec`, which validates as it reads. FlatBuffers walk reads every field of every item and the first and last byte of each text span through the generated accessors, unverified, and builds nothing. FlatBuffers materialize builds the same `[ChapterItem]` as the others with UTF-8 validation, with and without the FlatBuffers verifier. Every side reads from a pointer the `Data` already holds; no side copies the blob.",
                "",
            ]
            let report = (header + out).joined(separator: "\n") + "\n"
            print(report)
            let url = BenchSources.repository.appending(path: "docs/benchmarks/chapter-codec-2026-10-30.md")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try report.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
