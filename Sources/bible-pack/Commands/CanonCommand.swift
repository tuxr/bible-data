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

        @Option(help: "Where the canon package is written.")
        var out = "dist/canon.sqlite"

        @Option(help: ArgumentHelp("Pin meta.built_at, so two builds are byte-identical. Defaults to now.", valueName: "iso8601"))
        var builtAt: String?

        func validate() throws {
            if let builtAt, CanonPackage.parseBuiltAt(builtAt) == nil {
                throw ValidationError("--built-at takes an ISO 8601 UTC time such as 2026-10-29T00:00:00Z, got \(builtAt)")
            }
        }

        func run() throws {
            let date = builtAt.flatMap(CanonPackage.parseBuiltAt) ?? Date()
            let summary = try CanonPackage.build(to: URL(fileURLWithPath: out), builtAt: CanonPackage.formatBuiltAt(date))
            let width = summary.rowCounts.map(\.table.count).max() ?? 0
            for (table, rows) in summary.rowCounts {
                print(table.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + String(rows))
            }
            print("\(out)  \(summary.bytes) bytes  sha256 \(summary.sha256)")
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
