// 对已打开的设置窗口验证双语切换，结束后恢复原语言与标签。
// 需要调用进程已有辅助功能权限；不读写剪贴板，不请求授权。
import AppKit
import ApplicationServices
import Carbon

struct LanguageFailure: Error, CustomStringConvertible {
    let description: String
}
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw LanguageFailure(description: message) }
}
func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
    return value
}
func elements(_ root: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 12 else { return [] }
    return [root] + (attribute(root, kAXChildrenAttribute) as? [AXUIElement] ?? []).flatMap {
        elements($0, depth: depth + 1)
    }
}
func title(_ element: AXUIElement) -> String {
    attribute(element, kAXTitleAttribute) as? String ?? attribute(element, kAXDescriptionAttribute) as? String ?? ""
}
func waitFor(_ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(3)
    repeat {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    } while Date() < deadline
    return condition()
}
func press(_ element: AXUIElement) throws {
    try require(AXUIElementPerformAction(element, kAXPressAction as CFString) == .success, "界面操作失败。")
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
    func tab(_ index: Int, in window: AXUIElement) -> AXUIElement? {
        elements(window).first {
            attribute($0, kAXRoleAttribute) as? String == kAXButtonRole && labels[index].contains(title($0))
        }
    }
    guard let window = windows.first(where: { tab(0, in: $0) != nil }) else {
        throw LanguageFailure(description: "未找到设置窗口。")
    }
    let originalTab = labels.indices.first {
        guard let item = tab($0, in: window) else { return false }
        return (attribute(item, kAXSelectedAttribute) as? NSNumber)?.boolValue == true
    } ?? 0
    app.activate()
    func showTab(_ index: Int) throws {
        guard let item = tab(index, in: window) else { throw LanguageFailure(description: "未找到标签。") }
        try press(item)
    }
    func languagePicker() -> AXUIElement? {
        elements(window).first { attribute($0, kAXRoleAttribute) as? String == kAXPopUpButtonRole }
    }
    try showTab(0)
    try require(waitFor { languagePicker() != nil }, "通用页未显示语言选项。")
    let originalLanguage = languagePicker().flatMap { attribute($0, kAXValueAttribute) as? String } ?? "简体中文"
    func select(_ name: String) throws {
        try showTab(0)
        try require(waitFor { languagePicker() != nil }, "语言选项未显示。")
        guard languagePicker() != nil else { throw LanguageFailure(description: "未找到语言选项。") }
        if languagePicker().flatMap({ attribute($0, kAXValueAttribute) as? String }) == name { return }
        var item: AXUIElement?
        // 标签切换后的布局可能替换选择器，等待时每次重新取得当前元素。
        for attempt in 0..<2 {
            guard let current = languagePicker() else { continue }
            if attempt == 0 {
                try press(current)
            } else {
                // 系统偶尔接受按下动作却不展开；使用已聚焦的选择器处理空格键。
                _ = AXUIElementSetAttributeValue(current, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Space), keyDown: down)
                    event?.flags = []
                    event?.postToPid(app.processIdentifier)
                }
            }
            if waitFor({
                item = languagePicker().flatMap { picker in
                    elements(picker).first {
                        attribute($0, kAXRoleAttribute) as? String == kAXMenuItemRole && title($0) == name
                    }
                }
                return item != nil
            }) { break }
            if let current = languagePicker() {
                _ = AXUIElementPerformAction(current, kAXCancelAction as CFString)
            }
        }
        if item == nil {
            let current = languagePicker()
            let value = current.flatMap { attribute($0, kAXValueAttribute) as? String } ?? "无"
            let available = current.map { elements($0).map { title($0) }.filter { !$0.isEmpty } } ?? []
            throw LanguageFailure(description: "语言菜单未显示目标选项 \(name)，当前值：\(value)，菜单：\(available)。")
        }
        if let item { try press(item) }
        try require(waitFor {
            guard let picker = languagePicker() else { return false }
            return attribute(picker, kAXValueAttribute) as? String == name
        }, "语言选择未更新。")
    }
    defer {
        try? select(originalLanguage)
        try? showTab(originalTab)
    }
    for (name, english) in [("简体中文", false), ("English", true), ("简体中文", false)] {
        try select(name)
        try require(waitFor {
            title(window) == (english ? "EasyMacOS Settings" : "EasyMacOS 设置")
                && labels.indices.allSatisfy { index in
                    guard let item = tab(index, in: window) else { return false }
                    return title(item) == labels[index][english ? 1 : 0]
                }
        }, "设置标题或标签未立即切换语言。")
        try showTab(3)
        try require(waitFor {
            elements(window).contains {
                let value = attribute($0, kAXValueAttribute) as? String ?? title($0)
                return value == (english ? "Enable context menu" : "启用右键菜单")
            }
        }, "右键菜单设置未切换语言。")
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/EasyMacOS/finder-menu.json")
        let data = try Data(contentsOf: config)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        try require(json?["language"] as? String == (english ? "en" : "zh-Hans"), "访达扩展语言未保存。")
        try showTab(4)
        try require(waitFor {
            let text = elements(window).map {
                attribute($0, kAXValueAttribute) as? String ?? title($0)
            }
            return text.contains(english ? "Enable mouse enhancement" : "启用鼠标增强")
                && text.contains(english ? "Remote wheel compatibility" : "远程滚轮兼容")
        }, "鼠标设置未切换语言。")
        print("通过：\(name) 立即更新窗口、六个标签、鼠标及右键菜单设置和扩展语言配置。")
    }
} catch {
    fputs("语言检查失败：\(error)\n", stderr)
    exit(1)
}
