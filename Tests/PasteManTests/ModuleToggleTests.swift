import AppKit
import Carbon
import FinderMenuCore
import PasteManCore
import Testing

@testable import PasteMan

@MainActor private final class ModuleClipboard: ClipboardReading, ClipboardPermissionChecking {
    var changeCount = 0
    var types: Set<String> = ["public.utf8-plain-text"]
    var allowsMonitoring = true
    var snapshot: ClipboardSnapshot?
    var reads = 0
    func refreshClipboard() {}
    func capture() -> ClipboardSnapshot? { reads += 1; return snapshot }
    func copy(_ value: ClipboardSnapshot) { changeCount += 1; snapshot = value }
}

private actor ModulePreparation {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func resume() { continuation?.resume(); continuation = nil }
}

@MainActor private final class ModuleCapture: ScreenCapturing {
    var continuation: CheckedContinuation<[CapturedScreen], any Error>?
    var calls = 0
    func capture(_ screens: [ScreenshotScreen]) async throws -> [CapturedScreen] {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
}

@MainActor private struct ModuleFixture {
    let directory: URL
    let suite: String
    let defaults: UserDefaults
    let settings: AppSettings
    let store: HistoryStore
    let board: ModuleClipboard
    let monitor: ClipboardMonitor
    let keys: HotKeyService
    let screenshots: ScreenshotCoordinator
    let modules: ModuleController
    let model: AppModel

    init(enabled: Bool = true, screenshots: ScreenshotCoordinator? = nil,
         prepare: @escaping @Sendable (Data) async throws -> PreparedContent = { _ in .text("合成图片") }) throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ModuleToggle-" + UUID().uuidString)
        suite = "ModuleToggle." + UUID().uuidString
        defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        settings.hasOnboarded = true
        settings.clipboardEnabled = enabled
        settings.screenshotEnabled = enabled
        let modifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        settings.shortcut = Shortcut(keyCode: UInt32(kVK_F13), modifiers: modifiers, keyLabel: "F13")
        settings.screenshotShortcut = Shortcut(keyCode: UInt32(kVK_F14), modifiers: modifiers, keyLabel: "F14")
        self.settings = settings
        let store = try HistoryStore(directory: directory)
        self.store = store
        let board = ModuleClipboard()
        self.board = board
        let monitor = ClipboardMonitor(clipboard: board, repository: store, settings: settings,
            permissions: board, sourceApplication: { ("test.modules", "合成应用") }, prepareImage: prepare)
        self.monitor = monitor
        let keys = HotKeyService()
        self.keys = keys
        let screenshots = screenshots ?? ScreenshotCoordinator(presentWindow: { _ in })
        self.screenshots = screenshots
        let modules = ModuleController(settings: settings, hotKeys: keys, monitor: monitor, screenshots: screenshots)
        self.modules = modules
        let model = AppModel(repository: store, settings: settings, permissions: PermissionService(), hotKeys: keys,
            finderModel: FinderModel(store: FinderConfigurationStore(url: directory.appendingPathComponent("finder.json"))))
        self.model = model
        settings.onRecordingChanged = { [weak monitor] in monitor?.recordingStateChanged() }
        modules.onClipboardDisabled = { [weak model] in model?.suspendClipboard() }
        modules.onShortcutIssue = { [weak model] action, issue in model?.shortcutIssues[action] = issue }
    }

    func clean() {
        modules.stop()
        screenshots.pins.closeAll()
        model.cancelRefresh()
        keys.stop()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite("模块独立开关", .serialized) @MainActor struct ModuleToggleTests {
    @Test func defaultsAndIndependentPersistenceKeepExistingPauseAndFinderChoice() throws {
        let suite = "ModuleDefaults." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "paused")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.screenshotEnabled && settings.clipboardEnabled && settings.paused)
        settings.screenshotEnabled = false
        let first = AppSettings(defaults: defaults)
        #expect(!first.screenshotEnabled && first.clipboardEnabled && first.paused)
        first.clipboardEnabled = false
        first.screenshotEnabled = true
        let second = AppSettings(defaults: defaults)
        #expect(second.screenshotEnabled && !second.clipboardEnabled && second.paused)

        let f = try ModuleFixture()
        defer { f.clean() }
        f.model.finderModel.setEnabled(false)
        let store = FinderConfigurationStore(url: f.directory.appendingPathComponent("finder.json"))
        #expect(!FinderModel(store: store).configuration.enabled)
        #expect(f.settings.screenshotEnabled && f.settings.clipboardEnabled)
    }

    @Test func disabledStartupAndResumeCaptureOnlyTheFirstNewCopy() async throws {
        let f = try ModuleFixture(enabled: false)
        defer { f.clean() }
        f.modules.start()
        #expect(!f.monitor.isPolling && !f.monitor.isCleanupScheduled && !f.screenshots.isEnabled)
        f.board.copy(.text("关闭期间"))
        await f.monitor.poll()
        #expect(f.board.reads == 0)
        #expect(f.monitor.screenshotTicket(sourceID: "test.modules") == nil)
        f.settings.clipboardEnabled = true
        #expect(f.monitor.isPolling && f.monitor.isCleanupScheduled && !f.screenshots.isEnabled)
        f.board.copy(.text("开启后第一条"))
        await f.monitor.poll()
        #expect(try await f.store.list().map(\.preview) == ["开启后第一条"])
        f.settings.clipboardEnabled = false
        f.board.copy(.text("再次关闭期间"))
        f.settings.clipboardEnabled = true
        await f.monitor.poll()
        #expect(f.board.reads == 1)
        #expect(try await f.store.list().count == 1)
    }

    @Test func disabledModuleReleasesOnlyItsShortcutAndRestoresIt() throws {
        let f = try ModuleFixture()
        defer { f.clean() }
        let competitor = HotKeyService()
        defer { competitor.stop() }
        f.modules.start()
        #expect(f.model.shortcutIssues.isEmpty)
        #expect(!competitor.register(f.settings.shortcut))
        f.settings.clipboardEnabled = false
        #expect(competitor.register(f.settings.shortcut))
        #expect(!competitor.register(f.settings.screenshotShortcut, for: .screenshot))
        f.settings.clipboardEnabled = true
        #expect(f.settings.clipboardEnabled && f.model.shortcutIssues[.history] != nil)
        #expect(f.model.shortcutIssues[.screenshot] == nil && f.screenshots.isEnabled)
        competitor.unregister(for: .history)
        f.settings.clipboardEnabled = false
        f.settings.clipboardEnabled = true
        #expect(f.model.shortcutIssues.isEmpty)
        #expect(!competitor.register(f.settings.shortcut))
        f.settings.screenshotEnabled = false
        #expect(competitor.register(f.settings.screenshotShortcut, for: .screenshot))
        #expect(f.monitor.isPolling && !f.screenshots.isEnabled)
    }

    @Test func disablingCancelsQueriesAndKeepsFavoritesAndPauseAcrossResume() async throws {
        let f = try ModuleFixture()
        defer { f.clean() }
        try await f.store.save(.text("保留的历史"), sourceBundleID: "test", sourceName: "合成应用", policy: f.settings.policy)
        let entry = try #require(try await f.store.list().first)
        try await f.store.setFavorite(entry.id, value: true)
        f.modules.start()
        f.settings.paused = true
        f.model.search = "等待取消"
        f.model.panelVisible = true
        f.model.preview = entry
        f.model.refresh()
        #expect(f.model.loading)
        f.settings.clipboardEnabled = false
        #expect(!f.model.panelVisible && !f.model.loading && f.model.preview == nil)
        #expect(!f.monitor.isPolling && !f.monitor.isCleanupScheduled)
        f.model.refresh()
        #expect(!f.model.loading)
        f.settings.clipboardEnabled = true
        #expect(f.settings.paused && !f.monitor.isPolling && f.monitor.isCleanupScheduled)
        #expect(try await f.store.list().first?.isFavorite == true)
        f.settings.paused = false
        #expect(f.monitor.isPolling)
    }

    @Test func disabledHistoryDoesNotAutoPruneAndResumeRestoresRetention() async throws {
        let f = try ModuleFixture(enabled: false)
        defer { f.clean() }
        try await f.store.save(.text("待恢复保留策略"), sourceBundleID: "test", sourceName: "合成应用",
            policy: RetentionPolicy(days: 30), now: Date().addingTimeInterval(-2 * 86400))
        f.settings.retentionDays = 1
        f.modules.start()
        f.model.applyRetention()
        try await Task.sleep(for: .milliseconds(1100))
        #expect(try await f.store.list().count == 1)
        f.settings.clipboardEnabled = true
        for _ in 0..<200 {
            if try await f.store.list().isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try await f.store.list().isEmpty)
    }

    @Test func retentionChangesApplyWithoutSettingsWindowAndPreserveFavorites() async throws {
        let f = try ModuleFixture()
        defer { f.clean() }
        let now = Date()
        for index in 0..<5 {
            try await f.store.save(.text("历史参数检查 \(index)"), sourceBundleID: "test", sourceName: "合成应用",
                policy: f.settings.policy, now: now.addingTimeInterval(Double(index - 5) * 86400))
        }
        let favorite = try #require(try await f.store.list().last)
        try await f.store.setFavorite(favorite.id, value: true)
        var refreshes = 0
        f.monitor.onChange = { refreshes += 1 }
        f.modules.start()
        // 等待启动清理进入休眠，确保验证的是参数修改唤醒，而非启动清理。
        try await Task.sleep(for: .milliseconds(100))
        f.settings.historyLimit = 2
        for _ in 0..<100 {
            if try await f.store.list().count == 3 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try await f.store.list().count == 3)
        f.settings.retentionDays = 1
        for _ in 0..<100 {
            if try await f.store.list().count == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try await f.store.list().map(\.id) == [favorite.id])
        #expect(refreshes == 2)
        let restored = AppSettings(defaults: f.defaults)
        #expect(restored.retentionDays == 1 && restored.historyLimit == 2)
    }

    @Test func retentionParametersNormalizeBeforeNotificationAndSkipUnchangedValues() throws {
        let f = try ModuleFixture()
        defer { f.clean() }
        var changes = 0
        f.settings.onRetentionChanged = {
            changes += 1
            #expect(f.settings.retentionDays >= 1 && f.settings.historyLimit >= 1)
            #expect(f.defaults.integer(forKey: "retentionDays") == f.settings.retentionDays)
        }
        defer { f.settings.onRetentionChanged = nil }
        f.settings.retentionDays = 0
        f.settings.retentionDays = -1
        f.settings.historyLimit = 0
        f.settings.historyLimit = -1
        #expect(changes == 2)
        #expect(f.settings.retentionDays == 1 && f.settings.historyLimit == 1)
        #expect(f.settings.policy.days == 1 && f.settings.policy.count == 1)
        let restored = AppSettings(defaults: f.defaults)
        #expect(restored.retentionDays == 1 && restored.historyLimit == 1)
    }

    @Test func rapidDisableAndEnableDiscardsPendingImageAndScreenshotTickets() async throws {
        let preparation = ModulePreparation()
        let f = try ModuleFixture(prepare: { _ in await preparation.wait(); return .text("旧图片") })
        defer { f.clean() }
        f.modules.start()
        let ticket = try #require(f.monitor.screenshotTicket(sourceID: "test.modules"))
        f.board.copy(.image(Data([1])))
        let processing = Task { await f.monitor.poll() }
        for _ in 0..<200 {
            if await preparation.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await preparation.started)
        f.board.copy(.text("排队内容"))
        f.monitor.enqueueCapture()
        f.settings.clipboardEnabled = false
        #expect(f.monitor.pendingCaptureCount == 0)
        f.settings.clipboardEnabled = true
        await preparation.resume()
        await processing.value
        try await f.monitor.recordScreenshot(Data([2]), sourceID: "test.modules", sourceName: "合成应用", ticket: ticket)
        #expect(try await f.store.list().isEmpty)
        f.board.copy(.text("恢复后"))
        await f.monitor.poll()
        #expect(try await f.store.list().map(\.preview) == ["恢复后"])
    }

    @Test func pendingExplicitScreenshotCannotEnterHistoryAfterDisableAndEnable() async throws {
        let preparation = ModulePreparation()
        let f = try ModuleFixture(prepare: { _ in await preparation.wait(); return .text("旧截图") })
        defer { f.clean() }
        f.modules.start()
        let ticket = try #require(f.monitor.screenshotTicket(sourceID: "test.modules"))
        let processing = Task {
            try await f.monitor.recordScreenshot(Data([1]), sourceID: "test.modules", sourceName: "合成应用", ticket: ticket)
        }
        for _ in 0..<200 {
            if await preparation.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await preparation.started)
        f.settings.clipboardEnabled = false
        f.settings.clipboardEnabled = true
        await preparation.resume()
        try await processing.value
        #expect(try await f.store.list().isEmpty)
    }

    @Test func screenshotDisableCancelsCaptureRejectsNewStartsAndKeepsExistingPins() async throws {
        let capture = ModuleCapture()
        let pins = PinnedScreenshotManager(presentWindow: { _ in })
        let screenshots = ScreenshotCoordinator(captureService: capture, pins: pins, presentWindow: { _ in })
        let f = try ModuleFixture(screenshots: screenshots)
        defer { f.clean() }
        f.modules.start()
        let context = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try ScreenshotRenderer.export(base: #require(context.makeImage()), pointSize: CGSize(width: 16, height: 16), annotations: [])
        pins.show(image, sourceID: "test.modules", sourceName: "合成应用", origin: nil)
        screenshots.start(screens: [], sourceID: "test.modules", sourceName: "合成应用")
        for _ in 0..<200 where capture.calls == 0 { await Task.yield() }
        #expect(capture.calls == 1 && screenshots.isActive)
        f.settings.screenshotEnabled = false
        #expect(!screenshots.isActive && screenshots.windows.isEmpty && pins.count == 1)
        screenshots.start(screens: [], sourceID: "test.modules", sourceName: "合成应用")
        #expect(!screenshots.isActive && capture.calls == 1)
        capture.continuation?.resume(returning: [])
        for _ in 0..<20 { await Task.yield() }
        #expect(!screenshots.isActive && pins.count == 1 && f.monitor.isPolling)
        var copied = false
        screenshots.onCopy = { _, _, _ in copied = true; return true }
        #expect(pins.onCopy?(image, "test.modules", "合成应用") == true && copied)
        f.settings.screenshotEnabled = true
        #expect(screenshots.isEnabled && pins.count == 1)
    }

    @Test func allModulesOffKeepSettingsQuitAndPinCleanupAvailableInStatusMenu() throws {
        let f = try ModuleFixture(enabled: false)
        defer { f.clean() }
        f.model.finderModel.setEnabled(false)
        f.modules.start()
        let delegate = AppDelegate()
        let menu = delegate.makeStatusMenu(for: f.model)
        #expect(!menu.autoenablesItems)
        for name in ["startScreenshot", "togglePause", "confirmClear"] {
            #expect(menu.items.first { $0.action == NSSelectorFromString(name) }?.isEnabled == false)
        }
        for name in ["showSettings", "showFinderSettings", "quit", "closeAllPins"] {
            #expect(menu.items.first { $0.action == NSSelectorFromString(name) }?.isEnabled == true)
        }
        let disabled = RecordingStatusAppearance(paused: true, applicationLabel: "测试", clipboardEnabled: false)
        #expect(disabled.toolTip == "测试" + L.t(" — Clipboard disabled", " — 剪贴板已关闭"))
        #expect(disabled.symbol != "pause.circle")
    }

    @Test func screenshotAndPinnedCopyStillWriteToANamedClipboardWhileHistoryIsDisabled() async throws {
        let f = try ModuleFixture()
        defer { f.clean() }
        f.modules.start()
        f.settings.clipboardEnabled = false
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ModuleCopy." + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let clipboard = SystemClipboard(pasteboard: pasteboard)
        f.screenshots.onCopy = { image, sourceID, _ in
            let written = clipboard.write(.image(png: image.png, thumbnail: Data()))
            #expect(f.monitor.screenshotTicket(sourceID: sourceID) == nil)
            return written
        }
        let context = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try ScreenshotRenderer.export(base: #require(context.makeImage()), pointSize: CGSize(width: 16, height: 16), annotations: [])
        #expect(f.screenshots.onCopy?(image, "test.modules", "合成应用") == true)
        #expect(pasteboard.data(forType: .png) == image.png)
        #expect(f.screenshots.pins.onCopy?(image, "test.modules", "合成应用") == true)
        #expect(pasteboard.data(forType: .png) == image.png)
        #expect(try await f.store.list().isEmpty)
    }

    @Test func finderTogglePreservesActionChoicesFileTypesAndRejectsOldCommands() throws {
        let f = try ModuleFixture()
        defer { f.clean() }
        let finder = f.model.finderModel
        finder.set(.copyName, enabled: false)
        #expect(finder.addFileType("yaml"))
        let previous = finder.configuration
        let command = FinderMenuCommand(action: .openTerminal, usesTarget: true)
        finder.setEnabled(false)
        #expect(FinderMenuPlan(items: [f.directory], configuration: finder.configuration) == nil)
        #expect(throws: (any Error).self) {
            try command.request(target: f.directory, selection: [], configuration: finder.configuration)
        }
        finder.setEnabled(true)
        #expect(finder.configuration == previous)
        #expect(try command.request(target: f.directory, selection: [], configuration: finder.configuration).action == .openTerminal)
    }
}
