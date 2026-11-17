import AppKit
import ApplicationServices

@MainActor struct SystemLongScreenshotScroll: LongScreenshotScrolling {
    private let accessibility: LongScreenshotAccessibilityReader

    init(hitTest: @escaping @Sendable (AXUIElement, CGPoint) -> AXUIElement? = LongScreenshotAccessibilityReader.hitTest) {
        accessibility = LongScreenshotAccessibilityReader(hitTest: hitTest)
    }

    private func windows() -> [[String: Any]] {
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowOwnerPID as String] as? pid_t) != ProcessInfo.processInfo.processIdentifier
                && ($0[kCGWindowLayer as String] as? Int) == 0
                && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0 }
    }
    private func frame(_ window: [String: Any]) -> CGRect? {
        guard let bounds = window[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }
    func resolve(_ region: LongScreenshotRegion) throws -> LongScreenshotTarget {
        let center = CGPoint(x: region.quartzRect.midX, y: region.quartzRect.midY)
        guard region.selection.width >= 80, region.selection.height >= 80,
            CGRect(origin: .zero, size: region.screen.frame.size).contains(region.selection),
            let window = windows().first(where: { frame($0)?.contains(center) == true }),
            (window[kCGWindowLayer as String] as? Int) == 0,
            let bounds = frame(window), bounds.contains(region.quartzRect),
            let id = window[kCGWindowNumber as String] as? CGWindowID,
            let pid = window[kCGWindowOwnerPID as String] as? pid_t,
            let app = NSRunningApplication(processIdentifier: pid)
        else { throw LongScreenshotError.selection }
        let target = LongScreenshotTarget(windowID: id, processID: pid, frame: bounds,
            sourceID: app.bundleIdentifier ?? "unknown", sourceName: app.localizedName ?? L.unknownApp)
        return target
    }
    func prepare(_ target: LongScreenshotTarget, region: LongScreenshotRegion) async throws {
        try await LongScreenshotTargetReadiness.prepare(target: target, region: region,
            ownProcessID: ProcessInfo.processInfo.processIdentifier) {
            try await snapshot(target, region: region)
        } handoff: {
            guard let app = NSRunningApplication(processIdentifier: target.processID), !app.isTerminated else { return }
            NSApp.yieldActivation(to: app)
            app.activate(from: .current, options: [])
        }
    }
    func validate(_ target: LongScreenshotTarget, region: LongScreenshotRegion) async throws {
        try await LongScreenshotTargetValidation.validate(snapshot(target, region: region), target: target, region: region,
            ownProcessID: ProcessInfo.processInfo.processIdentifier)
    }

    private func snapshot(_ target: LongScreenshotTarget, region: LongScreenshotRegion) async throws -> LongScreenshotTargetSnapshot {
        guard CGPreflightScreenCaptureAccess() && AXIsProcessTrusted() && CGPreflightPostEventAccess() else {
            return windowSnapshot(target, region: region)
        }
        let query = LongScreenshotAccessibilityReader.Query(processID: target.processID,
            point: CGPoint(x: region.quartzRect.midX, y: region.quartzRect.midY),
            inspectFocus: NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID)
        let details = try await LongScreenshotOperation.run(timeout: .seconds(2)) { [accessibility] in
            try await accessibility.read(query)
        }
        try Task.checkCancellation()
        // 后台跨进程查询结束后重新读取窗口、前台和权限，不能使用等待前的状态。
        var snapshot = windowSnapshot(target, region: region)
        snapshot.focusedWindowFrame = details.focusedFrame
        snapshot.hitProcessID = details.hitProcessID
        snapshot.hitWindowFrame = details.hitFrame
        return snapshot
    }
    private func windowSnapshot(_ target: LongScreenshotTarget, region: LongScreenshotRegion) -> LongScreenshotTargetSnapshot {
        let windows = windows()
        return LongScreenshotTargetSnapshot(
            hasPermission: CGPreflightScreenCaptureAccess() && AXIsProcessTrusted() && CGPreflightPostEventAccess(),
            targetWindow: windows.first { $0[kCGWindowNumber as String] as? CGWindowID == target.windowID }.flatMap(identity),
            topWindow: windows.first { frame($0)?.intersects(region.quartzRect) == true }.flatMap(identity),
            frontmostProcessID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }
    func scroll(_ points: Int, target: LongScreenshotTarget, region: LongScreenshotRegion) throws {
        // 调用方已完成异步完整核验，发送前仍同步核验实时窗口身份。
        try scrollStep(points, target: target, region: region)
    }
    func scrollStep(_ points: Int, target: LongScreenshotTarget, region: LongScreenshotRegion) throws {
        try Task.checkCancellation()
        // 高频小步只读窗口服务器和前台身份；完整辅助功能命中由取帧循环持续复核。
        // 不在每个刷新周期内发起多次跨进程辅助功能请求。
        try LongScreenshotTargetValidation.validateWindow(windowSnapshot(target, region: region), target: target, region: region,
            ownProcessID: ProcessInfo.processInfo.processIdentifier)
        try post(points, target: target, region: region)
    }
    private func identity(_ window: [String: Any]) -> LongScreenshotWindowIdentity? {
        guard let id = window[kCGWindowNumber as String] as? CGWindowID,
            let pid = window[kCGWindowOwnerPID as String] as? pid_t, let frame = frame(window) else { return nil }
        return LongScreenshotWindowIdentity(id: id, processID: pid, frame: frame)
    }
    private func post(_ points: Int, target: LongScreenshotTarget, region: LongScreenshotRegion) throws {
        let amount = min(max(1, points), max(1, Int(region.selection.height / 3)))
        let location = CGPoint(x: region.quartzRect.midX, y: region.quartzRect.midY)
        guard let event = LongScreenshotScrollEvent.make(amount: amount, target: target,
            location: location) else { throw LongScreenshotError.scrollUnavailable }
        // 定向投递不更新系统指针位置；事件自带目标窗口及窗口内坐标。
        event.postToPid(target.processID)
    }
}
