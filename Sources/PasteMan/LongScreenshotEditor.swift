import AppKit
import SwiftUI
import PasteManCore

@MainActor final class LongScreenshotEditor: NSObject, NSWindowDelegate {
    let document: LongScreenshotDocument
    let state = ScreenshotEditorState()
    let window: NSPanel
    let canvas: LongScreenshotCanvas
    let scrollView = NSScrollView()
    private let previewContainer = LongScreenshotPreviewContainer()
    var onOutput: ((ScreenshotCoordinator.Output) -> Void)?
    var onClose: (() -> Void)?
    private var header: NSHostingView<LongScreenshotEditorHeader>?
    private var boundsObserver: NSObjectProtocol?
    private var hoverTip: NSPanel?
    private var fit = true
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
        window.minSize = CGSize(width: 560, height: 360)
        window.delegate = self
        state.isLongEditor = true; state.tool = .rectangle
        canvas.state = state
        state.action = { [weak self] in self?.perform($0) }
        state.layoutChanged = { [weak self] in self?.layout() }
        state.hoverChanged = { [weak self] title in self?.showHoverTip(title) }
        canvas.onAction = { [weak self] in self?.perform($0) }
        canvas.onHistoryChanged = { [weak self] in self?.refresh() }
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
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
            height: document.image.height, notice: notice, onFit: { [weak self] in self?.setZoom(fit: true) },
            onActual: { [weak self] in self?.setZoom(fit: false) }))
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
        if let hoverTip { hoverTip.parent?.removeChildWindow(hoverTip) }
        hoverTip?.close()
        hoverTip?.contentView = nil
        hoverTip = nil
    }

    private func showHoverTip(_ title: String?) {
        closeHoverTip()
        guard let title, !title.isEmpty, window.isVisible, let header else { return }
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .labelColor
        label.sizeToFit()
        let size = CGSize(width: label.frame.width + 16, height: 26)
        let screen = window.screen?.visibleFrame ?? window.frame
        let headerFrame = window.convertToScreen(header.convert(header.bounds, to: nil))
        let mouse = NSEvent.mouseLocation
        let below = headerFrame.minY - size.height - 5
        let above = headerFrame.maxY + 5
        let y = below >= screen.minY ? below : above
        let rect = CGRect(
            x: max(screen.minX + 4, min(mouse.x - size.width / 2, screen.maxX - size.width - 4)),
            y: min(max(screen.minY + 4, y), screen.maxY - size.height - 4),
            width: size.width, height: size.height)
        let tip = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        tip.isReleasedWhenClosed = false
        tip.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        tip.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        tip.ignoresMouseEvents = true
        tip.hidesOnDeactivate = false
        tip.isOpaque = false
        tip.backgroundColor = .clear
        let background = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 5
        background.layer?.masksToBounds = true
        label.setFrameOrigin(CGPoint(x: 8, y: (size.height - label.frame.height) / 2))
        background.addSubview(label)
        tip.contentView = background
        window.addChildWindow(tip, ordered: .above)
        tip.orderFrontRegardless()
        hoverTip = tip
    }
    func setZoom(fit: Bool) {
        canvas.commitText()
        self.fit = fit
        applyZoom()
    }
    private func applyZoom() {
        let padding: CGFloat = 24
        let old = max(0.001, zoom)
        let origin = scrollView.contentView.bounds.origin
        let oldCanvasOrigin = canvas.frame.origin
        // 常驻滚动条出现或隐藏时会改变视口尺寸；按最终视口收敛，保持两侧留白相等。
        for _ in 0..<4 {
            let viewport = scrollView.contentSize
            zoom = fit ? min(1, max(0.02, (viewport.width - padding * 2) / document.pointSize.width)) : 1
            canvas.zoom = zoom
            let imageSize = CGSize(width: document.pointSize.width * zoom, height: document.pointSize.height * zoom)
            let previewSize = CGSize(width: max(viewport.width, imageSize.width + padding * 2),
                height: max(viewport.height, imageSize.height + padding * 2))
            previewContainer.setFrameSize(previewSize)
            canvas.frame = CGRect(x: (previewSize.width - imageSize.width) / 2,
                y: (previewSize.height - imageSize.height) / 2, width: imageSize.width, height: imageSize.height)
            scrollView.tile()
            if scrollView.contentSize == viewport { break }
        }
        let nextOrigin = CGPoint(x: origin.x <= oldCanvasOrigin.x ? 0
                : (origin.x - oldCanvasOrigin.x) / old * zoom + canvas.frame.minX,
            y: origin.y <= oldCanvasOrigin.y ? 0
                : (origin.y - oldCanvasOrigin.y) / old * zoom + canvas.frame.minY)
        scrollView.contentView.scroll(to: nextOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        canvas.requestVisibleTiles()
    }
    private func perform(_ action: ScreenshotEditorAction) {
        guard !state.busy else { return }
        canvas.commitText()
        switch action {
        case .tool(let tool): if tool != .select { state.tool = tool }
        case .undo: state.history.undo(); refresh()
        case .redo: state.history.redo(); refresh()
        case .copy: onOutput?(.copy)
        case .save: onOutput?(.save)
        case .pin: onOutput?(.pin)
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
    let onFit: () -> Void
    let onActual: () -> Void
    var body: some View {
        VStack(spacing: 4) {
            ScreenshotToolbar(state: state)
            HStack {
                Text("\(width) × \(height) " + L.t("pixels", "像素")).monospacedDigit()
                Spacer()
                Button(L.t("Fit width", "适应宽度"), action: onFit)
                Button(L.t("Actual size", "原始比例"), action: onActual)
            }.font(.caption).padding(.horizontal, 14).frame(height: 28)
                .disabled(state.busy)
            if let notice { Text(notice).font(.caption).foregroundStyle(.orange).lineLimit(3).padding(.horizontal, 14).frame(height: 44) }
        }.padding(.top, 4).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(.bar)
    }
}

@MainActor final class LongScreenshotCanvas: NSView {
    let document: LongScreenshotDocument
    weak var state: ScreenshotEditorState?
    var onAction: ((ScreenshotEditorAction) -> Void)?
    var onHistoryChanged: (() -> Void)?
    var zoom: CGFloat = 1 {
        didSet { if abs(oldValue - zoom) > 0.001 { invalidateTiles() } }
    }
    private var tiles: [Int: CGImage] = [:]
    private var tileTask: Task<Void, Never>?
    private var revision = 0
    private var transient: ScreenshotAnnotation?
    private var textEditor: NSTextView?
    private var textPosition = CGPoint.zero
    private var textStyle: (AnnotationColor, CGFloat)?
    static let tileHeight = 1024
    init(document: LongScreenshotDocument) {
        self.document = document
        super.init(frame: CGRect(origin: .zero, size: document.pointSize))
        setAccessibilityLabel(L.t("Scrolling screenshot annotation canvas", "长截屏标注画布"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    func logicalPoint(_ viewPoint: CGPoint) -> CGPoint {
        CGPoint(x: min(document.pointSize.width, max(0, viewPoint.x / zoom)),
            y: min(document.pointSize.height, max(0, viewPoint.y / zoom)))
    }
    private var scale: CGFloat { CGFloat(document.image.width) / document.pointSize.width }
    private func tileRect(_ index: Int) -> CGRect {
        CGRect(x: 0, y: index * Self.tileHeight, width: document.image.width,
            height: min(Self.tileHeight, document.image.height - index * Self.tileHeight))
    }
    func invalidateTiles() {
        revision += 1; tileTask?.cancel(); tileTask = nil; tiles.removeAll()
        needsDisplay = true; requestVisibleTiles()
    }
    func requestVisibleTiles() {
        guard window != nil, zoom > 0 else { return }
        let visible = visibleRect
        let start = max(0, Int(visible.minY / zoom * scale) / Self.tileHeight)
        let end = min((document.image.height - 1) / Self.tileHeight, Int(visible.maxY / zoom * scale) / Self.tileHeight)
        guard start <= end else { return }
        let indices = Array(start...end)
        tiles = tiles.filter { indices.contains($0.key) }
        tileTask?.cancel()
        let version = revision
        let annotations = state?.history.annotations ?? []
        let maximumWidth = min(document.image.width, max(1, Int(document.pointSize.width * zoom * (window?.backingScaleFactor ?? 2))))
        tileTask = Task { [weak self, document] in
            guard let self else { return }
            for index in indices where self.tiles[index] == nil {
                do {
                    let image = try await LongScreenshotTileWorker.shared.render(document: document, rect: self.tileRect(index),
                        annotations: annotations, maximumWidth: maximumWidth)
                    guard !Task.isCancelled, self.revision == version else { return }
                    self.tiles[index] = image
                    self.setNeedsDisplay(CGRect(x: 0, y: CGFloat(index * Self.tileHeight) / self.scale * self.zoom,
                        width: self.bounds.width, height: CGFloat(image.height) / CGFloat(image.width) * self.bounds.width))
                } catch {
                    guard !Task.isCancelled, self.revision == version else { return }
                    self.state?.error = error.localizedDescription
                    self.state?.layoutChanged?()
                }
            }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSColor.textBackgroundColor.setFill(); dirtyRect.fill()
        for (index, image) in tiles {
            let rect = tileRect(index)
            let target = CGRect(x: 0, y: rect.minY / scale * zoom, width: document.pointSize.width * zoom,
                height: rect.height / scale * zoom)
            if target.intersects(dirtyRect) { ScreenshotRenderer.drawImage(image, in: target, context: context) }
        }
        if let transient {
            context.saveGState(); context.scaleBy(x: zoom, y: zoom)
            if transient.tool == .mosaic {
                context.setFillColor(NSColor.gray.withAlphaComponent(0.65).cgColor); context.fill(transient.rect)
            } else { ScreenshotRenderer.draw(transient, in: context) }
            context.restoreGState()
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard let state, !state.busy else { return }
        commitText(); window?.makeFirstResponder(self)
        let point = logicalPoint(convert(event.locationInWindow, from: nil))
        if state.tool == .text { beginText(point); return }
        guard state.tool != .select else { return }
        transient = ScreenshotAnnotation(tool: state.tool, points: [point],
            color: AnnotationColor.palette[state.colorIndex], width: state.width)
    }
    override func mouseDragged(with event: NSEvent) {
        guard state?.busy == false, var value = transient, let first = value.points.first else { return }
        autoscroll(with: event)
        let point = logicalPoint(convert(event.locationInWindow, from: nil))
        if value.tool == .pen {
            if let last = value.points.last, hypot(last.x - point.x, last.y - point.y) >= 0.75 { value.points.append(point) }
        } else { value.points = [first, point] }
        transient = value; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard state?.busy == false, transient != nil else { return }
        mouseDragged(with: event)
        if let transient, transient.tool == .pen || transient.rect.width > 0 || transient.rect.height > 0 {
            state?.history.append(transient)
        }
        transient = nil; onHistoryChanged?()
    }
    private func beginText(_ point: CGPoint) {
        guard let state else { return }
        textPosition = point; textStyle = (AnnotationColor.palette[state.colorIndex], state.width)
        let editor = NSTextView(frame: CGRect(x: point.x * zoom, y: point.y * zoom,
            width: max(1, min(320, (document.pointSize.width - point.x) * zoom)), height: max(24, 100 * zoom)))
        editor.font = .systemFont(ofSize: max(16, state.width * 6) * zoom)
        editor.textColor = NSColor(cgColor: AnnotationColor.palette[state.colorIndex].cgColor)
        editor.backgroundColor = .textBackgroundColor
        editor.isRichText = false; editor.textContainerInset = .zero
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = CGSize(width: 100_000, height: 100_000)
        textEditor = editor; addSubview(editor); window?.makeFirstResponder(editor)
    }
    func commitText() {
        guard let editor = textEditor else { return }
        editor.unmarkText()
        let text = editor.string
        editor.removeFromSuperview(); textEditor = nil
        window?.makeFirstResponder(self)
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let textStyle {
            state?.history.append(ScreenshotAnnotation(tool: .text, points: [textPosition], color: textStyle.0,
                width: textStyle.1, text: text))
            onHistoryChanged?()
        }
        textStyle = nil
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
        tiles.removeAll(); transient = nil
        textEditor?.removeFromSuperview(); textEditor = nil
        state = nil; onAction = nil; onHistoryChanged = nil
    }
}

actor LongScreenshotTileWorker {
    static let shared = LongScreenshotTileWorker()
    func render(document: LongScreenshotDocument, rect: CGRect, annotations: [ScreenshotAnnotation], maximumWidth: Int) async throws -> CGImage {
        let mosaicCost = annotations.contains { $0.tool == .mosaic } ? ScreenshotRenderer.mosaicCacheLimit : 0
        return try await ImageWorkBudget.shared.withPermit(estimatedBytes: Int(rect.width * rect.height) * 12 + mosaicCost, priority: .display) {
            try await self.renderAdmitted(document: document, rect: rect, annotations: annotations, maximumWidth: maximumWidth)
        }
    }
    private func renderAdmitted(document: LongScreenshotDocument, rect: CGRect, annotations: [ScreenshotAnnotation], maximumWidth: Int) throws -> CGImage {
        try Task.checkCancellation()
        let scale = CGFloat(document.image.width) / document.pointSize.width
        let dimension = Int(max(rect.width, rect.height) * min(1, CGFloat(maximumWidth) / rect.width))
        return try ScreenshotRenderer.render(base: document.image, pointSize: document.pointSize,
            annotations: annotations, maximumDimension: max(1, dimension),
            region: CGRect(x: rect.minX / scale, y: rect.minY / scale, width: rect.width / scale, height: rect.height / scale))
    }
}
