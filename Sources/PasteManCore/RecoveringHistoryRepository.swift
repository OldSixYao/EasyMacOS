import Foundation

/// 数据库打开与目录整理始终在后台执行；失败只影响历史模块，可以显式重试。
public actor RecoveringHistoryRepository: HistoryRepository {
    private let directory: URL
    private var opening: Task<HistoryStore, Error>?
    private var openingRevision = 0
    public init(directory: URL) throws {
        guard directory.isFileURL else { throw StoreError.database("Invalid history directory.") }
        self.directory = directory
    }
    private static func open(_ directory: URL) -> Task<HistoryStore, Error> {
        Task.detached(priority: .userInitiated) { try HistoryStore(directory: directory) }
    }
    private func store() async throws -> HistoryStore {
        try Task.checkCancellation()
        // 模块关闭时不打开数据库或整理图片目录；并发首次访问共用同一次打开。
        if opening == nil {
            openingRevision += 1
            opening = Self.open(directory)
        }
        let store = try await opening!.value
        try Task.checkCancellation()
        return store
    }
    public func retry() async throws {
        let revision = openingRevision
        if let opening, case .failure = await opening.result, revision == openingRevision {
            self.opening = nil
        }
        _ = try await store()
    }
    public func list(search: String, filter: HistoryFilter, source: String?) async throws -> [HistoryEntry] {
        try await store().list(search: search, filter: filter, source: source)
    }
    public func page(search: String, filter: HistoryFilter, source: String?, after: HistoryCursor?, limit: Int) async throws -> HistoryPage {
        try await store().page(search: search, filter: filter, source: source, after: after, limit: limit)
    }
    public func sources() async throws -> [SourceApplication] { try await store().sources() }
    public func save(_ content: PreparedContent, sourceBundleID: String, sourceName: String, policy: RetentionPolicy, now: Date) async throws {
        try await store().save(content, sourceBundleID: sourceBundleID, sourceName: sourceName, policy: policy, now: now)
    }
    public func setFavorite(_ id: UUID, value: Bool) async throws { try await store().setFavorite(id, value: value) }
    public func delete(_ id: UUID) async throws { try await store().delete(id) }
    public func clear(includingFavorites: Bool) async throws { try await store().clear(includingFavorites: includingFavorites) }
    public func prune(policy: RetentionPolicy, now: Date) async throws { try await store().prune(policy: policy, now: now) }
    public func pruneIfNeeded(policy: RetentionPolicy, now: Date) async throws -> Bool {
        try await store().pruneIfNeeded(policy: policy, now: now)
    }
    public func nextCleanup(policy: RetentionPolicy, now: Date) async throws -> Date {
        try await store().nextCleanup(policy: policy, now: now)
    }
    public func content(for entry: HistoryEntry) async throws -> PreparedContent { try await store().content(for: entry) }
    public func imageData(for id: UUID, thumbnail: Bool) async throws -> Data { try await store().imageData(for: id, thumbnail: thumbnail) }
}
