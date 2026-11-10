import AppKit
import Testing
@testable import PasteMan

@Suite("截图按钮提示定位", .serialized) @MainActor struct ScreenshotHoverTipTests {
    @Test(arguments: ["开始长截屏", "Start scrolling screenshot", "完成并复制 ⌘C"])
    func singleLineTooltipFitsTheEntireTitle(_ title: String) throws {
        try withTooltip(title: title) { panel, label in
            let cell = try #require(label.cell)
            #expect(label.bounds.width >= ceil(cell.cellSize.width), "提示须容纳文字控件的全部内容和内部边距")
            #expect(label.bounds.height >= ceil(cell.cellSize.height))
            #expect(abs(panel.frame.width - label.frame.width - 16) <= 1, "背景须随实际文字宽度收缩，容许窗口边界取整")
            #expect(panel.frame.height == max(26, label.frame.height + 12))
        }
    }

    @Test func descriptionDoesNotExpandTheVisibleTooltip() throws {
        let samples = [
            ("原始比例", "按截图原始比例查看，不改变导出图片尺寸。"),
            ("铺满窗口", "按窗口宽度等比例铺满，超出高度的部分垂直滚动查看。"),
            ("Actual size", "View at the original scale without changing the exported image."),
            ("Fill window", "Fill the window width proportionally; scroll vertically for the rest."),
            ("长说明", String(repeating: "按窗口宽度显示，超出高度的部分滚动查看。", count: 4)),
        ]
        for (title, detail) in samples {
            try withTooltip(title: title, detail: detail) { panel, label in
                let cell = try #require(label.cell)
                let required = cell.cellSize(forBounds: CGRect(x: 0, y: 0, width: label.bounds.width,
                    height: .greatestFiniteMagnitude))
                #expect(label.stringValue == title, "悬停只显示简短名称")
                #expect(label.bounds.height >= ceil(required.height), "名称须完整可见：\(title)")
                #expect(label.bounds.width >= ceil(required.width))
                #expect(label.bounds.width <= 280)
                #expect(abs(panel.frame.width - label.frame.width - 16) <= 1)
                #expect(panel.frame.height == 26, "详细说明不能扩大提示背景")
            }
        }
    }

    private func withTooltip(title: String, detail: String? = nil,
                             check: (NSPanel, NSTextField) throws -> Void) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 100, y: 200, width: 400, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        let tip = ScreenshotHoverTip()
        defer { tip.hide(); window.close() }
        window.orderFrontRegardless()
        tip.show(ScreenshotHoverTarget(title: title, detail: detail,
            screenFrame: CGRect(x: 250, y: 300, width: 32, height: 32)), in: window)
        let panel = try #require(tip.panel)
        let content = try #require(panel.contentView)
        let label = try #require(content.subviews.compactMap { $0 as? NSTextField }.first)
        try check(panel, label)
    }

    @Test func tooltipStaysBesideItsButtonAndInsideNegativeCoordinateDisplay() {
        let screen = CGRect(x: -1440, y: -200, width: 1440, height: 900)
        let size = CGSize(width: 210, height: 48)
        let button = CGRect(x: -900, y: 430, width: 32, height: 32)
        let frame = ScreenshotHoverTip.frame(size: size, anchor: button, screen: screen)
        #expect(frame.midX == button.midX)
        #expect(button.minY - frame.maxY == 5, "提示须紧贴按钮，不能按整个工具栏或标题栏定位")
        let bottomButton = CGRect(x: -1420, y: -190, width: 32, height: 32)
        let above = ScreenshotHoverTip.frame(size: size, anchor: bottomButton, screen: screen)
        #expect(above.minY - bottomButton.maxY == 5, "屏幕底部空间不足时改为贴在按钮上方")
        #expect(screen.contains(above))
        let rightButton = CGRect(x: -40, y: 300, width: 32, height: 32)
        let right = ScreenshotHoverTip.frame(size: size, anchor: rightButton, screen: screen)
        #expect(right.maxX == screen.maxX - 4 && screen.contains(right))
    }

    @Test func nativeHoverReportsButtonBoundsAndClearsOnExitOrRemoval() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 100, y: 200, width: 700, height: 220),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = try #require(window.contentView)
        let row = NSView(frame: CGRect(x: 40, y: 140, width: 600, height: 46))
        let anchor = ScreenshotHoverAnchorView(frame: CGRect(x: 72, y: 7, width: 32, height: 32))
        row.addSubview(anchor); root.addSubview(row)
        defer { anchor.changed = nil; window.contentView = nil; window.close() }
        var received: ScreenshotHoverTarget?
        var cleared = 0
        anchor.title = "马赛克"
        anchor.changed = { received = $0; if $0 == nil { cleared += 1 } }
        let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        anchor.mouseEntered(with: event)
        let target = try #require(received)
        #expect(target.title == "马赛克")
        #expect(target.screenFrame == CGRect(x: 212, y: 347, width: 32, height: 32))
        #expect(anchor.hitTest(CGPoint(x: 10, y: 10)) == nil, "定位视图不能挡住原按钮点击")
        // 工具栏背景向下扩展，按钮没移动时，提示位置不能跟着下移。
        row.setFrameSize(CGSize(width: 600, height: 118))
        anchor.mouseEntered(with: event)
        #expect(received?.screenFrame == target.screenFrame)
        anchor.mouseExited(with: event)
        #expect(received == nil && cleared == 1)
        anchor.mouseEntered(with: event)
        anchor.removeFromSuperview()
        #expect(received == nil && cleared == 2)
    }
}
