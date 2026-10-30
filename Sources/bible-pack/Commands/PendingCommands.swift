import ArgumentParser

struct NotYetImplemented: Error, CustomStringConvertible {
    var command: String
    var step: Int

    var description: String { "bible-pack \(command) is not implemented yet; Phase 0 step \(step) builds it." }
}

struct Build: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Build one edition's package from its locked sources.")

    @OptionGroup var global: GlobalOptions

    @Argument(help: "The edition to build, such as bsb.")
    var editionID: String

    @Option(help: "Directory the package is written to.")
    var out = "dist/"

    func run() throws { throw NotYetImplemented(command: "build", step: 4) }
}

struct Validate: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check a built package against the canon and its sources.")

    @Argument(help: "The package file to validate.")
    var packagePath: String

    func run() throws { throw NotYetImplemented(command: "validate", step: 4) }
}

struct Manifest: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Write the manifest that lists every published package.")

    @Option(help: "Where the manifest is written.")
    var out = "manifest/manifest.json"

    func run() throws { throw NotYetImplemented(command: "manifest", step: 6) }
}
