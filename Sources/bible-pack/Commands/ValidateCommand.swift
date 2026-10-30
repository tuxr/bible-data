import ArgumentParser
import BibleFormat
import Foundation

struct Validate: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check a built package: integrity, the canon, text round trips, search, notes, and its .xz. Exits 1 on the first failure."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "The package file to validate.")
    var packagePath: String

    @Flag(help: "Parse the edition again from its locked source and compare every chapter and row.")
    var againstSource = false

    @Option(help: "The directory of edition metadata files, <id>.json, for --against-source.")
    var editionsDir = "editions"

    func run() throws {
        let source: ((String) throws -> EditionInput)? = againstSource ? { id in
            try EditionInput.load(
                id,
                editionsDirectory: URL(fileURLWithPath: editionsDir, isDirectory: true),
                lock: try global.readLock(),
                cache: global.cache
            )
        } : nil
        try PackageValidator.validate(at: URL(fileURLWithPath: packagePath), source: source) { check, detail in
            print("pass  \(check.rawValue)\(detail.isEmpty ? "" : ": \(detail)")")
        }
    }
}
