import AppKit
import ApplicationServices
import Darwin
import FinderMenuCore
import PasteManCore
import SwiftUI
import Synchronization
import Testing

@testable import PasteMan

/// 只使用合成数据；报告由环境变量指定，日常测试不执行基准负载。
@Suite("优化对比测量", .serialized) @MainActor struct OptimizationBenchmarks {
    private var enabled: Bool { ProcessInfo.processInfo.environment["EASYMACOS_BENCHMARK_OUTPUT"] != nil }

    @Test func measureWorkloads() async throws {
        guard enabled else { return }
        _ = NSApplication.shared
        let report = BenchmarkReport()
        let image = try benchmarkImage(width: 3840, height: 2160)
        let size = CGSize(width: 1920, height: 1080)
        var annotations: [ScreenshotAnnotation] = []
        for index in 0..<100 {
            let first = CGPoint(x: 10 + index * 4, y: 10 + index * 2)
            let last = CGPoint(x: 200 + index * 4, y: 180 + index * 2)
            annotations.append(ScreenshotAnnotation(tool: .rectangle, points: [first, last],
                color: AnnotationColor.palette[index % 6], width: 3))
        }
        try await report.measure("截图导出_4K_无标注") {
            _ = try await ScreenshotRenderWorker.shared.export(base: image, pointSize: size, annotations: [])
        }
        try await report.measure("截图导出_4K_百个标注") {
            _ = try await ScreenshotRenderWorker.shared.export(base: image, pointSize: size, annotations: annotations)
        }
        try await report.measure("连续标注预览_百个标注") {
            let session = UUID()
            for count in stride(from: 10, through: 100, by: 10) {
                _ = try await ScreenshotRenderWorker.shared.preview(base: image, pointSize: size,
                    annotations: Array(annotations.prefix(count)), session: session)
            }
            await ScreenshotRenderWorker.shared.releasePreview(session: session)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EasyMacOS.Benchmark." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = try HistoryStore(directory: directory)
        let settings = AppSettings(defaults: defaults)
        settings.hasOnboarded = true
        let board = BenchmarkClipboard()
        let monitor = ClipboardMonitor(clipboard: board, repository: store, settings: settings, permissions: board)
        try await report.measure("截图导出并写入历史_4K") {
            let result = try await ScreenshotRenderWorker.shared.export(base: image, pointSize: size, annotations: [])
            let ticket = try #require(monitor.screenshotTicket(sourceID: "test.benchmark"))
            try await monitor.recordScreenshot(result, sourceID: "test.benchmark", sourceName: "合成应用", ticket: ticket)
        }
        let policy = RetentionPolicy(days: 365, count: 10_000)
        for count in [500, 5_000] {
            let existing = try await store.list().count
            for index in existing..<count {
                try await store.save(.text(String(repeating: "中文基准 abcdef ", count: 40) + "\(index)"),
                    sourceBundleID: "test.benchmark", sourceName: "合成应用", policy: policy)
            }
            try await report.measure("历史全量查询_\(count)") { _ = try await store.list() }
            try await report.measure("历史搜索无匹配_\(count)") { _ = try await store.list(search: "不存在的片段") }
            try await report.measure("历史重复保存_\(count)") {
                try await store.save(.text("重复保存基准"), sourceBundleID: "test.benchmark", sourceName: "合成应用", policy: policy)
            }
            try await report.measure("历史空清理_\(count)") { try await store.prune(policy: policy) }
        }
        let model = AppModel(repository: store, settings: settings, permissions: PermissionService(), hotKeys: HotKeyService())
        defer { model.hotKeys.stop() }
        try await report.measure("历史首屏含离屏布局_5000") {
            model.refresh()
            try await benchmarkWait { !model.loading }
            let view = NSHostingView(rootView: HistoryView(model: model))
            view.frame = CGRect(x: 0, y: 0, width: 440, height: 590)
            view.layoutSubtreeIfNeeded()
            model.cancelRefresh()
        }
        let beforePins = try benchmarkFootprint()
        report.values["钉图前物理内存_字节"] = [Double(beforePins)]
        var pinSamples = [beforePins]
        let pins = PinnedScreenshotManager(presentWindow: { window in
            window.contentView?.frame = CGRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size)
            window.contentView?.layoutSubtreeIfNeeded()
            if ProcessInfo.processInfo.environment["EASYMACOS_BENCHMARK_VISIBLE"] == "1" {
                window.orderFrontRegardless()
            }
        })
        let start = ContinuousClock.now
        for _ in 0..<8 {
            let output = try await PinnedImageWorker.shared.archive(base: image, pointSize: size, annotations: [])
            pins.show(output, sourceID: "test.benchmark", sourceName: "合成应用", origin: nil)
            pinSamples.append(try benchmarkFootprint())
        }
        await pins.waitForDisplays()
        report.values["八张钉图创建_毫秒"] = [benchmarkMilliseconds(start.duration(to: .now))]
        try await Task.sleep(for: .milliseconds(300))
        let activePins = try benchmarkFootprint()
        pinSamples.append(activePins)
        report.values["八张钉图物理内存增量_字节"] = [Double(activePins) - Double(beforePins)]
        report.values["八张钉图物理内存_字节"] = [Double(activePins)]
        report.values["八张钉图阶段采样峰值_字节"] = [Double(pinSamples.max() ?? activePins)]
        report.values["钉图显示缓存_字节"] = [Double(pins.cachedDisplayByteCount)]
        try #require(pins.cachedDisplayByteCount > 1_048_576 && pins.cachedDisplayByteCount <= 32 * 1_048_576)
        pins.closeAll()
        try await Task.sleep(for: .milliseconds(150))
        report.values["钉图关闭后物理内存增量_字节"] = [Double(try benchmarkFootprint()) - Double(beforePins)]
        let smallPin = try await PinnedImageWorker.shared.archive(base: image, pointSize: CGSize(width: 200, height: 112.5), annotations: [])
        for _ in 0..<6 {
            let stored = try await PinnedImageWorker.shared.archive(base: image, pointSize: smallPin.pointSize, annotations: [])
            pins.show(stored, sourceID: "test", sourceName: "合成应用", origin: nil)
        }
        await pins.waitForDisplays()
        try await report.measure("六张小钉图期间增减一张_毫秒") {
            pins.show(smallPin, sourceID: "test", sourceName: "合成应用", origin: nil)
            await pins.waitForDisplays()
            pins.windows.last?.close()
            await pins.waitForDisplays()
        }
        if let window = pins.windows.first {
            try await report.measure("钉图连续四十次缩放_毫秒") {
                for index in 0..<40 {
                    let width = CGFloat(200 + index * 2)
                    window.setContentSize(CGSize(width: width, height: width * 0.5625))
                    // 模拟连续输入，允许每个请求进入工作器，而非一次循环内全部取消。
                    await Task.yield()
                }
                await pins.waitForDisplays()
            }
        }
        try await report.measure("六张钉图轮流四十次缩放_毫秒") {
            for index in 0..<40 {
                let width = CGFloat(200 + index * 8)
                for window in pins.windows {
                    window.setContentSize(CGSize(width: width, height: width * 0.5625))
                }
                await Task.yield()
            }
            await pins.waitForDisplays()
        }
        try await Task.sleep(for: .milliseconds(150))
        report.values["六张钉图缩放后显示缓存统计_字节"] = [Double(pins.cachedDisplayByteCount)]
        report.values["六张钉图缩放后物理占用_字节"] = [Double(try benchmarkFootprint())]
        pins.closeAll()
        pins.show(smallPin, sourceID: "test", sourceName: "合成应用", origin: nil)
        if let window = pins.windows.first {
            window.setContentSize(CGSize(width: 1200, height: 675))
            await pins.waitForDisplays()
            report.values["钉图缩小前显示缓存_字节"] = [Double(pins.cachedDisplayByteCount)]
            window.setContentSize(CGSize(width: 200, height: 112.5))
            await pins.waitForDisplays()
            report.values["钉图缩小后显示缓存_字节"] = [Double(pins.cachedDisplayByteCount)]
        }
        pins.closeAll()
        report.values["正常监控轮询间隔_毫秒"] = [benchmarkMilliseconds(monitor.pollInterval)]
        settings.paused = true
        report.values["暂停监控轮询间隔_毫秒"] = [benchmarkMilliseconds(monitor.pollInterval)]
        let screen = ScreenshotScreen(id: 42, frame: CGRect(origin: .zero, size: size), scale: 2)
        let coordinator = ScreenshotCoordinator(presentWindow: { _ in })
        let overlay = ScreenshotOverlay(capture: CapturedScreen(screen: screen, image: image), coordinator: coordinator)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3840, pixelsHigh: 2160,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        try await report.measure("截图背景离屏局部重绘_4K") {
            autoreleasepool {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                NSGraphicsContext.current?.cgContext.clip(to: CGRect(x: 20, y: 20, width: 200, height: 240))
                overlay.drawInteraction(CGRect(x: 20, y: 20, width: 200, height: 240))
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        let queueDirectory = directory.appendingPathComponent("queue")
        let queueStore = try HistoryStore(directory: queueDirectory)
        settings.paused = false
        let delayedBoard = BenchmarkClipboard()
        let delayed = ClipboardMonitor(clipboard: delayedBoard, repository: queueStore, settings: settings,
            permissions: delayedBoard, sourceApplication: { ("test.benchmark", "合成应用") }, prepareImage: { _ in
                try await Task.sleep(for: .milliseconds(900))
                return .text("慢图片处理结果")
            })
        delayed.start()
        delayedBoard.changeCount += 1
        delayedBoard.snapshot = .image(Data([1]))
        try await Task.sleep(for: .milliseconds(650))
        delayedBoard.changeCount += 1
        delayedBoard.snapshot = .text("处理期间第一次复制")
        try await Task.sleep(for: .milliseconds(550))
        delayedBoard.changeCount += 1
        delayedBoard.snapshot = .text("处理期间第二次复制")
        try await Task.sleep(for: .milliseconds(1100))
        delayed.stop()
        report.values["慢图片期间捕获数_三次复制"] = [Double(try await queueStore.list().count)]
        report.values["监控检查次数_2点3秒"] = [Double(delayedBoard.refreshes)]
        let files = directory.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        var items: [URL] = []
        for index in 0..<1_000 {
            let url = files.appendingPathComponent("item-\(index).txt")
            try Data().write(to: url)
            items.append(url)
        }
        try await report.measure("千个文件目录检查_总耗时") { _ = try await FinderFileWorker.shared.directory(for: items) }
        try await report.measure("千个文件菜单规划_总耗时") {
            _ = FinderMenuPlan(items: items, configuration: FinderConfiguration(), hasSelection: true)
        }
        try await report.measure("访达默认图标_百轮") {
            autoreleasepool {
                for _ in 0..<100 {
                    for type in FinderConfiguration().fileTypes { _ = FinderFileTypeIcon.image(for: type) }
                }
            }
        }
        var stalls: [Double] = []
        for _ in 0..<7 {
            let heartbeat = BenchmarkHeartbeat()
            let tick = Task { @MainActor in
                var previous = ContinuousClock.now
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(1))
                    let now = ContinuousClock.now
                    heartbeat.maximum = max(heartbeat.maximum, benchmarkMilliseconds(previous.duration(to: now)))
                    previous = now
                }
            }
            try await Task.sleep(for: .milliseconds(3))
            _ = try await FinderFileWorker.shared.directory(for: items)
            try await Task.sleep(for: .milliseconds(3))
            tick.cancel()
            stalls.append(heartbeat.maximum)
        }
        report.values["千个文件目录检查_主线程最大调度间隔"] = stalls
        try report.write()
    }

    @Test func measureMixedImageWorkload() async throws {
        guard ProcessInfo.processInfo.environment["EASYMACOS_MIXED_BENCHMARK_OUTPUT"] != nil else { return }
        let large = ProcessInfo.processInfo.environment["EASYMACOS_MIXED_LARGE"] == "1"
        let image = try benchmarkImage(width: large ? 6000 : 3840, height: large ? 4000 : 2160)
        let size = large ? CGSize(width: 3000, height: 2000) : CGSize(width: 1920, height: 1080)
        let png = try ScreenshotRenderer.encode(image)
        let archive = try await PinnedImageWorker.shared.archive(base: image, pointSize: size, annotations: [])
        let annotations = [ScreenshotAnnotation(tool: .rectangle, points: [.zero, CGPoint(x: 800, y: 600)],
            color: AnnotationColor.palette[0], width: 3)]
        let baseline = try benchmarkFootprint()
        let peak = Mutex(baseline)
        let sampler = Task.detached {
            while !Task.isCancelled {
                if let bytes = try? benchmarkFootprint() { peak.withLock { $0 = max($0, bytes) } }
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        defer { sampler.cancel() }
        let start = ContinuousClock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = try await ImagePreparationWorker.shared.prepare(png) }
            group.addTask { _ = try await ScreenshotRenderWorker.shared.export(base: image, pointSize: size, annotations: annotations) }
            group.addTask { _ = try await archive.display(maximumPixels: 1024) }
            try await group.waitForAll()
        }
        sampler.cancel()
        _ = await sampler.result
        let report = BenchmarkReport()
        report.values["混合图片任务总耗时_毫秒"] = [benchmarkMilliseconds(start.duration(to: .now))]
        report.values["混合图片任务前物理占用_字节"] = [Double(baseline)]
        report.values["混合图片阶段采样峰值_字节"] = [Double(peak.withLock { $0 })]
        report.values["混合图片采样峰值增量_字节"] = [Double(peak.withLock { $0 }) - Double(baseline)]
        try report.write(outputKey: "EASYMACOS_MIXED_BENCHMARK_OUTPUT")
    }

    @Test func measureInputCosts() async throws {
        guard ProcessInfo.processInfo.environment["EASYMACOS_INPUT_BENCHMARK_OUTPUT"] != nil else { return }
        let report = BenchmarkReport()
        let template = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line,
            wheelCount: 2, wheel1: 8, wheel2: 0, wheel3: 0))
        try await report.measure("构造一千个平滑输出事件_毫秒") {
            for _ in 0..<1000 { _ = try #require(MouseScrollEventAdapter.output(MouseScrollVector(y: 8), template: template)) }
        }
        try await report.measure("一千次鼠标双权限检查_毫秒") {
            for _ in 0..<1000 {
                _ = AXIsProcessTrusted()
                _ = CGPreflightPostEventAccess()
            }
        }
        let board = NSPasteboard(name: .init("EasyMacOS.InputBenchmark." + UUID().uuidString))
        defer { board.releaseGlobally() }
        let png = try ScreenshotRenderer.encode(benchmarkImage(width: 3840, height: 2160))
        try #require(board.setData(png, forType: .png))
        let reader = SystemClipboard(pasteboard: board)
        try await report.measure("独立剪贴板一百次读取合成图片_毫秒") {
            for _ in 0..<100 { _ = try #require(await reader.capture(expectedChangeCount: board.changeCount)) }
        }
        try report.write(outputKey: "EASYMACOS_INPUT_BENCHMARK_OUTPUT")
    }

    @Test func measureMousePermissionCache() async throws {
        guard ProcessInfo.processInfo.environment["EASYMACOS_MOUSE_PERMISSION_BENCHMARK_OUTPUT"] != nil else { return }
        let report = BenchmarkReport()
        var checks: [Double] = []
        try await report.measure("一千帧权限门控_毫秒") {
            var gate = MouseScrollPermissionGate()
            var count = 0
            // 固定一百二十赫兹的模拟时钟，只测真实权限接口与门控开销，不投递事件。
            for frame in 0..<1000 {
                _ = gate.allows(at: Double(frame) / 120) {
                    count += 1
                    let accessibility = AXIsProcessTrusted()
                    let posting = CGPreflightPostEventAccess()
                    return accessibility && posting
                }
            }
            checks.append(Double(count))
        }
        report.values["一千帧实际权限检查次数"] = checks
        try report.write(outputKey: "EASYMACOS_MOUSE_PERMISSION_BENCHMARK_OUTPUT")
    }
}

@MainActor private final class BenchmarkHeartbeat { var maximum = 0.0 }

@MainActor private final class BenchmarkClipboard: ClipboardReading, ClipboardPermissionChecking {
    var changeCount = 0
    var types: Set<String> = []
    var allowsMonitoring = true
    var refreshes = 0
    var snapshot: ClipboardSnapshot?
    func refreshClipboard() { refreshes += 1 }
    func capture(expectedChangeCount: Int) -> ClipboardSnapshot? { snapshot }
}

@MainActor private final class BenchmarkReport {
    var values: [String: [Double]] = [:]
    func measure(_ name: String, operation: () async throws -> Void) async throws {
        try await operation()
        var samples: [Double] = []
        for _ in 0..<7 {
            let start = ContinuousClock.now
            try await operation()
            samples.append(benchmarkMilliseconds(start.duration(to: .now)))
        }
        values[name] = samples
        print("测量完成：\(name)")
    }
    func write(outputKey: String = "EASYMACOS_BENCHMARK_OUTPUT") throws {
        let path = try #require(ProcessInfo.processInfo.environment[outputKey])
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("results.json"), options: .atomic)
    }
}

private func benchmarkMilliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

@MainActor private func benchmarkWait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    try #require(condition())
}

private func benchmarkFootprint() throws -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    try #require(result == KERN_SUCCESS)
    return info.phys_footprint
}

private func benchmarkImage(width: Int, height: Int) throws -> CGImage {
    try autoreleasepool {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for y in stride(from: 0, to: height, by: 16) {
            context.setFillColor(CGColor(red: CGFloat(y % 255) / 255, green: 0.6, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: y, width: width, height: 16))
        }
        return try #require(context.makeImage())
    }
}
