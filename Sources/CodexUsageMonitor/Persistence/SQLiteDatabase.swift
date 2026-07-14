import Foundation
import SQLite3

enum SQLiteValue: Sendable {
    case integer(Int64)
    case real(Double)
    case text(String)
    case null
}

struct SQLiteError: Error, LocalizedError {
    let code: Int32
    let message: String

    var errorDescription: String? {
        "SQLite \(code): \(message)"
    }
}

final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL, configure: Bool = true) throws {
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard result == SQLITE_OK else {
            let error = currentError(fallbackCode: result)
            sqlite3_close(handle)
            handle = nil
            throw error
        }

        if configure {
            do {
                try configureForRepository()
            } catch {
                sqlite3_close(handle)
                handle = nil
                throw error
            }
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String, _ values: [SQLiteValue] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                continue
            case SQLITE_DONE:
                return
            default:
                throw currentError()
            }
        }
    }

    func query(
        _ sql: String,
        _ values: [SQLiteValue] = [],
        row: (OpaquePointer) throws -> Void
    ) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                try row(statement)
            case SQLITE_DONE:
                return
            default:
                throw currentError()
            }
        }
    }

    func quickCheck() throws {
        var messages: [String] = []
        try query("PRAGMA quick_check") { statement in
            guard let value = sqlite3_column_text(statement, 0) else {
                messages.append("quick_check returned a null result")
                return
            }
            messages.append(String(cString: value))
        }

        guard messages == ["ok"] else {
            throw SQLiteError(
                code: SQLITE_CORRUPT,
                message: messages.isEmpty
                    ? "quick_check returned no result"
                    : messages.joined(separator: "; ")
            )
        }
    }

    func configureForRepository() throws {
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw currentError(fallbackCode: result)
        }
        return statement
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws {
        for (zeroIndex, value) in values.enumerated() {
            let index = Int32(zeroIndex + 1)
            let result: Int32 = switch value {
            case let .integer(value):
                sqlite3_bind_int64(statement, index, value)
            case let .real(value):
                sqlite3_bind_double(statement, index, value)
            case let .text(value):
                sqlite3_bind_text(statement, index, value, -1, transient)
            case .null:
                sqlite3_bind_null(statement, index)
            }

            guard result == SQLITE_OK else {
                throw currentError(fallbackCode: result)
            }
        }
    }

    private func currentError(fallbackCode: Int32 = SQLITE_ERROR) -> SQLiteError {
        guard let handle else {
            return SQLiteError(code: fallbackCode, message: "database is not open")
        }
        return SQLiteError(
            code: sqlite3_errcode(handle),
            message: String(cString: sqlite3_errmsg(handle))
        )
    }
}
