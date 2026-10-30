import BibleFormat

/// What a USFM marker, or the USFX element named after it, does to the chapter stream. Both parsers read this
/// one table, so a marker means the same thing in either format.
enum MarkerRole: Equatable {
    case paragraph(ParagraphRole)
    case character(CharacterRole)
    case note(NoteKind)
    case notePart(NotePartRole)
    /// `ref`: visible text, then `|` and a machine-readable target.
    case reference
    /// `w`: a word, with its Strong's number and morphology as attributes.
    case word
}

enum ParagraphRole: Equatable {
    case block(BlockKind)
    /// `nb`: the text continues the open block with no break.
    case continuation
    case blankLine
    case label(LabelKind)
    /// `r`: a line of parallel passages under a heading, kept as a cross-reference note on the heading.
    case parallelPassage
    case bookName(BookNameField)
    /// Not chapter content: identification, book titles, and introductions.
    case ignored
}

enum LabelKind: Equatable {
    case heading(Level)
    case title
    case speaker
}

/// The USFM name markers: `h` the running header, `toc1` the long title, `toc2` the short title, `toc3` the abbreviation.
enum BookNameField: Equatable, Hashable {
    case header
    case longTitle
    case shortTitle
    case abbreviation
}

enum CharacterRole: Equatable {
    case style(RunStyle)
    /// Formatting with no `RunStyle` bit. The text is kept unstyled.
    case plain
    /// Content that is not text, such as a figure or a published verse number.
    case hidden
}

enum NotePartRole: Equatable {
    case text
    /// `fr` and `xo`: the note's own reference, implied by where its caller sits.
    case hidden
    /// `fv`: a verse number quoted in a note, kept as text.
    case verseNumber
    /// `fp`: a paragraph break inside the note.
    case paragraph
}

enum Markers {
    static func role(_ name: String) -> MarkerRole? {
        if let role = table[name] { return role }
        // USFM introduction markers all begin with `i`; the table lists the `i` markers that are not introductions.
        if name.first == "i" { return .paragraph(.ignored) }
        return nil
    }

    /// Heading levels: `ms` (a major section such as "Book I") is 1, `s` and `s1` are 2, and `s2` and deeper are 3.
    /// The BSB uses `ms`, `s1`, and `s2`, so three levels keep every distinction it draws.
    private static let table: [String: MarkerRole] = {
        var table: [String: MarkerRole] = [:]
        func paragraph(_ role: ParagraphRole, _ names: String...) {
            for name in names { table[name] = .paragraph(role) }
        }
        func character(_ role: CharacterRole, _ names: String...) {
            for name in names { table[name] = .character(role) }
        }
        func part(_ role: NotePartRole, _ names: String...) {
            for name in names { table[name] = .notePart(role) }
        }

        paragraph(.block(.paragraph), "p")
        paragraph(.block(.flush), "m")
        paragraph(.block(.indented), "pmo", "pm", "pmc", "pmr", "mi", "pi", "pi1", "pi2", "pi3", "cls")
        paragraph(.block(.poetry(level: .one)), "q", "q1")
        paragraph(.block(.poetry(level: .two)), "q2")
        paragraph(.block(.poetry(level: .three)), "q3", "q4")
        paragraph(.block(.rightAligned), "qr", "pr", "qd")
        paragraph(.block(.centered), "qc", "pc")
        paragraph(.block(.list(level: .one)), "li", "li1", "lim", "lim1")
        paragraph(.block(.list(level: .two)), "li2", "lim2")
        paragraph(.block(.list(level: .three)), "li3", "li4", "lim3", "lim4")
        paragraph(.continuation, "nb")
        paragraph(.blankLine, "b")
        paragraph(.label(.heading(.one)), "ms", "ms1", "ms2", "ms3", "mr")
        paragraph(.label(.heading(.two)), "s", "s1", "sr")
        paragraph(.label(.heading(.three)), "s2", "s3", "s4")
        paragraph(.label(.title), "d", "qa")
        paragraph(.label(.speaker), "sp")
        paragraph(.parallelPassage, "r")
        paragraph(.bookName(.header), "h")
        paragraph(.bookName(.longTitle), "toc1")
        paragraph(.bookName(.shortTitle), "toc2")
        paragraph(.bookName(.abbreviation), "toc3")
        paragraph(
            .ignored,
            "id", "usfm", "ide", "mt", "mt1", "mt2", "mt3", "mt4", "mte", "mte1", "mte2", "cl", "cd", "cp",
            "rem", "sts", "restore", "toca1", "toca2", "toca3", "sd", "sd1", "sd2", "sd3", "sd4"
        )

        character(.style(.wordsOfJesus), "wj")
        character(.style(.addedWords), "add")
        character(.style(.divineName), "nd")
        character(.style(.transliteration), "tl")
        character(.style(.quotedScripture), "qt")
        character(.style(.selah), "qs")
        character(
            .plain,
            "k", "bk", "pn", "png", "addpn", "wg", "wh", "wa", "ord", "sig", "sls", "dc", "qac",
            "bd", "it", "bdit", "em", "sc", "no", "sup"
        )
        character(.hidden, "vp", "ca", "va", "fig", "rq", "jmp")

        table["f"] = .note(.footnote)
        table["fe"] = .note(.footnote)
        table["ef"] = .note(.footnote)
        table["x"] = .note(.crossReference)
        table["ex"] = .note(.crossReference)
        part(.text, "ft", "fq", "fqa", "fk", "fl", "fw", "fdc", "xt", "xq", "xk", "xta", "xop", "xot", "xnt", "xdc")
        part(.hidden, "fr", "xo")
        part(.verseNumber, "fv")
        part(.paragraph, "fp")

        table["ref"] = .reference
        table["w"] = .word
        return table
    }()
}
