import ArgumentParser
import BibleFormat
import Foundation

/// The options `build-words` and `build-lexicon` share with `build`.
struct PackageOutputOptions: ParsableArguments {
    @Option(help: "Directory the package is written to.")
    var out = "dist/"

    @Option(help: ArgumentHelp("The package version. Defaults to the year and month of --built-at, in UTC.", valueName: "yyyy.mm"))
    var version: String?

    @Option(help: ArgumentHelp("Pin meta.built_at, so two builds are byte-identical. Defaults to now.", valueName: "iso8601"))
    var builtAt: String?

    func validate() throws {
        if let builtAt, CanonPackage.parseBuiltAt(builtAt) == nil {
            throw ValidationError("--built-at takes an ISO 8601 UTC time such as 2026-10-29T00:00:00Z, got \(builtAt)")
        }
        if let version, !PackageWriter.isValidVersion(version) {
            throw ValidationError("--version takes yyyy.mm, such as 2026.10, got \(version)")
        }
    }

    var date: Date { builtAt.flatMap(CanonPackage.parseBuiltAt) ?? Date() }

    func destination(_ name: (String) -> String) -> URL {
        URL(fileURLWithPath: out, isDirectory: true).appendingPathComponent(name(version ?? PackageWriter.version(for: date)))
    }
}

struct BuildWords: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build-words",
        abstract: "Build a tagged edition's words package and its .xz download.",
        discussion: "Aligns the edition's words, at the parser's positions, with the edition's word sources and prints the coverage."
    )

    /// Gloss for every edition and TCGNT morphology must cover this share of words, unless --allow-gaps.
    static let coverageFloor = 0.95

    @OptionGroup var global: GlobalOptions
    @OptionGroup var output: PackageOutputOptions

    @Argument(help: ArgumentHelp("The tagged edition: \(TaggedEdition.allCases.map(\.rawValue).joined(separator: " or ")).", valueName: "edition"))
    var editionID: String

    @Option(help: "The directory of edition metadata files, <id>.json.")
    var editionsDir = "editions"

    @Flag(help: "Write the package even when coverage is under the floor.")
    var allowGaps = false

    func validate() throws {
        if TaggedEdition(rawValue: editionID) == nil {
            throw ValidationError("build-words takes \(TaggedEdition.allCases.map(\.rawValue).joined(separator: " or ")), got \(editionID)")
        }
    }

    func run() throws {
        let tagged = TaggedEdition(rawValue: editionID)!
        let lock = try global.readLock()
        let edition = try EditionInput.load(
            editionID, editionsDirectory: URL(fileURLWithPath: editionsDir, isDirectory: true), lock: lock, cache: global.cache
        )
        let built = try tagged.build(edition, lock: lock, cache: global.cache)
        built.coverage.lines.forEach { print($0) }
        let shortfalls = built.coverage.shortfalls(floor: Self.coverageFloor, requireMorph: tagged.requiresMorph)
        if !shortfalls.isEmpty, !allowGaps {
            throw PackageError(description: shortfalls.joined(separator: "; ") + "; pass --allow-gaps to write it anyway")
        }
        let content = WordsContent(
            edition: edition, tagged: tagged, lock: lock, builtAt: CanonPackage.formatBuiltAt(output.date), rows: built.rows
        )
        let summary = try PackageWriter.build(
            ddl: WordsSchema.ddl, tables: content.tables(),
            to: output.destination { WordsSchema.fileName(edition: editionID, version: $0) }
        )
        summary.lines.forEach { print($0) }
    }
}
