import Foundation
import Testing

@testable import PasteManCore

@Suite("存储优化回归") struct StorageOptimizationTests {
    @Test func unusedRepositoryDoesNotCreateStorageAndConcurrentFirstAccessSharesOpen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try RecoveringHistoryRepository(directory: directory)
        try await Task.sleep(for: .milliseconds(30))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    try await repository.save(.text("并发首次保存 \(index)"), sourceBundleID: "test", sourceName: "合成应用",
                        policy: RetentionPolicy(), now: Date())
                }
            }
            try await group.waitForAll()
        }
        #expect(try await repository.list(search: "", filter: .all, source: nil).count == 8)
    }

    @Test func reopeningMigratesSortIndexesWithoutTemporaryTieSortAndPreservesTotals() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(directory: directory)
        try await store.save(.text("迁移后仍然存在"), sourceBundleID: "test", sourceName: "合成应用", policy: RetentionPolicy())
        let db = try Database(path: directory.appendingPathComponent("history.sqlite").path)
        try db.execute("DROP INDEX history_recency_cursor")
        try db.execute("DROP INDEX history_ordinary_cursor")
        try db.execute("CREATE INDEX history_recency ON history(favorite DESC, copied_at DESC)")
        try db.execute("CREATE INDEX history_ordinary ON history(copied_at DESC) WHERE favorite=0")
        let reopened = try HistoryStore(directory: directory)
        #expect(try await reopened.page().entries.count == 1)
        let migratedDB = try Database(path: directory.appendingPathComponent("history.sqlite").path)
        let plan = try migratedDB.rows("EXPLAIN QUERY PLAN SELECT id FROM history ORDER BY favorite DESC, copied_at DESC, rowid DESC LIMIT 101") {
            Database.text($0, 3)
        }
        #expect(plan.contains { $0.contains("history_recency_cursor") })
        #expect(!plan.contains { $0.contains("TEMP B-TREE") })
        let totals = try migratedDB.rows("SELECT bytes, ordinary FROM history_totals") {
            (Database.text($0, 0), Database.text($0, 1))
        }
        #expect(totals.count == 1 && totals[0].1 == "1")
    }

    @Test func paginationPreservesTiesFavoritesFiltersAndDeletedCursor() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(directory: directory)
        let date = Date()
        let policy = RetentionPolicy(count: 1000)
        for index in 0..<213 {
            try await store.save(.text("相同时间 \(index) %_'"), sourceBundleID: index % 2 == 0 ? "a" : "b",
                sourceName: "合成应用", policy: policy, now: date)
        }
        let original = try await store.list()
        for entry in original.prefix(31) { try await store.setFavorite(entry.id, value: true) }
        for filter in [HistoryFilter.all, .favorites, .text] {
            let expected = try await store.list(search: "%_'", filter: filter, source: "a")
            var rows: [HistoryEntry] = []
            var cursor: HistoryCursor?
            repeat {
                let page = try await store.page(search: "%_'", filter: filter, source: "a", after: cursor, limit: 17)
                rows += page.entries
                cursor = page.next
            } while cursor != nil
            #expect(rows == expected)
            #expect(Set(rows.map(\.id)).count == rows.count)
        }
        let first = try await store.page(limit: 17)
        try await store.delete(try #require(first.entries.last).id)
        let next = try await store.page(after: first.next, limit: 17)
        #expect(next.entries.map(\.id) == Array(try await store.list().dropFirst(16).prefix(17)).map(\.id))
    }

    @Test func aggregatesSurviveReopenClearFavoriteChangesAndCapacityEviction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(directory: directory)
        let now = Date()
        let policy = RetentionPolicy(byteLimit: 10)
        try await store.save(.text("12345"), sourceBundleID: "a", sourceName: "应用", policy: policy, now: now)
        let favorite = try #require(try await store.list().first)
        try await store.setFavorite(favorite.id, value: true)
        for index in 0..<5 {
            try await store.save(.text("abcd\(index)"), sourceBundleID: "a", sourceName: "应用", policy: policy,
                now: now.addingTimeInterval(Double(index + 1)))
        }
        let reopened = try HistoryStore(directory: directory)
        #expect(try await reopened.list().count == 2)
        #expect(try await reopened.pruneIfNeeded(policy: policy, now: now) == false)
        try await reopened.clear(includingFavorites: false)
        #expect(try await reopened.list().map(\.id) == [favorite.id])
        try await reopened.setFavorite(favorite.id, value: false)
        #expect(try await reopened.pruneIfNeeded(policy: policy, now: now.addingTimeInterval(31 * 86400)))
        #expect(try await reopened.list().isEmpty)
    }

    @Test func failedBackgroundOpenCanRetryWithoutReplacingExistingData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1]).write(to: directory)
        let repository = try RecoveringHistoryRepository(directory: directory)
        await #expect(throws: (any Error).self) { _ = try await repository.list(search: "", filter: .all, source: nil) }
        try FileManager.default.removeItem(at: directory)
        try await repository.retry()
        try await repository.save(.text("恢复后保存"), sourceBundleID: "a", sourceName: "应用", policy: RetentionPolicy(), now: Date())
        #expect(try await repository.list(search: "", filter: .all, source: nil).first?.preview == "恢复后保存")
    }
}
