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

    @OptionGroup var output: PackageOutputOptions

    @Option(help: "The directory of edition metadata files, <id>.json.")
    var editionsDir = "editions"

    @Option(help: ArgumentHelp("The chapter encoding: \(ChapterEncoding.allCases.map { "\($0)" }.joined(separator: ", ")).", valueName: "encoding"))
    var encoding = "\(EditionPackage.defaultEncoding)"

    var chapterEncoding: ChapterEncoding? {
        ChapterEncoding.allCases.first { "\($0)" == encoding }
    }

    func validate() throws {
        if chapterEncoding == nil {
            throw ValidationError("unknown --encoding \(encoding); known: \(ChapterEncoding.allCases.map { "\($0)" }.joined(separator: ", "))")
        }
    }

    func run() throws {
        let input = try EditionInput.load(
            editionID,
            editionsDirectory: URL(fileURLWithPath: editionsDir, isDirectory: true),
            lock: try global.readLock(),
            cache: global.cache
        )
        let summary = try EditionPackage.build(
            input.content(version: output.stamp.packageVersion, builtAt: output.stamp.builtAtText, encoding: chapterEncoding!),
            to: output.destination { PackageSchema.fileName(id: input.metadata.id, version: $0) }
        )
        summary.lines.forEach { print($0) }
    }
}
