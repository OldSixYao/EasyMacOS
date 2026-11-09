import AppKit
import ScreenCaptureKit
import Testing
@testable import PasteMan

@Suite("连续长截屏缓存与滚动", .serialized) @MainActor struct LongScreenshotStreamTests {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }
    private func image() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 96, height: 120, bitsPerComponent: 8,
            bytesPerRow: 96 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }

    @Test func mailboxKeepsOnlyTheLatestFrameAndRejectsCallbacksAfterClosure() throws {
        let mailbox = LongScreenshotFrameMailbox(), image = try image()
        #expect(try mailbox.read() == nil)
        for index in 0..<1000 { mailbox.publish(image, at: Double(index)) }
        let latest = try #require(try mailbox.read())
        #expect(latest.sequence == 1000 && latest.time == 999 && latest.image === image)
        mailbox.fail(LongScreenshotError.captureTimedOut)
        #expect(throws: (any Error).self) { try mailbox.read() }
        mailbox.close(); mailbox.publish(image, at: 1001)
        #expect(throws: CancellationError.self) { try mailbox.read() }
    }

    @Test func streamPreservesRetinaPixelsAndExcludesCursorAndAudio() {
        let region = LongScreenshotRegion(screen: ScreenshotScreen(id: 1,
            frame: CGRect(x: -1440, y: -180, width: 1440, height: 900), scale: 2),
            selection: CGRect(x: 20.25, y: 30.25, width: 400, height: 300), desktopTop: 1080)
        let configuration = SystemLongScreenshotCapture.configuration(region)
        #expect(configuration.width == 801 && configuration.height == 601)
        #expect(configuration.sourceRect == CGRect(x: 20, y: 30, width: 400.5, height: 300.5))
        #expect(configuration.minimumFrameInterval == CMTime(value: 1, timescale: 30))
        #expect(configuration.queueDepth == 3 && !configuration.showsCursor && !configuration.capturesAudio)
    }

    @Test func screenBufferIsCopiedWithoutColorRoundingAndSurvivesSystemBufferReuse() throws {
        var buffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, 96, 120, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let address = try #require(CVPixelBufferGetBaseAddress(pixels))
        let row = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<120 {
            for x in 0..<96 {
                let pixel = address.advanced(by: y * row + x * 4).assumingMemoryBound(to: UInt8.self)
                pixel[0] = 185; pixel[1] = 212; pixel[2] = 44; pixel[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let copied = try #require(LongScreenshotStreamImage.copy(pixels))
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(address, 0, row * 120)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let normalized = try ScreenshotRenderer.render(base: copied, pointSize: CGSize(width: 96, height: 120), annotations: [])
        let data = try #require(normalized.dataProvider?.data as Data?)
        for y in 0..<120 {
            let start = y * normalized.bytesPerRow + 32 * 4
            #expect(Array(data[start..<(start + 4)]) == [44, 212, 185, 255])
        }
    }

    @Test func slowMatchingCannotScrollBeyondTheUnconfirmedOverlapBudget() async throws {
        var events: [Int] = []
        let pump = LongScreenshotScrollPump(viewportHeight: 240) { events.append($0) }
        pump.start()
        defer { pump.stop() }
        try await wait { pump.pendingPoints == pump.maximumPendingPoints }
        #expect(events.count > 10 && events.allSatisfy { $0 <= 3 })
        #expect(CGFloat(events.reduce(0, +)) <= pump.maximumPendingPoints)
        let saturated = events.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(events.count == saturated)
        pump.paused = true; pump.acknowledge(40)
        try await Task.sleep(for: .milliseconds(80))
        #expect(events.count == saturated)
        pump.paused = false
        try await wait { events.count > saturated }
        #expect(events.count > saturated)
        pump.stop()
        let stopped = events.count
        try await Task.sleep(for: .milliseconds(50))
        #expect(events.count == stopped)
    }

    @Test func validationFailureImmediatelyStopsFurtherScroll() async throws {
        var events = 0
        let pump = LongScreenshotScrollPump(viewportHeight: 600) { _ in
            events += 1
            if events == 3 { throw LongScreenshotTargetError.applicationChanged }
        }
        pump.start()
        defer { pump.stop() }
        try await wait { pump.failure != nil }
        #expect(pump.failure != nil && events == 3)
        try await Task.sleep(for: .milliseconds(60))
        #expect(events == 3)
        pump.stop()
    }
}
