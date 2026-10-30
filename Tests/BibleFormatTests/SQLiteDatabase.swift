import Foundation
import SQLite3

final class SQLiteDatabase {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private var handle: OpaquePointer?

    init() throws {
        guard sqlite3_open(":memory:", &handle) == SQLITE_OK else { throw Failure(description: "open failed") }
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            defer { sqlite3_free(message) }
            throw Failure(description: message.map { String(cString: $0) } ?? "exec failed")
        }
    }

    func rows(_ sql: String, _ bindings: [String] = []) throws -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure(description: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }
        var result: [[String?]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                result.append((0..<sqlite3_column_count(statement)).map { column in
                    sqlite3_column_text(statement, column).map { String(cString: $0) }
                })
            case SQLITE_DONE:
                return result
            default:
                throw Failure(description: String(cString: sqlite3_errmsg(handle)))
            }
        }
    }
}
