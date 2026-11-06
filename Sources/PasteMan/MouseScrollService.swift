import AppKit
@preconcurrency import ApplicationServices
import Observation
import os

enum MouseScrollDriverStatus: Sendable { case running, permissionRequired, failed }

private final class MouseScrollObservations {
    private var subscriptions: [(NotificationCenter, NSObjectProtocol)] = []
    func add(_ token: NSObjectProtocol, to center: NotificationCenter) { subscriptions.append((center, token)) }
    func clear() {
        for (center, token) in subscriptions { center.removeObserver(token) }
        subscriptions.removeAll()
    }
    deinit { clear() }
}

@MainActor protocol MouseScrollDriving: AnyObject {
    func start(
        configuration: MouseScrollConfiguration, applications: [Int32: String],
        status: @escaping @MainActor @Sendable (MouseScrollDriverStatus) -> Void)
    func update(configuration: MouseScrollConfiguration, applications: [Int32: String])
    func cancelAnimation()
    func stop()
}

@MainActor @Observable final class MouseScrollService {
    enum Status { case disabled, starting, running, permissionRequired, failed, paused }
    private(set) var status = Status.disabled
    @ObservationIgnored private let driver: any MouseScrollDriving
    @ObservationIgnored private let hasPermission: () -> Bool
    @ObservationIgnored private var configuration: MouseScrollConfiguration
    @ObservationIgnored private var started = false
    @ObservationIgnored private var driverActive = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var inactiveReasons: Set<String> = []
    @ObservationIgnored private let observations = MouseScrollObservations()
    @ObservationIgnored private let observesWorkspace: Bool

    init(
        configuration: MouseScrollConfiguration = .init(),
        driver: any MouseScrollDriving = SystemMouseScrollDriver(),
        hasPermission: @escaping () -> Bool = { AXIsProcessTrusted() && CGPreflightPostEventAccess() },
        observesWorkspace: Bool = true
    ) {
        self.configuration = configuration.normalized
        self.driver = driver
        self.hasPermission = hasPermission
        self.observesWorkspace = observesWorkspace
    }

    func start() {
        guard !started else { return }
        started = true
        if observesWorkspace {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                observations.add(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateApplications() }
                }, to: center)
            }
            observations.add(center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.driver.cancelAnimation() }
            }, to: center)
            observations.add(NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }, to: .default)
        }
        reconcile()
    }

    func apply(_ configuration: MouseScrollConfiguration) {
        let next = configuration.normalized
        guard self.configuration != next else { return }
        self.configuration = next
        if driverActive { driver.update(configuration: next, applications: applications) }
        reconcile()
    }

    func refresh() { reconcile() }

    func setSessionActive(_ active: Bool, reason: String) {
        if active { inactiveReasons.remove(reason) } else { inactiveReasons.insert(reason) }
        reconcile()
    }

    func stop() {
        started = false
        stopDriver()
        observations.clear()
        status = .disabled
    }

    private var applications: [Int32: String] {
        guard observesWorkspace else { return [:] }
        return Dictionary(NSWorkspace.shared.runningApplications.compactMap { app in
            app.bundleIdentifier.map { (app.processIdentifier, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }

    private func updateApplications() {
        if driverActive { driver.update(configuration: configuration, applications: applications) }
    }

    private func stopDriver() {
        generation += 1
        if driverActive { driver.stop() }
        driverActive = false
    }

    private func reconcile() {
        guard started, configuration.enabled else {
            stopDriver()
            status = .disabled
            return
        }
        guard inactiveReasons.isEmpty else {
            stopDriver()
            status = .paused
            return
        }
        guard hasPermission() else {
            stopDriver()
            status = .permissionRequired
            return
        }
        guard !driverActive else { return }
        generation += 1
        let ticket = generation
        driverActive = true
        status = .starting
        driver.start(configuration: configuration, applications: applications) { [weak self] result in
            guard let self, self.generation == ticket, self.driverActive else { return }
            switch result {
            case .running: self.status = .running
            case .permissionRequired:
                self.stopDriver()
                self.status = .permissionRequired
            case .failed:
                self.stopDriver()
                self.status = .failed
            }
        }
    }
}

@MainActor final class SystemMouseScrollDriver: MouseScrollDriving {
    private var worker: MouseScrollWorker?
    deinit { worker?.stop() }

    func start(
        configuration: MouseScrollConfiguration, applications: [Int32: String],
        status: @escaping @MainActor @Sendable (MouseScrollDriverStatus) -> Void
    ) {
        stop()
        let worker = MouseScrollWorker(configuration: configuration, applications: applications) { result in
            Task { @MainActor in status(result) }
        }
        self.worker = worker
        worker.start()
    }

    func update(configuration: MouseScrollConfiguration, applications: [Int32: String]) {
        worker?.update(configuration: configuration, applications: applications)
    }

    func cancelAnimation() { worker?.cancelAnimation() }
    func stop() {
        worker?.stop()
        worker = nil
    }
}

/// 系统事件转换与字段缩放可独立测试，不安装接管点或回注事件。
struct MouseScrollEventAdapter {
    static let marker: Int64 = 0x454D_5343_524F_4C4C
    private var context: MouseScrollInput.Context?
    private var lineX = MouseScrollQuantizer()
    private var lineY = MouseScrollQuantizer()
    private var pointX = MouseScrollQuantizer()
    private var pointY = MouseScrollQuantizer()

    static func input(_ event: CGEvent, applications: [Int32: String]) -> MouseScrollInput {
        let rawPID = event.getIntegerValueField(.eventTargetUnixProcessID)
        let pid = Int32(exactly: rawPID) ?? 0
        func pixels(_ point: CGEventField, _ fixed: CGEventField, _ line: CGEventField) -> Double {
            let value = event.getIntegerValueField(point)
            if value != 0 { return Double(value) }
            let fractional = event.getDoubleValueField(fixed)
            if fractional != 0 { return fractional * 10 }
            return Double(event.getIntegerValueField(line)) * 10
        }
        return MouseScrollInput(
            delta: MouseScrollVector(
                x: pixels(.scrollWheelEventPointDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventDeltaAxis2),
                y: pixels(.scrollWheelEventPointDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventDeltaAxis1)),
            targetPID: pid,
            targetWindow: event.getIntegerValueField(.mouseEventWindowUnderMousePointer),
            targetBundleID: applications[pid], flags: event.flags.rawValue,
            continuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
            hasPhase: event.getIntegerValueField(.scrollWheelEventScrollPhase) != 0
                || event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0,
            hasOtherAxis: event.getIntegerValueField(.scrollWheelEventDeltaAxis3) != 0
                || event.getIntegerValueField(.scrollWheelEventPointDeltaAxis3) != 0
                || event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis3) != 0,
            generated: event.getIntegerValueField(.eventSourceUserData) == marker,
            commandOrControl: !event.flags.intersection([.maskCommand, .maskControl]).isEmpty)
    }

    mutating func scale(_ event: CGEvent, input: MouseScrollInput, multiplier: Double) {
        if context != input.context {
            self = Self()
            context = input.context
        }
        guard multiplier != 1 else { return }
        // 写行位移会连带改写像素和小数字段，必须先捕获所有原始值。
        let originalLineY = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let originalLineX = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let originalPointY = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let originalPointX = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        let originalFixedY = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let originalFixedX = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: lineY.scale(
            originalLineY, by: multiplier))
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: lineX.scale(
            originalLineX, by: multiplier))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: pointY.scale(
            originalPointY, by: multiplier))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: pointX.scale(
            originalPointX, by: multiplier))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: originalFixedY * multiplier)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: originalFixedX * multiplier)
    }

    static func output(_ delta: MouseScrollVector, template: CGEvent) -> CGEvent? {
        guard delta.x.isFinite, delta.y.isFinite,
            abs(delta.x) <= Double(Int32.max), abs(delta.y) <= Double(Int32.max),
            let source = CGEventSource(stateID: .privateState),
            let pixels = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: Int32(delta.y), wheel2: Int32(delta.x), wheel3: 0),
            let event = template.copy()
        else { return nil }
        // 从模板复制只读的目标窗口元数据，位移使用系统创建的像素事件。
        for field in [CGEventField.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2, .scrollWheelEventDeltaAxis3] {
            event.setIntegerValueField(field, value: pixels.getIntegerValueField(field))
        }
        for field in [CGEventField.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis3] {
            event.setDoubleValueField(field, value: pixels.getDoubleValueField(field))
        }
        for field in [CGEventField.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2,
                      .scrollWheelEventPointDeltaAxis3, .scrollWheelEventIsContinuous,
                      .scrollWheelEventScrollPhase, .scrollWheelEventMomentumPhase] {
            event.setIntegerValueField(field, value: pixels.getIntegerValueField(field))
        }
        event.timestamp = pixels.timestamp
        // 直接投递会重新写入来源信息，独立来源和字段都必须标记，防止远程输入回注循环。
        source.userData = marker
        event.setSource(source)
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        return event
    }
}

/// 可变事件状态仅由专用线程访问；跨线程命令及运行循环引用由 control 锁保护。
private final class MouseScrollWorker: @unchecked Sendable {
    // CoreFoundation 的引用未声明可发送；这些运行循环操作本身支持跨线程调用。
    private struct RunLoopHandle: @unchecked Sendable { let value: CFRunLoop }
    private struct Control {
        var loop: RunLoopHandle?
        var stopped = false
        var configuration: MouseScrollConfiguration
        var applications: [Int32: String]
    }
    private let control: OSAllocatedUnfairLock<Control>
    private let report: @Sendable (MouseScrollDriverStatus) -> Void
    private var processor: MouseScrollProcessor
    private var applications: [Int32: String]
    private var adapter = MouseScrollEventAdapter()
    private var permissionGate = MouseScrollPermissionGate()
    private var tap: CFMachPort?
    private var timer: CFRunLoopTimer?
    private var template: CGEvent?
    private var timeoutCount = 0
    private var lastTimeout = 0.0

    init(
        configuration: MouseScrollConfiguration, applications: [Int32: String],
        report: @escaping @Sendable (MouseScrollDriverStatus) -> Void
    ) {
        control = OSAllocatedUnfairLock(uncheckedState: Control(
            configuration: configuration, applications: applications))
        processor = MouseScrollProcessor(configuration: configuration, ownPID: ProcessInfo.processInfo.processIdentifier)
        self.applications = applications
        self.report = report
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "EasyMacOS.MouseScroll"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func update(configuration: MouseScrollConfiguration, applications: [Int32: String]) {
        control.withLock {
            $0.configuration = configuration
            $0.applications = applications
        }
        enqueue { worker in
            let snapshot = worker.control.withLock { ($0.configuration, $0.applications) }
            worker.cancel()
            worker.processor.configure(snapshot.0)
            worker.applications = snapshot.1
        }
    }

    func cancelAnimation() { enqueue { $0.cancel() } }

    func stop() {
        let loop = control.withLock { state in
            state.stopped = true
            return state.loop
        }
        if let loop {
            CFRunLoopPerformBlock(loop.value, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(loop.value) }
            CFRunLoopWakeUp(loop.value)
        }
    }

    private func enqueue(_ action: @escaping @Sendable (MouseScrollWorker) -> Void) {
        guard let loop = control.withLock({ $0.stopped ? nil : $0.loop }) else { return }
        CFRunLoopPerformBlock(loop.value, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            if let self, !self.control.withLock({ $0.stopped }) { action(self) }
        }
        CFRunLoopWakeUp(loop.value)
    }

    private func run() {
        autoreleasepool {
            let loop = CFRunLoopGetCurrent()!
            let handle = RunLoopHandle(value: loop)
            guard control.withLock({ state in
                guard !state.stopped else { return false }
                state.loop = handle
                processor.configure(state.configuration)
                applications = state.applications
                return true
            }) else { return }
            defer {
                cancel()
                if let tap { CFMachPortInvalidate(tap) }
                tap = nil
                control.withLock { $0.loop = nil }
            }
            guard permissionGate.allows(at: ProcessInfo.processInfo.systemUptime, force: true, check: {
                AXIsProcessTrusted() && CGPreflightPostEventAccess()
            }) else {
                report(.permissionRequired)
                return
            }
            let callback: CGEventTapCallBack = { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                return Unmanaged<MouseScrollWorker>.fromOpaque(userInfo).takeUnretainedValue()
                    .handle(type: type, event: event)
            }
            guard let port = CGEvent.tapCreate(
                tap: .cgAnnotatedSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: CGEventMask(1) << CGEventType.scrollWheel.rawValue,
                callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()),
                let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            else {
                report(.failed)
                return
            }
            tap = port
            CFRunLoopAddSource(loop, source, .commonModes)
            defer { CFRunLoopRemoveSource(loop, source, .commonModes) }
            CGEvent.tapEnable(tap: port, enable: true)
            guard CGEvent.tapIsEnabled(tap: port) else {
                report(.failed)
                return
            }
            if control.withLock({ $0.stopped }) { return }
            report(.running)
            CFRunLoopRun()
        }
    }

    private func cancel() {
        timer.map(CFRunLoopTimerInvalidate)
        timer = nil
        template = nil
        processor.cancel()
        adapter = MouseScrollEventAdapter()
    }

    private func fail() {
        cancel()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        report(AXIsProcessTrusted() && CGPreflightPostEventAccess() ? .failed : .permissionRequired)
        CFRunLoopStop(CFRunLoopGetCurrent())
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard !control.withLock({ $0.stopped }) else { return Unmanaged.passUnretained(event) }
        if type == .tapDisabledByTimeout {
            cancel()
            let now = ProcessInfo.processInfo.systemUptime
            timeoutCount = now - lastTimeout < 1 ? timeoutCount + 1 : 1
            lastTimeout = now
            if timeoutCount < 3, permissionGate.allows(at: now, force: true, check: {
                AXIsProcessTrusted() && CGPreflightPostEventAccess()
            }), let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                if !CGEvent.tapIsEnabled(tap: tap) { fail() }
            } else { fail() }
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByUserInput {
            fail()
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
        // 自生成事件不需要读取其余滚轮字段，也不能清除尚未结束的动画。
        if event.getIntegerValueField(.eventSourceUserData) == MouseScrollEventAdapter.marker {
            return Unmanaged.passUnretained(event)
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard permissionGate.allows(at: now, check: { AXIsProcessTrusted() && CGPreflightPostEventAccess() }) else {
            fail()
            return Unmanaged.passUnretained(event)
        }
        let input = MouseScrollEventAdapter.input(event, applications: applications)
        switch processor.receive(input, at: ProcessInfo.processInfo.systemUptime) {
        case .passThrough:
            cancel()
            return Unmanaged.passUnretained(event)
        case .immediate:
            adapter.scale(event, input: input, multiplier: processor.configuration.multiplier)
            return Unmanaged.passUnretained(event)
        case .smooth:
            guard let copy = event.copy() else {
                cancel()
                return Unmanaged.passUnretained(event)
            }
            template = copy
            if timer == nil {
                let timer = CFRunLoopTimerCreateWithHandler(
                    kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 1 / 120, 1 / 120, 0, 0
                ) { [weak self] _ in self?.tick() }
                self.timer = timer
                CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
            }
            return nil
        }
    }

    private func tick() {
        guard !control.withLock({ $0.stopped }), let tap, CGEvent.tapIsEnabled(tap: tap) else {
            cancel()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard permissionGate.allows(at: now, check: { AXIsProcessTrusted() && CGPreflightPostEventAccess() }) else {
            fail()
            return
        }
        let delta = processor.sample(at: ProcessInfo.processInfo.systemUptime)
        if !delta.isZero, let template {
            guard let output = MouseScrollEventAdapter.output(delta, template: template) else {
                fail()
                return
            }
            // 固定接收进程，避免动画余量随光标进入另一个应用。
            let pid = Int32(exactly: template.getIntegerValueField(.eventTargetUnixProcessID)) ?? 0
            if pid > 0 { output.postToPid(pid) }
        }
        if !processor.hasPending {
            timer.map(CFRunLoopTimerInvalidate)
            timer = nil
            template = nil
        }
    }
}
