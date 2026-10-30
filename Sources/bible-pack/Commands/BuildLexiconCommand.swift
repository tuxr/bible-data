import ArgumentParser
import BibleFormat
import Foundation

struct BuildLexicon: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build-lexicon",
        abstract: "Build the Greek or Hebrew lexicon package and its .xz download.",
        discussion: """
        With --count-from, each entry's occurrences counts the id in that words package, and the build fails when \
        the words package uses an id the lexicon lacks. The Hebrew lexicon also takes each id's part of speech and \
        gloss from it.
        """
    )

    @OptionGroup var global: GlobalOptions
    @OptionGroup var output: PackageOutputOptions

    @Argument(help: ArgumentHelp("greek or hebrew.", valueName: "language"))
    var language: String

    @Option(help: ArgumentHelp("A words package of the same language to count occurrences in.", valueName: "words file"))
    var countFrom: String?

    @Flag(help: "Write the package even when the words package uses ids the lexicon lacks.")
    var allowGaps = false

    func validate() throws {
        if LexiconLanguage(rawValue: language) == nil {
            throw ValidationError("build-lexicon takes greek or hebrew, got \(language)")
        }
    }

    func run() throws {
        let language = LexiconLanguage(rawValue: language)!
        let lock = try global.readLock()
        let usage = try countFrom.map { try WordsUsage.read(URL(fileURLWithPath: $0)) }
        if let usage, usage.edition.lexicon != language {
            throw PackageError(description: "\(countFrom!) is \(usage.edition.rawValue) words, not \(language.rawValue)")
        }
        let build = switch language {
        case .greek: try LexiconBuild.greek(lock: lock, cache: global.cache, usage: usage)
        case .hebrew: try LexiconBuild.hebrew(lock: lock, cache: global.cache, usage: usage)
        }
        print("entries  \(build.entries.count)")
        for note in build.notes { print("\(note.label)  \(note.count)") }
        if usage != nil {
            print("ids the words package uses that the lexicon lacks  \(build.missing.count)"
                + (build.missing.isEmpty ? "" : ": " + build.missing.prefix(10).map(\.description).joined(separator: " ")))
            if !build.missing.isEmpty, !allowGaps {
                throw PackageError(description: "the lexicon lacks \(build.missing.count) ids the words package uses; pass --allow-gaps to write it anyway")
            }
        }
        let summary = try PackageWriter.build(
            ddl: LexiconSchema.ddl, tables: build.tables(version: output.stamp.packageVersion, builtAt: output.stamp.builtAtText),
            to: output.destination(language.fileName)
        )
        summary.lines.forEach { print($0) }
    }
}
