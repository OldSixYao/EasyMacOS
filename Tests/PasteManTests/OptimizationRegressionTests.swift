import AppKit
import PasteManCore
import Testing

@testable import PasteMan

@MainActor private final class QueueClipboard: ClipboardReading, ClipboardPermissionChecking {
    var changeCount = 0
    var types: Set<String> = []
    var allowsMonitoring = true
    var reads = 0
    var snapshot: ClipboardSnapshot?
    func refreshClipboard() {}
    func capture() -> ClipboardSnapshot? { reads += 1; return snapshot }
}

private actor DelayedPreparation {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func resume() { continuation?.resume(); continuation = nil }
}

@Suite("优化行为回归", .serialized) @MainActor struct OptimizationRegressionTests {
    @Test func layeredOverlayPreservesFrozenOrientationAndSingleMask() throws {
        _ = NSApplication.shared
        let context = try #require(CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 480,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 40))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 40, width: 120, height: 40))
        let image = try #require(context.makeImage())
        let screen = ScreenshotScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 120, height: 80), scale: 1)
        let coordinator = ScreenshotCoordinator(presentWindow: { _ in })
        let overlay = ScreenshotOverlay(capture: CapturedScreen(screen: screen, image: image), coordinator: coordinator)
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = overlay
        defer { overlay.dispose(); window.contentView = nil; window.close() }
        overlay.layoutSubtreeIfNeeded()
        let bitmap = try #require(overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds))
        overlay.cacheDisplay(in: overlay.bounds, to: bitmap)
        let output = try #require(bitmap.cgImage)
        let inputSampler = try #require(ScreenshotPixelSampler(image: image))
        let outputSampler = try #require(ScreenshotPixelSampler(image: output))
        for y in [CGFloat(10), 70] {
            let point = CGPoint(x: 10, y: y)
            let input = try #require(inputSampler.sample(at: point, pointSize: screen.frame.size))
            let result = try #require(outputSampler.sample(at: point, pointSize: screen.frame.size))
            // 窗口色彩转换允许小偏差，仍拒绝上下翻转或重复叠加遮罩。
            #expect(abs(Int(result.red) - Int(Double(input.red) * 0.58)) < 20)
            #expect(abs(Int(result.blue) - Int(Double(input.blue) * 0.58)) < 20)
        }
    }

    @Test func pinArchiveAndHistoryReusePreservePixelsAndOriginalResolution() async throws {
        let context = try #require(CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 480,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 40))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 40, width: 120, height: 40))
        let base = try #require(context.makeImage())
        let original = try ScreenshotRenderer.export(base: base, pointSize: CGSize(width: 60, height: 40), annotations: [])
        let archive = try await PinnedImageWorker.shared.archive(base: base, pointSize: original.pointSize, annotations: [])
        let restored = try await archive.loadImage()
        let png = try await archive.png()
        #expect(png == original.png)
        #expect(restored.width == 120 && restored.height == 80)
        let display = try await archive.display(maximumPixels: 30)
        #expect(display.width == 30 && display.height == 20)
        let compressed = PinnedImageStorage(png: original.png, pointSize: original.pointSize)
        let compressedDisplay = try await compressed.display(maximumPixels: 30)
        #expect(compressedDisplay.width == 30 && compressedDisplay.height == 20)
        let fullCompressed = try await compressed.loadImage()
        #expect(fullCompressed.width == base.width && fullCompressed.height == base.height)
        let sample = try #require(ScreenshotPixelSampler(image: compressedDisplay))
        let top = try #require(sample.sample(at: CGPoint(x: 10, y: 2), pointSize: CGSize(width: 30, height: 20)))
        let bottom = try #require(sample.sample(at: CGPoint(x: 10, y: 18), pointSize: CGSize(width: 30, height: 20)))
        #expect(top.blue > 240 && top.red < 10)
        #expect(bottom.red > 240 && bottom.blue < 10)
        let prepared = try await ScreenshotRenderWorker.shared.prepareHistory(original)
        if case .image(let saved, let thumbnail) = prepared {
            #expect(saved == original.png)
            #expect(!thumbnail.isEmpty)
        } else { Issue.record("截图必须保存为图片") }
    }

    @Test func incrementalPreviewMatchesFullRenderingAndUndoBranch() async throws {
        let context = try #require(CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 480,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        let base = try #require(context.makeImage())
        let size = CGSize(width: 120, height: 80)
        let session = UUID()
        var annotations: [ScreenshotAnnotation] = []
        for tool in [AnnotationTool.rectangle, .pen, .mosaic, .arrow] {
            annotations.append(ScreenshotAnnotation(tool: tool, points: [CGPoint(x: 10, y: 10), CGPoint(x: 80, y: 60)],
                color: AnnotationColor.palette[0], width: 3))
            let incremental = try await ScreenshotRenderWorker.shared.preview(base: base, pointSize: size,
                annotations: annotations, session: session)
            let full = try ScreenshotRenderer.render(base: base, pointSize: size, annotations: annotations, maximumDimension: 1800)
            #expect(incremental.dataProvider?.data as Data? == full.dataProvider?.data as Data?)
        }
        annotations.removeLast(2)
        let undone = try await ScreenshotRenderWorker.shared.preview(base: base, pointSize: size, annotations: annotations, session: session)
        let expected = try ScreenshotRenderer.render(base: base, pointSize: size, annotations: annotations, maximumDimension: 1800)
        #expect(undone.dataProvider?.data as Data? == expected.dataProvider?.data as Data?)
        await ScreenshotRenderWorker.shared.releasePreview(session: session)
    }

    @Test func suspensionDiscardsOldClipboardAndResumesFromFreshBaseline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let settings = AppSettings(defaults: defaults)
        settings.hasOnboarded = true
        let store = try HistoryStore(directory: directory)
        let board = QueueClipboard()
        let monitor = ClipboardMonitor(clipboard: board, repository: store, settings: settings,
            permissions: board, sourceApplication: { ("test", "应用") })
        monitor.setSessionActive(false)
        board.changeCount += 1
        board.snapshot = .text("锁屏期间")
        await monitor.poll()
        #expect(board.reads == 0)
        #expect(monitor.screenshotTicket(sourceID: "test") == nil)
        monitor.setSessionActive(true)
        await monitor.poll()
        board.changeCount += 1
        board.snapshot = .text("解锁后")
        await monitor.poll()
        #expect(try await store.list().map(\.preview) == ["解锁后"])
        monitor.stop()
    }

    @Test func processingQueueIsBoundedAndPauseDiscardsAllPendingCaptures() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let settings = AppSettings(defaults: defaults)
        settings.hasOnboarded = true
        let board = QueueClipboard()
        let store = try HistoryStore(directory: directory)
        let gate = DelayedPreparation()
        let monitor = ClipboardMonitor(clipboard: board, repository: store, settings: settings, permissions: board,
            sourceApplication: { ("test", "应用") }, prepareImage: { _ in await gate.wait(); return .text("旧图片") })
        var busy = 0
        monitor.onError = { if ($0 as? StoreError) == .processingBusy { busy += 1 } }
        board.changeCount += 1
        board.snapshot = .image(Data([1]))
        monitor.enqueueCapture()
        while !(await gate.started) { await Task.yield() }
        for index in 0..<10 {
            board.changeCount += 1
            board.snapshot = .text("待处理 \(index)")
            monitor.enqueueCapture()
        }
        #expect(monitor.pendingCaptureCount == 8)
        #expect(busy == 2)
        #expect(board.reads == 9, "等待队列已满时不能继续索取完整剪贴板数据")
        settings.paused = true
        monitor.recordingStateChanged()
        #expect(monitor.pendingCaptureCount == 0)
        await gate.resume()
        try await Task.sleep(for: .milliseconds(30))
        #expect(try await store.list().isEmpty)
        monitor.stop()
    }

    @Test func processingImageSharesCaptureByteBudgetAndFullBudgetSkipsReads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let settings = AppSettings(defaults: defaults)
        settings.hasOnboarded = true
        let board = QueueClipboard()
        let store = try HistoryStore(directory: directory)
        let gate = DelayedPreparation()
        let monitor = ClipboardMonitor(clipboard: board, repository: store, settings: settings, permissions: board,
            sourceApplication: { ("test", "应用") }, prepareImage: { _ in await gate.wait(); return .text("处理完成") })
        board.snapshot = .image(Data(repeating: 1, count: 20 * 1024 * 1024))
        board.changeCount += 1
        monitor.enqueueCapture()
        while !(await gate.started) { await Task.yield() }
        #expect(monitor.retainedCaptureBytes == 20 * 1024 * 1024)
        board.snapshot = .text(String(repeating: "x", count: 12 * 1024 * 1024))
        board.changeCount += 1
        monitor.enqueueCapture()
        #expect(monitor.retainedCaptureBytes == 32 * 1024 * 1024)
        let reads = board.reads
        board.snapshot = .text("满载时不应读取，也不应事后补录")
        board.changeCount += 1
        monitor.enqueueCapture()
        #expect(board.reads == reads)
        settings.paused = true
        monitor.recordingStateChanged()
        await gate.resume()
        for _ in 0..<100 where monitor.retainedCaptureBytes > 0 { try await Task.sleep(for: .milliseconds(1)) }
        #expect(monitor.retainedCaptureBytes == 0)
        #expect(try await store.list().isEmpty)
        monitor.stop()
    }

    @Test func pinChangesPreserveOtherBitmapsAndPressureIncludesLayerContents() async throws {
        _ = NSApplication.shared
        let context = try #require(CGContext(data: nil, width: 1600, height: 900, bitsPerComponent: 8,
            bytesPerRow: 6400, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let base = try #require(context.makeImage())
        let pins = PinnedScreenshotManager(presentWindow: { _ in })
        defer { pins.closeAll() }
        for _ in 0..<6 {
            let image = try await PinnedImageWorker.shared.archive(base: base, pointSize: CGSize(width: 200, height: 112.5), annotations: [])
            pins.show(image, sourceID: "test", sourceName: "应用", origin: nil)
        }
        await pins.waitForDisplays()
        let first = try #require(pins.windows.first)
        let bitmap = try #require(first.contentView?.layer?.contents) as AnyObject
        let decodes = pins.displayDecodeCount
        let extra = try await PinnedImageWorker.shared.archive(base: base, pointSize: CGSize(width: 200, height: 112.5), annotations: [])
        pins.show(extra, sourceID: "test", sourceName: "应用", origin: nil)
        await pins.waitForDisplays()
        pins.windows.last?.close()
        await pins.waitForDisplays()
        let retained = first.contentView?.layer?.contents as AnyObject?
        #expect(retained === bitmap)
        #expect(pins.displayDecodeCount == decodes)
        for index in 0..<40 {
            let width = CGFloat(600 + index * 2)
            first.setContentSize(CGSize(width: width, height: width * 0.5625))
            await Task.yield()
        }
        await pins.waitForDisplays()
        #expect(pins.displayDecodeCount == decodes + 1, "连续放大只能补一次清晰位图")
        pins.applyMemoryPressure(.critical)
        await pins.waitForDisplays()
        let layerBytes = try pins.windows.reduce(0) { total, window in
            let contents = try #require(window.contentView?.layer?.contents)
            try #require(CFGetTypeID(contents as CFTypeRef) == CGImage.typeID)
            let image = contents as! CGImage
            return total + image.bytesPerRow * image.height
        }
        #expect(layerBytes > 0 && layerBytes == pins.cachedDisplayByteCount)
        #expect(layerBytes <= 4 * 1024 * 1024)
        pins.applyMemoryPressure(.normal)
        await pins.waitForDisplays()
        #expect(pins.cachedDisplayByteCount <= 32 * 1024 * 1024)
    }

    @Test func keyboardSelectionCrossesPagesWithoutLosingItems() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let keys = HotKeyService()
        defer {
            keys.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = try HistoryStore(directory: directory)
        for index in 0..<205 {
            try await store.save(.text("分页记录 \(index)"), sourceBundleID: "test", sourceName: "应用", policy: RetentionPolicy())
        }
        let model = AppModel(repository: store, settings: AppSettings(defaults: defaults), permissions: PermissionService(), hotKeys: keys)
        model.refresh()
        while model.loading { try await Task.sleep(for: .milliseconds(1)) }
        #expect(model.entries.count == 100 && model.hasMore)
        model.selection = model.entries.last?.id
        model.moveSelection(1)
        while model.loadingMore { try await Task.sleep(for: .milliseconds(1)) }
        #expect(model.entries.count == 200)
        #expect(model.selection == model.entries[100].id)
        model.loadMore()
        while model.loadingMore { try await Task.sleep(for: .milliseconds(1)) }
        #expect(model.entries.count == 205 && !model.hasMore)
        #expect(Set(model.entries.map(\.id)).count == 205)
        model.cancelRefresh()
    }
}
