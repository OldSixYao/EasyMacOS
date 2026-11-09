import AppKit
import Testing
@testable import PasteMan

@Suite("长截屏目标窗口校验") struct LongScreenshotTargetValidationTests {
    private let ownPID: pid_t = 900
    private var region: LongScreenshotRegion {
        LongScreenshotRegion(screen: ScreenshotScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 1200, height: 900), scale: 2),
            selection: CGRect(x: 100, y: 100, width: 500, height: 500), desktopTop: 900)
    }
    private var target: LongScreenshotTarget {
        LongScreenshotTarget(windowID: 17, processID: 123, frame: CGRect(x: 50, y: 50, width: 800, height: 700),
            sourceID: "test.long-page", sourceName: "测试长页面")
    }
    private var valid: LongScreenshotTargetSnapshot {
        let window = LongScreenshotWindowIdentity(id: target.windowID, processID: target.processID, frame: target.frame)
        return LongScreenshotTargetSnapshot(hasPermission: true, targetWindow: window, topWindow: window,
            frontmostProcessID: target.processID, focusedWindowFrame: target.frame,
            hitProcessID: target.processID, hitWindowFrame: target.frame)
    }
    private func check(_ snapshot: LongScreenshotTargetSnapshot) throws {
        try LongScreenshotTargetValidation.validate(snapshot, target: target, region: region, ownProcessID: ownPID)
    }

    @Test func unchangedTargetAllowsScrollingAndDistinguishesStaleSelectionOverlay() throws {
        try check(valid)
        var snapshot = valid
        snapshot.hitProcessID = ownPID
        #expect(throws: LongScreenshotTargetError.overlayClosing) { try check(snapshot) }
        snapshot = valid; snapshot.frontmostProcessID = ownPID
        #expect(throws: LongScreenshotTargetError.ownApplicationFocused) { try check(snapshot) }
    }
    @Test func permissionWindowAndFocusFailuresHaveSpecificCauses() throws {
        var snapshot = valid; snapshot.hasPermission = false
        #expect(throws: LongScreenshotTargetError.permissionLost) { try check(snapshot) }
        snapshot = valid; snapshot.targetWindow = nil
        #expect(throws: LongScreenshotTargetError.windowUnavailable) { try check(snapshot) }
        snapshot = valid
        snapshot.targetWindow = LongScreenshotWindowIdentity(id: 17, processID: 123, frame: target.frame.offsetBy(dx: 2, dy: 0))
        #expect(throws: LongScreenshotTargetError.windowMoved) { try check(snapshot) }
        snapshot = valid
        snapshot.topWindow = LongScreenshotWindowIdentity(id: 18, processID: 321, frame: target.frame)
        #expect(throws: LongScreenshotTargetError.windowObscured) { try check(snapshot) }
        snapshot = valid; snapshot.frontmostProcessID = 321
        #expect(throws: LongScreenshotTargetError.applicationChanged) { try check(snapshot) }
        snapshot = valid; snapshot.focusedWindowFrame = target.frame.offsetBy(dx: 50, dy: 0)
        #expect(throws: LongScreenshotTargetError.windowChanged) { try check(snapshot) }
        snapshot = valid; snapshot.hitProcessID = 321
        #expect(throws: LongScreenshotTargetError.windowObscured) { try check(snapshot) }
    }
    @Test func missingAccessibilityResponseIsNotReportedAsLostPermission() throws {
        var snapshot = valid; snapshot.frontmostProcessID = nil
        #expect(throws: LongScreenshotTargetError.focusUnavailable) { try check(snapshot) }
        snapshot = valid; snapshot.hitProcessID = nil
        #expect(throws: LongScreenshotTargetError.hitTestUnavailable) { try check(snapshot) }
        snapshot = valid; snapshot.hitWindowFrame = target.frame.offsetBy(dx: 2, dy: 0)
        #expect(throws: LongScreenshotTargetError.windowChanged) { try check(snapshot) }
        snapshot = valid
        snapshot.targetWindow = LongScreenshotWindowIdentity(id: 17, processID: 999, frame: target.frame)
        #expect(throws: LongScreenshotTargetError.windowUnavailable) { try check(snapshot) }
    }

    @Test func knownFrontmostProcessAndMatchingHitDoNotRequireOptionalFocusWindowMetadata() throws {
        var snapshot = valid
        snapshot.focusedWindowFrame = nil
        try check(snapshot)
        // 窗口元数据缺失仍须校验真实前台进程与选区命中，不能跳过切换检查。
        snapshot.frontmostProcessID = 321
        #expect(throws: LongScreenshotTargetError.applicationChanged) { try check(snapshot) }
        snapshot.frontmostProcessID = target.processID
        snapshot.hitProcessID = 321
        #expect(throws: LongScreenshotTargetError.windowObscured) { try check(snapshot) }
    }

    @Test @MainActor func initialOverlayRetirementWaitsForTwoStableChecksBeforeCapture() async throws {
        var attempts = 0
        var handoffs = 0
        try await LongScreenshotTargetReadiness.wait(timeout: .seconds(5), interval: .milliseconds(1)) {
            attempts += 1
            var snapshot = valid
            if attempts <= 3 { snapshot.hitProcessID = ownPID }
            try check(snapshot)
        } handoff: { handoffs += 1 }
        #expect(attempts == 5 && handoffs == 0)
    }
    @Test @MainActor func ownFocusIsHandedBackOnceAndEveryStableCheckMustBeConsecutive() async throws {
        var attempts = 0
        var handoffs = 0
        try await LongScreenshotTargetReadiness.wait(timeout: .seconds(5), interval: .milliseconds(1)) {
            attempts += 1
            var snapshot = valid
            if attempts <= 2 { snapshot.frontmostProcessID = ownPID }
            if attempts == 4 { snapshot.hitProcessID = ownPID }
            try check(snapshot)
        } handoff: { handoffs += 1 }
        #expect(attempts == 6 && handoffs == 1)
    }
    @Test @MainActor func switchingToAnotherApplicationFailsImmediatelyWithoutReactivation() async throws {
        var attempts = 0
        var handoffs = 0
        do {
            try await LongScreenshotTargetReadiness.wait(interval: .milliseconds(1)) {
                attempts += 1
                var snapshot = valid
                snapshot.frontmostProcessID = 321
                try check(snapshot)
            } handoff: { handoffs += 1 }
            Issue.record("切换到其他应用后不应继续")
        } catch let error as LongScreenshotTargetError { #expect(error == .applicationChanged) }
        #expect(attempts == 1 && handoffs == 0)
    }
    @Test @MainActor func startupTimeoutPreservesItsActualCauseAndCancellationStopsPolling() async throws {
        do {
            try await LongScreenshotTargetReadiness.wait(timeout: .milliseconds(5), interval: .milliseconds(1)) {
                throw LongScreenshotTargetError.overlayClosing
            }
            Issue.record("浮层始终未退场时应超时")
        } catch let error as LongScreenshotTargetError { #expect(error == .overlayClosing) }
        var checks = 0
        let task = Task {
            try await LongScreenshotTargetReadiness.wait {
                checks += 1
                throw LongScreenshotTargetError.focusUnavailable
            }
        }
        while checks == 0 { await Task.yield() }
        task.cancel()
        do { try await task.value; Issue.record("取消后不应完成准备") } catch is CancellationError {} catch { throw error }
        #expect(checks == 1)
    }

    @Test func startupErrorsNeverClaimAnImageWasSaved() {
        for error in [LongScreenshotTargetError.permissionLost, .windowUnavailable, .windowMoved, .windowObscured,
                      .applicationChanged, .windowChanged, .focusUnavailable, .ownApplicationFocused, .hitTestUnavailable, .overlayClosing] {
            #expect(!error.localizedDescription.contains("已保留"))
            #expect(!error.localizedDescription.contains("kept"))
        }
    }
}
