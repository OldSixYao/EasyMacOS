import AppKit

enum LongScreenshotTargetError: Error, LocalizedError, Equatable {
    case permissionLost, windowUnavailable, windowMoved, windowObscured, applicationChanged, windowChanged
    case focusUnavailable, ownApplicationFocused, overlayClosing

    var canWaitForInitialFocus: Bool {
        switch self {
        case .focusUnavailable, .ownApplicationFocused, .overlayClosing: true
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
        // 辅助功能接口缺值不等于窗口未响应。系统窗口编号、位置、遮挡与前台身份
        // 已独立核验；命中信息可用时仍拒绝明确的浮层残留或目标变化。
        if let hit = snapshot.hitProcessID {
            guard hit != ownProcessID else { throw LongScreenshotTargetError.overlayClosing }
            guard hit == target.processID else { throw LongScreenshotTargetError.windowObscured }
        }
        if let frame = snapshot.hitWindowFrame, !matches(frame, target.frame) {
            throw LongScreenshotTargetError.windowChanged
        }
    }

    static func validateWindow(_ snapshot: LongScreenshotTargetSnapshot, target: LongScreenshotTarget,
                               region: LongScreenshotRegion, ownProcessID: pid_t) throws {
        guard snapshot.hasPermission else { throw LongScreenshotTargetError.permissionLost }
        guard let window = snapshot.targetWindow, window.id == target.windowID, window.processID == target.processID else {
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
    static func prepare(target: LongScreenshotTarget, region: LongScreenshotRegion, ownProcessID: pid_t,
                        timeout: Duration = .seconds(1), interval: Duration = .milliseconds(50),
                        snapshot: () -> LongScreenshotTargetSnapshot, handoff: () -> Void) async throws {
        try Task.checkCancellation()
        let initial = snapshot()
        var first: LongScreenshotTargetSnapshot? = initial
        var reachedTarget = false
        var handedOff = false
        func handoffOnce() {
            guard !handedOff else { return }
            handedOff = true
            handoff()
        }
        try await wait(timeout: timeout, interval: interval) {
            let current = first ?? snapshot()
            first = nil
            if !reachedTarget, current.frontmostProcessID == initial.frontmostProcessID,
               current.frontmostProcessID != target.processID {
                // 框选可见的后台窗口也表示选择该目标。交接前先核验权限、窗口和遮挡，
                // 只等待最初前台身份退场；出现新的外部应用不能重新抢回焦点。
                var selected = current
                selected.frontmostProcessID = target.processID
                do {
                    try LongScreenshotTargetValidation.validate(selected, target: target, region: region, ownProcessID: ownProcessID)
                } catch LongScreenshotTargetError.overlayClosing {
                    // 本应用的旧框选命中可能要交还焦点后才消失，不能反过来一直等待它。
                    handoffOnce()
                    throw LongScreenshotTargetError.overlayClosing
                }
                handoffOnce()
                throw LongScreenshotTargetError.focusUnavailable
            }
            try LongScreenshotTargetValidation.validate(current, target: target, region: region, ownProcessID: ownProcessID)
            reachedTarget = true
        } handoff: { handoffOnce() }
    }

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
