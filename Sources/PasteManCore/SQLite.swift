import CSQLite
import Foundation

/// Used exclusively inside HistoryStore's actor. Statements never escape a synchronous operation.
final class Database {
    private var handle: OpaquePointer?
    init(path: String) throws {
        guard
            sqlite3_open_v2(path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
                == SQLITE_OK
        else {
            let error = StoreError.database("Unable to open local history.")
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw error
        }
        sqlite3_busy_timeout(handle, 3000)
    }
    deinit { sqlite3_close(handle) }
    func execute(_ sql: String, _ values: [Value] = []) throws {
        try statement(sql, values) { statement in
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return }
                guard result == SQLITE_ROW else { throw failure() }
            }
        }
    }
    func rows<T>(
        _ sql: String, _ values: [Value] = [], cancellable: Bool = false,
        map: (OpaquePointer) throws -> T
    ) throws -> [T] {
        if cancellable {
            try Task.checkCancellation()
            // sqlite3_step runs synchronously in the caller's task. Check inside the VM
            // too: a scan/sort may do substantial work before returning its first row.
            sqlite3_progress_handler(
                handle, 1000,
                { _ in
                    withUnsafeCurrentTask { $0?.isCancelled == true ? 1 : 0 }
                }, nil)
        }
        defer { if cancellable { sqlite3_progress_handler(handle, 0, nil, nil) } }
        return try statement(sql, values) { statement in
            var rows: [T] = []
            while true {
                if cancellable { try Task.checkCancellation() }
                let result = sqlite3_step(statement)
                if cancellable { try Task.checkCancellation() }
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw failure() }
                rows.append(try map(statement))
            }
            return rows
        }
    }
    func transaction<T>(_ action: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try action()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
    enum Value {
        case text(String)
        case int(Int)
        case real(Double)
        case null
    }
    private func failure() -> StoreError {
        // SQLite error text does not include bound clipboard payloads.
        .database(String(cString: sqlite3_errmsg(handle)))
    }
    private func statement<T>(_ sql: String, _ values: [Value], body: (OpaquePointer) throws -> T) throws -> T {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &pointer, nil) == SQLITE_OK, let pointer else { throw failure() }
        defer { sqlite3_finalize(pointer) }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch value {
            case .text(let text):
                result = text.withCString {
                    sqlite3_bind_text(
                        pointer, position, $0, Int32(text.utf8.count),
                        unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            case .int(let number): result = sqlite3_bind_int64(pointer, position, Int64(number))
            case .real(let number): result = sqlite3_bind_double(pointer, position, number)
            case .null: result = sqlite3_bind_null(pointer, position)
            }
            guard result == SQLITE_OK else { throw failure() }
        }
        return try body(pointer)
    }
    static func text(_ row: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(row, column) else { return "" }
        return String(
            decoding: UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(row, column))), as: UTF8.self)
    }
}
