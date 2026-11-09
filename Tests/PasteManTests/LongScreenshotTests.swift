import AppKit
import ImageIO
import PasteManCore
import Testing
@testable import PasteMan

private func longPage(width: Int = 192, height: Int = 240, offset: Int = 0,
                      top: Int = 0, bottom: Int = 0, dynamic: Bool = false) -> CGImage {
    var data = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        let row = y < top ? 90_000 + y : (y >= height - bottom ? 100_000 + y - height + bottom : offset + y - top)
        for x in 0..<width {
            var hash = UInt32(row) &* 747_796_405 &+ UInt32(x) &* 2_891_336_453
            hash = (hash ^ (hash >> 16)) &* 2_246_822_519
            let i = (y * width + x) * 4
            data[i] = UInt8(truncatingIfNeeded: hash)
            data[i + 1] = UInt8(truncatingIfNeeded: hash >> 8)
            data[i + 2] = UInt8(truncatingIfNeeded: hash >> 16)
            if dynamic && x > width * 3 / 4 && y > height / 3 && y < height / 2 { data[i] = 0; data[i + 1] = 0 }
        }
    }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

private func longBytes(_ image: CGImage) -> Data { image.dataProvider!.data! as Data }

@Suite("长截屏像素拼接") struct LongScreenshotImageTests {
    @Test func unequalStepsPartialLastFrameAndDuplicatesHaveNoMissingOrRepeatedRows() async throws {
        let stitcher = LongScreenshotStitcher(scale: 2)
        var offset = 0
        _ = try await stitcher.append(longPage())
        for distance in [60, 38, 0, 51, 7, 0, 23] {
            offset += distance
            let progress = try await stitcher.append(longPage(offset: offset))
            #expect(progress.added == distance)
        }
        let document = try #require(try await stitcher.finish())
        #expect(document.image.height == 240 + offset)
        #expect(document.pointSize == CGSize(width: 96, height: CGFloat(240 + offset) / 2))
        #expect(longBytes(document.image) == longBytes(longPage(height: 240 + offset)))
        #expect(try FileManager.default.attributesOfItem(atPath: document.directory.path)[.posixPermissions] as? Int == 0o700)
    }

    @Test func fixedHeaderAndFooterAppearExactlyOnce() async throws {
        let stitcher = LongScreenshotStitcher(scale: 1)
        _ = try await stitcher.append(longPage(top: 20, bottom: 18))
        for offset in [50, 90, 143, 157] {
            _ = try await stitcher.append(longPage(offset: offset, top: 20, bottom: 18))
        }
        let document = try #require(try await stitcher.finish())
        #expect(document.image.height == 397)
        #expect(longBytes(document.image) == longBytes(longPage(height: 397, top: 20, bottom: 18)))
    }

    @Test func translucentViewportEdgeDuringScrollingDoesNotLeaveInternalSeams() async throws {
        func frame(_ offset: Int, edge: Bool) -> CGImage {
            let image = longPage(offset: offset)
            guard edge else { return image }
            var data = longBytes(image)
            for y in 238..<240 {
                for x in 0..<192 {
                    for channel in 0..<3 {
                        let index = (y * 192 + x) * 4 + channel
                        data[index] = UInt8((Int(data[index]) * 3 + 255) / 4)
                    }
                }
            }
            return CGImage(width: 192, height: 240, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 192 * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: image.bitmapInfo,
                provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
        let stitcher = LongScreenshotStitcher(scale: 1)
        _ = try await stitcher.append(frame(0, edge: true))
        for offset in stride(from: 20, through: 200, by: 20) { _ = try await stitcher.append(frame(offset, edge: true)) }
        _ = try await stitcher.append(frame(200, edge: false))
        let document = try #require(try await stitcher.finish())
        #expect(longBytes(document.image) == longBytes(longPage(height: 440)))
    }

    @Test func smallDynamicAreaAndScrollbarDoNotPreventMatching() throws {
        let first = try LongScreenshotFeatures(longPage())
        let next = try LongScreenshotFeatures(longPage(offset: 47, dynamic: true))
        #expect(try first.match(next).displacement == 47)
        let changed = try LongScreenshotFeatures(longPage(dynamic: true))
        #expect(first.isStable(comparedTo: changed))
    }

    @Test func sparseTextUsesFineRowNumbersToDisambiguateSimilarLines() throws {
        func page(_ offset: Int, distinct: Bool) throws -> CGImage {
            let context = try #require(CGContext(data: nil, width: 1592, height: 1184, bitsPerComponent: 8,
                bytesPerRow: 1592 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1592, height: 1184))
            context.translateBy(x: 0, y: 1184); context.scaleBy(x: 2, y: -2)
            for row in 0..<55 {
                let y = CGFloat(52 + row * 44 - offset)
                context.setFillColor(CGColor(gray: row.isMultiple(of: 2) ? 1 : 0.95, alpha: 1))
                context.fill(CGRect(x: 0, y: y, width: 796, height: 44))
                ScreenshotRenderer.draw(ScreenshotAnnotation(tool: .text, points: [CGPoint(x: 44, y: y + 12)],
                    color: AnnotationColor.palette[5], width: 2.5, text: String(format: "第 %04d 行 · 长截屏验证内容", row + 1)), in: context)
                context.setFillColor(CGColor(gray: distinct ? CGFloat((row * 47) % 200) / 255 : 0.3, alpha: 1))
                context.fill(CGRect(x: 530, y: y + 9, width: CGFloat(24 + row % 19), height: 26))
            }
            context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.45, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 796, height: 52))
            context.fill(CGRect(x: 0, y: 564, width: 796, height: 28))
            return try #require(context.makeImage())
        }
        let similar = try LongScreenshotFeatures(page(0, distinct: false))
        #expect(try similar.match(LongScreenshotFeatures(page(148, distinct: false))).displacement == 296)
        let first = try LongScreenshotFeatures(page(0, distinct: true))
        #expect(try first.match(LongScreenshotFeatures(page(148, distinct: true))).displacement == 296)
    }

    @Test func unrelatedAndRepeatedPatternsAreRejected() throws {
        let first = try LongScreenshotFeatures(longPage())
        #expect(throws: (any Error).self) { try first.match(LongScreenshotFeatures(longPage(offset: 10_000))) }
        let context = try #require(CGContext(data: nil, width: 192, height: 240, bitsPerComponent: 8,
            bytesPerRow: 192 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 192, height: 240))
        let blank = try LongScreenshotFeatures(#require(context.makeImage()))
        #expect(try blank.match(blank).displacement == 0)
        func periodic(_ offset: Int) -> CGImage {
            let source = longBytes(longPage(height: 32))
            var bytes = Data()
            for y in 0..<240 {
                let start = ((y + offset) % 32) * 192 * 4
                bytes.append(source.subdata(in: start..<(start + 192 * 4)))
            }
            return CGImage(width: 192, height: 240, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 192 * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
        let repeated = try LongScreenshotFeatures(periodic(0))
        #expect(throws: (any Error).self) { try repeated.match(LongScreenshotFeatures(periodic(10))) }
    }

    @Test(arguments: [true, false]) func capacityKeepsAllReliableRowsWithoutDownscaling(_ heightLimit: Bool) async throws {
        let limits = LongScreenshotLimits(maximumHeight: heightLimit ? 300 : 50_000,
            maximumPixels: heightLimit ? 100_000_000 : 192 * 300)
        let stitcher = LongScreenshotStitcher(scale: 1, limits: limits)
        _ = try await stitcher.append(longPage())
        _ = try await stitcher.append(longPage(offset: 40))
        let last = try await stitcher.append(longPage(offset: 80))
        #expect(last.height == 300 && last.added == 20 && last.reachedLimit)
        let document = try #require(try await stitcher.finish())
        #expect(document.image.width == 192 && document.image.height == 300)
        #expect(longBytes(document.image) == longBytes(longPage(height: 300)))
    }

    @Test func rejectedFrameDoesNotChangePriorResultAndTemporaryFileIsRemoved() async throws {
        let stitcher = LongScreenshotStitcher(scale: 1)
        _ = try await stitcher.append(longPage())
        do { _ = try await stitcher.append(longPage(offset: 10_000)); Issue.record("应拒绝不可靠画面") } catch {}
        var document = try await stitcher.finish()
        let directory = try #require(document?.directory)
        #expect(longBytes(try #require(document?.image)) == longBytes(longPage()))
        document = nil
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func negativeDisplayOriginAndRetinaSelectionUseTopLeftPixelCoordinates() {
        let region = LongScreenshotRegion(screen: ScreenshotScreen(id: 5,
            frame: CGRect(x: -1440, y: -180, width: 1440, height: 900), scale: 2),
            selection: CGRect(x: 20.25, y: 30.25, width: 400, height: 300), desktopTop: 1080)
        #expect(region.quartzRect == CGRect(x: -1419.75, y: 390.25, width: 400, height: 300))
        #expect(region.appKitRect == CGRect(x: -1419.75, y: 389.75, width: 400, height: 300))
        #expect(region.pixelRect == CGRect(x: 40, y: 60, width: 801, height: 601))
    }

    @Test func allAnnotationsAtTopMiddleAndBottomPreserveCoordinatesThroughTilesAndExport() async throws {
        let stitcher = LongScreenshotStitcher(scale: 2)
        _ = try await stitcher.append(longPage(width: 240, height: 2400))
        let document = try #require(try await stitcher.finish())
        var history = AnnotationHistory()
        for y in [CGFloat(30), 560, 1110] {
            for (index, tool) in [AnnotationTool.rectangle, .ellipse, .arrow, .pen, .text, .mosaic].enumerated() {
                let x = CGFloat(5 + index * 18)
                history.append(ScreenshotAnnotation(tool: tool, points: [CGPoint(x: x, y: y), CGPoint(x: x + 14, y: y + 35)],
                    color: AnnotationColor.palette[2], width: 2, text: "字"))
            }
        }
        history.undo(); history.redo()
        history.append(ScreenshotAnnotation(tool: .mosaic, points: [CGPoint(x: 4, y: 480), CGPoint(x: 115, y: 1100)],
            color: AnnotationColor.palette[0], width: 3))
        let output = try await ScreenshotRenderWorker.shared.export(base: document.image,
            pointSize: document.pointSize, annotations: history.annotations)
        #expect(output.image.width == 240 && output.image.height == 2400)
        #expect(output.png != (try ScreenshotRenderer.encode(document.image)))
        for y in [0, 1024, 2048] {
            let tile = try await LongScreenshotTileWorker.shared.render(document: document,
                rect: CGRect(x: 0, y: y, width: 240, height: min(1024, 2400 - y)),
                annotations: history.annotations, maximumWidth: 240)
            let full = try ScreenshotRenderer.render(base: document.image, pointSize: document.pointSize,
                annotations: history.annotations)
            let crop = try #require(full.cropping(to: CGRect(x: 0, y: y, width: 240, height: min(1024, 2400 - y))))
            // 裁剪图像的行跨度可能仍引用整图；重新渲染使像素布局相同。
            let normalized = try ScreenshotRenderer.render(base: crop, pointSize: CGSize(width: 120, height: CGFloat(tile.height) / 2), annotations: [])
            #expect(longBytes(tile) == longBytes(normalized))
        }
    }
}

@MainActor private final class LongCaptureStub: LongScreenshotCapturing {
    var capturesContinuously = false
    var offset = 0
    var calls = 0
    var releases = 0
    var failureAfter: Int?
    var changingAfter: Int?
    var temporaryMismatch = 0
    var pending: CheckedContinuation<CGImage, Error>?
    var delay = false
    func prepare(_ region: LongScreenshotRegion) async throws {}
    func capture() async throws -> CGImage {
        calls += 1
        if delay { return try await withCheckedThrowingContinuation { pending = $0 } }
        if let failureAfter, calls > failureAfter { throw ScreenshotImageError.captureUnavailable }
        if let changingAfter, calls > changingAfter { return longPage(offset: calls * 317) }
        if offset > 0, temporaryMismatch > 0 {
            temporaryMismatch -= 1
            return longPage(offset: 10_000)
        }
        return longPage(offset: offset)
    }
    func release() { releases += 1 }
}
@MainActor private final class LongScrollStub: LongScreenshotScrolling {
    let capture: LongCaptureStub
    var events = 0
    var maximumOffset = 113
    var changed = false
    var times: [TimeInterval] = []
    init(_ capture: LongCaptureStub) { self.capture = capture }
    func resolve(_ region: LongScreenshotRegion) throws -> LongScreenshotTarget {
        LongScreenshotTarget(windowID: 1, processID: 1, frame: region.quartzRect, sourceID: "test.page", sourceName: "测试页面")
    }
    func validate(_ target: LongScreenshotTarget, region: LongScreenshotRegion) throws {
        if changed { throw LongScreenshotError.targetChanged }
    }
    func scroll(_ points: Int, target: LongScreenshotTarget, region: LongScreenshotRegion) throws {
        try validate(target, region: region)
        #expect(points <= Int(region.selection.height / 3))
        events += 1; capture.offset = min(maximumOffset, capture.offset + points)
        times.append(ProcessInfo.processInfo.systemUptime)
    }
}

@Suite("长截屏生命周期", .serialized) @MainActor struct LongScreenshotLifecycleTests {
    private var region: LongScreenshotRegion {
        LongScreenshotRegion(screen: ScreenshotScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 192, height: 240), scale: 1),
            selection: CGRect(x: 0, y: 0, width: 192, height: 240), desktopTop: 240)
    }
    private func wait(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(6))
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(3)) }
        try #require(condition())
    }
    @Test func bottomRequiresThreeProbesAndRestoresMouseConfiguration() async throws {
        let capture = LongCaptureStub()
        let driver = LongScrollStub(capture)
        let coordinator = LongScreenshotCoordinator(capture: capture, scroll: driver, settleInterval: .milliseconds(1), observesSystem: false)
        var result: LongScreenshotDocument?, done = false
        var suspension: [Bool] = []
        coordinator.onScrollSuspension = { suspension.append($0) }
        coordinator.onFinish = { document, reason, target in
            result = document; done = true
            #expect(reason == nil && target?.sourceID == "test.page")
        }
        coordinator.start(region); coordinator.start(region)
        try await wait { done }
        #expect(result?.image.height == 353)
        #expect(driver.events == 5)
        #expect(suspension == [true, false] && coordinator.phase == .idle)
        let count = driver.events
        try await Task.sleep(for: .milliseconds(15))
        #expect(driver.events == count)
    }
    @Test func continuousStreamUsesSmallStepsAndDoesNotTreatDuplicateFramesAsImmediateBottom() async throws {
        let capture = LongCaptureStub(); capture.capturesContinuously = true
        let driver = LongScrollStub(capture)
        let coordinator = LongScreenshotCoordinator(capture: capture, scroll: driver, settleInterval: .milliseconds(1), observesSystem: false)
        var result: LongScreenshotDocument?, done = false
        coordinator.onFinish = { document, reason, _ in
            result = document; done = true; #expect(reason == nil)
        }
        coordinator.start(region)
        try await wait { done }
        #expect(result?.image.height == 353)
        #expect(driver.events > 40)
        #expect(driver.times.last! - driver.times.first! > 0.8)
        let events = driver.events
        try await Task.sleep(for: .milliseconds(40))
        #expect(driver.events == events && capture.releases == 1)
    }

    @Test func continuousStreamPausesForDelayedContentAndKeepsTheLastReliableReference() async throws {
        let capture = LongCaptureStub(); capture.capturesContinuously = true; capture.temporaryMismatch = 2
        let driver = LongScrollStub(capture)
        let coordinator = LongScreenshotCoordinator(capture: capture, scroll: driver, settleInterval: .milliseconds(1), observesSystem: false)
        var done = false
        coordinator.onFinish = { document, reason, _ in
            #expect(document?.image.height == 353 && reason == nil); done = true
        }
        coordinator.start(region)
        try await wait { done }
        #expect(capture.temporaryMismatch == 0)
        #expect(zip(driver.times, driver.times.dropFirst()).contains { $1 - $0 >= 0.12 })
    }
    @Test(arguments: [false, true]) func manualStopAndWindowChangeKeepOnlyReliableContent(_ targetChanged: Bool) async throws {
        let capture = LongCaptureStub()
        let driver = LongScrollStub(capture)
        let coordinator = LongScreenshotCoordinator(capture: capture, scroll: driver, settleInterval: .milliseconds(1), observesSystem: false)
        var done = false
        coordinator.onProgress = { progress in
            if progress.height > 240 {
                if targetChanged { driver.changed = true }
                else { coordinator.stop() }
            }
        }
        coordinator.onFinish = { document, reason, _ in
            #expect(document?.image.height == 300)
            #expect((reason != nil) == targetChanged); done = true
        }
        coordinator.start(region)
        try await wait { done }
        #expect(driver.events == 1)
    }
    @Test func cancellationDiscardsLateCaptureAndRestoresSuspensionExactlyOnce() async throws {
        let capture = LongCaptureStub(); capture.delay = true
        let driver = LongScrollStub(capture)
        let coordinator = LongScreenshotCoordinator(capture: capture, scroll: driver, settleInterval: .milliseconds(1), observesSystem: false)
        var suspension: [Bool] = [], finishes = 0
        coordinator.onScrollSuspension = { suspension.append($0) }
        coordinator.onFinish = { _, _, _ in finishes += 1 }
        coordinator.start(region)
        try await wait { capture.pending != nil }
        coordinator.cancel()
        capture.pending?.resume(returning: longPage()); capture.pending = nil
        try await Task.sleep(for: .milliseconds(20))
        #expect(coordinator.phase == .idle && finishes == 0 && driver.events == 0)
        #expect(suspension == [true, false])
    }
    @Test func captureFailureKeepsFirstFrameAndTimeLimitDoesNotSendEvents() async throws {
        let capture = LongCaptureStub(); capture.failureAfter = 2
        let driver = LongScrollStub(capture)
        let coordinator = LongScreenshotCoordinator(capture: capture, scroll: driver, settleInterval: .milliseconds(1), observesSystem: false)
        var done = false
        coordinator.onFinish = { document, reason, _ in #expect(document?.image.height == 240 && reason != nil); done = true }
        coordinator.start(region); try await wait { done }
        let timed = LongScreenshotCoordinator(capture: capture, scroll: driver,
            limits: LongScreenshotLimits(maximumDuration: .zero), observesSystem: false)
        done = false
        let events = driver.events
        timed.onFinish = { document, reason, _ in #expect(document == nil && reason != nil); done = true }
        timed.start(region); try await wait { done }
        #expect(driver.events == events)
    }
    @Test func unstablePagePreservesFirstFrameAndStopsFurtherScroll() async throws {
        let capture = LongCaptureStub(); capture.changingAfter = 2
        let driver = LongScrollStub(capture)
        let coordinator = LongScreenshotCoordinator(capture: capture, scroll: driver, settleInterval: .milliseconds(1), observesSystem: false)
        var done = false
        coordinator.onFinish = { document, reason, _ in
            #expect(document?.image.height == 240 && reason == LongScreenshotError.unstable.localizedDescription); done = true
        }
        coordinator.start(region); try await wait { done }
        #expect(driver.events == 1 && capture.releases == 1)
    }
    @Test func stoppingWithPendingCaptureDiscardsLateFrameAndKeepsPriorPixels() async throws {
        let capture = LongCaptureStub(), driver: LongScrollStub
        driver = LongScrollStub(capture)
        let coordinator = LongScreenshotCoordinator(capture: capture, scroll: driver, settleInterval: .milliseconds(1), observesSystem: false)
        var done = false
        coordinator.onProgress = { _ in capture.delay = true }
        coordinator.onFinish = { document, reason, _ in #expect(document?.image.height == 240 && reason == nil); done = true }
        coordinator.start(region)
        try await wait { capture.pending != nil }
        coordinator.stop()
        capture.pending?.resume(returning: longPage(offset: 60)); capture.pending = nil
        try await wait { done }
        #expect(driver.events == 1)
    }
    @Test func scrollEventLocksProcessAndLocationAndUsesOnlyDownwardPixelDelta() throws {
        let target = LongScreenshotTarget(windowID: 123, processID: 456, frame: region.quartzRect,
            sourceID: "test", sourceName: "测试")
        let point = CGPoint(x: -300, y: 400)
        let event = try #require(LongScreenshotScrollEvent.make(amount: 45, target: target, location: point))
        #expect(event.type == .scrollWheel && event.location == point && event.flags.isEmpty)
        #expect(event.getIntegerValueField(.eventTargetUnixProcessID) == 456)
        #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -45)
        #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 0)
        #expect(event.getIntegerValueField(.scrollWheelEventIsContinuous) == 1)
        #expect(event.getIntegerValueField(.eventSourceUserData) == MouseScrollEventAdapter.marker)
        #expect(NSEvent(cgEvent: event)?.windowNumber == Int(target.windowID))
        #expect(LongScreenshotScrollEvent.make(amount: 0, target: target, location: point) == nil)
    }

    @Test func delayedContentIsRecapturedAtSamePositionBeforeSendingAnotherScroll() async throws {
        let capture = LongCaptureStub(), driver: LongScrollStub
        driver = LongScrollStub(capture)
        capture.temporaryMismatch = 2
        let coordinator = LongScreenshotCoordinator(capture: capture, scroll: driver, settleInterval: .milliseconds(1), observesSystem: false)
        var done = false
        coordinator.onFinish = { document, reason, _ in
            #expect(document?.image.height == 353 && reason == nil)
            done = true
        }
        coordinator.start(region)
        try await wait { done }
        #expect(driver.events == 5)
        #expect(capture.temporaryMismatch == 0)
    }
}

@MainActor private struct LongSelectionCapture: ScreenCapturing {
    func capture(_ screens: [ScreenshotScreen]) async throws -> [CapturedScreen] {
        screens.map { CapturedScreen(screen: $0, image: longPage(width: 800, height: 600)) }
    }
}

@Suite("长截屏编辑与输出", .serialized) @MainActor struct LongScreenshotOutputTests {
    private func wait(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(6))
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(3)) }
        try #require(condition())
    }
    private func selected(save: @escaping (Data) async throws -> Bool = { _ in false }) async throws -> (ScreenshotCoordinator, ScreenshotOverlay, LongScrollStub) {
        _ = NSApplication.shared
        let capture = LongCaptureStub(), driver: LongScrollStub
        driver = LongScrollStub(capture)
        let long = LongScreenshotCoordinator(capture: capture, scroll: driver, settleInterval: .milliseconds(1), observesSystem: false)
        let coordinator = ScreenshotCoordinator(captureService: LongSelectionCapture(), pins: PinnedScreenshotManager(presentWindow: { _ in }),
            presentWindow: { _ in }, saveImage: save, longCapture: long, presentLongWindow: { _ in }, presentLongControls: { _ in })
        coordinator.validateLongAccess = { true }
        coordinator.start(screens: [ScreenshotScreen(id: 9, frame: CGRect(x: 0, y: 0, width: 800, height: 600), scale: 1)],
            sourceID: "test.original", sourceName: "原始来源", prefersLongScreenshot: true)
        try await wait { coordinator.phase == .selecting }
        let view = try #require(coordinator.windows.first?.contentView as? ScreenshotOverlay)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: point.x, y: 600 - point.y), modifierFlags: [],
                timestamp: 0, windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 100, y: 100)))
        view.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 292, y: 340)))
        try #require(coordinator.phase == .editing)
        #expect(view.state.prefersLongScreenshot)
        return (coordinator, view, driver)
    }
    private func editing(save: @escaping (Data) async throws -> Bool = { _ in false }) async throws -> ScreenshotCoordinator {
        let (coordinator, view, _) = try await selected(save: save)
        view.state.action?(.longScreenshot)
        #expect(coordinator.isActive && coordinator.windows.isEmpty && view.window == nil)
        try await wait { coordinator.phase == .longEditing }
        return coordinator
    }
    @Test func permissionAndAnnotationsPreventCaptureAndDisablingCancelsEveryStage() async throws {
        let (locked, view, driver) = try await selected()
        defer { locked.cancel() }
        view.state.history.append(ScreenshotAnnotation(tool: .rectangle, points: [.zero, CGPoint(x: 20, y: 20)],
            color: AnnotationColor.palette[0], width: 3))
        view.state.action?(.longScreenshot)
        #expect(locked.phase == .editing && driver.events == 0)
        view.state.history = AnnotationHistory()
        var errors = 0
        locked.onError = { _ in errors += 1 }
        locked.validateLongAccess = { false }
        view.state.action?(.longScreenshot)
        #expect(locked.phase == .idle && driver.events == 0 && errors == 1)
        let editor = try await editing()
        editor.isEnabled = false
        #expect(editor.phase == .idle && editor.longEditor == nil)
        editor.start(screens: [], sourceID: "test", sourceName: "测试")
        #expect(editor.phase == .idle)
    }
    @Test func saveCancellationAndFailurePreserveEditorWithoutCopying() async throws {
        for fail in [false, true] {
            var saved = 0, copies = 0
            let coordinator = try await editing(save: { _ in
                saved += 1
                if fail { throw CocoaError(.fileWriteNoPermission) }
                return false
            })
            defer { coordinator.cancel() }
            coordinator.onCopy = { _, _, _ in copies += 1; return true }
            let editor = try #require(coordinator.longEditor)
            editor.state.history.append(ScreenshotAnnotation(tool: .pen, points: [CGPoint(x: 10, y: 320), CGPoint(x: 80, y: 340)],
                color: AnnotationColor.palette[2], width: 3))
            coordinator.finishLongScreenshot(.save)
            #expect(coordinator.phase == .exporting && coordinator.isActive)
            try await wait { coordinator.phase != .exporting }
            #expect(coordinator.phase == .longEditing && !editor.state.busy && saved == 1 && copies == 0)
            #expect(editor.state.history.annotations.count == 1 && (editor.state.error != nil) == fail)
        }
    }
    @Test func failedCopyCanRetryAndSuccessfulCopyUsesActualTargetAndOriginalPixels() async throws {
        let coordinator = try await editing()
        defer { coordinator.cancel() }
        let editor = try #require(coordinator.longEditor)
        coordinator.onCopy = { _, _, _ in false }
        coordinator.finishLongScreenshot(.copy)
        try await wait { coordinator.phase != .exporting }
        #expect(coordinator.phase == .longEditing && editor.state.error != nil)
        var result: ScreenshotImage?
        coordinator.onCopy = { image, id, name in
            #expect(id == "test.page" && name == "测试页面")
            result = image; return true
        }
        coordinator.finishLongScreenshot(.copy)
        try await wait { coordinator.phase != .exporting }
        #expect(coordinator.phase == .idle && coordinator.longEditor == nil)
        #expect(result?.image.height == 353 && result?.image.width == 192)
        #expect(result?.png == (try ScreenshotRenderer.encode(longPage(height: 353))))
    }
    @Test func pinDoesNotCopyAndOutlivesTheEditor() async throws {
        let coordinator = try await editing()
        defer { coordinator.cancel(); coordinator.pins.closeAll() }
        var copies = 0
        coordinator.onCopy = { _, _, _ in copies += 1; return true }
        coordinator.finishLongScreenshot(.pin)
        try await wait { coordinator.phase != .exporting }
        #expect(coordinator.phase == .idle && coordinator.pins.count == 1 && copies == 0)
    }
    @Test func lateSaveAfterModuleDisableDoesNotRestoreEditor() async throws {
        var continuation: CheckedContinuation<Bool, Never>?
        let coordinator = try await editing(save: { _ in await withCheckedContinuation { continuation = $0 } })
        coordinator.finishLongScreenshot(.save)
        try await wait { continuation != nil }
        coordinator.isEnabled = false; coordinator.isEnabled = true
        continuation?.resume(returning: false)
        try await Task.sleep(for: .milliseconds(20))
        #expect(coordinator.phase == .idle && coordinator.longEditor == nil)
    }
    @Test func closingEditorReleasesMappedPixelsPreviewTasksAndTemporaryDirectory() async throws {
        let coordinator = try await editing()
        weak let document = coordinator.longEditor?.document
        let directory = try #require(document?.directory)
        coordinator.cancel()
        try await wait { document == nil }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
    @Test func zoomScrollAndTextKeepLogicalCoordinatesAndUndoHistory() async throws {
        let coordinator = try await editing()
        defer { coordinator.cancel() }
        let editor = try #require(coordinator.longEditor)
        let point = CGPoint(x: 31, y: 310)
        editor.canvas.zoom = 0.4
        #expect(editor.canvas.logicalPoint(CGPoint(x: point.x * 0.4, y: point.y * 0.4)) == point)
        editor.canvas.zoom = 1
        editor.state.action?(.tool(.text))
        let location = editor.canvas.convert(point, to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: editor.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        editor.canvas.mouseDown(with: event)
        let text = try #require(editor.canvas.subviews.compactMap { $0 as? NSTextView }.first)
        text.string = "长图底部文字"
        editor.setZoom(fit: true)
        #expect(editor.state.history.annotations.last?.points.first == point)
        #expect(editor.state.history.annotations.last?.text == "长图底部文字")
        editor.state.action?(.undo); #expect(editor.state.history.annotations.isEmpty)
        editor.state.action?(.redo); #expect(editor.state.history.annotations.count == 1)
    }

    @Test func previewCentersNarrowAndShortImagesAfterResizingAndZoomChanges() async throws {
        let coordinator = try await editing()
        defer { coordinator.cancel() }
        let editor = try #require(coordinator.longEditor)
        func expectCentered() throws {
            let viewport = editor.scrollView.contentSize
            let frame = editor.canvas.frame
            #expect(abs(frame.midX - viewport.width / 2) < 1, "窄图左右留白须相等")
            if frame.height + 48 <= viewport.height {
                #expect(abs(frame.midY - viewport.height / 2) < 1, "短图上下留白须相等")
            }
            #expect(editor.scrollView.contentView.bounds.origin == .zero)
        }
        try expectCentered()
        editor.window.setContentSize(CGSize(width: 1100, height: 820))
        editor.windowDidResize(Notification(name: NSWindow.didResizeNotification))
        try expectCentered()
        editor.setZoom(fit: false); try expectCentered()
        editor.setZoom(fit: true); try expectCentered()
        let logical = CGPoint(x: 41, y: 121)
        let location = editor.canvas.convert(CGPoint(x: logical.x * editor.zoom, y: logical.y * editor.zoom), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
            timestamp: 0, windowNumber: editor.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        editor.state.action?(.tool(.text))
        editor.canvas.mouseDown(with: event)
        let text = try #require(editor.canvas.subviews.compactMap { $0 as? NSTextView }.first)
        text.string = "居中后坐标仍正确"
        editor.canvas.commitText()
        #expect(editor.state.history.annotations.last?.points.first == logical)
    }

    @Test func longPreviewStaysCenteredAndZoomKeepsTheVisibleDocumentPosition() async throws {
        let stitcher = LongScreenshotStitcher(scale: 1)
        _ = try await stitcher.append(longPage(width: 1200, height: 2400))
        let document = try #require(try await stitcher.finish())
        let editor = LongScreenshotEditor(document: document, notice: nil)
        defer { editor.close() }
        let viewport = editor.scrollView.contentSize
        #expect(abs(editor.canvas.frame.midX - viewport.width / 2) < 1)
        #expect(editor.canvas.frame.minY == 24)
        #expect(editor.canvas.frame.height > viewport.height && editor.scrollView.contentView.bounds.origin.y == 0)
        editor.scrollView.contentView.scroll(to: CGPoint(x: 0, y: 440))
        editor.scrollView.reflectScrolledClipView(editor.scrollView.contentView)
        let oldPosition = (editor.scrollView.contentView.bounds.minY - editor.canvas.frame.minY) / editor.zoom
        editor.setZoom(fit: false)
        let actualPosition = (editor.scrollView.contentView.bounds.minY - editor.canvas.frame.minY) / editor.zoom
        #expect(abs(oldPosition - actualPosition) < 1)
        let container = try #require(editor.canvas.superview)
        #expect(abs(editor.canvas.frame.midX - container.bounds.midX) < 1)
        #expect(editor.canvas.frame.width > editor.scrollView.contentSize.width)
        editor.setZoom(fit: true)
        #expect(abs(editor.canvas.frame.midX - editor.scrollView.contentSize.width / 2) < 1)
    }

    @Test func currentResultCanBeReopenedWithoutStartingAnotherCaptureOrDiscardingAnnotations() async throws {
        let coordinator = try await editing()
        defer { coordinator.cancel() }
        let editor = try #require(coordinator.longEditor)
        #expect(editor.window.level == .floating && !editor.window.hidesOnDeactivate)
        editor.state.history.append(ScreenshotAnnotation(tool: .rectangle, points: [.zero, CGPoint(x: 20, y: 20)],
            color: AnnotationColor.palette[0], width: 2))
        coordinator.showLongScreenshotEditor()
        #expect(coordinator.longEditor === editor && coordinator.phase == .longEditing)
        #expect(editor.state.history.annotations.count == 1)
    }

    @Test func statusMenuOffersCurrentEditorWhileRejectingNewCapturesAndRecordings() async throws {
        let coordinator = try await editing()
        defer { coordinator.cancel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "LongScreenshotMenu." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults)
        settings.screenshotEnabled = true; settings.screenRecordingEnabled = true
        let model = AppModel(repository: try HistoryStore(directory: root), settings: settings,
            permissions: PermissionService(), hotKeys: HotKeyService())
        defer { model.cancelRefresh() }
        let delegate = AppDelegate(screenshots: coordinator)
        let menu = delegate.makeStatusMenu(for: model)
        for action in ["startScreenshot", "startLongScreenshot", "startFullScreenRecording", "startRegionRecording"] {
            let item = try #require(menu.items.first { $0.action == NSSelectorFromString(action) })
            #expect(!item.isEnabled)
        }
        let resume = try #require(menu.items.first { $0.action == NSSelectorFromString("showLongScreenshotEditor") })
        #expect(resume.isEnabled)
        #expect(NSApp.sendAction(try #require(resume.action), to: resume.target, from: resume))
        #expect(coordinator.phase == .longEditing && coordinator.longEditor != nil)
    }
}

@Suite("长截屏界面外观", .serialized, .enabled(if: ProcessInfo.processInfo.environment["EASYMACOS_LONG_UI"] == "1"))
@MainActor struct LongScreenshotAppearanceTests {
    @Test func chineseEnglishAndLightDarkEditorsKeepFixedToolbarAndScrollableCanvas() async throws {
        _ = NSApplication.shared
        let language = L.language
        let preference = UserDefaults.standard.object(forKey: InterfaceLocalization.defaultsKey)
        defer {
            InterfaceLocalization.shared.setLanguage(language)
            if let preference { UserDefaults.standard.set(preference, forKey: InterfaceLocalization.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: InterfaceLocalization.defaultsKey) }
        }
        let sample = try #require(CGContext(data: nil, width: 560, height: 3200, bitsPerComponent: 8,
            bytesPerRow: 560 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        sample.translateBy(x: 0, y: 3200); sample.scaleBy(x: 1, y: -1)
        for row in 0..<40 {
            sample.setFillColor(CGColor(gray: row.isMultiple(of: 2) ? 1 : 0.95, alpha: 1))
            sample.fill(CGRect(x: 0, y: row * 80, width: 560, height: 80))
            ScreenshotRenderer.draw(ScreenshotAnnotation(tool: .text, points: [CGPoint(x: 30, y: row * 80 + 24)],
                color: AnnotationColor(red: 0.18, green: 0.22, blue: 0.28), width: 3,
                text: "第 \(row + 1) 段 · 居中预览与原始像素"), in: sample)
        }
        let stitcher = LongScreenshotStitcher(scale: 1)
        _ = try await stitcher.append(try #require(sample.makeImage()))
        let document = try #require(try await stitcher.finish())
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EASYMACOS_LONG_OUTPUT"] ?? "/tmp/easymacos-long-ui")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for chinese in [true, false] {
            InterfaceLocalization.shared.setLanguage(chinese ? .simplifiedChinese : .english)
            for dark in [false, true] {
                let editor = LongScreenshotEditor(document: document, notice: LongScreenshotError.capacity.localizedDescription)
                editor.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                editor.state.optionsExpanded = true
                editor.refresh(); editor.show()
                try await Task.sleep(for: .milliseconds(300))
                let scrollFrame = editor.scrollView.frame
                editor.scrollView.contentView.scroll(to: CGPoint(x: 0, y: 1500))
                editor.scrollView.reflectScrolledClipView(editor.scrollView.contentView)
                editor.canvas.requestVisibleTiles()
                try await Task.sleep(for: .milliseconds(200))
                #expect(editor.scrollView.frame == scrollFrame)
                #expect(editor.canvas.frame.height > editor.scrollView.frame.height)
                #expect(editor.state.tool == .rectangle && editor.state.isLongEditor)
                #expect(editor.window.title == (chinese ? "长截屏" : "Scrolling screenshot"))
                let view = try #require(editor.window.contentView)
                view.layoutSubtreeIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: root.appendingPathComponent("editor-\(chinese ? "zh" : "en")-\(dark ? "dark" : "light").png"))
                editor.close()
            }
        }
    }
}
