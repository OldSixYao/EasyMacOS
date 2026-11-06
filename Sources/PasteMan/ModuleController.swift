import Foundation

/// 启停跟随持久设置，不依赖设置窗口或当前页面的生命周期。
@MainActor final class ModuleController {
    private let settings: AppSettings
    private let hotKeys: HotKeyService
    private let monitor: ClipboardMonitor
    private let screenshots: ScreenshotCoordinator
    private var started = false
    var onClipboardDisabled: (() -> Void)?
    var onStatusChanged: (() -> Void)?
    var onShortcutIssue: ((HotKeyAction, String?) -> Void)?

    init(settings: AppSettings, hotKeys: HotKeyService, monitor: ClipboardMonitor, screenshots: ScreenshotCoordinator) {
        self.settings = settings
        self.hotKeys = hotKeys
        self.monitor = monitor
        self.screenshots = screenshots
    }

    func start() {
        guard !started else { return }
        started = true
        settings.onClipboardChanged = { [weak self] in self?.applyClipboard() }
        settings.onScreenshotChanged = { [weak self] in self?.applyScreenshot() }
        settings.onRetentionChanged = { [weak self] in self?.monitor.scheduleCleanup() }
        applyClipboard()
        applyScreenshot()
    }

    private func applyClipboard() {
        hotKeys.cancelRecording()
        if settings.clipboardEnabled {
            monitor.recordingStateChanged()
            monitor.start()
            register(settings.shortcut, for: .history)
        } else {
            monitor.stop()
            hotKeys.unregister(for: .history)
            onShortcutIssue?(.history, nil)
            onClipboardDisabled?()
        }
        onStatusChanged?()
    }

    private func applyScreenshot() {
        hotKeys.cancelRecording()
        screenshots.isEnabled = settings.screenshotEnabled
        if settings.screenshotEnabled {
            register(settings.screenshotShortcut, for: .screenshot)
        } else {
            hotKeys.unregister(for: .screenshot)
            onShortcutIssue?(.screenshot, nil)
        }
    }

    private func register(_ shortcut: Shortcut, for action: HotKeyAction) {
        let issue = hotKeys.register(shortcut, for: action) ? nil : L.t(
            "Shortcut unavailable. Choose another in Settings.", "快捷键已被占用，请在设置中修改。")
        onShortcutIssue?(action, issue)
    }

    func stop() {
        started = false
        settings.onClipboardChanged = nil
        settings.onScreenshotChanged = nil
        settings.onRetentionChanged = nil
        monitor.stop()
        screenshots.isEnabled = false
        hotKeys.unregister(for: .history)
        hotKeys.unregister(for: .screenshot)
    }
}
