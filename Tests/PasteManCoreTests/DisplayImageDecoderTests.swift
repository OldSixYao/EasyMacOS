import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import PasteManCore

@Suite("Bounded display images") struct DisplayImageDecoderTests {
    @Test func largePreviewUsesDisplayPixelsAndPreservesSource() throws {
        let data = try imageData(width: 3000, height: 2000)
        let original = data
        let image = try ImageProcessor.decodeForDisplay(data, maximumPixelSize: 800)
        #expect(image.width == 800)
        #expect(image.height <= 534)
        #expect(image.bytesPerRow * image.height < 2 * 1024 * 1024)
        #expect(image.alphaInfo != .none && image.alphaInfo != .noneSkipLast && image.alphaInfo != .noneSkipFirst)
        #expect(data == original)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 3000)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 2000)
        let thumb = try ImageProcessor.decodeForDisplay(data, maximumPixelSize: 80)
        #expect(max(thumb.width, thumb.height) == 80)
    }

    @Test func smallImageIsNotUpscaledAndInvalidDataRejected() throws {
        let image = try ImageProcessor.decodeForDisplay(imageData(width: 16, height: 8), maximumPixelSize: 800)
        #expect(image.width == 16 && image.height == 8)
        #expect(throws: StoreError.self) {
            try ImageProcessor.decodeForDisplay(Data([0, 1]), maximumPixelSize: 800)
        }
        #expect(throws: StoreError.self) {
            try ImageProcessor.decodeForDisplay(Data(), maximumPixelSize: 0)
        }
    }

    @Test func concurrentRequestsNeverDecodeTogether() async throws {
        let stats = Mutex((active: 0, peak: 0, calls: 0))
        let decoder = DisplayImageDecoder { data, size in
            stats.withLock { value in
                value.active += 1
                value.peak = max(value.peak, value.active)
                value.calls += 1
            }
            defer { stats.withLock { $0.active -= 1 } }
            Thread.sleep(forTimeInterval: 0.01)
            return try ImageProcessor.decodeForDisplay(data, maximumPixelSize: size)
        }
        let data = try imageData(width: 64, height: 32)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask { _ = try await decoder.decode(data, maximumPixelSize: 32) }
            }
            try await group.waitForAll()
        }
        #expect(stats.withLock { $0.peak } == 1)
        #expect(stats.withLock { $0.calls } == 12)
        #expect(stats.withLock { $0.active } == 0)
    }

    @Test func canceledQueuedPreviewDoesNotStartDecoding() async throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let calls = Mutex(0)
        let decoder = DisplayImageDecoder { data, size in
            let call = calls.withLock { value in
                value += 1
                return value
            }
            if call == 1 {
                started.signal()
                _ = release.wait(timeout: .now() + 5)
            }
            return try ImageProcessor.decodeForDisplay(data, maximumPixelSize: size)
        }
        let data = try imageData(width: 16, height: 8)
        let first = Task { try await decoder.decode(data, maximumPixelSize: 16) }
        let began = await waitForSignal(started)
        #expect(began)
        let queued = Task { try await decoder.decode(data, maximumPixelSize: 16) }
        queued.cancel()
        release.signal()
        _ = try await first.value
        await #expect(throws: CancellationError.self) { _ = try await queued.value }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func cancellationDuringDecodeDiscardsTheResult() async throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let decoder = DisplayImageDecoder { data, size in
            let image = try ImageProcessor.decodeForDisplay(data, maximumPixelSize: size)
            started.signal()
            _ = release.wait(timeout: .now() + 5)
            return image
        }
        let data = try imageData(width: 16, height: 8)
        let request = Task { try await decoder.decode(data, maximumPixelSize: 16) }
        let began = await waitForSignal(started)
        #expect(began)
        request.cancel()
        release.signal()
        await #expect(throws: CancellationError.self) { _ = try await request.value }
    }
}

private func imageData(width: Int, height: Int) throws -> Data {
    let context = try #require(
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 0.5))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
    return data as Data
}

private func waitForSignal(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + 5) == .success)
        }
    }
}
