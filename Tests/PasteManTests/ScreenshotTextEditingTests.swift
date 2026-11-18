import AppKit
import CoreText
import SwiftUI
import Testing

@testable import PasteMan

@MainActor private struct TextEditingCapture: ScreenCapturing {
    let image: CGImage
    func capture(_ screens: [ScreenshotScreen]) async throws -> [CapturedScreen] {
        screens.map { CapturedScreen(screen: $0, image: image) }
    }
}

@Suite("截图文字属性与拖动缩放", .serialized) @MainActor struct ScreenshotTextEditingTests {
    private func image() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.18, green: 0.4, blue: 0.65, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        return try #require(context.makeImage())
    }

    private func event(_ type: NSEvent.EventType, point: CGPoint, view: NSView) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func overlay() async throws -> (ScreenshotCoordinator, ScreenshotOverlay) {
        _ = NSApplication.shared
        let coordinator = ScreenshotCoordinator(captureService: TextEditingCapture(image: try image()), presentWindow: { _ in })
        let screen = ScreenshotScreen(id: 42, frame: CGRect(x: 0, y: 0, width: 800, height: 600), scale: 1)
        coordinator.start(screens: [screen], sourceID: "test.text", sourceName: "文字测试")
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while coordinator.phase == .capturing, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let overlay = try #require(coordinator.windows.first?.contentView as? ScreenshotOverlay)
        overlay.mouseDown(with: try event(.leftMouseDown, point: CGPoint(x: 20, y: 20), view: overlay))
        overlay.mouseDragged(with: try event(.leftMouseDragged, point: CGPoint(x: 720, y: 520), view: overlay))
        overlay.mouseUp(with: try event(.leftMouseUp, point: CGPoint(x: 720, y: 520), view: overlay))
        try #require(coordinator.phase == .editing)
        overlay.state.action?(.tool(.text))
        return (coordinator, overlay)
    }

    @Test func ordinaryAndSharedCanvasTextInputsHaveTransparentBackgrounds() async throws {
        let (coordinator, overlay) = try await overlay()
        defer { coordinator.cancel() }
        overlay.mouseDown(with: try event(.leftMouseDown, point: CGPoint(x: 50, y: 50), view: overlay))
        let ordinary = try #require(overlay.subviews.compactMap { $0 as? NSTextView }.first)
        #expect(!ordinary.drawsBackground && ordinary.backgroundColor.alphaComponent == 0)
        let editor = PinnedScreenshotEditor(image: try image(), pointSize: CGSize(width: 800, height: 600), mode: .annotate)
        defer { editor.close() }
        editor.state.action?(.tool(.text))
        editor.canvas.mouseDown(with: try event(.leftMouseDown, point: CGPoint(x: 40, y: 40), view: editor.canvas))
        let shared = try #require(editor.canvas.subviews.compactMap { $0 as? NSTextView }.first)
        #expect(!shared.drawsBackground && shared.backgroundColor.alphaComponent == 0)
    }

    @Test func draggingWhenAddingTextChangesFontSizeWithoutChangingSelection() async throws {
        let (coordinator, overlay) = try await overlay()
        defer { coordinator.cancel(); NSCursor.arrow.set() }
        let selection = overlay.selection
        overlay.mouseDown(with: try event(.leftMouseDown, point: CGPoint(x: 50, y: 50), view: overlay))
        let editor = try #require(overlay.subviews.compactMap { $0 as? NSTextView }.first)
        let before = try #require(editor.font?.pointSize)
        overlay.mouseDragged(with: try event(.leftMouseDragged, point: CGPoint(x: 170, y: 120), view: overlay))
        let resize = NSCursor.frameResize(position: .bottomRight, directions: .all)
        #expect(NSCursor.current.image.tiffRepresentation == resize.image.tiffRepresentation)
        overlay.mouseUp(with: try event(.leftMouseUp, point: CGPoint(x: 170, y: 120), view: overlay))
        #expect(NSCursor.current === NSCursor.iBeam)
        #expect(try #require(editor.font?.pointSize) > before)
        #expect(overlay.selection == selection)
    }

    @Test func fontControlsUpdateActiveTextAndCommitIndependentAttributes() async throws {
        let (coordinator, overlay) = try await overlay()
        defer { coordinator.cancel() }
        overlay.state.width = 6; overlay.state.colorIndex = 4
        overlay.state.textStyle = AnnotationTextStyle(fontFamily: "Times New Roman", fontSize: 32, isBold: true, isItalic: true)
        overlay.state.textColor = AnnotationColor(red: 0.15, green: 0.8, blue: 0.35)
        overlay.mouseDown(with: try event(.leftMouseDown, point: CGPoint(x: 50, y: 50), view: overlay))
        let editor = try #require(overlay.subviews.compactMap { $0 as? ScreenshotTextView }.first)
        editor.string = "字体属性\nBold Italic"; editor.didChangeText()
        #expect(editor.string == "字体属性\nBold Italic")
        #expect(editor.font?.pointSize == 32)
        let font = try #require(editor.typingAttributes[.font] as? NSFont)
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        #expect(NSFontManager.shared.traits(of: font).contains(.italicFontMask))
        overlay.state.textStyle.fontSize = 48
        overlay.state.textStyle.isItalic = false
        #expect(editor.font?.pointSize == 48)
        #expect(!NSFontManager.shared.traits(of: try #require(editor.font)).contains(.italicFontMask))
        overlay.state.textColor = AnnotationColor.palette[1]
        #expect(editor.annotationColor == AnnotationColor.palette[1])
        overlay.state.textStyle.fontFamily = "Courier New"
        let updatedFont = try #require(editor.typingAttributes[.font] as? NSFont)
        #expect(updatedFont.familyName?.contains("Courier") == true)
        #expect(editor.string == "字体属性\nBold Italic")
        #expect(overlay.state.width == 6 && overlay.state.colorIndex == 4)
        overlay.commitText()
        let annotation = try #require(overlay.state.history.annotations.last)
        #expect(annotation.textStyle == overlay.state.textStyle)
        #expect(annotation.color == overlay.state.textColor)
        #expect(annotation.points == [CGPoint(x: 30, y: 30)] && annotation.text == "字体属性\nBold Italic")
    }

    @Test(arguments: [CGFloat(0.5), 1, 2]) func resizeHandleChangesLogicalFontSizeAtEachZoom(_ zoom: CGFloat) throws {
        _ = NSApplication.shared
        let editor = PinnedScreenshotEditor(image: try image(), pointSize: CGSize(width: 800, height: 600), mode: .annotate)
        defer { editor.close() }
        editor.state.textStyle.fontSize = 24
        editor.state.action?(.tool(.text))
        editor.canvas.zoom = zoom
        editor.canvas.mouseDown(with: try event(.leftMouseDown, point: CGPoint(x: 40, y: 40), view: editor.canvas))
        let text = try #require(editor.canvas.subviews.compactMap { $0 as? ScreenshotTextView }.first)
        text.string = "拖动缩放"; text.didChangeText()
        let handle = text.resizeHandleRect
        let start = CGPoint(x: handle.midX, y: handle.midY)
        let end = CGPoint(x: start.x + text.bounds.width, y: start.y + text.bounds.height)
        let startEvent = try event(.leftMouseDown, point: start, view: text)
        let dragEvent = try event(.leftMouseDragged, point: end, view: text)
        let upEvent = try event(.leftMouseUp, point: end, view: text)
        text.mouseDown(with: startEvent); text.mouseDragged(with: dragEvent); text.mouseUp(with: upEvent)
        #expect(editor.state.textStyle.fontSize > 40)
        #expect(abs((text.font?.pointSize ?? 0) / zoom - editor.state.textStyle.fontSize) < 0.01)
        editor.canvas.commitText()
        let annotation = try #require(editor.state.history.annotations.last)
        #expect(annotation.textStyle?.fontSize == editor.state.textStyle.fontSize)
        #expect(annotation.text == "拖动缩放" && annotation.points == [CGPoint(x: 40 / zoom, y: 40 / zoom)])
    }

    @Test func textRenderingUsesExplicitStyleAndRetainsTransparentPixels() throws {
        let context = try #require(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let base = try #require(context.makeImage())
        var annotation = ScreenshotAnnotation(tool: .text, points: [CGPoint(x: 30, y: 30)],
            color: AnnotationColor.palette[3], width: 1, text: "Font Size 中文",
            textStyle: AnnotationTextStyle(fontFamily: "Helvetica", fontSize: 32))
        func render(_ value: ScreenshotAnnotation) throws -> Data {
            let image = try ScreenshotRenderer.render(base: base, pointSize: CGSize(width: 800, height: 600), annotations: [value])
            return try #require(image.dataProvider?.data) as Data
        }
        let regular = try render(annotation)
        annotation.width = 12
        #expect(try render(annotation) == regular)
        annotation.textStyle?.isBold = true
        let bold = try render(annotation)
        #expect(bold != regular)
        annotation.textStyle?.isItalic = true
        #expect(try render(annotation) != bold)
        annotation.textStyle?.fontSize = 64
        let large = try render(annotation)
        #expect(large != regular && large[3] == 0)
        #expect(large.contains { $0 != 0 })
    }

    @Test(arguments: ["PingFang SC", "Helvetica"]) func chineseFontWithoutItalicFaceStillRendersAnItalicStyle(_ family: String) throws {
        let base = try image()
        var value = ScreenshotAnnotation(tool: .text, points: [CGPoint(x: 30, y: 30)],
            color: AnnotationColor.palette[4], width: 1, text: "中文斜体",
            textStyle: AnnotationTextStyle(fontFamily: family, fontSize: 42))
        let regular = try ScreenshotRenderer.render(base: base, pointSize: CGSize(width: 800, height: 600), annotations: [value])
        value.textStyle?.isItalic = true
        let italic = try ScreenshotRenderer.render(base: base, pointSize: CGSize(width: 800, height: 600), annotations: [value])
        #expect(italic.dataProvider?.data as Data? != regular.dataProvider?.data as Data?)
    }

    @Test func textToolbarAndTransparentInputRenderInBothLanguagesAndAppearances() async throws {
        _ = NSApplication.shared
        let previousLanguage = L.language
        let preference = UserDefaults.standard.object(forKey: InterfaceLocalization.defaultsKey)
        defer {
            InterfaceLocalization.shared.setLanguage(previousLanguage)
            if let preference { UserDefaults.standard.set(preference, forKey: InterfaceLocalization.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: InterfaceLocalization.defaultsKey) }
        }
        let output = ProcessInfo.processInfo.environment["EASYMACOS_TEXT_EDITOR_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for chinese in [true, false] {
            InterfaceLocalization.shared.setLanguage(chinese ? .simplifiedChinese : .english)
            for dark in [false, true] {
                for small in [false, true] {
                    let editor = PinnedScreenshotEditor(image: try image(), pointSize: CGSize(width: 800, height: 600), mode: .annotate)
                    editor.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    editor.window.setContentSize(small ? CGSize(width: 712, height: 460) : CGSize(width: 920, height: 660))
                    editor.state.textStyle = AnnotationTextStyle(fontFamily: "Helvetica", fontSize: 36, isBold: true, isItalic: true)
                    editor.state.textColor = AnnotationColor.palette[4]
                    editor.state.action?(.tool(.text))
                    #expect(editor.state.optionsExpanded && editor.state.toolbarHeight == 118)
                    editor.canvas.mouseDown(with: try event(.leftMouseDown, point: CGPoint(x: 45, y: 45), view: editor.canvas))
                    let text = try #require(editor.canvas.subviews.compactMap { $0 as? ScreenshotTextView }.first)
                    text.string = chinese ? "透明文字背景\n拖动控制点调整字号" : "Transparent text\nDrag the handle to resize"
                    text.didChangeText()
                    #expect(!text.string.isEmpty)
                    await editor.canvas.waitForTiles()
                    #expect(!text.drawsBackground && text.resizeHandleRect.width > 0)
                    if let output {
                        let content = try #require(editor.window.contentView)
                        content.layoutSubtreeIfNeeded()
                        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                        content.cacheDisplay(in: content.bounds, to: bitmap)
                        let png = try #require(bitmap.representation(using: .png, properties: [:]))
                        try png.write(to: output.appendingPathComponent("text-\(chinese ? "zh" : "en")-\(dark ? "dark" : "light")-\(small ? "small" : "normal").png"))
                    }
                    editor.close()
                }
            }
        }
    }

    @Test func closingEditorsReleasesTextInputAndItsTextStorage() async throws {
        let (coordinator, overlay) = try await overlay()
        func waitForRelease(_ name: String, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try #require(condition(), "\(name)的文字输入与文本缓冲未释放")
        }
        weak var ordinary: ScreenshotTextView?
        weak var ordinaryStorage: NSTextStorage?
        try autoreleasepool {
            overlay.mouseDown(with: try event(.leftMouseDown, point: CGPoint(x: 50, y: 50), view: overlay))
            ordinary = overlay.subviews.compactMap { $0 as? ScreenshotTextView }.first
            ordinaryStorage = ordinary?.textStorage
            try #require(ordinary != nil && ordinaryStorage != nil)
            coordinator.cancel()
        }
        try await waitForRelease("普通截图") { ordinary == nil && ordinaryStorage == nil }
        let editor = PinnedScreenshotEditor(image: try image(), pointSize: CGSize(width: 800, height: 600), mode: .annotate)
        editor.state.action?(.tool(.text))
        weak var shared: ScreenshotTextView?
        weak var sharedStorage: NSTextStorage?
        try autoreleasepool {
            editor.canvas.mouseDown(with: try event(.leftMouseDown, point: CGPoint(x: 40, y: 40), view: editor.canvas))
            shared = editor.canvas.subviews.compactMap { $0 as? ScreenshotTextView }.first
            sharedStorage = shared?.textStorage
            try #require(shared != nil && sharedStorage != nil)
            editor.close()
        }
        try await waitForRelease("独立编辑窗口") { shared == nil && sharedStorage == nil }
    }

    @Test func textPointerShowsMoveResizeAndInsertionCursors() throws {
        _ = NSApplication.shared
        defer { NSCursor.arrow.set() }
        let editor = PinnedScreenshotEditor(image: try image(), pointSize: CGSize(width: 800, height: 600), mode: .annotate)
        defer { editor.close() }
        editor.state.action?(.tool(.text))
        editor.canvas.mouseDown(with: try event(.leftMouseDown, point: CGPoint(x: 45, y: 45), view: editor.canvas))
        let text = try #require(editor.canvas.subviews.compactMap { $0 as? ScreenshotTextView }.first)
        text.string = "指针与文字交互"; text.didChangeText()
        func hover(_ point: CGPoint) throws {
            let value = try #require(NSEvent.enterExitEvent(with: .cursorUpdate, location: text.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: editor.window.windowNumber, context: nil,
                eventNumber: 0, trackingNumber: 0, userData: nil))
            text.cursorUpdate(with: value)
        }
        try hover(CGPoint(x: text.bounds.midX, y: 2))
        #expect(NSCursor.current === NSCursor.openHand)
        let handle = text.resizeHandleRect
        try hover(CGPoint(x: handle.midX, y: handle.midY))
        let resize = NSCursor.frameResize(position: .bottomRight, directions: .all)
        #expect(NSCursor.current.image.tiffRepresentation == resize.image.tiffRepresentation)
        try hover(CGPoint(x: 20, y: text.bounds.midY))
        #expect(NSCursor.current === NSCursor.iBeam)
    }

    @Test func movingOrdinaryScreenshotTextPreservesStyleAndCommitsNewPosition() async throws {
        let (coordinator, overlay) = try await overlay()
        defer { coordinator.cancel(); NSCursor.arrow.set() }
        overlay.mouseDown(with: try event(.leftMouseDown, point: CGPoint(x: 70, y: 70), view: overlay))
        let text = try #require(overlay.subviews.compactMap { $0 as? ScreenshotTextView }.first)
        text.string = "移动文字"; text.didChangeText()
        text.setSelectedRange(NSRange(location: 1, length: 2))
        let originalSelection = overlay.selection
        let originalStyle = text.annotationStyle
        let originalSize = text.bounds.size
        let start = CGPoint(x: text.bounds.midX, y: 2)
        let down = try event(.leftMouseDown, point: start, view: text)
        let dragged = try event(.leftMouseDragged, point: CGPoint(x: start.x + 85, y: start.y + 45), view: text)
        let up = try event(.leftMouseUp, point: CGPoint(x: start.x + 85, y: start.y + 45), view: text)
        text.mouseDown(with: down)
        #expect(NSCursor.current === NSCursor.closedHand)
        text.mouseDragged(with: dragged); text.mouseUp(with: up)
        #expect(NSCursor.current === NSCursor.openHand)
        #expect(text.frame.origin == CGPoint(x: 155, y: 115))
        #expect(text.bounds.size == originalSize && text.annotationStyle == originalStyle)
        #expect(text.string == "移动文字" && !text.drawsBackground && overlay.selection == originalSelection)
        #expect(text.selectedRange() == NSRange(location: 1, length: 2))
        overlay.commitText()
        let annotation = try #require(overlay.state.history.annotations.last)
        #expect(annotation.points == [CGPoint(x: 135, y: 95)] && annotation.textStyle == originalStyle)
        overlay.state.action?(.undo); #expect(overlay.state.history.annotations.isEmpty)
        overlay.state.action?(.redo); #expect(overlay.state.history.annotations.last == annotation)
    }

    @Test(arguments: [CGFloat(0.5), 1, 2]) func movingAndResizingSharedCanvasTextUsesLogicalCoordinates(_ zoom: CGFloat) throws {
        _ = NSApplication.shared
        defer { NSCursor.arrow.set() }
        let editor = PinnedScreenshotEditor(image: try image(), pointSize: CGSize(width: 800, height: 600), mode: .annotate)
        defer { editor.close() }
        editor.state.action?(.tool(.text)); editor.canvas.zoom = zoom
        editor.canvas.mouseDown(with: try event(.leftMouseDown, point: CGPoint(x: 40, y: 40), view: editor.canvas))
        let text = try #require(editor.canvas.subviews.compactMap { $0 as? ScreenshotTextView }.first)
        text.string = "移动并放大"; text.didChangeText()
        let start = CGPoint(x: text.bounds.midX, y: 2)
        let down = try event(.leftMouseDown, point: start, view: text)
        let dragged = try event(.leftMouseDragged, point: CGPoint(x: start.x + 30 * zoom, y: start.y + 20 * zoom), view: text)
        let up = try event(.leftMouseUp, point: CGPoint(x: start.x + 30 * zoom, y: start.y + 20 * zoom), view: text)
        text.mouseDown(with: down); text.mouseDragged(with: dragged); text.mouseUp(with: up)
        let movedOrigin = text.frame.origin
        #expect(abs(movedOrigin.x - 40 - 30 * zoom) < 0.01 && abs(movedOrigin.y - 40 - 20 * zoom) < 0.01)
        let handle = text.resizeHandleRect
        let resize = CGPoint(x: handle.midX, y: handle.midY)
        let resizeDown = try event(.leftMouseDown, point: resize, view: text)
        let resizeDrag = try event(.leftMouseDragged, point: CGPoint(x: resize.x + 60, y: resize.y + 30), view: text)
        let resizeUp = try event(.leftMouseUp, point: CGPoint(x: resize.x + 60, y: resize.y + 30), view: text)
        text.mouseDown(with: resizeDown); text.mouseDragged(with: resizeDrag); text.mouseUp(with: resizeUp)
        #expect(editor.state.textStyle.fontSize > 24 && text.frame.origin == movedOrigin)
        editor.canvas.commitText()
        let annotation = try #require(editor.state.history.annotations.last)
        let position = try #require(annotation.points.first)
        #expect(abs(position.x - 40 / zoom - 30) < 0.01 && abs(position.y - 40 / zoom - 20) < 0.01)
        #expect(annotation.textStyle?.fontSize == editor.state.textStyle.fontSize)
    }

    @Test func movingTextClampsToSelectionAndAllowsGrowthAfterMovingAwayFromEdge() async throws {
        let (coordinator, overlay) = try await overlay()
        defer { coordinator.cancel(); NSCursor.arrow.set() }
        overlay.mouseDown(with: try event(.leftMouseDown, point: CGPoint(x: 650, y: 450), view: overlay))
        let text = try #require(overlay.subviews.compactMap { $0 as? ScreenshotTextView }.first)
        text.string = "移动后的长文字"; text.didChangeText()
        let initialWidth = text.bounds.width
        func moveBy(_ delta: CGPoint) throws {
            let start = CGPoint(x: text.bounds.midX, y: 2)
            let down = try event(.leftMouseDown, point: start, view: text)
            let dragged = try event(.leftMouseDragged, point: CGPoint(x: start.x + delta.x, y: start.y + delta.y), view: text)
            let up = try event(.leftMouseUp, point: CGPoint(x: start.x + delta.x, y: start.y + delta.y), view: text)
            text.mouseDown(with: down); text.mouseDragged(with: dragged); text.mouseUp(with: up)
        }
        try moveBy(CGPoint(x: -2000, y: -2000))
        #expect(text.frame.origin == overlay.selection.origin)
        overlay.state.textStyle.fontSize = 48
        #expect(text.bounds.width > initialWidth && overlay.selection.contains(text.frame))
        try moveBy(CGPoint(x: 2000, y: 2000))
        #expect(abs(text.frame.maxX - overlay.selection.maxX) < 0.01)
        #expect(abs(text.frame.maxY - overlay.selection.maxY) < 0.01)
    }

    @Test(arguments: [false, true]) func closingDuringTextDragRestoresPointerAndIgnoresLateMovement(_ visible: Bool) async throws {
        _ = NSApplication.shared
        defer { NSCursor.arrow.set() }
        let editor = PinnedScreenshotEditor(image: try image(), pointSize: CGSize(width: 800, height: 600), mode: .annotate)
        if visible { editor.window.orderFrontRegardless() }
        editor.state.action?(.tool(.text))
        weak var released: ScreenshotTextView?
        weak var storage: NSTextStorage?
        try autoreleasepool {
            editor.canvas.mouseDown(with: try event(.leftMouseDown, point: CGPoint(x: 45, y: 45), view: editor.canvas))
            let text = try #require(editor.canvas.subviews.compactMap { $0 as? ScreenshotTextView }.first)
            text.string = "关闭拖动中的文字"; text.didChangeText()
            text.updateTrackingAreas()
            let point = CGPoint(x: text.bounds.midX, y: 2)
            text.mouseDown(with: try event(.leftMouseDown, point: point, view: text))
            #expect(NSCursor.current === NSCursor.closedHand)
            let dragged = try event(.leftMouseDragged, point: CGPoint(x: point.x + 100, y: 50), view: text)
            let frame = text.frame
            released = text; storage = text.textStorage
            editor.close()
            #expect(NSCursor.current === NSCursor.arrow)
            text.mouseDragged(with: dragged)
            #expect(text.frame == frame && text.superview == nil)
            #expect(text.pointerCursor(at: .zero) === NSCursor.arrow)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while (released != nil || storage != nil), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(released == nil && storage == nil && editor.window.contentView == nil)
    }
}
