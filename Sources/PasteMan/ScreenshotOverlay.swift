import AppKit
import Observation
import SwiftUI

@MainActor @Observable final class ScreenshotEditorState {
    var tool = AnnotationTool.select
    var colorIndex = 0
    var width: CGFloat = 3
    var mosaicOptions = ScreenshotMosaicOptions() {
        didSet {
            if mosaicOptions != oldValue { mosaicAttributesChanged?() }
            if mosaicOptions.mode != oldValue.mode { layoutChanged?() }
        }
    }
    var mosaicAttributesChanged: (() -> Void)?
    var textStyle = AnnotationTextStyle() { didSet { if textStyle != oldValue { textAttributesChanged?() } } }
    var textColor = AnnotationColor.palette[0] { didSet { if textColor != oldValue { textAttributesChanged?() } } }
    var textAttributesChanged: (() -> Void)?
    var history = AnnotationHistory()
    var shapeTool = AnnotationTool.rectangle
    var optionsExpanded = false
    var shapesExpanded = false
    var layoutChanged: (() -> Void)?
    var hoverChanged: ((ScreenshotHoverTarget?) -> Void)?
    var toolbarHeight: CGFloat {
        46 + (optionsExpanded ? optionsHeight : 0) + (shapesExpanded ? 36 : 0) + (busy ? 36 : 0) + (error == nil ? 0 : 68)
    }
    private var optionsHeight: CGFloat { tool == .text || (tool == .mosaic && mosaicOptions.mode == .brush) ? 72 : 36 }
    func annotation(at point: CGPoint) -> ScreenshotAnnotation {
        ScreenshotAnnotation(tool: tool, points: [point], color: AnnotationColor.palette[colorIndex], width: width,
            mosaic: tool == .mosaic ? mosaicOptions : nil)
    }
    var busy = false
    var error: String?
    var isLongEditor = false
    var isPinnedEditor = false
    var usesImagePreview: Bool { isLongEditor || isPinnedEditor }
    var prefersLongScreenshot = false
    var confirmsLongScreenshot: Bool { prefersLongScreenshot && !isLongEditor }
    var previewMode = ScreenshotPreviewMode.fill
    var toolbarWidth: CGFloat { ScreenshotToolbar.width + (usesImagePreview ? 124 : 36) }
    var canAdjust: Bool { history.annotations.isEmpty && history.undone.isEmpty }
    var action: ((ScreenshotEditorAction) -> Void)?
}

enum ScreenshotEditorAction {
    case tool(AnnotationTool)
    case preview(ScreenshotPreviewMode)
    case undo, redo, reselect, longScreenshot, recognizeText, recognizeBarcodes, confirm, copy, save, pin, cancel
}

enum ScreenshotPreviewMode: String, CaseIterable {
    case fill, width, actual
    var title: String {
        switch self {
        case .fill: L.t("Fill window", "铺满窗口")
        case .width: L.t("Fit width", "适应宽度")
        case .actual: L.t("Actual size", "原始比例")
        }
    }
    var detail: String {
        switch self {
        case .fill: L.t("Fill the window width proportionally; scroll vertically for the rest.", "按窗口宽度等比例铺满，超出高度的部分垂直滚动查看。")
        case .width: L.t("Show the full image width inside the window.", "让整行图片完整显示在窗口内。")
        case .actual: L.t("View at the original scale without changing the exported image.", "按截图原始比例查看，不改变导出图片尺寸。")
        }
    }
    var symbol: String {
        switch self {
        case .fill: "arrow.up.left.and.arrow.down.right"
        case .width: "arrow.left.and.right"
        case .actual: "1.magnifyingglass"
        }
    }
}

/// 命中范围必须放在按钮标签内；按钮外的悬停范围不会扩大纯图标的点击范围。
struct ScreenshotToolbarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.4)
    }
}

struct ScreenshotToolbar: View {
    @Bindable var state: ScreenshotEditorState
    static let width: CGFloat = 564
    static let scrollingScreenshotSymbol = "arrow.down.doc"
    static let barcodeRecognitionSymbol = "qrcode.viewfinder"
    static let tint = Color(red: 0, green: 0.76, blue: 0.48)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                toolButton(state.shapeTool)
                Button {
                    state.shapesExpanded.toggle()
                    state.optionsExpanded = false
                    state.layoutChanged?()
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9)).frame(width: 14, height: 30)
                }.modifier(ScreenshotHoverFeedback(title: L.t("Shapes and selection", "形状与选区"), state: state))
                ForEach([AnnotationTool.arrow, .pen, .text, .mosaic], id: \.self) { tool in toolButton(tool) }
                separator
                action("arrow.uturn.backward", title: L.t("Undo ⌘Z", "撤销 ⌘Z"), action: .undo,
                    enabled: !state.history.annotations.isEmpty)
                action("arrow.uturn.forward", title: L.t("Redo ⇧⌘Z", "重做 ⇧⌘Z"), action: .redo,
                    enabled: !state.history.undone.isEmpty)
                if !state.usesImagePreview {
                    action("arrow.up.left.and.arrow.down.right", title: L.t("Reselect", "重新框选"), action: .reselect)
                    action(Self.scrollingScreenshotSymbol, title: state.canAdjust
                        ? L.t("Start scrolling screenshot", "开始长截屏")
                        : L.t("Reselect before starting a scrolling screenshot", "已有标注，请先重新框选再长截屏"),
                        action: .longScreenshot, enabled: state.canAdjust)
                } else {
                    separator
                    ForEach(ScreenshotPreviewMode.allCases, id: \.self) { mode in
                        let fitImage = state.isPinnedEditor && mode == .fill
                        action(mode.symbol, title: fitImage ? L.t("Fit image", "适应窗口") : mode.title, action: .preview(mode),
                            detail: fitImage ? L.t("Show the complete image inside the window.", "在窗口中完整显示图片。") : mode.detail,
                            selected: state.previewMode == mode)
                            .accessibilityIdentifier("screenshot.preview." + mode.rawValue)
                    }
                }
                separator
                if !state.isPinnedEditor {
                    action("text.viewfinder", title: L.t("Recognize text", "识别文字"), action: .recognizeText)
                        .accessibilityIdentifier("screenshot.recognizeText")
                    action(Self.barcodeRecognitionSymbol, title: ScreenshotRecognitionKind.barcodes.title, action: .recognizeBarcodes)
                        .accessibilityIdentifier("screenshot.recognizeBarcodes")
                }
                action("square.and.arrow.down", title: L.t("Save PNG…", "保存 PNG…"), action: .save)
                if state.isPinnedEditor {
                    action("doc.on.doc", title: L.t("Copy ⌘C", "复制 ⌘C"), action: .copy)
                } else {
                    action("pin", title: L.t("Pin to desktop", "钉在桌面"), action: .pin)
                }
                action("xmark", title: L.t("Cancel Esc", "取消 Esc"), action: .cancel, color: .red)
                action("checkmark", title: state.isPinnedEditor ? L.t("Apply to pinned image", "应用到贴图") : state.confirmsLongScreenshot
                    ? (state.canAdjust ? L.t("Start scrolling screenshot", "开始长截屏")
                        : L.t("Reselect before starting a scrolling screenshot", "已有标注，请先重新框选再长截屏"))
                    : L.t("Finish and copy ⌘C", "完成并复制 ⌘C"), action: .confirm, color: Self.tint,
                    enabled: !state.confirmsLongScreenshot || state.canAdjust)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 46)
            .padding(.horizontal, 8)
            if state.shapesExpanded {
                HStack(spacing: 8) {
                    ForEach([AnnotationTool.select, .rectangle, .ellipse], id: \.self) { tool in
                        Button {
                            if tool != .select { state.shapeTool = tool }
                            state.action?(.tool(tool))
                            state.shapesExpanded = false
                            state.optionsExpanded = tool != .select
                            state.layoutChanged?()
                        } label: {
                            Label(tool.title, systemImage: tool.symbol)
                        }
                        .disabled(tool == .select && (!state.canAdjust || state.usesImagePreview))
                        .modifier(ScreenshotHoverFeedback(title: tool.title, state: state,
                            buttonEnabled: tool != .select || (state.canAdjust && !state.usesImagePreview)))
                    }
                    Spacer(minLength: 0)
                }.frame(height: 36).padding(.horizontal, 14)
            }
            if state.optionsExpanded && state.tool == .text { ScreenshotTextOptions(state: state) }
            if state.optionsExpanded && state.tool == .mosaic { ScreenshotMosaicOptionsView(state: state) }
            if state.optionsExpanded && state.tool != .text && state.tool != .mosaic {
                HStack(spacing: 12) {
                    ForEach(AnnotationColor.palette.indices, id: \.self) { index in
                        let color = AnnotationColor.palette[index]
                        Button {
                            state.colorIndex = index
                        } label: {
                            Circle().fill(Color(red: color.red, green: color.green, blue: color.blue))
                                .frame(width: 14, height: 14)
                                .overlay(
                                    Circle().stroke(
                                        state.colorIndex == index ? Self.tint : .gray.opacity(0.5),
                                        lineWidth: state.colorIndex == index ? 2 : 1
                                    ).padding(-3))
                        }.modifier(ScreenshotHoverFeedback(title: L.t("Color", "颜色") + " \(index + 1)", state: state))
                    }
                    separator
                    ForEach([CGFloat(2), 3, 6], id: \.self) { width in
                        Button {
                            state.width = width
                        } label: {
                            Capsule().fill(state.width == width ? Self.tint : Color.primary.opacity(0.65))
                                .frame(width: 24, height: width)
                                .frame(width: 30, height: 25)
                        }.modifier(ScreenshotHoverFeedback(title: L.t("Width", "粗细") + " \(Int(width))", state: state))
                    }
                    Spacer(minLength: 0)
                }.frame(height: 36).padding(.horizontal, 16)
            }
            if state.busy { ProgressView().controlSize(.small).padding(8) }
            if let error = state.error { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3).padding(10) }
        }
        .font(.system(size: 17, weight: .regular))
        .buttonStyle(ScreenshotToolbarButtonStyle())
        .frame(width: state.toolbarWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .disabled(state.busy)
    }
    private var separator: some View { Divider().frame(height: 22).padding(.horizontal, 5) }
    private func toolButton(_ tool: AnnotationTool) -> some View {
        Button {
            if state.tool == tool {
                state.optionsExpanded.toggle()
            } else {
                state.action?(.tool(tool))
                state.optionsExpanded = true
            }
            state.shapesExpanded = false
            state.layoutChanged?()
        } label: {
            Image(systemName: tool.symbol).frame(width: 32, height: 32)
                .foregroundStyle(state.tool == tool ? Self.tint : Color.primary.opacity(0.7))
                .background(state.tool == tool ? Self.tint.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }.modifier(ScreenshotHoverFeedback(title: tool.title, state: state))
    }
    private func action(_ symbol: String, title: String, action: ScreenshotEditorAction, color: Color? = nil,
                        enabled: Bool = true, detail: String? = nil, selected: Bool = false)
        -> some View
    {
        Button {
            state.action?(action)
        } label: {
            Image(systemName: symbol).frame(width: 32, height: 32)
                .foregroundStyle(color ?? (selected ? Self.tint : Color.primary.opacity(0.7)))
                .background(selected ? Self.tint.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }.disabled(!enabled)
            .modifier(ScreenshotHoverFeedback(title: title, state: state, buttonEnabled: enabled, detail: detail))
    }
}

struct ScreenshotHoverFeedback: ViewModifier {
    let title: String
    let state: ScreenshotEditorState
    var buttonEnabled = true
    var detail: String?
    @ViewState private var hovering = false
    @ViewState private var anchor = ScreenshotHoverReference()
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(
                hovering && enabled && buttonEnabled ? ScreenshotToolbar.tint.opacity(0.16) : .clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
            .onHover { inside in
                hovering = inside
                if inside { anchor.view?.beginHover() }
                else { anchor.view?.endHover() }
            }
            .background(ScreenshotHoverAnchor(title: title, detail: detail, reference: anchor) { [weak state] target in
                state?.hoverChanged?(target)
            })
            .accessibilityLabel(title)
            .accessibilityHint(detail ?? "")
    }
}

@MainActor final class ScreenshotOverlay: NSView {
    let capture: CapturedScreen
    weak var coordinator: ScreenshotCoordinator?
    let state = ScreenshotEditorState()
    private(set) var selection: CGRect = .zero
    private(set) var selectedImage: CGImage?
    private var preview: CGImage?
    private var toolbar: NSHostingView<ScreenshotToolbar>?
    private let hoverTip = ScreenshotHoverTip()
    private var textEditor: ScreenshotTextView?
    private var textPosition: CGPoint = .zero
    private var transient: ScreenshotAnnotation?
    let mosaicPreview = ScreenshotMosaicPreview()
    private var mosaicPointer: CGPoint?
    var mosaicCursorRect: CGRect? {
        guard state.tool == .mosaic, state.mosaicOptions.mode == .brush, !state.busy, let point = mosaicPointer else { return nil }
        return ScreenshotMosaicCursor.rect(at: point, diameter: state.mosaicOptions.resolvedBrushSize)
    }
    private var anchor = CGPoint.zero
    private var originalSelection = CGRect.zero
    private enum Drag {
        case selection, move
        case resize(Int)
        case annotation, textSizing
    }
    private var drag: Drag?
    private var previewTask: Task<Void, Never>?
    private var previewSession = UUID()
    private var drawingSurface: ScreenshotDrawingSurface?
    private var revision = 0
    private var pointerTracking: NSTrackingArea?
    private(set) var cursorSample: ScreenshotCursorSample?
    private var cursorPoint: CGPoint?
    private var cursorCard: CGRect = .zero
    private let sampler: ScreenshotPixelSampler?

    init(capture: CapturedScreen, coordinator: ScreenshotCoordinator) {
        self.capture = capture
        self.sampler = ScreenshotPixelSampler(image: capture.image)
        self.coordinator = coordinator
        super.init(frame: CGRect(origin: .zero, size: capture.screen.frame.size))
        let background = ScreenshotFrozenBackground(frame: bounds, image: capture.image)
        background.wantsLayer = true
        background.autoresizingMask = [.width, .height]
        addSubview(background)
        let surface = ScreenshotDrawingSurface(frame: bounds)
        surface.owner = self
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
        drawingSurface = surface
        state.action = { [weak self] in self?.perform($0) }
        state.layoutChanged = { [weak self] in self?.showToolbar() }
        state.hoverChanged = { [weak self] title in self?.showHoverTip(title) }
        state.textAttributesChanged = { [weak self] in self?.updateTextAttributes() }
        state.mosaicAttributesChanged = { [weak self] in self?.drawingSurface?.needsDisplay = true }
        mosaicPreview.onChange = { [weak self] in self?.drawingSurface?.needsDisplay = true }
        mosaicPreview.onError = { [weak self] error in
            self?.state.error = error.localizedDescription; self?.showToolbar()
        }
        setAccessibilityLabel(L.t("Screenshot selection and annotation", "截图框选与标注"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        if state.tool == .text, selectedImage != nil { addCursorRect(selection, cursor: .iBeam) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        if let window, window.isVisible {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(point) { updateCursor(at: point) }
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self, userInfo: nil)
        pointerTracking = area
        addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) {
        if coordinator?.phase == .selecting, window?.isVisible == true {
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(self)
        }
        updateCursor(at: location(event))
    }
    override func mouseMoved(with event: NSEvent) { updateCursor(at: location(event)) }
    override func mouseExited(with event: NSEvent) { hideCursorCard(); updateMosaicPointer(at: nil) }
    private func updateMosaicPointer(at point: CGPoint?) {
        let previous = mosaicCursorRect
        mosaicPointer = point.flatMap { point in
            selectedImage != nil && selection.contains(point) && toolbar?.frame.contains(point) != true ? point : nil
        }
        if let previous { drawingSurface?.setNeedsDisplay(previous.insetBy(dx: -3, dy: -3)) }
        if let next = mosaicCursorRect { drawingSurface?.setNeedsDisplay(next.insetBy(dx: -3, dy: -3)) }
    }
    private func updateCursor(at point: CGPoint) {
        updateMosaicPointer(at: point)
        guard !state.busy, textEditor == nil,
            coordinator?.selectedScreen == nil || coordinator?.selectedScreen == capture.screen.id,
            selectedImage == nil || drag != nil,
            transient == nil,
            let sample = sampler?.sample(at: point, pointSize: bounds.size)
        else {
            hideCursorCard()
            return
        }
        drawingSurface?.setNeedsDisplay(cursorCard.insetBy(dx: -2, dy: -2))
        cursorPoint = point
        cursorSample = sample
        cursorCard = ScreenshotGeometry.cursorCard(at: point, bounds: bounds)
        drawingSurface?.setNeedsDisplay(cursorCard.insetBy(dx: -2, dy: -2))
    }
    private func hideCursorCard() {
        if cursorSample != nil { drawingSurface?.setNeedsDisplay(cursorCard.insetBy(dx: -2, dy: -2)) }
        cursorPoint = nil
        cursorSample = nil
        cursorCard = .zero
    }
    private func drawCursorCard(in context: CGContext) {
        guard let sample = cursorSample, cursorPoint != nil, !state.busy else { return }
        let card = cursorCard
        context.saveGState()
        defer { context.restoreGState() }
        context.addPath(CGPath(roundedRect: card, cornerWidth: 9, cornerHeight: 9, transform: nil))
        context.clip()
        context.setFillColor(NSColor(calibratedWhite: 0.12, alpha: 0.98).cgColor)
        context.fill(card)
        let zoom = CGRect(x: card.minX, y: card.minY, width: card.width, height: 136)
        let source = CGRect(x: sample.x - 8, y: sample.y - 6, width: 17, height: 13)
        let clipped = source.intersection(CGRect(x: 0, y: 0, width: capture.image.width, height: capture.image.height))
        if let crop = capture.image.cropping(to: clipped) {
            context.saveGState()
            context.clip(to: zoom)
            context.interpolationQuality = .none
            let cell: CGFloat = 11
            let rect = CGRect(
                x: zoom.midX + (clipped.minX - CGFloat(sample.x) - 0.5) * cell,
                y: zoom.midY + (clipped.minY - CGFloat(sample.y) - 0.5) * cell,
                width: clipped.width * cell, height: clipped.height * cell)
            ScreenshotRenderer.drawImage(crop, in: rect, context: context)
            context.restoreGState()
        }
        context.setStrokeColor(NSColor(red: 0, green: 0.76, blue: 0.48, alpha: 1).cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: zoom.midX, y: zoom.minY))
        context.addLine(to: CGPoint(x: zoom.midX, y: zoom.maxY))
        context.move(to: CGPoint(x: zoom.minX, y: zoom.midY))
        context.addLine(to: CGPoint(x: zoom.maxX, y: zoom.midY))
        context.strokePath()
        func label(_ text: String, x: CGFloat, y: CGFloat, color: NSColor = .white, size: CGFloat = 12) {
            (text as NSString).draw(
                at: CGPoint(x: card.minX + x, y: card.minY + y),
                withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: size, weight: .medium), .foregroundColor: color,
                ])
        }
        label(L.t("Pixel", "坐标"), x: 12, y: 147)
        let coordinates = "\(sample.x), \(sample.y)"
        let coordinateSize: CGFloat = coordinates.count > 10 ? 10 : 12
        label(coordinates, x: 59, y: 147, size: coordinateSize)
        label(L.t("Color", "色值"), x: 12, y: 170)
        label(sample.hex, x: 87, y: 170)
        label(L.t("⌘C to copy color", "按 ⌘C 复制色值"), x: 12, y: 195, color: .gray, size: 11)
    }

    override func draw(_ dirtyRect: NSRect) {
        // 父视图不重复绘制遮罩，所有交互绘制只由透明子层触发。
    }
    func drawInteraction(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        defer { drawCursorCard(in: context) }
        context.setFillColor(NSColor.black.withAlphaComponent(0.42).cgColor)
        context.beginPath()
        context.addRect(bounds)
        if selection.width > 0, selection.height > 0 { context.addRect(selection) }
        context.drawPath(using: .eoFill)
        guard selection.width > 0, selection.height > 0 else { return }
        context.saveGState()
        context.clip(to: selection)
        if let preview { ScreenshotRenderer.drawImage(preview, in: selection, context: context) }
        context.saveGState()
        context.translateBy(x: selection.minX, y: selection.minY)
        mosaicPreview.draw(in: context)
        if let transient, transient.tool != .mosaic { ScreenshotRenderer.draw(transient, in: context) }
        context.restoreGState()
        if let rect = mosaicCursorRect { ScreenshotMosaicCursor.draw(rect, in: context) }
        context.restoreGState()
        context.setStrokeColor(NSColor(red: 0, green: 0.76, blue: 0.48, alpha: 1).cgColor)
        context.setLineWidth(1)
        context.stroke(selection)
        if state.canAdjust {
            for point in handles {
                context.setFillColor(NSColor(red: 0, green: 0.76, blue: 0.48, alpha: 1).cgColor)
                context.fill(CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
            }
        }
        let pixels = ScreenshotGeometry.pixelRect(
            selection, pointSize: bounds.size,
            pixelSize: CGSize(width: capture.image.width, height: capture.image.height))
        drawLabel(
            "\(Int(pixels.width)) × \(Int(pixels.height))",
            at: CGPoint(
                x: selection.minX,
                y: max(4, selection.minY - 25)))
    }
    private func drawLabel(_ text: String, at point: CGPoint) {
        (text as NSString).draw(
            at: point,
            withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white, .backgroundColor: NSColor.black.withAlphaComponent(0.65),
            ])
    }
    private var handles: [CGPoint] {
        [
            CGPoint(x: selection.minX, y: selection.minY), CGPoint(x: selection.midX, y: selection.minY),
            CGPoint(x: selection.maxX, y: selection.minY), CGPoint(x: selection.maxX, y: selection.midY),
            CGPoint(x: selection.maxX, y: selection.maxY), CGPoint(x: selection.midX, y: selection.maxY),
            CGPoint(x: selection.minX, y: selection.maxY), CGPoint(x: selection.minX, y: selection.midY),
        ]
    }
    private func location(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(0, p.x), bounds.width), y: min(max(0, p.y), bounds.height))
    }
    override func mouseDown(with event: NSEvent) {
        guard !state.busy, coordinator?.claim(capture.screen.id) == true else { return }
        commitText()
        if window?.isVisible == true { window?.makeKeyAndOrderFront(nil) }
        window?.makeFirstResponder(self)
        anchor = location(event)
        updateCursor(at: anchor)
        originalSelection = selection
        state.error = nil
        if selectedImage == nil {
            drag = .selection
            toolbar?.isHidden = true
            selection = CGRect(origin: anchor, size: .zero)
        } else if state.tool == .select, state.canAdjust {
            if let index = handles.firstIndex(where: { hypot($0.x - anchor.x, $0.y - anchor.y) <= 9 }) {
                drag = .resize(index)
            } else if selection.contains(anchor) {
                drag = .move
            } else {
                return
            }
            toolbar?.isHidden = true
        } else if selection.contains(anchor) {
            let p = CGPoint(x: anchor.x - selection.minX, y: anchor.y - selection.minY)
            if state.tool == .text {
                beginText(at: p)
                drag = .textSizing
                hideCursorCard()
                return
            }
            guard state.tool != .select else { return }
            let annotation = state.annotation(at: p)
            transient = annotation
            mosaicPreview.begin(annotation, preceding: state.history.annotations)
            requestMosaicPreview()
            drag = .annotation
            hideCursorCard()
        }
        drawingSurface?.needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard !state.busy, let drag else { return }
        let p = location(event)
        let previousSelection = selection
        let previousStroke = transient?.coverageBounds.offsetBy(dx: selection.minX, dy: selection.minY)
        updateCursor(at: p)
        switch drag {
        case .textSizing:
            textEditor?.resizeForCreation(delta: CGPoint(x: p.x - anchor.x, y: p.y - anchor.y))
        case .selection: selection = ScreenshotGeometry.rect(from: anchor, to: p)
        case .move:
            selection.origin.x = min(max(0, originalSelection.minX + p.x - anchor.x), bounds.width - selection.width)
            selection.origin.y = min(max(0, originalSelection.minY + p.y - anchor.y), bounds.height - selection.height)
        case .resize(let index):
            var x1 = originalSelection.minX
            var x2 = originalSelection.maxX
            var y1 = originalSelection.minY
            var y2 = originalSelection.maxY
            if [0, 6, 7].contains(index) { x1 = p.x }
            if [2, 3, 4].contains(index) { x2 = p.x }
            if [0, 1, 2].contains(index) { y1 = p.y }
            if [4, 5, 6].contains(index) { y2 = p.y }
            selection = ScreenshotGeometry.rect(from: CGPoint(x: x1, y: y1), to: CGPoint(x: x2, y: y2))
        case .annotation:
            let local = CGPoint(
                x: min(max(p.x - selection.minX, 0), selection.width),
                y: min(max(p.y - selection.minY, 0), selection.height))
            transient?.extend(to: local)
            if let transient { mosaicPreview.update(transient) }
            requestMosaicPreview()
        }
        let changed: CGRect
        if case .annotation = drag {
            changed = (previousStroke ?? .zero).union(transient?.coverageBounds.offsetBy(dx: selection.minX, dy: selection.minY) ?? .zero)
        } else { changed = previousSelection.union(selection) }
        drawingSurface?.setNeedsDisplay(changed.insetBy(dx: -32, dy: -32))
    }
    override func mouseUp(with event: NSEvent) {
        guard let drag else { return }
        mouseDragged(with: event)
        self.drag = nil
        switch drag {
        case .textSizing: textEditor?.finishCreationSizing()
        case .annotation:
            if let transient, transient.canCommit {
                state.history.append(transient)
            }
            mosaicPreview.end(commit: transient?.canCommit == true)
            transient = nil
            updatePreview()
        default:
            guard selection.width >= 2, selection.height >= 2 else {
                coordinator?.reselect()
                return
            }
            let pixelRect = ScreenshotGeometry.pixelRect(
                selection, pointSize: bounds.size,
                pixelSize: CGSize(width: capture.image.width, height: capture.image.height))
            selectedImage = capture.image.cropping(to: pixelRect)
            preview = nil
            coordinator?.didSelect()
        }
        hideCursorCard()
        showToolbar()
        drawingSurface?.needsDisplay = true
    }
    func showToolbar() {
        if toolbar == nil {
            let hosting = NSHostingView(rootView: ScreenshotToolbar(state: state))
            toolbar = hosting
            addSubview(hosting)
        }
        guard let toolbar else { return }
        let height = state.toolbarHeight
        let width = state.toolbarWidth
        let x = min(max(8, selection.maxX - width), max(8, bounds.width - width - 8))
        var y = selection.maxY + 10
        if y + height > bounds.height - 8 { y = selection.minY - height - 10 }
        y = min(max(8, y), max(8, bounds.height - height - 8))
        toolbar.frame = CGRect(x: x, y: y, width: width, height: height)
        toolbar.isHidden = false
    }
    private func showHoverTip(_ target: ScreenshotHoverTarget?) {
        guard let window, let toolbar, !toolbar.isHidden else { hoverTip.hide(); return }
        hoverTip.show(target, in: window)
    }
    private func beginText(at point: CGPoint) {
        let editor = ScreenshotTextView(origin: CGPoint(x: selection.minX + point.x, y: selection.minY + point.y),
            maximumSize: CGSize(width: selection.width - point.x, height: selection.height - point.y),
            style: state.textStyle, color: state.textColor, scale: 1, movementBounds: selection)
        editor.onFontSizeChanged = { [weak state] in state?.textStyle.fontSize = $0 }
        textPosition = point
        textEditor = editor
        addSubview(editor)
        window?.makeFirstResponder(editor)
    }
    private func updateTextAttributes() { textEditor?.apply(style: state.textStyle, color: state.textColor) }
    private func requestMosaicPreview() {
        guard let base = selectedImage else { return }
        mosaicPreview.request(base: base, pointSize: selection.size, visibleRegion: CGRect(origin: .zero, size: selection.size))
    }
    func commitText() {
        guard let editor = textEditor else { return }
        editor.unmarkText()
        let annotation = editor.annotation(at: textPosition)
        editor.dispose()
        textEditor = nil
        window?.makeFirstResponder(self)
        if let annotation {
            state.history.append(annotation)
            updatePreview()
        }
    }
    private func updatePreview() {
        previewTask?.cancel()
        revision += 1
        let version = revision
        guard let base = selectedImage else { return }
        let size = selection.size
        let annotations = state.history.annotations
        previewTask = Task { [weak self] in
            do {
                let image = try await ScreenshotRenderWorker.shared.preview(
                    base: base, pointSize: size, annotations: annotations, session: self?.previewSession)
                guard !Task.isCancelled, let self, self.revision == version else { return }
                self.preview = image
                self.mosaicPreview.acknowledge(annotations)
                self.drawingSurface?.needsDisplay = true
            } catch {
                guard !Task.isCancelled, let self, self.revision == version else { return }
                self.state.error = error.localizedDescription
                self.showToolbar()
            }
        }
        drawingSurface?.needsDisplay = true
    }
    private func perform(_ action: ScreenshotEditorAction) {
        guard !state.busy else { return }
        showHoverTip(nil)
        commitText()
        switch action {
        case .tool(let tool):
            state.tool = tool
            if tool == .text { state.optionsExpanded = true; state.shapesExpanded = false }
            if window?.isVisible == true { window?.invalidateCursorRects(for: self) }
        case .preview: break
        case .undo:
            mosaicPreview.clear()
            state.history.undo()
            updatePreview()
        case .redo:
            mosaicPreview.clear()
            state.history.redo()
            updatePreview()
        case .reselect: coordinator?.reselect()
        case .longScreenshot: coordinator?.startLongScreenshot(from: self)
        case .recognizeText: coordinator?.recognizeText(from: self)
        case .recognizeBarcodes: coordinator?.recognizeText(from: self, kind: .barcodes)
        case .confirm:
            if state.confirmsLongScreenshot { coordinator?.startLongScreenshot(from: self) }
            else { coordinator?.finish(.copy, from: self) }
        case .copy: coordinator?.finish(.copy, from: self)
        case .save: coordinator?.finish(.save, from: self)
        case .pin: coordinator?.finish(.pin, from: self)
        case .cancel: coordinator?.cancel()
        }
        drawingSurface?.needsDisplay = true
        if selectedImage != nil { showToolbar() }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Text editing keeps native selection, clipboard and undo handling, including IME.
        if textEditor != nil { return super.performKeyEquivalent(with: event) }
        guard event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "z": perform(event.modifierFlags.contains(.shift) ? .redo : .undo)
        case "c":
            if let cursorSample {
                if coordinator?.onCopyColor?(cursorSample.hex) != true { NSSound.beep() }
            } else {
                perform(.copy)
            }
        case "s": perform(.save)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
    func resetSelection() {
        dispose()
        selection = .zero
        selectedImage = nil
        preview = nil
        transient = nil
        drag = nil
        state.history = AnnotationHistory()
        state.tool = .select
        state.optionsExpanded = false
        state.shapesExpanded = false
        state.error = nil
        state.busy = false
        drawingSurface?.needsDisplay = true
    }
    func dispose() {
        showHoverTip(nil)
        revision += 1
        hideCursorCard()
        updateMosaicPointer(at: nil)
        mosaicPreview.clear()
        previewTask?.cancel()
        previewTask = nil
        let session = previewSession
        previewSession = UUID()
        Task { await ScreenshotRenderWorker.shared.releasePreview(session: session) }
        textEditor?.dispose()
        textEditor = nil
        toolbar?.removeFromSuperview()
        toolbar = nil
    }
    func releaseDisplayResources() {
        // 窗口退场前清空图层，避免整屏纹理在合成器事务中继续滞留。
        for child in subviews {
            (child as? ScreenshotFrozenBackground)?.image = nil
            child.layer?.contents = nil
            child.layer?.removeAllAnimations()
        }
    }
}

// 静态背景由合成器复用，透明交互层只重绘失效区域；两层均不截获鼠标。
@MainActor private final class ScreenshotFrozenBackground: NSView {
    var image: CGImage?
    init(frame: CGRect, image: CGImage) { self.image = image; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        ScreenshotRenderer.drawImage(image, in: bounds, context: context)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
@MainActor private final class ScreenshotDrawingSurface: NSView {
    weak var owner: ScreenshotOverlay?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { owner?.drawInteraction(dirtyRect) }
}
