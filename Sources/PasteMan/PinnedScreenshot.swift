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
    init(presentWindow: @escaping (NSWindow) -> Void = { $0.orderFrontRegardless() }) {
        self.presentWindow = presentWindow
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
        let view = PinnedScreenshotView(image: image)
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
        window.contentView = nil
        windows.removeAll { $0 === window }
    }
    func closeAll() {
        for window in windows {
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
    init(image: ScreenshotImage) {
        self.image = image
        super.init(frame: .zero)
        toolTip = L.t(
            "Drag to move. Double-click to dismiss. Resize from the edges. Right-click to copy or save.",
            "拖动移动，双击关闭钉图，拖拽边缘缩放。右键可复制或保存。")
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
        if onCopy?() != true { showError(L.t("Could not write to the clipboard.", "无法写入剪贴板。")) }
    }
    @objc private func saveImage() {
        Task {
            do { _ = try await ScreenshotFileSaver.save(image.png) } catch { showError(error.localizedDescription) }
        }
    }
    @objc private func resetSize() { onReset?() }
    @objc private func closeImage() { onClose?() }
    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "EasyMacOS"
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }
}
