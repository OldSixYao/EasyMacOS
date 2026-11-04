import AppKit
import Carbon
import ImageIO
import PasteManCore
import Testing

@testable import PasteMan

private func testImage(width: Int = 120, height: Int = 80, patterned: Bool = false) -> CGImage {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            bytes[i] = patterned ? UInt8((x * 47 + y * 23) % 256) : (y < height / 2 ? 255 : 0)
            bytes[i + 1] = patterned ? UInt8((x * 17 + y * 59) % 256) : 0
            bytes[i + 2] = patterned ? UInt8((x * 31 + y * 7) % 256) : (y < height / 2 ? 0 : 255)
        }
    }
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false,
        intent: .defaultIntent)!
}

private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
    let data = image.dataProvider!.data!
    let ptr = CFDataGetBytePtr(data)!
    let offset = y * image.bytesPerRow + x * 4
    return Array(UnsafeBufferPointer(start: ptr + offset, count: 4))
}

@Suite("Screenshot images") struct ScreenshotImageTests {
    @Test func cursorSamplesFrozenPixelsInSrgbAtRetinaScaleAndClampsEdges() throws {
        let sampler = try #require(ScreenshotPixelSampler(image: testImage(width: 240, height: 160, patterned: true)))
        let size = CGSize(width: 120, height: 80)
        let value = try #require(sampler.sample(at: CGPoint(x: 12.5, y: 20), pointSize: size))
        #expect(value.x == 25 && value.y == 40)
        #expect(value.red == UInt8((25 * 47 + 40 * 23) % 256))
        #expect(value.green == UInt8((25 * 17 + 40 * 59) % 256))
        #expect(value.blue == UInt8((25 * 31 + 40 * 7) % 256))
        #expect(value.hex == String(format: "#%02X%02X%02X", value.red, value.green, value.blue))
        let edge = try #require(sampler.sample(at: CGPoint(x: 120, y: 80), pointSize: size))
        #expect(edge.x == 239 && edge.y == 159)
        let negative = try #require(sampler.sample(at: CGPoint(x: -1, y: -1), pointSize: size))
        #expect(negative.x == 0 && negative.y == 0)
        #expect(sampler.sample(at: .zero, pointSize: .zero) == nil)
        let vertical = try #require(ScreenshotPixelSampler(image: testImage()))
        #expect(vertical.sample(at: CGPoint(x: 5, y: 5), pointSize: size)?.hex == "#FF0000")
        #expect(vertical.sample(at: CGPoint(x: 5, y: 75), pointSize: size)?.hex == "#0000FF")
    }
    @Test func cursorCardAvoidsPointerAndScreenEdges() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 799, y: 599), CGPoint(x: 799, y: 0), CGPoint(x: 0, y: 599)] {
            let card = ScreenshotGeometry.cursorCard(at: point, bounds: bounds)
            #expect(bounds.contains(card))
            #expect(!card.contains(point))
        }
    }

    @Test func selectionCoordinatesHandleDirectionNegativeScreenOriginAndScale() {
        let screen = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        #expect(ScreenshotGeometry.localPoint(CGPoint(x: -1900, y: 860), in: screen) == CGPoint(x: 20, y: 20))
        let selection = ScreenshotGeometry.rect(from: CGPoint(x: 90, y: 70), to: CGPoint(x: 10, y: 20))
        #expect(selection == CGRect(x: 10, y: 20, width: 80, height: 50))
        #expect(
            ScreenshotGeometry.pixelRect(
                selection, pointSize: CGSize(width: 120, height: 80),
                pixelSize: CGSize(width: 240, height: 160)) == CGRect(x: 20, y: 40, width: 160, height: 100))
        #expect(
            ScreenshotGeometry.pixelRect(
                selection, pointSize: CGSize(width: 120, height: 80),
                pixelSize: CGSize(width: 120, height: 80)) == selection)
        #expect(
            ScreenshotGeometry.pixelRect(
                CGRect(x: -10, y: -10, width: 30, height: 30),
                pointSize: CGSize(width: 120, height: 80), pixelSize: CGSize(width: 120, height: 80))
                == CGRect(x: 0, y: 0, width: 20, height: 20))
    }

    @Test func renderingPreservesOrientationPixelsAndPngDimensions() throws {
        let image = testImage()
        let output = try ScreenshotRenderer.export(
            base: image, pointSize: CGSize(width: 60, height: 40), annotations: [])
        #expect(pixel(output.image, 10, 10) == [255, 0, 0, 255])
        #expect(pixel(output.image, 10, 70) == [0, 0, 255, 255])
        let source = try #require(CGImageSourceCreateWithData(output.png as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 120 && decoded.height == 80)
        let crop = try #require(image.cropping(to: CGRect(x: 0, y: 0, width: 20, height: 20)))
        let rendered = try ScreenshotRenderer.render(
            base: crop, pointSize: CGSize(width: 10, height: 10), annotations: [])
        #expect(pixel(rendered, 5, 5) == [255, 0, 0, 255])
    }

    @Test func allDrawingToolsChangePixelsAndUndoRedoBranchesCorrectly() throws {
        let base = testImage()
        let original = try ScreenshotRenderer.render(
            base: base, pointSize: CGSize(width: 120, height: 80), annotations: [])
        for tool in [AnnotationTool.rectangle, .ellipse, .arrow, .pen, .text] {
            let annotation = ScreenshotAnnotation(
                tool: tool, points: [CGPoint(x: 15, y: 15), CGPoint(x: 90, y: 60)],
                color: AnnotationColor.palette[2], width: 3, text: "中文 Hello")
            let rendered = try ScreenshotRenderer.render(
                base: base, pointSize: CGSize(width: 120, height: 80), annotations: [annotation])
            #expect(rendered.dataProvider!.data! as Data != original.dataProvider!.data! as Data)
        }
        var history = AnnotationHistory()
        let value = ScreenshotAnnotation(
            tool: .pen, points: [.zero, CGPoint(x: 10, y: 10)], color: AnnotationColor.palette[0], width: 3)
        history.append(value)
        history.undo()
        #expect(history.annotations.isEmpty && history.undone.count == 1)
        history.redo()
        #expect(history.annotations.count == 1 && history.undone.isEmpty)
        history.undo()
        history.append(value)
        history.redo()
        #expect(history.annotations.count == 1 && history.undone.isEmpty)
    }

    @Test func mosaicChangesActualPixelsOnlyInsideItsRegionAndHonorsDrawingOrder() throws {
        let base = testImage(patterned: true)
        let size = CGSize(width: 120, height: 80)
        let original = try ScreenshotRenderer.render(base: base, pointSize: size, annotations: [])
        let mosaic = ScreenshotAnnotation(
            tool: .mosaic, points: [CGPoint(x: 20, y: 10), CGPoint(x: 100, y: 70)],
            color: AnnotationColor.palette[0], width: 6)
        let output = try ScreenshotRenderer.export(base: base, pointSize: size, annotations: [mosaic])
        #expect(pixel(output.image, 2, 2) == pixel(original, 2, 2))
        #expect(pixel(output.image, 119, 79) == pixel(original, 119, 79))
        #expect(pixel(output.image, 25, 15) == pixel(output.image, 30, 20))
        #expect(pixel(output.image, 25, 15) != pixel(original, 25, 15))
        let stroke = ScreenshotAnnotation(
            tool: .pen, points: [CGPoint(x: 25, y: 20), CGPoint(x: 95, y: 60)],
            color: AnnotationColor.palette[2], width: 6)
        let a = try ScreenshotRenderer.render(base: base, pointSize: size, annotations: [stroke, mosaic])
        let b = try ScreenshotRenderer.render(base: base, pointSize: size, annotations: [mosaic, stroke])
        #expect(a.dataProvider!.data! as Data != b.dataProvider!.data! as Data)
        let source = try #require(CGImageSourceCreateWithData(output.png as CFData, nil))
        let flattened = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(flattened.width == base.width && flattened.height == base.height)
    }
}

@MainActor private final class ScreenshotPermissions: ClipboardPermissionChecking {
    var allowsMonitoring = true
    func refreshClipboard() {}
}

@MainActor private final class DelayedScreenCapture: ScreenCapturing {
    var calls = 0
    var continuation: CheckedContinuation<[CapturedScreen], any Error>?
    func capture(_ screens: [ScreenshotScreen]) async throws -> [CapturedScreen] {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
}

@Suite("Screenshot integration", .serialized) @MainActor struct ScreenshotIntegrationTests {
    @Test func pendingCaptureRejectsReentryAndDiscardsLateResultsAfterCancellation() async throws {
        let service = DelayedScreenCapture()
        let coordinator = ScreenshotCoordinator(captureService: service)
        coordinator.start(screens: [], sourceID: "test.editor", sourceName: "Editor")
        coordinator.start(screens: [], sourceID: "test.editor", sourceName: "Editor")
        for _ in 0..<100 where service.calls == 0 { await Task.yield() }
        #expect(service.calls == 1 && coordinator.phase == .capturing)
        coordinator.cancel()
        service.continuation?.resume(returning: [])
        for _ in 0..<20 { await Task.yield() }
        #expect(coordinator.phase == .idle && coordinator.selectedScreen == nil)
        #expect(coordinator.pins.count == 0)
    }

    @Test func failedCaptureReturnsToIdleAndReportsError() async {
        let service = DelayedScreenCapture()
        let coordinator = ScreenshotCoordinator(captureService: service)
        var errors = 0
        coordinator.onError = { _ in errors += 1 }
        coordinator.start(screens: [], sourceID: "test", sourceName: "Test")
        for _ in 0..<100 where service.calls == 0 { await Task.yield() }
        service.continuation?.resume(throwing: ScreenshotImageError.captureUnavailable)
        for _ in 0..<100 where coordinator.isActive { await Task.yield() }
        #expect(errors == 1 && coordinator.phase == .idle)
    }

    @Test func screenshotCopyRecordsOnceAndRespectsPrivacyAndPauseWithoutReadingClipboard() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ScreenshotTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = AppSettings(defaults: defaults)
        settings.hasOnboarded = true
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let clipboard = SystemClipboard(pasteboard: board)
        let permissions = ScreenshotPermissions()
        let store = try HistoryStore(directory: directory)
        let monitor = ClipboardMonitor(
            clipboard: clipboard, repository: store, settings: settings,
            permissions: permissions, sourceApplication: { ("test.editor", "Editor") })
        settings.onRecordingChanged = { monitor.recordingStateChanged() }
        let image = try ScreenshotRenderer.export(
            base: testImage(), pointSize: CGSize(width: 120, height: 80), annotations: [])
        #expect(clipboard.write(.image(png: image.png, thumbnail: Data())))
        monitor.ignoreOwnWrite()
        let ticket = try #require(monitor.screenshotTicket(sourceID: "test.editor"))
        try await monitor.recordScreenshot(image.png, sourceID: "test.editor", sourceName: "Editor", ticket: ticket)
        await monitor.poll()
        #expect(try await store.list().count == 1)
        #expect(try await store.list().first?.sourceBundleID == "test.editor")
        let oldTicket = try #require(monitor.screenshotTicket(sourceID: "test.editor"))
        settings.paused = true
        #expect(monitor.screenshotTicket(sourceID: "test.editor") == nil)
        settings.paused = false
        try await monitor.recordScreenshot(image.png, sourceID: "other", sourceName: "Other", ticket: oldTicket)
        #expect(try await store.list().first?.sourceBundleID == "test.editor")
        settings.excludedApps.insert("test.editor")
        #expect(monitor.screenshotTicket(sourceID: "test.editor") == nil)
        settings.excludedApps.remove("test.editor")
        permissions.allowsMonitoring = false
        #expect(monitor.screenshotTicket(sourceID: "test.editor") == nil)
    }

    private func editor(save: @escaping (Data) async throws -> Bool = { _ in false }) async throws
        -> (ScreenshotCoordinator, ScreenshotOverlay)
    {
        let service = DelayedScreenCapture()
        let coordinator = ScreenshotCoordinator(captureService: service, presentWindow: { _ in }, saveImage: save)
        let screen = ScreenshotScreen(id: 42, frame: CGRect(x: 0, y: 0, width: 800, height: 600), scale: 1)
        coordinator.start(screens: [screen], sourceID: "test.editor", sourceName: "Editor")
        for _ in 0..<100 where service.calls == 0 { await Task.yield() }
        service.continuation?.resume(returning: [
            CapturedScreen(screen: screen, image: testImage(width: 800, height: 600))
        ])
        for _ in 0..<100 where coordinator.phase == .capturing { await Task.yield() }
        let view = try #require(coordinator.windows.first?.contentView as? ScreenshotOverlay)
        try drag(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 350, y: 250))
        #expect(coordinator.phase == .editing)
        #expect(view.selectedImage?.width == 300 && view.selectedImage?.height == 200)
        return (coordinator, view)
    }
    private func drag(_ view: ScreenshotOverlay, from: CGPoint, to: CGPoint) throws {
        func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: CGPoint(x: point.x, y: view.bounds.height - point.y),
                    modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, at: from))
        view.mouseDragged(with: try event(.leftMouseDragged, at: to))
        view.mouseUp(with: try event(.leftMouseUp, at: to))
    }
    private func waitForExport(_ coordinator: ScreenshotCoordinator) async throws {
        for _ in 0..<200 {
            if coordinator.phase != .exporting { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Screenshot export timed out")
    }

    @Test func rightClickCancelsSelectionAndAnnotationIncludingTextEditor() async throws {
        for phase in 0..<3 {
            let (coordinator, view) = try await editor()
            defer { coordinator.cancel() }
            var copied = false
            coordinator.onCopy = { _, _, _ in
                copied = true
                return true
            }
            if phase == 0 { coordinator.reselect() }
            if phase == 2 {
                view.state.action?(.tool(.text))
                try drag(view, from: CGPoint(x: 80, y: 80), to: CGPoint(x: 80, y: 80))
                let text = try #require(view.subviews.compactMap { $0 as? NSTextView }.first)
                text.string = "未完成的标注"
            }
            let window = try #require(coordinator.windows.first)
            let rightClick = try #require(
                NSEvent.mouseEvent(
                    with: .rightMouseDown,
                    location: CGPoint(x: 80, y: 520), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(rightClick)
            #expect(coordinator.phase == .idle && coordinator.windows.isEmpty)
            #expect(window.contentView == nil && !copied && coordinator.pins.count == 0)
        }
    }

    @Test func selectionMovesResizesAndLocksWhenAnnotationsBegin() async throws {
        let (coordinator, view) = try await editor()
        defer { coordinator.cancel() }
        try drag(view, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 130, y: 120))
        #expect(view.selection.origin == CGPoint(x: 80, y: 70))
        try drag(view, from: CGPoint(x: 380, y: 270), to: CGPoint(x: 400, y: 300))
        #expect(view.selection.size == CGSize(width: 320, height: 230))
        view.state.action?(.tool(.rectangle))
        try drag(view, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 180))
        #expect(view.state.history.annotations.count == 1 && !view.state.canAdjust)
        #expect(view.state.history.annotations.first?.points.first == CGPoint(x: 20, y: 30))
        view.state.action?(.undo)
        #expect(view.state.history.annotations.isEmpty && !view.state.canAdjust)
        view.state.action?(.reselect)
        #expect(coordinator.phase == .selecting && coordinator.selectedScreen == nil)
        #expect(view.selectedImage == nil && view.state.history.undone.isEmpty)
    }

    @Test func copyFailureKeepsEditorAndSuccessfulCopyClosesItWithSameFlattenedPng() async throws {
        let (coordinator, view) = try await editor()
        defer { coordinator.cancel() }
        coordinator.onCopy = { _, _, _ in false }
        view.state.action?(.copy)
        try await waitForExport(coordinator)
        #expect(coordinator.phase == .editing && view.state.error != nil)
        var copied: ScreenshotImage?
        coordinator.onCopy = { image, id, name in
            copied = image
            #expect(id == "test.editor" && name == "Editor")
            return true
        }
        view.state.action?(.copy)
        try await waitForExport(coordinator)
        #expect(coordinator.phase == .idle && coordinator.windows.isEmpty)
        let value = try #require(copied)
        let expected = try ScreenshotRenderer.export(
            base: testImage(width: 800, height: 600).cropping(to: CGRect(x: 50, y: 50, width: 300, height: 200))!,
            pointSize: CGSize(width: 300, height: 200), annotations: [])
        #expect(value.png == expected.png)
    }

    @Test func saveCancellationAndFailurePreserveEditorAndSavingDoesNotCopy() async throws {
        var savedPng: Data?
        let (cancelled, first) = try await editor(save: { data in
            savedPng = data
            return false
        })
        var copied = 0
        cancelled.onCopy = { _, _, _ in
            copied += 1
            return true
        }
        first.state.action?(.save)
        try await waitForExport(cancelled)
        #expect(cancelled.phase == .editing && !first.state.busy && savedPng != nil && copied == 0)
        cancelled.cancel()
        let (failed, second) = try await editor(save: { _ in throw CocoaError(.fileWriteNoPermission) })
        second.state.action?(.save)
        try await waitForExport(failed)
        #expect(failed.phase == .editing && second.state.error != nil && !second.state.busy)
        failed.cancel()
        let (saved, third) = try await editor(save: { _ in true })
        saved.onCopy = { _, _, _ in
            copied += 1
            return true
        }
        third.state.action?(.save)
        try await waitForExport(saved)
        #expect(saved.phase == .idle && copied == 0)
    }

    @Test func textCommitsBeforeExportAndPinsKeepIndependentImagesUntilClosed() async throws {
        let (coordinator, view) = try await editor()
        defer { coordinator.cancel() }
        view.state.action?(.tool(.text))
        try drag(view, from: CGPoint(x: 80, y: 80), to: CGPoint(x: 80, y: 80))
        let editor = try #require(view.subviews.compactMap { $0 as? NSTextView }.first)
        editor.string = "中文输入\nHello"
        var copied: ScreenshotImage?
        coordinator.onCopy = { image, _, _ in
            copied = image
            return true
        }
        view.state.action?(.copy)
        try await waitForExport(coordinator)
        #expect(view.state.history.annotations.last?.text == "中文输入\nHello")
        #expect(view.subviews.compactMap { $0 as? NSTextView }.isEmpty)
        let image = try #require(copied)
        let pins = PinnedScreenshotManager(presentWindow: { _ in })
        var copies = 0
        pins.onCopy = { value, id, _ in
            #expect(value.png == image.png && id == "test.editor")
            copies += 1
            return true
        }
        pins.show(image, sourceID: "test.editor", sourceName: "Editor", origin: .zero)
        pins.show(image, sourceID: "test.editor", sourceName: "Editor", origin: .zero)
        #expect(pins.count == 2 && copies == 0)
        let window = try #require(pins.windows.first)
        #expect(window.level == .floating && !window.hidesOnDeactivate)
        #expect(window.contentAspectRatio == image.pointSize)
        #expect(!window.styleMask.contains(.titled) && !window.styleMask.contains(.closable))
        #expect(!window.styleMask.contains(.miniaturizable))
        #expect(window.contentRect(forFrameRect: window.frame) == window.frame)
        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseUp, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0))
        let copy = try #require(window.contentView?.menu(for: event)?.items.first)
        #expect(NSApp.sendAction(try #require(copy.action), to: copy.target, from: copy))
        #expect(copies == 1)
        let doubleClick = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: CGPoint(x: 10, y: 10), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 2, pressure: 1))
        window.contentView?.mouseDown(with: doubleClick)
        #expect(pins.count == 1 && window.contentView == nil)
        #expect(pins.windows.first?.contentView != nil && copies == 1)
        pins.closeAll()
        #expect(pins.count == 0)
    }

    @Test func cursorColorCopyStaysInSelectionAndToolbarDefaultsToOneRow() throws {
        let coordinator = ScreenshotCoordinator(presentWindow: { _ in })
        let screen = ScreenshotScreen(id: 1, frame: CGRect(x: -800, y: 0, width: 800, height: 600), scale: 1)
        let view = ScreenshotOverlay(
            capture: CapturedScreen(screen: screen, image: testImage(width: 800, height: 600)),
            coordinator: coordinator)
        let window = NSPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer {
            window.contentView = nil
            window.close()
            coordinator.cancel()
        }
        let movement = try #require(
            NSEvent.mouseEvent(
                with: .mouseMoved, location: CGPoint(x: 50, y: 550),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 0, pressure: 0))
        view.mouseMoved(with: movement)
        #expect(view.cursorSample?.x == 50 && view.cursorSample?.y == 50)
        var copied: String?
        coordinator.onCopyColor = {
            copied = $0
            return true
        }
        let key = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c",
                isARepeat: false, keyCode: UInt16(kVK_ANSI_C)))
        #expect(view.performKeyEquivalent(with: key))
        #expect(copied == "#FF0000" && view.selectedImage == nil)
        #expect(view.state.toolbarHeight == 46)
        view.state.optionsExpanded = true
        #expect(view.state.toolbarHeight == 82)
        view.mouseExited(with: movement)
        #expect(view.cursorSample == nil)
    }

    @Test func independentlyPersistedShortcutsRejectEachOtherAndDispatchSeparately() throws {
        let suite = "ScreenshotShortcuts." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.screenshotShortcut.label == "⌃⌥A")
        settings.screenshotShortcut = Shortcut(
            keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey), keyLabel: "S")
        let loaded = AppSettings(defaults: defaults)
        #expect(loaded.screenshotShortcut.label == "⌃⌥S" && loaded.shortcut.label == "⇧⌘V")
        let keys = HotKeyService()
        defer { keys.stop() }
        var history = 0
        var screenshots = 0
        keys.onInvoke = { history += 1 }
        keys.onScreenshot = { screenshots += 1 }
        keys.invoke(.history)
        keys.invoke(.screenshot)
        #expect(history == 1 && screenshots == 1)
        keys.record { _ in }
        keys.invoke(.history)
        keys.invoke(.screenshot)
        #expect(history == 1 && screenshots == 1)
        keys.cancelRecording()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            repository: try HistoryStore(directory: directory), settings: settings,
            permissions: PermissionService(), hotKeys: keys)
        #expect(!model.applyShortcut(settings.shortcut, for: .screenshot))
        #expect(!model.applyShortcut(settings.screenshotShortcut, for: .history))
        #expect(settings.screenshotShortcut.label == "⌃⌥S" && settings.shortcut.label == "⇧⌘V")
    }
}
