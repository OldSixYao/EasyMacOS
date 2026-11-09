import AppKit

enum LongScreenshotTargetError: Error, LocalizedError, Equatable {
    case permissionLost, windowUnavailable, windowMoved, windowObscured, applicationChanged, windowChanged
    case focusUnavailable, ownApplicationFocused, hitTestUnavailable, overlayClosing

    var canWaitForInitialFocus: Bool {
        switch self {
        case .focusUnavailable, .ownApplicationFocused, .hitTestUnavailable, .overlayClosing: true
        default: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .permissionLost:
            L.t("Screen Recording or Accessibility access is no longer available. Check permissions and start again.",
                "屏幕录制或辅助功能权限已失效，请检查权限后重新开始。")
        case .windowUnavailable:
            L.t("The selected window was closed or is no longer on this display.", "所选窗口已关闭或已离开当前显示器。")
        case .windowMoved:
            L.t("The selected window moved or changed size. Select the scrolling area again.", "所选窗口的位置或大小已变化，请重新框选滚动区域。")
        case .windowObscured:
            L.t("Another window or menu is covering the selected area. Uncover it and start again.",
                "其他窗口或菜单遮住了选区，请移开遮挡后重新开始。")
        case .applicationChanged:
            L.t("The active application changed. Return to the selected window and start again.",
                "当前应用已切换，请回到所选窗口后重新开始。")
        case .windowChanged:
            L.t("The active window changed. Return to the selected window and start again.",
                "当前窗口已切换，请回到所选窗口后重新开始。")
        case .focusUnavailable, .ownApplicationFocused, .overlayClosing:
            L.t("The selected window could not regain focus after selection. Click it and start again.",
                "框选结束后未能恢复目标窗口焦点，请点击目标窗口后重新开始。")
        case .hitTestUnavailable:
            L.t("The selected window is not responding to Accessibility checks. Try again after it responds.",
                "目标窗口暂未响应辅助功能检查，请待窗口恢复响应后重试。")
        }
    }
}

struct LongScreenshotWindowIdentity: Sendable {
    let id: CGWindowID
    let processID: pid_t
    let frame: CGRect
}

struct LongScreenshotTargetSnapshot: Sendable {
    var hasPermission: Bool
    var targetWindow: LongScreenshotWindowIdentity?
    var topWindow: LongScreenshotWindowIdentity?
    var frontmostProcessID: pid_t?
    var focusedWindowFrame: CGRect?
    var hitProcessID: pid_t?
    var hitWindowFrame: CGRect?
}

enum LongScreenshotTargetValidation {
    static func validate(_ snapshot: LongScreenshotTargetSnapshot, target: LongScreenshotTarget,
                         region: LongScreenshotRegion, ownProcessID: pid_t) throws {
        try validateWindow(snapshot, target: target, region: region, ownProcessID: ownProcessID)
        if let frame = snapshot.focusedWindowFrame, !matches(frame, target.frame) {
            throw LongScreenshotTargetError.windowChanged
        }
        guard let hit = snapshot.hitProcessID else { throw LongScreenshotTargetError.hitTestUnavailable }
        // 系统可能在关闭非激活截图窗口后仍命中上一轮辅助功能树。
        // 只在首次采集准备期间等待这一已知过渡，采集过程中不放宽校验。
        guard hit != ownProcessID else { throw LongScreenshotTargetError.overlayClosing }
        guard hit == target.processID else { throw LongScreenshotTargetError.windowObscured }
        if let frame = snapshot.hitWindowFrame, !matches(frame, target.frame) {
            throw LongScreenshotTargetError.windowChanged
        }
    }

    static func validateWindow(_ snapshot: LongScreenshotTargetSnapshot, target: LongScreenshotTarget,
                               region: LongScreenshotRegion, ownProcessID: pid_t) throws {
        guard snapshot.hasPermission else { throw LongScreenshotTargetError.permissionLost }
        guard let window = snapshot.targetWindow, window.processID == target.processID else {
            throw LongScreenshotTargetError.windowUnavailable
        }
        guard window.frame == target.frame, window.frame.contains(region.quartzRect) else {
            throw LongScreenshotTargetError.windowMoved
        }
        guard snapshot.topWindow?.id == target.windowID, snapshot.topWindow?.processID == target.processID else {
            throw LongScreenshotTargetError.windowObscured
        }
        guard let focused = snapshot.frontmostProcessID else { throw LongScreenshotTargetError.focusUnavailable }
        guard focused != ownProcessID else { throw LongScreenshotTargetError.ownApplicationFocused }
        guard focused == target.processID else { throw LongScreenshotTargetError.applicationChanged }
    }

    private static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1
            && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }
}

@MainActor enum LongScreenshotTargetReadiness {
    static func wait(timeout: Duration = .seconds(1), interval: Duration = .milliseconds(50),
                     validate: () throws -> Void, handoff: () -> Void = {}) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var consecutive = 0
        var handedOff = false
        var lastIssue = LongScreenshotTargetError.focusUnavailable
        while true {
            try Task.checkCancellation()
            do {
                try validate()
                consecutive += 1
                if consecutive >= 2 { return }
            } catch let issue as LongScreenshotTargetError {
                guard issue.canWaitForInitialFocus else { throw issue }
                consecutive = 0
                lastIssue = issue
                if issue == .ownApplicationFocused, !handedOff {
                    handoff()
                    handedOff = true
                }
            }
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw lastIssue }
            try await Task.sleep(for: min(interval, ContinuousClock.now.duration(to: deadline)))
        }
    }
}
