import AppKit
import ApplicationServices
import Foundation
import Testing
import os

@testable import PasteMan

/// 仅为合成接收进程复制系统已路由的事件，不收集其他应用的输入。
private final class MouseEventTemplateCapture: @unchecked Sendable {
    private let targetPID: Int32
    private let latest = OSAllocatedUnfairLock(uncheckedState: Optional<CGEvent>.none)
    init(targetPID: Int32) { self.targetPID = targetPID }
    var template: CGEvent? { latest.withLockUnchecked { $0?.copy() } }

    func receive(_ event: CGEvent) {
        guard event.getIntegerValueField(.eventTargetUnixProcessID) == Int64(targetPID) else { return }
        latest.withLockUnchecked { $0 = event.copy() }
    }

    @MainActor func install() throws -> CFMachPort {
        let callback: CGEventTapCallBack = { _, type, event, context in
            if type == .scrollWheel, let context {
                Unmanaged<MouseEventTemplateCapture>.fromOpaque(context).takeUnretainedValue().receive(event)
            }
            return Unmanaged.passUnretained(event)
        }
        let tap = try #require(CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(1) << CGEventType.scrollWheel.rawValue,
            callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()))
        let source = try #require(CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0))
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        return tap
    }
}

@Suite("鼠标跨进程滚动", .serialized) @MainActor struct MouseScrollDeliveryTests {
    /// 仅明确设置环境变量时安装真实接管，事件发送到临时合成窗口。
    @Test func realTapSmoothsDiscreteWheelsAndPassesNativeAndExcludedEvents() async throws {
        guard ProcessInfo.processInfo.environment["EASYMACOS_MOUSE_LIVE"] == "1" else { return }
        try #require(AXIsProcessTrusted() && CGPreflightPostEventAccess(), "需要测试进程已有辅助功能权限，不请求授权。")
        _ = NSApplication.shared
        let previous = NSWorkspace.shared.frontmostApplication
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MouseDelivery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ready = directory.appendingPathComponent("ready.json")
        let results = directory.appendingPathComponent("events.json")
        let receiver = Process()
        receiver.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/mouse-recipient.swift")
        receiver.arguments = [script.path, ready.path, results.path]
        let driver = SystemMouseScrollDriver()
        try receiver.run()
        defer {
            driver.stop()
            if receiver.isRunning { receiver.terminate() }
            previous?.activate()
            try? FileManager.default.removeItem(at: directory)
        }
        for _ in 0..<250 {
            if FileManager.default.fileExists(atPath: ready.path) || !receiver.isRunning { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let info = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: ready)) as? [String: NSNumber])
        let pid = try #require(info["pid"]?.int32Value)
        let point = CGPoint(x: try #require(info["x"]?.doubleValue), y: try #require(info["y"]?.doubleValue))
        let apps = [pid: "test.synthetic.mouse"]
        let capture = MouseEventTemplateCapture(targetPID: pid)
        let captureTap = try capture.install()
        defer { CFMachPortInvalidate(captureTap) }
        func tapCount() -> Int {
            var count: UInt32 = 0
            guard CGGetEventTapList(0, nil, &count) == .success else { return -1 }
            var taps = Array(repeating: CGEventTapInformation(), count: Int(count))
            guard CGGetEventTapList(count, &taps, &count) == .success else { return -1 }
            return taps.prefix(Int(count)).filter {
                $0.tappingProcess == ProcessInfo.processInfo.processIdentifier
                    && $0.eventsOfInterest == CGEventMask(1) << CGEventType.scrollWheel.rawValue
            }.count
        }
        let originalTapCount = tapCount()
        var configuration = MouseScrollConfiguration()
        configuration.enabled = true
        var state: MouseScrollDriverStatus?
        driver.start(configuration: configuration, applications: apps) { state = $0 }
        for _ in 0..<100 {
            if state != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(state == .running, "系统未成功创建并启用事件接管。")
        #expect(tapCount() == originalTapCount + 1)
        try await Task.sleep(for: .milliseconds(100))

        func events() -> [[String: Any]] {
            guard let data = try? Data(contentsOf: results),
                let values = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
            return values
        }
        func post(amount: Int32 = 8, precise: Bool = false, phase: Int64 = 0, direct: Bool = false) throws {
            let event: CGEvent
            if direct {
                // 进程直接投递不负责窗口路由，沿用合成窗口已收到的事件元数据。
                let template = try #require(capture.template)
                event = try #require(MouseScrollEventAdapter.output(MouseScrollVector(y: Double(amount)), template: template))
                let source = try #require(CGEventSource(stateID: .privateState))
                source.userData = 0
                event.setSource(source)
                event.setIntegerValueField(.eventSourceUserData, value: 0)
            } else {
                event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
                                             wheelCount: 2, wheel1: amount, wheel2: 0, wheel3: 0))
                event.location = point
            }
            event.flags = []
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            if direct { event.postToPid(pid) }
            else { event.post(tap: .cgSessionEventTap) }
        }
        try post()
        try await Task.sleep(for: .milliseconds(500))
        let smoothed = events()
        try #require(smoothed.count > 1, "离散滚轮没有转换成多个平滑事件，需检查实际接收进程。")
        #expect(smoothed.allSatisfy { ($0["precise"] as? Bool) == true })
        #expect(smoothed.allSatisfy { ($0["marker"] as? NSNumber)?.int64Value == MouseScrollEventAdapter.marker })
        let distance = smoothed.reduce(0.0) { $0 + (($1["y"] as? NSNumber)?.doubleValue ?? 0) }
        #expect(abs(distance - 80) <= 1)

        for amount: Int32 in [1, -1] {
            let beforeSmall = events().count
            try post(amount: amount)
            try await Task.sleep(for: .milliseconds(250))
            let small = Array(events().dropFirst(beforeSmall))
            #expect(small.count > 1)
            #expect(small.allSatisfy { ($0["precise"] as? Bool) == true })
            let distance = small.reduce(0.0) { $0 + (($1["y"] as? NSNumber)?.doubleValue ?? 0) }
            #expect(abs(distance - Double(amount) * configuration.minimumStep) < 1)
            #expect(small.allSatisfy { ($0["marker"] as? NSNumber)?.int64Value == MouseScrollEventAdapter.marker })
        }

        let count = events().count
        try post(precise: true)
        try await Task.sleep(for: .milliseconds(250))
        let native = Array(events().dropFirst(count))
        #expect(native.count == 1 && (native.first?["y"] as? NSNumber)?.doubleValue == 8)
        #expect((native.first?["marker"] as? NSNumber)?.int64Value != MouseScrollEventAdapter.marker)

        configuration.remoteCompatibility = true
        configuration.reversed = true
        configuration.speed = 2.2
        driver.update(configuration: configuration, applications: apps)
        try await Task.sleep(for: .milliseconds(50))
        let beforeRemote = events().count
        try post(amount: 24, precise: true, direct: true)
        try await Task.sleep(for: .milliseconds(350))
        let remote = Array(events().dropFirst(beforeRemote))
        #expect(remote.count > 1)
        #expect(remote.allSatisfy { ($0["marker"] as? NSNumber)?.int64Value == MouseScrollEventAdapter.marker })
        let remoteDistance = remote.reduce(0.0) { $0 + (($1["y"] as? NSNumber)?.doubleValue ?? 0) }
        #expect(abs(remoteDistance + configuration.minimumStep * 2.2) < 1)

        for amount: Int32 in [8, -8] {
            let beforeSmallRemote = events().count
            try post(amount: amount, precise: true, direct: true)
            try await Task.sleep(for: .milliseconds(250))
            let smallRemote = Array(events().dropFirst(beforeSmallRemote))
            #expect(smallRemote.count > 1)
            #expect(smallRemote.allSatisfy { ($0["precise"] as? Bool) == true })
            let distance = smallRemote.reduce(0.0) { $0 + (($1["y"] as? NSNumber)?.doubleValue ?? 0) }
            #expect(abs(distance + (amount < 0 ? -1 : 1) * configuration.minimumStep * 2.2) < 1)
            #expect(smallRemote.allSatisfy { ($0["marker"] as? NSNumber)?.int64Value == MouseScrollEventAdapter.marker })
        }

        let beforeGesture = events().count
        try post(precise: true, phase: 4)
        try await Task.sleep(for: .milliseconds(200))
        let gesture = Array(events().dropFirst(beforeGesture))
        #expect(gesture.count == 1 && (gesture.first?["y"] as? NSNumber)?.doubleValue == 8)
        #expect((gesture.first?["marker"] as? NSNumber)?.int64Value != MouseScrollEventAdapter.marker)

        configuration.excludedApps = ["test.synthetic.mouse"]
        driver.update(configuration: configuration, applications: apps)
        try await Task.sleep(for: .milliseconds(50))
        let beforeExcluded = events().count
        try post()
        try await Task.sleep(for: .milliseconds(250))
        let excluded = Array(events().dropFirst(beforeExcluded))
        #expect(excluded.count == 1 && (excluded.first?["precise"] as? Bool) == false)
        let beforeExcludedRemote = events().count
        try post(precise: true, direct: true)
        try await Task.sleep(for: .milliseconds(200))
        let excludedRemote = Array(events().dropFirst(beforeExcludedRemote))
        #expect(excludedRemote.count == 1 && (excludedRemote.first?["y"] as? NSNumber)?.doubleValue == 8)

        driver.stop()
        try await Task.sleep(for: .milliseconds(50))
        let beforeStopped = events().count
        try post()
        try await Task.sleep(for: .milliseconds(250))
        let stopped = Array(events().dropFirst(beforeStopped))
        #expect(stopped.count == 1 && (stopped.first?["precise"] as? Bool) == false)
        #expect(tapCount() == originalTapCount)

        configuration.excludedApps = []
        configuration.smooth = false
        configuration.reversed = true
        configuration.speed = 2
        state = nil
        driver.start(configuration: configuration, applications: apps) { state = $0 }
        for _ in 0..<100 {
            if state != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(state == .running)
        let beforeImmediate = events().count
        try post()
        try await Task.sleep(for: .milliseconds(250))
        let immediate = Array(events().dropFirst(beforeImmediate))
        #expect(immediate.count == 1 && (immediate.first?["precise"] as? Bool) == false)
        // 非连续事件的 scrollingDeltaY 由接收端以原生行单位报告。
        #expect((immediate.first?["y"] as? NSNumber)?.doubleValue == -16)
        let beforeImmediateRemote = events().count
        try post(precise: true, direct: true)
        try await Task.sleep(for: .milliseconds(200))
        let immediateRemote = Array(events().dropFirst(beforeImmediateRemote))
        #expect(immediateRemote.count == 1 && (immediateRemote.first?["precise"] as? Bool) == true)
        #expect((immediateRemote.first?["y"] as? NSNumber)?.doubleValue == -16)
        driver.stop()
        try await Task.sleep(for: .milliseconds(50))
        #expect(tapCount() == originalTapCount)
    }
}
