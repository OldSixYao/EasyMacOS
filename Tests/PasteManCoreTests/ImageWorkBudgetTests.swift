import Foundation
import Testing

@testable import PasteManCore

private actor HeldImageWork {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func run() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(); continuation = nil }
}

@Suite("图片临时内存预算") struct ImageWorkBudgetTests {
    private let mib = 1024 * 1024

    @Test func largeTasksWaitWhileSmallPreviewCanProceedAndCanceledQueueNeverRuns() async throws {
        let budget = ImageWorkBudget(byteLimit: 100 * mib)
        let active = HeldImageWork(), canceledWork = HeldImageWork()
        let first = Task { try await budget.withPermit(estimatedBytes: 80 * mib, priority: .background) { await active.run() } }
        try await wait { await active.started }
        let canceled = Task {
            try await budget.withPermit(estimatedBytes: 60 * mib, priority: .background) { await canceledWork.run() }
        }
        try await wait { budget.pendingCount == 1 }
        let bytes = try await budget.withPermit(estimatedBytes: 2 * mib, priority: .display) { budget.activeByteCount }
        #expect(bytes == 82 * mib)
        canceled.cancel()
        await #expect(throws: CancellationError.self) { try await canceled.value }
        #expect(await canceledWork.started == false)
        #expect(budget.activeByteCount == 80 * mib)
        await active.finish()
        try await first.value
        #expect(budget.activeByteCount == 0)
        #expect(budget.pendingCount == 0)
    }

    @Test func userActionPrecedesQueuedBackgroundWorkWithoutLosingItsReservation() async throws {
        let budget = ImageWorkBudget(byteLimit: 100 * mib)
        let initial = HeldImageWork(), background = HeldImageWork(), user = HeldImageWork()
        let first = Task { try await budget.withPermit(estimatedBytes: 90 * mib, priority: .display) { await initial.run() } }
        try await wait { await initial.started }
        let queued = Task { try await budget.withPermit(estimatedBytes: 80 * mib, priority: .background) { await background.run() } }
        try await wait { budget.pendingCount == 1 }
        let foreground = Task { try await budget.withPermit(estimatedBytes: 80 * mib, priority: .userInitiated) { await user.run() } }
        try await wait { budget.pendingCount == 2 }
        await initial.finish()
        try await wait { await user.started }
        #expect(await background.started == false)
        await user.finish()
        try await wait { await background.started }
        await background.finish()
        try await first.value
        try await foreground.value
        try await queued.value
        #expect(budget.activeByteCount == 0)
    }

    @Test func pressureRestrictsNewWorkAndActiveCancellationWaitsForSynchronousOperation() async throws {
        let budget = ImageWorkBudget(byteLimit: 128 * mib)
        let active = HeldImageWork(), next = HeldImageWork()
        let first = Task { try await budget.withPermit(estimatedBytes: 64 * mib, priority: .background) { await active.run() } }
        try await wait { await active.started }
        budget.setMemoryPressure(.warning)
        let queued = Task { try await budget.withPermit(estimatedBytes: 64 * mib, priority: .background) { await next.run() } }
        try await wait { budget.pendingCount == 1 }
        first.cancel()
        try await Task.sleep(for: .milliseconds(20))
        #expect(budget.activeByteCount == 64 * mib)
        #expect(await next.started == false)
        await active.finish()
        await #expect(throws: CancellationError.self) { try await first.value }
        try await wait { await next.started }
        await next.finish()
        try await queued.value
        #expect(budget.activeByteCount == 0)
        budget.setMemoryPressure(.normal)
    }

    @Test func oversizeWorkRunsAloneAndThrowingOperationReturnsBudget() async throws {
        let budget = ImageWorkBudget(byteLimit: 32 * mib)
        enum SyntheticFailure: Error { case failed }
        await #expect(throws: SyntheticFailure.self) {
            try await budget.withPermit(estimatedBytes: 64 * mib, priority: .userInitiated) {
                throw SyntheticFailure.failed
            }
        }
        #expect(budget.activeByteCount == 0)
        let result = try await budget.withPermit(estimatedBytes: 32 * mib, priority: .display) { 42 }
        #expect(result == 42)
    }

    @Test func cancellationRacingWithAdmissionDoesNotLeakReservationsOrContinuations() async throws {
        let budget = ImageWorkBudget(byteLimit: 16 * mib)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask {
                    let request = Task {
                        try await budget.withPermit(estimatedBytes: 12 * mib, priority: .background) {
                            try await Task.sleep(for: .microseconds(100))
                        }
                    }
                    if index.isMultiple(of: 2) { await Task.yield() }
                    request.cancel()
                    do { try await request.value } catch is CancellationError { }
                }
            }
            try await group.waitForAll()
        }
        #expect(budget.activeByteCount == 0 && budget.pendingCount == 0)
    }

    @Test func immediateWorkSharesAccountingAndCannotBypassQueuedLargeTask() async throws {
        let budget = ImageWorkBudget(byteLimit: 100 * mib)
        let active = HeldImageWork(), pending = HeldImageWork()
        let first = Task { try await budget.withPermit(estimatedBytes: 90 * mib, priority: .background) { await active.run() } }
        try await wait { await active.started }
        let immediate = try budget.performIfAvailable(estimatedBytes: 2 * mib) { budget.activeByteCount }
        #expect(immediate == 92 * mib && budget.activeByteCount == 90 * mib)
        let tooLarge = try budget.performIfAvailable(estimatedBytes: 20 * mib) { 1 }
        #expect(tooLarge == nil)
        let queued = Task { try await budget.withPermit(estimatedBytes: 80 * mib, priority: .background) { await pending.run() } }
        try await wait { budget.pendingCount == 1 }
        let noQueueJump = try budget.performIfAvailable(estimatedBytes: 2 * mib) { 1 }
        #expect(noQueueJump == nil)
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        await active.finish()
        try await first.value
        enum Failure: Error { case failed }
        #expect(throws: Failure.self) {
            try budget.performIfAvailable(estimatedBytes: 20 * mib) { throw Failure.failed }
        }
        #expect(budget.activeByteCount == 0 && budget.pendingCount == 0)
    }

    private func wait(_ ready: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await ready()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(await ready())
    }
}
