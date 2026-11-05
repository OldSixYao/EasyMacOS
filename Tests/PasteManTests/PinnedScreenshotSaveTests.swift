import AppKit
import Testing

@testable import PasteMan

@Suite("钉图保存生命周期", .serialized) @MainActor struct PinnedScreenshotSaveTests {
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
        var continuation: CheckedContinuation<Bool, any Error>?
        let pins = PinnedScreenshotManager(presentWindow: { _ in }, saveImage: { _ in
            calls += 1
            return try await withCheckedThrowingContinuation { continuation = $0 }
        })
        defer { pins.closeAll() }
        pins.show(try image(), sourceID: "test", sourceName: "测试", origin: .zero)
        let window = try #require(pins.windows.first)
        try save(window)
        try save(window)
        for _ in 0..<100 where calls == 0 { await Task.yield() }
        #expect(calls == 1)
        continuation?.resume(returning: false)
        for _ in 0..<100 { await Task.yield() }
        try save(window)
        for _ in 0..<100 where calls < 2 { await Task.yield() }
        #expect(calls == 2)
        continuation?.resume(returning: true)
        for _ in 0..<100 { await Task.yield() }
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
        weak var view = window.contentView
        try save(window)
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        try #require(continuation != nil)
        if closeAll { pins.closeAll() } else { window.close() }
        #expect(pins.count == 0)
        #expect(window.contentView == nil)
        for _ in 0..<100 where view != nil { await Task.yield() }
        #expect(view == nil)
        continuation?.resume(throwing: CocoaError(.fileWriteNoPermission))
        for _ in 0..<100 where !cancelled { await Task.yield() }
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
        for _ in 0..<100 where errors.isEmpty { await Task.yield() }
        #expect(errors.count == 1)
        try save(window)
        for _ in 0..<100 where calls < 2 { await Task.yield() }
        #expect(calls == 2)
        #expect(errors.count == 2)
    }
}
