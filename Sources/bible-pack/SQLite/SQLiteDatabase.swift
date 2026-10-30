import Foundation
import SQLite3

enum SQLiteValue: Hashable, Sendable, Comparable, CustomStringConvertible {
    case null
    case integer(Int64)
    case text(String)
    case blob(Data)

    static func integer(_ value: Int) -> SQLiteValue { .integer(Int64(value)) }

    static func optional(_ value: Int?) -> SQLiteValue { value.map { .integer($0) } ?? .null }

    var description: String {
        switch self {
        case .null: "NULL"
        case .integer(let value): String(value)
        case .text(let value): "'\(value)'"
        case .blob(let value): "<\(value.count) bytes>"
        }
    }

    static func < (lhs: SQLiteValue, rhs: SQLiteValue) -> Bool {
        switch (lhs, rhs) {
        case let (.integer(left), .integer(right)): left < right
        case let (.text(left), .text(right)): left.utf8.lexicographicallyPrecedes(right.utf8)
        case let (.blob(left), .blob(right)): left.lexicographicallyPrecedes(right)
        default: lhs.rank < rhs.rank
        }
    }

    private var rank: Int {
        switch self {
        case .null: 0
        case .integer: 1
        case .text: 2
        case .blob: 3
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

    /// A writable in-memory database holding a copy of `bytes`, for checks that SQLite runs as writes, such as
    /// FTS5's `integrity-check`, on a file that must stay untouched.
    static func inMemoryCopy(of bytes: Data) throws -> SQLiteDatabase {
        let database = try SQLiteDatabase(path: ":memory:", mode: .create)
        guard let buffer = sqlite3_malloc64(UInt64(bytes.count)) else { throw SQLiteError(description: "out of memory") }
        bytes.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: bytes.count)
        let flags = UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_RESIZEABLE)
        let size = sqlite3_int64(bytes.count)
        guard sqlite3_deserialize(database.handle, "main", buffer.assumingMemoryBound(to: UInt8.self), size, size, flags) == SQLITE_OK else {
            throw SQLiteError(description: "cannot load a copy: \(database.lastError)")
        }
        return database
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

    /// Inserts every row with one prepared statement.
    func insert(into table: String, columns: [String], rows: some Sequence<[SQLiteValue]>) throws {
        let placeholders = columns.map { _ in "?" }.joined(separator: ", ")
        let statement = try prepare("INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(placeholders))")
        for row in rows {
            do {
                try statement.bind(row)
                while try statement.step() {}
            } catch {
                throw SQLiteError(description: "\(table): cannot insert (\(row.map(\.description).joined(separator: ", "))): \(error)")
            }
        }
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
            // An empty blob has no base address, and binding a nil pointer would store NULL.
            case .blob(let data) where data.isEmpty: sqlite3_bind_zeroblob(statement, index, 0)
            case .blob(let data): data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient) }
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
            case SQLITE_BLOB:
                .blob(sqlite3_column_blob(statement, column).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(statement, column))) } ?? Data())
            default: .text(String(cString: sqlite3_column_text(statement, column)))
            }
        }
    }

    private static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }
}
