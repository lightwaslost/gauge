import Foundation
import SQLite3

enum SQLValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case null

    static func optional(_ value: Double?) -> SQLValue { value.map(SQLValue.double) ?? .null }
}

/// A read cursor over the current result row.
struct SQLRow {
    fileprivate let statement: OpaquePointer

    func isNull(_ index: Int32) -> Bool { sqlite3_column_type(statement, index) == SQLITE_NULL }
    func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
    func int(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
    func optionalDouble(_ index: Int32) -> Double? { isNull(index) ? nil : double(index) }
    func text(_ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }
}

/// Thin wrapper over the SQLite C API. Use from one thread.
final class Database {
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw DatabaseError(message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed")
        }
        execute("PRAGMA journal_mode = WAL")
        execute("PRAGMA synchronous = NORMAL")
    }

    deinit { sqlite3_close(handle) }

    @discardableResult
    func execute(_ sql: String, _ arguments: [SQLValue] = []) -> Bool {
        guard let statement = prepare(sql, arguments) else { return false }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        return result == SQLITE_DONE || result == SQLITE_ROW
    }

    func query<T>(_ sql: String, _ arguments: [SQLValue] = [], _ map: (SQLRow) -> T) -> [T] {
        guard let statement = prepare(sql, arguments) else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(map(SQLRow(statement: statement)))
        }
        return rows
    }

    func transaction(_ body: () -> Void) {
        execute("BEGIN")
        body()
        execute("COMMIT")
    }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }

    private func prepare(_ sql: String, _ arguments: [SQLValue]) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            print("SQLite prepare failed: \(String(cString: sqlite3_errmsg(handle))) — \(sql)")
            return nil
        }
        for (offset, argument) in arguments.enumerated() {
            let index = Int32(offset + 1)
            switch argument {
            case .int(let value): sqlite3_bind_int64(statement, index, value)
            case .double(let value): sqlite3_bind_double(statement, index, value)
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }
}

struct DatabaseError: Error {
    let message: String
}
