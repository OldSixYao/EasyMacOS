import AppKit
import PasteManCore
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
    private var closingAll = false
    private var displayByteLimit = 32 * 1024 * 1024
    private var pressureSource: DispatchSourceMemoryPressure?
    init(
        presentWindow: @escaping (NSWindow) -> Void = { $0.orderFrontRegardless() },
        saveImage: @escaping (Data) async throws -> Bool = { try await ScreenshotFileSaver.save($0) },
        reportError: @escaping (String) -> Void = { PinnedScreenshotView.showError($0) }
    ) {
        self.presentWindow = presentWindow
        self.saveImage = saveImage
        self.reportError = reportError
        super.init()
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let pressure = self.pressureSource else { return }
                self.applyMemoryPressure(pressure.data)
            }
        }
        pressure.resume()
        pressureSource = pressure
    }
    deinit { pressureSource?.cancel() }
    var onCopy: ((ScreenshotImage, String, String) -> Bool)?
    var count: Int { windows.count }
    var cachedDisplayByteCount: Int {
        windows.reduce(0) { $0 + (($1.contentView as? PinnedScreenshotView)?.displayByteCount ?? 0) }
    }
    var displayDecodeCount: Int {
        windows.reduce(0) { $0 + (($1.contentView as? PinnedScreenshotView)?.displayDecodeCount ?? 0) }
    }
    func applyMemoryPressure(_ pressure: DispatchSource.MemoryPressureEvent) {
        displayByteLimit = pressure.contains(.critical) ? 4 * 1024 * 1024
            : pressure.contains(.warning) ? 8 * 1024 * 1024 : 32 * 1024 * 1024
        rebalanceDisplayBudget()
    }
    func waitForDisplays() async {
        for window in windows { await (window.contentView as? PinnedScreenshotView)?.waitForDisplay() }
    }

    func show(_ image: ScreenshotImage, sourceID: String, sourceName: String, origin: CGPoint?) {
        show(PinnedImageStorage(png: image.png, pointSize: image.pointSize), sourceID: sourceID, sourceName: sourceName, origin: origin)
    }
    func show(_ image: PinnedImageStorage, sourceID: String, sourceName: String, origin: CGPoint?) {
        let screen = NSScreen.screens.first { $0.frame.contains(origin ?? NSEvent.mouseLocation) } ?? NSScreen.main
        var initialFrame = CGRect(origin: origin ?? .zero, size: image.pointSize)
        if let screen {
            let available = screen.visibleFrame.insetBy(dx: 16, dy: 24)
            let ratio = min(1, available.width / image.pointSize.width, available.height / image.pointSize.height)
            initialFrame.size = CGSize(width: image.pointSize.width * ratio, height: image.pointSize.height * ratio)
            initialFrame.origin.x = max(available.minX, min(initialFrame.minX, available.maxX - initialFrame.width))
            initialFrame.origin.y = max(available.minY, min(initialFrame.minY, available.maxY - initialFrame.height))
        }
        let window = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: true)
        window.title = L.t("Pinned screenshot", "钉图")
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hidesOnDeactivate = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = false
        window.contentAspectRatio = image.pointSize
        window.contentMinSize = CGSize(width: min(100, image.pointSize.width), height: min(60, image.pointSize.height))
        window.delegate = self
        let view = PinnedScreenshotView(image: image, saveImage: saveImage, reportError: reportError)
        view.frame = CGRect(origin: .zero, size: initialFrame.size)
        view.onCopy = { [weak self] value in self?.onCopy?(value, sourceID, sourceName) ?? false }
        view.onReset = { [weak window] in window?.setContentSize(image.pointSize) }
        view.onClose = { [weak window] in window?.close() }
        window.contentView = view
        windows.append(window)
        rebalanceDisplayBudget()
        presentWindow(window)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        (window.contentView as? PinnedScreenshotView)?.dispose()
        window.contentView = nil
        windows.removeAll { $0 === window }
        if !closingAll { rebalanceDisplayBudget() }
    }
    private func rebalanceDisplayBudget() {
        // 每个窗口只持有当前显示位图；图层和预算统计引用同一对象，不再保留历史尺寸缓存。
        let rawDimension = Int(sqrt(Double(displayByteLimit / max(1, windows.count) / 4)))
        // 行宽按六十四字节对齐后仍在每个窗口的份额内。
        let dimension = min(4096, max(1, rawDimension / 16 * 16))
        for window in windows { (window.contentView as? PinnedScreenshotView)?.setPixelLimit(dimension) }
    }
    func closeAll() {
        closingAll = true
        defer { closingAll = false }
        for window in windows {
            (window.contentView as? PinnedScreenshotView)?.dispose()
            window.contentView = nil
            window.close()
        }
        windows.removeAll()
    }
}

@MainActor private final class PinnedScreenshotView: NSView {
    let image: PinnedImageStorage
    private var displayImage: CGImage?
    private var displayPixels = 0
    private var displayRevision = 0
    private(set) var displayDecodeCount = 0
    var displayByteCount: Int { displayImage.map { $0.bytesPerRow * $0.height } ?? 0 }
    private var displayTask: Task<Void, Never>?
    private var copyTask: Task<Void, Never>?
    private var pixelLimit = 2048
    private var requestedPixels = 0
    var onCopy: ((ScreenshotImage) -> Bool)?
    var onReset: (() -> Void)?
    var onClose: (() -> Void)?
    private let saveImageData: (Data) async throws -> Bool
    private let reportError: (String) -> Void
    private var saveTask: Task<Void, Never>?
    private var disposed = false
    init(image: PinnedImageStorage, saveImage: @escaping (Data) async throws -> Bool, reportError: @escaping (String) -> Void) {
        self.image = image
        saveImageData = saveImage
        self.reportError = reportError
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.contentsGravity = .resizeAspect
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
    func setPixelLimit(_ limit: Int) {
        guard pixelLimit != limit else { requestDisplay(); return }
        pixelLimit = limit
        if displayPixels > limit {
            // 预算缩小时同步释放图层引用，异步补图期间不会把旧像素藏在预算外。
            layer?.contents = nil
            displayImage = nil
            displayPixels = 0
        }
        requestDisplay()
    }
    func waitForDisplay() async { await displayTask?.value }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !disposed { requestDisplay() }
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if !disposed { requestDisplay() }
    }
    private func requestDisplay() {
        guard !disposed else { return }
        let desired = max(1, Int(ceil(max(bounds.width, bounds.height) * (window?.backingScaleFactor ?? 2))))
        let pixels = min(pixelLimit, ((desired + 127) / 128) * 128)
        // 尺寸差距不足两倍时继续复用；明显缩小才延迟换图，减少拖动期间反复分配。
        let shrinking = displayImage.map { max($0.width, $0.height) >= pixels * 2 } ?? false
        if displayImage != nil, displayPixels >= pixels, displayPixels <= pixelLimit, !shrinking {
            if displayTask != nil {
                displayRevision += 1
                displayTask?.cancel()
                displayTask = nil
            }
            return
        }
        if pixels == requestedPixels, displayTask != nil { return }
        displayTask?.cancel()
        displayRevision += 1
        let revision = displayRevision
        requestedPixels = pixels
        let deferResize = displayImage != nil
        displayTask = Task { [weak self, image] in
            do {
                // 缩小时多等待片刻；若随即放大，上面的复用分支会取消尚未开始的缩小。
                if deferResize { try await Task.sleep(for: .milliseconds(shrinking ? 180 : 60)) }
                try Task.checkCancellation()
                self?.displayDecodeCount += 1
                let bitmap = try await image.display(maximumPixels: pixels)
                try Task.checkCancellation()
                guard let self, !self.disposed, self.displayRevision == revision else { return }
                self.displayImage = bitmap
                self.displayPixels = pixels
                // 直接替换图层内容，旧位图不等待下一次绘制才退出预算。
                self.layer?.contents = bitmap
                self.displayTask = nil
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, let self, !self.disposed, self.displayRevision == revision else { return }
                self.displayTask = nil
                self.reportError(error.localizedDescription)
            }
        }
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.contents = displayImage
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
        guard !disposed, copyTask == nil else { return }
        copyTask = Task { [weak self, image] in
            defer { self?.copyTask = nil }
            do {
                let png = try await image.png()
                let bitmap = try await image.loadImage()
                try Task.checkCancellation()
                guard let self, !self.disposed else { return }
                if self.onCopy?(ScreenshotImage(image: bitmap, png: png, pointSize: image.pointSize)) != true {
                    self.reportError(L.t("Could not write to the clipboard.", "无法写入剪贴板。"))
                }
            } catch is CancellationError {} catch {
                guard let self, !self.disposed else { return }
                self.reportError(error.localizedDescription)
            }
        }
    }
    @objc private func saveImage() {
        guard !disposed, saveTask == nil else { return }
        saveTask = Task { [weak self, saveImageData, image] in
            defer { self?.saveTask = nil }
            do {
                try Task.checkCancellation()
                let png = try await image.png()
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
        displayRevision += 1
        layer?.contents = nil
        displayImage = nil
        layer?.removeAllAnimations()
        displayTask?.cancel()
        displayTask = nil
        copyTask?.cancel()
        copyTask = nil
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
