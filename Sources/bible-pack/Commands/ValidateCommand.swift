import ArgumentParser
import BibleFormat
import Foundation

struct Validate: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check a built package of any kind, named by its meta.kind. Exits 1 on the first failure.",
        discussion: """
        An edition package: integrity, the canon, text round trips, search, notes, and its .xz. A words package: \
        verse ids, positions, Strong's ids, parts, and with --lexicon every id in that lexicon. A lexicon package: \
        ids, order, lemmas, and with --words every id that words package uses. A canon package: as `canon validate`.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "The package file to validate.")
    var packagePath: String

    @Flag(help: "Parse the edition again from its locked source and compare, for an edition or words package.")
    var againstSource = false

    @Option(help: "The directory of edition metadata files, <id>.json, for --against-source.")
    var editionsDir = "editions"

    @Option(help: ArgumentHelp("For a words package, a lexicon package that must define every Strong's id it uses.", valueName: "lexicon file"))
    var lexicon: String?

    @Option(help: ArgumentHelp("For a lexicon package, a words package whose every Strong's id it must define.", valueName: "words file"))
    var words: String?

    func run() throws {
        let url = URL(fileURLWithPath: packagePath)
        let source: ((String) throws -> EditionInput)? = againstSource ? { id in
            try EditionInput.load(
                id,
                editionsDirectory: URL(fileURLWithPath: editionsDir, isDirectory: true),
                lock: try global.readLock(),
                cache: global.cache
            )
        } : nil
        func report(_ check: String, _ detail: String) {
            print("pass  \(check)\(detail.isEmpty ? "" : ": \(detail)")")
        }
        switch try CompanionValidator.kind(of: url) {
        case .edition:
            try PackageValidator.validate(at: url, source: source) { report($0.rawValue, $1) }
        case .words:
            try CompanionValidator.validateWords(at: url, lexicon: lexicon.map(URL.init(fileURLWithPath:)), source: source) { report($0.rawValue, $1) }
        case .lexicon:
            try CompanionValidator.validateLexicon(at: url, words: words.map(URL.init(fileURLWithPath:))) { report($0.rawValue, $1) }
        case .canon:
            try CanonPackage.validate(at: url) { report($0, "") }
        }
    }
}
