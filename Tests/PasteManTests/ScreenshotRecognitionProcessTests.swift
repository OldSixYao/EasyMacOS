import AppKit
import Darwin
import Testing

@testable import PasteMan

@Suite("识别辅助进程生命周期", .serialized) struct ScreenshotRecognitionProcessTests {
    @Test func stripedInputPreservesEveryRowAndTransparency() async throws {
        let context = try #require(CGContext(data: nil, width: 80, height: 641, bitsPerComponent: 8,
            bytesPerRow: 320, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for row in 0..<641 {
            context.setFillColor(CGColor(red: CGFloat(row % 7) / 6, green: CGFloat(row % 5) / 4,
                blue: CGFloat(row % 3) / 2, alpha: row.isMultiple(of: 11) ? 0.5 : 1))
            context.fill(CGRect(x: 0, y: row, width: 80, height: 1))
        }
        let image = try #require(context.makeImage())
        let size = CGSize(width: 40, height: 320.5)
        let complete = try PinnedImageStorage(image: image, pointSize: size)
        let striped = try await PinnedImageWorker.shared.archiveForRecognition(base: image, pointSize: size)
        let expected = try await complete.png(), actual = try await striped.png()
        #expect(actual == expected)
        #expect(striped.pointSize == size)
    }

    @Test func helperRendersTextAnnotationsAndExitsAfterReturningResult() async throws {
        let image = try input()
        guard case .image(let base, let size, _) = image else { return }
        let annotation = ScreenshotAnnotation(tool: .text, points: [CGPoint(x: 4, y: 8)],
            color: AnnotationColor.palette[5], width: 2, text: "Hello 123",
            textStyle: AnnotationTextStyle(fontFamily: "Helvetica", fontSize: 12))
        let worker: ScreenshotRecognitionProcess
        if let path = ProcessInfo.processInfo.environment["EASYMACOS_RECOGNITION_EXECUTABLE"] {
            worker = ScreenshotRecognitionProcess(executableURL: URL(fileURLWithPath: path))
        } else { worker = .shared }
        let result = try await worker.recognize(.image(base, pointSize: size, annotations: [annotation]),
            kind: .text, progress: { _ in })
        #expect(result.contains("Hello 123"))
        #expect(worker.processIdentifier == nil)
    }

    private func input() throws -> ScreenshotTextInput {
        let context = try #require(CGContext(data: nil, width: 80, height: 80, bitsPerComponent: 8,
            bytesPerRow: 320, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        return .image(try #require(context.makeImage()), pointSize: CGSize(width: 80, height: 80), annotations: [])
    }

    @Test func cancellingTerminatesActiveHelperAndDoesNotLaunchQueuedRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("helper")
        try Data("#!/bin/sh\nexec /bin/sleep 10\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let requests = directory.appendingPathComponent("requests")
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        let worker = ScreenshotRecognitionProcess(executableURL: script, temporaryDirectory: requests)
        let image = try input()
        let active = Task { try await worker.recognize(image, kind: .text, progress: { _ in }) }
        defer { active.cancel() }
        let deadline = ContinuousClock.now + .seconds(3)
        while worker.processIdentifier == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let pid = try #require(worker.processIdentifier)
        let queued = Task { try await worker.recognize(image, kind: .barcodes, progress: { _ in }) }
        defer { queued.cancel() }
        // 两个私有请求目录说明后一个请求已准备完成，正在串行队列中等候。
        while try FileManager.default.contentsOfDirectory(atPath: requests.path).count < 2,
            ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: requests.path).count == 2)
        #expect(worker.processIdentifier == pid)
        queued.cancel()
        active.cancel()
        await #expect(throws: CancellationError.self) { try await active.value }
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(worker.processIdentifier == nil)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(try FileManager.default.contentsOfDirectory(atPath: requests.path).isEmpty)
    }

    @Test func failedHelperCleansRequestAndAllowsRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = ScreenshotRecognitionProcess(executableURL: URL(fileURLWithPath: "/usr/bin/false"), temporaryDirectory: directory)
        let image = try input()
        for _ in 0..<2 {
            await #expect(throws: ScreenshotRecognitionProcessError.self) {
                try await worker.recognize(image, kind: .text, progress: { _ in })
            }
            #expect(worker.processIdentifier == nil)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }

    @Test func missingExecutableAndPreCancelledRequestDoNotCreateFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let worker = ScreenshotRecognitionProcess(executableURL: directory.appendingPathComponent("missing"), temporaryDirectory: directory)
        let image = try input()
        await #expect(throws: ScreenshotRecognitionProcessError.self) {
            try await worker.recognize(image, kind: .text, progress: { _ in })
        }
        let task = Task {
            try Task.checkCancellation()
            return try await worker.recognize(image, kind: .text, progress: { _ in })
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
