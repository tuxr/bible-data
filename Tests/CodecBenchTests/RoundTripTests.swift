import BibleFormat
import Foundation
import Testing

/// Serialized so the benchmark never shares the CPU with the round-trip sweep.
@Suite(.serialized, .enabled(if: BenchSources.present, BenchSources.skipMessage))
enum CodecBenchTests {}

/// Every chapter of the three real editions, through the binary and FlatBuffers codecs.
extension CodecBenchTests {
    @Suite struct RoundTrip {
        @Test(arguments: BenchSources.ids)
        func everyChapterRoundTripsInBinaryAndEncodesDeterministically(_ id: String) throws {
            let codec = BinaryChapterCodec()
            var failures: [String] = []
            for chapter in BenchSources.chapters[id]! {
                let bytes = try codec.encode(chapter)
                if try codec.decode(bytes, book: chapter.book, number: chapter.number) != chapter { failures.append("\(chapter.book.rawValue) \(chapter.number) round trip") }
                if try codec.encode(chapter) != bytes { failures.append("\(chapter.book.rawValue) \(chapter.number) determinism") }
            }
            #expect(failures == [])
        }

        @Test(arguments: BenchSources.ids)
        func everyChapterRoundTripsInFlatBuffers(_ id: String) throws {
            let codec = FlatBuffersChapterCodec()
            var failures: [String] = []
            for chapter in BenchSources.chapters[id]! {
                let bytes = codec.encode(chapter)
                if try codec.decode(bytes, book: chapter.book, number: chapter.number, verify: true) != chapter { failures.append("\(chapter.book.rawValue) \(chapter.number)") }
            }
            #expect(failures == [])
        }

        @Test func everyBSBChapterIsSmallerInBinaryThanInJSON() throws {
            var larger: [String] = []
            for chapter in BenchSources.chapters["bsb"]! {
                if try BinaryChapterCodec().encode(chapter).count >= JSONChapterCodec().encode(chapter).count {
                    larger.append("\(chapter.book.rawValue) \(chapter.number)")
                }
            }
            #expect(BenchSources.chapters["bsb"]!.count == 1189)
            #expect(larger == [])
        }
    }
}
