import AppKit
import PasteManCore
import Testing
import Synchronization

@testable import PasteMan

@MainActor private final class DelayedClipboard: ClipboardReading, ClipboardPermissionChecking {
    var changeCount = 0
    var types: Set<String> = []
    var allowsMonitoring = true
    var reads = 0
    var continuation: CheckedContinuation<ClipboardSnapshot?, Never>?
    func refreshClipboard() {}
    func capture(expectedChangeCount: Int) async -> ClipboardSnapshot? {
        reads += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func complete() { continuation?.resume(returning: .text("延迟内容")); continuation = nil }
}

@Suite("异步剪贴板读取", .serialized) @MainActor struct ClipboardReadTests {
    @Test func blockedReaderRunsOffMainAndCanceledQueuedReadDoesNotFetchData() async throws {
        let release = DispatchSemaphore(value: 0)
        let state = Mutex((started: false, onMain: false, calls: 0))
        let worker = ClipboardReadWorker { _, _ in
            state.withLock { $0.started = true; $0.onMain = Thread.isMainThread; $0.calls += 1 }
            _ = release.wait(timeout: .now() + 5)
            return .text("迟到内容")
        }
        let first = Task { await worker.capture(name: "test", expectedChangeCount: 1) }
        defer { release.signal(); first.cancel() }
        let deadline = ContinuousClock.now + .seconds(2)
        while !state.withLock({ $0.started }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(state.withLock { $0.started })
        #expect(!state.withLock { $0.onMain })
        let queued = Task { await worker.capture(name: "test", expectedChangeCount: 2) }
        await Task.yield()
        queued.cancel()
        first.cancel()
        release.signal()
        #expect(await first.value == nil)
        #expect(await queued.value == nil)
        #expect(state.withLock { $0.calls } == 1)
    }

    @Test func namedClipboardReadsImageOnWorkerAndRejectsStaleCount() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("图片说明", forType: .string)
        item.setData(Data([1, 2, 3]), forType: .png)
        try #require(board.writeObjects([item]))
        let clipboard = SystemClipboard(pasteboard: board)
        let count = board.changeCount
        guard case .image(let data) = await clipboard.capture(expectedChangeCount: count) else {
            Issue.record("异步读取应优先取得图片")
            return
        }
        #expect(data == Data([1, 2, 3]))
        board.clearContents()
        #expect(await clipboard.capture(expectedChangeCount: count) == nil)
    }

    @Test(arguments: ["pause", "source", "count", "permission", "stop"])
    func lateReadCannotSaveInvalidatedContent(_ invalidation: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ClipboardRead." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = try HistoryStore(directory: directory)
        let settings = AppSettings(defaults: defaults)
        settings.hasOnboarded = true
        let board = DelayedClipboard()
        let monitor = ClipboardMonitor(clipboard: board, repository: store, settings: settings,
            permissions: board, sourceApplication: { ("test.editor", "合成应用") })
        board.changeCount += 1
        let pending = Task { await monitor.poll() }
        defer { pending.cancel(); board.complete(); monitor.stop() }
        let deadline = ContinuousClock.now + .seconds(2)
        while board.continuation == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(board.continuation != nil, "采集必须等待异步读取，期间主线程仍能操作")
        // 并发轮询不能为同一剪贴板增加第二个等待中的读取。
        await monitor.poll()
        #expect(board.reads == 1)
        switch invalidation {
        case "pause":
            settings.paused = true
            monitor.recordingStateChanged()
            settings.paused = false
            monitor.recordingStateChanged()
        case "source": monitor.sourceApplicationChanged()
        case "count": board.changeCount += 1
        case "permission": board.allowsMonitoring = false
        default: monitor.stop()
        }
        board.complete()
        await pending.value
        #expect(try await store.list().isEmpty)
        board.allowsMonitoring = true
        monitor.recordingStateChanged()
        board.changeCount += 1
        let fresh = Task { await monitor.poll() }
        defer { fresh.cancel(); board.complete() }
        let freshDeadline = ContinuousClock.now + .seconds(2)
        while board.continuation == nil, ContinuousClock.now < freshDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(board.continuation != nil)
        board.complete()
        await fresh.value
        #expect(try await store.list().first?.preview == "延迟内容")
    }
}
