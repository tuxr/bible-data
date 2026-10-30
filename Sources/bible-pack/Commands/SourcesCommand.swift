import ArgumentParser
import BibleFormat
import Foundation

struct SourcesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sources",
        abstract: "Lock, verify, and fetch the sources that packages are built from.",
        discussion: """
        A source is a publisher zip (format usfm or usfx), pinned by its own SHA-256, or a file set (format files): \
        plain files at one GitHub commit, pinned by a hash over their names and bytes and archived as <id>.zip, \
        a zip bible-pack builds deterministically. Add a zip with `sources lock --add` and a file set with `sources add-files`.
        """,
        subcommands: [Lock.self, AddFiles.self, Verify.self, Fetch.self, Show.self]
    )

    struct Lock: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Download sources and record their revision and hashes in the lock.",
            discussion: "A file set is rebuilt from its members into <sources-dir>/<id>.zip."
        )

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Source ids to relock. Defaults to every locked source.")
        var ids: [String] = []

        @Option(
            name: .customLong("add"),
            help: ArgumentHelp("A new publisher zip to lock; format is usfm or usfx.", valueName: "id:format:url"),
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

    struct AddFiles: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add-files",
            abstract: "Lock a new file set: plain files at one GitHub commit, archived as <sources-dir>/<id>.zip.",
            discussion: """
            Each member is stored under its URL's last path component, decoded, with spaces as underscores. \
            The revision is the commit's committer date. Upload <sources-dir>/<id>.zip to the source-archive \
            release under the name at the end of the lock entry's archive URL, unless --not-redistributable \
            says the license forbids it.

              bible-pack sources add-files strongs \\
                --repo https://github.com/openscriptures/strongs/tree/<sha> \\
                --license "Public domain" --attribution "Open Scriptures" \\
                <raw-url> <raw-url>
            """
        )

        @OptionGroup var global: GlobalOptions

        @Argument(help: "The new source's id: lowercase letters and digits.")
        var id: String

        @Option(help: ArgumentHelp("The commit every file comes from: https://github.com/<owner>/<repo>/tree/<sha>.", valueName: "tree-url"))
        var repo: String

        @Option(help: "The license the files are under, as a package credits it.")
        var license: String

        @Option(help: "The attribution a package built from the files must show.")
        var attribution: String

        @Flag(help: "The files' license asks that they not be redistributed: lock no archive, and fetch rebuilds from the files.")
        var notRedistributable = false

        @Argument(help: ArgumentHelp("The files at that commit: https://raw.githubusercontent.com/<owner>/<repo>/<sha>/<path>.", valueName: "raw-url"))
        var urls: [String]

        func run() async throws {
            let addition = try SourceRequest.parseFiles(
                id: id, repo: repo, urls: urls, license: license, attribution: attribution, redistributable: !notRedistributable
            )
            let lock = try global.readLock()
            let results = try await lock.relock(lock.requests(ids: [], additions: [addition]), download: HTTP.download)
            for result in results {
                try global.cache.store(result.zipBytes, as: result.source.file)
            }
            try LockFile.write(lock.applying(results), to: global.lockURL)
            printLines(results.map { ($0.id, "\($0.line)  \($0.source.archive?.lastPathComponent ?? "not redistributable")") })
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
            let requests = try lock.locked(ids: ids).map { SourceRequest(id: $0.id, spec: try $0.source.spec()) }
            let results = try await lock.relock(requests, download: HTTP.download)
            printLines(results.map { ($0.id, $0.line) })
            if results.contains(where: { $0.change != .unchanged }) { throw ExitCode.failure }
        }
    }

    struct Fetch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Ensure each locked zip is in the sources directory with its locked sha256.",
            discussion: "Tries the archive first, then the publisher's zip, or for a file set its members rebuilt into the zip."
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
                print("No sources locked in \(global.lock). Add one with `bible-pack sources lock --add <id>:<format>:<url>` or `bible-pack sources add-files`.")
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
        try checkID(id)
        guard let format = SourceFormat(rawValue: formatName) else {
            let formats = SourceFormat.allCases.map(\.rawValue).joined(separator: ", ")
            throw ValidationError("format \(formatName) is not one of \(formats)")
        }
        guard let url = URL(string: urlString), url.scheme == "https", LockedSource.isValidFileName(url.lastPathComponent) else {
            throw ValidationError("source url \(urlString) must be an https URL ending in a plain .zip file name")
        }
        return SourceRequest(id: id, spec: .zip(format, url))
    }

    static func parseFiles(
        id: String, repo: String, urls: [String], license: String, attribution: String, redistributable: Bool = true
    ) throws -> SourceRequest {
        try checkID(id)
        guard let repoURL = URL(string: repo), let commit = GitHubCommit(treeURL: repoURL) else {
            throw ValidationError("--repo \(repo) must be https://github.com/<owner>/<repo>/tree/<40-hex commit sha>")
        }
        guard !urls.isEmpty else { throw ValidationError("a file set needs at least one file URL") }
        guard !license.isEmpty, !attribution.isEmpty else { throw ValidationError("--license and --attribution must not be empty") }
        var members: [FileSetSpec.Member] = []
        for urlString in urls {
            guard let url = URL(string: urlString), commit.pins(url) else {
                throw ValidationError("\(urlString) is not https://raw.githubusercontent.com/\(commit.owner)/\(commit.repo)/\(commit.sha)/<path>")
            }
            guard let name = LockedFile.name(for: url) else {
                throw ValidationError("\(urlString) does not end in a file name of letters, digits, spaces, '.', '_', or '-'")
            }
            if members.contains(where: { $0.name == name }) { throw ValidationError("two files are both named \(name)") }
            members.append(FileSetSpec.Member(name: name, url: url))
        }
        return SourceRequest(id: id, spec: .files(FileSetSpec(
            commit: commit, members: members, license: license, attribution: attribution, redistributable: redistributable
        )))
    }

    private static func checkID(_ id: String) throws {
        guard !id.isEmpty, id.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) }) else {
            throw ValidationError("source id \(id) must be lowercase letters and digits")
        }
    }
}

func table(_ lock: SourcesLock) -> String {
    let header = ["id", "format", "revision", "bytes", "sha256", "archive"]
    let rows = lock.sources.keys.sorted().map { id in
        let source = lock.sources[id]!
        return [id, source.formatName, source.revision, String(source.bytes), String(source.sha256.prefix(8)),
                source.archive?.absoluteString ?? "none: not redistributable, rebuilt from its files"]
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
