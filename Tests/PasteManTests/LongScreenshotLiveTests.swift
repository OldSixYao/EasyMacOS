import AppKit
import ScreenCaptureKit
import Testing
@testable import PasteMan

@Suite("长截屏可见后台窗口焦点交接", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["EASYMACOS_LONG_INITIAL_FOCUS"] == "1"))
@MainActor struct LongScreenshotInitialFocusLiveTests {
    @Test func visibleInactiveWindowIsFocusedBeforeScrolling() async throws {
        try #require(CGPreflightScreenCaptureAccess() && AXIsProcessTrusted() && CGPreflightPostEventAccess())
        _ = NSApplication.shared
        let environment = ProcessInfo.processInfo.environment
        let url = URL(fileURLWithPath: try #require(environment["EASYMACOS_LONG_SCENE"]))
        let geometry = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let pid = try #require(geometry["pid"] as? pid_t)
        let scene = try #require(NSRunningApplication(processIdentifier: pid))
        let foregroundPID = try #require(environment["EASYMACOS_LONG_FOREGROUND_PID"].flatMap(Int32.init))
        let foreground = try #require(NSRunningApplication(processIdentifier: foregroundPID))
        let previous = NSWorkspace.shared.frontmostApplication
        defer { previous?.activate(from: .current, options: []) }
        func activate(_ application: NSRunningApplication) async throws {
            application.activate(from: .current, options: [])
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while NSWorkspace.shared.frontmostApplication?.processIdentifier != application.processIdentifier,
                  ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            try #require(NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier)
        }
        try await activate(scene)
        try await activate(foreground)
        func value(_ key: String) throws -> CGFloat { CGFloat(try #require(geometry[key] as? Double)) }
        let rect = try CGRect(x: value("x"), y: value("y"), width: value("width"), height: value("height"))
        let screen = try #require(NSScreen.screens.first { $0.frame.contains(rect) })
        let id = try #require(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32)
        let region = LongScreenshotRegion(screen: ScreenshotScreen(id: id, frame: screen.frame, scale: screen.backingScaleFactor),
            selection: CGRect(x: rect.minX - screen.frame.minX + 40, y: screen.frame.maxY - rect.maxY + 40,
                width: rect.width - 80, height: rect.height - 80), desktopTop: try value("desktopTop"))
        let driver = SystemLongScreenshotScroll()
        let target = try driver.resolve(region)
        try #require(target.processID == pid, "只能交接到本轮合成窗口，前台测试窗口不得遮挡选区")
        #expect(throws: LongScreenshotTargetError.applicationChanged) { try driver.validate(target, region: region) }
        try await driver.prepare(target, region: region)
        try driver.validate(target, region: region)
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)
        print("可见后台窗口实机检查：初始前台不同，准备后目标获得焦点且完整校验通过；未采集图片或发送滚轮。")
    }
}

@Suite("长截屏真实前台焦点", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["EASYMACOS_LONG_FOCUS_TARGET_PID"] != nil))
@MainActor struct LongScreenshotFrontmostLiveTests {
    @Test func frontmostWindowCanPrepareWithoutGlobalAccessibilityFocus() async throws {
        try #require(CGPreflightScreenCaptureAccess() && AXIsProcessTrusted() && CGPreflightPostEventAccess())
        let requestedTarget = ProcessInfo.processInfo.environment["EASYMACOS_LONG_FOCUS_TARGET_PID"]
        let pid = try #require(requestedTarget == "frontmost"
            ? NSWorkspace.shared.frontmostApplication?.processIdentifier : requestedTarget.flatMap(Int32.init))
        try #require(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
            "只检查已在前台的指定测试窗口，不主动激活、采集图片或发送滚轮")
        let windows = try #require(CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID) as? [[String: Any]])
        let window = try #require(windows.first {
            $0[kCGWindowOwnerPID as String] as? pid_t == pid && $0[kCGWindowLayer as String] as? Int == 0
        })
        let bounds = try #require(window[kCGWindowBounds as String] as? NSDictionary)
        let frame = try #require(CGRect(dictionaryRepresentation: bounds))
        let desktopTop = try #require(NSScreen.screens.first?.frame.maxY)
        let screen = try #require(NSScreen.screens.first {
            CGRect(x: $0.frame.minX, y: desktopTop - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height)
                .contains(CGPoint(x: frame.midX, y: frame.midY))
        })
        let id = try #require(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32)
        let area = CGRect(x: frame.midX - 100, y: frame.midY - 100, width: 200, height: 200)
        let region = LongScreenshotRegion(screen: ScreenshotScreen(id: id, frame: screen.frame, scale: screen.backingScaleFactor),
            selection: CGRect(x: area.minX - screen.frame.minX, y: area.minY - desktopTop + screen.frame.maxY,
                width: area.width, height: area.height), desktopTop: desktopTop)
        var globalFocus: CFTypeRef?
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.4)
        let globalResult = AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &globalFocus)
        print("系统全局焦点接口返回：\(globalResult.rawValue)，实际前台进程：\(pid)")
        let driver = SystemLongScreenshotScroll()
        let target = try driver.resolve(region)
        try #require(target.processID == pid)
        try await driver.prepare(target, region: region)
        try driver.validate(target, region: region)
        var missingHitChecks = 0
        let unavailableHit = SystemLongScreenshotScroll(hitTest: { _, _ in
            missingHitChecks += 1
            return nil
        })
        // 只替换辅助功能命中边界；窗口编号、位置、遮挡、真实前台与权限继续读取系统。
        try await unavailableHit.prepare(target, region: region)
        try unavailableHit.validate(target, region: region)
        #expect(missingHitChecks >= 6, "系统与应用级命中均缺值时，真实有效窗口仍可完成连续准备")
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)
    }
}

@MainActor private final class LongScreenshotLiveCaptureTrace: LongScreenshotCapturing {
    let capturesContinuously = true
    private let inner = SystemLongScreenshotCapture()
    private var previous: LongScreenshotFeatures?
    private var number = 0
    func prepare(_ region: LongScreenshotRegion) async throws { try await inner.prepare(region) }
    func release() { inner.release() }
    func capture() async throws -> CGImage {
        let image = try await inner.capture()
        let features = try LongScreenshotFeatures(image)
        if let previous, let match = try? previous.match(features), match.displacement > 0 {
            print("帧匹配：位移 \(match.displacement)，顶部 \(match.fixedTop)，底部 \(match.fixedBottom)")
            try ScreenshotRenderer.encode(image).write(to: URL(fileURLWithPath: "/tmp/easymacos-long-frame-\(number).png"))
            number += 1
        } else if previous == nil {
            try ScreenshotRenderer.encode(image).write(to: URL(fileURLWithPath: "/tmp/easymacos-long-frame-first.png"))
        } else if previous?.isStable(comparedTo: features) == false {
            try ScreenshotRenderer.encode(image).write(to: URL(fileURLWithPath: "/tmp/easymacos-long-frame-unmatched.png"))
        }
        previous = features
        return image
    }
}

@Suite("长截屏实机验证", .serialized, .enabled(if: ProcessInfo.processInfo.environment["EASYMACOS_LIVE_LONG_SCREENSHOT"] == "1"))
@MainActor struct LongScreenshotLiveTests {
    @Test func automaticScrollStaysInsideTheSelectionWhileThePointerMovesFreely() async throws {
        try #require(CGPreflightScreenCaptureAccess() && AXIsProcessTrusted() && CGPreflightPostEventAccess())
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EASYMACOS_LONG_SCENE"] ?? "/tmp/easymacos-long-scene.json")
        let geometry = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let pid = try #require(geometry["pid"] as? pid_t)
        let scene = try #require(NSRunningApplication(processIdentifier: pid))
        let previous = NSWorkspace.shared.frontmostApplication
        let originalCursor = CGEvent(source: nil)?.location
        defer {
            if let originalCursor {
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: originalCursor,
                    mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            previous?.activate(from: .current, options: [])
        }
        scene.activate(from: .current, options: [])
        _ = AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        try await Task.sleep(for: .milliseconds(300))
        func value(_ key: String) throws -> CGFloat { CGFloat(try #require(geometry[key] as? Double)) }
        let rect = try CGRect(x: value("x"), y: value("y"), width: value("width"), height: value("height"))
        let screen = try #require(NSScreen.screens.first { $0.frame.contains(rect) })
        let id = try #require(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32)
        let region = LongScreenshotRegion(screen: ScreenshotScreen(id: id, frame: screen.frame, scale: screen.backingScaleFactor),
            selection: CGRect(x: rect.minX - screen.frame.minX + 80, y: screen.frame.maxY - rect.maxY + 40,
                width: rect.width - 160, height: rect.height - 80), desktopTop: try value("desktopTop"))
        let driver = SystemLongScreenshotScroll(), capture = SystemLongScreenshotCapture()
        let target = try driver.resolve(region)
        try #require(target.processID == pid, "仅向合成测试窗口投递事件")
        try await driver.prepare(target, region: region)
        try await capture.prepare(region)
        defer { capture.release() }
        let first = try await capture.capture()
        for index in 0..<12 {
            // 让指针经过选区内外；滚动目标始终固定，不能把指针拉回锚点。
            let point = CGPoint(x: region.quartzRect.minX - 40 + CGFloat(index % 4) * 90,
                y: region.quartzRect.minY - 20 + CGFloat(index % 3) * 80)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point,
                mouseButton: .left)?.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(25))
            for _ in 0..<3 {
                try driver.scrollStep(6, target: target, region: region)
                try await Task.sleep(for: .milliseconds(20))
                let actual = try #require(CGEvent(source: nil)?.location)
                #expect(hypot(actual.x - point.x, actual.y - point.y) < 2, "滚动不得移动真实指针")
            }
        }
        try await Task.sleep(for: .milliseconds(120))
        let last = try await capture.capture()
        let match = try LongScreenshotFeatures(first).match(LongScreenshotFeatures(last))
        #expect(match.displacement > 0, "指针离开选区后，目标内容仍须真实滚动")
        print("真实鼠标回归：十二个指针位置、三十六次定向滚动均未拉回指针，内容位移 \(match.displacement) 像素。")
    }

    @Test func closedSelectionOverlayReleasesFocusBeforeAnyScrolling() async throws {
        try #require(CGPreflightScreenCaptureAccess() && AXIsProcessTrusted() && CGPreflightPostEventAccess())
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EASYMACOS_LONG_SCENE"] ?? "/tmp/easymacos-long-scene.json")
        let geometry = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let pid = try #require(geometry["pid"] as? pid_t)
        let scene = try #require(NSRunningApplication(processIdentifier: pid))
        func value(_ key: String) throws -> CGFloat { CGFloat(try #require(geometry[key] as? Double)) }
        let rect = try CGRect(x: value("x"), y: value("y"), width: value("width"), height: value("height"))
        let screen = try #require(NSScreen.screens.first { $0.frame.contains(rect) })
        let id = try #require(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32)
        let region = LongScreenshotRegion(screen: ScreenshotScreen(id: id, frame: screen.frame, scale: screen.backingScaleFactor),
            selection: CGRect(x: rect.minX - screen.frame.minX + 4, y: screen.frame.maxY - rect.maxY + 4,
                width: rect.width - 24, height: rect.height - 8), desktopTop: try value("desktopTop"))
        let driver = SystemLongScreenshotScroll()
        var transitions = 0
        for attempt in 0..<6 {
            scene.activate(from: .current, options: [])
            _ = AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            try await Task.sleep(for: .milliseconds(150))
            let target = try driver.resolve(region)
            try #require(target.processID == pid, "只验证合成窗口")
            let panel = ScreenshotPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            panel.contentView = NSView(frame: CGRect(origin: .zero, size: rect.size))
            panel.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(60))
            if attempt.isMultiple(of: 2) { NSApp.activate() }
            panel.contentView = nil; panel.close()
            do { try driver.validate(target, region: region) }
            catch let issue as LongScreenshotTargetError where issue.canWaitForInitialFocus { transitions += 1 }
            try await driver.prepare(target, region: region)
            try driver.validate(target, region: region)
        }
        print("浮层退场实机检查：六次准备全部通过，观察到 \(transitions) 次异步焦点或命中过渡；未发送滚轮事件。")
    }

    @Test func syntheticPageScrollsToBottomWithConsecutiveRowMarkers() async throws {
        try #require(CGPreflightScreenCaptureAccess() && AXIsProcessTrusted() && CGPreflightPostEventAccess(), "调用进程须已获权限，本测试不请求授权")
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EASYMACOS_LONG_SCENE"] ?? "/tmp/easymacos-long-scene.json")
        let geometry = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let scenePID = try #require(geometry["pid"] as? pid_t)
        let scene = try #require(NSRunningApplication(processIdentifier: scenePID))
        scene.activate(from: .current, options: [])
        _ = AXUIElementSetAttributeValue(AXUIElementCreateApplication(scenePID), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        try await Task.sleep(for: .milliseconds(400))
        func value(_ key: String) throws -> CGFloat { CGFloat(try #require(geometry[key] as? Double)) }
        let rect = try CGRect(x: value("x"), y: value("y"), width: value("width"), height: value("height"))
        let screen = try #require(NSScreen.screens.first { $0.frame.contains(rect) })
        let id = try #require(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32)
        let region = LongScreenshotRegion(screen: ScreenshotScreen(id: id, frame: screen.frame, scale: screen.backingScaleFactor),
            selection: CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height),
            desktopTop: try value("desktopTop"))
        try #require(SystemLongScreenshotScroll().resolve(region).processID == scenePID, "只允许采集合成验证窗口")
        if ProcessInfo.processInfo.environment["EASYMACOS_LONG_TRACE"] == "1" {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            print("采集进程：\(ProcessInfo.processInfo.processIdentifier)，合成场景进程：\(scenePID)")
            print("应用过滤匹配：\(content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier || $0.processID == scenePID }.map { ($0.processID, $0.applicationName) })")
            let check = SystemLongScreenshotCapture()
            try await check.prepare(region)
            let baseline = try await check.capture()
            check.release()
            try ScreenshotRenderer.encode(baseline).write(to: URL(fileURLWithPath: "/tmp/easymacos-long-baseline.png"))
        }
        let tracing = ProcessInfo.processInfo.environment["EASYMACOS_LONG_TRACE"] == "1"
        let savesFrames = ProcessInfo.processInfo.environment["EASYMACOS_LONG_FRAME_IMAGES"] == "1"
        let coordinator = LongScreenshotCoordinator(capture: savesFrames ? LongScreenshotLiveCaptureTrace() : SystemLongScreenshotCapture())
        defer { coordinator.cancel() }
        var done = false
        var document: LongScreenshotDocument?
        var message: String?
        coordinator.onFinish = { result, reason, _ in document = result; message = reason; done = true }
        if tracing { coordinator.onProgress = { print("拼接进度：\($0.height)，本次新增 \($0.added)") } }
        coordinator.start(region)
        let deadline = ContinuousClock.now.advanced(by: .seconds(150))
        while !done, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(done, "实机采集超时")
        #expect(message == nil, "采集停止原因：\(message ?? "")")
        let result = try #require(document)
        let expectedHeight = Int(try value("expectedHeight") * screen.backingScaleFactor)
        let output = try ScreenshotRenderer.export(base: result.image, pointSize: result.pointSize, annotations: [])
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EASYMACOS_LONG_OUTPUT"] ?? "/tmp/easymacos-long-live")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let isWeb = geometry["web"] as? Bool == true
        try output.png.write(to: root.appendingPathComponent(isWeb ? "web.png" : "native.png"))
        try #require(result.image.height == expectedHeight, "实际高度 \(result.image.height)，预期 \(expectedHeight)")
        if geometry["floatingButton"] as? Bool == true {
            let raw = try #require(result.image.dataProvider?.data as Data?)
            var markedRows: [Int] = []
            for y in 0..<result.image.height {
                var marked = 0
                for x in (result.image.width / 2 - 50)..<(result.image.width / 2 + 50) {
                    let index = y * result.image.bytesPerRow + x * 4
                    if raw[index] < 26, raw[index + 1] > 150, raw[index + 1] < 185, raw[index + 2] > 225 { marked += 1 }
                }
                if marked >= 2 { markedRows.append(y) }
            }
            let first = try #require(markedRows.first, "最终视口中的合成悬浮按钮仍应存在")
            let last = try #require(markedRows.last)
            #expect(last - first <= Int(44 * screen.backingScaleFactor),
                "悬浮圆弧只能位于最终按钮所在区域，不能沿长图重复；标记纵向跨度 \(last - first)")
            #expect(first > result.image.height - Int(170 * screen.backingScaleFactor), "历史视口不应留下圆弧残影")
        }
        let context = try #require(CGContext(data: nil, width: result.image.width, height: result.image.height, bitsPerComponent: 8,
            bytesPerRow: result.image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(result.image, in: CGRect(x: 0, y: 0, width: result.image.width, height: result.image.height))
        let pixels = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
        let scale = screen.backingScaleFactor
        let top = try value("top")
        for row in 0..<55 {
            let hash = UInt32(row + 1) &* 2_654_435_761
            let expected = [Int(32 + (hash & 191)), Int(32 + ((hash >> 8) & 191)), Int(32 + ((hash >> 16) & 191))]
            // 检查整条色带而非仅中点，发现跳行、重复行与拼接接缝。
            for y in stride(from: Int((top + CGFloat(row * 44 + 2)) * scale), to: Int((top + CGFloat((row + 1) * 44 - 2)) * scale), by: 3) {
                guard y < result.image.height else { Issue.record("成片缺少第 \(row + 1) 行"); continue }
                let offset = y * context.bytesPerRow + Int(30 * scale) * 4
                // 系统表面含空间颜色抖动，单个色阶可偏四级；相邻五点取中位数。
                // 仍逐行检查同一条色带，透明底边形成的整行接缝不会被滤掉。
                #expect((0..<3).allSatisfy { channel in
                    let samples = (-2...2).map { Int(pixels[offset + $0 * 4 + channel]) }.sorted()
                    return abs(samples[2] - expected[channel]) <= 3
                }, "第 \(row + 1) 行像素 \(y) 不连续")
            }
        }
        print("长截屏实机检查：\(isWeb ? "网页" : "原生列表")，\(result.image.width) × \(result.image.height)，\(root.path)")
    }
}
