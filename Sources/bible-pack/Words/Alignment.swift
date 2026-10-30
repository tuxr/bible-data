/// A word's comparison key as scalars, so the aligner's inner loop compares integers.
struct WordKey: Hashable {
    let text: String
    let scalars: [UInt32]

    init(_ text: String) {
        self.text = text
        scalars = text.unicodeScalars.map(\.value)
    }
}

/// Global alignment of two word sequences, ported from bible-api's `alignSequences`: the pairing in order that
/// maximizes the total score, where a score of 0 means the two words are never paired.
enum Alignment {
    struct Pair: Hashable {
        let index: Int
        let score: Int
    }

    /// How far from the diagonal the alignment may stray beyond the two lengths' difference. Two editions of
    /// one text stay near the diagonal, and a bound keeps a chapter's alignment linear in its length.
    static let band = 128

    /// For each element of `a`, its pair in `b`, or nil.
    static func align<A, B>(_ a: [A], _ b: [B], score: (A, B) -> Int) -> [Pair?] {
        let n = a.count
        let m = b.count
        let width = m + 1
        let unreachable = Int32.min / 4
        let reach = abs(n - m) + band
        var table = [Int32](repeating: unreachable, count: (n + 1) * width)
        // 0 pairs the two, 1 skips an element of a, 2 skips an element of b.
        var moves = [UInt8](repeating: 0, count: (n + 1) * width)
        for j in 0...m { table[j] = 0; moves[j] = 2 }
        for i in stride(from: 1, through: n, by: 1) { table[i * width] = 0; moves[i * width] = 1 }
        var scores = [Int32](repeating: 0, count: (n + 1) * width)
        for i in stride(from: 1, through: n, by: 1) {
            let center = i * m / n
            for j in stride(from: max(1, center - reach), through: min(m, center + reach), by: 1) {
                let pair = Int32(score(a[i - 1], b[j - 1]))
                scores[i * width + j] = pair
                let diagonal = pair > 0 ? table[(i - 1) * width + j - 1] + pair : unreachable
                let up = table[(i - 1) * width + j]
                let left = table[i * width + j - 1]
                var best = diagonal
                var move: UInt8 = 0
                if up > best { best = up; move = 1 }
                if left > best { best = left; move = 2 }
                table[i * width + j] = best
                moves[i * width + j] = move
            }
        }
        var result = [Pair?](repeating: nil, count: n)
        var i = n
        var j = m
        while i > 0, j > 0 {
            switch moves[i * width + j] {
            case 0:
                result[i - 1] = Pair(index: j - 1, score: Int(scores[i * width + j]))
                i -= 1
                j -= 1
            case 1: i -= 1
            default: j -= 1
            }
        }
        return result
    }

    /// The edit distance, or `limit + 1` as soon as it must exceed `limit`.
    static func levenshtein(_ a: [UInt32], _ b: [UInt32], limit: Int) -> Int {
        if abs(a.count - b.count) > limit { return limit + 1 }
        var previous = Array(0...b.count)
        var current = previous
        for i in stride(from: 1, through: a.count, by: 1) {
            current[0] = i
            var rowMin = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                let value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                current[j] = value
                rowMin = min(rowMin, value)
            }
            if rowMin > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}

/// How alike two folded Greek forms are, from bible-api's `wordMatchScore`.
enum GreekMatch {
    static let exact = 4
    static let movable = 3
    static let fuzzy = 2

    private static let nu: UInt32 = 0x03BD
    private static let sigma: UInt32 = 0x03C3
    /// ν σ α ε ο ι: a movable nu or sigma, or an elided final vowel, as in δι᾽ and διά.
    private static let droppable: Set<UInt32> = [0x03BD, 0x03C3, 0x03B1, 0x03B5, 0x03BF, 0x03B9]

    static func score(_ a: WordKey, _ b: WordKey) -> Int {
        let x = a.scalars
        let y = b.scalars
        if x.isEmpty || y.isEmpty { return 0 }
        if x == y { return exact }
        let (shorter, longer) = x.count < y.count ? (x, y) : (y, x)
        if longer.count == shorter.count + 1, longer.starts(with: shorter), droppable.contains(longer.last!) { return movable }
        // Spelling variants of one word, such as Δαυίδ and Δαβίδ.
        guard shorter.count >= 4 else { return 0 }
        let allowed = x[0] != y[0] ? (shorter.count >= 5 ? 1 : 0) : (shorter.count >= 7 ? 2 : 1)
        guard allowed > 0 else { return 0 }
        return Alignment.levenshtein(withoutMovable(x), withoutMovable(y), limit: allowed) <= allowed ? fuzzy : 0
    }

    /// The form and its movable nu or sigma partners: ἤκουε and ἤκουεν, οὕτω and οὕτως.
    static func movableVariants(_ key: String) -> [String] {
        var variants = [key, key + "ν", key + "σ"]
        if let last = key.unicodeScalars.last?.value, last == nu || last == sigma, key.unicodeScalars.count > 2 {
            variants.append(String(key.dropLast()))
        }
        return variants
    }

    private static func withoutMovable(_ word: [UInt32]) -> [UInt32] {
        if let last = word.last, last == nu || last == sigma { return Array(word.dropLast()) }
        return word
    }
}

/// How alike two folded Hebrew forms are. TAHOT and the WLC both come from the Leningrad Codex, so an exact
/// match is the rule and a near match is a spelling difference such as a Ketiv.
enum HebrewMatch {
    static let exact = 4
    static let near = 2

    static func score(_ a: WordKey, _ b: WordKey) -> Int {
        if a.scalars.isEmpty || b.scalars.isEmpty { return 0 }
        if a.scalars == b.scalars { return exact }
        let shorter = min(a.scalars.count, b.scalars.count)
        let allowed = shorter >= 6 ? 2 : shorter >= 3 ? 1 : 0
        guard allowed > 0 else { return 0 }
        return Alignment.levenshtein(a.scalars, b.scalars, limit: allowed) <= allowed ? near : 0
    }
}
