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
    @Test func missingHitResponseUsesIndependentlyVerifiedWindowIdentity() throws {
        var snapshot = valid
        snapshot.hitProcessID = nil
        snapshot.hitWindowFrame = nil
        try check(snapshot)
        snapshot.focusedWindowFrame = nil
        try check(snapshot)

        snapshot.hasPermission = false
        #expect(throws: LongScreenshotTargetError.permissionLost) { try check(snapshot) }
        snapshot = valid; snapshot.hitProcessID = nil; snapshot.targetWindow = nil
        #expect(throws: LongScreenshotTargetError.windowUnavailable) { try check(snapshot) }
        snapshot = valid; snapshot.hitProcessID = nil
        snapshot.targetWindow = LongScreenshotWindowIdentity(id: 18, processID: target.processID, frame: target.frame)
        #expect(throws: LongScreenshotTargetError.windowUnavailable) { try check(snapshot) }
        snapshot = valid; snapshot.hitProcessID = nil
        snapshot.targetWindow = LongScreenshotWindowIdentity(id: target.windowID, processID: target.processID,
            frame: target.frame.offsetBy(dx: 2, dy: 0))
        #expect(throws: LongScreenshotTargetError.windowMoved) { try check(snapshot) }
        snapshot = valid; snapshot.hitProcessID = nil
        snapshot.topWindow = LongScreenshotWindowIdentity(id: 18, processID: 321, frame: target.frame)
        #expect(throws: LongScreenshotTargetError.windowObscured) { try check(snapshot) }
        snapshot = valid; snapshot.hitProcessID = nil; snapshot.frontmostProcessID = 321
        #expect(throws: LongScreenshotTargetError.applicationChanged) { try check(snapshot) }
        snapshot = valid; snapshot.hitProcessID = nil; snapshot.frontmostProcessID = ownPID
        #expect(throws: LongScreenshotTargetError.ownApplicationFocused) { try check(snapshot) }
        snapshot = valid; snapshot.hitProcessID = nil
        snapshot.focusedWindowFrame = target.frame.offsetBy(dx: 2, dy: 0)
        #expect(throws: LongScreenshotTargetError.windowChanged) { try check(snapshot) }
    }

    @Test func missingFocusIdentityStillStopsAndKnownWindowMetadataIsChecked() throws {
        var snapshot = valid; snapshot.frontmostProcessID = nil
        #expect(throws: LongScreenshotTargetError.focusUnavailable) { try check(snapshot) }
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
    @Test @MainActor func unavailableHitMetadataDoesNotBlockAStableVerifiedWindow() async throws {
        var attempts = 0
        try await LongScreenshotTargetReadiness.wait(timeout: .seconds(5), interval: .milliseconds(1)) {
            attempts += 1
            var snapshot = valid
            snapshot.hitProcessID = nil
            snapshot.hitWindowFrame = nil
            snapshot.focusedWindowFrame = nil
            try check(snapshot)
        }
        #expect(attempts == 2)
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

    @Test(arguments: [pid_t(321), pid_t(900)]) @MainActor
    func initiallyVisibleWindowReceivesFocusOnceBeforeTwoStableChecks(_ initialPID: pid_t) async throws {
        var attempts = 0, handoffs = 0
        try await LongScreenshotTargetReadiness.prepare(target: target, region: region, ownProcessID: ownPID,
            timeout: .seconds(5), interval: .milliseconds(1)) {
            attempts += 1
            var snapshot = valid
            if attempts <= 3 { snapshot.frontmostProcessID = initialPID }
            return snapshot
        } handoff: { handoffs += 1 }
        #expect(attempts == 5 && handoffs == 1)
    }

    @Test @MainActor func alreadyFocusedTargetNeedsNoActivation() async throws {
        var attempts = 0, handoffs = 0
        try await LongScreenshotTargetReadiness.prepare(target: target, region: region, ownProcessID: ownPID,
            timeout: .seconds(5), interval: .milliseconds(1)) {
            attempts += 1
            return valid
        } handoff: { handoffs += 1 }
        #expect(attempts == 2 && handoffs == 0)
    }

    @Test @MainActor func staleOverlayDoesNotPreventInitialFocusHandoff() async throws {
        var attempts = 0, handoffs = 0
        try await LongScreenshotTargetReadiness.prepare(target: target, region: region, ownProcessID: ownPID,
            timeout: .seconds(5), interval: .milliseconds(1)) {
            attempts += 1
            var snapshot = valid
            snapshot.frontmostProcessID = handoffs == 0 ? ownPID : target.processID
            if attempts <= 2 { snapshot.hitProcessID = ownPID }
            return snapshot
        } handoff: { handoffs += 1 }
        #expect(attempts == 4 && handoffs == 1)
    }

    @Test(arguments: [false, true]) @MainActor
    func initialHandoffRejectsAUserSwitchAndDoesNotActivateAgain(_ targetWasReached: Bool) async throws {
        var attempts = 0, handoffs = 0
        do {
            try await LongScreenshotTargetReadiness.prepare(target: target, region: region, ownProcessID: ownPID,
                timeout: .seconds(5), interval: .milliseconds(1)) {
                attempts += 1
                var snapshot = valid
                if attempts == 1 { snapshot.frontmostProcessID = 321 }
                else if !targetWasReached { snapshot.frontmostProcessID = 456 }
                else if attempts > 2 { snapshot.frontmostProcessID = 321 }
                return snapshot
            } handoff: { handoffs += 1 }
            Issue.record("准备期间真实切换应用时不能继续")
        } catch let issue as LongScreenshotTargetError { #expect(issue == .applicationChanged) }
        #expect(attempts == (targetWasReached ? 3 : 2) && handoffs == 1)
    }

    @Test @MainActor func invalidInitialWindowIsNeverActivated() async throws {
        for issue in [LongScreenshotTargetError.permissionLost, .windowUnavailable, .windowMoved,
                      .windowObscured, .windowChanged] {
            var snapshot = valid
            snapshot.frontmostProcessID = 321
            switch issue {
            case .permissionLost: snapshot.hasPermission = false
            case .windowUnavailable: snapshot.targetWindow = nil
            case .windowMoved:
                snapshot.targetWindow = LongScreenshotWindowIdentity(id: target.windowID, processID: target.processID,
                    frame: target.frame.offsetBy(dx: 2, dy: 0))
            case .windowObscured: snapshot.hitProcessID = 456
            case .windowChanged: snapshot.hitWindowFrame = target.frame.offsetBy(dx: 2, dy: 0)
            default: break
            }
            var handoffs = 0
            do {
                try await LongScreenshotTargetReadiness.prepare(target: target, region: region, ownProcessID: ownPID) {
                    snapshot
                } handoff: { handoffs += 1 }
                Issue.record("无效窗口不能开始采集")
            } catch let actual as LongScreenshotTargetError { #expect(actual == issue) }
            #expect(handoffs == 0)
        }
    }

    @Test @MainActor func incompleteHandoffTimesOutWithoutAcceptingTheOldForeground() async throws {
        var handoffs = 0
        do {
            try await LongScreenshotTargetReadiness.prepare(target: target, region: region, ownProcessID: ownPID,
                timeout: .milliseconds(5), interval: .milliseconds(1)) {
                var snapshot = valid
                snapshot.frontmostProcessID = 321
                return snapshot
            } handoff: { handoffs += 1 }
            Issue.record("目标始终未获得焦点时不能完成准备")
        } catch let issue as LongScreenshotTargetError { #expect(issue == .focusUnavailable) }
        #expect(handoffs == 1)
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
                      .applicationChanged, .windowChanged, .focusUnavailable, .ownApplicationFocused, .overlayClosing] {
            #expect(!error.localizedDescription.contains("已保留"))
            #expect(!error.localizedDescription.contains("kept"))
        }
    }
}
