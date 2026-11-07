import AppKit
import Darwin
import PasteManCore
import SwiftUI
import Testing

@testable import PasteMan

@MainActor private final class ReleasedObjects {
    private struct Reference {
        let name: String
        weak var object: AnyObject?
    }
    private var references: [Reference] = []
    func watch(_ object: AnyObject, _ name: String) {
        references.append(Reference(name: name, object: object))
    }
    var survivors: [String] { references.compactMap { $0.object == nil ? nil : $0.name } }

    func verify() async throws {
        // Allow completed tasks, SwiftUI updates and AppKit autoreleases to drain.
        do { try await waitUntil { self.survivors.isEmpty } }
        catch {
            Issue.record("未释放对象：\(survivors.joined(separator: "、"))")
            throw error
        }
    }
}

@MainActor private func waitUntil(_ ready: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !ready(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(ready(), "等待任务结束或对象释放超时")
}

private func syntheticImage(width: Int, height: Int) throws -> CGImage {
    try autoreleasepool {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Touch the full allocation; an untouched zero buffer understates physical memory.
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
}

@MainActor private struct SyntheticCapture: ScreenCapturing {
    func capture(_ screens: [ScreenshotScreen]) async throws -> [CapturedScreen] {
        try screens.map { screen in
            CapturedScreen(screen: screen, image: try syntheticImage(
                width: Int(screen.frame.width), height: Int(screen.frame.height)))
        }
    }
}

@MainActor private final class PendingCapture: ScreenCapturing {
    var continuation: CheckedContinuation<[CapturedScreen], any Error>?
    func capture(_ screens: [ScreenshotScreen]) async throws -> [CapturedScreen] {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
}

@MainActor private final class MemoryClipboard: ClipboardReading, ClipboardPermissionChecking {
    var changeCount = 0
    var types: Set<String> = []
    var allowsMonitoring = true
    func refreshClipboard() {}
    func capture(expectedChangeCount: Int) -> ClipboardSnapshot? { nil }
}

@MainActor private final class MemoryFixture {
    let directory: URL
    let suite: String
    let defaults: UserDefaults
    let store: HistoryStore
    let model: AppModel
    let panel: HistoryPanel
    let keys: HotKeyService
    let coordinator: ScreenshotCoordinator

    init() throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("EasyMacOS-memory-" + UUID().uuidString)
        suite = "EasyMacOS.Memory." + UUID().uuidString
        defaults = try #require(UserDefaults(suiteName: suite))
        store = try HistoryStore(directory: directory)
        keys = HotKeyService()
        model = AppModel(repository: store, settings: AppSettings(defaults: defaults),
                         permissions: PermissionService(), hotKeys: keys)
        panel = HistoryPanel()
        coordinator = ScreenshotCoordinator(
            captureService: SyntheticCapture(), pins: PinnedScreenshotManager(presentWindow: { _ in }),
            presentWindow: { _ in })
    }

    func seed() async throws {
        try await store.save(.text(String(repeating: "合成预览文本\n", count: 1_000)),
                             sourceBundleID: "test.memory", sourceName: "内存验证", policy: RetentionPolicy())
        let content = try autoreleasepool {
            try ImageProcessor.prepare(ScreenshotRenderer.encode(syntheticImage(width: 960, height: 540)))
        }
        try await store.save(content, sourceBundleID: "test.memory", sourceName: "内存验证", policy: RetentionPolicy())
    }

    func close() {
        coordinator.cancel()
        coordinator.pins.closeAll()
        coordinator.onCopy = nil
        panel.contentView = nil
        panel.close()
        model.cancelRefresh()
        model.preview = nil
        keys.stop()
        ThumbnailCache.shared.removeAll()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    func historyCycle(index: Int, probes: ReleasedObjects) async throws {
        model.search = ""
        model.panelVisible = true
        model.refresh()
        try await waitUntil { !self.model.loading }
        try #require(model.entries.count == 2)
        switch index % 3 {
        case 1: model.preview = model.entries.first(where: { $0.kind == .image })
        case 2: model.preview = model.entries.first(where: { $0.kind == .text })
        default: model.preview = nil
        }
        autoreleasepool {
            let hosting = NSHostingView(rootView: HistoryView(model: model))
            hosting.frame = CGRect(x: 0, y: 0, width: 440, height: 590)
            probes.watch(hosting, "历史预览视图")
            panel.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
        }
        // Offscreen layout still runs the real text/image preview tasks.
        try await Task.sleep(for: .milliseconds(30))
        if index % 3 == 2 {
            try await waitUntil { self.panel.contentView.flatMap(findTextView) != nil }
        }
        try autoreleasepool {
            panel.contentView?.layoutSubtreeIfNeeded()
            if index % 3 == 2 {
                let text = try #require(panel.contentView.flatMap(findTextView))
                try #require(text.string == String(repeating: "合成预览文本\n", count: 1_000))
                probes.watch(text, "长文本预览")
            }
            panel.orderOut(nil)
            panel.contentView = nil
        }
        model.panelVisible = false
        model.preview = nil
        // Also close while a debounced search is pending.
        model.search = "待取消查询"
        model.refresh()
        model.cancelRefresh()
    }

    func screenshotCycle(index: Int, width: Int, probes: ReleasedObjects,
                         onActive: (() throws -> Void)? = nil) async throws {
        let mode = index % 7
        // Save operations use the real coordinator flow but never show a system dialog.
        let controller: ScreenshotCoordinator
        if (2...4).contains(mode) {
            controller = ScreenshotCoordinator(
                captureService: SyntheticCapture(), presentWindow: { _ in }, saveImage: { _ in
                    if mode == 3 { throw CocoaError(.fileWriteNoPermission) }
                    return mode == 2
                })
            probes.watch(controller, "保存协调器")
        } else { controller = coordinator }
        defer { controller.cancel() }
        controller.onCopy = { image, _, _ in
            probes.watch(image.image, "复制输出位图")
            return true
        }
        defer { controller.onCopy = nil }
        let screen = ScreenshotScreen(id: 42, frame: CGRect(x: 0, y: 0, width: width, height: width * 9 / 16), scale: 1)
        controller.start(screens: [screen], sourceID: "test.memory", sourceName: "内存验证")
        try await waitUntil { controller.phase != .capturing }
        try #require(controller.phase == .selecting)
        try autoreleasepool {
            let window = try #require(controller.windows.first)
            let overlay = try #require(window.contentView as? ScreenshotOverlay)
            probes.watch(window, "截图窗口")
            probes.watch(overlay, "截图视图")
            probes.watch(overlay.state, "截图编辑状态")
            probes.watch(overlay.capture.image, "捕获原始位图")
            try drag(overlay, from: CGPoint(x: 8, y: 8), to: CGPoint(x: width - 8, y: width * 9 / 16 - 8))
            probes.watch(try #require(overlay.selectedImage), "选区位图")
            overlay.state.action?(.tool(.rectangle))
            try drag(overlay, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 80, y: 60))
            for child in overlay.subviews { probes.watch(child, "截图工具栏") }
            try onActive?()
            // Mode zero deliberately cancels an outstanding preview task.
            if mode != 0 { overlay.state.action?(mode == 1 ? .copy : ((2...4).contains(mode) ? .save : .pin)) }
        }
        if mode != 0 {
            try await waitUntil { controller.phase != .exporting }
            if mode == 3 || mode == 4 {
                try #require(controller.phase == .editing)
                let error = (controller.windows.first?.contentView as? ScreenshotOverlay)?.state.error
                try #require(mode == 3 ? error != nil : error == nil)
            } else {
                try #require(controller.phase == .idle)
            }
        }
        if mode >= 5 {
            try #require(controller.pins.count == 1)
            try autoreleasepool {
                let window = try #require(controller.pins.windows.first)
                probes.watch(window, "钉图窗口")
                probes.watch(try #require(window.contentView), "钉图视图")
                try onActive?()
                if mode == 5 { window.close() } else { controller.pins.closeAll() }
            }
            try #require(controller.pins.count == 0)
        }
        controller.cancel()
        try #require(controller.windows.isEmpty && controller.phase == .idle)
    }
}

@MainActor private func findTextView(_ view: NSView) -> NSTextView? {
    if let text = view as? NSTextView { return text }
    return view.subviews.lazy.compactMap(findTextView).first
}

@MainActor private func drag(_ view: ScreenshotOverlay, from: CGPoint, to: CGPoint) throws {
    func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: CGPoint(x: point.x, y: view.bounds.height - point.y), modifierFlags: [],
            timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
    }
    view.mouseDown(with: try event(.leftMouseDown, from))
    view.mouseDragged(with: try event(.leftMouseDragged, to))
    view.mouseUp(with: try event(.leftMouseUp, to))
}

private struct MemorySample: Codable {
    let phase: String
    let cycles: Int
    let footprint: UInt64
    let resident: UInt64

    static func read(phase: String, cycles: Int) throws -> Self {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        try #require(result == KERN_SUCCESS, "无法读取当前测试进程的内存")
        return Self(phase: phase, cycles: cycles, footprint: info.phys_footprint, resident: info.resident_size)
    }
}

@Suite("Memory lifecycle", .serialized) @MainActor struct MemoryLifecycleTests {
    @Test func canceledPendingCaptureReleasesCoordinatorAndLatePixels() async throws {
        let service = PendingCapture()
        defer {
            service.continuation?.resume(throwing: CancellationError())
            service.continuation = nil
        }
        let owners = ReleasedObjects()
        try await cancelPendingCapture(service, probes: owners)
        try await owners.verify()
        let pixels = ReleasedObjects()
        try autoreleasepool {
            let screen = ScreenshotScreen(id: 42, frame: CGRect(x: 0, y: 0, width: 320, height: 180), scale: 1)
            let image = try syntheticImage(width: 320, height: 180)
            pixels.watch(image, "取消后晚到的位图")
            service.continuation?.resume(returning: [CapturedScreen(screen: screen, image: image)])
            service.continuation = nil
        }
        try await pixels.verify()
    }

    private func cancelPendingCapture(_ service: PendingCapture, probes: ReleasedObjects) async throws {
        let coordinator = ScreenshotCoordinator(captureService: service, presentWindow: { _ in })
        probes.watch(coordinator, "捕获尚未返回的协调器")
        coordinator.start(screens: [], sourceID: "test.memory", sourceName: "内存验证")
        defer { coordinator.cancel() }
        try await waitUntil { service.continuation != nil }
    }

    @Test func repeatedSessionsReleaseViewsWindowsImagesAndOwners() async throws {
        let owners = ReleasedObjects()
        try await exerciseOwners(owners)
        try await owners.verify()
        #expect(owners.survivors.isEmpty)
    }

    private func exerciseOwners(_ owners: ReleasedObjects) async throws {
        let fixture = try MemoryFixture()
        defer { fixture.close() }
        owners.watch(fixture.coordinator, "截图协调器")
        owners.watch(fixture.coordinator.pins, "钉图管理器")
        owners.watch(fixture.panel, "历史面板")
        owners.watch(fixture.model, "应用模型")
        owners.watch(fixture.store, "历史仓库")
        try await fixture.seed()
        for index in 0..<21 {
            let probes = ReleasedObjects()
            try await fixture.historyCycle(index: index, probes: probes)
            try await fixture.screenshotCycle(index: index, width: 320, probes: probes)
            try await probes.verify()
            #expect(probes.survivors.isEmpty)
        }
    }

    @Test func stoppedMonitorAndClearedCacheReleaseOwnersAndImages() async throws {
        let fixture = try MemoryFixture()
        defer { fixture.close() }
        for _ in 0..<12 {
            let probes = ReleasedObjects()
            try await exerciseMonitor(fixture, probes: probes)
            let cache = ThumbnailCache(byteLimit: 1_048_576)
            try autoreleasepool {
                let image = try syntheticImage(width: 128, height: 128)
                probes.watch(image, "缓存位图")
                cache.insert(image, id: UUID(), pixelSize: 128, generation: cache.generation)
            }
            cache.removeAll()
            try await probes.verify()
            // The image must be released by clear, while the cache itself is still alive.
            withExtendedLifetime(cache) {}
        }
    }

    private func exerciseMonitor(_ fixture: MemoryFixture, probes: ReleasedObjects) async throws {
        let board = MemoryClipboard()
        let monitor = ClipboardMonitor(clipboard: board, repository: fixture.store,
            settings: fixture.model.settings, permissions: board)
        probes.watch(monitor, "已停止的剪贴板监控器")
        monitor.start()
        defer { monitor.stop() }
        // Let the monitoring task enter its sleep before cancellation.
        try await Task.sleep(for: .milliseconds(10))
    }

    @Test func repeatedPinGroupsReleaseAllWindowsAndPixels() async throws {
        let pins = PinnedScreenshotManager(presentWindow: { _ in })
        defer { pins.closeAll() }
        for _ in 0..<12 {
            let probes = ReleasedObjects()
            try autoreleasepool {
                for _ in 0..<3 {
                    let image = try ScreenshotRenderer.export(
                        base: syntheticImage(width: 320, height: 180),
                        pointSize: CGSize(width: 320, height: 180), annotations: [])
                    probes.watch(image.image, "独立钉图位图")
                    pins.show(image, sourceID: "test.memory", sourceName: "内存验证", origin: .zero)
                }
                try #require(pins.count == 3)
                for window in pins.windows {
                    probes.watch(window, "批量关闭的钉图窗口")
                    probes.watch(try #require(window.contentView), "批量关闭的钉图视图")
                }
                pins.closeAll()
            }
            try #require(pins.count == 0)
            try await probes.verify()
        }
    }

    @Test func memoryTrendAfterWarmup() async throws {
        guard ProcessInfo.processInfo.environment["PASTEMAN_MEMORY_TESTS"] == "1" else { return }
        let fixture = try MemoryFixture()
        defer { fixture.close() }
        try await fixture.seed()
        var samples: [MemorySample] = []
        for index in 0..<74 {
            let probes = ReleasedObjects()
            try await fixture.historyCycle(index: index, probes: probes)
            try await fixture.screenshotCycle(index: index, width: 1920, probes: probes) {
                if index >= 13 && (index - 13).isMultiple(of: 10) {
                    samples.append(try MemorySample.read(phase: "active", cycles: index - 13))
                }
            }
            try await probes.verify()
            // Fourteen warmup cycles cover every output path twice. Sample six equal batches afterward.
            if index == 13 || (index > 13 && (index - 13).isMultiple(of: 10)) {
                try await Task.sleep(for: .milliseconds(150))
                samples.append(try MemorySample.read(phase: "settled", cycles: index - 13))
            }
        }
        let settled = samples.filter { $0.phase == "settled" }
        try #require(settled.count == 7)
        let baseline = Double(try #require(settled.first).footprint)
        let growth = Double(try #require(settled.last).footprint) - baseline
        let meanX = settled.map { Double($0.cycles) }.reduce(0, +) / Double(settled.count)
        let meanY = settled.map { Double($0.footprint) }.reduce(0, +) / Double(settled.count)
        let slope = settled.reduce(0.0) { $0 + (Double($1.cycles) - meanX) * (Double($1.footprint) - meanY) }
            / settled.reduce(0.0) { $0 + pow(Double($1.cycles) - meanX, 2) }
        if let path = ProcessInfo.processInfo.environment["PASTEMAN_MEMORY_OUTPUT"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(samples).write(to: directory.appendingPathComponent("samples.json"))
            let rows = samples.map { "\($0.phase),\($0.cycles),\($0.footprint),\($0.resident)" }
            try ("phase,cycles,physical_footprint_bytes,resident_bytes\n" + rows.joined(separator: "\n") + "\n")
                .write(to: directory.appendingPathComponent("samples.csv"), atomically: true, encoding: .utf8)
        }
        print("内存趋势：预热后 \(Int(baseline)) 字节，末轮 \(settled.last!.footprint) 字节，增长 \(Int(growth)) 字节，斜率 \(Int(slope)) 字节／轮")
        // A regression gate, not proof of zero leakage: tolerate allocator/framework high-water marks.
        #expect(growth < 24 * 1_048_576, "预热后物理占用增长超过二十四兆字节")
        #expect(slope < 256 * 1024, "物理占用趋势超过每轮二百五十六千字节")
    }
}
