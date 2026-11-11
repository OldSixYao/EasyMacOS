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

    @Test(arguments: [false, true], [false, true])
    func canceledSaveWaitingForDatabaseLockDoesNotInsertOrRefreshContent(_ image: Bool, _ existing: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CanceledSave-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(directory: directory)
        let content: PreparedContent = image ? .image(png: Data([1, 2]), thumbnail: Data([3])) : .text("取消的保存")
        if existing {
            try await store.save(content, sourceBundleID: "original", sourceName: "原始来源", policy: RetentionPolicy())
        }
        let before = try await store.list()
        let blocker = try Database(path: directory.appendingPathComponent("history.sqlite").path)
        try blocker.execute("BEGIN IMMEDIATE")
        let started = DispatchSemaphore(value: 0)
        let request = Task.detached {
            started.signal()
            try await store.save(content, sourceBundleID: "late", sourceName: "取消后的来源", policy: RetentionPolicy())
        }
        let began = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: started.wait(timeout: .now() + 5) == .success) }
        }
        #expect(began)
        // 覆盖同步 SQLite 锁等待中的取消，而非只检查进入 actor 之前已取消。
        try await Task.sleep(for: .milliseconds(150))
        request.cancel()
        try blocker.execute("COMMIT")
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(try await store.list() == before)
        if !existing {
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Images").path).isEmpty)
        }
    }
}

private func waitSynchronously(_ semaphore: DispatchSemaphore) {
    _ = semaphore.wait(timeout: .now() + 5)
}
