import AppKit
import Foundation
import PasteManCore
import Testing

@testable import PasteMan

@MainActor private final class FakePermissions: ClipboardPermissionChecking {
    var allowsMonitoring = true
    func refreshClipboard() {}
}

@MainActor private final class FakeClipboard: ClipboardReading {
    var changeCount = 1
    var types: Set<String> = ["public.utf8-plain-text"]
    var snapshot: ClipboardSnapshot? = .text("initial")
    var reads = 0
    func capture() -> ClipboardSnapshot? {
        reads += 1
        return snapshot
    }
    func copy(_ text: String) {
        changeCount += 1
        snapshot = .text(text)
    }
}

@MainActor private final class FakeWriter: ClipboardWriting {
    var writes = 0
    var text: String?
    func write(_ content: PreparedContent) -> Bool {
        writes += 1
        if case .text(let value) = content { text = value }
        return true
    }
}

@MainActor private final class FakePasteExecutor: PasteExecuting {
    var calls = 0
    func paste(to target: NSRunningApplication?) async -> PasteOutcome {
        calls += 1
        return .sent
    }
}

@MainActor private struct CaptureFixture {
    let directory: URL
    let store: HistoryStore
    let clipboard = FakeClipboard()
    let permissions = FakePermissions()
    let settings: AppSettings
    let defaults: UserDefaults
    let suite: String
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PasteManIntegration-" + UUID().uuidString)
        store = try HistoryStore(directory: directory)
        suite = "PasteManTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        settings = AppSettings(defaults: defaults)
        settings.hasOnboarded = true
    }
    func monitor(app: String = "test.editor", prepare: (@Sendable (Data) async throws -> PreparedContent)? = nil)
        -> ClipboardMonitor
    {
        if let prepare {
            return ClipboardMonitor(
                clipboard: clipboard, repository: store, settings: settings, permissions: permissions,
                sourceApplication: { (app, "Editor") }, prepareImage: prepare)
        }
        return ClipboardMonitor(
            clipboard: clipboard, repository: store, settings: settings, permissions: permissions,
            sourceApplication: { (app, "Editor") })
    }
    func clean() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite("System integration", .serialized) @MainActor struct ClipboardIntegrationTests {
    @Test func monitorStartsAtCurrentCountAndSuppressesSelfWrites() async throws {
        let f = try CaptureFixture()
        defer { f.clean() }
        let monitor = f.monitor()
        await monitor.poll()
        #expect(f.clipboard.reads == 0)
        f.clipboard.copy("new copy")
        await monitor.poll()
        await monitor.poll()
        #expect(try await f.store.list().count == 1)
        f.clipboard.copy("own write")
        monitor.ignoreOwnWrite()
        await monitor.poll()
        #expect(f.clipboard.reads == 1)
        #expect(try await f.store.list().first?.preview == "new copy")
    }

    @Test func deniedPermissionAndPauseNeverReadOrReplayClipboard() async throws {
        let f = try CaptureFixture()
        defer { f.clean() }
        let monitor = f.monitor()
        f.permissions.allowsMonitoring = false
        f.clipboard.copy("denied")
        await monitor.poll()
        f.permissions.allowsMonitoring = true
        await monitor.poll()
        f.settings.paused = true
        f.clipboard.copy("paused")
        await monitor.poll()
        f.settings.paused = false
        monitor.resetBaseline()
        await monitor.poll()
        #expect(f.clipboard.reads == 0)
        #expect(try await f.store.list().isEmpty)
        f.clipboard.copy("allowed")
        await monitor.poll()
        #expect(try await f.store.list().first?.preview == "allowed")
    }

    @Test func privacyFiltersBeforeReadingPayload() async throws {
        let f = try CaptureFixture()
        defer { f.clean() }
        let monitor = f.monitor()
        f.clipboard.types.insert("org.nspasteboard.ConcealedType")
        f.clipboard.copy("secret")
        await monitor.poll()
        f.clipboard.types = []
        f.settings.excludedApps.insert("test.editor")
        f.clipboard.copy("excluded")
        await monitor.poll()
        #expect(f.clipboard.reads == 0)
        #expect(try await f.store.list().isEmpty)
    }

    @Test func inactiveMonitoringBacksOffAndPermissionRecoveryEstablishesNewBaseline() async throws {
        let f = try CaptureFixture()
        defer { f.clean() }
        let monitor = f.monitor()
        #expect(monitor.pollInterval == .milliseconds(500))
        f.settings.paused = true
        #expect(monitor.pollInterval == .seconds(60))
        f.settings.paused = false
        f.permissions.allowsMonitoring = false
        #expect(monitor.pollInterval == .seconds(5))
        await monitor.poll()
        f.clipboard.copy("copied while permission was denied")
        f.permissions.allowsMonitoring = true
        await monitor.poll()
        #expect(f.clipboard.reads == 0)
        f.clipboard.copy("new allowed copy")
        await monitor.poll()
        #expect(try await f.store.list().first?.preview == "new allowed copy")
    }

    @Test func resumeImmediatelyUsesFreshBaselineWithoutDroppingTheNextCopy() async throws {
        let f = try CaptureFixture()
        defer { f.clean() }
        let monitor = f.monitor()
        f.settings.onRecordingChanged = { monitor.recordingStateChanged() }
        f.settings.paused = true
        f.clipboard.copy("paused copy")
        f.settings.paused = false
        f.clipboard.copy("first copy after resume")
        await monitor.poll()
        #expect(f.clipboard.reads == 1)
        #expect(try await f.store.list().first?.preview == "first copy after resume")
    }

    @Test func pausingInvalidatesImageAlreadyBeingProcessed() async throws {
        let f = try CaptureFixture()
        defer { f.clean() }
        let work = ImageWork()
        let monitor = f.monitor(prepare: { _ in
            await work.wait()
            return .image(png: Data([1]), thumbnail: Data([2]))
        })
        f.clipboard.snapshot = .image(Data([0]))
        f.clipboard.changeCount += 1
        let poll = Task { await monitor.poll() }
        await work.waitUntilStarted()
        f.settings.paused = true
        monitor.resetBaseline()
        // Even a quick pause/resume must invalidate the pending capture.
        f.settings.paused = false
        monitor.resetBaseline()
        await work.resume()
        await poll.value
        #expect(try await f.store.list().isEmpty)
    }

    @Test func namedPasteboardChoosesImageBeforeTextAndSkipsFiles() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let clipboard = SystemClipboard(pasteboard: board)
        let item = NSPasteboardItem()
        item.setString("caption", forType: .string)
        item.setData(Data([1, 2, 3]), forType: .png)
        board.writeObjects([item])
        guard case .image(let data) = clipboard.capture() else {
            Issue.record("Image should take precedence")
            return
        }
        #expect(data == Data([1, 2, 3]))
        board.clearContents()
        let file = NSPasteboardItem()
        file.setString("file:///tmp/private.txt", forType: .fileURL)
        file.setString("/tmp/private.txt", forType: .string)
        board.writeObjects([file])
        #expect(clipboard.capture() == nil)
        board.clearContents()
        #expect(clipboard.write(.text("  中文\nline  ")))
        #expect(board.string(forType: .string) == "  中文\nline  ")
    }

    @Test func firstSupportedItemIsUsedAndSettingsPersist() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let first = NSPasteboardItem()
        first.setString("unsupported", forType: NSPasteboard.PasteboardType("test.custom"))
        let second = NSPasteboardItem()
        second.setString("first supported", forType: .string)
        let third = NSPasteboardItem()
        third.setString("later", forType: .string)
        board.writeObjects([first, second, third])
        guard case .text(let text) = SystemClipboard(pasteboard: board).capture() else {
            Issue.record("Expected text")
            return
        }
        #expect(text == "first supported")
        let f = try CaptureFixture()
        defer { f.clean() }
        f.settings.retentionDays = 7
        f.settings.historyLimit = 1000
        f.settings.excludedApps = ["custom.private"]
        let reloaded = AppSettings(defaults: f.defaults)
        #expect(reloaded.retentionDays == 7 && reloaded.historyLimit == 1000)
        #expect(reloaded.excludedApps == ["custom.private"])
        #expect(reloaded.shortcut.label == "⇧⌘V")
    }

    @Test func autoPasteWithoutRecipientFailsSafely() async {
        let result = await SystemPasteExecutor().paste(to: nil)
        #expect(result == .targetUnavailable)
    }

    @Test func selectionWritesClosesAndPastesOnlyOnce() async throws {
        let f = try CaptureFixture()
        defer { f.clean() }
        let keys = HotKeyService()
        defer { keys.stop() }
        let writer = FakeWriter()
        let executor = FakePasteExecutor()
        let model = AppModel(
            repository: f.store, settings: f.settings, permissions: PermissionService(), hotKeys: keys,
            pasteExecutor: executor, clipboardWriter: writer)
        try await f.store.save(
            .text("selected text"), sourceBundleID: "test", sourceName: "test", policy: RetentionPolicy(), now: Date())
        let entry = try #require(try await f.store.list().first)
        var closed = 0
        var ignored = 0
        model.onClose = { closed += 1 }
        model.onIgnoreWrite = { ignored += 1 }
        model.activate(entry)
        model.activate(entry)  // repeated Enter while loading must not deliver twice
        for _ in 0..<100 {
            if executor.calls == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(writer.writes == 1 && writer.text == "selected text")
        #expect(closed == 1 && ignored == 1 && executor.calls == 1)
    }

    @Test func copyOnlyNeverRequestsPaste() async throws {
        let f = try CaptureFixture()
        defer { f.clean() }
        let keys = HotKeyService()
        defer { keys.stop() }
        let writer = FakeWriter()
        let executor = FakePasteExecutor()
        let model = AppModel(
            repository: f.store, settings: f.settings, permissions: PermissionService(), hotKeys: keys,
            pasteExecutor: executor, clipboardWriter: writer)
        try await f.store.save(
            .text("copy only"), sourceBundleID: "test", sourceName: "test", policy: RetentionPolicy(), now: Date())
        let entry = try #require(try await f.store.list().first)
        var closed = false
        model.onClose = { closed = true }
        model.activate(entry, copyOnly: true)
        for _ in 0..<100 {
            if closed { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(writer.text == "copy only" && closed)
        #expect(executor.calls == 0)
    }

    @Test func sourcesStayCompleteDuringSearchAndUpdateAfterHiddenChanges() async throws {
        let f = try CaptureFixture()
        defer { f.clean() }
        let keys = HotKeyService()
        defer { keys.stop() }
        let model = AppModel(
            repository: f.store, settings: f.settings, permissions: PermissionService(), hotKeys: keys)
        try await f.store.save(
            .text("editor text"), sourceBundleID: "test.editor", sourceName: "Editor",
            policy: RetentionPolicy(), now: Date())
        model.panelVisible = true
        model.refresh()
        try await waitForRefresh(model)
        model.search = "no match"
        model.refresh()
        try await waitForRefresh(model)
        #expect(model.entries.isEmpty)
        #expect(model.sources.map(\.bundleID) == ["test.editor"])
        model.panelVisible = false
        model.cancelRefresh()
        try await f.store.save(
            .text("browser text"), sourceBundleID: "test.browser", sourceName: "Browser",
            policy: RetentionPolicy(), now: Date())
        model.changed()
        model.search = ""
        model.panelVisible = true
        model.refresh()
        try await waitForRefresh(model)
        #expect(model.entries.count == 2)
        #expect(Set(model.sources.map(\.bundleID)) == ["test.editor", "test.browser"])
        model.search = "canceled"
        model.refresh()
        model.cancelRefresh()
        try await Task.sleep(for: .milliseconds(120))
        #expect(!model.loading)
        #expect(model.entries.count == 2)
    }
}

@MainActor private func waitForRefresh(_ model: AppModel) async throws {
    for _ in 0..<200 {
        if !model.loading { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("History refresh timed out")
}

private actor ImageWork {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var finishWaiter: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { finishWaiter = $0 }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func resume() {
        finishWaiter?.resume()
        finishWaiter = nil
    }
}
