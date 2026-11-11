import AppKit
import PasteManCore
import Testing

@testable import PasteMan

@MainActor private final class LifecycleClipboard: ClipboardReading, ClipboardPermissionChecking {
    var changeCount = 0
    var types: Set<String> = []
    var allowsMonitoring = true
    func refreshClipboard() {}
    func capture(expectedChangeCount: Int) async -> ClipboardSnapshot? { nil }
}

/// 在真正提交前提供可控的等待点；解除等待后仍遵守生产仓库的取消约定。
private actor LifecycleRepository: HistoryRepository {
    let store: HistoryStore
    var pendingSaves: [CheckedContinuation<Void, Never>] = []
    var shouldSuspendSave = true
    var cleanupCalls = 0
    var failuresAtCleanup: Set<Int> = []
    var failNextDeadline = false
    var immediateDeadline = false
    var retries = 0

    init(store: HistoryStore) { self.store = store }
    func configureCleanup(failures: Set<Int> = [], deadlineFailure: Bool = false, immediate: Bool = false) {
        failuresAtCleanup = failures
        failNextDeadline = deadlineFailure
        immediateDeadline = immediate
    }
    func releaseSaves() {
        shouldSuspendSave = false
        let saves = pendingSaves
        pendingSaves = []
        for save in saves { save.resume() }
    }
    var waitingSaves: Int { pendingSaves.count }
    func retry() async throws { retries += 1 }
    func save(_ content: PreparedContent, sourceBundleID: String, sourceName: String, policy: RetentionPolicy, now: Date) async throws {
        if shouldSuspendSave { await withCheckedContinuation { pendingSaves.append($0) } }
        try Task.checkCancellation()
        try await store.save(content, sourceBundleID: sourceBundleID, sourceName: sourceName, policy: policy, now: now)
    }
    func pruneIfNeeded(policy: RetentionPolicy, now: Date) async throws -> Bool {
        cleanupCalls += 1
        if failuresAtCleanup.remove(cleanupCalls) != nil { throw StoreError.database("合成的暂时性存储故障") }
        return try await store.pruneIfNeeded(policy: policy, now: now)
    }
    func nextCleanup(policy: RetentionPolicy, now: Date) async throws -> Date {
        if failNextDeadline { failNextDeadline = false; throw StoreError.database("合成的调度查询故障") }
        if immediateDeadline { immediateDeadline = false; return now }
        return try await store.nextCleanup(policy: policy, now: now)
    }
    func list(search: String, filter: HistoryFilter, source: String?) async throws -> [HistoryEntry] {
        try await store.list(search: search, filter: filter, source: source)
    }
    func sources() async throws -> [SourceApplication] { try await store.sources() }
    func setFavorite(_ id: UUID, value: Bool) async throws { try await store.setFavorite(id, value: value) }
    func delete(_ id: UUID) async throws { try await store.delete(id) }
    func clear(includingFavorites: Bool) async throws { try await store.clear(includingFavorites: includingFavorites) }
    func prune(policy: RetentionPolicy, now: Date) async throws { try await store.prune(policy: policy, now: now) }
    func content(for entry: HistoryEntry) async throws -> PreparedContent { try await store.content(for: entry) }
    func imageData(for id: UUID, thumbnail: Bool) async throws -> Data { try await store.imageData(for: id, thumbnail: thumbnail) }
}

@MainActor private struct LifecycleFixture {
    let root: URL
    let suite = "ClipboardLifecycle." + UUID().uuidString
    let defaults: UserDefaults
    let settings: AppSettings
    let repository: LifecycleRepository
    let monitor: ClipboardMonitor

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardLifecycle-" + UUID().uuidString)
        defaults = try #require(UserDefaults(suiteName: suite))
        settings = AppSettings(defaults: defaults)
        settings.hasOnboarded = true
        repository = LifecycleRepository(store: try HistoryStore(directory: root))
        let board = LifecycleClipboard()
        monitor = ClipboardMonitor(clipboard: board, repository: repository, settings: settings, permissions: board)
    }
    func clean() {
        monitor.stop()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    func seedExpired() async throws {
        try await repository.store.save(.text("过期历史"), sourceBundleID: "test", sourceName: "合成应用",
            policy: RetentionPolicy(days: 365), now: Date().addingTimeInterval(-31 * 86400))
    }
    func image() throws -> ScreenshotImage {
        let context = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try ScreenshotRenderer.export(base: #require(context.makeImage()), pointSize: CGSize(width: 16, height: 16), annotations: [])
    }
}

@Suite("剪贴板保存取消与清理恢复", .serialized) @MainActor struct ClipboardLifecycleTests {
    private func wait(_ ready: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try await !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(try await ready())
    }

    @Test(arguments: [false, true], ["pause", "disable", "clear", "lock"])
    func invalidationCancelsScreenshotsAlreadyWaitingToSave(_ png: Bool, _ action: String) async throws {
        let f = try LifecycleFixture(); defer { f.clean() }
        let image = try f.image()
        let ticket = try #require(f.monitor.screenshotTicket(sourceID: "test"))
        let pending = Task {
            if png { try await f.monitor.recordScreenshot(image.png, sourceID: "test", sourceName: "合成应用", ticket: ticket) }
            else { try await f.monitor.recordScreenshot(image, sourceID: "test", sourceName: "合成应用", ticket: ticket) }
        }
        try await wait { await f.repository.waitingSaves == 1 }
        switch action {
        case "pause": f.settings.paused = true; f.monitor.recordingStateChanged()
        case "disable": f.settings.clipboardEnabled = false; f.monitor.stop()
        case "lock": f.monitor.setSessionActive(false, reason: "lock")
        default: f.monitor.resetBaseline(); try await f.repository.store.clear(includingFavorites: true)
        }
        await f.repository.releaseSaves()
        try await pending.value
        #expect(try await f.repository.store.list().isEmpty)
    }

    @Test func ownWritesKeepPendingScreenshotsAndFreshTicketWorksAfterCancellation() async throws {
        let f = try LifecycleFixture(); defer { f.clean() }
        let image = try f.image()
        let ticket = try #require(f.monitor.screenshotTicket(sourceID: "test"))
        let pending = Task { try await f.monitor.recordScreenshot(image, sourceID: "test", sourceName: "合成应用", ticket: ticket) }
        try await wait { await f.repository.waitingSaves == 1 }
        f.monitor.ignoreOwnWrite()
        await f.repository.releaseSaves()
        try await pending.value
        #expect(try await f.repository.store.list().count == 1)
        f.monitor.resetBaseline()
        try await f.repository.store.clear(includingFavorites: true)
        try await f.monitor.recordScreenshot(image, sourceID: "test", sourceName: "合成应用", ticket: ticket)
        #expect(try await f.repository.store.list().isEmpty)
        let fresh = try #require(f.monitor.screenshotTicket(sourceID: "test"))
        try await f.monitor.recordScreenshot(image, sourceID: "test", sourceName: "合成应用", ticket: fresh)
        #expect(try await f.repository.store.list().count == 1)
    }

    @Test func callerCancellationAlsoCancelsItsPendingScreenshotSave() async throws {
        let f = try LifecycleFixture(); defer { f.clean() }
        let image = try f.image()
        let ticket = try #require(f.monitor.screenshotTicket(sourceID: "test"))
        let pending = Task { try await f.monitor.recordScreenshot(image, sourceID: "test", sourceName: "合成应用", ticket: ticket) }
        try await wait { await f.repository.waitingSaves == 1 }
        pending.cancel()
        await f.repository.releaseSaves()
        try await pending.value
        #expect(try await f.repository.store.list().isEmpty)
        // 取消一个调用不能使其他仍有效的截图票据失效。
        try await f.monitor.recordScreenshot(image, sourceID: "test", sourceName: "合成应用", ticket: ticket)
        #expect(try await f.repository.store.list().count == 1)
    }

    @Test(arguments: ["startup", "scheduled", "deadline"])
    func transientCleanupErrorsRecoverWithoutANewCopy(_ stage: String) async throws {
        let f = try LifecycleFixture(); defer { f.clean() }
        await f.repository.configureCleanup(failures: stage == "deadline" ? [] : [stage == "startup" ? 1 : 2],
            deadlineFailure: stage == "deadline", immediate: stage == "scheduled")
        if stage == "startup" { try await f.seedExpired() }
        var errors = 0
        f.monitor.onError = { _ in errors += 1 }
        f.monitor.start()
        try await wait { errors == 1 }
        if stage != "startup" { try await f.seedExpired() }
        try await wait { try await f.repository.store.list().isEmpty }
        #expect(await f.repository.retries > 0)
        #expect(f.monitor.isCleanupScheduled)
        f.monitor.stop()
        #expect(!f.monitor.isCleanupScheduled)
    }

    @Test func stoppingDuringCleanupRetryPreservesDataUntilMonitoringRestarts() async throws {
        let f = try LifecycleFixture(); defer { f.clean() }
        try await f.seedExpired()
        await f.repository.configureCleanup(failures: [1])
        var failed = false
        f.monitor.onError = { _ in failed = true }
        f.monitor.start()
        try await wait { failed }
        f.monitor.stop()
        try await Task.sleep(for: .milliseconds(1200))
        #expect(!f.monitor.isCleanupScheduled)
        #expect(await f.repository.retries == 0)
        #expect(await f.repository.cleanupCalls == 1)
        #expect(try await f.repository.store.list().count == 1)
        f.monitor.start()
        try await wait { try await f.repository.store.list().isEmpty }
        #expect(f.monitor.isCleanupScheduled)
    }
}
