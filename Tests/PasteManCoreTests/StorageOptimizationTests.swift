import Foundation
import Testing

@testable import PasteManCore

@Suite("存储优化回归") struct StorageOptimizationTests {
    @Test func legacyHistoryMigratesInPlaceAndKeepsTextImagesAndFavorites() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try HistoryStore(directory: directory)
        try await original.save(.text("升级前的文字与收藏"), sourceBundleID: "legacy", sourceName: "旧版来源", policy: .init())
        try await original.save(.image(png: Data([1, 2, 3]), thumbnail: Data([4])), sourceBundleID: "legacy", sourceName: "旧版来源", policy: .init())
        let entries = try await original.list()
        let favorite = try #require(entries.first(where: { $0.kind == .text }))
        let image = try #require(entries.first(where: { $0.kind == .image }))
        try await original.setFavorite(favorite.id, value: true)
        let before = try await original.list()
        let database = try Database(path: directory.appendingPathComponent("history.sqlite").path)
        try database.execute("DROP TRIGGER history_queue_image_deletion")
        try database.execute("DROP TABLE history_image_deletions")
        try database.execute("PRAGMA user_version = 1")
        let migrated = try HistoryStore(directory: directory)
        #expect(try await migrated.list() == before)
        #expect(try await migrated.imageData(for: image.id, thumbnail: false) == Data([1, 2, 3]))
        #expect(try database.rows("PRAGMA user_version", map: { Database.text($0, 0) }) == ["2"])
        try await migrated.delete(image.id)
        #expect(try await migrated.list().map(\.id) == [favorite.id])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Images").path).isEmpty)
    }

    @Test func recoveringRepositoryUsesDatabaseCursorAndActualCleanupDeadline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try RecoveringHistoryRepository(directory: directory)
        let now = Date()
        let policy = RetentionPolicy(days: 1)
        for index in 0..<3 {
            try await repository.save(.text("游标回归 \(index)"), sourceBundleID: "test", sourceName: "合成应用",
                policy: policy, now: now.addingTimeInterval(-86400 + 120 + Double(index)))
        }
        let first = try await repository.page(search: "", filter: .all, source: nil, after: nil, limit: 1)
        let cursor = try #require(first.next)
        #expect(cursor.rowID > 0)
        try await repository.delete(try #require(first.entries.first).id)
        let second = try await repository.page(search: "", filter: .all, source: nil, after: cursor, limit: 1)
        #expect(second.entries.first?.preview == "游标回归 1")
        let cleanup = try await repository.nextCleanup(policy: policy, now: now)
        #expect(abs(cleanup.timeIntervalSince(now) - 121) < 0.01)
    }

    @Test(arguments: ["delete", "clear", "prune"])
    func failedImageRemovalIsRetriedWithoutReopeningHistory(_ operation: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let images = directory.appendingPathComponent("Images")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: images.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = try HistoryStore(directory: directory)
        let now = Date()
        try await store.save(.image(png: Data([1, 2]), thumbnail: Data([3])), sourceBundleID: "test", sourceName: "合成应用",
            policy: RetentionPolicy(), now: now)
        let entry = try #require(try await store.list().first)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: images.path)
        await #expect(throws: (any Error).self) {
            switch operation {
            case "delete": try await store.delete(entry.id)
            case "clear": try await store.clear(includingFavorites: true)
            default: try await store.prune(policy: RetentionPolicy(days: 1), now: now.addingTimeInterval(2 * 86400))
            }
        }
        #expect(try await store.list().isEmpty)
        let database = try Database(path: directory.appendingPathComponent("history.sqlite").path)
        #expect(try database.rows("SELECT id FROM history_image_deletions", map: { Database.text($0, 0) }) == [entry.id.uuidString])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: images.path)
        let cleaned = try await store.pruneIfNeeded(policy: RetentionPolicy(), now: now)
        #expect(cleaned)
        #expect(try FileManager.default.contentsOfDirectory(atPath: images.path).isEmpty)
        let unchanged = try await store.pruneIfNeeded(policy: RetentionPolicy(), now: now)
        #expect(!unchanged)
    }

    @Test func pendingImageCleanupSurvivesReopenAndExplicitRepositoryRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let images = directory.appendingPathComponent("Images")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: images.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = try HistoryStore(directory: directory)
        try await store.save(.image(png: Data([1]), thumbnail: Data([2])), sourceBundleID: "test", sourceName: "合成应用", policy: .init())
        let entry = try #require(try await store.list().first)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: images.path)
        await #expect(throws: StoreError.imageCleanupPending) { try await store.delete(entry.id) }
        let repository = try RecoveringHistoryRepository(directory: directory)
        #expect(try await repository.list(search: "", filter: .all, source: nil).isEmpty)
        await #expect(throws: StoreError.imageCleanupPending) { try await repository.retry() }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: images.path)
        try await repository.retry()
        #expect(try FileManager.default.contentsOfDirectory(atPath: images.path).isEmpty)
    }

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
