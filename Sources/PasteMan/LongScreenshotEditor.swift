import AppKit
import SwiftUI
import PasteManCore

protocol ScreenshotAnnotationDocument: Sendable {
    var image: CGImage { get }
    var pointSize: CGSize { get }
}

extension LongScreenshotDocument: ScreenshotAnnotationDocument {}

struct PinnedScreenshotDocument: ScreenshotAnnotationDocument {
    let image: CGImage
    let pointSize: CGSize
}

@MainActor final class LongScreenshotEditor: NSObject, NSWindowDelegate {
    typealias ZoomMode = ScreenshotPreviewMode
    let document: LongScreenshotDocument
    let state = ScreenshotEditorState()
    let window: NSPanel
    let canvas: LongScreenshotCanvas
    let scrollView = NSScrollView()
    private let previewContainer = LongScreenshotPreviewContainer()
    var onOutput: ((ScreenshotCoordinator.Output) -> Void)?
    var onRecognizeText: (() -> Void)?
    var onRecognizeBarcodes: (() -> Void)?
    var onClose: (() -> Void)?
    private var header: NSHostingView<LongScreenshotEditorHeader>?
    private var boundsObserver: NSObjectProtocol?
    private let hoverTip = ScreenshotHoverTip()
    private(set) var zoom: CGFloat = 1
    private let notice: String?

    init(document: LongScreenshotDocument, notice: String?) {
        self.document = document; self.notice = notice
        canvas = LongScreenshotCanvas(document: document)
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let size = CGSize(width: min(920, screen.width - 40), height: min(660, screen.height - 40))
        window = NSPanel(contentRect: CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
            width: size.width, height: size.height),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = L.t("Scrolling screenshot", "长截屏")
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.acceptsMouseMovedEvents = true
        window.level = .floating
        window.delegate = self
        state.isLongEditor = true; state.tool = .rectangle
        window.minSize = CGSize(width: state.toolbarWidth + 24, height: 360)
        canvas.state = state
        state.action = { [weak self] in self?.perform($0) }
        state.layoutChanged = { [weak self] in self?.layout() }
        state.hoverChanged = { [weak self] title in self?.showHoverTip(title) }
        canvas.onAction = { [weak self] in self?.perform($0) }
        canvas.onHistoryChanged = { [weak self] in self?.refresh() }
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .legacy
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        previewContainer.addSubview(canvas)
        scrollView.documentView = previewContainer
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView, queue: .main) { [weak canvas] _ in
                MainActor.assumeIsolated { canvas?.requestVisibleTiles() }
            }
        window.contentView?.addSubview(scrollView)
        let header = NSHostingView(rootView: LongScreenshotEditorHeader(state: state, width: document.image.width,
            height: document.image.height, notice: notice))
        self.header = header
        window.contentView?.addSubview(header)
        layout()
    }
    func show() {
        NSApp.activate()
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        canvas.requestVisibleTiles()
    }
    func windowDidResize(_ notification: Notification) { layout() }
    func windowDidResignKey(_ notification: Notification) { closeHoverTip() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !state.busy else { NSSound.beep(); return false }
        onClose?(); return false
    }
    func close() {
        onRecognizeText = nil
        onRecognizeBarcodes = nil
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        boundsObserver = nil
        canvas.dispose()
        state.action = nil; state.layoutChanged = nil
        state.hoverChanged = nil
        closeHoverTip()
        header?.removeFromSuperview(); header = nil
        scrollView.documentView = nil
        canvas.removeFromSuperview()
        window.delegate = nil; window.contentView = nil; window.close()
    }
    func refresh() {
        canvas.invalidateTiles()
        layout()
    }
    private func layout() {
        closeHoverTip()
        guard let content = window.contentView else { return }
        let height = state.toolbarHeight + 40 + (notice == nil ? 0 : 48)
        header?.frame = CGRect(x: 0, y: max(0, content.bounds.height - height), width: content.bounds.width, height: height)
        scrollView.frame = CGRect(x: 0, y: 0, width: content.bounds.width, height: max(1, content.bounds.height - height))
        applyZoom()
    }

    private func closeHoverTip() {
        hoverTip.hide()
    }

    private func showHoverTip(_ target: ScreenshotHoverTarget?) {
        hoverTip.show(target, in: window)
    }
    func setZoom(_ mode: ZoomMode) {
        canvas.commitText()
        state.previewMode = mode
        applyZoom()
    }
    private func applyZoom() {
        let old = max(0.001, zoom)
        let origin = scrollView.contentView.bounds.origin
        // 默认从左上角等比例铺满宽度，只允许纵向滚动条占用视口。
        // 不为填满高度而放大宽短图，确保整行内容完整可见。
        for _ in 0..<8 {
            let viewport = scrollView.contentSize
            let widthScale = viewport.width / document.pointSize.width
            switch state.previewMode {
            case .fill, .width: zoom = widthScale
            case .actual: zoom = 1
            }
            canvas.zoom = zoom
            var imageSize = CGSize(width: document.pointSize.width * zoom, height: document.pointSize.height * zoom)
            // 浮点舍入不能为本应恰好铺满的方向额外触发一条滚动条。
            if abs(imageSize.width - viewport.width) < 0.01 { imageSize.width = viewport.width }
            if abs(imageSize.height - viewport.height) < 0.01 { imageSize.height = viewport.height }
            let previewSize = CGSize(width: max(viewport.width, imageSize.width), height: max(viewport.height, imageSize.height))
            previewContainer.setFrameSize(previewSize)
            canvas.frame = CGRect(origin: .zero, size: imageSize)
            scrollView.tile()
            if scrollView.contentSize == viewport { break }
        }
        let viewport = scrollView.contentSize
        let nextOrigin = CGPoint(x: min(max(0, origin.x / old * zoom), max(0, previewContainer.frame.width - viewport.width)),
            y: min(max(0, origin.y / old * zoom), max(0, previewContainer.frame.height - viewport.height)))
        scrollView.contentView.scroll(to: nextOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        canvas.requestVisibleTiles()
    }
    private func perform(_ action: ScreenshotEditorAction) {
        guard !state.busy else { return }
        canvas.commitText()
        switch action {
        case .tool(let tool):
            if tool != .select { state.tool = tool }
            if tool == .text { state.optionsExpanded = true; state.shapesExpanded = false; layout() }
            if window.isVisible { window.invalidateCursorRects(for: canvas) }
        case .preview(let mode): setZoom(mode)
        case .undo: state.history.undo(); refresh()
        case .redo: state.history.redo(); refresh()
        case .confirm, .copy: onOutput?(.copy)
        case .save: onOutput?(.save)
        case .pin: onOutput?(.pin)
        case .recognizeText: onRecognizeText?()
        case .recognizeBarcodes: onRecognizeBarcodes?()
        case .cancel: onClose?()
        case .reselect, .longScreenshot: break
        }
        canvas.needsDisplay = true
    }
}

@MainActor private final class LongScreenshotPreviewContainer: NSView {
    override var isFlipped: Bool { true }
}

private struct LongScreenshotEditorHeader: View {
    @Bindable var state: ScreenshotEditorState
    let width: Int
    let height: Int
    let notice: String?
    var body: some View {
        VStack(spacing: 4) {
            ScreenshotToolbar(state: state)
            HStack {
                Text("\(width) × \(height) " + L.t("pixels", "像素")).monospacedDigit()
                Spacer()
            }.font(.caption).padding(.horizontal, 14).frame(height: 28)
                .disabled(state.busy)
            if let notice { Text(notice).font(.caption).foregroundStyle(.orange).lineLimit(3).padding(.horizontal, 14).frame(height: 44) }
        }.padding(.top, 4).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(.bar)
    }
}

@MainActor final class LongScreenshotCanvas: NSView {
    let document: any ScreenshotAnnotationDocument
    weak var state: ScreenshotEditorState? {
        didSet {
            oldValue?.textAttributesChanged = nil
            oldValue?.mosaicAttributesChanged = nil
            state?.textAttributesChanged = { [weak self] in self?.updateTextAttributes() }
            state?.mosaicAttributesChanged = { [weak self] in self?.needsDisplay = true }
        }
    }
    var onAction: ((ScreenshotEditorAction) -> Void)?
    var onHistoryChanged: (() -> Void)?
    var zoom: CGFloat = 1 {
        didSet { if abs(oldValue - zoom) > 0.001 { commitText(); invalidateTiles() } }
    }
    private var tiles: [Int: CGImage] = [:]
    private var tileVersions: [Int: Int] = [:]
    private var tileTask: Task<Void, Never>?
    private var revision = 0
    private var transient: ScreenshotAnnotation?
    let mosaicPreview = ScreenshotMosaicPreview()
    private var pointerTracking: NSTrackingArea?
    private var mosaicPointer: CGPoint?
    var mosaicCursorRect: CGRect? {
        guard let state, state.tool == .mosaic, state.mosaicOptions.mode == .brush,
            !state.busy, let point = mosaicPointer else { return nil }
        return ScreenshotMosaicCursor.rect(at: point, diameter: state.mosaicOptions.resolvedBrushSize, zoom: zoom)
    }
    private var textEditor: ScreenshotTextView?
    private var textPosition = CGPoint.zero
    private var textCreationAnchor: CGPoint?
    static let tileHeight = 1024
    init(document: any ScreenshotAnnotationDocument) {
        self.document = document
        super.init(frame: CGRect(origin: .zero, size: document.pointSize))
        mosaicPreview.onChange = { [weak self] in self?.needsDisplay = true }
        mosaicPreview.onError = { [weak self] error in
            self?.state?.error = error.localizedDescription; self?.state?.layoutChanged?()
        }
        setAccessibilityLabel(L.t("Scrolling screenshot annotation canvas", "长截屏标注画布"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: state?.tool == .text ? .iBeam : .crosshair) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self, userInfo: nil)
        pointerTracking = area; addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) { updateMosaicPointer(event) }
    override func mouseMoved(with event: NSEvent) { updateMosaicPointer(event) }
    override func mouseExited(with event: NSEvent) {
        let previous = mosaicCursorRect
        mosaicPointer = nil
        if let previous { setNeedsDisplay(previous.insetBy(dx: -3, dy: -3)) }
    }
    private func updateMosaicPointer(_ event: NSEvent) {
        let previous = mosaicCursorRect
        let point = convert(event.locationInWindow, from: nil)
        mosaicPointer = visibleRect.contains(point) && bounds.contains(point) ? logicalPoint(point) : nil
        if let previous { setNeedsDisplay(previous.insetBy(dx: -3, dy: -3)) }
        if let next = mosaicCursorRect { setNeedsDisplay(next.insetBy(dx: -3, dy: -3)) }
    }
    func logicalPoint(_ viewPoint: CGPoint) -> CGPoint {
        CGPoint(x: min(document.pointSize.width, max(0, viewPoint.x / zoom)),
            y: min(document.pointSize.height, max(0, viewPoint.y / zoom)))
    }
    private var verticalScale: CGFloat { CGFloat(document.image.height) / document.pointSize.height }
    private func tileRect(_ index: Int) -> CGRect {
        CGRect(x: 0, y: index * Self.tileHeight, width: document.image.width,
            height: min(Self.tileHeight, document.image.height - index * Self.tileHeight))
    }
    func invalidateTiles() {
        revision += 1; tileTask?.cancel(); tileTask = nil
        mosaicPreview.reconcile(history: state?.history.annotations ?? [])
        needsDisplay = true; requestVisibleTiles()
    }
    func requestVisibleTiles() {
        guard window != nil, zoom > 0 else { return }
        let visible = visibleRect
        let start = max(0, Int(visible.minY / zoom * verticalScale) / Self.tileHeight)
        let end = min((document.image.height - 1) / Self.tileHeight, Int(visible.maxY / zoom * verticalScale) / Self.tileHeight)
        guard start <= end else { return }
        let indices = Array(start...end)
        tiles = tiles.filter { indices.contains($0.key) }
        tileVersions = tileVersions.filter { indices.contains($0.key) }
        requestMosaicPreview()
        tileTask?.cancel()
        let version = revision
        let annotations = state?.history.annotations ?? []
        let maximumWidth = min(document.image.width, max(1, Int(document.pointSize.width * zoom * (window?.backingScaleFactor ?? 2))))
        tileTask = Task { [weak self, document] in
            guard let self else { return }
            for index in indices where self.tileVersions[index] != version {
                do {
                    let image = try await LongScreenshotTileWorker.shared.render(document: document, rect: self.tileRect(index),
                        annotations: annotations, maximumWidth: maximumWidth)
                    guard !Task.isCancelled, self.revision == version else { return }
                    self.tiles[index] = image
                    self.tileVersions[index] = version
                    self.setNeedsDisplay(CGRect(x: 0, y: CGFloat(index * Self.tileHeight) / self.verticalScale * self.zoom,
                        width: self.bounds.width, height: self.tileRect(index).height / self.verticalScale * self.zoom))
                } catch {
                    guard !Task.isCancelled, self.revision == version else { return }
                    self.state?.error = error.localizedDescription
                    self.state?.layoutChanged?()
                }
            }
            guard !Task.isCancelled, self.revision == version else { return }
            if indices.allSatisfy({ self.tileVersions[$0] == version }) { self.mosaicPreview.acknowledge(annotations) }
            self.needsDisplay = true
        }
    }
    func waitForTiles() async { await tileTask?.value }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSColor.textBackgroundColor.setFill(); dirtyRect.fill()
        for (index, image) in tiles {
            let rect = tileRect(index)
            let target = CGRect(x: 0, y: rect.minY / verticalScale * zoom, width: document.pointSize.width * zoom,
                height: rect.height / verticalScale * zoom)
            if target.intersects(dirtyRect) { ScreenshotRenderer.drawImage(image, in: target, context: context) }
        }
        context.saveGState()
        context.clip(to: bounds)
        context.scaleBy(x: zoom, y: zoom)
        mosaicPreview.draw(in: context)
        if let transient, transient.tool != .mosaic { ScreenshotRenderer.draw(transient, in: context) }
        context.restoreGState()
        if let rect = mosaicCursorRect {
            context.saveGState(); context.clip(to: bounds)
            ScreenshotMosaicCursor.draw(rect, in: context); context.restoreGState()
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard let state, !state.busy else { return }
        commitText(); window?.makeFirstResponder(self)
        updateMosaicPointer(event)
        let point = logicalPoint(convert(event.locationInWindow, from: nil))
        if state.tool == .text { beginText(point); textCreationAnchor = point; return }
        guard state.tool != .select else { return }
        let annotation = state.annotation(at: point)
        transient = annotation
        mosaicPreview.begin(annotation, preceding: state.history.annotations)
        requestMosaicPreview(); needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard state?.busy == false else { return }
        autoscroll(with: event)
        updateMosaicPointer(event)
        let point = logicalPoint(convert(event.locationInWindow, from: nil))
        if let anchor = textCreationAnchor {
            textEditor?.resizeForCreation(delta: CGPoint(x: point.x - anchor.x, y: point.y - anchor.y))
            return
        }
        guard var value = transient else { return }
        value.extend(to: point)
        mosaicPreview.update(value)
        transient = value; needsDisplay = true
        requestMosaicPreview()
    }
    override func mouseUp(with event: NSEvent) {
        if textCreationAnchor != nil {
            mouseDragged(with: event); textCreationAnchor = nil
            textEditor?.finishCreationSizing()
            return
        }
        guard state?.busy == false, transient != nil else { return }
        mouseDragged(with: event)
        if let transient, transient.canCommit {
            state?.history.append(transient)
        }
        mosaicPreview.end(commit: transient?.canCommit == true)
        transient = nil; onHistoryChanged?()
    }
    private func requestMosaicPreview() {
        guard zoom > 0 else { return }
        let visible = visibleRect
        mosaicPreview.request(base: document.image, pointSize: document.pointSize,
            visibleRegion: CGRect(x: visible.minX / zoom, y: visible.minY / zoom,
                width: visible.width / zoom, height: visible.height / zoom))
    }
    private func beginText(_ point: CGPoint) {
        guard let state else { return }
        textPosition = point
        let editor = ScreenshotTextView(origin: CGPoint(x: point.x * zoom, y: point.y * zoom),
            maximumSize: CGSize(width: (document.pointSize.width - point.x) * zoom, height: (document.pointSize.height - point.y) * zoom),
            style: state.textStyle, color: state.textColor, scale: zoom,
            movementBounds: CGRect(x: 0, y: 0, width: document.pointSize.width * zoom, height: document.pointSize.height * zoom))
        editor.onFontSizeChanged = { [weak state] in state?.textStyle.fontSize = $0 }
        textEditor = editor; addSubview(editor); window?.makeFirstResponder(editor)
    }
    private func updateTextAttributes() {
        guard let state else { return }
        textEditor?.apply(style: state.textStyle, color: state.textColor)
    }
    func commitText() {
        textCreationAnchor = nil
        guard let editor = textEditor else { return }
        editor.unmarkText()
        let annotation = editor.annotation(at: textPosition)
        editor.dispose(); textEditor = nil
        window?.makeFirstResponder(self)
        if let annotation {
            state?.history.append(annotation)
            onHistoryChanged?()
        }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if textEditor != nil { return super.performKeyEquivalent(with: event) }
        guard event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "z": onAction?(event.modifierFlags.contains(.shift) ? .redo : .undo)
        case "c": onAction?(.copy)
        case "s": onAction?(.save)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
    func dispose() {
        revision += 1; tileTask?.cancel(); tileTask = nil
        tiles.removeAll(); tileVersions.removeAll(); transient = nil
        mosaicPreview.dispose(); mosaicPointer = nil
        textEditor?.dispose(); textEditor = nil; textCreationAnchor = nil
        state = nil; onAction = nil; onHistoryChanged = nil
    }
}

actor LongScreenshotTileWorker {
    static let shared = LongScreenshotTileWorker()
    func render(document: any ScreenshotAnnotationDocument, rect: CGRect, annotations: [ScreenshotAnnotation], maximumWidth: Int) async throws -> CGImage {
        let mosaicCost = annotations.contains { $0.tool == .mosaic } ? ScreenshotRenderer.mosaicCacheLimit : 0
        return try await ImageWorkBudget.shared.withPermit(estimatedBytes: Int(rect.width * rect.height) * 12 + mosaicCost, priority: .display) {
            try await self.renderAdmitted(document: document, rect: rect, annotations: annotations, maximumWidth: maximumWidth)
        }
    }
    private func renderAdmitted(document: any ScreenshotAnnotationDocument, rect: CGRect, annotations: [ScreenshotAnnotation], maximumWidth: Int) throws -> CGImage {
        try Task.checkCancellation()
        let scaleX = CGFloat(document.image.width) / document.pointSize.width
        let scaleY = CGFloat(document.image.height) / document.pointSize.height
        let dimension = Int(max(rect.width, rect.height) * min(1, CGFloat(maximumWidth) / rect.width))
        return try ScreenshotRenderer.render(base: document.image, pointSize: document.pointSize,
            annotations: annotations, maximumDimension: max(1, dimension),
            region: CGRect(x: rect.minX / scaleX, y: rect.minY / scaleY, width: rect.width / scaleX, height: rect.height / scaleY))
    }
}
