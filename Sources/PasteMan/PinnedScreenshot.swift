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
    var onCopyText: ((String, String, String) -> Bool)?
    var textRecognizer: any ScreenshotTextRecognizing = SystemScreenshotTextRecognizer.shared
    var barcodeRecognizer: any ScreenshotTextRecognizing = SystemScreenshotBarcodeRecognizer.shared
    var presentTextWindow: (NSPanel) -> Void = { NSApp.activate(); $0.makeKeyAndOrderFront(nil) }
    var presentEditorWindow: (PinnedScreenshotEditor) -> Void = { $0.show() }
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
        view.textRecognizer = textRecognizer
        view.barcodeRecognizer = barcodeRecognizer
        view.presentTextWindow = presentTextWindow
        view.presentEditorWindow = presentEditorWindow
        view.onCopyText = { [weak self] text in self?.onCopyText?(text, sourceID, sourceName) ?? false }
        view.onReset = { [weak window] size in window?.setContentSize(size) }
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
    private var image: PinnedImageStorage
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
    var onReset: ((CGSize) -> Void)?
    var onClose: (() -> Void)?
    private let saveImageData: (Data) async throws -> Bool
    private let reportError: (String) -> Void
    private var saveTask: Task<Void, Never>?
    private var changeTask: Task<Void, Never>?
    private var editor: PinnedScreenshotEditor?
    private var disposed = false
    var textRecognizer: any ScreenshotTextRecognizing = SystemScreenshotTextRecognizer.shared
    var barcodeRecognizer: any ScreenshotTextRecognizing = SystemScreenshotBarcodeRecognizer.shared
    var presentTextWindow: (NSPanel) -> Void = { NSApp.activate(); $0.makeKeyAndOrderFront(nil) }
    var presentEditorWindow: (PinnedScreenshotEditor) -> Void = { $0.show() }
    var onCopyText: ((String) -> Bool)?
    private var textSession: ScreenshotTextSession?
    init(image: PinnedImageStorage, saveImage: @escaping (Data) async throws -> Bool, reportError: @escaping (String) -> Void) {
        self.image = image
        saveImageData = saveImage
        self.reportError = reportError
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.contentsGravity = .resizeAspect
        toolTip = L.t(
            "Drag to move. Double-click to dismiss. Scroll or resize from the edges to zoom. Right-click to rotate, mirror, crop, edit, copy, save, or recognize content.",
            "拖动移动，双击关闭钉图，滚轮或拖拽边缘缩放。右键可旋转、镜像、裁剪、二次编辑、复制、保存或识别内容。")
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
        menu.autoenablesItems = false
        let canRead = !disposed && changeTask == nil && editor == nil
        let canChange = canRead && copyTask == nil && saveTask == nil
        func add(_ title: String, _ action: Selector, to target: NSMenu, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.isEnabled = enabled
            target.addItem(item)
        }
        add(L.t("Copy", "复制"), #selector(copyImage), to: menu, enabled: canRead)
        add(L.t("Save…", "保存…"), #selector(saveImage), to: menu, enabled: canRead)
        menu.addItem(.separator())
        for (title, actions) in [
            (L.t("Rotate", "旋转"), [
                (L.t("Rotate clockwise 90°", "顺时针旋转 90°"), #selector(rotateClockwise)),
                (L.t("Rotate counterclockwise 90°", "逆时针旋转 90°"), #selector(rotateCounterclockwise)),
                (L.t("Rotate 180°", "旋转 180°"), #selector(rotateHalfTurn))]),
            (L.t("Mirror", "镜像"), [
                (L.t("Mirror horizontally", "水平镜像"), #selector(mirrorHorizontally)),
                (L.t("Mirror vertically", "垂直镜像"), #selector(mirrorVertically))]),
        ] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            submenu.autoenablesItems = false
            for (name, action) in actions { add(name, action, to: submenu, enabled: canChange) }
            item.submenu = submenu; item.isEnabled = canChange
            menu.addItem(item)
        }
        add(L.t("Crop pinned image…", "贴图裁剪…"), #selector(cropImage), to: menu, enabled: canChange || editor != nil)
        add(L.t("Edit pinned image…", "二次编辑…"), #selector(editImage), to: menu, enabled: canChange || editor != nil)
        menu.addItem(.separator())
        for (title, action) in [
            (L.t("Recognize text", "识别文字"), #selector(recognizeText)),
            (ScreenshotRecognitionKind.barcodes.title, #selector(recognizeBarcodes)),
        ] {
            add(title, action, to: menu, enabled: canRead)
        }
        menu.addItem(.separator())
        add(L.t("Original size", "恢复原始显示比例"), #selector(resetSize), to: menu, enabled: !disposed)
        add(L.t("Close", "关闭"), #selector(closeImage), to: menu, enabled: !disposed)
        return menu
    }
    @objc private func rotateClockwise() { transform(.clockwise) }
    @objc private func rotateCounterclockwise() { transform(.counterclockwise) }
    @objc private func rotateHalfTurn() { transform(.halfTurn) }
    @objc private func mirrorHorizontally() { transform(.horizontalMirror) }
    @objc private func mirrorVertically() { transform(.verticalMirror) }
    @objc private func cropImage() { beginEditing(.crop) }
    @objc private func editImage() { beginEditing(.annotate) }
    private var canChangeImage: Bool {
        !disposed && changeTask == nil && copyTask == nil && saveTask == nil && editor == nil
    }
    private func closeRecognition() {
        textSession?.close(notify: false); textSession = nil
    }
    private func transform(_ operation: PinnedImageTransform) {
        guard canChangeImage else { return }
        closeRecognition()
        changeTask = Task { [weak self, image] in
            defer { self?.changeTask = nil }
            do {
                let base = try await image.loadImage()
                try Task.checkCancellation()
                let result = try await PinnedImageWorker.shared.transform(base: base, pointSize: image.pointSize, operation: operation)
                try Task.checkCancellation()
                guard let self, !self.disposed else { return }
                self.replaceImage(result)
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, let self, !self.disposed else { return }
                self.reportError(error.localizedDescription)
            }
        }
    }
    private func beginEditing(_ mode: PinnedScreenshotEditor.Mode) {
        if let editor { presentEditorWindow(editor); return }
        guard canChangeImage else { return }
        closeRecognition()
        changeTask = Task { [weak self, image] in
            defer { self?.changeTask = nil }
            do {
                let base = try await image.loadImage()
                try Task.checkCancellation()
                guard let self, !self.disposed else { return }
                let editor = PinnedScreenshotEditor(image: base, pointSize: image.pointSize, mode: mode)
                editor.onClose = { [weak self] in self?.closeEditor() }
                editor.onFinish = { [weak self] in self?.finishEditing($0) }
                self.editor = editor
                self.presentEditorWindow(editor)
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, let self, !self.disposed else { return }
                self.reportError(error.localizedDescription)
            }
        }
    }
    private func closeEditor() {
        editor?.close(); editor = nil
    }
    private func finishEditing(_ output: ScreenshotCoordinator.Output?) {
        guard !disposed, changeTask == nil, let editor, !editor.state.busy else { return }
        editor.canvas.commitText()
        let document = editor.canvas.document
        let annotations = editor.state.history.annotations
        let selection = editor.cropView?.selection
        editor.state.busy = true; editor.state.error = nil; editor.state.layoutChanged?()
        changeTask = Task { [weak self, weak editor] in
            defer { self?.changeTask = nil }
            do {
                let result: PinnedImageStorage
                if let selection {
                    result = try await PinnedImageWorker.shared.crop(base: document.image, pointSize: document.pointSize,
                        selection: selection)
                } else {
                    result = try await PinnedImageWorker.shared.archive(base: document.image,
                        pointSize: document.pointSize, annotations: annotations)
                }
                try Task.checkCancellation()
                if let output {
                    let png = try await result.png()
                    try Task.checkCancellation()
                    switch output {
                    case .copy:
                        let bitmap = try await result.loadImage()
                        try Task.checkCancellation()
                        guard let self, !self.disposed else { return }
                        guard self.onCopy?(ScreenshotImage(image: bitmap, png: png, pointSize: result.pointSize)) == true else {
                            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey:
                                L.t("Could not write to the clipboard. Try again.", "无法写入剪贴板，请重试。")])
                        }
                    case .save:
                        guard let save = self?.saveImageData else { return }
                        let saved = try await save(png)
                        try Task.checkCancellation()
                        if !saved {
                            editor?.state.busy = false; editor?.state.layoutChanged?()
                            return
                        }
                    case .pin: break
                    }
                }
                guard let self, let editor, !self.disposed, self.editor === editor else { return }
                let snappedSelection = selection.map { area in
                    let pixels = ScreenshotGeometry.pixelRect(area, pointSize: document.pointSize,
                        pixelSize: CGSize(width: document.image.width, height: document.image.height))
                    return CGRect(x: pixels.minX * document.pointSize.width / CGFloat(document.image.width),
                        y: pixels.minY * document.pointSize.height / CGFloat(document.image.height),
                        width: result.pointSize.width, height: result.pointSize.height)
                }
                self.replaceImage(result, croppedRegion: snappedSelection)
                self.closeEditor()
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, let self, let editor, !self.disposed, self.editor === editor else { return }
                editor.state.busy = false; editor.state.error = error.localizedDescription; editor.state.layoutChanged?()
            }
        }
    }
    private func replaceImage(_ result: PinnedImageStorage, croppedRegion: CGRect? = nil) {
        let oldSize = image.pointSize
        let scale = bounds.width / oldSize.width
        image = result
        displayRevision += 1; displayTask?.cancel(); displayTask = nil
        displayImage = nil; displayPixels = 0; requestedPixels = 0; layer?.contents = nil
        if let window {
            let oldFrame = window.frame
            let size = CGSize(width: result.pointSize.width * scale, height: result.pointSize.height * scale)
            let origin: CGPoint
            if let croppedRegion {
                origin = CGPoint(x: oldFrame.minX + croppedRegion.minX * scale,
                    y: oldFrame.minY + (oldSize.height - croppedRegion.maxY) * scale)
            } else { origin = CGPoint(x: oldFrame.midX - size.width / 2, y: oldFrame.midY - size.height / 2) }
            window.contentAspectRatio = result.pointSize
            window.contentMinSize = CGSize(width: min(100, result.pointSize.width), height: min(60, result.pointSize.height))
            window.setFrame(CGRect(origin: origin, size: size), display: true)
        }
        requestDisplay()
    }
    @objc private func recognizeText() { recognize(.text) }
    @objc private func recognizeBarcodes() { recognize(.barcodes) }
    private func recognize(_ kind: ScreenshotRecognitionKind) {
        guard !disposed, changeTask == nil, editor == nil else { return }
        if let textSession { textSession.show(); return }
        let session = ScreenshotTextSession(input: .pinned(image), kind: kind,
            recognizer: kind == .text ? textRecognizer : barcodeRecognizer, presentWindow: presentTextWindow)
        session.onCopy = { [weak self] in self?.onCopyText?($0) ?? false }
        session.onClose = { [weak self] _ in self?.textSession = nil }
        textSession = session
        session.show()
    }
    @objc private func copyImage() {
        guard !disposed, copyTask == nil, changeTask == nil, editor == nil else { return }
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
        guard !disposed, saveTask == nil, changeTask == nil, editor == nil else { return }
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
        closeRecognition()
        closeEditor()
        changeTask?.cancel(); changeTask = nil
        onCopyText = nil
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
    @objc private func resetSize() { onReset?(image.pointSize) }
    @objc private func closeImage() { onClose?() }
    static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "EasyMacOS"
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }
}
