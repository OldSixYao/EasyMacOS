import AppKit
import CoreText

/// 普通截图和独立编辑画布共用透明输入框，字号始终以原图中的点数保存。
@MainActor final class ScreenshotTextView: NSTextView {
    private(set) var annotationStyle: AnnotationTextStyle
    private(set) var annotationColor: AnnotationColor
    let logicalScale: CGFloat
    private let backingStorage: NSTextStorage
    private let initialOrigin: CGPoint
    private let movementBounds: CGRect
    private var maximumSize: CGSize {
        CGSize(width: movementBounds.maxX - frame.minX, height: movementBounds.maxY - frame.minY)
    }
    var onFontSizeChanged: ((CGFloat) -> Void)?
    private var resizeStart: (point: CGPoint, size: CGSize, fontSize: CGFloat)?
    private var moveStart: (point: CGPoint, origin: CGPoint)?
    private var pointerTracking: NSTrackingArea?
    private var disposed = false
    private var sizingCreation = false
    private static let resizeCursor = NSCursor.frameResize(position: .bottomRight, directions: .all)
    var resizeHandleRect: CGRect { CGRect(x: max(0, bounds.width - 12), y: max(0, bounds.height - 12), width: 12, height: 12) }
    private var moveRegions: [CGRect] {
        let thickness: CGFloat = min(6, bounds.width / 2, bounds.height / 2)
        return [CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: thickness),
            CGRect(x: bounds.minX, y: bounds.maxY - thickness, width: bounds.width, height: thickness),
            CGRect(x: bounds.minX, y: bounds.minY, width: thickness, height: bounds.height),
            CGRect(x: bounds.maxX - thickness, y: bounds.minY, width: thickness, height: bounds.height)]
    }

    init(origin: CGPoint, maximumSize: CGSize, style: AnnotationTextStyle, color: AnnotationColor, scale: CGFloat,
         movementBounds: CGRect? = nil) {
        annotationStyle = style; annotationColor = color
        logicalScale = max(0.001, scale)
        initialOrigin = origin
        self.movementBounds = movementBounds ?? CGRect(origin: .zero,
            size: CGSize(width: origin.x + maximumSize.width, height: origin.y + maximumSize.height))
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: CGSize(width: 100_000, height: 100_000))
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        backingStorage = storage
        super.init(frame: CGRect(origin: origin, size: CGSize(width: 120, height: 44)), textContainer: container)
        drawsBackground = false
        backgroundColor = .clear
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        textContainer?.containerSize = CGSize(width: 100_000, height: 100_000)
        layoutManager?.usesFontLeading = true
        toolTip = L.t("Drag the border to move text. Drag the bottom-right handle to resize it.",
            "拖动边框移动文字，拖动右下角控制点调整字号。")
        apply(style: style, color: color)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(style: AnnotationTextStyle, color: AnnotationColor) {
        annotationStyle = style; annotationStyle.fontSize = style.resolvedSize
        annotationColor = color
        let ctFont = style.font(scale: logicalScale)
        let font = NSFont(name: CTFontCopyPostScriptName(ctFont) as String, size: CTFontGetSize(ctFont))
            ?? .systemFont(ofSize: style.resolvedSize * logicalScale)
        self.font = font
        textColor = NSColor(cgColor: color.cgColor)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4 * logicalScale
        let traits = CTFontGetSymbolicTraits(ctFont)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: textColor ?? NSColor.textColor, .paragraphStyle: paragraph,
        ]
        if style.isBold && !traits.contains(.boldTrait) { attributes[.strokeWidth] = -3 }
        if style.isItalic && !traits.contains(.italicTrait) { attributes[.obliqueness] = 0.2 }
        defaultParagraphStyle = paragraph
        typingAttributes = attributes
        if let textStorage, textStorage.length > 0 { textStorage.setAttributes(attributes, range: NSRange(location: 0, length: textStorage.length)) }
        applyFallbackStyles()
        fitText()
        needsDisplay = true
    }

    private func fitText() {
        guard let textContainer, let layoutManager else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let minimumHeight = (font?.ascender ?? 20) - (font?.descender ?? -5) + 14
        setFrameSize(CGSize(width: max(16, min(maximumSize.width, max(100, ceil(used.width) + 16))),
            height: max(16, min(maximumSize.height, max(minimumHeight, ceil(used.height) + 16)))))
        if window?.isVisible == true { window?.invalidateCursorRects(for: self) }
    }
    private func applyFallbackStyles() {
        guard annotationStyle.isItalic, let storage = textStorage, storage.length > 0 else { return }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string,
            attributes: annotationStyle.attributes(color: annotationColor, scale: logicalScale)))
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let range = CTRunGetStringRange(run)
            guard range.location >= 0, range.length > 0, range.location + range.length <= storage.length else { continue }
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let font = attributes[kCTFontAttributeName] as! CTFont
            if !CTFontGetSymbolicTraits(font).contains(.italicTrait) {
                storage.addAttribute(.obliqueness, value: 0.2, range: NSRange(location: range.location, length: range.length))
            }
        }
    }
    override func didChangeText() { super.didChangeText(); applyFallbackStyles(); fitText(); needsDisplay = true }

    func annotation(at point: CGPoint) -> ScreenshotAnnotation? {
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let position = CGPoint(x: point.x + (frame.minX - initialOrigin.x) / logicalScale,
            y: point.y + (frame.minY - initialOrigin.y) / logicalScale)
        return ScreenshotAnnotation(tool: .text, points: [position], color: annotationColor, width: 1,
            text: string, textStyle: annotationStyle)
    }

    func resizeForCreation(delta: CGPoint) {
        guard !disposed, hypot(delta.x * logicalScale, delta.y * logicalScale) >= 4 else { return }
        sizingCreation = true
        onFontSizeChanged?(min(512, max(6, max(abs(delta.y), abs(delta.x) * 0.5))))
        Self.resizeCursor.set()
    }
    func finishCreationSizing() {
        sizingCreation = false
        if !disposed { NSCursor.iBeam.set() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.systemGreen.withAlphaComponent(0.8).setStroke()
        let outline = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.setLineDash([3, 3], count: 2, phase: 0)
        outline.stroke()
        NSColor.systemGreen.setFill()
        resizeHandleRect.insetBy(dx: 2, dy: 2).fill()
        let grip = NSBezierPath()
        grip.move(to: CGPoint(x: bounds.midX - 10, y: 2))
        grip.line(to: CGPoint(x: bounds.midX + 10, y: 2))
        grip.lineWidth = 2
        grip.stroke()
    }
    override func resetCursorRects() {
        guard !disposed else { return }
        super.resetCursorRects()
        for rect in moveRegions { addCursorRect(rect, cursor: .openHand) }
        addCursorRect(resizeHandleRect, cursor: Self.resizeCursor)
    }
    override func updateTrackingAreas() {
        guard !disposed else { return }
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        pointerTracking = nil
        let tracking = NSTrackingArea(rect: .zero,
            options: [.activeAlways, .inVisibleRect, .cursorUpdate, .mouseMoved, .mouseEnteredAndExited, .enabledDuringMouseDrag],
            owner: self)
        pointerTracking = tracking
        addTrackingArea(tracking)
    }
    func pointerCursor(at point: CGPoint) -> NSCursor {
        if disposed { return .arrow }
        if moveStart != nil { return .closedHand }
        if resizeStart != nil || sizingCreation { return Self.resizeCursor }
        guard bounds.contains(point) else { return .arrow }
        if resizeHandleRect.contains(point) { return Self.resizeCursor }
        if moveRegions.contains(where: { $0.contains(point) }) { return .openHand }
        return .iBeam
    }
    private func updatePointer(with event: NSEvent) {
        pointerCursor(at: convert(event.locationInWindow, from: nil)).set()
    }
    override func cursorUpdate(with event: NSEvent) { updatePointer(with: event) }
    override func mouseMoved(with event: NSEvent) { updatePointer(with: event) }
    override func mouseEntered(with event: NSEvent) { updatePointer(with: event) }
    override func mouseExited(with event: NSEvent) {
        if moveStart != nil || resizeStart != nil || sizingCreation { updatePointer(with: event) }
        else { NSCursor.arrow.set() }
    }
    override func mouseDown(with event: NSEvent) {
        guard !disposed else { return }
        let point = convert(event.locationInWindow, from: nil)
        if resizeHandleRect.contains(point) {
            resizeStart = (superview?.convert(event.locationInWindow, from: nil) ?? .zero, bounds.size, annotationStyle.resolvedSize)
            Self.resizeCursor.set()
        } else if moveRegions.contains(where: { $0.contains(point) }) {
            moveStart = (superview?.convert(event.locationInWindow, from: nil) ?? .zero, frame.origin)
            NSCursor.closedHand.set()
        } else { super.mouseDown(with: event) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard !disposed else { return }
        if let start = moveStart {
            let point = superview?.convert(event.locationInWindow, from: nil) ?? start.point
            let oldFrame = frame
            setFrameOrigin(CGPoint(
                x: min(max(movementBounds.minX, start.origin.x + point.x - start.point.x), max(movementBounds.minX, movementBounds.maxX - frame.width)),
                y: min(max(movementBounds.minY, start.origin.y + point.y - start.point.y), max(movementBounds.minY, movementBounds.maxY - frame.height))))
            superview?.setNeedsDisplay(oldFrame.union(frame).insetBy(dx: -1, dy: -1))
            if window?.isVisible == true { window?.invalidateCursorRects(for: self) }
            NSCursor.closedHand.set()
            return
        }
        guard let start = resizeStart else { super.mouseDragged(with: event); return }
        let point = superview?.convert(event.locationInWindow, from: nil) ?? start.point
        let size = CGSize(width: max(1, start.size.width + point.x - start.point.x),
            height: max(1, start.size.height + point.y - start.point.y))
        let ratio = hypot(size.width, size.height) / max(1, hypot(start.size.width, start.size.height))
        onFontSizeChanged?(min(512, max(6, (start.fontSize * ratio * 10).rounded() / 10)))
        Self.resizeCursor.set()
    }
    override func mouseUp(with event: NSEvent) {
        guard !disposed else { return }
        if resizeStart != nil || moveStart != nil {
            mouseDragged(with: event); resizeStart = nil; moveStart = nil
            fitText()
            updatePointer(with: event)
        } else { super.mouseUp(with: event) }
    }
    func dispose() {
        disposed = true
        let ownerWindow = window
        let parent = superview
        if moveStart != nil || resizeStart != nil || sizingCreation { NSCursor.arrow.set() }
        sizingCreation = false
        onFontSizeChanged = nil; resizeStart = nil; moveStart = nil
        // 原生文字控件也会添加追踪区；会话结束后全部移除，禁止晚到布局重新注册。
        for tracking in trackingAreas { removeTrackingArea(tracking) }
        pointerTracking = nil
        discardCursorRects()
        ownerWindow?.discardCursorRects()
        if window?.firstResponder === self { window?.makeFirstResponder(superview) }
        undoManager?.removeAllActions(withTarget: self)
        removeFromSuperview()
        // 先结束本次排版关系，避免原生视图延迟销毁时把文本缓冲带到外层释放池。
        if let layoutManager { backingStorage.removeLayoutManager(layoutManager) }
        if ownerWindow?.isVisible == true, let parent { ownerWindow?.invalidateCursorRects(for: parent) }
    }
}
