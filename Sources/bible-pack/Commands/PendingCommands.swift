import ArgumentParser

struct NotYetImplemented: Error, CustomStringConvertible {
    var command: String
    var step: Int

    var description: String { "bible-pack \(command) is not implemented yet; Phase 0 step \(step) builds it." }
}

struct Manifest: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Write the manifest that lists every published package.")

    @Option(help: "Where the manifest is written.")
    var out = "manifest/manifest.json"

    func run() throws { throw NotYetImplemented(command: "manifest", step: 6) }
}
