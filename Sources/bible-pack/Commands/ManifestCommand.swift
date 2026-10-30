import ArgumentParser
import BibleFormat
import Foundation

struct ManifestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "manifest",
        abstract: "Write the manifest that lists every published package (manifest build), or check one (manifest validate).",
        subcommands: [Build.self, Validate.self]
    )

    struct Build: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List every package in a directory, from each file's own meta and bytes, in manifest.json.",
            discussion: """
            Reads every .bible, .words, .lexicon, and canon .sqlite file and the .xz beside it. With --merge, every \
            entry of that manifest whose file is not in the directory stays listed, so old versions stay published. \
            The output is byte-identical for the same files and --generated-at.
            """
        )

        @Option(help: "The directory of built packages and their .xz downloads.")
        var dist = "dist"

        @Option(help: ArgumentHelp("Where the manifest is written. Defaults to manifest.json in --dist.", valueName: "path"))
        var out: String?

        @Option(help: "The URL every entry's url is relative to.")
        var baseURL = Manifest.defaultBaseURL

        @Option(help: ArgumentHelp("Pin generated_at, so two runs are byte-identical. Defaults to now.", valueName: "iso8601"))
        var generatedAt: String?

        @Option(help: ArgumentHelp("A published manifest, a path or an https URL, whose other entries stay listed. A 404 merges nothing.", valueName: "manifest"))
        var merge: String?

        @Option(help: "The min_app_version policy.")
        var policy = "manifest/policy.json"

        func validate() throws {
            if let generatedAt, CanonPackage.parseBuiltAt(generatedAt) == nil {
                throw ValidationError("--generated-at takes an ISO 8601 UTC time such as 2026-10-30T12:00:00Z, got \(generatedAt)")
            }
        }

        func run() async throws {
            let policy = try ManifestPolicy(jsonData: try Data(contentsOf: URL(fileURLWithPath: policy)))
            let dist = URL(fileURLWithPath: dist, isDirectory: true)
            let files = try ManifestBuilder.packageFiles(in: dist)
            guard !files.isEmpty else { throw PackageError(description: "\(dist.path) holds no packages") }
            var packages = try files.map { try ManifestBuilder.entry(for: $0, policy: policy) }
            for entry in packages { print("listed  \(entry.file)  \(entry.size) bytes, \(entry.url) \(entry.compressedSize) bytes") }

            if let merge {
                if let published = try await ManifestBuilder.load(merge) {
                    let merged = try ManifestBuilder.merge(packages, into: published, baseURL: baseURL)
                    packages = merged.packages
                    for entry in merged.kept { print("kept  \(entry.file) from \(merge)") }
                } else {
                    print("merged nothing: \(merge) answered 404")
                }
            }

            let manifest = Manifest(
                generatedAt: generatedAt.flatMap(CanonPackage.parseBuiltAt).map(CanonPackage.formatBuiltAt) ?? CanonPackage.formatBuiltAt(Date()),
                baseURL: baseURL, packages: packages
            )
            try manifest.check { _, _ in }
            let destination = out.map { URL(fileURLWithPath: $0) } ?? dist.appending(path: "manifest.json")
            let data = manifest.jsonData()
            try data.write(to: destination, options: .atomic)
            print("\(destination.path)  \(manifest.packages.count) entries  sha256 \(sha256Hex(data))")
        }
    }

    struct Validate: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Check a manifest, and with --dist the files it lists there. Exits 1 on the first failure.",
            discussion: """
            The manifest's checks: fields each kind requires, ids, file names and relative urls, released dates, \
            sizes, hashes, attribution, min_app_version, one entry per id and version, the order, and a supported \
            format for the newest version of each id. With --dist, every package there is listed, and every entry \
            whose files are there matches their sizes and hashes and decompresses to its sha256.
            """
        )

        @Argument(help: "The manifest.json to check.")
        var path: String

        @Option(help: "A directory of the packages and .xz downloads the manifest lists.")
        var dist: String?

        func run() throws {
            let manifest = try Manifest.decode(try Data(contentsOf: URL(fileURLWithPath: path)))
            print("pass  \(ManifestCheck.schema.rawValue): \(manifest.packages.count) entries")
            try manifest.check { print("pass  \($0.rawValue): \($1)") }
            if let dist {
                try ManifestBuilder.verify(manifest, dist: URL(fileURLWithPath: dist, isDirectory: true)) { print("pass  \($0.rawValue): \($1)") }
            }
        }
    }
}
