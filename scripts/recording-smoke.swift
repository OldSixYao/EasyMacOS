// 针对已运行且已授权的签名应用验证真实框选、暂停和保存。
// 不请求或重置权限；视频保存到应用已配置目录，验证产物仅留本地。
import AppKit
import ApplicationServices
@preconcurrency import AVFoundation
import Carbon

struct RecordingSmokeError: Error, CustomStringConvertible { let description: String }
func require(_ value: Bool, _ message: String) throws {
    if !value { throw RecordingSmokeError(description: message) }
}
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
func elements(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 14 else { return [] }
    return [element] + ((attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []).flatMap { elements($0, depth: depth + 1) }
}
func control(_ app: AXUIElement, id: String) -> AXUIElement? {
    ((attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).flatMap { elements($0) }.first {
        attribute($0, kAXIdentifierAttribute) as? String == id
    }
}
func title(_ element: AXUIElement?) -> String {
    guard let element else { return "" }
    return attribute(element, kAXTitleAttribute) as? String ?? attribute(element, kAXDescriptionAttribute) as? String ?? ""
}
@MainActor func wait(_ message: String, timeout: TimeInterval = 8, until condition: () -> Bool) async throws {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(30))
    }
    try require(condition(), message)
}
func key(_ code: Int, flags: CGEventFlags = []) {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
}
func mouse(_ type: CGEventType, _ point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
}
@MainActor func drag(_ from: CGPoint, _ to: CGPoint, interval: Duration = .milliseconds(15)) async throws {
    mouse(.leftMouseDown, from)
    for step in 1...12 {
        mouse(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * Double(step) / 12,
                                        y: from.y + (to.y - from.y) * Double(step) / 12))
        try await Task.sleep(for: interval)
    }
    mouse(.leftMouseUp, to)
    try await Task.sleep(for: .milliseconds(80))
}
func overlays(_ pid: pid_t) -> Int {
    ((CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]) ?? []).filter {
        ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid)
            && ($0[kCGWindowLayer as String] as? Int ?? 0) > NSWindow.Level.screenSaver.rawValue
    }.count
}
func regionHighlights(_ pid: pid_t) -> [[String: Any]] {
    ((CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]) ?? []).filter {
        ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid)
            && ($0[kCGWindowLayer as String] as? Int) == NSWindow.Level.screenSaver.rawValue
    }
}
func windowRect(_ element: AXUIElement) -> CGRect? {
    guard let window = attribute(element, kAXWindowAttribute),
          let p = attribute(window as! AXUIElement, kAXPositionAttribute),
          let s = attribute(window as! AXUIElement, kAXSizeAttribute) else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}
func elementRect(_ element: AXUIElement) -> CGRect? {
    guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute) else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}
@MainActor func clickControl(_ app: AXUIElement, id: String) throws {
    guard let button = control(app, id: id), let frame = elementRect(button) else {
        throw RecordingSmokeError(description: "找不到按钮：" + id)
    }
    let point = CGPoint(x: frame.midX, y: frame.midY)
    mouse(.leftMouseDown, point)
    mouse(.leftMouseUp, point)
}
func snapshot(_ name: String) throws {
    guard let path = ProcessInfo.processInfo.environment["EASYMACOS_RECORDING_SCREENSHOTS"] else { return }
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-R80,500,700,500", URL(fileURLWithPath: path).appendingPathComponent(name + ".png").path]
    try process.run()
    process.waitUntilExit()
}
@MainActor func checkHover(_ app: AXUIElement) async throws {
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EASYMACOS_RECORDING_SCREENSHOTS"]
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("EasyMacOS-Hover-" + UUID().uuidString).path)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    func capture(_ rect: CGRect, _ name: String, cursor: Bool = false) throws -> NSBitmapImageRep {
        let path = directory.appendingPathComponent(name + ".png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x"] + (cursor ? ["-C"] : []) + ["-R\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))", path.path]
        try process.run()
        process.waitUntilExit()
        guard let image = NSBitmapImageRep(data: try Data(contentsOf: path)) else {
            throw RecordingSmokeError(description: "无法读取悬停检查图像。")
        }
        return image
    }
    for (name, point) in [("inside-cursor", CGPoint(x: 300, y: 700)), ("outside-cursor", CGPoint(x: 70, y: 530)),
                          ("edge-cursor", CGPoint(x: 100, y: 740))] {
        mouse(.mouseMoved, point)
        try await Task.sleep(for: .milliseconds(150))
        _ = try capture(CGRect(x: point.x - 24, y: point.y - 24, width: 64, height: 64), name, cursor: true)
    }
    for (index, id) in ["recording.selection.start", "recording.selection.reselect", "recording.selection.cancel"].enumerated() {
        guard let button = control(app, id: id), let frame = elementRect(button) else {
            throw RecordingSmokeError(description: "找不到悬停按钮：" + id)
        }
        mouse(.mouseMoved, CGPoint(x: 70, y: 530))
        try await Task.sleep(for: .milliseconds(150))
        let before = try capture(frame, "button-\(index)-normal")
        let point = CGPoint(x: frame.midX, y: frame.midY)
        mouse(.mouseMoved, point)
        try await Task.sleep(for: .milliseconds(200))
        let hovered = try capture(frame, "button-\(index)-hover")
        var changed = 0
        for y in 0..<min(before.pixelsHigh, hovered.pixelsHigh) {
            for x in 0..<min(before.pixelsWide, hovered.pixelsWide) {
                if let a = before.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   let b = hovered.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent) > 0.1 { changed += 1 }
            }
        }
        try require(changed > before.pixelsWide * before.pixelsHigh / 20, "按钮悬停未出现明显高亮：" + id)
        _ = try capture(CGRect(x: point.x - 24, y: point.y - 24, width: 64, height: 64), "button-\(index)-cursor", cursor: true)
        mouse(.mouseMoved, CGPoint(x: 70, y: 530))
        try await Task.sleep(for: .milliseconds(150))
    }
    print("通过：三个选区按钮的真实鼠标悬停均产生可见高亮。")
}
struct Options: Decodable { let directory: URL; let systemAudio: Bool; let microphone: Bool }

@MainActor func run() async throws {
    try require(AXIsProcessTrusted() && CGPreflightPostEventAccess(), "调用进程需要已有辅助功能与事件发送权限。")
    let running = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "app.pasteman.PasteMan" }
    try require(running.count == 1, "必须仅运行一个已完成引导的应用实例。")
    let app = running[0]
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    let defaults = UserDefaults(suiteName: "app.pasteman.PasteMan")!
    let options = defaults.data(forKey: "screenRecordingOptions").flatMap { try? JSONDecoder().decode(Options.self, from: $0) }
    try require(options?.microphone != true, "实机检查不请求麦克风权限，请先关闭录制麦克风。")
    let directory = options?.directory ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("EasyMacOS")
    func files() -> Set<URL> {
        Set(((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "mp4" })
    }
    let before = files()
    let shortcutFlags: CGEventFlags = [.maskControl, .maskAlternate]
    // 缓慢框选会让系统在一至十五点的中间尺寸刷新光标，曾导致无效矩形异常。
    for size in [CGSize(width: 1, height: 1), CGSize(width: 8, height: 40), CGSize(width: 40, height: 8), CGSize(width: 16, height: 16)] {
        key(kVK_ANSI_R, flags: [.maskControl, .maskAlternate, .maskShift])
        try await wait("小选区检查未进入框选。") { overlays(app.processIdentifier) > 0 }
        try await Task.sleep(for: .milliseconds(150))
        try await drag(CGPoint(x: 200, y: 600), CGPoint(x: 200 + size.width, y: 600 + size.height), interval: .milliseconds(70))
        try require(!app.isTerminated, "小选区刷新光标时应用退出。")
        key(kVK_Escape)
        try await wait("小选区取消后未关闭框选层。") { overlays(app.processIdentifier) == 0 }
    }
    key(kVK_ANSI_R, flags: [.maskControl, .maskAlternate, .maskShift])
    try await wait("缩放检查未进入框选。") { overlays(app.processIdentifier) > 0 }
    try await Task.sleep(for: .milliseconds(150))
    try await drag(CGPoint(x: 200, y: 600), CGPoint(x: 600, y: 850))
    try await drag(CGPoint(x: 600, y: 850), CGPoint(x: 201, y: 850), interval: .milliseconds(70))
    try await drag(CGPoint(x: 201, y: 850), CGPoint(x: 600, y: 850), interval: .milliseconds(70))
    try require(!app.isTerminated, "缩放经过窄选区时应用退出。")
    key(kVK_Escape)
    try await wait("缩放检查取消后未关闭框选层。") { overlays(app.processIdentifier) == 0 }
    print("通过：缓慢框选小区域、窄区域及缩放经过窄区域均未闪退。")
    key(kVK_ANSI_R, flags: shortcutFlags)
    try await wait("全屏录制未显示选屏层。") { overlays(app.processIdentifier) > 0 }
    key(kVK_Escape)
    try await wait("取消后选屏层未关闭。") { overlays(app.processIdentifier) == 0 }
    print("通过：全屏选屏及退出键取消。")

    // 框选合成画面，先确认倒计时可取消，再完成真实录制。
    for cancel in [true, false] {
        key(kVK_ANSI_R, flags: [.maskControl, .maskAlternate, .maskShift])
        try await wait("区域录制未显示选区层。") { overlays(app.processIdentifier) > 0 }
        try await Task.sleep(for: .milliseconds(150))
        try await drag(CGPoint(x: 110, y: 590), CGPoint(x: 730, y: 970))
        let startBefore = control(ax, id: "recording.selection.start").flatMap(elementRect)
        try require(startBefore != nil, "框选后未显示选区旁的操作栏。")
        try await drag(CGPoint(x: 400, y: 750), CGPoint(x: 420, y: 730))
        let startAfter = control(ax, id: "recording.selection.start").flatMap(elementRect)
        if let before = startBefore, let after = startAfter {
            try require(abs(after.minX - before.minX - 20) < 2 && abs(after.minY - before.minY + 20) < 2,
                        "移动选区时操作栏没有跟随：\(before) → \(after)。")
        }
        try await drag(CGPoint(x: 420, y: 730), CGPoint(x: 400, y: 750))
        // 验证边缘调整，再重新选择固定区域，最终尺寸应为六百四十乘四百逻辑像素。
        try await drag(CGPoint(x: 730, y: 970), CGPoint(x: 740, y: 980))
        if let reselect = control(ax, id: "recording.selection.reselect") {
            try require(AXUIElementPerformAction(reselect, kAXPressAction as CFString) == .success, "重新选择失败。")
        }
        try await drag(CGPoint(x: 100, y: 580), CGPoint(x: 740, y: 980))
        if !cancel { try await checkHover(ax) }
        try snapshot("region-selection")
        try clickControl(ax, id: "recording.selection.start")
        try await wait("确认后未进入倒计时。") { control(ax, id: "recording.cancel") != nil }
        try require(regionHighlights(app.processIdentifier).count == 1, "倒计时未显示区域高亮。")
        if cancel {
            key(kVK_Escape)
            try await wait("倒计时取消失败。") { control(ax, id: "recording.cancel") == nil && overlays(app.processIdentifier) == 0 }
            try require(regionHighlights(app.processIdentifier).isEmpty, "倒计时取消后高亮未移除。")
            print("通过：区域调整、重新选择及倒计时取消。")
            continue
        }
        try await wait("倒计时后未开始录制，检查屏幕权限。", timeout: 12) { control(ax, id: "recording.pause") != nil }
        if let pause = control(ax, id: "recording.pause"), let frame = windowRect(pause) {
            try require(frame.size == CGSize(width: 244, height: 44), "录屏控制条不是紧凑尺寸：\(frame.size)。")
            try require(!frame.intersects(CGRect(x: 100, y: 580, width: 640, height: 400)), "控制条初始位置遮挡选区。")
        }
        try require(regionHighlights(app.processIdentifier).count == 1, "录制中区域高亮消失。")
        try snapshot("region-recording")
        // 将本应用控制条放进录制区域，随后检查成片应仍显示后方的合成画面。
        if let pause = control(ax, id: "recording.pause"), let window = attribute(pause, kAXWindowAttribute) {
            var point = CGPoint(x: 180, y: 740)
            if let value = AXValueCreate(.cgPoint, &point) {
                try require(AXUIElementSetAttributeValue(window as! AXUIElement, kAXPositionAttribute as CFString, value) == .success,
                            "无法移动录屏控制条。")
            }
        }
        try await Task.sleep(for: .seconds(1))
        key(kVK_ANSI_P, flags: shortcutFlags)
        try await wait("暂停未完成。") { ["继续", "Resume"].contains(title(control(ax, id: "recording.pause"))) }
        try require(regionHighlights(app.processIdentifier).count == 1, "暂停时区域高亮消失。")
        try snapshot("region-paused")
        try await Task.sleep(for: .seconds(1))
        if let resume = control(ax, id: "recording.pause") {
            try require(AXUIElementPerformAction(resume, kAXPressAction as CFString) == .success, "继续按钮无响应。")
        }
        try await wait("继续录制未完成。") { ["暂停", "Pause"].contains(title(control(ax, id: "recording.pause"))) }
        try await Task.sleep(for: .seconds(1))
        key(kVK_ANSI_S, flags: shortcutFlags)
        try await wait("停止后未完成保存。", timeout: 30) { control(ax, id: "recording.close") != nil }
        try require(regionHighlights(app.processIdentifier).isEmpty, "保存后高亮边框未移除。")
    }
    let saved = files().subtracting(before)
    try require(saved.count == 1, "取消操作产生了视频，或最终保存文件数量错误。")
    let url = saved.first!
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration).seconds
    try require(duration > 1.6 && duration < 3, "成片时长错误，暂停间隔可能进入了视频。")
    let track = try await asset.loadTracks(withMediaType: .video).first
    try require(track != nil, "保存的视频没有画面。")
    let size = try await track!.load(.naturalSize)
    let scale = NSScreen.screens[0].backingScaleFactor
    try require(size == CGSize(width: 640 * scale, height: 400 * scale), "区域录制尺寸错误：\(size)。")
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track!, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    try require(reader.startReading(), "无法解码验证视频。")
    var checked = 0
    var edgeChecks = 0
    while let sample = output.copyNextSampleBuffer() {
        guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        if let base = CVPixelBufferGetBaseAddress(image) {
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let offset = Int(180 * scale) * CVPixelBufferGetBytesPerRow(image) + Int(220 * scale) * 4
            // 合成画面此处为蓝绿色，控制条若被录入则会覆盖为中性背景色。
            if Int(bytes[offset]) - Int(bytes[offset + 2]) > 30 { checked += 1 }
            let edgeOffset = Int(180 * scale) * CVPixelBufferGetBytesPerRow(image) + Int(scale) * 4
            if Int(bytes[edgeOffset]) - Int(bytes[edgeOffset + 2]) > 30 { edgeChecks += 1 }
        }
        CVPixelBufferUnlockBaseAddress(image, .readOnly)
    }
    try require(checked > 20, "控制条可能进入了成片，或合成验证画面未保持可见。")
    print("通过：快捷键开始、暂停、停止，悬浮条继续，自动保存及视频时长与区域尺寸。")
    try require(edgeChecks > 20, "高亮边框可能进入成片。")
    print("通过：紧凑控制条优先位于选区外，高亮持续至停止且未进入成片。")
    print("通过：位于录制区域内部的控制条未进入成片。")
    print("验证视频：\(url.path)")
    try clickControl(ax, id: "recording.showInFinder")
    try await wait("在访达中显示后完成窗口未关闭。") { control(ax, id: "recording.close") == nil }
    print("通过：在访达中显示视频后，完成窗口自动关闭。")
    let beforeQuit = files()
    key(kVK_ANSI_R, flags: shortcutFlags)
    try await wait("退出保存检查未进入选屏。") { overlays(app.processIdentifier) > 0 }
    // 等待窗口服务器完成新选屏层的输入区域更新，避免把点击发给刚关闭的保存窗口。
    try await Task.sleep(for: .milliseconds(200))
    mouse(.leftMouseDown, CGPoint(x: 1000, y: 500))
    try await Task.sleep(for: .milliseconds(50))
    mouse(.leftMouseUp, CGPoint(x: 1000, y: 500))
    try await wait("全屏选择后没有显示确认操作栏。") { control(ax, id: "recording.selection.start") != nil }
    try snapshot("full-screen-selection")
    key(kVK_Return)
    try await wait("确认显示器后未开始全屏录制。", timeout: 12) { control(ax, id: "recording.pause") != nil }
    if let pause = control(ax, id: "recording.pause"), let frame = windowRect(pause) {
        try require(frame.size == CGSize(width: 244, height: 44), "全屏录制控制条尺寸错误。")
    }
    try require(regionHighlights(app.processIdentifier).count == 1, "全屏录制未显示屏幕边框。")
    try await Task.sleep(for: .seconds(1))
    key(kVK_ANSI_S, flags: shortcutFlags)
    try await wait("全屏录制未完成保存。", timeout: 30) { control(ax, id: "recording.openVideo") != nil }
    try clickControl(ax, id: "recording.openVideo")
    try await wait("打开视频后完成窗口未关闭。") { control(ax, id: "recording.close") == nil }
    print("通过：打开视频后完成窗口自动关闭。")
    let quitSaved = files().subtracting(beforeQuit)
    try require(quitSaved.count == 1, "全屏录制未保存视频。")
    let quitAsset = AVURLAsset(url: quitSaved.first!)
    let quitDuration = try await quitAsset.load(.duration).seconds
    try require(quitDuration > 0.8 && quitDuration < 2.5, "全屏录制的视频时长异常。")
    print("通过：全屏显式确认、细边框与视频保存。")
}

Task { @MainActor in
    do { try await run(); exit(0) }
    catch { fputs("录屏界面检查失败：\(error)\n", stderr); exit(1) }
}
NSApplication.shared.run()
