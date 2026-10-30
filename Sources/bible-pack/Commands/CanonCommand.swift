import ArgumentParser
import Foundation

struct CanonCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "canon",
        abstract: "Build canon.sqlite from the BibleFormat tables (canon build), or check one against them (canon validate).",
        subcommands: [Build.self, Validate.self]
    )

    struct Build: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Write canon.sqlite: books, aliases, sections, versification schemes, verse counts, and mappings."
        )

        @Option(help: ArgumentHelp("Where the canon package is written. A published canon is named canon-<version>.sqlite.", valueName: "path"))
        var out = "dist/canon.sqlite"

        @OptionGroup var stamp: PackageVersionOptions

        func run() throws {
            let summary = try CanonPackage.build(to: URL(fileURLWithPath: out), version: stamp.packageVersion, builtAt: stamp.builtAtText)
            summary.lines.forEach { print($0) }
        }
    }

    struct Validate: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Check a canon.sqlite against the BibleFormat tables. Exits 1 on the first failure."
        )

        @Argument(help: "The canon package to validate.")
        var path: String

        func run() throws {
            try CanonPackage.validate(at: URL(fileURLWithPath: path)) { print("pass  \($0)") }
        }
    }
}
