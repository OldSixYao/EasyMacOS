import AppKit
import SwiftUI
import Testing

@testable import PasteMan

@Suite("截图工具栏点击", .serialized) @MainActor struct ScreenshotToolbarInteractionTests {
    enum Editor: CaseIterable { case screenshot, longScreenshot, pinned }

    @Test(arguments: Editor.allCases)
    func enabledButtonsRespondOnceAtCenterEdgesAndCorners(_ editor: Editor) async throws {
        let state = ScreenshotEditorState()
        state.isLongEditor = editor == .longScreenshot
        state.isPinnedEditor = editor == .pinned
        let annotation = ScreenshotAnnotation(tool: .arrow, points: [.zero, CGPoint(x: 20, y: 20)],
            color: AnnotationColor.palette[0], width: 3)
        state.history.append(annotation)
        state.history.append(annotation)
        state.history.undo()
        var received: [String] = []
        state.action = { received.append(actionName($0)) }
        let host = ToolbarHost(state: state)
        defer { state.action = nil; host.close() }
        try await host.ready()
        var targets = [AnnotationTool.rectangle, .arrow, .pen, .text, .mosaic].map { ($0.title, "tool." + $0.rawValue) }
        targets += [(L.t("Undo ⌘Z", "撤销 ⌘Z"), "undo"), (L.t("Redo ⇧⌘Z", "重做 ⇧⌘Z"), "redo"),
            (L.t("Save PNG…", "保存 PNG…"), "save"), (L.t("Cancel Esc", "取消 Esc"), "cancel")]
        if editor == .screenshot { targets.append((L.t("Reselect", "重新框选"), "reselect")) }
        else {
            targets += ScreenshotPreviewMode.allCases.map { mode in
                (editor == .pinned && mode == .fill ? L.t("Fit image", "适应窗口") : mode.title, "preview." + mode.rawValue)
            }
        }
        if editor == .pinned {
            targets += [(L.t("Copy ⌘C", "复制 ⌘C"), "copy"), (L.t("Apply to pinned image", "应用到贴图"), "confirm")]
        } else {
            targets += [(L.t("Recognize text", "识别文字"), "recognizeText"), (ScreenshotRecognitionKind.barcodes.title, "recognizeBarcodes"),
                (L.t("Pin to desktop", "钉在桌面"), "pin"), (L.t("Finish and copy ⌘C", "完成并复制 ⌘C"), "confirm")]
        }
        for (title, expected) in targets {
            for position in positions {
                let previous = received.count
                try host.click(title, at: position)
                try await Task.sleep(for: .milliseconds(5))
                #expect(received.count == previous + 1 && received.last == expected,
                    "按钮中心、边缘和四角均须单击触发一次对应动作：\(title)，\(position)")
            }
        }
    }

    @Test func expandedColorsAndWidthsRespondInTheirTransparentPadding() async throws {
        let state = ScreenshotEditorState()
        state.optionsExpanded = true
        state.tool = .arrow
        let host = ToolbarHost(state: state)
        defer { host.close() }
        try await host.ready()
        for index in AnnotationColor.palette.indices {
            for position in positions {
                state.colorIndex = (index + 1) % AnnotationColor.palette.count
                try host.click(L.t("Color", "颜色") + " \(index + 1)", at: position)
                #expect(state.colorIndex == index, "圆形色块的矩形留白也应响应")
            }
        }
        for width in [CGFloat(2), 3, 6] {
            for position in positions {
                state.width = 11
                try host.click(L.t("Width", "粗细") + " \(Int(width))", at: position)
                #expect(state.width == width, "粗细按钮的透明留白也应响应")
            }
        }
    }

    @Test func disabledButtonsAndGapsDoNotTriggerActions() async throws {
        let state = ScreenshotEditorState()
        var invocations = 0
        state.action = { _ in invocations += 1 }
        let host = ToolbarHost(state: state)
        defer { state.action = nil; host.close() }
        try await host.ready()
        for title in [L.t("Undo ⌘Z", "撤销 ⌘Z"), L.t("Redo ⇧⌘Z", "重做 ⇧⌘Z")] {
            for position in positions { try host.click(title, at: position) }
        }
        let shape = try host.anchor(AnnotationTool.rectangle.title)
        try host.click(point: shape.convert(CGPoint(x: shape.bounds.maxX + 2, y: shape.bounds.midY), to: nil))
        #expect(invocations == 0, "禁用按钮和按钮间隙不能触发动作")
        state.busy = true
        try await host.ready()
        for title in [AnnotationTool.arrow.title, L.t("Save PNG…", "保存 PNG…"), L.t("Cancel Esc", "取消 Esc")] {
            for position in positions { try host.click(title, at: position) }
        }
        #expect(invocations == 0, "处理中仍应禁用整排按钮")
    }

    @Test(arguments: Editor.allCases)
    func mosaicModesAndSlidersWorkIndependently(_ editor: Editor) async throws {
        let state = ScreenshotEditorState()
        state.isLongEditor = editor == .longScreenshot; state.isPinnedEditor = editor == .pinned
        state.tool = .mosaic; state.optionsExpanded = true
        state.width = 6; state.colorIndex = 4
        let host = ToolbarHost(state: state)
        defer { host.close() }
        try await host.ready()
        #expect(state.toolbarHeight == 82)
        for position in positions {
            try host.click(ScreenshotMosaicMode.brush.title, at: position)
            #expect(state.mosaicOptions.mode == .brush && state.toolbarHeight == 118)
            try await Task.sleep(for: .milliseconds(10))
            try host.click(ScreenshotMosaicMode.rectangle.title, at: position)
            #expect(state.mosaicOptions.mode == .rectangle && state.toolbarHeight == 82)
            try await Task.sleep(for: .milliseconds(10))
        }
        try host.click(ScreenshotMosaicMode.brush.title, at: CGPoint(x: 0.5, y: 0.5))
        try await host.ready()
        try host.click(L.t("Brush size", "画笔大小"), at: CGPoint(x: 0.25, y: 0.5))
        let small = state.mosaicOptions.brushSize
        try host.click(L.t("Brush size", "画笔大小"), at: CGPoint(x: 0.8, y: 0.5))
        #expect(state.mosaicOptions.brushSize > small)
        #expect(state.mosaicOptions.blockSize == 12)
        let diameter = state.mosaicOptions.brushSize
        try host.click(L.t("Block size", "颗粒大小"), at: CGPoint(x: 0.8, y: 0.5))
        #expect(state.mosaicOptions.blockSize > 12 && state.mosaicOptions.brushSize == diameter)
        #expect(state.width == 6 && state.colorIndex == 4)
    }

    private var positions: [CGPoint] {
        [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.08, y: 0.08), CGPoint(x: 0.92, y: 0.08),
            CGPoint(x: 0.08, y: 0.92), CGPoint(x: 0.92, y: 0.92), CGPoint(x: 0.5, y: 0.08),
            CGPoint(x: 0.08, y: 0.5), CGPoint(x: 0.92, y: 0.5), CGPoint(x: 0.5, y: 0.92)]
    }
}

@MainActor private func actionName(_ action: ScreenshotEditorAction) -> String {
    switch action {
    case .tool(let tool): "tool." + tool.rawValue
    case .preview(let mode): "preview." + mode.rawValue
    case .undo: "undo"
    case .redo: "redo"
    case .reselect: "reselect"
    case .longScreenshot: "longScreenshot"
    case .recognizeText: "recognizeText"
    case .recognizeBarcodes: "recognizeBarcodes"
    case .confirm: "confirm"
    case .copy: "copy"
    case .save: "save"
    case .pin: "pin"
    case .cancel: "cancel"
    }
}

@MainActor private final class ToolbarHost {
    let hosting: NSHostingView<ScreenshotToolbar>
    let window: ScreenshotPanel

    init(state: ScreenshotEditorState) {
        _ = NSApplication.shared
        hosting = NSHostingView(rootView: ScreenshotToolbar(state: state))
        window = ScreenshotPanel(contentRect: CGRect(x: 100, y: 100, width: state.toolbarWidth, height: 200),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
    }

    func ready() async throws {
        try await Task.sleep(for: .milliseconds(60))
        hosting.layoutSubtreeIfNeeded()
    }

    func close() { window.contentView = nil; window.close() }

    func anchor(_ title: String) throws -> ScreenshotHoverAnchorView {
        try #require(anchors(hosting).first { $0.title == title })
    }

    func click(_ title: String, at fraction: CGPoint) throws {
        hosting.layoutSubtreeIfNeeded()
        let anchor = try anchor(title)
        let point = anchor.convert(CGPoint(x: anchor.bounds.width * fraction.x, y: anchor.bounds.height * fraction.y), to: nil)
        try click(point: point)
    }

    func click(point: CGPoint) throws {
        // 直接经过应用的原生事件分发；不移动真实指针、不需要事件投递权限，也不触发外部应用。
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            NSApp.sendEvent(event)
        }
    }

    private func anchors(_ view: NSView) -> [ScreenshotHoverAnchorView] {
        (view as? ScreenshotHoverAnchorView).map { [$0] } ?? view.subviews.flatMap { anchors($0) }
    }
}
