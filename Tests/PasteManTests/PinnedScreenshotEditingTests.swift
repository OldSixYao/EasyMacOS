import AppKit
import ImageIO
import Testing

@testable import PasteMan

@Suite("钉图旋转、镜像与编辑", .serialized) @MainActor struct PinnedScreenshotEditingTests {
    private func image() throws -> ScreenshotImage {
        // 四角使用不同颜色，左上另有半透明像素，检测方向和透明通道。
        let bytes: [UInt8] = [
            128, 0, 0, 128, 255, 0, 0, 255, 0, 255, 0, 255, 0, 255, 0, 255,
            0, 0, 255, 255, 0, 0, 255, 255, 255, 255, 0, 255, 255, 255, 0, 255,
        ]
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let bitmap = try #require(CGImage(width: 4, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 16, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        return try ScreenshotRenderer.export(base: bitmap, pointSize: CGSize(width: 2, height: 1), annotations: [])
    }

    private func pixels(_ image: CGImage) throws -> [[UInt8]] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pointer = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<(image.width * image.height)).map { index in
            Array(UnsafeBufferPointer(start: pointer + index * 4, count: 4))
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    private func menu(_ window: NSWindow) throws -> NSMenu {
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseUp, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        return try #require(window.contentView?.menu(for: event))
    }

    private func item(_ selector: String, in menu: NSMenu) -> NSMenuItem? {
        for value in menu.items {
            if value.action == NSSelectorFromString(selector) { return value }
            if let submenu = value.submenu, let nested = item(selector, in: submenu) { return nested }
        }
        return nil
    }

    private func perform(_ selector: String, on window: NSWindow) throws {
        let action = try #require(item(selector, in: menu(window)))
        try #require(action.isEnabled)
        #expect(NSApp.sendAction(try #require(action.action), to: action.target, from: action))
    }

    @Test func contextMenuOffersAllImageEditingActions() throws {
        _ = NSApplication.shared
        let pins = PinnedScreenshotManager(presentWindow: { _ in })
        defer { pins.closeAll() }
        pins.show(try image(), sourceID: "test.pin", sourceName: "测试来源", origin: .zero)
        let menu = try menu(#require(pins.windows.first))
        for selector in ["rotateClockwise", "rotateCounterclockwise", "rotateHalfTurn", "mirrorHorizontally",
            "mirrorVertically", "cropImage", "editImage"] {
            #expect(item(selector, in: menu) != nil, "缺少右键入口：\(selector)")
        }
    }

    @Test(arguments: ["rotateClockwise", "rotateCounterclockwise", "rotateHalfTurn", "mirrorHorizontally", "mirrorVertically"])
    func menuTransformsFullResolutionPixelsAndSavedImage(_ selector: String) async throws {
        _ = NSApplication.shared
        let original = try image()
        var saved: Data?
        var errors: [String] = []
        let pins = PinnedScreenshotManager(presentWindow: { _ in }, saveImage: { saved = $0; return true },
            reportError: { errors.append($0) })
        defer { pins.closeAll() }
        var copies: [ScreenshotImage] = []
        pins.onCopy = { value, id, name in
            #expect(id == "test.pin" && name == "测试来源")
            copies.append(value); return true
        }
        pins.show(original, sourceID: "test.pin", sourceName: "测试来源", origin: .zero)
        pins.show(original, sourceID: "test.other", sourceName: "另一张", origin: .zero)
        let window = try #require(pins.windows.first)
        let otherFrame = pins.windows[1].frame
        window.setContentSize(CGSize(width: 200, height: 100))
        try perform(selector, on: window)
        try await waitUntil { (try? item("copyImage", in: menu(window))?.isEnabled) == true }
        try perform("copyImage", on: window)
        try await waitUntil { copies.count == 1 }
        let result = try #require(copies.first)
        let source = try pixels(original.image)
        let indices: [Int]
        switch selector {
        case "rotateClockwise": indices = [4, 0, 5, 1, 6, 2, 7, 3]
        case "rotateCounterclockwise": indices = [3, 7, 2, 6, 1, 5, 0, 4]
        case "rotateHalfTurn": indices = [7, 6, 5, 4, 3, 2, 1, 0]
        case "mirrorHorizontally": indices = [3, 2, 1, 0, 7, 6, 5, 4]
        default: indices = [4, 5, 6, 7, 0, 1, 2, 3]
        }
        #expect(try pixels(result.image) == indices.map { source[$0] })
        let swapped = selector == "rotateClockwise" || selector == "rotateCounterclockwise"
        #expect(result.image.width == (swapped ? 2 : 4) && result.image.height == (swapped ? 4 : 2))
        #expect(result.pointSize == (swapped ? CGSize(width: 1, height: 2) : original.pointSize))
        #expect(window.contentAspectRatio == result.pointSize)
        #expect(abs(window.frame.width / window.frame.height - result.pointSize.width / result.pointSize.height) < 0.01)
        #expect(pins.count == 2 && pins.windows[1].frame == otherFrame)
        try perform("saveImage", on: window)
        try await waitUntil { saved != nil }
        let savedData = try #require(saved)
        let png = try #require(CGImageSourceCreateWithData(savedData as CFData, nil))
        let savedImage = try #require(CGImageSourceCreateImageAtIndex(png, 0, nil))
        #expect(try pixels(savedImage) == pixels(result.image))
        #expect(errors.isEmpty)
        try perform("resetSize", on: window)
        #expect(window.contentView?.bounds.size == result.pointSize)
    }

    @Test func cropUsesTopLeftCoordinatesAtOriginalPixelScaleAndReplacesOnlyItsPin() async throws {
        _ = NSApplication.shared
        let original = try image()
        let pins = PinnedScreenshotManager(presentWindow: { _ in })
        var editors: [PinnedScreenshotEditor] = []
        pins.presentEditorWindow = { editors.append($0) }
        defer { pins.closeAll() }
        var copied: ScreenshotImage?
        pins.onCopy = { value, _, _ in copied = value; return true }
        pins.show(original, sourceID: "test.crop", sourceName: "裁剪", origin: .zero)
        let window = try #require(pins.windows.first)
        window.setContentSize(CGSize(width: 200, height: 100))
        try perform("cropImage", on: window)
        try await waitUntil { !editors.isEmpty }
        let editor = try #require(editors.first)
        let crop = try #require(editor.cropView)
        let start = CGPoint(x: 0.6 * editor.zoom, y: 0)
        let end = CGPoint(x: 1.9 * editor.zoom, y: 0.4 * editor.zoom)
        for (type, point) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: crop.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: editor.window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { crop.mouseDown(with: event) }
            else if type == .leftMouseDragged { crop.mouseDragged(with: event) }
            else { crop.mouseUp(with: event) }
        }
        editor.state.action?(.confirm)
        try await waitUntil { editor.window.contentView == nil }
        try perform("copyImage", on: window)
        try await waitUntil { copied != nil }
        let result = try #require(copied)
        #expect(result.image.width == 3 && result.image.height == 1)
        #expect(result.pointSize == CGSize(width: 1.5, height: 0.5))
        #expect(try pixels(result.image) == Array(pixels(original.image)[1...3]))
        #expect(pins.count == 1 && window.contentAspectRatio == result.pointSize)
    }

    @Test func annotationCancelPreservesImageAndApplyFlattensMarksWithoutCopying() async throws {
        _ = NSApplication.shared
        let original = try image()
        let pins = PinnedScreenshotManager(presentWindow: { _ in })
        var editors: [PinnedScreenshotEditor] = []
        pins.presentEditorWindow = { editors.append($0) }
        defer { pins.closeAll() }
        var copies: [ScreenshotImage] = []
        pins.onCopy = { value, _, _ in copies.append(value); return true }
        pins.show(original, sourceID: "test.edit", sourceName: "编辑", origin: .zero)
        let window = try #require(pins.windows.first)
        try perform("editImage", on: window)
        try await waitUntil { editors.count == 1 }
        let cancelled = editors[0]
        cancelled.state.history.append(ScreenshotAnnotation(tool: .rectangle, points: [.zero, CGPoint(x: 2, y: 1)],
            color: AnnotationColor.palette[2], width: 0.5))
        cancelled.state.action?(.cancel)
        #expect(cancelled.window.contentView == nil && copies.isEmpty)
        try perform("copyImage", on: window)
        try await waitUntil { copies.count == 1 }
        #expect(copies[0].png == original.png)
        try perform("editImage", on: window)
        try await waitUntil { editors.count == 2 }
        let editor = editors[1]
        #expect(editor.state.history.annotations.isEmpty && editor.cropView == nil)
        let annotation = ScreenshotAnnotation(tool: .rectangle, points: [.zero, CGPoint(x: 2, y: 1)],
            color: AnnotationColor.palette[2], width: 0.5)
        editor.state.history.append(annotation)
        editor.state.action?(.undo)
        #expect(editor.state.history.annotations.isEmpty)
        editor.state.action?(.redo)
        editor.state.action?(.confirm)
        try await waitUntil { editor.window.contentView == nil }
        #expect(copies.count == 1 && pins.count == 1)
        try perform("copyImage", on: window)
        try await waitUntil { copies.count == 2 }
        let expected = try ScreenshotRenderer.render(base: original.image, pointSize: original.pointSize, annotations: [annotation])
        #expect(try pixels(copies[1].image) == pixels(expected))
        #expect(copies[1].png != original.png)
    }

    @Test(arguments: [false, true]) func closingPinClosesEditorAndReleasesItsView(_ closeAll: Bool) async throws {
        _ = NSApplication.shared
        let pins = PinnedScreenshotManager(presentWindow: { _ in })
        var editor: PinnedScreenshotEditor?
        pins.presentEditorWindow = { editor = $0 }
        pins.show(try image(), sourceID: "test.close", sourceName: "关闭", origin: .zero)
        let window = try #require(pins.windows.first)
        weak let view = window.contentView
        try perform("editImage", on: window)
        try await waitUntil { editor != nil }
        let editWindow = try #require(editor?.window)
        editor = nil
        if closeAll { pins.closeAll() } else { window.close() }
        try await waitUntil { view == nil }
        #expect(pins.count == 0 && editWindow.contentView == nil && editWindow.delegate == nil)
    }

    @Test func failedCopyAndCancelledSaveKeepEditsAndAllowRetry() async throws {
        _ = NSApplication.shared
        var saves = 0
        let pins = PinnedScreenshotManager(presentWindow: { _ in }, saveImage: { _ in saves += 1; return false })
        var editor: PinnedScreenshotEditor?
        pins.presentEditorWindow = { editor = $0 }
        defer { pins.closeAll() }
        pins.show(try image(), sourceID: "test.retry", sourceName: "重试", origin: .zero)
        let window = try #require(pins.windows.first)
        try perform("editImage", on: window)
        try await waitUntil { editor != nil }
        let active = try #require(editor)
        let annotation = ScreenshotAnnotation(tool: .pen, points: [.zero, CGPoint(x: 2, y: 1)],
            color: AnnotationColor.palette[0], width: 0.25)
        active.state.history.append(annotation)
        pins.onCopy = { _, _, _ in false }
        active.state.action?(.copy)
        try await waitUntil { !active.state.busy }
        #expect(active.state.error != nil && active.state.history.annotations == [annotation])
        #expect(active.window.contentView != nil && pins.count == 1)
        active.state.action?(.save)
        try await waitUntil { saves == 1 && !active.state.busy }
        #expect(active.window.contentView != nil && active.state.error == nil)
        var copied: ScreenshotImage?
        pins.onCopy = { value, _, _ in copied = value; return true }
        active.state.action?(.copy)
        try await waitUntil { active.window.contentView == nil }
        #expect(copied != nil && pins.count == 1)
    }

    @Test func repeatedEditorEntryReusesSessionAndCropCancellationPreservesOriginal() async throws {
        _ = NSApplication.shared
        let original = try image()
        let pins = PinnedScreenshotManager(presentWindow: { _ in })
        var editors: [PinnedScreenshotEditor] = []
        pins.presentEditorWindow = { editors.append($0) }
        defer { pins.closeAll() }
        pins.show(original, sourceID: "test.cancel", sourceName: "取消", origin: .zero)
        let window = try #require(pins.windows.first)
        try perform("cropImage", on: window)
        try await waitUntil { editors.count == 1 }
        try perform("cropImage", on: window)
        #expect(editors.count == 2 && editors[0] === editors[1])
        let rotated = try #require(item("rotateClockwise", in: menu(window)))
        #expect(!rotated.isEnabled)
        editors[0].state.action?(.cancel)
        var copied: ScreenshotImage?
        pins.onCopy = { value, _, _ in copied = value; return true }
        try perform("copyImage", on: window)
        try await waitUntil { copied != nil }
        #expect(copied?.png == original.png)
    }

    @Test func closingDuringEditorSaveCancelsAndSuppressesLateFailure() async throws {
        _ = NSApplication.shared
        var pending: CheckedContinuation<Bool, any Error>?
        var cancelled = false
        var errors: [String] = []
        let pins = PinnedScreenshotManager(presentWindow: { _ in }, saveImage: { _ in
            defer { cancelled = Task.isCancelled }
            return try await withCheckedThrowingContinuation { pending = $0 }
        }, reportError: { errors.append($0) })
        var editor: PinnedScreenshotEditor?
        pins.presentEditorWindow = { editor = $0 }
        pins.show(try image(), sourceID: "test.save.close", sourceName: "关闭保存", origin: .zero)
        let window = try #require(pins.windows.first)
        weak let view = window.contentView
        try perform("editImage", on: window)
        try await waitUntil { editor != nil }
        let active = try #require(editor)
        active.state.action?(.save)
        try await waitUntil { pending != nil }
        window.close()
        try await waitUntil { view == nil }
        pending?.resume(throwing: CocoaError(.fileWriteNoPermission))
        try await waitUntil { cancelled }
        #expect(active.window.contentView == nil && errors.isEmpty && pins.count == 0)
    }

    @Test func editorLayoutsSupportBothLanguagesAppearancesAndWindowSizes() async throws {
        _ = NSApplication.shared
        let previousLanguage = L.language
        let preference = UserDefaults.standard.object(forKey: InterfaceLocalization.defaultsKey)
        defer {
            InterfaceLocalization.shared.setLanguage(previousLanguage)
            if let preference { UserDefaults.standard.set(preference, forKey: InterfaceLocalization.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: InterfaceLocalization.defaultsKey) }
        }
        let context = try #require(CGContext(data: nil, width: 1000, height: 600, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.94, green: 0.96, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 600))
        context.setFillColor(CGColor(red: 0.1, green: 0.55, blue: 0.85, alpha: 1))
        context.fill(CGRect(x: 50, y: 50, width: 360, height: 220))
        context.setFillColor(CGColor(red: 0.95, green: 0.55, blue: 0.2, alpha: 1))
        context.fillEllipse(in: CGRect(x: 500, y: 180, width: 350, height: 350))
        let base = try #require(context.makeImage())
        let sample = try ScreenshotRenderer.render(base: base, pointSize: CGSize(width: 500, height: 300), annotations: [
            ScreenshotAnnotation(tool: .text, points: [CGPoint(x: 30, y: 22)],
                color: AnnotationColor(red: 0.1, green: 0.15, blue: 0.25), width: 3, text: "贴图编辑 · EasyMacOS"),
            ScreenshotAnnotation(tool: .arrow, points: [CGPoint(x: 100, y: 160), CGPoint(x: 270, y: 170)],
                color: AnnotationColor.palette[0], width: 4),
        ])
        let output = ProcessInfo.processInfo.environment["EASYMACOS_PIN_EDITOR_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for chinese in [true, false] {
            InterfaceLocalization.shared.setLanguage(chinese ? .simplifiedChinese : .english)
            for dark in [false, true] {
                for mode in [PinnedScreenshotEditor.Mode.crop, .annotate] {
                    let editor = PinnedScreenshotEditor(image: sample, pointSize: CGSize(width: 500, height: 300), mode: mode)
                    editor.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    for small in [false, true] {
                        editor.window.setContentSize(small ? CGSize(width: 712, height: 420) : CGSize(width: 920, height: 660))
                        editor.windowDidResize(Notification(name: NSWindow.didResizeNotification))
                        await editor.canvas.waitForTiles()
                        #expect(editor.canvas.frame.width <= editor.scrollView.contentSize.width + 0.01)
                        #expect(editor.canvas.frame.height <= editor.scrollView.contentSize.height + 0.01)
                        #expect(abs(editor.canvas.frame.width / editor.canvas.frame.height - 5.0 / 3) < 0.01)
                        #expect(editor.cropView?.frame == (mode == .crop ? editor.canvas.bounds : nil))
                        if let output {
                            let content = try #require(editor.window.contentView)
                            content.layoutSubtreeIfNeeded()
                            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                            content.cacheDisplay(in: content.bounds, to: bitmap)
                            let png = try #require(bitmap.representation(using: .png, properties: [:]))
                            try png.write(to: output.appendingPathComponent(
                                "\(mode == .crop ? "crop" : "edit")-\(chinese ? "zh" : "en")-\(dark ? "dark" : "light")-\(small ? "small" : "normal").png"))
                        }
                    }
                    editor.close()
                }
            }
        }
    }

    @Test func initialCropHandlesResizeAndSelectedAreaMovesWithinImageBounds() throws {
        _ = NSApplication.shared
        let original = try image()
        let editor = PinnedScreenshotEditor(image: original.image, pointSize: CGSize(width: 400, height: 200), mode: .crop)
        defer { editor.close() }
        let crop = try #require(editor.cropView)
        func expectSelection(_ expected: CGRect) {
            #expect(abs(crop.selection.minX - expected.minX) < 0.000001)
            #expect(abs(crop.selection.minY - expected.minY) < 0.000001)
            #expect(abs(crop.selection.width - expected.width) < 0.000001)
            #expect(abs(crop.selection.height - expected.height) < 0.000001)
        }
        func drag(from start: CGPoint, to end: CGPoint) throws {
            for (type, point) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)] {
                let location = crop.convert(CGPoint(x: point.x * editor.zoom, y: point.y * editor.zoom), to: nil)
                let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: 0, windowNumber: editor.window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1))
                if type == .leftMouseDown { crop.mouseDown(with: event) }
                else if type == .leftMouseDragged { crop.mouseDragged(with: event) }
                else { crop.mouseUp(with: event) }
            }
        }
        try drag(from: .zero, to: CGPoint(x: 40, y: 30))
        expectSelection(CGRect(x: 40, y: 30, width: 360, height: 170))
        try drag(from: CGPoint(x: 220, y: 115), to: CGPoint(x: 200, y: 100))
        expectSelection(CGRect(x: 20, y: 15, width: 360, height: 170))
        editor.state.busy = true
        try drag(from: CGPoint(x: 20, y: 15), to: CGPoint(x: 100, y: 100))
        expectSelection(CGRect(x: 20, y: 15, width: 360, height: 170))
        editor.state.busy = false
        editor.state.action?(.reselect)
        #expect(crop.selection == CGRect(x: 0, y: 0, width: 400, height: 200))
    }
}
