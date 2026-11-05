// 对已打开的设置页验证总开关与真实接管状态，结束后恢复开关和标签。
// 不滚动其他应用、不请求权限；要求调用进程和被测应用均已有辅助功能权限。
import AppKit
import ApplicationServices

struct MouseFailure: Error, CustomStringConvertible { let description: String }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw MouseFailure(description: message) }
}
func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
    return value
}
func elements(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 12 else { return [] }
    return [element] + (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).flatMap {
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
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    } while Date() < deadline
    return condition()
}

do {
    try require(AXIsProcessTrusted(), "需要调用进程已有辅助功能权限，不请求授权。")
    let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "app.pasteman.PasteMan" }
    try require(apps.count == 1, "请只运行一个应用实例并打开设置。")
    let app = apps[0]
    let root = AXUIElementCreateApplication(app.processIdentifier)
    let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
    guard let window = windows.first(where: { window in
        elements(window).contains { ["鼠标", "Mouse"].contains(title($0)) }
    }) else { throw MouseFailure(description: "没有找到含鼠标标签的设置窗口。") }
    let originalTab = elements(window).first {
        attribute($0, kAXRoleAttribute) as? String == kAXButtonRole
            && (attribute($0, kAXSelectedAttribute) as? NSNumber)?.boolValue == true
    }
    app.activate()
    guard let tab = elements(window).first(where: { ["鼠标", "Mouse"].contains(title($0)) }) else {
        throw MouseFailure(description: "没有找到鼠标标签。")
    }
    try require(AXUIElementPerformAction(tab, kAXPressAction as CFString) == .success, "无法打开鼠标页。")
    defer {
        if let originalTab { _ = AXUIElementPerformAction(originalTab, kAXPressAction as CFString) }
    }
    func toggle() -> AXUIElement? {
        elements(window).first { attribute($0, kAXRoleAttribute) as? String == kAXCheckBoxRole }
    }
    func enabled() -> Bool {
        toggle().flatMap { attribute($0, kAXValueAttribute) as? NSNumber }?.boolValue == true
    }
    func shows(_ labels: [String]) -> Bool {
        elements(window).contains { labels.contains(attribute($0, kAXValueAttribute) as? String ?? title($0)) }
    }
    try require(waitFor { toggle() != nil && shows(["启用鼠标增强", "Enable mouse enhancement"]) }, "鼠标页未就绪。")
    let originalEnabled = enabled()
    func setEnabled(_ desired: Bool) throws {
        if enabled() != desired, let toggle = toggle() {
            try require(AXUIElementPerformAction(toggle, kAXPressAction as CFString) == .success, "总开关操作失败。")
        }
        try require(waitFor { enabled() == desired }, "总开关未更新。")
    }
    defer { try? setEnabled(originalEnabled) }
    try setEnabled(false)
    try require(waitFor { shows(["已关闭", "Disabled"]) }, "关闭后状态未更新。")
    try setEnabled(true)
    try require(waitFor { shows(["运行中", "Running"]) }, "未成功启动接管，请检查应用已有权限。")
    print("通过：安装后的鼠标总开关启动真实事件接管并显示运行中。")
    try setEnabled(false)
    try require(waitFor { shows(["已关闭", "Disabled"]) }, "停止后状态未更新。")
    print("通过：关闭增强后显示已关闭，结束时恢复原开关与标签。")
} catch {
    fputs("鼠标设置检查失败：\(error)\n", stderr)
    exit(1)
}
