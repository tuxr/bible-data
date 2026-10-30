import BibleFormat

/// The WLC's words: Strong's and morphology from the parser's OSHB tags, and glosses and the prefix and suffix
/// split from TAHOT, aligned verse by verse. No morph code comes from TAHOT, whose morphology is ETCBC's.
enum HebrewWords {
    static func build(
        _ books: [ParsedBook],
        tahot: [TAHOTWord],
        lemmas: (StrongID) -> String?
    ) -> (rows: [WordRow], coverage: WordsCoverage) {
        let byVerse = groupByHebrewVerse(tahot)
        var coverage = WordsCoverage()
        var rows: [WordRow] = []
        var ketiv = 0
        var partsWithoutMorph = 0
        var pieceCountMismatches = Tally()
        var strongDisagreements = Tally()
        var unmatched = Tally()

        for verse in books.flatMap(\.chapters).flatMap(\.words) {
            let candidates = byVerse[verse.ref] ?? []
            let keys = verse.words.map { WordKey(WordText.key($0.surface, script: .hebrew)) }
            let readings = candidates.map { word in
                (qere: WordKey(WordText.key(word.reading.text, script: .hebrew)), ketiv: word.ketiv.map { WordKey(WordText.key($0.text, script: .hebrew)) })
            }
            func score(_ key: WordKey, _ index: Int) -> Int {
                max(HebrewMatch.score(key, readings[index].qere), readings[index].ketiv.map { HebrewMatch.score(key, $0) } ?? 0)
            }
            let inOrder = keys.count == candidates.count && keys.indices.allSatisfy { score(keys[$0], $0) > 0 }
            let pairs: [Int?] = inOrder ? Array(keys.indices) : Alignment.align(keys, Array(candidates.indices), score: score).map { $0?.index }
            if !inOrder { coverage.fuzzyVerses += 1 }

            for (offset, tag) in verse.words.enumerated() {
                var row = WordRow(ref: verse.ref, position: tag.index, surface: tag.surface)
                row.strong = tag.strong.flatMap { StrongID($0, language: .hebrew) }
                row.morph = tag.morph
                if let index = pairs[offset] {
                    let candidate = candidates[index]
                    let key = keys[offset]
                    let reading: TAHOTReading
                    // The WLC prints the Ketiv, so it wins a tie with the Qere.
                    if let written = candidate.ketiv, let writtenKey = readings[index].ketiv,
                       HebrewMatch.score(key, writtenKey) >= HebrewMatch.score(key, readings[index].qere) {
                        reading = written
                        ketiv += 1
                    } else {
                        reading = candidate.reading
                    }
                    let stem = reading.pieces[reading.main].strong.map(\.base)
                    if let parsed = row.strong, let stem, parsed != stem {
                        strongDisagreements.add("\(verse.ref) word \(tag.index) \(tag.surface): parser \(parsed), TAHOT \(stem)")
                    }
                    row.strong = row.strong ?? stem.flatMap { $0.number < 9000 ? $0 : nil }
                    row.gloss = reading.gloss
                    if row.gloss != nil { coverage.contextualGloss += 1 }
                    if reading.pieces.count > 1 {
                        let pieceMorphs = row.morph.flatMap { pieces(of: $0, count: reading.pieces.count) }
                        if let morph = row.morph, pieceMorphs == nil {
                            pieceCountMismatches.add("\(verse.ref) word \(tag.index) \(tag.surface): OSHB \(morph), TAHOT \(reading.pieces.map(\.text).joined(separator: "/"))")
                        } else if row.morph == nil {
                            partsWithoutMorph += 1
                        }
                        row.parts = parts(of: reading, morphs: pieceMorphs, surface: tag.surface, key: key, stem: row.strong)
                    }
                } else {
                    coverage.unmatched += 1
                    unmatched.add("\(verse.ref) word \(tag.index) \(tag.surface)")
                }
                row.lemma = row.strong.flatMap(lemmas)
                coverage.count(row)
                rows.append(row)
            }
        }
        coverage.notes = [
            ("Ketiv readings used", ketiv),
            ("Strong's disagreements, parser and TAHOT", strongDisagreements.count),
            ("words with parts but no OSHB morph", partsWithoutMorph),
            ("OSHB and TAHOT piece counts disagree", pieceCountMismatches.count),
        ]
        coverage.examples = [
            ("first Strong's disagreements (the parser's id is kept)", strongDisagreements.examples),
            ("first piece count disagreements (parts keep no morph)", pieceCountMismatches.examples),
            ("first unmatched words", unmatched.examples),
        ]
        return (rows, coverage)
    }

    /// TAHOT rows by the verse they have in the WLC's `heb` numbering: the parenthesized Hebrew reference where
    /// TAHOT gives one, else the reference as written, since TAHOT gives one wherever the two differ. Rows for
    /// words the Leningrad Codex lacks are left out.
    static func groupByHebrewVerse(_ words: [TAHOTWord]) -> [VerseRef: [TAHOTWord]] {
        var byVerse: [VerseRef: [TAHOTWord]] = [:]
        for word in words where word.inLeningrad {
            byVerse[word.reference.parenthesized ?? word.reference.ref, default: []].append(word)
        }
        return byVerse
    }

    /// An OSHB code split into one code per piece: `HC/Td/Ncfsa` is `HC`, `HTd`, and `HNcfsa`, since OSHB writes
    /// the language letter once. Nil when the code has a different number of pieces.
    static func pieces(of morph: String, count: Int) -> [String]? {
        let segments = morph.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.count == count, let language = segments.first?.first, segments.allSatisfy({ !$0.isEmpty }) else { return nil }
        return segments.enumerated().map { $0.offset == 0 ? $0.element : String(language) + $0.element }
    }

    /// The pieces of a word TAHOT splits. The stem carries the word's own Strong's id, at the lexicon's level;
    /// a prefix or suffix carries TAHOT's code for it, H9001 to H9049. Each piece gets its slice of the WLC
    /// surface when the word's letters split cleanly into the pieces' letter counts.
    static func parts(of reading: TAHOTReading, morphs: [String]?, surface: String, key: WordKey, stem: StrongID?) -> [WordPart] {
        let counts = reading.pieces.map { WordText.key($0.text, script: .hebrew).unicodeScalars.count }
        let slices = key.text == WordText.key(reading.text, script: .hebrew) ? split(surface, letterCounts: counts) : nil
        return reading.pieces.enumerated().map { index, piece in
            WordPart(
                strong: (index == reading.main ? stem ?? piece.strong?.base : piece.strong?.base)?.description,
                morph: morphs?[index],
                gloss: piece.gloss,
                surface: slices?[index]
            )
        }
    }

    /// Splits a word into pieces of the given letter counts, keeping each letter's points and accents with it:
    /// `וְהָאָ֗רֶץ` with 1, 1, 3 is `וְ`, `הָ`, `אָ֗רֶץ`. Nil when the counts do not add up to the word's letters.
    static func split(_ word: String, letterCounts: [Int]) -> [String]? {
        var clusters: [String.UnicodeScalarView] = []
        for scalar in word.unicodeScalars {
            if scalar.isLetter || clusters.isEmpty {
                clusters.append(String.UnicodeScalarView([scalar]))
            } else {
                clusters[clusters.count - 1].append(scalar)
            }
        }
        guard letterCounts.allSatisfy({ $0 > 0 }), letterCounts.reduce(0, +) == clusters.count,
              word.unicodeScalars.first?.isLetter == true else { return nil }
        var pieces: [String] = []
        var start = 0
        for count in letterCounts {
            pieces.append(clusters[start..<start + count].map(String.init).joined())
            start += count
        }
        return pieces
    }
}
