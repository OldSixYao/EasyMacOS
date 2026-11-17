import Foundation
import Synchronization
import Testing
@testable import PasteMan

@Suite("长截屏后台辅助功能查询", .serialized) @MainActor struct LongScreenshotAccessibilityTests {
    private var query: LongScreenshotAccessibilityReader.Query {
        .init(processID: 123, point: CGPoint(x: 50, y: 50), inspectFocus: true)
    }

    @Test func blockedAccessibilityQueryLeavesMainActorResponsiveAndTimesOutWithoutLateResult() async throws {
        let started = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        let reader = LongScreenshotAccessibilityReader { _ in
            #expect(!Thread.isMainThread)
            let first = started.withLock { started in
                let first = !started
                started = true
                return first
            }
            if first { _ = release.wait(timeout: .now() + 5) }
            return .init(hitProcessID: 123)
        }
        defer { release.signal() }
        let query = query
        let request = Task {
            try await LongScreenshotOperation.run(timeout: .milliseconds(80)) { try await reader.read(query) }
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while !started.withLock({ $0 }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(started.withLock { $0 })
        // 查询仍然阻塞时主执行器可处理其他任务，不能依靠查询先返回。
        var responsive = false
        await Task { @MainActor in responsive = true }.value
        #expect(responsive)
        do {
            _ = try await request.value
            Issue.record("未响应的查询应超时")
        } catch let error as LongScreenshotError {
            #expect(error == .captureTimedOut)
        }
        release.signal()
        let next = try await reader.read(query)
        #expect(next.hitProcessID == 123)
    }

    @Test func validationWaitDoesNotSendScrollAndResumesOnlyAfterValidation() async throws {
        var steps = 0
        let pump = LongScreenshotScrollPump(viewportHeight: 400) { _ in steps += 1 }
        defer { pump.stop() }
        pump.validationPending = true
        pump.start()
        try await Task.sleep(for: .milliseconds(65))
        #expect(steps == 0)
        pump.validationPending = false
        let deadline = ContinuousClock.now + .seconds(2)
        while steps == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(steps > 0)
        pump.paused = true
        let before = steps
        pump.validationPending = true
        pump.validationPending = false
        try await Task.sleep(for: .milliseconds(40))
        #expect(steps == before)
    }
}
