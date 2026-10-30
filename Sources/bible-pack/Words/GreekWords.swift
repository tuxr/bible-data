import BibleFormat

/// The TCGNT's words: Strong's from the parser, Robinson morphology from Byztxt, and glosses from TAGNT, each
/// aligned chapter by chapter so a verse numbered differently or a word the editions disagree on costs only
/// the words involved.
enum GreekWords {
    private struct ChapterKey: Hashable {
        let book: Book
        let chapter: Int
    }

    private struct Unit {
        let ref: VerseRef
        let tag: WordTag
        let key: WordKey
    }

    /// The Strong's ids Byztxt gives each form anywhere in the NT, for the rule that trusts a fuzzy pair only
    /// when Byztxt never uses the word's exact form for a different word.
    private static func formStrongs(_ words: some Sequence<ByztxtWord>) -> [String: Set<StrongID>] {
        var strongs: [String: Set<StrongID>] = [:]
        for word in words {
            strongs[WordText.key(word.form, script: .greek), default: []].formUnion(word.analyses.map(\.strong))
        }
        return strongs
    }

    static func build(
        _ books: [ParsedBook],
        byztxt: [Book: [ByztxtWord]],
        tagnt: [TAGNTWord],
        tbesg: [StrongID: TBESGEntry],
        strongs: [StrongID: StrongsEntry]
    ) -> (rows: [WordRow], coverage: WordsCoverage) {
        let byzByChapter = Dictionary(grouping: Book.allCases.flatMap { book in (byztxt[book] ?? []).map { (book, $0) } }) {
            ChapterKey(book: $0.0, chapter: $0.1.chapter)
        }.mapValues { $0.map(\.1) }
        let forms = formStrongs(Book.allCases.flatMap { byztxt[$0] ?? [] })
        let tagntByChapter = Dictionary(grouping: tagnt) { ChapterKey(book: $0.reference.ref.book, chapter: $0.reference.ref.chapter) }
        // TAGNT tags some forms below lemma level (ὀφθέντες as G3700, under ὁράω G3708), so its lemma is read too.
        var lemmaStrong: [String: StrongID] = [:]
        let lemmas = tbesg.values.map { ($0.strong, $0.lemma) } + strongs.values.map { ($0.strong, $0.lemma) }
        for (id, lemma) in lemmas.sorted(by: { $0.0 < $1.0 }) where lemmaStrong[WordText.key(lemma, script: .greek)] == nil {
            lemmaStrong[WordText.key(lemma, script: .greek)] = id
        }

        var coverage = WordsCoverage()
        var rows: [WordRow] = []
        var byztxtWins = Tally()
        var parserKept = Tally()
        var unmatched = Tally()
        var untaggedByParser = 0

        for chapter in books.flatMap(\.chapters) {
            let key = ChapterKey(book: chapter.chapter.book, chapter: chapter.chapter.number)
            let units = chapter.words.flatMap { verse in
                verse.words.map { Unit(ref: verse.ref, tag: $0, key: WordKey(WordText.key($0.surface, script: .greek))) }
            }
            let byz = byzByChapter[key] ?? []
            let byzKeys = byz.map { WordKey(WordText.key($0.form, script: .greek)) }
            let step = tagntByChapter[key] ?? []
            let stepKeys = step.map { WordKey(WordText.key($0.greek, script: .greek)) }
            let byzPairs = Alignment.align(units.map(\.key), byzKeys, score: GreekMatch.score)
            let stepPairs = Alignment.align(units.map(\.key), stepKeys, score: GreekMatch.score)
            var fuzzyVerses = Set<VerseRef>()

            for (offset, unit) in units.enumerated() {
                var row = WordRow(ref: unit.ref, position: unit.tag.index, surface: unit.tag.surface)
                let parsed = unit.tag.strong.flatMap { StrongID($0, language: .greek) }
                if parsed == nil { untaggedByParser += 1 }
                let hint = stepPairs[offset].map { step[$0.index] }
                let known = forms[unit.key.text]

                var analysis: ByztxtWord.Analysis?
                var strong = parsed
                if let pair = byzPairs[offset] {
                    let word = byz[pair.index]
                    if pair.score < GreekMatch.exact { fuzzyVerses.insert(unit.ref) }
                    // A fuzzy pair is trusted only when Byztxt never uses this exact form for a different word.
                    let trusted = pair.score >= GreekMatch.movable || known == nil
                        || word.analyses.contains { known!.contains($0.strong) }
                    if trusted {
                        // An ambiguous form's first analysis is Robinson-Pierpont's own preference.
                        analysis = word.analyses.first
                        let byzStrong = analysis!.strong
                        let example = "\(unit.ref) word \(unit.tag.index) \(unit.tag.surface): parser \(parsed?.description ?? "none"), Byztxt \(byzStrong)"
                        // The eBible tags ignore accents and breathings, so ἢ "or" is tagged as the article and τίς
                        // as τις; on the same form, Robinson's tag in context is the one to keep.
                        if parsed == nil {
                            strong = byzStrong
                        } else if byzStrong != parsed, pair.score >= GreekMatch.movable {
                            byztxtWins.add(example)
                            strong = byzStrong
                        } else if byzStrong != parsed {
                            parserKept.add(example)
                        }
                    }
                } else {
                    fuzzyVerses.insert(unit.ref)
                }
                if analysis == nil { unmatched.add("\(unit.ref) word \(unit.tag.index) \(unit.tag.surface)") }

                row.strong = strong
                row.morph = analysis?.morph
                if let strong = row.strong, let hint, hint.strongs.contains(strong)
                    || hint.lemmas.contains(where: { lemmaStrong[WordText.key($0, script: .greek)] == strong }),
                   let gloss = hint.gloss {
                    row.gloss = gloss
                    coverage.contextualGloss += 1
                } else if let gloss = row.strong.flatMap({ tbesg[$0]?.gloss }) {
                    row.gloss = gloss
                    coverage.lexiconGloss += 1
                }
                row.lemma = row.strong.flatMap { tbesg[$0]?.lemma ?? strongs[$0]?.lemma }
                coverage.count(row)
                rows.append(row)
            }
            coverage.fuzzyVerses += fuzzyVerses.count
        }
        coverage.unmatched = unmatched.count
        coverage.notes = [
            ("words the parser left without Strong's", untaggedByParser),
            ("Strong's disagreements, parser and Byztxt", byztxtWins.count + parserKept.count),
            ("  on the same form, Byztxt's id kept", byztxtWins.count),
            ("  on a fuzzy pair, the parser's id kept", parserKept.count),
        ]
        coverage.examples = [
            ("first disagreements where Byztxt's id is kept", byztxtWins.examples),
            ("first disagreements where the parser's id is kept", parserKept.examples),
            ("first words Byztxt does not pair (morph left null)", unmatched.examples),
        ]
        return (rows, coverage)
    }
}
