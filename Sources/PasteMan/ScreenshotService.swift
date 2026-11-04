import AppKit
import ScreenCaptureKit

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
    enum Phase: Equatable { case idle, capturing, selecting, editing, exporting }
    private(set) var phase: Phase = .idle
    private(set) var selectedScreen: CGDirectDisplayID?
    private(set) var windows: [NSPanel] = []
    private var captureTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var generation = 0
    private var saving = false
    private var sourceID = ""
    private var sourceName = ""
    private let captureService: any ScreenCapturing
    private let presentWindow: (NSPanel) -> Void
    private let saveImage: (Data) async throws -> Bool
    let pins: PinnedScreenshotManager
    var onCopy: ((ScreenshotImage, String, String) -> Bool)?
    var onError: ((String) -> Void)?
    var onCopyColor: ((String) -> Bool)?
    var isActive: Bool { phase != .idle }

    init(
        captureService: any ScreenCapturing = SystemScreenCapture(),
        pins: PinnedScreenshotManager = PinnedScreenshotManager(),
        presentWindow: @escaping (NSPanel) -> Void = { $0.makeKeyAndOrderFront(nil) },
        saveImage: @escaping (Data) async throws -> Bool = { try await ScreenshotFileSaver.save($0) }
    ) {
        self.captureService = captureService
        self.presentWindow = presentWindow
        self.saveImage = saveImage
        self.pins = pins
        pins.onCopy = { [weak self] image, id, name in self?.onCopy?(image, id, name) ?? false }
    }

    func start(screens: [ScreenshotScreen], sourceID: String, sourceName: String) {
        guard !isActive else { return }
        phase = .capturing
        generation += 1
        let version = generation
        self.sourceID = sourceID
        self.sourceName = sourceName
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
            MainActor.assumeIsolated { self?.cancel() }
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
            panel.onCancel = { [weak self] in self?.cancel() }
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hasShadow = false
            panel.isOpaque = true
            panel.backgroundColor = .black
            let view = ScreenshotOverlay(capture: capture, coordinator: self)
            panel.contentView = view
            windows.append(panel)
        }
        let point = NSEvent.mouseLocation
        for window in windows where !window.frame.contains(point) { presentWindow(window) }
        if let active = windows.first(where: { $0.frame.contains(point) }) ?? windows.first { presentWindow(active) }
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
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        for window in windows {
            (window.contentView as? ScreenshotOverlay)?.dispose()
            window.contentView = nil
            window.close()
        }
        windows.removeAll()
        selectedScreen = nil
        saving = false
        phase = .idle
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
                case .pin:
                    self.pins.show(
                        image, sourceID: self.sourceID, sourceName: self.sourceName,
                        origin: view.window?.convertToScreen(
                            NSRect(
                                x: view.selection.minX,
                                y: view.bounds.height - view.selection.maxY, width: 0, height: 0)
                        ).origin)
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
