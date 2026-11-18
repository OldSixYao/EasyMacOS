import AppKit
import Testing

@testable import PasteMan

@MainActor private struct MosaicCapture: ScreenCapturing {
    let image: CGImage
    func capture(_ screens: [ScreenshotScreen]) async throws -> [CapturedScreen] {
        screens.map { CapturedScreen(screen: $0, image: image) }
    }
}

@Suite("马赛克编辑交互", .serialized) @MainActor struct ScreenshotMosaicEditingTests {
    private func event(_ type: NSEvent.EventType, _ point: CGPoint, in view: NSView) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    private func overlay() async throws -> (ScreenshotCoordinator, ScreenshotOverlay) {
        _ = NSApplication.shared
        let coordinator = ScreenshotCoordinator(captureService: MosaicCapture(image: mosaicImage(width: 800, height: 600)),
            presentWindow: { _ in })
        coordinator.start(screens: [ScreenshotScreen(id: 42, frame: CGRect(x: 0, y: 0, width: 800, height: 600), scale: 1)],
            sourceID: "test.mosaic", sourceName: "马赛克测试")
        let deadline = ContinuousClock.now + .seconds(3)
        while coordinator.phase == .capturing, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let view = try #require(coordinator.windows.first?.contentView as? ScreenshotOverlay)
        view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 20, y: 20), in: view))
        view.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 720, y: 520), in: view))
        view.state.action?(.tool(.mosaic)); view.state.mosaicOptions.mode = .brush
        return (coordinator, view)
    }

    @Test func ordinaryScreenshotShowsRealPixelsBeforeReleaseAndCommitsOneUndoStep() async throws {
        let (coordinator, view) = try await overlay()
        defer { coordinator.cancel() }
        let start = CGPoint(x: 60, y: 200), middle = CGPoint(x: 180, y: 200), end = CGPoint(x: 180, y: 300)
        view.mouseDown(with: try event(.leftMouseDown, start, in: view))
        view.mouseDragged(with: try event(.leftMouseDragged, middle, in: view))
        view.mouseDragged(with: try event(.leftMouseDragged, end, in: view))
        await view.mosaicPreview.waitForSources()
        #expect(view.state.history.annotations.isEmpty && view.mosaicPreview.hasLayers)
        #expect(view.mosaicPreview.cachedBytes > 0 && view.mosaicPreview.cachedBytes <= ScreenshotRenderer.mosaicCacheLimit)

        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 600,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let graphics = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.translateBy(x: 0, y: 600); context.scaleBy(x: 1, y: -1)
        ScreenshotRenderer.drawImage(view.capture.image, in: view.bounds, context: context)
        view.drawInteraction(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let displayed = try #require(bitmap.cgImage)
        #expect(mosaicPixel(displayed, 100, 200) != mosaicPixel(view.capture.image, 100, 200))

        view.mouseUp(with: try event(.leftMouseUp, end, in: view))
        let mark = try #require(view.state.history.annotations.first)
        #expect(view.state.history.annotations.count == 1 && mark.isMosaicBrush && mark.points.count == 3)
        #expect(mark.points == [CGPoint(x: 40, y: 180), CGPoint(x: 160, y: 180), CGPoint(x: 160, y: 280)])
        let selected = try #require(view.selectedImage)
        let exported = try ScreenshotRenderer.render(base: selected, pointSize: view.selection.size, annotations: [mark])
        #expect(mosaicPixel(exported, 80, 180) != mosaicPixel(selected, 80, 180))
        view.state.mosaicOptions.brushSize = 80; view.state.mosaicOptions.blockSize = 24
        #expect(view.state.history.annotations.first?.mosaic?.brushSize == 32)
        #expect(view.state.history.annotations.first?.mosaic?.blockSize == 12)
        view.state.action?(.undo)
        #expect(view.state.history.annotations.isEmpty && !view.mosaicPreview.hasLayers)
        view.state.action?(.redo)
        #expect(view.state.history.annotations == [mark])
    }

    @Test(arguments: [CGFloat(0.5), 1, 2])
    func sharedCanvasKeepsLogicalPathAndScalesBrushCursor(_ zoom: CGFloat) async throws {
        _ = NSApplication.shared
        let editor = PinnedScreenshotEditor(image: mosaicImage(width: 800, height: 600),
            pointSize: CGSize(width: 800, height: 600), mode: .annotate)
        defer { editor.close() }
        editor.state.action?(.tool(.mosaic)); editor.state.mosaicOptions.mode = .brush
        let canvas = editor.canvas
        canvas.zoom = zoom; canvas.setFrameSize(CGSize(width: 800 * zoom, height: 600 * zoom))
        let point = CGPoint(x: 60 * zoom, y: 60 * zoom)
        canvas.mouseMoved(with: try event(.mouseMoved, point, in: canvas))
        #expect(canvas.mosaicCursorRect?.width == 32 * zoom)
        #expect(canvas.mosaicCursorRect?.midX == point.x)
        editor.state.mosaicOptions.brushSize = 64
        #expect(canvas.mosaicCursorRect?.width == 64 * zoom)
        canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 30 * zoom, y: 30 * zoom), in: canvas))
        canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 100 * zoom, y: 30 * zoom), in: canvas))
        await canvas.mosaicPreview.waitForSources()
        #expect(canvas.mosaicPreview.hasLayers && canvas.mosaicPreview.cachedBytes > 0)
        canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 100 * zoom, y: 80 * zoom), in: canvas))
        let mark = try #require(editor.state.history.annotations.first)
        #expect(mark.points == [CGPoint(x: 30, y: 30), CGPoint(x: 100, y: 30), CGPoint(x: 100, y: 80)])
        #expect(mark.mosaic?.brushSize == 64 && mark.mosaic?.blockSize == 12)
        editor.state.action?(.undo)
        #expect(editor.state.history.annotations.isEmpty && !canvas.mosaicPreview.hasLayers)
        editor.state.action?(.redo)
        #expect(editor.state.history.annotations == [mark])
        canvas.mouseExited(with: try event(.mouseMoved, point, in: canvas))
        #expect(canvas.mosaicCursorRect == nil)
    }

    @Test func dotCommitsButRectangleClickDoesNotAndClosingDropsPendingSources() async throws {
        let (coordinator, view) = try await overlay()
        let point = CGPoint(x: 70, y: 240)
        view.mouseDown(with: try event(.leftMouseDown, point, in: view))
        view.mouseUp(with: try event(.leftMouseUp, point, in: view))
        #expect(view.state.history.annotations.count == 1 && view.state.history.annotations[0].points.count == 1)
        view.state.mosaicOptions.mode = .rectangle
        view.mouseDown(with: try event(.leftMouseDown, point, in: view))
        view.mouseUp(with: try event(.leftMouseUp, point, in: view))
        #expect(view.state.history.annotations.count == 1)
        view.state.mosaicOptions.mode = .brush
        view.mouseDown(with: try event(.leftMouseDown, point, in: view))
        coordinator.cancel()
        await view.mosaicPreview.waitForSources()
        #expect(!view.mosaicPreview.hasLayers && view.mosaicPreview.cachedBytes == 0 && view.mosaicCursorRect == nil)
    }

    @Test func livePreviewTracksVisibleRegionsAndDiscardsCanceledGenerations() async throws {
        let image = mosaicImage(width: 1800, height: 2600), size = CGSize(width: 1800, height: 2600)
        let preview = ScreenshotMosaicPreview()
        defer { preview.dispose() }
        var mark = ScreenshotAnnotation(tool: .mosaic, points: [.zero, CGPoint(x: 1700, y: 2550)],
            color: AnnotationColor.palette[0], width: 3, mosaic: ScreenshotMosaicOptions(mode: .rectangle, blockSize: 4))
        preview.begin(mark, preceding: [])
        preview.request(base: image, pointSize: size, visibleRegion: CGRect(x: 0, y: 0, width: 1800, height: 700))
        await preview.waitForSources()
        #expect(preview.cachedBytes > 0 && preview.cachedBytes <= ScreenshotRenderer.mosaicCacheLimit)
        let oldBytes = preview.cachedBytes
        preview.request(base: image, pointSize: size, visibleRegion: CGRect(x: 0, y: 2100, width: 1800, height: 500))
        await preview.waitForSources()
        #expect(preview.cachedBytes > 0 && preview.cachedBytes <= oldBytes)
        preview.end(commit: true)
        preview.reconcile(history: [mark])
        #expect(preview.hasLayers)
        preview.acknowledge([mark])
        #expect(!preview.hasLayers && preview.cachedBytes == 0)
        preview.begin(mark, preceding: [])
        preview.request(base: image, pointSize: size, visibleRegion: CGRect(origin: .zero, size: size))
        preview.clear()
        mark.mosaic?.blockSize = 24
        preview.begin(mark, preceding: [])
        preview.request(base: image, pointSize: size, visibleRegion: CGRect(x: 0, y: 0, width: 800, height: 600))
        await preview.waitForSources()
        #expect(preview.hasLayers && preview.cachedBytes > 0)
        preview.end(commit: true)
        preview.reconcile(history: [])
        #expect(!preview.hasLayers && preview.cachedBytes == 0)
    }

    @Test func scrollingEditorBrushCrossesPreviewTileBoundaryAsOneOperation() async throws {
        _ = NSApplication.shared
        let stitcher = LongScreenshotStitcher(scale: 2)
        _ = try await stitcher.append(mosaicImage(width: 400, height: 2400))
        let document = try #require(try await stitcher.finish())
        let editor = LongScreenshotEditor(document: document, notice: nil)
        defer { editor.close() }
        editor.setZoom(.actual)
        editor.state.action?(.tool(.mosaic)); editor.state.mosaicOptions.mode = .brush
        editor.scrollView.contentView.scroll(to: CGPoint(x: 0, y: 350))
        let canvas = editor.canvas
        canvas.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 40, y: 480), in: canvas))
        canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 120, y: 550), in: canvas))
        await canvas.mosaicPreview.waitForSources()
        #expect(canvas.mosaicPreview.cachedBytes > 0 && editor.state.history.annotations.isEmpty)
        canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 150, y: 580), in: canvas))
        #expect(editor.state.history.annotations.count == 1)
        #expect(editor.state.history.annotations.first?.points == [CGPoint(x: 40, y: 480), CGPoint(x: 120, y: 550), CGPoint(x: 150, y: 580)])
        await canvas.waitForTiles()
        #expect(!canvas.mosaicPreview.hasLayers)
        editor.state.action?(.undo)
        #expect(editor.state.history.annotations.isEmpty)
        editor.state.action?(.redo)
        #expect(editor.state.history.annotations.count == 1)
    }

    @Test func mosaicOptionsFitBothLanguagesAppearancesAndModes() async throws {
        _ = NSApplication.shared
        let language = L.language, preference = UserDefaults.standard.object(forKey: InterfaceLocalization.defaultsKey)
        defer {
            InterfaceLocalization.shared.setLanguage(language)
            if let preference { UserDefaults.standard.set(preference, forKey: InterfaceLocalization.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: InterfaceLocalization.defaultsKey) }
        }
        let output = ProcessInfo.processInfo.environment["EASYMACOS_MOSAIC_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        let context = try #require(CGContext(data: nil, width: 800, height: 500, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: 500); context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(red: 0.94, green: 0.96, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 800, height: 500))
        let colors = [AnnotationColor.palette[3], .palette[2], .palette[1], .palette[0]]
        for (index, color) in colors.enumerated() {
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 35 + index * 180, y: 40, width: 160, height: 240))
        }
        ScreenshotRenderer.draw(ScreenshotAnnotation(tool: .text, points: [CGPoint(x: 50, y: 320)],
            color: AnnotationColor.palette[5], width: 3, text: "电话 138 1234 5678\nMosaic preview 2026",
            textStyle: AnnotationTextStyle(fontSize: 28)), in: context)
        let image = try #require(context.makeImage())
        for chinese in [true, false] {
            InterfaceLocalization.shared.setLanguage(chinese ? .simplifiedChinese : .english)
            for dark in [false, true] {
                for mode in ScreenshotMosaicMode.allCases {
                    let editor = PinnedScreenshotEditor(image: image, pointSize: CGSize(width: 800, height: 500), mode: .annotate)
                    editor.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    editor.window.setContentSize(CGSize(width: 712, height: 460))
                    editor.state.action?(.tool(.mosaic)); editor.state.optionsExpanded = true
                    editor.state.mosaicOptions = ScreenshotMosaicOptions(mode: mode, brushSize: 48, blockSize: 12)
                    editor.state.layoutChanged?()
                    let canvas = editor.canvas, zoom = editor.zoom
                    let start = CGPoint(x: 100 * zoom, y: 110 * zoom), end = CGPoint(x: 650 * zoom, y: 220 * zoom)
                    canvas.mouseDown(with: try event(.leftMouseDown, start, in: canvas))
                    canvas.mouseDragged(with: try event(.leftMouseDragged, end, in: canvas))
                    await canvas.waitForTiles(); await canvas.mosaicPreview.waitForSources()
                    try await Task.sleep(for: .milliseconds(50))
                    #expect(editor.state.toolbarHeight == (mode == .brush ? 118 : 82))
                    let content = try #require(editor.window.contentView)
                    content.layoutSubtreeIfNeeded()
                    let anchors = descendants(content).compactMap { $0 as? ScreenshotHoverAnchorView }
                    for title in [ScreenshotMosaicMode.rectangle.title, ScreenshotMosaicMode.brush.title, L.t("Block size", "颗粒大小")] {
                        let anchor = try #require(anchors.first { $0.title == title })
                        #expect(content.bounds.contains(anchor.convert(anchor.bounds, to: content)))
                    }
                    if let output {
                        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                        content.cacheDisplay(in: content.bounds, to: bitmap)
                        let png = try #require(bitmap.representation(using: .png, properties: [:]))
                        try png.write(to: output.appendingPathComponent("mosaic-\(chinese ? "zh" : "en")-\(dark ? "dark" : "light")-\(mode.rawValue).png"))
                    }
                    editor.close()
                }
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
}
