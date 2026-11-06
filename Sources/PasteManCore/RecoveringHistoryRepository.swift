import Foundation

/// 数据库打开与目录整理始终在后台执行；失败只影响历史模块，可以显式重试。
public actor RecoveringHistoryRepository: HistoryRepository {
    private let directory: URL
    private var opening: Task<HistoryStore, Error>
    public init(directory: URL) throws {
        guard directory.isFileURL else { throw StoreError.database("Invalid history directory.") }
        self.directory = directory
        opening = Self.open(directory)
    }
    private static func open(_ directory: URL) -> Task<HistoryStore, Error> {
        Task.detached(priority: .userInitiated) { try HistoryStore(directory: directory) }
    }
    public func retry() async throws {
        if case .failure = await opening.result { opening = Self.open(directory) }
        _ = try await opening.value
    }
    public func list(search: String, filter: HistoryFilter, source: String?) async throws -> [HistoryEntry] {
        try await opening.value.list(search: search, filter: filter, source: source)
    }
    public func page(search: String, filter: HistoryFilter, source: String?, after: HistoryCursor?, limit: Int) async throws -> HistoryPage {
        try await opening.value.page(search: search, filter: filter, source: source, after: after, limit: limit)
    }
    public func sources() async throws -> [SourceApplication] { try await opening.value.sources() }
    public func save(_ content: PreparedContent, sourceBundleID: String, sourceName: String, policy: RetentionPolicy, now: Date) async throws {
        try await opening.value.save(content, sourceBundleID: sourceBundleID, sourceName: sourceName, policy: policy, now: now)
    }
    public func setFavorite(_ id: UUID, value: Bool) async throws { try await opening.value.setFavorite(id, value: value) }
    public func delete(_ id: UUID) async throws { try await opening.value.delete(id) }
    public func clear(includingFavorites: Bool) async throws { try await opening.value.clear(includingFavorites: includingFavorites) }
    public func prune(policy: RetentionPolicy, now: Date) async throws { try await opening.value.prune(policy: policy, now: now) }
    public func pruneIfNeeded(policy: RetentionPolicy, now: Date) async throws -> Bool {
        try await opening.value.pruneIfNeeded(policy: policy, now: now)
    }
    public func nextCleanup(policy: RetentionPolicy, now: Date) async throws -> Date {
        try await opening.value.nextCleanup(policy: policy, now: now)
    }
    public func content(for entry: HistoryEntry) async throws -> PreparedContent { try await opening.value.content(for: entry) }
    public func imageData(for id: UUID, thumbnail: Bool) async throws -> Data { try await opening.value.imageData(for: id, thumbnail: thumbnail) }
}
