# Chapter codec benchmark, 2026-10-30

Phase 0 step 4: the hand-rolled binary codec (encoding id 1) against FlatBuffers and the JSON reference, on every chapter of the three parsed editions. Regenerate with `swift test -c release --filter CodecBenchTests`.

## Method

- Machine: Apple M3 Pro, 12 cores, macOS 27.0.1.
- Toolchain: swift-driver version: 1.168.6 Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1); Xcode 27.2 Build version 27B52.
- Build: `swift test -c release` (optimized, with testable imports). FlatBuffers Swift 25.12.19, schema `Benchmarks/chapter.fbs`.
- Tree: `source-archive-3-gd9bbd32-dirty`. Sources: bsb 2026-10-02 (sha256 f0c56438eb89); tcgnt 2026-10-28 (sha256 90ab404f9cd2); wlc 2026-10-20 (sha256 ee9a3f713368).
- Load before: `5:30  up 2 days, 14:12, 2 users, load averages: 3.15 3.29 3.22`. Load after: `5:31  up 2 days, 14:13, 2 users, load averages: 2.26 3.03 3.12`.
- Clock: `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` around each single decode. The timed region is the codec's decode from an in-memory `Data` to a `Chapter` (or the walk); parsing, encoding, and SQLite reads are outside it. Every result feeds a checksum that the test asserts on, and every chapter of every edition is checked to round-trip in binary and FlatBuffers before timing.
- Limiter: a `sample` profile of the binary decode of WLC Psalm 119, taken outside the reported runs, puts the time in UTF-8 validation, `String` allocation and release, and varint reads. An earlier profile found about 40% of samples in generic metadata lookups under `String(validating:as:)`, so both the binary and FlatBuffers decoders validate through `String(decoding:)` plus a byte comparison instead.
- Not measured: an iPhone. These are M3 Pro numbers; the 5 ms Psalm 119 budget is for an iPhone 16.
- Sides. JSON is `JSONChapterCodec` (Foundation `JSONDecoder`). Binary is `BinaryChapterCodec`, which validates as it reads. FlatBuffers walk reads every field of every item and the first and last byte of each text span through the generated accessors, unverified, and builds nothing. FlatBuffers materialize builds the same `[ChapterItem]` as the others with UTF-8 validation, with and without the FlatBuffers verifier. Every side reads from a pointer the `Data` already holds; no side copies the blob.

## Sizes

Bytes of `chapters.content` summed over every chapter, then the same blobs concatenated per edition and compressed with `COMPRESSION_LZMA`.

| Edition | Chapters | JSON | binary | FlatBuffers | JSON LZMA | binary LZMA | FlatBuffers LZMA |
|---|---:|---:|---:|---:|---:|---:|---:|
| bsb | 1189 | 9067563 | 4321402 | 6193528 | 1137184 | 1074844 | 1208408 |
| wlc | 929 | 32196806 | 7890571 | 15567412 | 1710740 | 1237328 | 1975292 |
| tcgnt | 260 | 14812085 | 2901625 | 6596420 | 714384 | 490268 | 925464 |

| Chapter | JSON | binary | FlatBuffers |
|---|---:|---:|---:|
| bsb PSA 119 | 48063 | 14762 | 28128 |
| bsb JHN 3 | 8054 | 4293 | 5744 |

The binary layout's string bytes and an exact count of the same layout with a per-chapter string table (each distinct run text and glyph stored once, referenced by a varint index):

| Edition | binary | UTF-8 string bytes | strings share | with string table | change |
|---|---:|---:|---:|---:|---:|
| bsb | 4321402 | 3925453 | 90.8% | 4368763 | +1.1% |
| wlc | 7890571 | 5374163 | 68.1% | 7233968 | -8.3% |
| tcgnt | 2901625 | 1710661 | 59.0% | 2377000 | -18.1% |

## Decode one chapter

Microseconds per decode. 5 rounds of 20 warm-up and 200 timed iterations; every iteration decodes once with each side, rotating the order. Median and p95 are over all 1000 samples; the range is the lowest and highest round median.

| Chapter | Items | Side | Median µs | p95 µs | Round medians µs |
|---|---:|---|---:|---:|---:|
| bsb PSA 119 | 951 | JSON | 2342.4 | 2470.1 | 2335.8 to 2374.8 |
| bsb PSA 119 | 951 | binary | 28.6 | 32.5 | 28.5 to 29.0 |
| bsb PSA 119 | 951 | FlatBuffers walk | 11.3 | 12.1 | 11.3 to 11.3 |
| bsb PSA 119 | 951 | FlatBuffers materialize, verified | 35.8 | 40.2 | 35.8 to 36.0 |
| bsb PSA 119 | 951 | FlatBuffers materialize, unverified | 35.4 | 39.8 | 35.3 to 35.5 |
| bsb PSA 119, context | | items to NSMutableAttributedString | 463.0 | 485.0 | 458.4 to 471.5 |
| bsb PSA 117 | 16 | JSON | 41.8 | 46.3 | 41.7 to 41.8 |
| bsb PSA 117 | 16 | binary | 0.6 | 0.6 | 0.6 to 0.6 |
| bsb PSA 117 | 16 | FlatBuffers walk | 0.3 | 0.4 | 0.3 to 0.4 |
| bsb PSA 117 | 16 | FlatBuffers materialize, verified | 1.1 | 1.1 | 1.0 to 1.1 |
| bsb PSA 117 | 16 | FlatBuffers materialize, unverified | 0.7 | 0.8 | 0.7 to 0.7 |
| bsb JHN 3 | 109 | JSON | 246.8 | 265.4 | 246.6 to 246.9 |
| bsb JHN 3 | 109 | binary | 4.4 | 4.8 | 4.4 to 4.4 |
| bsb JHN 3 | 109 | FlatBuffers walk | 1.5 | 1.9 | 1.5 to 1.5 |
| bsb JHN 3 | 109 | FlatBuffers materialize, verified | 5.3 | 6.6 | 5.3 to 5.3 |
| bsb JHN 3 | 109 | FlatBuffers materialize, unverified | 4.9 | 5.9 | 4.9 to 4.9 |
| wlc PSA 119 | 2305 | JSON | 5198.2 | 5373.5 | 5181.7 to 5223.3 |
| wlc PSA 119 | 2305 | binary | 87.3 | 95.2 | 86.9 to 88.7 |
| wlc PSA 119 | 2305 | FlatBuffers walk | 24.8 | 28.4 | 24.8 to 25.1 |
| wlc PSA 119 | 2305 | FlatBuffers materialize, verified | 93.2 | 101.3 | 92.5 to 93.9 |
| wlc PSA 119 | 2305 | FlatBuffers materialize, unverified | 92.8 | 101.0 | 92.0 to 93.3 |
| tcgnt LUK 1 | 2610 | JSON | 5977.6 | 6128.6 | 5957.7 to 5997.5 |
| tcgnt LUK 1 | 2610 | binary | 82.1 | 88.5 | 80.9 to 82.5 |
| tcgnt LUK 1 | 2610 | FlatBuffers walk | 28.3 | 31.8 | 28.2 to 28.3 |
| tcgnt LUK 1 | 2610 | FlatBuffers materialize, verified | 88.4 | 96.2 | 87.5 to 88.7 |
| tcgnt LUK 1 | 2610 | FlatBuffers materialize, unverified | 87.9 | 97.3 | 87.1 to 88.2 |

## Decode every BSB chapter

Milliseconds to decode all 1189 chapters once. 2 warm-up passes, then 11 timed passes, rotating the side order each pass.

| Side | Median ms | Min ms | Max ms |
|---|---:|---:|---:|
| JSON | 329.25 | 327.56 | 335.75 |
| binary | 5.68 | 5.59 | 6.07 |
| FlatBuffers walk | 1.98 | 1.84 | 2.16 |
| FlatBuffers materialize, verified | 6.73 | 6.68 | 7.26 |
| FlatBuffers materialize, unverified | 6.36 | 6.29 | 6.82 |

## Encode every chapter

Milliseconds to encode each edition's chapters, median of 3 passes.

| Edition | JSON ms | binary ms | FlatBuffers ms |
|---|---:|---:|---:|
| bsb | 321.42 | 2.92 | 3.18 |
| wlc | 1426.40 | 16.17 | 11.01 |
| tcgnt | 675.91 | 7.13 | 4.57 |
