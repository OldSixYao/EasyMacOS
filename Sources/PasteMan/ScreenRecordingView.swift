import AppKit
import SwiftUI

@MainActor final class ScreenRecordingPresentation {
    private let coordinator: ScreenRecordingCoordinator
    private var selections: [NSPanel] = []
    private(set) var controls: NSPanel?
    private(set) var regionHighlight: NSPanel?
    private var escapeMonitor: Any?
    private var activeDisplay: CGDirectDisplayID?

    init(coordinator: ScreenRecordingCoordinator) {
        self.coordinator = coordinator
        coordinator.onSelection = { [weak self] in self?.showSelection($0) }
        coordinator.onDismissSelection = { [weak self] in self?.dismissSelection() }
        coordinator.onShowControls = { [weak self] in self?.showControls() }
        coordinator.onFinished = { [weak self] in self?.showControls() }
        coordinator.onPresentationChanged = { [weak self] in self?.refreshPresentation() }
    }
    func dismissSelection() {
        for panel in selections {
            (panel.contentView as? RecordingSelectionView)?.dispose()
            panel.close()
            panel.contentView = nil
        }
        selections = []
        activeDisplay = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }
    func closeControls() {
        controls?.close()
        controls = nil
        regionHighlight?.close()
        regionHighlight = nil
    }

    private func refreshPresentation() {
        let active = [.countdown, .starting, .recording, .pausing, .paused, .stopping].contains(coordinator.phase)
        if active, let target = coordinator.target {
            let rect = CGRect(x: target.displayFrame.minX + target.rect.minX,
                              y: target.displayFrame.maxY - target.rect.maxY,
                              width: target.rect.width, height: target.rect.height)
            if regionHighlight == nil {
                let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
                panel.identifier = NSUserInterfaceItemIdentifier("recording.regionHighlight")
                panel.title = L.t("Recording region", "录制区域")
                panel.isReleasedWhenClosed = false
                panel.hidesOnDeactivate = false
                panel.ignoresMouseEvents = true
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.animationBehavior = .none
                panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue)
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                panel.contentView = RecordingRegionHighlight(frame: CGRect(origin: .zero, size: panel.frame.size))
                regionHighlight = panel
                panel.orderFrontRegardless()
            }
            (regionHighlight?.contentView as? RecordingRegionHighlight)?.paused = coordinator.phase == .paused
        } else {
            regionHighlight?.close()
            regionHighlight = nil
        }
        guard let controls else { return }
        if coordinator.phase == .idle && coordinator.savedURL == nil { closeControls(); return }
        let size = ScreenRecordingControls.size(for: coordinator.phase)
        guard controls.frame.size != size else { return }
        // 状态切换只调整尺寸，不跳回初始位置；保留用户拖动后的左上角。
        var frame = controls.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        let visible = controls.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        if let visible {
            frame.origin.x = min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - size.width))
            frame.origin.y = min(max(frame.minY, visible.minY), max(visible.minY, visible.maxY - size.height))
        }
        controls.setFrame(frame, display: true)
    }

    static func controlsFrame(size: CGSize, visible: CGRect, region: CGRect?) -> CGRect {
        let margin: CGFloat = 10
        let area = visible.insetBy(dx: margin, dy: margin)
        func fit(_ origin: CGPoint) -> CGRect {
            CGRect(x: min(max(origin.x, area.minX), max(area.minX, area.maxX - size.width)),
                   y: min(max(origin.y, area.minY), max(area.minY, area.maxY - size.height)),
                   width: size.width, height: size.height)
        }
        if let region {
            let candidates = [
                CGPoint(x: region.midX - size.width / 2, y: region.maxY + margin),
                CGPoint(x: region.midX - size.width / 2, y: region.minY - margin - size.height),
                CGPoint(x: region.maxX + margin, y: region.midY - size.height / 2),
                CGPoint(x: region.minX - margin - size.width, y: region.midY - size.height / 2),
            ].map(fit)
            if let outside = candidates.first(where: { !$0.intersects(region.insetBy(dx: -3, dy: -3)) }) { return outside }
        }
        return fit(CGPoint(x: area.midX - size.width / 2, y: area.maxY - size.height))
    }

    private func showSelection(_ mode: ScreenRecordingCoordinator.Mode) {
        dismissSelection()
        closeControls()
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { continue }
            let panel = ScreenshotPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.animationBehavior = .none
            panel.acceptsMouseMovedEvents = true
            panel.onCancel = { [weak coordinator] in coordinator?.cancelSelection() }
            let overlay = RecordingSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size), mode: mode,
                                                displayScale: screen.backingScaleFactor)
            overlay.claim = { [weak self] in
                guard let self else { return false }
                if let activeDisplay = self.activeDisplay { return activeDisplay == id }
                self.activeDisplay = id
                return true
            }
            overlay.onReselect = { [weak self] in
                self?.activeDisplay = nil
                for panel in self?.selections ?? [] { (panel.contentView as? RecordingSelectionView)?.resetSelection() }
            }
            overlay.onCancel = { [weak coordinator] in coordinator?.cancelSelection() }
            overlay.onConfirm = { [weak coordinator] rect in
                let global = CGRect(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY,
                                    width: rect.width, height: rect.height)
                if let target = ScreenRecordingTarget.region(displayID: id, frame: screen.frame,
                    scale: screen.backingScaleFactor, globalRect: global) { coordinator?.confirm(target) }
            }
            panel.contentView = overlay
            selections.append(panel)
        }
        for panel in selections { panel.orderFrontRegardless() }
        let panel = selections.first { $0.frame.contains(NSEvent.mouseLocation) } ?? selections.first
        panel?.makeKeyAndOrderFront(nil)
        if let view = panel?.contentView { panel?.makeFirstResponder(view) }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator] event in
            if event.keyCode == 53 { coordinator?.cancelSelection(); return nil }
            return event
        }
    }

    private func showControls() {
        if let controls { refreshPresentation(); controls.orderFrontRegardless(); return }
        let size = ScreenRecordingControls.size(for: coordinator.phase)
        let panel = RecordingControlsPanel(contentRect: CGRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = L.t("Screen recording", "屏幕录制")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.animationBehavior = .none
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ScreenRecordingControls(coordinator: coordinator, close: { [weak self] in self?.closeControls() }))
        let target = coordinator.target
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == target?.displayID
        } ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let region = coordinator.mode == .region ? target.map {
                CGRect(x: $0.displayFrame.minX + $0.rect.minX, y: $0.displayFrame.maxY - $0.rect.maxY,
                       width: $0.rect.width, height: $0.rect.height)
            } : nil
            panel.setFrame(Self.controlsFrame(size: size, visible: frame, region: region), display: false)
        }
        controls = panel
        refreshPresentation()
        panel.orderFrontRegardless()
        // 倒计时期间也允许退出键取消，不依赖应用是否为前台。
        panel.makeKeyAndOrderFront(nil)
    }

}

@MainActor private final class RecordingControlsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 透明中心和鼠标穿透使用户可直接操作录制区域，窗口由采集过滤器排除。
@MainActor final class RecordingRegionHighlight: NSView {
    var paused = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.compositingOperation = .copy
        NSColor.clear.setFill()
        bounds.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        let edge = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        NSColor.white.withAlphaComponent(0.95).setStroke()
        edge.lineWidth = 3
        edge.stroke()
        (paused ? NSColor.systemOrange : NSColor.systemRed).setStroke()
        edge.lineWidth = 1.5
        edge.stroke()
    }
}

/// 原生按钮增加独立跟踪，按钮上方的鼠标事件不会依赖父视图命中。
@MainActor final class RecordingSelectionButton: NSButton {
    var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    var refreshPointer: (() -> Void)?
    private var hoverTracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate], owner: self)
        hoverTracking = area
        addTrackingArea(area)
    }
    override func cursorUpdate(with event: NSEvent) { refreshPointer?() }
    override func mouseMoved(with event: NSEvent) { refreshPointer?() }
    override func mouseEntered(with event: NSEvent) { refreshPointer?() }
    override func mouseExited(with event: NSEvent) { hovered = false; refreshPointer?() }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard hovered, isEnabled else { return }
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 6, yRadius: 6)
        NSColor.white.withAlphaComponent(0.16).setFill()
        shape.fill()
        NSColor.white.withAlphaComponent(0.5).setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
}

@MainActor final class RecordingSelectionView: NSView {
    let mode: ScreenRecordingCoordinator.Mode
    private let displayScale: CGFloat
    var claim: (() -> Bool)?
    var onConfirm: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onReselect: (() -> Void)?
    private(set) var selection = CGRect.zero
    private var anchor = CGPoint.zero
    private var original = CGRect.zero
    private enum Drag { case new, move, resize(Int) }
    private var drag = Drag.new
    private(set) var selectionToolbar: NSVisualEffectView!
    private var dragging = false
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var pointerMonitor: Any?
    private(set) var selectionButtons: [RecordingSelectionButton] = []

    // 由同一套鼠标跟踪统一更新，避免系统光标区域与手动 set 相互覆盖。
    override func resetCursorRects() { }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        dispose()
        guard let window else { return }
        window.acceptsMouseMovedEvents = true
        pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            guard let self, event.window === self.window, self.window?.isVisible == true else { return event }
            self.updatePointer(at: self.convert(event.locationInWindow, from: nil))
            return event
        }
    }
    func dispose() {
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        pointerMonitor = nil
        for button in selectionButtons { button.hovered = false }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.activeAlways, .inVisibleRect, .cursorUpdate, .mouseMoved, .mouseEnteredAndExited], owner: self)
        tracking = area
        addTrackingArea(area)
    }
    override func cursorUpdate(with event: NSEvent) { updatePointer(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { updatePointer(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { updatePointer(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) {
        for button in selectionButtons { button.hovered = false }
        NSCursor.arrow.set()
    }
    func pointerCursor(at point: CGPoint) -> NSCursor {
        if dragging {
            switch drag {
            case .move: return .closedHand
            case .new: return .crosshair
            case .resize(let edges): return resizeCursor(edges)
            }
        }
        if !selectionToolbar.isHidden && selectionToolbar.frame.contains(point) {
            let hitButton = selectionButtons.contains {
                $0.isEnabled && $0.bounds.contains($0.convert(point, from: self))
            }
            return hitButton ? .pointingHand : .arrow
        }
        guard bounds.contains(point) else { return .arrow }
        if mode == .region, let edges = resizeEdges(at: point) { return resizeCursor(edges) }
        if mode == .region && selection.contains(point) { return .openHand }
        return selection.isEmpty ? .crosshair : .arrow
    }
    private func resizeCursor(_ edges: Int) -> NSCursor {
        switch edges {
        case 5: .frameResize(position: .topLeft, directions: .all)
        case 6: .frameResize(position: .topRight, directions: .all)
        case 9: .frameResize(position: .bottomLeft, directions: .all)
        case 10: .frameResize(position: .bottomRight, directions: .all)
        case 1, 2: .resizeLeftRight
        default: .resizeUpDown
        }
    }
    private func updatePointer(at point: CGPoint) {
        for button in selectionButtons {
            button.hovered = !dragging && !selectionToolbar.isHidden && button.isEnabled
                && button.bounds.contains(button.convert(point, from: self))
        }
        pointerCursor(at: point).set()
    }

    private func resizeEdges(at point: CGPoint) -> Int? {
        guard !selection.isEmpty, selection.insetBy(dx: -8, dy: -8).contains(point) else { return nil }
        var edges = 0
        if abs(point.x - selection.minX) <= 8 { edges |= 1 }
        if abs(point.x - selection.maxX) <= 8 { edges |= 2 }
        if abs(point.y - selection.minY) <= 8 { edges |= 4 }
        if abs(point.y - selection.maxY) <= 8 { edges |= 8 }
        return edges == 0 ? nil : edges
    }
    private func updateSelectionUI() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        selectionToolbar.isHidden = dragging || selection.width < 8 || selection.height < 8
        if selectionToolbar.isHidden {
            for button in selectionButtons { button.hovered = false }
            return
        }
        let size = selectionToolbar.frame.size
        let x = min(max(8, selection.maxX - size.width), max(8, bounds.width - size.width - 8))
        var y = selection.maxY + 10
        if y + size.height > bounds.height - 8 { y = selection.minY - size.height - 10 }
        y = min(max(8, y), max(8, bounds.height - size.height - 8))
        selectionToolbar.setFrameOrigin(CGPoint(x: x, y: y))
        selectionToolbar.layoutSubtreeIfNeeded()
        if let window { updatePointer(at: convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
    }

    init(frame: CGRect, mode: ScreenRecordingCoordinator.Mode, displayScale: CGFloat = 1) {
        self.mode = mode
        self.displayScale = displayScale
        super.init(frame: frame)
        let start = RecordingSelectionButton(title: L.t("Start ↩", "开始录制 ↩"), target: self, action: #selector(confirm))
        start.setAccessibilityIdentifier("recording.selection.start")
        let reselect = RecordingSelectionButton(title: L.t("Reselect", "重新选择"), target: self, action: #selector(reselect))
        reselect.setAccessibilityIdentifier("recording.selection.reselect")
        let cancel = RecordingSelectionButton(title: L.t("Cancel ⎋", "取消 ⎋"), target: self, action: #selector(cancel))
        cancel.setAccessibilityIdentifier("recording.selection.cancel")
        let stack = NSStackView(views: [start, reselect, cancel])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.distribution = .fillEqually
        for button in [start, reselect, cancel] { button.bezelStyle = .rounded; button.setButtonType(.momentaryPushIn) }
        selectionButtons = [start, reselect, cancel]
        for button in selectionButtons {
            button.toolTip = button.title
            button.refreshPointer = { [weak self] in
                guard let self, let window = self.window else { return }
                self.updatePointer(at: self.convert(window.mouseLocationOutsideOfEventStream, from: nil))
            }
        }
        start.bezelColor = .systemRed
        let toolbar = NSVisualEffectView(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        toolbar.material = .popover
        toolbar.state = .active
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 9
        toolbar.layer?.masksToBounds = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
        ])
        selectionToolbar = toolbar
        toolbar.isHidden = true
        addSubview(toolbar)
    }
    required init?(coder: NSCoder) { nil }
    func resetSelection() { selection = .zero; dragging = false; updateSelectionUI() }
    @objc private func confirm() { if selection.width >= 8 && selection.height >= 8 { onConfirm?(selection) } }
    @objc private func reselect() { onReselect?() }
    @objc private func cancel() { onCancel?() }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: confirm()
        case 53: cancel()
        default: super.keyDown(with: event)
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard claim?() == true else { return }
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        anchor = convert(event.locationInWindow, from: nil)
        if mode == .fullScreen { selection = bounds; updateSelectionUI(); return }
        original = selection
        dragging = true
        if let edges = resizeEdges(at: anchor) { drag = .resize(edges) }
        else if selection.contains(anchor) { drag = .move; NSCursor.closedHand.set() }
        else { drag = .new; selection = .zero }
        updateSelectionUI()
    }
    override func mouseDragged(with event: NSEvent) {
        guard mode == .region, dragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        let clamped = CGPoint(x: min(bounds.maxX, max(0, point.x)), y: min(bounds.maxY, max(0, point.y)))
        switch drag {
        case .new: selection = ScreenshotGeometry.rect(from: anchor, to: clamped).intersection(bounds)
        case .move:
            selection.origin = CGPoint(x: min(bounds.width - original.width, max(0, original.minX + point.x - anchor.x)),
                                       y: min(bounds.height - original.height, max(0, original.minY + point.y - anchor.y)))
        case .resize(let edges):
            let left = edges & 1 != 0 ? clamped.x : original.minX
            let right = edges & 2 != 0 ? clamped.x : original.maxX
            let top = edges & 4 != 0 ? clamped.y : original.minY
            let bottom = edges & 8 != 0 ? clamped.y : original.maxY
            selection = ScreenshotGeometry.rect(from: CGPoint(x: left, y: top), to: CGPoint(x: right, y: bottom))
        }
        updateSelectionUI()
    }
    override func mouseUp(with event: NSEvent) {
        dragging = false
        updateSelectionUI()
        cursorUpdate(with: event)
    }
    override func rightMouseDown(with event: NSEvent) { cancel() }
    override func draw(_ dirtyRect: NSRect) {
        // 完全透明的窗口像素会被窗口服务器穿透，选区内保留极浅底色以接收移动手势。
        // 每次重绘先覆盖旧遮罩，避免移动后留下上一处选区的残影。
        NSGraphicsContext.current?.compositingOperation = .copy
        NSColor.white.withAlphaComponent(0.035).setFill()
        bounds.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        let shade = NSBezierPath(rect: bounds)
        shade.appendRect(selection)
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.48).setFill(); shade.fill()
        if !selection.isEmpty {
            NSColor.systemRed.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: 0.75, dy: 0.75)); border.lineWidth = 1.5; border.stroke()
            if mode == .region {
                for x in [selection.minX, selection.midX, selection.maxX] {
                    for y in [selection.minY, selection.midY, selection.maxY] where x != selection.midX || y != selection.midY {
                        let handle = NSBezierPath(ovalIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6))
                        NSColor.white.setFill(); handle.fill(); handle.stroke()
                    }
                }
                drawSelectionSize()
            }
        }
        let text = mode == .fullScreen
            ? L.t("Click a display, then Start or Enter · Escape to cancel", "点击显示器，再点击开始或按回车 · 退出键取消")
            : L.t("Drag a region · Adjust edges · Enter to start", "拖动框选区域 · 拖动边缘调整 · 回车开始")
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        if selection.isEmpty {
            (text as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: bounds.height - 50), withAttributes: attrs)
        }
    }

    private func drawSelectionSize() {
        let pixels = ScreenshotGeometry.pixelRect(selection, pointSize: bounds.size,
            pixelSize: CGSize(width: bounds.width * displayScale, height: bounds.height * displayScale))
        let text = "\(Int(pixels.width)) × \(Int(pixels.height)) " + L.t("px", "像素")
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.65),
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        var point = CGPoint(
            x: min(max(4, selection.minX), max(4, bounds.maxX - size.width - 4)),
            y: min(max(4, selection.minY - 25), max(4, bounds.maxY - size.height - 4)))
        if !selectionToolbar.isHidden, selectionToolbar.frame.intersects(CGRect(origin: point, size: size)) {
            let above = selectionToolbar.frame.minY - size.height - 6
            point.y = above >= 4 ? above : min(bounds.maxY - size.height - 4, selectionToolbar.frame.maxY + 6)
        }
        (text as NSString).draw(at: point, withAttributes: attrs)
    }
}

struct ScreenRecordingControls: View {
    @Bindable var coordinator: ScreenRecordingCoordinator
    var close: () -> Void

    static func size(for phase: ScreenRecordingCoordinator.Phase) -> CGSize {
        switch phase {
        case .failed: CGSize(width: 390, height: 130)
        case .idle: CGSize(width: 350, height: 96)
        default: CGSize(width: 244, height: 44)
        }
    }

    var body: some View {
        Group {
            switch coordinator.phase {
            case .idle: savedControls
            case .failed: failureControls
            default: compactControls
            }
        }
        .frame(width: Self.size(for: coordinator.phase).width, height: Self.size(for: coordinator.phase).height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
    }

    private var compactControls: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .help(L.t("Drag to move", "拖动以移动"))
            switch coordinator.phase {
            case .countdown:
                Text(L.t("Starting in", "即将开始") + " \(coordinator.countdown)")
                    .font(.system(size: 13, weight: .medium)).monospacedDigit()
                Spacer(minLength: 0)
                iconButton("xmark", title: L.t("Cancel", "取消"), id: "recording.cancel") {
                    coordinator.cancelSelection(); close()
                }.keyboardShortcut(.cancelAction)
            case .recording, .paused:
                Circle().fill(coordinator.phase == .paused ? Color.orange : .red).frame(width: 7, height: 7)
                Text(coordinator.timeLabel).font(.system(size: 13, weight: .medium, design: .monospaced))
                    .accessibilityLabel((coordinator.phase == .paused ? L.t("Paused", "已暂停") : L.t("Recording", "录制中")) + " " + coordinator.timeLabel)
                Spacer(minLength: 0)
                iconButton(coordinator.phase == .paused ? "play.fill" : "pause.fill",
                           title: coordinator.phase == .paused ? L.t("Resume", "继续") : L.t("Pause", "暂停"),
                           id: "recording.pause") { coordinator.togglePause() }
                iconButton("stop.fill", title: L.t("Stop and save", "停止并保存"), id: "recording.stop", tint: .red) { coordinator.stop() }
            case .saving:
                ProgressView(value: coordinator.saveProgress).frame(width: 62)
                Text(L.t("Saving", "保存中") + " \(Int(coordinator.saveProgress * 100))%")
                    .font(.system(size: 12)).monospacedDigit()
            default:
                ProgressView().controlSize(.small)
                Text(L.t("Preparing recording…", "正在处理录屏…")).font(.system(size: 12))
            }
        }
        .padding(.horizontal, 12)
    }

    private func iconButton(_ symbol: String, title: String, id: String, tint: Color = .primary,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(RecordingControlHover())
        .help(title).accessibilityLabel(title).accessibilityIdentifier(id)
    }

    private var savedControls: some View {
        VStack(spacing: 10) {
            if let url = coordinator.savedURL {
                Text(L.t("Recording saved", "录屏已保存")).font(.headline)
                HStack {
                    Button(L.t("Open video", "打开视频")) {
                        NSWorkspace.shared.open(url)
                        close()
                    }.accessibilityIdentifier("recording.openVideo")
                    Button(L.t("Show in Finder", "在访达中显示")) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                        close()
                    }.accessibilityIdentifier("recording.showInFinder")
                    Button(L.t("Close", "关闭"), action: close).accessibilityIdentifier("recording.close")
                }
                if let message = coordinator.errorMessage { Text(message).font(.caption).foregroundStyle(.orange).lineLimit(2) }
            }
        }.padding(12)
    }
    private var failureControls: some View {
        VStack(spacing: 10) {
            Text(coordinator.errorMessage ?? "").font(.caption).lineLimit(3)
            HStack {
                if !coordinator.segments.isEmpty { Button(L.t("Retry saving", "重试保存")) { coordinator.retrySave() } }
                if let folder = coordinator.sessionDirectory {
                    Button(L.t("Show segments", "定位片段")) { NSWorkspace.shared.open(folder) }
                }
                Button(L.t("Keep and close", "保留并关闭")) { coordinator.keepForRecovery(); close() }
            }
        }.padding(12)
    }
}

private struct RecordingControlHover: ViewModifier {
    @ViewState private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(hovering ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
    }
}
