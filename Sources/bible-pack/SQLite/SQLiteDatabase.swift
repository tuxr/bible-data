import Foundation
import SQLite3

enum SQLiteValue: Hashable, Sendable, Comparable, CustomStringConvertible {
    case null
    case integer(Int64)
    case text(String)

    static func integer(_ value: Int) -> SQLiteValue { .integer(Int64(value)) }

    static func optional(_ value: Int?) -> SQLiteValue { value.map { .integer($0) } ?? .null }

    var description: String {
        switch self {
        case .null: "NULL"
        case .integer(let value): String(value)
        case .text(let value): "'\(value)'"
        }
    }

    static func < (lhs: SQLiteValue, rhs: SQLiteValue) -> Bool {
        switch (lhs, rhs) {
        case let (.integer(left), .integer(right)): left < right
        case let (.text(left), .text(right)): left.utf8.lexicographicallyPrecedes(right.utf8)
        default: lhs.rank < rhs.rank
        }
    }

    private var rank: Int {
        switch self {
        case .null: 0
        case .integer: 1
        case .text: 2
        }
    }
}

struct SQLiteError: Error, CustomStringConvertible {
    let description: String
}

final class SQLiteDatabase {
    enum Mode {
        case readOnly
        case readWrite
        case create

        var flags: Int32 {
            switch self {
            case .readOnly: SQLITE_OPEN_READONLY
            case .readWrite: SQLITE_OPEN_READWRITE
            case .create: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
            }
        }
    }

    private let handle: OpaquePointer

    init(path: String, mode: Mode) throws {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(path, &handle, mode.flags, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? String(cString: sqlite3_errstr(status))
            sqlite3_close_v2(handle)
            throw SQLiteError(description: "cannot open \(path): \(message)")
        }
        self.handle = handle
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            defer { sqlite3_free(message) }
            throw SQLiteError(description: message.map { String(cString: $0) } ?? lastError)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteError(description: "\(lastError) in \(sql)")
        }
        return Statement(statement, database: self)
    }

    func run(_ sql: String, _ values: [SQLiteValue] = []) throws {
        let statement = try prepare(sql)
        try statement.bind(values)
        while try statement.step() {}
    }

    func rows(_ sql: String, _ values: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
        let statement = try prepare(sql)
        try statement.bind(values)
        var rows: [[SQLiteValue]] = []
        while try statement.step() {
            rows.append(statement.row())
        }
        return rows
    }

    func pragma(_ name: String) throws -> [[SQLiteValue]] {
        try rows("PRAGMA \(name)")
    }

    func pragma(_ name: String, _ value: String) throws {
        try exec("PRAGMA \(name) = \(value)")
    }

    func transaction<Result>(_ body: () throws -> Result) throws -> Result {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    fileprivate var lastError: String { String(cString: sqlite3_errmsg(handle)) }
}

final class Statement {
    private let statement: OpaquePointer
    private let database: SQLiteDatabase

    fileprivate init(_ statement: OpaquePointer, database: SQLiteDatabase) {
        self.statement = statement
        self.database = database
    }

    deinit {
        sqlite3_finalize(statement)
    }

    /// Resets the statement, so one prepared insert serves every row.
    func bind(_ values: [SQLiteValue]) throws {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status = switch value {
            case .null: sqlite3_bind_null(statement, index)
            case .integer(let integer): sqlite3_bind_int64(statement, index, integer)
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, Self.transient)
            }
            guard status == SQLITE_OK else { throw SQLiteError(description: database.lastError) }
        }
    }

    /// True when a row is ready to read, false when the statement is done.
    func step() throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError(description: database.lastError)
        }
    }

    func row() -> [SQLiteValue] {
        (0..<sqlite3_column_count(statement)).map { column in
            switch sqlite3_column_type(statement, column) {
            case SQLITE_NULL: .null
            case SQLITE_INTEGER: .integer(sqlite3_column_int64(statement, column))
            default: .text(String(cString: sqlite3_column_text(statement, column)))
            }
        }
    }

    private static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }
}
