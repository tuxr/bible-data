import Foundation

/// The `verses.text_search` rule. FTS5's `unicode61 remove_diacritics 2` folds case and Latin diacritics but
/// not Hebrew points or polytonic Greek, so the packager folds those here and the app folds its queries the
/// same way.
public enum SearchText {
    public static func normalize(_ text: String, script: Script) -> String {
        switch script {
        case .latin: text
        case .hebrew: hebrew(text)
        case .greek: greek(text)
        }
    }

    /// The `verses.text_search` column: the folded text, or nil when folding leaves the plain text unchanged,
    /// so a Latin edition does not store its text twice.
    public static func column(plain: String, script: Script) -> String? {
        let folded = normalize(plain, script: script)
        return folded == plain ? nil : folded
    }

    /// The same fold as `normalize`, for a query typed against an edition in `script`.
    public static func normalizeQuery(_ query: String, script: Script) -> String {
        normalize(query, script: script)
    }

    /// Removes the points and cantillation marks. Maqaf, paseq, sof pasuq, and nun hafukha stay, because they
    /// are punctuation the tokenizer splits on.
    private static func hebrew(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !hebrewMarks.contains(scalar.value) {
            out.append(scalar)
        }
        return String(out)
    }

    private static let hebrewMarks: Set<UInt32> = Set(0x0591...0x05BD).union([0x05BF, 0x05C1, 0x05C2, 0x05C4, 0x05C5, 0x05C7])

    /// Decomposes, drops every combining mark, lowercases, and folds every sigma to `σ`. Lowercasing comes
    /// before the sigma fold because a locale-aware lowercase turns a word-final `Σ` into `ς`.
    private static func greek(_ text: String) -> String {
        var stripped = String.UnicodeScalarView()
        for scalar in text.decomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: continue
            default: stripped.append(scalar)
            }
        }
        var out = String.UnicodeScalarView()
        for scalar in String(stripped).lowercased().unicodeScalars {
            out.append(sigmas.contains(scalar) ? "σ" : scalar)
        }
        return String(out)
    }

    /// Final sigma and lunate sigma. `lowercased()` turns the capital lunate sigma into the small one.
    private static let sigmas: Set<Unicode.Scalar> = ["\u{03C2}", "\u{03F2}"]
}
