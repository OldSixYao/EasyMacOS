import AppKit
import Testing
@testable import PasteMan

@MainActor private final class StalledLongCapture: LongScreenshotCapturing {
    var capturesContinuously = false
    let image: CGImage
    var suspendPreparation = false
    var preparation: CheckedContinuation<Void, Error>?
    var capture: CheckedContinuation<CGImage, Error>?
    var firstFrameOnly = false
    var calls = 0
    var releases = 0

    init() throws {
        let context = try #require(CGContext(data: nil, width: 192, height: 240, bitsPerComponent: 8,
            bytesPerRow: 192 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        image = try #require(context.makeImage())
    }
    func prepare(_ region: LongScreenshotRegion) async throws {
        if suspendPreparation { try await withCheckedThrowingContinuation { preparation = $0 } }
    }
    func capture() async throws -> CGImage {
        calls += 1
        if firstFrameOnly && calls <= 2 { return image }
        return try await withCheckedThrowingContinuation { capture = $0 }
    }
    func release() { releases += 1 }
}

@MainActor private final class StalledLongScroll: LongScreenshotScrolling {
    var events = 0
    func resolve(_ region: LongScreenshotRegion) throws -> LongScreenshotTarget {
        LongScreenshotTarget(windowID: 1, processID: 1, frame: region.quartzRect, sourceID: "test.stalled", sourceName: "合成等待")
    }
    func validate(_ target: LongScreenshotTarget, region: LongScreenshotRegion) throws {}
    func scroll(_ points: Int, target: LongScreenshotTarget, region: LongScreenshotRegion) throws { events += 1 }
}

@Suite("长截屏等待与停止响应", .serialized) @MainActor struct LongScreenshotOperationTests {
    private var region: LongScreenshotRegion {
        LongScreenshotRegion(screen: ScreenshotScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 192, height: 240), scale: 1),
            selection: CGRect(x: 0, y: 0, width: 192, height: 240), desktopTop: 240)
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(condition())
    }

    @Test(arguments: [false, true]) func systemRequestTimesOutBeforeAnUncooperativeCallbackReturns(_ preparing: Bool) async throws {
        let capture = try StalledLongCapture(), scroll = StalledLongScroll()
        capture.suspendPreparation = preparing
        let coordinator = LongScreenshotCoordinator(capture: capture, scroll: scroll, settleInterval: .milliseconds(1),
            observesSystem: false, captureTimeout: .milliseconds(30))
        var finishes = 0
        var suspension: [Bool] = []
        coordinator.onScrollSuspension = { suspension.append($0) }
        coordinator.onFinish = { document, reason, _ in
            #expect(document == nil && reason == LongScreenshotError.captureTimedOut.localizedDescription)
            finishes += 1
        }
        coordinator.start(region)
        try await wait { finishes == 1 }
        #expect(coordinator.phase == .idle && scroll.events == 0 && suspension == [true, false])
        #expect(capture.releases == 1)
        if preparing { try #require(capture.preparation).resume(); capture.preparation = nil }
        else { try #require(capture.capture).resume(returning: capture.image); capture.capture = nil }
        try await Task.sleep(for: .milliseconds(15))
        #expect(finishes == 1 && coordinator.phase == .idle)
    }

    @Test(arguments: [false, true]) func stopDuringStalledFrameImmediatelyDeliversPreviousImageAndIgnoresLateFrame(_ continuous: Bool) async throws {
        let capture = try StalledLongCapture(), scroll = StalledLongScroll()
        capture.firstFrameOnly = true
        capture.capturesContinuously = continuous
        let coordinator = LongScreenshotCoordinator(capture: capture, scroll: scroll, settleInterval: .milliseconds(1),
            observesSystem: false, captureTimeout: .seconds(5))
        var finishes = 0
        coordinator.onFinish = { document, reason, _ in
            #expect(document?.image.height == 240 && reason == nil)
            finishes += 1
        }
        coordinator.start(region)
        try await wait { capture.capture != nil }
        let events = scroll.events
        #expect(continuous ? events > 0 : events == 1)
        coordinator.stop()
        try await wait { finishes == 1 }
        // 回调仍未返回时，编辑结果已就绪，不能继续等待系统调用结束。
        #expect(capture.capture != nil && coordinator.phase == .idle && scroll.events == events)
        try #require(capture.capture).resume(returning: capture.image); capture.capture = nil
        try await Task.sleep(for: .milliseconds(15))
        #expect(finishes == 1 && scroll.events == events)
    }

    @Test func cancelledPendingOperationDoesNotHoldItsCallerOrReturnALateValue() async throws {
        var callback: CheckedContinuation<Int, Error>?
        var returned = false
        let task = Task {
            do {
                _ = try await LongScreenshotOperation.run(timeout: .seconds(5)) {
                    try await withCheckedThrowingContinuation { callback = $0 }
                }
                Issue.record("取消后不应返回正常结果")
            } catch is CancellationError { returned = true }
            catch { Issue.record("取消错误类型不正确") }
        }
        try await wait { callback != nil }
        task.cancel()
        try await wait { returned }
        try #require(callback).resume(returning: 42); callback = nil
        await task.value
    }

    @Test func timeoutAfterFirstFrameKeepsEditableContentAndRestoresMouseScroll() async throws {
        let capture = try StalledLongCapture(), scroll = StalledLongScroll()
        capture.firstFrameOnly = true
        let coordinator = LongScreenshotCoordinator(capture: capture, scroll: scroll, settleInterval: .milliseconds(1),
            observesSystem: false, captureTimeout: .milliseconds(30))
        var done = false
        var suspension: [Bool] = []
        coordinator.onScrollSuspension = { suspension.append($0) }
        coordinator.onFinish = { document, reason, _ in
            #expect(document?.image.height == 240 && reason == LongScreenshotError.captureTimedOut.localizedDescription)
            done = true
        }
        coordinator.start(region)
        try await wait { done }
        #expect(scroll.events == 1 && suspension == [true, false])
        try #require(capture.capture).resume(throwing: ScreenshotImageError.captureUnavailable); capture.capture = nil
    }
}
