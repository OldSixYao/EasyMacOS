import AppKit
import ScreenCaptureKit
import PasteManCore

struct ScreenshotScreen: Sendable {
    let id: CGDirectDisplayID
    let frame: CGRect
    let scale: CGFloat
}
struct CapturedScreen: Sendable {
    let screen: ScreenshotScreen
    let image: CGImage
}

@MainActor protocol ScreenCapturing {
    func capture(_ screens: [ScreenshotScreen]) async throws -> [CapturedScreen]
}

@MainActor struct SystemScreenCapture: ScreenCapturing {
    func capture(_ screens: [ScreenshotScreen]) async throws -> [CapturedScreen] {
        let interval = PerformanceTrace.signposter.beginInterval("SystemScreenCapture", id: PerformanceTrace.signposter.makeSignpostID())
        defer { PerformanceTrace.signposter.endInterval("SystemScreenCapture", interval) }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var result: [CapturedScreen] = []
        var pixels = 0
        for screen in screens {
            try Task.checkCancellation()
            guard let display = content.displays.first(where: { $0.displayID == screen.id }) else {
                throw ScreenshotImageError.captureUnavailable
            }
            let width = Int(screen.frame.width * screen.scale)
            let height = Int(screen.frame.height * screen.scale)
            guard width > 0, height > 0, width <= (100_000_000 - pixels) / height else {
                throw ScreenshotImageError.allocationFailed
            }
            pixels += width * height
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = width
            configuration.height = height
            configuration.showsCursor = false
            configuration.captureResolution = .best
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.colorSpaceName = CGColorSpace.sRGB
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            try Task.checkCancellation()
            result.append(CapturedScreen(screen: screen, image: image))
        }
        return result
    }
}

@MainActor final class ScreenshotCoordinator {
    enum Phase: Equatable { case idle, capturing, selecting, editing, longCapturing, longEditing, exporting }
    private(set) var phase: Phase = .idle
    private(set) var selectedScreen: CGDirectDisplayID?
    private(set) var windows: [NSPanel] = []
    private var captureTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private var longEscapeMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var generation = 0
    private var saving = false
    private var sourceID = ""
    private var sourceName = ""
    private let captureService: any ScreenCapturing
    private let presentWindow: (NSPanel) -> Void
    private let saveImage: (Data) async throws -> Bool
    private let presentLongWindow: (LongScreenshotEditor) -> Void
    private let presentLongControls: (NSPanel) -> Void
    let longCapture: LongScreenshotCoordinator
    private(set) var longEditor: LongScreenshotEditor?
    private var longControls: LongScreenshotControls?
    private var prefersLongScreenshot = false
    var onLongScrollSuspension: ((Bool) -> Void)?
    var validateLongAccess: () -> Bool = {
        let screen = CGPreflightScreenCaptureAccess()
        let accessibility = AXIsProcessTrusted() && CGPreflightPostEventAccess()
        if !screen { _ = CGRequestScreenCaptureAccess() }
        if !accessibility { FinderRenameAccess.request() }
        return screen && accessibility
    }
    let pins: PinnedScreenshotManager
    var onCopy: ((ScreenshotImage, String, String) -> Bool)?
    var onError: ((String) -> Void)?
    var onCopyColor: ((String) -> Bool)?
    var isActive: Bool { phase != .idle }
    var isEnabled = true {
        didSet { if !isEnabled { cancel() } }
    }

    init(
        captureService: any ScreenCapturing = SystemScreenCapture(),
        pins: PinnedScreenshotManager = PinnedScreenshotManager(),
        presentWindow: @escaping (NSPanel) -> Void = { $0.makeKeyAndOrderFront(nil) },
        saveImage: @escaping (Data) async throws -> Bool = { try await ScreenshotFileSaver.save($0) },
        longCapture: LongScreenshotCoordinator = LongScreenshotCoordinator(),
        presentLongWindow: @escaping (LongScreenshotEditor) -> Void = { $0.show() },
        presentLongControls: @escaping (NSPanel) -> Void = { $0.orderFrontRegardless() }
    ) {
        self.captureService = captureService
        self.presentWindow = presentWindow
        self.saveImage = saveImage
        self.pins = pins
        self.longCapture = longCapture
        self.presentLongWindow = presentLongWindow
        self.presentLongControls = presentLongControls
        pins.onCopy = { [weak self] image, id, name in self?.onCopy?(image, id, name) ?? false }
        longCapture.onScrollSuspension = { [weak self] in self?.onLongScrollSuspension?($0) }
        longCapture.onProgress = { [weak self] progress in
            self?.longControls?.state.width = progress.width
            self?.longControls?.state.height = progress.height
        }
        longCapture.onFinish = { [weak self] document, reason, target in
            self?.presentLongEditor(document, reason: reason, target: target)
        }
    }

    func start(screens: [ScreenshotScreen], sourceID: String, sourceName: String, prefersLongScreenshot: Bool = false) {
        guard isEnabled, !isActive else { return }
        phase = .capturing
        generation += 1
        let version = generation
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.prefersLongScreenshot = prefersLongScreenshot
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event }
            if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.hasMarkedText() { return event }
            // Saving uses a system sheet; let Escape dismiss that sheet first.
            if self.saving { return event }
            self.cancel()
            return nil
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.phase == .longCapturing { self.longCapture.stop(reason: LongScreenshotError.targetChanged.localizedDescription) }
                else if self.longEditor == nil { self.cancel() }
            }
        }
        captureTask = Task { [weak self, captureService] in
            do {
                let captures = try await captureService.capture(screens)
                guard let self, self.generation == version, !Task.isCancelled else { return }
                guard !captures.isEmpty else { throw ScreenshotImageError.captureUnavailable }
                self.phase = .selecting
                self.present(captures)
            } catch is CancellationError {
                guard let self, self.generation == version else { return }
                self.cancel()
            } catch {
                guard let self, self.generation == version else { return }
                self.cancel()
                self.onError?(error.localizedDescription)
            }
        }
    }

    private func present(_ captures: [CapturedScreen]) {
        for capture in captures {
            let panel = ScreenshotPanel(
                contentRect: capture.screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            // 全屏冻结画面必须原位出现，系统缩放动画会让整个桌面看起来抖动。
            panel.animationBehavior = .none
            panel.onCancel = { [weak self] in self?.cancel() }
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hasShadow = false
            panel.isOpaque = true
            panel.backgroundColor = .black
            let view = ScreenshotOverlay(capture: capture, coordinator: self)
            view.state.prefersLongScreenshot = prefersLongScreenshot
            panel.contentView = view
            windows.append(panel)
        }
        let point = NSEvent.mouseLocation
        let active = windows.first(where: { $0.frame.contains(point) }) ?? windows.first
        for window in windows where window !== active { presentWindow(window) }
        if let active { presentWindow(active) }
    }

    func claim(_ id: CGDirectDisplayID) -> Bool {
        guard phase == .selecting || phase == .editing else { return false }
        guard selectedScreen == nil || selectedScreen == id else { return false }
        selectedScreen = id
        return true
    }
    func didSelect() { phase = .editing }
    func reselect() {
        guard phase == .editing || phase == .selecting else { return }
        selectedScreen = nil
        phase = .selecting
        for window in windows { (window.contentView as? ScreenshotOverlay)?.resetSelection() }
    }
    func cancel() {
        generation += 1
        captureTask?.cancel()
        captureTask = nil
        exportTask?.cancel()
        exportTask = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        removeLongEscapeMonitor()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        longCapture.cancel()
        longControls?.close(); longControls = nil
        longEditor?.close(); longEditor = nil
        closeSelectionWindows()
        selectedScreen = nil
        saving = false
        phase = .idle
    }

    private func closeSelectionWindows() {
        for window in windows {
            (window.contentView as? ScreenshotOverlay)?.dispose()
            (window.contentView as? ScreenshotOverlay)?.releaseDisplayResources()
            window.contentView = nil
            window.close()
        }
        windows.removeAll()
    }

    func startLongScreenshot(from view: ScreenshotOverlay) {
        guard phase == .editing, view.state.canAdjust, view.selection.width >= 80, view.selection.height >= 80 else {
            view.state.error = LongScreenshotError.selection.localizedDescription
            view.showToolbar(); return
        }
        guard validateLongAccess() else {
            cancel(); onError?(LongScreenshotError.permission.localizedDescription); return
        }
        let region = LongScreenshotRegion(screen: view.capture.screen, selection: view.selection,
            desktopTop: NSScreen.screens.first?.frame.maxY ?? view.capture.screen.frame.maxY)
        phase = .longCapturing
        closeSelectionWindows()
        longControls = LongScreenshotControls(region: region, stop: { [weak self] in self?.longCapture.stop() },
            cancel: { [weak self] in self?.cancel() }, present: presentLongControls)
        longEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancel() }
        }
        longCapture.start(region)
    }

    private func presentLongEditor(_ document: LongScreenshotDocument?, reason: String?, target: LongScreenshotTarget?) {
        guard phase == .longCapturing else { return }
        removeLongEscapeMonitor()
        longControls?.close(); longControls = nil
        guard let document else { cancel(); if let reason { onError?(reason) }; return }
        if let target { sourceID = target.sourceID; sourceName = target.sourceName }
        phase = .longEditing
        let notice = reason.map { message in
            message + "\n" + L.t("Previously captured content is available for editing.", "此前可靠的截取内容已保留，可继续编辑。")
        }
        let editor = LongScreenshotEditor(document: document, notice: notice)
        longEditor = editor
        editor.onClose = { [weak self] in self?.cancel() }
        editor.onOutput = { [weak self] in self?.finishLongScreenshot($0) }
        presentLongWindow(editor)
    }

    private func removeLongEscapeMonitor() {
        if let longEscapeMonitor { NSEvent.removeMonitor(longEscapeMonitor) }
        longEscapeMonitor = nil
    }

    func showLongScreenshotEditor() {
        guard let longEditor else { return }
        presentLongWindow(longEditor)
    }

    func stopLongScreenshot() {
        guard phase == .longCapturing else { return }
        longControls?.state.stopping = true
        longCapture.stop()
    }

    func finishLongScreenshot(_ output: Output) {
        guard phase == .longEditing, let editor = longEditor else { return }
        editor.canvas.commitText()
        let document = editor.document
        let annotations = editor.state.history.annotations
        let version = generation
        phase = .exporting; editor.state.busy = true; editor.state.error = nil
        editor.state.layoutChanged?()
        exportTask = Task { [weak self, weak editor, document] in
            do {
                if output == .pin {
                    let archive = try await PinnedImageWorker.shared.archive(base: document.image,
                        pointSize: document.pointSize, annotations: annotations)
                    guard let self, let editor, self.generation == version, !Task.isCancelled else { return }
                    self.pins.show(archive, sourceID: self.sourceID, sourceName: self.sourceName, origin: editor.window.frame.origin)
                    self.cancel(); return
                }
                let image = try await ScreenshotRenderWorker.shared.export(base: document.image,
                    pointSize: document.pointSize, annotations: annotations)
                guard let self, let editor, self.generation == version, !Task.isCancelled else { return }
                switch output {
                case .copy:
                    guard self.onCopy?(image, self.sourceID, self.sourceName) == true else {
                        throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey:
                            L.t("Could not write to the clipboard. Try again.", "无法写入剪贴板，请重试。")])
                    }
                case .save:
                    self.saving = true
                    let saved = try await self.saveImage(image.png)
                    guard self.generation == version, !Task.isCancelled else { return }
                    self.saving = false
                    if !saved { self.restoreLongEditor(editor); return }
                case .pin: break
                }
                self.cancel()
            } catch {
                guard let self, let editor, self.generation == version else { return }
                self.restoreLongEditor(editor)
                editor.state.error = error.localizedDescription; editor.state.layoutChanged?()
            }
        }
    }
    private func restoreLongEditor(_ editor: LongScreenshotEditor) {
        saving = false; phase = .longEditing; editor.state.busy = false
        editor.state.layoutChanged?(); presentLongWindow(editor)
    }

    enum Output { case copy, save, pin }
    func finish(_ output: Output, from view: ScreenshotOverlay) {
        guard phase == .editing else { return }
        view.commitText()
        guard let base = view.selectedImage else { return }
        let size = view.selection.size
        let annotations = view.state.history.annotations
        let version = generation
        phase = .exporting
        view.state.busy = true
        view.showToolbar()
        exportTask = Task { [weak self, weak view] in
            do {
                if output == .pin {
                    let archive = try await PinnedImageWorker.shared.archive(base: base, pointSize: size, annotations: annotations)
                    guard let self, let view, self.generation == version, !Task.isCancelled else { return }
                    self.pins.show(archive, sourceID: self.sourceID, sourceName: self.sourceName,
                        origin: view.window?.convertToScreen(NSRect(x: view.selection.minX,
                            y: view.bounds.height - view.selection.maxY, width: 0, height: 0)).origin)
                    self.cancel()
                    return
                }
                let image = try await ScreenshotRenderWorker.shared.export(
                    base: base, pointSize: size, annotations: annotations)
                guard let self, let view, self.generation == version, !Task.isCancelled else { return }
                switch output {
                case .copy:
                    guard self.onCopy?(image, self.sourceID, self.sourceName) == true else {
                        throw CocoaError(
                            .fileWriteUnknown,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    L.t("Could not write to the clipboard. Try again.", "无法写入剪贴板，请重试。")
                            ])
                    }
                case .save:
                    // Hide the screen-level overlays so the system save panel is accessible.
                    for window in self.windows { window.orderOut(nil) }
                    self.saving = true
                    let saved = try await self.saveImage(image.png)
                    guard self.generation == version, !Task.isCancelled else { return }
                    self.saving = false
                    if !saved {
                        self.restoreEditor(view)
                        return
                    }
                case .pin: break
                }
                self.cancel()
            } catch {
                guard let self, let view, self.generation == version else { return }
                self.restoreEditor(view)
                view.state.error = error.localizedDescription
                view.showToolbar()
            }
        }
    }
    private func restoreEditor(_ view: ScreenshotOverlay) {
        saving = false
        phase = .editing
        view.state.busy = false
        view.showToolbar()
        for window in windows { presentWindow(window) }
    }
}

@MainActor final class ScreenshotPanel: NSPanel {
    var onCancel: (() -> Void)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown {
            onCancel?()
            return
        }
        super.sendEvent(event)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
