import AppKit
import SwiftUI

@MainActor final class PinnedScreenshotEditor: NSObject, NSWindowDelegate {
    enum Mode { case crop, annotate }
    let mode: Mode
    let state = ScreenshotEditorState()
    let window: NSPanel
    let canvas: LongScreenshotCanvas
    let cropView: PinnedScreenshotCropView?
    let scrollView = NSScrollView()
    private let container = PinnedScreenshotPreviewContainer()
    private var header: NSHostingView<PinnedScreenshotEditorHeader>?
    private var boundsObserver: NSObjectProtocol?
    private let hoverTip = ScreenshotHoverTip()
    private(set) var zoom: CGFloat = 1
    var onFinish: ((ScreenshotCoordinator.Output?) -> Void)?
    var onClose: (() -> Void)?

    init(image: CGImage, pointSize: CGSize, mode: Mode) {
        self.mode = mode
        canvas = LongScreenshotCanvas(document: PinnedScreenshotDocument(image: image, pointSize: pointSize))
        cropView = mode == .crop ? PinnedScreenshotCropView(pointSize: pointSize) : nil
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let size = CGSize(width: min(920, screen.width - 40), height: min(660, screen.height - 40))
        let panel = PinnedScreenshotEditorPanel(contentRect: CGRect(x: screen.midX - size.width / 2,
            y: screen.midY - size.height / 2, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window = panel
        super.init()
        window.title = mode == .crop ? L.t("Crop pinned image", "贴图裁剪") : L.t("Edit pinned image", "二次编辑")
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = .floating
        window.delegate = self
        window.acceptsMouseMovedEvents = true
        state.isPinnedEditor = true; state.tool = .rectangle
        window.minSize = CGSize(width: mode == .crop ? 420 : state.toolbarWidth + 24, height: 320)
        state.action = { [weak self] in self?.perform($0) }
        state.layoutChanged = { [weak self] in self?.layout() }
        state.hoverChanged = { [weak self] in
            guard let self else { return }
            self.hoverTip.show($0, in: self.window)
        }
        panel.onCancel = { [weak self] in self?.perform(.cancel) }
        panel.onConfirm = { [weak self] in self?.perform(.confirm) }
        canvas.state = state
        canvas.onAction = { [weak self] in self?.perform($0) }
        canvas.onHistoryChanged = { [weak self] in self?.canvas.invalidateTiles() }
        canvas.setAccessibilityLabel(L.t("Pinned image annotation canvas", "贴图标注画布"))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .legacy
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        container.addSubview(canvas)
        if let cropView {
            cropView.isBusy = { [weak state] in state?.busy != false }
            cropView.autoresizingMask = [.width, .height]
            cropView.onConfirm = { [weak self] in self?.perform(.confirm) }
            cropView.onCancel = { [weak self] in self?.perform(.cancel) }
            canvas.addSubview(cropView)
        }
        scrollView.documentView = container
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView, queue: .main) { [weak canvas] _ in
                MainActor.assumeIsolated { canvas?.requestVisibleTiles() }
            }
        window.contentView?.addSubview(scrollView)
        let header = NSHostingView(rootView: PinnedScreenshotEditorHeader(state: state, mode: mode,
            width: image.width, height: image.height))
        self.header = header
        window.contentView?.addSubview(header)
        layout()
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(cropView ?? canvas)
        canvas.requestVisibleTiles()
    }

    func windowDidResize(_ notification: Notification) { layout() }
    func windowDidResignKey(_ notification: Notification) { hoverTip.hide() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { perform(.cancel); return false }

    private func layout() {
        hoverTip.hide()
        guard let content = window.contentView else { return }
        let cropHeaderHeight: CGFloat = 46 + (state.busy ? 36 : 0) + (state.error == nil ? 0 : 68)
        let headerHeight = (mode == .crop ? cropHeaderHeight : state.toolbarHeight) + 32
        header?.frame = CGRect(x: 0, y: max(0, content.bounds.height - headerHeight),
            width: content.bounds.width, height: headerHeight)
        scrollView.frame = CGRect(x: 0, y: 0, width: content.bounds.width,
            height: max(1, content.bounds.height - headerHeight))
        let pointSize = canvas.document.pointSize
        let oldZoom = zoom
        let oldOrigin = scrollView.contentView.bounds.origin
        for _ in 0..<8 {
            let viewport = scrollView.contentSize
            switch state.previewMode {
            case .actual: zoom = 1
            case .width: zoom = viewport.width / pointSize.width
            case .fill: zoom = min(viewport.width / pointSize.width, viewport.height / pointSize.height)
            }
            canvas.zoom = zoom
            let size = CGSize(width: pointSize.width * zoom, height: pointSize.height * zoom)
            container.setFrameSize(CGSize(width: max(viewport.width, size.width), height: max(viewport.height, size.height)))
            canvas.frame = CGRect(origin: .zero, size: size)
            cropView?.frame = canvas.bounds
            cropView?.zoom = zoom
            scrollView.tile()
            if scrollView.contentSize == viewport { break }
        }
        let viewport = scrollView.contentSize
        scrollView.contentView.scroll(to: CGPoint(
            x: min(max(0, oldOrigin.x / max(0.001, oldZoom) * zoom), max(0, container.frame.width - viewport.width)),
            y: min(max(0, oldOrigin.y / max(0.001, oldZoom) * zoom), max(0, container.frame.height - viewport.height))))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        canvas.requestVisibleTiles()
    }

    private func perform(_ action: ScreenshotEditorAction) {
        guard !state.busy else { return }
        hoverTip.hide()
        canvas.commitText()
        switch action {
        case .tool(let tool):
            if tool != .select { state.tool = tool }
            if tool == .text { state.optionsExpanded = true; state.shapesExpanded = false; layout() }
            if window.isVisible { window.invalidateCursorRects(for: canvas) }
        case .preview(let mode): state.previewMode = mode; layout()
        case .undo: state.history.undo(); canvas.invalidateTiles()
        case .redo: state.history.redo(); canvas.invalidateTiles()
        case .reselect: cropView?.resetSelection()
        case .confirm, .pin: onFinish?(nil)
        case .copy: onFinish?(.copy)
        case .save: onFinish?(.save)
        case .cancel: onClose?()
        case .recognizeText, .recognizeBarcodes, .longScreenshot: break
        }
        canvas.needsDisplay = true
    }

    func close() {
        hoverTip.hide()
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        boundsObserver = nil
        onClose = nil; onFinish = nil
        state.action = nil; state.layoutChanged = nil; state.hoverChanged = nil
        (window as? PinnedScreenshotEditorPanel)?.onCancel = nil
        (window as? PinnedScreenshotEditorPanel)?.onConfirm = nil
        cropView?.onCancel = nil; cropView?.onConfirm = nil
        cropView?.isBusy = { true }
        cropView?.removeFromSuperview()
        canvas.dispose()
        scrollView.documentView = nil
        canvas.removeFromSuperview()
        header?.removeFromSuperview(); header = nil
        window.delegate = nil; window.contentView = nil; window.close()
    }
}

private struct PinnedScreenshotEditorHeader: View {
    @Bindable var state: ScreenshotEditorState
    let mode: PinnedScreenshotEditor.Mode
    let width: Int
    let height: Int
    var body: some View {
        VStack(spacing: 4) {
            if mode == .crop {
                HStack {
                    Button(L.t("Reselect", "重新框选")) { state.action?(.reselect) }
                    Spacer()
                    Button(L.t("Cancel", "取消")) { state.action?(.cancel) }
                    Button(L.t("Apply crop", "应用裁剪")) { state.action?(.confirm) }
                        .tint(.accentColor)
                }.padding(.horizontal, 14).frame(height: 46).disabled(state.busy)
                if state.busy { ProgressView().controlSize(.small).frame(height: 32) }
                if let error = state.error {
                    Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3).padding(10).frame(height: 64)
                }
            } else { ScreenshotToolbar(state: state) }
            HStack {
                Text("\(width) × \(height) " + L.t("pixels", "像素")).monospacedDigit()
                if mode == .crop { Text(L.t("Drag to select; move or resize the selection.", "拖动框选，可移动选区或拖拽边角调整。")) }
                Spacer()
            }.font(.caption).padding(.horizontal, 14).frame(height: 24)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(.bar)
    }
}

@MainActor private final class PinnedScreenshotPreviewContainer: NSView {
    override var isFlipped: Bool { true }
}

@MainActor private final class PinnedScreenshotEditorPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onConfirm?() }
        else { super.keyDown(with: event) }
    }
}

@MainActor final class PinnedScreenshotCropView: NSView {
    let pointSize: CGSize
    private(set) var selection: CGRect
    var zoom: CGFloat = 1 { didSet { needsDisplay = true } }
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    var isBusy: () -> Bool = { false }
    private enum Drag { case select, move, resize(Int) }
    private var drag: Drag?
    private var anchor = CGPoint.zero
    private var originalSelection = CGRect.zero
    init(pointSize: CGSize) {
        self.pointSize = pointSize
        selection = CGRect(origin: .zero, size: pointSize)
        super.init(frame: .zero)
        setAccessibilityLabel(L.t("Pinned image crop selection", "贴图裁剪选区"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    private var handles: [CGPoint] {
        [CGPoint(x: selection.minX, y: selection.minY), CGPoint(x: selection.midX, y: selection.minY),
         CGPoint(x: selection.maxX, y: selection.minY), CGPoint(x: selection.maxX, y: selection.midY),
         CGPoint(x: selection.maxX, y: selection.maxY), CGPoint(x: selection.midX, y: selection.maxY),
         CGPoint(x: selection.minX, y: selection.maxY), CGPoint(x: selection.minX, y: selection.midY)]
    }
    func resetSelection() { selection = CGRect(origin: .zero, size: pointSize); needsDisplay = true }
    private func point(_ event: NSEvent) -> CGPoint {
        let value = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(pointSize.width, max(0, value.x / zoom)), y: min(pointSize.height, max(0, value.y / zoom)))
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = CGRect(x: selection.minX * zoom, y: selection.minY * zoom,
            width: selection.width * zoom, height: selection.height * zoom)
        context.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        context.addRect(bounds); context.addRect(rect); context.drawPath(using: .eoFill)
        context.setStrokeColor(NSColor.systemGreen.cgColor); context.setLineWidth(1); context.stroke(rect)
        context.setFillColor(NSColor.systemGreen.cgColor)
        for point in handles { context.fill(CGRect(x: point.x * zoom - 3, y: point.y * zoom - 3, width: 6, height: 6)) }
    }
    override func mouseDown(with event: NSEvent) {
        guard !isBusy() else { return }
        window?.makeFirstResponder(self)
        anchor = point(event); originalSelection = selection
        if let handle = handles.firstIndex(where: { hypot(($0.x - anchor.x) * zoom, ($0.y - anchor.y) * zoom) <= 9 }) {
            drag = .resize(handle)
        } else if selection != CGRect(origin: .zero, size: pointSize), selection.contains(anchor) { drag = .move }
        else { drag = .select; selection = CGRect(origin: anchor, size: .zero) }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard !isBusy(), let drag else { return }
        autoscroll(with: event)
        let value = point(event)
        switch drag {
        case .select: selection = ScreenshotGeometry.rect(from: anchor, to: value)
        case .move:
            selection.origin = CGPoint(x: min(max(0, originalSelection.minX + value.x - anchor.x), pointSize.width - selection.width),
                y: min(max(0, originalSelection.minY + value.y - anchor.y), pointSize.height - selection.height))
        case .resize(let handle):
            var a = originalSelection.origin
            var b = CGPoint(x: originalSelection.maxX, y: originalSelection.maxY)
            if [0, 6, 7].contains(handle) { a.x = value.x }
            if [2, 3, 4].contains(handle) { b.x = value.x }
            if [0, 1, 2].contains(handle) { a.y = value.y }
            if [4, 5, 6].contains(handle) { b.y = value.y }
            selection = ScreenshotGeometry.rect(from: a, to: b)
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event); drag = nil
        if selection.width <= 0 || selection.height <= 0 { selection = originalSelection }
        needsDisplay = true
    }
    override func rightMouseDown(with event: NSEvent) { onCancel?() }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onConfirm?() }
        else { super.keyDown(with: event) }
    }
}
