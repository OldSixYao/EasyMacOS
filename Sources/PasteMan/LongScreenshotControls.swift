import AppKit
import Observation
import SwiftUI

@MainActor @Observable final class LongScreenshotControlState {
    var width = 0
    var height = 0
    var stopping = false
}

@MainActor final class LongScreenshotControls {
    let state = LongScreenshotControlState()
    private let border: NSPanel
    private let controls: NSPanel
    init(region: LongScreenshotRegion, stop: @escaping () -> Void, cancel: @escaping () -> Void,
         present: (NSPanel) -> Void = { $0.orderFrontRegardless() }) {
        border = NSPanel(contentRect: region.appKitRect.insetBy(dx: -2, dy: -2),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        border.contentView = LongScreenshotBorder(frame: CGRect(origin: .zero, size: border.frame.size))
        border.ignoresMouseEvents = true
        let size = CGSize(width: 460, height: 48)
        let screen = region.screen.frame
        var y = region.appKitRect.minY - size.height - 10
        if y < screen.minY + 8 { y = region.appKitRect.maxY + 10 }
        let origin = CGPoint(x: min(max(screen.minX + 8, region.appKitRect.midX - size.width / 2), screen.maxX - size.width - 8),
            y: min(max(screen.minY + 8, y), screen.maxY - size.height - 8))
        controls = NSPanel(contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        controls.isMovableByWindowBackground = true
        controls.contentView = NSHostingView(rootView: LongScreenshotControlBar(state: state, stop: stop, cancel: cancel))
        for panel in [border, controls] {
            panel.isReleasedWhenClosed = false
            panel.animationBehavior = .none
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false; panel.backgroundColor = .clear
            panel.hasShadow = panel === controls
            panel.hidesOnDeactivate = false
            present(panel)
        }
    }
    func close() {
        for panel in [border, controls] { panel.contentView = nil; panel.close() }
    }
}

private struct LongScreenshotControlBar: View {
    @Bindable var state: LongScreenshotControlState
    let stop: () -> Void
    let cancel: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(state.width == 0 ? L.t("Preparing…", "准备中…") : "\(state.width) × \(state.height)")
                .monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
            Button(L.t("Stop and edit", "停止并编辑")) { state.stopping = true; stop() }
                .disabled(state.stopping)
            Button(L.t("Cancel", "取消"), action: cancel)
        }.font(.system(size: 12)).buttonStyle(.bordered).padding(.horizontal, 14)
            .frame(width: 460, height: 48).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

@MainActor private final class LongScreenshotBorder: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemGreen.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 1; path.stroke()
    }
}
