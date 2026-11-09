import AppKit
import AVFoundation
import Carbon
import FinderMenuCore
import PasteManCore
import SwiftUI

@MainActor final class HistoryPanel: NSPanel {
    var handleKey: ((NSEvent) -> Bool)?

    init() {
        // Status-item actions need not activate the owning app. A nonactivating panel can
        // take keyboard focus directly; NSPanel's default deactivate hiding must be disabled.
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 590),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleKey?(event) == true { return }
        super.sendEvent(event)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    let updates: any UpdateChecking
    private var statusItem: NSStatusItem!
    private var recordingStatusSymbol: String?
    private var panel: HistoryPanel?
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private var model: AppModel?
    private var monitor: ClipboardMonitor?
    private var hotKeys: HotKeyService?
    private var screenshots: ScreenshotCoordinator?
    private let screenRecorder = ScreenRecordingCoordinator()
    private var recordingPresentation: ScreenRecordingPresentation?
    private var recordingScreenObserver: NSObjectProtocol?
    private var waitingToTerminate = false
    private var modules: ModuleController?
    private let outsideClicks = HistoryOutsideClickMonitor()
    private var lastExternalApp: NSRunningApplication?
    private var workspaceObserver: NSObjectProtocol?
    private var sessionObservers: [NSObjectProtocol] = []
    private var lockObservers: [NSObjectProtocol] = []
    private var menuOpen = false
    private let finderRequests = FinderRequestQueue()

    init(updates: any UpdateChecking = UpdateController()) {
        self.updates = updates
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--version") {
            print(AppVersion.current.applicationLabel)
            NSApp.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--permission-status") {
            // Launch via `open --stdout ... --args --permission-status` to inspect this app's
            // actual TCC identity, rather than the terminal's inherited permissions.
            print("Application: \(Bundle.main.bundleURL.path)")
            print("Accessibility object access: \(AXIsProcessTrusted())")
            print("Keyboard event posting: \(CGPreflightPostEventAccess())")
            print("Screen recording: \(CGPreflightScreenCaptureAccess())")
            print("Microphone: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
            NSApp.terminate(nil)
            return
        }
        setupMainMenu()
        do {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let settings = AppSettings()
            let repository = try RecoveringHistoryRepository(directory: base.appendingPathComponent("PasteMan", isDirectory: true))
            let permissions = PermissionService()
            permissions.refresh()
            let keys = HotKeyService()
            let state = AppModel(repository: repository, settings: settings, permissions: permissions, hotKeys: keys, updates: updates)
            model = state
            configureDockVisibility(settings)
            let mouseScroll = state.mouseScroll
            state.finderModel.setLanguage(L.language)
            NotificationCenter.default.addObserver(
                self, selector: #selector(interfaceLanguageChanged), name: InterfaceLocalization.didChange, object: nil)
            hotKeys = keys
            let watcher = ClipboardMonitor(
                clipboard: SystemClipboard(), repository: repository, settings: settings, permissions: permissions)
            monitor = watcher
            for (name, reason) in [(NSWorkspace.willSleepNotification, "sleep"), (NSWorkspace.sessionDidResignActiveNotification, "session"), (NSWorkspace.screensDidSleepNotification, "display")] {
                sessionObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self, weak watcher, weak mouseScroll] _ in
                    MainActor.assumeIsolated {
                        self?.screenRecorder.stop()
                        watcher?.setSessionActive(false, reason: reason)
                        mouseScroll?.setSessionActive(false, reason: reason)
                    }
                })
            }
            for (name, reason) in [(NSWorkspace.didWakeNotification, "sleep"), (NSWorkspace.sessionDidBecomeActiveNotification, "session"), (NSWorkspace.screensDidWakeNotification, "display")] {
                sessionObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak watcher, weak mouseScroll] _ in
                    MainActor.assumeIsolated {
                        watcher?.setSessionActive(true, reason: reason)
                        mouseScroll?.setSessionActive(true, reason: reason)
                    }
                })
            }
            for (name, active) in [("com.apple.screenIsLocked", false), ("com.apple.screenIsUnlocked", true)] {
                lockObservers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self, weak watcher, weak mouseScroll] _ in
                    MainActor.assumeIsolated {
                        if !active { self?.screenRecorder.stop() }
                        watcher?.setSessionActive(active, reason: "lock")
                        mouseScroll?.setSessionActive(active, reason: "lock")
                    }
                })
            }
            settings.onRecordingChanged = { [weak watcher, weak self] in
                watcher?.recordingStateChanged()
                self?.refreshRecordingStatus()
            }
            watcher.onChange = { [weak state] in state?.changed() }
            watcher.onError = { [weak state] in state?.recordingIssue = L.error($0) }
            watcher.onCaptureSucceeded = { [weak state] in state?.recordingIssue = nil }
            state.onIgnoreWrite = { [weak watcher] in watcher?.ignoreOwnWrite() }
            state.onClose = { [weak self] in self?.hidePanel() }
            state.onSettings = { [weak self] in self?.showSettings() }
            state.onMenu = { [weak self] in self?.showMenu() }
            state.onClear = { [weak self] in self?.confirmClear() }
            state.onPause = { [weak self] in self?.togglePause() }
            keys.onInvoke = { [weak self] in self?.togglePanel(fromMenuBar: false) }
            let screenshotController = ScreenshotCoordinator()
            screenshots = screenshotController
            configureScreenRecording(settings: settings, permissions: permissions, keys: keys)
            keys.onScreenshot = { [weak self] in self?.startScreenshot() }
            screenshotController.onError = { message in
                let alert = NSAlert()
                alert.messageText = L.t("Screenshot unavailable", "无法截图")
                alert.informativeText = message
                NSApp.activate()
                alert.runModal()
            }
            screenshotController.onCopyColor = { [weak watcher] hex in
                let written = SystemClipboard().write(.text(hex))
                if written { watcher?.ignoreOwnWrite() }
                return written
            }
            screenshotController.onCopy = { [weak watcher, weak self] image, sourceID, sourceName in
                guard SystemClipboard().write(.image(png: image.png, thumbnail: Data())) else { return false }
                watcher?.ignoreOwnWrite()
                let ticket = watcher?.screenshotTicket(sourceID: sourceID)
                Task { [weak watcher, weak self] in
                    guard let ticket else { return }
                    do {
                        try await watcher?.recordScreenshot(
                            image, sourceID: sourceID, sourceName: sourceName, ticket: ticket)
                    } catch {
                        guard watcher?.screenshotTicket(sourceID: sourceID) == ticket else { return }
                        self?.model?.recordingIssue = L.error(error)
                        let alert = NSAlert()
                        alert.messageText = L.t("Copied; history not saved", "已复制，未保存到历史")
                        alert.informativeText = L.error(error)
                        NSApp.activate()
                        alert.runModal()
                    }
                }
                return true
            }
            let modules = ModuleController(settings: settings, hotKeys: keys, monitor: watcher, screenshots: screenshotController)
            self.modules = modules
            modules.onScreenRecordingDisabled = { [weak self] in self?.screenRecorder.stop() }
            modules.onClipboardDisabled = { [weak self, weak state] in
                state?.suspendClipboard()
                self?.hidePanel()
            }
            modules.onStatusChanged = { [weak self] in self?.refreshRecordingStatus() }
            modules.onShortcutIssue = { [weak state] action, issue in state?.shortcutIssues[action] = issue }
            setupStatusItem()
            trackExternalApps()
            modules.start()
            mouseScroll.start()
            let openingFinderSettings = CommandLine.arguments.contains("--finder-settings")
            if !settings.hasOnboarded, !finderRequests.hasPending, !openingFinderSettings { showWelcome() }
            if openingFinderSettings { showFinderSettings() }
            DispatchQueue.main.async { [weak self] in
                self?.finderRequests.start { [weak self] url in await self?.handleFinderRequest(url) }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L.t("EasyMacOS could not open history", "EasyMacOS 无法打开历史记录")
            alert.informativeText = L.error(error)
            alert.runModal()
            NSApp.terminate(nil)
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        finderRequests.enqueue(urls.filter { $0.scheme == FinderRequest.scheme })
    }

    private func configureDockVisibility(_ settings: AppSettings) {
        settings.onDockVisibilityChanged = { [weak self, weak settings] in
            guard let settings else { return }
            self?.applyDockVisibility(settings.showInDock)
        }
        applyDockVisibility(settings.showInDock)
    }

    private func applyDockVisibility(_ visible: Bool) {
        let policy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        let window = NSApp.isActive ? NSApp.keyWindow : nil
        NSApp.setActivationPolicy(policy)
        // 系统切换显示策略时可能改变焦点，下一轮恢复原先正在操作的窗口。
        if let window {
            DispatchQueue.main.async { [weak window] in
                guard let window, window.isVisible else { return }
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let model else { return false }
        if model.settings.hasOnboarded {
            presentSettings()
        } else {
            showWelcome()
        }
        return false
    }

    private func handleFinderRequest(_ url: URL) async {
        if url == FinderRequest.settingsURL {
            showFinderSettings()
            return
        }
        do {
            let request = try FinderRequest(url: url)
            guard model?.finderModel.configuration.contains(request.action) == true else { return }
            hidePanel()
            await FinderActionHandler().perform(request)
        } catch { FinderActionHandler.show(error) }
    }

    @objc private func interfaceLanguageChanged() {
        setupMainMenu()
        recordingStatusSymbol = nil
        refreshRecordingStatus()
        settingsWindow?.title = L.t("EasyMacOS Settings", "EasyMacOS 设置")
        model?.finderModel.setLanguage(L.language)
    }

    private func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = makeApplicationMenu()
        main.addItem(appItem)
        let edit = NSMenuItem(title: L.t("Edit", "编辑"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: edit.title)
        for (title, action, key) in [
            (L.t("Undo", "撤销"), "undo:", "z"),
            (L.t("Cut", "剪切"), "cut:", "x"),
            (L.t("Copy", "复制"), "copy:", "c"),
            (L.t("Paste", "粘贴"), "paste:", "v"),
            (L.t("Select All", "全选"), "selectAll:", "a"),
        ] {
            editMenu.addItem(NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: key))
        }
        edit.submenu = editMenu
        main.addItem(edit)
        NSApp.mainMenu = main
    }

    func makeApplicationMenu() -> NSMenu {
        let appMenu = NSMenu()
        addVersionItem(to: appMenu)
        appMenu.addItem(.separator())
        addMenu(appMenu, L.t("Settings…", "设置…"), #selector(showSettings), key: ",")
        addMenu(appMenu, L.t("Check for Updates…", "检查更新…"), #selector(checkForUpdates))
        appMenu.addItem(.separator())
        addMenu(appMenu, L.t("Quit EasyMacOS", "退出 EasyMacOS"), #selector(quit), key: "q")
        return appMenu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(checkForUpdates) || updates.canCheckForUpdates
    }

    @objc func checkForUpdates() {
        hidePanel()
        updates.checkForUpdates()
    }
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        refreshRecordingStatus()
        button.target = self
        button.action = #selector(statusClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    private func refreshRecordingStatus() {
        guard let model, let button = statusItem?.button else { return }
        if screenRecorder.isActive {
            let symbol: String
            switch screenRecorder.phase {
            case .paused: symbol = "pause.circle.fill"
            case .saving, .stopping, .pausing: symbol = "arrow.down.circle"
            case .failed: symbol = "exclamationmark.circle"
            default: symbol = "record.circle"
            }
            if recordingStatusSymbol != symbol {
                recordingStatusSymbol = symbol
                button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: L.t("Screen recording", "屏幕录制"))
                button.image?.isTemplate = false
                button.contentTintColor = screenRecorder.phase == .paused ? .systemOrange : .systemRed
            }
            let label = L.t("Screen recording", "屏幕录制") + " " + screenRecorder.timeLabel
            if button.toolTip != label { button.toolTip = label }
            return
        }
        recordingStatusSymbol = nil
        button.contentTintColor = nil
        RecordingStatusAppearance(paused: model.settings.paused, applicationLabel: AppVersion.current.applicationLabel,
                                  clipboardEnabled: model.settings.clipboardEnabled)
            .apply(to: button)
    }
    private func trackExternalApps() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ownPID { lastExternalApp = app }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                self?.monitor?.sourceApplicationChanged()
                guard app.processIdentifier != ownPID else { return }
                self?.lastExternalApp = app
                self?.hidePanel()
            }
        }
    }
    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp || model?.settings.clipboardEnabled == false || screenRecorder.isActive {
            showMenu()
        } else {
            // A menu-bar click always opens history, even if focus loss just dismissed the panel.
            showPanel(fromMenuBar: true)
        }
    }
    private func togglePanel(fromMenuBar: Bool) {
        if panel?.isVisible == true {
            hidePanel()
        } else {
            showPanel(fromMenuBar: fromMenuBar)
        }
    }
    private func showPanel(fromMenuBar: Bool) {
        guard screenshots?.isActive != true, screenRecorder.phase != .selecting, screenRecorder.phase != .countdown else { return }
        guard let model, model.settings.clipboardEnabled else { return }
        if !model.settings.hasOnboarded {
            showWelcome()
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        model.target = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? lastExternalApp : front
        if panel == nil { createPanel(model) }
        guard let panel else { return }
        model.preview = nil
        model.panelVisible = true
        model.permissions.refresh()
        model.refresh()
        panel.contentView = NSHostingView(rootView: HistoryView(model: model))
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let size = panel.frame.size
        var origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 24)
        if fromMenuBar, let button = statusItem.button, let window = button.window {
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 6)
        }
        origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - size.width - 8))
        origin.y = max(visible.minY + 8, min(origin.y, visible.maxY - size.height))
        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
        outsideClicks.start { [weak self] in self?.hidePanel() }
    }
    private func createPanel(_ model: AppModel) {
        let panel = HistoryPanel()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovable = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self
        panel.handleKey = { [weak model, weak self] event in
            guard let model else { return false }
            if event.keyCode == UInt16(kVK_Escape) {
                if model.preview != nil { model.preview = nil } else { self?.hidePanel() }
                return true
            }
            guard model.preview == nil, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            else { return false }
            switch Int(event.keyCode) {
            case kVK_DownArrow:
                model.moveSelection(1)
                return true
            case kVK_UpArrow:
                model.moveSelection(-1)
                return true
            case kVK_Return, kVK_ANSI_KeypadEnter:
                model.performSelected()
                return true
            default: return false
            }
        }
        self.panel = panel
    }
    func hidePanel() {
        outsideClicks.stop()
        panel?.orderOut(nil)
        // Release thumbnail views and cancel their tasks while history is hidden.
        panel?.contentView = nil
        model?.panelVisible = false
        model?.cancelRefresh()
        model?.preview = nil
    }
    func windowDidResignKey(_ notification: Notification) {
        if notification.object as? NSWindow === panel, !menuOpen { hidePanel() }
    }
    private func showMenu() {
        guard let model, let button = statusItem.button else { return }
        menuOpen = true
        let menu = makeStatusMenu(for: model)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        menuOpen = false
    }
    func makeStatusMenu(for model: AppModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        addVersionItem(to: menu)
        menu.addItem(.separator())
        addMenu(
            menu, L.t("Screenshot", "截图") + "  " + model.settings.screenshotShortcut.label, #selector(startScreenshot),
            enabled: model.settings.screenshotEnabled && !screenRecorder.isActive)
        if !screenRecorder.isActive {
            addMenu(menu, HotKeyAction.recordFullScreen.title + "  " + model.settings.shortcut(for: .recordFullScreen).label,
                    #selector(startFullScreenRecording), enabled: model.settings.screenRecordingEnabled && screenshots?.isActive != true)
            addMenu(menu, HotKeyAction.recordRegion.title + "  " + model.settings.shortcut(for: .recordRegion).label,
                    #selector(startRegionRecording), enabled: model.settings.screenRecordingEnabled && screenshots?.isActive != true)
            if !screenRecorder.pendingRecoveries.isEmpty {
                let recovery = NSMenuItem(title: L.t("Recover unfinished recording", "恢复未完成录屏"), action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                let date = DateFormatter()
                date.dateFormat = "yyyy-MM-dd HH:mm:ss"
                for (index, url) in screenRecorder.pendingRecoveries.enumerated() {
                    let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    let title = "\(index + 1). " + date.string(from: created)
                    let item = NSMenuItem(title: title, action: #selector(recoverScreenRecording(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = url
                    submenu.addItem(item)
                }
                recovery.submenu = submenu
                menu.addItem(recovery)
            }
        } else {
            addMenu(menu, L.t("Screen recording", "屏幕录制") + "  " + screenRecorder.timeLabel, #selector(showRecordingControls))
            if screenRecorder.isCapturing {
                addMenu(menu, screenRecorder.phase == .paused ? L.t("Resume screen recording", "继续录屏") : L.t("Pause screen recording", "暂停录屏"), #selector(pauseScreenRecording))
            }
            addMenu(menu, L.t("Stop screen recording", "停止录屏") + "  " + model.settings.shortcut(for: .recordStop).label,
                    #selector(stopScreenRecording), enabled: screenRecorder.phase != .saving && screenRecorder.phase != .failed)
        }
        addMenu(menu, L.t("Close all pinned screenshots", "关闭所有钉图"), #selector(closeAllPins))
        addMenu(menu, L.t("Finder menu…", "访达右键…"), #selector(showFinderSettings))
        menu.addItem(.separator())
        addMenu(
            menu, model.settings.paused ? L.t("Resume recording", "恢复记录") : L.t("Pause recording", "暂停记录"),
            #selector(togglePause), enabled: model.settings.clipboardEnabled)
        addMenu(menu, L.t("Clear history…", "清空历史…"), #selector(confirmClear), enabled: model.settings.clipboardEnabled)
        menu.addItem(.separator())
        addMenu(menu, L.t("Settings…", "设置…"), #selector(showSettings), key: ",")
        addMenu(menu, L.t("Check for Updates…", "检查更新…"), #selector(checkForUpdates), enabled: updates.canCheckForUpdates)
        menu.addItem(.separator())
        addMenu(menu, L.t("Quit EasyMacOS", "退出 EasyMacOS"), #selector(quit), key: "q")
        return menu
    }
    private func addVersionItem(to menu: NSMenu) {
        let item = NSMenuItem(title: AppVersion.current.applicationLabel, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }
    private func addMenu(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "", enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }
    @objc private func startScreenshot() {
        guard let model, model.settings.screenshotEnabled, screenshots?.isActive != true, !screenRecorder.isActive else { return }
        guard model.settings.hasOnboarded else {
            showWelcome()
            return
        }
        model.permissions.refresh()
        guard model.permissions.screenRecording else {
            model.permissions.requestScreenRecording()
            // First permission interaction ends here; invoke again once macOS grants access.
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        let source = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? lastExternalApp : front
        hidePanel()
        let screens = NSScreen.screens.compactMap { screen -> ScreenshotScreen? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else {
                return nil
            }
            return ScreenshotScreen(id: id, frame: screen.frame, scale: screen.backingScaleFactor)
        }
        screenshots?.start(
            screens: screens, sourceID: source?.bundleIdentifier ?? "unknown",
            sourceName: source?.localizedName ?? L.unknownApp)
    }
    private func configureScreenRecording(settings: AppSettings, permissions: PermissionService, keys: HotKeyService) {
        recordingPresentation = ScreenRecordingPresentation(coordinator: screenRecorder)
        keys.onScreenRecording = { [weak self] action in
            switch action {
            case .recordFullScreen: self?.startFullScreenRecording()
            case .recordRegion: self?.startRegionRecording()
            case .recordPause: self?.pauseScreenRecording()
            case .recordStop: self?.stopScreenRecording()
            default: break
            }
        }
        screenRecorder.validateAccess = { [weak permissions] options in
            guard let permissions else { throw ScreenRecordingError.unavailable }
            permissions.refresh()
            if !permissions.screenRecording {
                permissions.requestScreenRecording()
                throw NSError(domain: "ScreenRecording", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    L.t("Allow Screen Recording in System Settings, then start again.", "请在系统设置中允许屏幕录制，然后重新开始。")])
            }
            if options.microphone {
                if permissions.microphone == .notDetermined { await permissions.requestMicrophone() }
                guard permissions.microphone == .authorized else {
                    throw NSError(domain: "ScreenRecording", code: 2, userInfo: [NSLocalizedDescriptionKey:
                        L.t("Microphone access is required. Enable it in Settings, or turn off microphone recording.", "需要麦克风权限，请在设置中授权，或关闭录制麦克风后重试。")])
                }
            }
        }
        screenRecorder.onChange = { [weak self] in
            guard let self else { return }
            self.refreshRecordingStatus()
            if self.waitingToTerminate && (self.screenRecorder.phase == .idle || self.screenRecorder.phase == .failed) {
                self.waitingToTerminate = false
                NSApp.reply(toApplicationShouldTerminate: self.screenRecorder.phase == .idle)
            }
        }
        recordingScreenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.screenRecorder.stop() } }
        if let recovery = screenRecorder.pendingRecoveries.first { screenRecorder.recover(recovery) }
    }
    private func startScreenRecording(_ mode: ScreenRecordingCoordinator.Mode) {
        guard let model, model.settings.screenRecordingEnabled, !screenRecorder.isActive, screenshots?.isActive != true else { return }
        guard model.settings.hasOnboarded else { showWelcome(); return }
        hidePanel()
        screenRecorder.select(mode: mode, options: model.settings.screenRecordingOptions)
    }
    @objc private func startFullScreenRecording() { startScreenRecording(.fullScreen) }
    @objc private func startRegionRecording() { startScreenRecording(.region) }
    @objc private func pauseScreenRecording() { screenRecorder.togglePause() }
    @objc private func stopScreenRecording() { screenRecorder.stop() }
    @objc private func showRecordingControls() { screenRecorder.onShowControls?() }
    @objc private func recoverScreenRecording(_ sender: NSMenuItem) {
        if let recovery = sender.representedObject as? URL { screenRecorder.recover(recovery) }
    }
    @objc private func closeAllPins() { screenshots?.pins.closeAll() }

    @objc private func togglePause() {
        guard let model, model.settings.clipboardEnabled else { return }
        model.settings.paused.toggle()
        refreshRecordingStatus()
    }
    @objc private func confirmClear() {
        guard let model, model.settings.clipboardEnabled else { return }
        hidePanel()
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L.t("Clear clipboard history?", "清空剪贴板历史？")
        alert.informativeText = L.t(
            "This deletes saved text and images from EasyMacOS. Favorites are kept unless you select the option below. This cannot be undone.",
            "将删除 EasyMacOS 保存的文本和图片。默认保留收藏，可勾选下方选项同时删除。此操作无法撤销。")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L.t("Cancel", "取消"))
        alert.addButton(withTitle: L.t("Clear history", "清空历史"))
        let checkbox = NSButton(checkboxWithTitle: L.t("Also delete favorites", "同时删除收藏"), target: nil, action: nil)
        checkbox.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = checkbox
        if alert.runModal() == .alertSecondButtonReturn {
            monitor?.resetBaseline()
            model.clear(includingFavorites: checkbox.state == .on)
        }
    }
    @objc private func showSettings() { presentSettings() }
    @objc private func showFinderSettings() { presentSettings(initialTab: .finder) }

    private func presentSettings(initialTab: SettingsTab? = nil) {
        guard let model else { return }
        hidePanel()
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = L.t("EasyMacOS Settings", "EasyMacOS 设置")
            window.delegate = self
            window.contentView = NSHostingView(rootView: SettingsView(model: model, initialTab: initialTab ?? .general))
            window.setContentSize(NSSize(width: 600, height: 580))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        } else if let initialTab {
            settingsWindow?.contentView = NSHostingView(rootView: SettingsView(model: model, initialTab: initialTab))
        }
        model.permissions.refresh()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow {
            hotKeys?.cancelRecording()
            settingsWindow?.contentView = nil
            settingsWindow = nil
        }
    }
    private func showWelcome() {
        guard let model else { return }
        if welcomeWindow == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "EasyMacOS"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: WelcomeView(permissions: model.permissions) { [weak self, weak model] in
                    model?.settings.hasOnboarded = true
                    self?.welcomeWindow?.orderOut(nil)
                    self?.togglePanel(fromMenuBar: false)
                })
            window.setContentSize(NSSize(width: 470, height: 540))
            window.center()
            welcomeWindow = window
        }
        NSApp.activate()
        welcomeWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if screenRecorder.phase == .selecting || screenRecorder.phase == .countdown { screenRecorder.cancelSelection() }
        guard screenRecorder.isActive else { return .terminateNow }
        if screenRecorder.phase == .failed { showRecordingControls(); return .terminateCancel }
        waitingToTerminate = true
        Task { @MainActor [weak self] in self?.screenRecorder.stop() }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        recordingPresentation?.dismissSelection()
        recordingPresentation?.closeControls()
        if let recordingScreenObserver { NotificationCenter.default.removeObserver(recordingScreenObserver) }
        modules?.stop()
        screenshots?.cancel()
        screenshots?.pins.closeAll()
        monitor?.stop()
        model?.mouseScroll.stop()
        hotKeys?.stop()
        outsideClicks.stop()
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        for observer in sessionObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in lockObservers { DistributedNotificationCenter.default().removeObserver(observer) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
