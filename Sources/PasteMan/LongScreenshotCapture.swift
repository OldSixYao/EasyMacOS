import AppKit
import ApplicationServices
import ScreenCaptureKit
import PasteManCore
import Darwin

struct LongScreenshotRegion: Sendable {
    let screen: ScreenshotScreen
    let selection: CGRect
    let desktopTop: CGFloat
    var quartzRect: CGRect {
        CGRect(x: screen.frame.minX + selection.minX, y: desktopTop - screen.frame.maxY + selection.minY,
            width: selection.width, height: selection.height)
    }
    var appKitRect: CGRect {
        CGRect(x: screen.frame.minX + selection.minX, y: screen.frame.maxY - selection.maxY,
            width: selection.width, height: selection.height)
    }
    var pixelRect: CGRect {
        ScreenshotGeometry.pixelRect(selection, pointSize: screen.frame.size,
            pixelSize: CGSize(width: screen.frame.width * screen.scale, height: screen.frame.height * screen.scale))
    }
}

struct LongScreenshotTarget: Sendable {
    let windowID: CGWindowID
    let processID: pid_t
    let frame: CGRect
    let sourceID: String
    let sourceName: String
}

@MainActor protocol LongScreenshotCapturing {
    var capturesContinuously: Bool { get }
    func prepare(_ region: LongScreenshotRegion) async throws
    func capture() async throws -> CGImage
    func release()
}
extension LongScreenshotCapturing { var capturesContinuously: Bool { false } }
@MainActor protocol LongScreenshotScrolling {
    func resolve(_ region: LongScreenshotRegion) throws -> LongScreenshotTarget
    func prepare(_ target: LongScreenshotTarget, region: LongScreenshotRegion) async throws
    func validate(_ target: LongScreenshotTarget, region: LongScreenshotRegion) throws
    func scroll(_ points: Int, target: LongScreenshotTarget, region: LongScreenshotRegion) throws
    func scrollStep(_ points: Int, target: LongScreenshotTarget, region: LongScreenshotRegion) throws
}

extension LongScreenshotScrolling {
    func scrollStep(_ points: Int, target: LongScreenshotTarget, region: LongScreenshotRegion) throws {
        try scroll(points, target: target, region: region)
    }
    func prepare(_ target: LongScreenshotTarget, region: LongScreenshotRegion) async throws {
        try validate(target, region: region)
    }
}

@MainActor struct SystemLongScreenshotScroll: LongScreenshotScrolling {
    private let hitTest: (AXUIElement, CGPoint) -> AXUIElement?

    init(hitTest: @escaping (AXUIElement, CGPoint) -> AXUIElement? = { root, point in
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &element) == .success else { return nil }
        return element
    }) {
        self.hitTest = hitTest
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
            snapshot(target, region: region)
        } handoff: {
            guard let app = NSRunningApplication(processIdentifier: target.processID), !app.isTerminated else { return }
            NSApp.yieldActivation(to: app)
            app.activate(from: .current, options: [])
        }
    }
    func validate(_ target: LongScreenshotTarget, region: LongScreenshotRegion) throws {
        try LongScreenshotTargetValidation.validate(snapshot(target, region: region), target: target, region: region,
            ownProcessID: ProcessInfo.processInfo.processIdentifier)
    }

    private func snapshot(_ target: LongScreenshotTarget, region: LongScreenshotRegion) -> LongScreenshotTargetSnapshot {
        guard CGPreflightScreenCaptureAccess() && AXIsProcessTrusted() && CGPreflightPostEventAccess() else {
            return windowSnapshot(target, region: region)
        }
        // 部分正常前台应用会让系统级 AXFocusedApplication 持续返回无法完成或无值。
        // 使用工作空间的前台进程身份，再直接检查该进程窗口；接口缺值不能当成焦点丢失。
        let application = AXUIElementCreateApplication(target.processID)
        AXUIElementSetMessagingTimeout(application, 0.2)
        var focusedFrame: CGRect?
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID {
            var focusedWindow: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
               let focusedWindow, CFGetTypeID(focusedWindow) == AXUIElementGetTypeID() {
                focusedFrame = accessibilityFrame(unsafeDowncast(focusedWindow, to: AXUIElement.self))
            }
        }
        // 辅助功能命中测试穿过系统的透明覆盖窗口，也能发现选区中心的弹出菜单与对话框。
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        let point = CGPoint(x: region.quartzRect.midX, y: region.quartzRect.midY)
        var element = hitTest(system, point)
        if element == nil {
            // 系统级接口可能单独失效，直接询问目标应用补充命中信息。
            element = hitTest(application, point)
        }
        var pid: pid_t = 0
        var hitPID: pid_t?
        var hitFrame: CGRect?
        if let element, AXUIElementGetPid(element, &pid) == .success {
            hitPID = pid
            var windowValue: CFTypeRef?
            if pid == target.processID,
               AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowValue) == .success,
               let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() {
                hitFrame = accessibilityFrame(unsafeDowncast(windowValue, to: AXUIElement.self))
            }
        }
        // 跨进程查询返回后重新核验窗口和前台状态，不能据查询前的旧状态继续采集。
        var snapshot = windowSnapshot(target, region: region)
        snapshot.focusedWindowFrame = focusedFrame
        snapshot.hitProcessID = hitPID
        snapshot.hitWindowFrame = hitFrame
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
    private func accessibilityFrame(_ window: AXUIElement) -> CGRect? {
        AXUIElementSetMessagingTimeout(window, 0.2)
        var position: CFTypeRef?, size: CFTypeRef?
        var origin = CGPoint.zero, dimensions = CGSize.zero
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
            AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
            let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
            AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &origin),
            AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions)
        else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }
    func scroll(_ points: Int, target: LongScreenshotTarget, region: LongScreenshotRegion) throws {
        try Task.checkCancellation()
        try validate(target, region: region)
        try post(points, target: target, region: region)
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

@MainActor enum LongScreenshotScrollEvent {
    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private static let setWindowLocation: SetWindowLocation? = {
        // 系统在直接投递时不会补齐窗口内坐标。按需解析兼容接口；不可用时停止，
        // 不回退到会不断拉回鼠标的全局输入层，也不读取或改写事件序列化数据。
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else { return nil }
        return unsafeBitCast(symbol, to: SetWindowLocation.self)
    }()

    static func make(amount: Int, target: LongScreenshotTarget, location: CGPoint) -> CGEvent? {
        guard amount > 0, amount <= Int(Int32.max),
            location.x.isFinite, location.y.isFinite, target.frame.minX.isFinite, target.frame.minY.isFinite,
            let setWindowLocation,
            let template = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: Int(target.windowID), context: nil,
                eventNumber: 0, clickCount: 0, pressure: 0)?.cgEvent,
            let delta = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                wheel1: -Int32(amount), wheel2: 0, wheel3: 0) else { return nil }
        let event = template
        event.type = .scrollWheel
        for field in [CGEventField.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2, .scrollWheelEventDeltaAxis3,
                      .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventPointDeltaAxis3,
                      .scrollWheelEventIsContinuous] {
            event.setIntegerValueField(field, value: delta.getIntegerValueField(field))
        }
        for field in [CGEventField.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis3] {
            event.setDoubleValueField(field, value: delta.getDoubleValueField(field))
        }
        event.location = location; event.flags = []
        setWindowLocation(event, CGPoint(x: location.x - target.frame.minX, y: location.y - target.frame.minY))
        event.setIntegerValueField(.eventSourceUserData, value: MouseScrollEventAdapter.marker)
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(target.processID))
        return event
    }
}

@MainActor final class LongScreenshotCoordinator {
    enum Phase { case idle, preparing, capturing, stopping }
    private(set) var phase = Phase.idle
    private(set) var target: LongScreenshotTarget?
    var onProgress: ((LongScreenshotStitcher.Progress) -> Void)?
    var onFinish: ((LongScreenshotDocument?, String?, LongScreenshotTarget?) -> Void)?
    var onScrollSuspension: ((Bool) -> Void)?
    private let capture: any LongScreenshotCapturing
    private let scroll: any LongScreenshotScrolling
    private let limits: LongScreenshotLimits
    private let settleInterval: Duration
    private let captureTimeout: Duration
    private let makeStitcher: @Sendable (CGFloat, LongScreenshotLimits) -> any LongScreenshotStitching
    private var task: Task<Void, Never>?
    private var finalizing: Task<Void, Never>?
    private var generation = 0
    private var stopReason: String?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var suspended = false
    private var scrollPump: LongScreenshotScrollPump?
    private let observesSystem: Bool

    init(capture: any LongScreenshotCapturing = SystemLongScreenshotCapture(),
         scroll: any LongScreenshotScrolling = SystemLongScreenshotScroll(),
         limits: LongScreenshotLimits = .init(), settleInterval: Duration = .milliseconds(160), observesSystem: Bool = true,
         captureTimeout: Duration = .seconds(8),
         makeStitcher: @escaping @Sendable (CGFloat, LongScreenshotLimits) -> any LongScreenshotStitching = {
             LongScreenshotStitcher(scale: $0, limits: $1)
         }) {
        self.capture = capture; self.scroll = scroll; self.limits = limits
        self.settleInterval = settleInterval; self.observesSystem = observesSystem
        self.captureTimeout = captureTimeout
        self.makeStitcher = makeStitcher
    }

    func start(_ region: LongScreenshotRegion) {
        guard phase == .idle else { return }
        generation += 1
        let version = generation
        phase = .preparing; stopReason = nil
        suspended = true; onScrollSuspension?(true)
        observeSystem()
        let stitcher = makeStitcher(region.screen.scale, limits)
        task = Task { [weak self] in
            guard let self else { return }
            var reason: String?
            let deadline = ContinuousClock.now.advanced(by: self.limits.maximumDuration)
            do {
                let target = try self.scroll.resolve(region)
                self.target = target
                // 选区退场后立即建立焦点交接基线，不能在异步启动屏幕流后才接受新的前台身份。
                try await self.scroll.prepare(target, region: region)
                try await LongScreenshotOperation.run(timeout: self.captureTimeout) { [capture = self.capture] in
                    try await capture.prepare(region)
                }
                try self.check(version, target: target, region: region, deadline: deadline)
                // 冻结选区已经关闭，从当前真实画面重新建立第一帧。
                let first = try await self.stableFrame(version, target: target, region: region, deadline: deadline)
                try self.check(version, target: target, region: region, deadline: deadline)
                var progress = try await stitcher.append(first)
                try self.check(version, target: target, region: region, deadline: deadline)
                self.phase = .capturing; self.onProgress?(progress)
                if self.capture.capturesContinuously {
                    progress = try await self.captureContinuously(stitcher, progress: progress, version: version,
                        target: target, region: region, deadline: deadline)
                } else {
                    var unchanged = 0
                    while !progress.reachedLimit {
                        try self.check(version, target: target, region: region, deadline: deadline)
                        try self.scroll.scroll(max(1, Int(region.selection.height / 4)), target: target, region: region)
                        try await Task.sleep(for: self.settleInterval)
                        progress = try await self.appendNextFrame(stitcher, version: version, target: target,
                            region: region, deadline: deadline)
                        try self.check(version, target: target, region: region, deadline: deadline)
                        self.onProgress?(progress)
                        unchanged = progress.added == 0 ? unchanged + 1 : 0
                        if unchanged >= 3 { break }
                    }
                }
                if progress.reachedLimit { reason = LongScreenshotError.capacity.localizedDescription }
            } catch is CancellationError {
                reason = self.stopReason
            } catch { reason = error.localizedDescription }
            guard self.generation == version else { return }
            self.phase = .stopping
            self.capture.release()
            self.restoreScroll()
            self.removeObservers()
            // 独立收尾任务不继承停止时的取消状态，仍可交付此前可靠内容。
            self.finalizing = Task { [weak self] in
                do {
                    let document = try await stitcher.finish()
                    guard let self, self.generation == version else { return }
                    let target = self.target
                    self.phase = .idle; self.target = nil; self.task = nil; self.finalizing = nil
                    self.onFinish?(document, reason, target)
                } catch {
                    guard let self, self.generation == version else { return }
                    self.phase = .idle; self.target = nil; self.task = nil; self.finalizing = nil
                    self.onFinish?(nil, error.localizedDescription, nil)
                }
            }
        }
    }

    private func check(_ version: Int, target: LongScreenshotTarget, region: LongScreenshotRegion,
                       deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard generation == version, phase != .idle, phase != .stopping else { throw CancellationError() }
        guard ContinuousClock.now < deadline else { throw LongScreenshotError.timeout }
        try scroll.validate(target, region: region)
    }

    private func stableFrame(_ version: Int, target: LongScreenshotTarget, region: LongScreenshotRegion,
                             deadline: ContinuousClock.Instant) async throws -> CGImage {
        var previous: LongScreenshotFeatures?
        for _ in 0..<10 {
            try check(version, target: target, region: region, deadline: deadline)
            let image = try await LongScreenshotOperation.run(timeout: captureTimeout) { [capture] in
                try await capture.capture()
            }
            try check(version, target: target, region: region, deadline: deadline)
            let features = try await LongScreenshotFeatureWorker.shared.features(image)
            try check(version, target: target, region: region, deadline: deadline)
            if let previous, previous.isStable(comparedTo: features) { return image }
            previous = features
            try await Task.sleep(for: settleInterval)
        }
        throw LongScreenshotError.unstable
    }

    private func appendNextFrame(_ stitcher: any LongScreenshotStitching, version: Int, target: LongScreenshotTarget,
                                 region: LongScreenshotRegion, deadline: ContinuousClock.Instant) async throws -> LongScreenshotStitcher.Progress {
        for attempt in 0..<3 {
            let image = try await stableFrame(version, target: target, region: region, deadline: deadline)
            try check(version, target: target, region: region, deadline: deadline)
            do { return try await stitcher.append(image) }
            catch LongScreenshotError.overlap where attempt < 2 {
                // 虚拟列表、图片懒加载和悬停预览可能晚于滚动稳定。
                // 只在原位置重取画面，不继续滚动，也不将失败画面写入长图。
                try await Task.sleep(for: max(settleInterval, .milliseconds(150)))
            }
        }
        throw LongScreenshotError.overlap
    }

    private func captureContinuously(_ stitcher: any LongScreenshotStitching, progress initial: LongScreenshotStitcher.Progress,
                                    version: Int, target: LongScreenshotTarget, region: LongScreenshotRegion,
                                    deadline: ContinuousClock.Instant) async throws -> LongScreenshotStitcher.Progress {
        let pump = LongScreenshotScrollPump(viewportHeight: region.selection.height) { [scroll] points in
            try scroll.scrollStep(points, target: target, region: region)
        }
        scrollPump = pump
        pump.start()
        defer { pump.stop(); if scrollPump === pump { scrollPump = nil } }
        var progress = initial
        var lastAddition = ContinuousClock.now
        var mismatchSince: ContinuousClock.Instant?
        var unchanged = 0
        while !progress.reachedLimit {
            try await Task.sleep(for: .milliseconds(80))
            try check(version, target: target, region: region, deadline: deadline)
            if let error = pump.failure { throw error }
            let image = try await LongScreenshotOperation.run(timeout: captureTimeout) { [capture] in
                try await capture.capture()
            }
            do {
                progress = try await stitcher.append(image)
            } catch LongScreenshotError.overlap {
                // 画面尚在合成或虚拟列表迟到时，先停滚并复用上次可靠参考帧。
                // 期间屏幕流继续更新，既不追加失败帧，也不扩大未确认的距离。
                pump.paused = true
                if mismatchSince == nil { mismatchSince = .now }
                if let mismatchSince, mismatchSince.duration(to: .now) >= .milliseconds(1200) { throw LongScreenshotError.overlap }
                continue
            }
            try check(version, target: target, region: region, deadline: deadline)
            if progress.added > 0 {
                pump.acknowledge(CGFloat(progress.added) / region.screen.scale)
                lastAddition = .now; unchanged = 0; mismatchSince = nil; pump.paused = false
            } else {
                unchanged += 1
                if let mismatchSince, mismatchSince.duration(to: .now) >= .milliseconds(1200) { throw LongScreenshotError.overlap }
                if mismatchSince == nil, unchanged >= 5, lastAddition.duration(to: .now) >= .seconds(1) { break }
            }
            onProgress?(progress)
        }
        return progress
    }

    func stop(reason: String? = nil) {
        guard phase == .capturing || phase == .preparing else { return }
        stopReason = reason
        phase = .stopping
        scrollPump?.stop()
        task?.cancel()
        restoreScroll()
    }
    func cancel() {
        generation += 1
        scrollPump?.stop(); scrollPump = nil
        task?.cancel(); task = nil
        finalizing?.cancel(); finalizing = nil
        capture.release(); restoreScroll(); removeObservers()
        phase = .idle; target = nil
    }
    private func restoreScroll() {
        if suspended { suspended = false; onScrollSuspension?(false) }
    }
    private func observeSystem() {
        guard observesSystem else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification] {
            addObserver(name, center: workspace)
        }
        addObserver(NSApplication.didChangeScreenParametersNotification, center: .default)
        addObserver(Notification.Name("com.apple.screenIsLocked"), center: DistributedNotificationCenter.default())
    }
    private func addObserver(_ name: Notification.Name, center: NotificationCenter) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop(reason: LongScreenshotError.targetChanged.localizedDescription) }
        }
        observers.append((center, token))
    }
    private func removeObservers() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }
}

actor LongScreenshotFeatureWorker {
    static let shared = LongScreenshotFeatureWorker()
    func features(_ image: CGImage) async throws -> LongScreenshotFeatures {
        let cost = image.height * (min(96, image.width) + min(384, image.width)) * 3
        return try await ImageWorkBudget.shared.withPermit(estimatedBytes: cost, priority: .display) {
            try await self.makeFeatures(image)
        }
    }
    private func makeFeatures(_ image: CGImage) throws -> LongScreenshotFeatures { try LongScreenshotFeatures(image) }
}
