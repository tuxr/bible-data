import BibleFormat

/// The WLC's words: morphology and its pieces from OSHB, Strong's from the parser's tags and then OSHB's lemma,
/// and glosses and the prefix and suffix ids from TAHOT, each aligned verse by verse. No morph code comes from
/// TAHOT, whose morphology is ETCBC's.
enum HebrewWords {
    static func build(
        _ books: [ParsedBook],
        oshb: [VerseRef: [OSHBWord]],
        tahot: [TAHOTWord],
        lemmas: (StrongID) -> String?
    ) -> (rows: [WordRow], coverage: WordsCoverage) {
        let byVerse = groupByHebrewVerse(tahot)
        var coverage = WordsCoverage()
        var rows: [WordRow] = []
        var oshbMatched = 0
        var oshbKetiv = 0
        var tahotKetiv = 0
        var tahotFuzzyVerses = 0
        var strongFromOSHB = 0
        var strongFromTAHOT = 0
        var partsWithoutMorph = 0
        var invalidMorphs = Tally()
        var parserMorphsReplaced = Tally()
        var pieceCountMismatches = Tally()
        var strongDisagreements = Tally()
        var unmatched = Tally()
        var unmatchedTAHOT = Tally()

        for verse in books.flatMap(\.chapters).flatMap(\.words) {
            let keys = verse.words.map { WordKey(WordText.key($0.surface, script: .hebrew)) }
            let tagged = oshb[verse.ref] ?? []
            let taggedKeys = tagged.map { WordKey(WordText.key($0.surface, script: .hebrew)) }
            let oshbPairs = pair(keys, count: tagged.count) { HebrewMatch.score($0, taggedKeys[$1]) }
            if oshbPairs.fuzzy { coverage.fuzzyVerses += 1 }

            let candidates = byVerse[verse.ref] ?? []
            let readings = candidates.map { word in
                (qere: WordKey(WordText.key(word.reading.text, script: .hebrew)), ketiv: word.ketiv.map { WordKey(WordText.key($0.text, script: .hebrew)) })
            }
            let tahotPairs = pair(keys, count: candidates.count) { key, index in
                max(HebrewMatch.score(key, readings[index].qere), readings[index].ketiv.map { HebrewMatch.score(key, $0) } ?? 0)
            }
            if tahotPairs.fuzzy { tahotFuzzyVerses += 1 }

            for (offset, tag) in verse.words.enumerated() {
                var row = WordRow(ref: verse.ref, position: tag.index, surface: tag.surface)
                let parsed = tag.strong.flatMap { StrongID($0, language: .hebrew) }
                row.strong = parsed
                let key = keys[offset]

                let word = oshbPairs.indices[offset].map { tagged[$0] }
                if let word {
                    oshbMatched += 1
                    if word.isKetiv { oshbKetiv += 1 }
                    if let morph = word.morph {
                        if OSHBMorph.isValid(morph) {
                            row.morph = morph
                        } else {
                            invalidMorphs.add("\(verse.ref) word \(tag.index) \(tag.surface): \(morph)")
                        }
                    }
                    if let own = tag.morph, let morph = row.morph, own != morph {
                        parserMorphsReplaced.add("\(verse.ref) word \(tag.index) \(tag.surface): parser \(own), OSHB \(morph)")
                    }
                    if row.strong == nil, let strong = word.strong {
                        row.strong = strong
                        strongFromOSHB += 1
                    }
                } else {
                    coverage.unmatched += 1
                    unmatched.add("\(verse.ref) word \(tag.index) \(tag.surface)")
                }

                var reading: TAHOTReading?
                if let index = tahotPairs.indices[offset] {
                    let candidate = candidates[index]
                    // The WLC prints the Ketiv, so it wins a tie with the Qere.
                    if let written = candidate.ketiv, let writtenKey = readings[index].ketiv,
                       HebrewMatch.score(key, writtenKey) >= HebrewMatch.score(key, readings[index].qere) {
                        reading = written
                        tahotKetiv += 1
                    } else {
                        reading = candidate.reading
                    }
                    let stem = reading!.pieces[reading!.main].strong.map(\.base)
                    if let parsed, let stem, parsed != stem {
                        strongDisagreements.add("\(verse.ref) word \(tag.index) \(tag.surface): parser \(parsed), TAHOT \(stem)")
                    }
                    if row.strong == nil, let stem, stem.number < 9000 {
                        row.strong = stem
                        strongFromTAHOT += 1
                    }
                    row.gloss = reading!.gloss
                    if row.gloss != nil { coverage.contextualGloss += 1 }
                } else {
                    unmatchedTAHOT.add("\(verse.ref) word \(tag.index) \(tag.surface)")
                }

                if let word, row.morph != nil {
                    let piecesAgree = reading.map { $0.pieces.count == word.pieces.count } ?? true
                    if !piecesAgree, let reading {
                        pieceCountMismatches.add("\(verse.ref) word \(tag.index) \(tag.surface): OSHB \(word.pieces.map(\.surface).joined(separator: "/")), TAHOT \(reading.pieces.map(\.text).joined(separator: "/"))")
                    }
                    if word.pieces.count > 1 {
                        row.parts = parts(of: word, reading: piecesAgree ? reading : nil, surface: tag.surface, key: key, stem: row.strong)
                    }
                } else if let reading, reading.pieces.count > 1 {
                    partsWithoutMorph += 1
                    row.parts = parts(of: reading, surface: tag.surface, key: key, stem: row.strong)
                }
                row.lemma = row.strong.flatMap(lemmas)
                coverage.count(row)
                rows.append(row)
            }
        }
        coverage.notes = [
            ("OSHB words matched to no WLC word", oshb.values.reduce(0) { $0 + $1.count } - oshbMatched),
            ("Ketiv words, as the WLC prints them", oshbKetiv),
            ("OSHB codes outside the code grammar", invalidMorphs.count),
            ("parser morph codes OSHB's replaces", parserMorphsReplaced.count),
            ("Strong's filled from OSHB lemma", strongFromOSHB),
            ("Strong's filled from TAHOT", strongFromTAHOT),
            ("verses needing fuzzy alignment to TAHOT", tahotFuzzyVerses),
            ("words matched to no TAHOT word", unmatchedTAHOT.count),
            ("TAHOT Ketiv readings used", tahotKetiv),
            ("Strong's disagreements, parser and TAHOT", strongDisagreements.count),
            ("OSHB and TAHOT piece counts disagree", pieceCountMismatches.count),
            ("words with TAHOT parts but no OSHB morph", partsWithoutMorph),
        ]
        coverage.examples = [
            ("first OSHB codes outside the grammar (left out)", invalidMorphs.examples),
            ("first parser morph codes OSHB's replaces", parserMorphsReplaced.examples),
            ("first Strong's disagreements (the parser's id is kept)", strongDisagreements.examples),
            ("first piece count disagreements (those parts get no gloss)", pieceCountMismatches.examples),
            ("first words matched to no OSHB word", unmatched.examples),
            ("first words matched to no TAHOT word", unmatchedTAHOT.examples),
        ]
        return (rows, coverage)
    }

    /// Each word's index in a source's words for the verse: by position when the counts agree and every pair
    /// matches, else by the banded alignment, which counts as fuzzy.
    static func pair(_ keys: [WordKey], count: Int, score: (WordKey, Int) -> Int) -> (indices: [Int?], fuzzy: Bool) {
        if keys.count == count, keys.indices.allSatisfy({ score(keys[$0], $0) > 0 }) { return (Array(keys.indices), false) }
        return (Alignment.align(keys, Array(0..<count), score: score).map { $0?.index }, true)
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

    /// The pieces of a word OSHB splits, each with its code. With a TAHOT reading of as many pieces, each also
    /// takes TAHOT's gloss, and a prefix or suffix TAHOT's code for it, H9001 to H9049. The stem, OSHB's last
    /// piece before any suffix, carries the word's own Strong's id. A word OSHB tags as two, with two stems,
    /// gives each stem its own lemma's id instead.
    static func parts(of word: OSHBWord, reading: TAHOTReading?, surface: String, key: WordKey, stem: StrongID?) -> [WordPart] {
        let main = word.pieces.lastIndex { !$0.isSuffix } ?? 0
        let lemmas = word.pieces.map { $0.lemma.flatMap(OSHBWord.strong) }
        let ownStems = lemmas.compactMap { $0 }.count > 1
        let counts = word.pieces.map { WordText.key($0.surface, script: .hebrew).unicodeScalars.count }
        let slices = key.text == WordText.key(word.surface, script: .hebrew) ? split(surface, letterCounts: counts) : nil
        return word.pieces.enumerated().map { index, piece in
            let tahot = reading?.pieces[index]
            let id = ownStems && lemmas[index] != nil ? lemmas[index] : index == main ? stem ?? tahot?.strong?.base : tahot?.strong?.base
            return WordPart(
                strong: id?.description,
                morph: piece.morph,
                gloss: tahot?.gloss,
                surface: slices?[index]
            )
        }
    }

    /// The pieces of a word only TAHOT splits, for a word OSHB gives no code: no morph, TAHOT's ids and glosses.
    static func parts(of reading: TAHOTReading, surface: String, key: WordKey, stem: StrongID?) -> [WordPart] {
        let counts = reading.pieces.map { WordText.key($0.text, script: .hebrew).unicodeScalars.count }
        let slices = key.text == WordText.key(reading.text, script: .hebrew) ? split(surface, letterCounts: counts) : nil
        return reading.pieces.enumerated().map { index, piece in
            WordPart(
                strong: (index == reading.main ? stem ?? piece.strong?.base : piece.strong?.base)?.description,
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
