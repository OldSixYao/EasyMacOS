import AppKit
import ScreenCaptureKit
import os

/// 只保留最新一帧，不让采集队列积压。静止画面可复用最近的完整帧。
final class LongScreenshotFrameMailbox: Sendable {
    struct Frame: Sendable {
        let image: CGImage
        let time: TimeInterval
        let sequence: Int
    }
    private struct State {
        var latest: Frame?
        var nextSequence = 0
        var closed = false
        var failure: Error?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func publish(_ image: CGImage, at time: TimeInterval) {
        state.withLock {
            guard !$0.closed else { return }
            $0.nextSequence += 1
            $0.latest = Frame(image: image, time: time, sequence: $0.nextSequence)
        }
    }
    func read() throws -> Frame? {
        try state.withLock {
            if let failure = $0.failure { throw failure }
            if $0.closed { throw CancellationError() }
            return $0.latest
        }
    }
    func fail(_ error: Error) { state.withLock { if !$0.closed { $0.failure = error } } }
    func close() { state.withLock { $0.closed = true; $0.latest = nil; $0.failure = nil } }
}

enum LongScreenshotStreamImage {
    static func copy(_ pixels: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
            CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let row = CVPixelBufferGetBytesPerRow(pixels)
        guard let address = CVPixelBufferGetBaseAddress(pixels),
            let provider = CGDataProvider(data: Data(bytes: address, count: row * height) as CFData) else { return nil }
        // 拷出系统表面后立即归还，避免持有屏幕流缓冲；已为标准红绿蓝，不再经浮点颜色转换。
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: row,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

private final class LongScreenshotStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let mailbox = LongScreenshotFrameMailbox()

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
            let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        autoreleasepool {
            if let image = LongScreenshotStreamImage.copy(pixels) {
                mailbox.publish(image, at: ProcessInfo.processInfo.systemUptime)
            }
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { mailbox.fail(error) }
}

/// 整次长截屏只建立一个屏幕流，避免每帧建立单张截图事务。
@MainActor final class SystemLongScreenshotCapture: LongScreenshotCapturing {
    let capturesContinuously = true
    private var stream: SCStream?
    private var output: LongScreenshotStreamOutput?
    private let queue = DispatchQueue(label: "app.easymacos.long-screenshot.frames", qos: .userInitiated)
    private var generation = 0

    static func configuration(_ region: LongScreenshotRegion) -> SCStreamConfiguration {
        let pixels = region.pixelRect
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(x: pixels.minX / region.screen.scale, y: pixels.minY / region.screen.scale,
            width: pixels.width / region.screen.scale, height: pixels.height / region.screen.scale)
        configuration.width = Int(pixels.width); configuration.height = Int(pixels.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.captureDynamicRange = .SDR
        return configuration
    }

    func prepare(_ region: LongScreenshotRegion) async throws {
        release()
        let version = generation
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard generation == version else { throw CancellationError() }
        guard let display = content.displays.first(where: { $0.displayID == region.screen.id }) else {
            throw ScreenshotImageError.captureUnavailable
        }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let output = LongScreenshotStreamOutput()
        let stream = SCStream(filter: filter, configuration: Self.configuration(region), delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
        self.output = output; self.stream = stream
        do {
            try await stream.startCapture()
            try Task.checkCancellation()
            guard generation == version else { throw CancellationError() }
            _ = try await capture()
        } catch {
            output.mailbox.close()
            try? await stream.stopCapture()
            if generation == version { self.output = nil; self.stream = nil }
            throw error
        }
    }

    func capture() async throws -> CGImage {
        let version = generation
        guard CGPreflightScreenCaptureAccess(), let output else { throw LongScreenshotError.permission }
        while true {
            try Task.checkCancellation()
            guard version == generation else { throw CancellationError() }
            if let frame = try output.mailbox.read() { return frame.image }
            try await Task.sleep(for: .milliseconds(8))
        }
    }

    func release() {
        generation += 1
        output?.mailbox.close()
        let stream = stream
        self.stream = nil; output = nil
        if let stream { Task { try? await stream.stopCapture() } }
    }
}
