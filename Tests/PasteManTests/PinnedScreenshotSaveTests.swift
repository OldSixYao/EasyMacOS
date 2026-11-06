import AppKit
import Testing

@testable import PasteMan

@Suite("钉图保存生命周期", .serialized) @MainActor struct PinnedScreenshotSaveTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        // 图片准备在独立队列执行；固定次数 Task.yield 不能保证该队列已完成。
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }

    private func image() throws -> ScreenshotImage {
        let context = try #require(CGContext(
            data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        return try ScreenshotRenderer.export(
            base: #require(context.makeImage()), pointSize: CGSize(width: 40, height: 30), annotations: [])
    }

    private func save(_ window: NSWindow) throws {
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        let item = try #require(window.contentView?.menu(for: event)?.items.first { $0.action == NSSelectorFromString("saveImage") })
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
    }

    @Test func repeatedSaveWhilePendingStartsOnlyOneOperationThenAllowsRetry() async throws {
        _ = NSApplication.shared
        var calls = 0
        var completions = 0
        var continuation: CheckedContinuation<Bool, any Error>?
        let pins = PinnedScreenshotManager(presentWindow: { _ in }, saveImage: { _ in
            calls += 1
            let result: Bool = try await withCheckedThrowingContinuation { continuation = $0 }
            completions += 1
            return result
        })
        defer { pins.closeAll() }
        pins.show(try image(), sourceID: "test", sourceName: "测试", origin: .zero)
        let window = try #require(pins.windows.first)
        try save(window)
        try save(window)
        try await waitUntil { calls == 1 }
        #expect(calls == 1)
        continuation?.resume(returning: false)
        try await waitUntil { completions == 1 }
        try save(window)
        try await waitUntil { calls == 2 }
        #expect(calls == 2)
        continuation?.resume(returning: true)
        try await waitUntil { completions == 2 }
    }

    @Test(arguments: [false, true]) func closingCancelsSaveReleasesViewAndSuppressesLateError(_ closeAll: Bool) async throws {
        _ = NSApplication.shared
        var continuation: CheckedContinuation<Bool, any Error>?
        var cancelled = false
        var errors: [String] = []
        let pins = PinnedScreenshotManager(presentWindow: { _ in }, saveImage: { _ in
            do {
                let result: Bool = try await withCheckedThrowingContinuation { continuation = $0 }
                cancelled = Task.isCancelled
                return result
            } catch {
                cancelled = Task.isCancelled
                throw error
            }
        }, reportError: { errors.append($0) })
        pins.show(try image(), sourceID: "test", sourceName: "测试", origin: .zero)
        let window = try #require(pins.windows.first)
        weak let view = window.contentView
        try save(window)
        try await waitUntil { continuation != nil }
        try #require(continuation != nil)
        if closeAll { pins.closeAll() } else { window.close() }
        #expect(pins.count == 0)
        #expect(window.contentView == nil)
        try await waitUntil { view == nil }
        #expect(view == nil)
        continuation?.resume(throwing: CocoaError(.fileWriteNoPermission))
        try await waitUntil { cancelled }
        #expect(cancelled)
        #expect(errors.isEmpty)
    }

    @Test func realSaveFailureIsReportedOnceAndCanRetry() async throws {
        _ = NSApplication.shared
        var calls = 0
        var errors: [String] = []
        let pins = PinnedScreenshotManager(presentWindow: { _ in }, saveImage: { _ in
            calls += 1
            throw CocoaError(.fileWriteNoPermission)
        }, reportError: { errors.append($0) })
        defer { pins.closeAll() }
        pins.show(try image(), sourceID: "test", sourceName: "测试", origin: .zero)
        let window = try #require(pins.windows.first)
        try save(window)
        try await waitUntil { errors.count == 1 }
        #expect(errors.count == 1)
        try save(window)
        try await waitUntil { errors.count == 2 }
        #expect(calls == 2)
        #expect(errors.count == 2)
    }
}
