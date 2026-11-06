// 检查已打开的设置窗口；只读取界面元数据，不读取剪贴板或更改应用配置。
// 需要调用进程已有辅助功能权限；不主动请求授权。
import AppKit
import ApplicationServices
import Carbon

struct SettingsFailure: Error, CustomStringConvertible {
    let description: String
}
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw SettingsFailure(description: message) }
}
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
func elements(_ root: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 12 else { return [] }
    return [root] + (attribute(root, kAXChildrenAttribute) as? [AXUIElement] ?? []).flatMap {
        elements($0, depth: depth + 1)
    }
}
func waitFor(_ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(2)
    repeat {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    } while Date() < deadline
    return condition()
}
func flag(_ element: AXUIElement, _ key: String) -> Bool {
    (attribute(element, key) as? NSNumber)?.boolValue == true
}
func key(_ code: CGKeyCode, pid: pid_t) {
    CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)?.postToPid(pid)
    CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)?.postToPid(pid)
}

do {
    try require(AXIsProcessTrusted(), "需要调用进程已有辅助功能权限，未请求授权。")
    let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "app.pasteman.PasteMan" }
    try require(apps.count == 1, "请只运行一个应用实例并打开设置。")
    let app = apps[0]
    let application = AXUIElementCreateApplication(app.processIdentifier)
    let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
    let labels = [["通用", "General"], ["截图", "Screenshots"], ["剪贴板", "Clipboard"],
                  ["右键菜单", "Context Menu"], ["鼠标", "Mouse"], ["权限", "Permissions"]]
    func tabs(in window: AXUIElement) -> [AXUIElement] {
        let all = elements(window)
        return labels.compactMap { titles in
            all.first {
                attribute($0, kAXRoleAttribute) as? String == kAXButtonRole
                    && titles.contains(attribute($0, kAXTitleAttribute) as? String
                        ?? attribute($0, kAXDescriptionAttribute) as? String ?? "")
            }
        }
    }
    guard let window = windows.first(where: { tabs(in: $0).count == labels.count }) else {
        throw SettingsFailure(description: "找不到包含六个标签项的设置窗口。")
    }
    let original = tabs(in: window).firstIndex { flag($0, kAXSelectedAttribute) } ?? 0
    app.activate()
    func press(_ index: Int) throws {
        let current = tabs(in: window)
        try require(current.count == labels.count, "标签项数量错误。")
        try require(AXUIElementPerformAction(current[index], kAXPressAction as CFString) == .success, "标签点击失败。")
    }
    func matches(_ index: Int, requiresFocus: Bool = true) -> Bool {
        let current = tabs(in: window)
        let text = elements(window).flatMap { element in
            [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap {
                attribute(element, $0) as? String
            }
        }
        let pageMatches: Bool
        switch index {
        case 0: pageMatches = text.contains("开机启动") || text.contains("Launch at login")
        case 1:
            pageMatches = (text.contains("快捷键") || text.contains("Shortcut"))
                && !text.contains("保留时间") && !text.contains("Keep history")
        case 2: pageMatches = text.contains("保留时间") || text.contains("Keep history")
        case 3: pageMatches = text.contains("启用右键菜单") || text.contains("Enable context menu")
        case 4: pageMatches = text.contains("启用鼠标增强") || text.contains("Enable mouse enhancement")
        default: pageMatches = text.contains("访达扩展") || text.contains("Finder Extension")
        }
        let focused = current.indices.filter { flag(current[$0], kAXFocusedAttribute) }
        return pageMatches && current.count == labels.count
            && current.indices.filter { flag(current[$0], kAXSelectedAttribute) } == [index]
            && (focused == [index] || (!requiresFocus && focused.isEmpty))
    }
    if CommandLine.arguments.contains("--expect-finder") {
        try require(waitFor { matches(3, requiresFocus: false) }, "从访达入口打开设置时，未保持右键菜单标签。")
        print("通过：指定标签打开后，页面及唯一选中项正确，无其他标签残留焦点。")
    }
    defer { try? press(original) }
    for index in [2, 0, 5, 4, 1, 3, 2] {
        try press(index)
        try require(waitFor { matches(index) }, "第 \(index + 1) 个标签的焦点与唯一选中状态不一致。")
    }
    print("通过：逐项点击后，焦点、唯一选中项与页面内容一致。")
    for index in [3, 4, 5, 0, 1, 2] {
        key(CGKeyCode(kVK_RightArrow), pid: app.processIdentifier)
        try require(waitFor { matches(index) }, "向右切换后，焦点与选中状态不一致。")
    }
    for index in [1, 0, 5, 4, 3, 2] {
        key(CGKeyCode(kVK_LeftArrow), pid: app.processIdentifier)
        try require(waitFor { matches(index) }, "向左切换后，焦点与选中状态不一致。")
    }
    print("通过：左右方向键切换及首尾循环保持唯一选中。")
} catch {
    fputs("设置检查失败：\(error)\n", stderr)
    exit(1)
}
