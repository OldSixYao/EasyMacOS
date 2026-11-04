import Foundation
import Testing

@testable import PasteManCore

@Suite("Cancelable database reads") struct QueryCancellationTests {
    @Test func cancellationInterruptsSQLiteBeforeItsFirstResultAndConnectionRemainsUsable() async throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let request = Task.detached {
            let db = try Database(path: ":memory:")
            started.signal()
            waitSynchronously(release)
            do {
                // Enough SQLite VM work to require cancellation during sqlite3_step,
                // rather than relying on a check between returned rows.
                _ = try db.rows(
                    "WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM n WHERE x<100000000) SELECT sum(x) FROM n",
                    cancellable: true
                ) { _ in 0 }
                return false
            } catch is CancellationError {
                try db.execute("CREATE TABLE recovered (value INTEGER)")
                return true
            }
        }
        let began = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: started.wait(timeout: .now() + 5) == .success)
            }
        }
        #expect(began)
        release.signal()
        try await Task.sleep(for: .milliseconds(20))
        request.cancel()
        #expect(try await request.value)
    }

    @Test func alreadyCanceledListDoesNotReturnStaleRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(directory: directory)
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.list(search: "obsolete")
        }
        await #expect(throws: CancellationError.self) { _ = try await request.value }
        #expect(try await store.list().isEmpty)
    }
}

private func waitSynchronously(_ semaphore: DispatchSemaphore) {
    _ = semaphore.wait(timeout: .now() + 5)
}
