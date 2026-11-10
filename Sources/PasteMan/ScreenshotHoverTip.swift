import AppKit
import SwiftUI

struct ScreenshotHoverTarget {
    let title: String
    let detail: String?
    let screenFrame: CGRect
}

@MainActor final class ScreenshotHoverReference {
    weak var view: ScreenshotHoverAnchorView?
}

/// 按钮自身提供屏幕坐标，提示不依赖工具栏高度或进入时的鼠标位置。
struct ScreenshotHoverAnchor: NSViewRepresentable {
    let title: String
    let detail: String?
    let reference: ScreenshotHoverReference
    let changed: (ScreenshotHoverTarget?) -> Void

    func makeNSView(context: Context) -> ScreenshotHoverAnchorView {
        let view = ScreenshotHoverAnchorView()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: ScreenshotHoverAnchorView, context: Context) {
        view.title = title
        view.detail = detail
        view.changed = changed
        reference.view = view
    }
    static func dismantleNSView(_ view: ScreenshotHoverAnchorView, coordinator: ()) {
        view.endHover()
        view.changed = nil
    }
}

@MainActor final class ScreenshotHoverAnchorView: NSView {
    var title = ""
    var detail: String?
    var changed: ((ScreenshotHoverTarget?) -> Void)?
    private var hovering = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func mouseEntered(with event: NSEvent) { beginHover() }
    override func mouseMoved(with event: NSEvent) { if !hovering { beginHover() } }
    override func mouseExited(with event: NSEvent) { endHover() }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { endHover() }
        super.viewWillMove(toWindow: newWindow)
    }
    func beginHover() {
        guard let window, !bounds.isEmpty else { return }
        hovering = true
        changed?(ScreenshotHoverTarget(title: title, detail: detail,
            screenFrame: window.convertToScreen(convert(bounds, to: nil))))
    }
    func endHover() {
        guard hovering else { return }
        hovering = false
        changed?(nil)
    }
}

@MainActor final class ScreenshotHoverTip {
    private(set) var panel: NSPanel?

    func hide() {
        if let panel { panel.parent?.removeChildWindow(panel) }
        panel?.close()
        panel?.contentView = nil
        panel = nil
    }
    static func frame(size: CGSize, anchor: CGRect, screen: CGRect) -> CGRect {
        let margin: CGFloat = 4, gap: CGFloat = 5
        let below = anchor.minY - gap - size.height
        let y = below >= screen.minY + margin ? below : anchor.maxY + gap
        return CGRect(x: max(screen.minX + margin, min(anchor.midX - size.width / 2, screen.maxX - size.width - margin)),
            y: max(screen.minY + margin, min(y, screen.maxY - size.height - margin)), width: size.width, height: size.height)
    }
    func show(_ target: ScreenshotHoverTarget?, in window: NSWindow) {
        hide()
        guard let target, !target.title.isEmpty, !target.screenFrame.isEmpty, window.isVisible else { return }
        // 可见提示只显示简短名称，详细说明保留在按钮的辅助功能提示中。
        let label = NSTextField(wrappingLabelWithString: target.title)
        let font = NSFont.systemFont(ofSize: 11)
        label.font = font
        label.textColor = .labelColor
        // 使用控件自身的排版尺寸，计入内部留白、实际行高与换行，避免文字被裁切。
        let measured = label.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: 280,
            height: CGFloat.greatestFiniteMagnitude)) ?? label.intrinsicContentSize
        let size = CGSize(width: ceil(measured.width) + 16, height: max(26, ceil(measured.height) + 12))
        let center = CGPoint(x: target.screenFrame.midX, y: target.screenFrame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) }?.visibleFrame ?? window.screen?.visibleFrame ?? window.frame
        let tip = NSPanel(contentRect: Self.frame(size: size, anchor: target.screenFrame, screen: screen),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        tip.isReleasedWhenClosed = false
        tip.animationBehavior = .none
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
        label.frame = CGRect(x: 8, y: 6, width: size.width - 16, height: size.height - 12)
        background.addSubview(label)
        tip.contentView = background
        window.addChildWindow(tip, ordered: .above)
        tip.orderFrontRegardless()
        panel = tip
    }
}
