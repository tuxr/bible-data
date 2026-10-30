import ArgumentParser
import BibleFormat
import Foundation

struct Build: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Build one edition's package and its .xz download from its locked source."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "The edition to build, such as bsb.")
    var editionID: String

    @Option(help: "Directory the package is written to.")
    var out = "dist/"

    @Option(help: "The directory of edition metadata files, <id>.json.")
    var editionsDir = "editions"

    @Option(help: ArgumentHelp("The package version. Defaults to the year and month of --built-at, in UTC.", valueName: "yyyy.mm"))
    var version: String?

    @Option(help: ArgumentHelp("Pin meta.built_at, so two builds are byte-identical. Defaults to now.", valueName: "iso8601"))
    var builtAt: String?

    @Option(help: ArgumentHelp("The chapter encoding: \(ChapterEncoding.allCases.map { "\($0)" }.joined(separator: ", ")).", valueName: "encoding"))
    var encoding = "\(EditionPackage.defaultEncoding)"

    var chapterEncoding: ChapterEncoding? {
        ChapterEncoding.allCases.first { "\($0)" == encoding }
    }

    func validate() throws {
        if let builtAt, CanonPackage.parseBuiltAt(builtAt) == nil {
            throw ValidationError("--built-at takes an ISO 8601 UTC time such as 2026-10-29T00:00:00Z, got \(builtAt)")
        }
        if let version, !PackageWriter.isValidVersion(version) {
            throw ValidationError("--version takes yyyy.mm, such as 2026.10, got \(version)")
        }
        if chapterEncoding == nil {
            throw ValidationError("unknown --encoding \(encoding); known: \(ChapterEncoding.allCases.map { "\($0)" }.joined(separator: ", "))")
        }
    }

    func run() throws {
        let date = builtAt.flatMap(CanonPackage.parseBuiltAt) ?? Date()
        let input = try EditionInput.load(
            editionID,
            editionsDirectory: URL(fileURLWithPath: editionsDir, isDirectory: true),
            lock: try global.readLock(),
            cache: global.cache
        )
        let destination = URL(fileURLWithPath: out, isDirectory: true)
            .appendingPathComponent(EditionPackage.fileName(id: input.metadata.id, version: version ?? PackageWriter.version(for: date)))
        let summary = try EditionPackage.build(
            input.content(builtAt: CanonPackage.formatBuiltAt(date), encoding: chapterEncoding!),
            to: destination
        )
        summary.lines.forEach { print($0) }
    }
}
