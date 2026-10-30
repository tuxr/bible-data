import ArgumentParser
import BibleFormat
import Foundation

enum BiblePackVersion {
    static let current = "0.1.0"
}

@main
struct BiblePack: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bible-pack",
        abstract: "Builds the Bible app's canon package, and its scripture packages from locked publisher sources.",
        version: BiblePackVersion.current,
        subcommands: [SourcesCommand.self, CanonCommand.self, Build.self, Validate.self, Manifest.self]
    )
}

struct GlobalOptions: ParsableArguments {
    @Option(help: "The sources lock file.")
    var lock = "sources.lock.json"

    @Option(help: "Where downloaded source zips are kept.")
    var sourcesDir = ".sources"

    var lockURL: URL { URL(fileURLWithPath: lock) }
    var cache: SourceCache { SourceCache(directory: URL(fileURLWithPath: sourcesDir, isDirectory: true)) }

    func readLock() throws -> SourcesLock {
        try LockFile.read(lockURL) ?? SourcesLock()
    }
}
