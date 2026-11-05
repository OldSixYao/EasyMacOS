import AppKit
import UniformTypeIdentifiers

@MainActor enum ScreenshotFileSaver {
    static func save(_ png: Data) async throws -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        panel.nameFieldStringValue = "Screenshot_\(formatter.string(from: Date())).png"
        NSApp.activate()
        try Task.checkCancellation()
        let response = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                panel.begin { continuation.resume(returning: $0) }
            }
        } onCancel: {
            Task { @MainActor in panel.cancel(nil) }
        }
        try Task.checkCancellation()
        guard response == .OK, let url = panel.url else { return false }
        try await Task.detached(priority: .userInitiated) { try png.write(to: url, options: .atomic) }.value
        return true
    }
}

@MainActor final class PinnedScreenshotManager: NSObject, NSWindowDelegate {
    private(set) var windows: [NSWindow] = []
    private let presentWindow: (NSWindow) -> Void
    private let saveImage: (Data) async throws -> Bool
    private let reportError: (String) -> Void
    init(
        presentWindow: @escaping (NSWindow) -> Void = { $0.orderFrontRegardless() },
        saveImage: @escaping (Data) async throws -> Bool = { try await ScreenshotFileSaver.save($0) },
        reportError: @escaping (String) -> Void = { PinnedScreenshotView.showError($0) }
    ) {
        self.presentWindow = presentWindow
        self.saveImage = saveImage
        self.reportError = reportError
        super.init()
    }
    var onCopy: ((ScreenshotImage, String, String) -> Bool)?
    var count: Int { windows.count }

    func show(_ image: ScreenshotImage, sourceID: String, sourceName: String, origin: CGPoint?) {
        let window = NSPanel(
            contentRect: CGRect(origin: origin ?? .zero, size: image.pointSize),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false)
        window.title = L.t("Pinned screenshot", "钉图")
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = false
        window.contentAspectRatio = image.pointSize
        window.contentMinSize = CGSize(width: min(100, image.pointSize.width), height: min(60, image.pointSize.height))
        window.delegate = self
        let view = PinnedScreenshotView(image: image, saveImage: saveImage, reportError: reportError)
        view.onCopy = { [weak self] in self?.onCopy?(image, sourceID, sourceName) ?? false }
        view.onReset = { [weak window] in window?.setContentSize(image.pointSize) }
        view.onClose = { [weak window] in window?.close() }
        window.contentView = view
        // Fit initial large captures onto the destination screen without changing exported pixels.
        let screen = NSScreen.screens.first { $0.frame.contains(origin ?? NSEvent.mouseLocation) } ?? NSScreen.main
        if let screen {
            let available = screen.visibleFrame.insetBy(dx: 16, dy: 24)
            let ratio = min(1, available.width / image.pointSize.width, available.height / image.pointSize.height)
            window.setContentSize(CGSize(width: image.pointSize.width * ratio, height: image.pointSize.height * ratio))
            var frame = window.frame
            frame.origin.x = max(available.minX, min(frame.minX, available.maxX - frame.width))
            frame.origin.y = max(available.minY, min(frame.minY, available.maxY - frame.height))
            window.setFrame(frame, display: false)
        }
        windows.append(window)
        presentWindow(window)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        (window.contentView as? PinnedScreenshotView)?.dispose()
        window.contentView = nil
        windows.removeAll { $0 === window }
    }
    func closeAll() {
        for window in windows {
            (window.contentView as? PinnedScreenshotView)?.dispose()
            window.contentView = nil
            window.close()
        }
        windows.removeAll()
    }
}

@MainActor private final class PinnedScreenshotView: NSView {
    let image: ScreenshotImage
    var onCopy: (() -> Bool)?
    var onReset: (() -> Void)?
    var onClose: (() -> Void)?
    private let saveImageData: (Data) async throws -> Bool
    private let reportError: (String) -> Void
    private var saveTask: Task<Void, Never>?
    private var disposed = false
    init(image: ScreenshotImage, saveImage: @escaping (Data) async throws -> Bool, reportError: @escaping (String) -> Void) {
        self.image = image
        saveImageData = saveImage
        self.reportError = reportError
        super.init(frame: .zero)
        toolTip = L.t(
            "Drag to move. Double-click to dismiss. Scroll or resize from the edges to zoom. Right-click to copy or save.",
            "拖动移动，双击关闭钉图，滚轮或拖拽边缘缩放。右键可复制或保存。")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onClose?()
        } else if event.clickCount == 1 {
            window?.performDrag(with: event)
        }
    }
    override func scrollWheel(with event: NSEvent) {
        guard let window, event.momentumPhase.isEmpty,
            event.scrollingDeltaY.isFinite, event.scrollingDeltaY != 0,
            bounds.width > 0, bounds.height > 0
        else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }

        // Precise devices report point deltas; wheel mice report discrete steps.
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1)
        let currentScale = bounds.width / image.pointSize.width
        let minimumScale = max(
            0.1, window.contentMinSize.width / image.pointSize.width,
            window.contentMinSize.height / image.pointSize.height)
        let scale = min(8, max(minimumScale, currentScale * exp(max(-0.5, min(0.5, delta)))))
        guard abs(scale - currentScale) > 0.000001 else { return }

        let size = CGSize(width: image.pointSize.width * scale, height: image.pointSize.height * scale)
        let anchor = window.convertPoint(toScreen: event.locationInWindow)
        let fraction = CGPoint(x: (point.x - bounds.minX) / bounds.width, y: (point.y - bounds.minY) / bounds.height)
        // Keep the image point beneath the pointer stationary while resizing the borderless panel.
        let frame = CGRect(
            x: anchor.x - fraction.x * size.width, y: anchor.y - fraction.y * size.height,
            width: size.width, height: size.height)
        window.setFrame(frame, display: true)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .high
        context.draw(image.image, in: bounds)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [
            (L.t("Copy", "复制"), #selector(copyImage)), (L.t("Save…", "保存…"), #selector(saveImage)),
            (L.t("Original size", "恢复原始显示比例"), #selector(resetSize)), (L.t("Close", "关闭"), #selector(closeImage)),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }
    @objc private func copyImage() {
        if onCopy?() != true { reportError(L.t("Could not write to the clipboard.", "无法写入剪贴板。")) }
    }
    @objc private func saveImage() {
        guard !disposed, saveTask == nil else { return }
        saveTask = Task { [weak self, saveImageData, png = image.png] in
            defer { self?.saveTask = nil }
            do {
                try Task.checkCancellation()
                _ = try await saveImageData(png)
            } catch is CancellationError {
                // 关闭钉图会取消保存，不再弹出错误或重新激活应用。
            } catch {
                guard !Task.isCancelled, let self, !self.disposed else { return }
                self.reportError(error.localizedDescription)
            }
        }
    }
    func dispose() {
        disposed = true
        saveTask?.cancel()
        saveTask = nil
        onCopy = nil
        onReset = nil
        onClose = nil
    }
    @objc private func resetSize() { onReset?() }
    @objc private func closeImage() { onClose?() }
    static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "EasyMacOS"
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }
}
