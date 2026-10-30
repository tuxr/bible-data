import ArgumentParser
import BibleFormat
import Foundation

struct SourcesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sources",
        abstract: "Lock, verify, and fetch the publisher zips that packages are built from.",
        subcommands: [Lock.self, Verify.self, Fetch.self, Show.self]
    )

    struct Lock: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Download sources and record their revision and hashes in the lock."
        )

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Source ids to relock. Defaults to every locked source.")
        var ids: [String] = []

        @Option(
            name: .customLong("add"),
            help: ArgumentHelp("A new source to lock.", valueName: "id:format:url"),
            transform: SourceRequest.parseAddition
        )
        var additions: [SourceRequest] = []

        func run() async throws {
            let lock = try global.readLock()
            let results = try await lock.relock(lock.requests(ids: ids, additions: additions), download: HTTP.download)
            let cache = global.cache
            for result in results {
                try cache.store(result.zipBytes, as: result.source.file)
            }
            try LockFile.write(lock.applying(results), to: global.lockURL)
            printLines(results.map { ($0.id, $0.line) })
        }
    }

    struct Verify: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Re-download sources and compare them to the lock without writing. Exits 1 on any change."
        )

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Source ids to verify. Defaults to every locked source.")
        var ids: [String] = []

        func run() async throws {
            let lock = try global.readLock()
            let requests = try lock.locked(ids: ids).map { SourceRequest(id: $0.id, format: $0.source.format, url: $0.source.url) }
            let results = try await lock.relock(requests, download: HTTP.download)
            printLines(results.map { ($0.id, $0.line) })
            if results.contains(where: { $0.change != .unchanged }) { throw ExitCode.failure }
        }
    }

    struct Fetch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Ensure each locked zip is in the sources directory with its locked sha256."
        )

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Source ids to fetch. Defaults to every locked source.")
        var ids: [String] = []

        func run() async throws {
            let cache = global.cache
            var lines: [(String, String)] = []
            var failed = false
            for (id, source) in try global.readLock().locked(ids: ids) {
                let outcome = try await cache.fetch(source, download: HTTP.download)
                if case .failed = outcome { failed = true }
                lines.append((id, "\(source.revision)  \(source.sha256.prefix(8))  \(outcome.status)"))
            }
            printLines(lines)
            if failed { throw ExitCode.failure }
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the lock as a table.")

        @OptionGroup var global: GlobalOptions

        func run() throws {
            let lock = try global.readLock()
            if lock.sources.isEmpty {
                print("No sources locked in \(global.lock). Add one with `bible-pack sources lock --add <id>:<format>:<url>`.")
                return
            }
            print(table(lock))
        }
    }
}

extension SourceRequest {
    static func parseAddition(_ argument: String) throws -> SourceRequest {
        let parts = argument.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { throw ValidationError("--add takes <id>:<format>:<url>, got \(argument)") }
        let (id, formatName, urlString) = (parts[0], parts[1], parts[2])
        guard !id.isEmpty, id.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) }) else {
            throw ValidationError("source id \(id) must be lowercase letters and digits")
        }
        guard let format = SourceFormat(rawValue: formatName) else {
            let formats = SourceFormat.allCases.map(\.rawValue).joined(separator: ", ")
            throw ValidationError("format \(formatName) is not one of \(formats)")
        }
        guard let url = URL(string: urlString), url.scheme == "https", LockedSource.isValidFileName(url.lastPathComponent) else {
            throw ValidationError("source url \(urlString) must be an https URL ending in a plain .zip file name")
        }
        return SourceRequest(id: id, format: format, url: url)
    }
}

func table(_ lock: SourcesLock) -> String {
    let header = ["id", "format", "revision", "bytes", "sha256", "archive"]
    let rows = lock.sources.keys.sorted().map { id in
        let source = lock.sources[id]!
        return [id, source.format.rawValue, source.revision, String(source.bytes), String(source.sha256.prefix(8)), source.archive.absoluteString]
    }
    let all = [header] + rows
    let widths = header.indices.map { column in all.map { $0[column].count }.max()! }
    return all.map { row in
        row.indices.map { column in
            column == row.count - 1 ? row[column] : row[column].padding(toLength: widths[column], withPad: " ", startingAt: 0)
        }.joined(separator: "  ")
    }.joined(separator: "\n")
}

private func printLines(_ lines: [(id: String, text: String)]) {
    let width = lines.map(\.id.count).max() ?? 0
    for line in lines {
        print(line.id.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + line.text)
    }
}
