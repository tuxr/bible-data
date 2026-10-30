import BibleFormat
import Foundation

enum LockFile {
    static func read(_ url: URL) throws -> SourcesLock? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try SourcesLock(jsonData: Data(contentsOf: url))
    }

    static func write(_ lock: SourcesLock, to url: URL) throws {
        try lock.jsonData().write(to: url, options: .atomic)
    }
}
