// 交互验证：默认检查应用链接；--context-menu 通过已启用的真实访达菜单检查新建与复制。
// 仅操作临时合成文件；菜单模式会将合成路径和文件名写入剪贴板，不更改系统权限。
import AppKit
import ApplicationServices
import Foundation

struct FinderSmokeError: Error, CustomStringConvertible {
    let description: String
}

final class FinderFocusObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var activations = 0
    private var observer: NSObjectProtocol?

    init(bundleID: String) {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app.bundleIdentifier == bundleID, let self else { return }
            lock.lock()
            activations += 1
            lock.unlock()
        }
    }

    var hostActivations: Int {
        lock.lock()
        defer { lock.unlock() }
        return activations
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

func find(_ element: AXUIElement, role: String, title: String? = nil, depth: Int = 0) -> AXUIElement? {
    guard depth < 20 else { return nil }
    if attribute(element, kAXRoleAttribute) as? String == role,
        title == nil || attribute(element, kAXTitleAttribute) as? String == title
            || attribute(element, kAXValueAttribute) as? String == title
    {
        return element
    }
    for child in children(element) {
        if let found = find(child, role: role, title: title, depth: depth + 1) { return found }
    }
    return nil
}

@MainActor func waitForElement(_ app: AXUIElement, role: String, title: String? = nil) async throws -> AXUIElement {
    for _ in 0..<100 {
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        for window in windows {
            if let element = find(window, role: role, title: title) { return element }
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw FinderSmokeError(description: "未出现预期控件：\(title ?? role)")
}

func press(_ element: AXUIElement) throws {
    guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
        throw FinderSmokeError(description: "无法点击目标按钮。")
    }
}

@MainActor func invokeFinderMenu(_ title: String, in directory: URL, selection: [URL]? = nil) async throws {
    NSWorkspace.shared.open(directory)
    guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
        throw FinderSmokeError(description: "访达未运行。")
    }
    let app = AXUIElementCreateApplication(finder.processIdentifier)
    var target: AXUIElement?
    for _ in 0..<100 {
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        target = windows.first { attribute($0, kAXTitleAttribute) as? String == directory.lastPathComponent }
        if target != nil { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    guard let window = target else { throw FinderSmokeError(description: "未找到合成测试目录的访达窗口。") }
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    func content(_ element: AXUIElement) -> AXUIElement? {
        let description = attribute(element, kAXDescriptionAttribute) as? String ?? ""
        if ["列表视图", "图标视图", "list view", "icon view"].contains(description) { return element }
        for child in children(element) { if let found = content(child) { return found } }
        return nil
    }
    guard let view = content(window) else {
        throw FinderSmokeError(description: "请将访达测试目录设为列表或图标视图后重试。")
    }
    if let selection {
        func selectedFileURLs(_ node: AXUIElement, depth: Int = 0) -> Set<String> {
            guard depth < 5 else { return [] }
            if let url = attribute(node, kAXURLAttribute) as? NSURL, let path = url.filePathURL {
                return [path.resolvingSymlinksInPath().standardizedFileURL.path]
            }
            return children(node).reduce(into: Set<String>()) { result, child in
                result.formUnion(selectedFileURLs(child, depth: depth + 1))
            }
        }
        let expected = Set(selection.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        var ready = false
        for attempt in 0..<100 {
            let selected = attribute(view, kAXSelectedChildrenAttribute) as? [AXUIElement]
                ?? attribute(view, kAXSelectedRowsAttribute) as? [AXUIElement] ?? []
            let paths = selected.reduce(into: Set<String>()) { $0.formUnion(selectedFileURLs($1)) }
            if paths == expected { ready = true; break }
            if attempt == 2 || attempt == 10 {
                // 访达撤销后 reveal 有时只打开窗口而不恢复选区，明确选中合成行后再验收菜单。
                let rows = attribute(view, kAXRowsAttribute) as? [AXUIElement] ?? []
                let matches = rows.filter { !selectedFileURLs($0).isDisjoint(with: expected) }
                if matches.count == expected.count {
                    _ = AXUIElementSetAttributeValue(view, kAXSelectedRowsAttribute as CFString, matches as CFArray)
                    _ = AXUIElementSetAttributeValue(view, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard ready else { throw FinderSmokeError(description: "访达尚未选中本次要求的合成文件，拒绝打开剪切菜单。") }
    }
    guard AXUIElementPerformAction(view, kAXShowMenuAction as CFString) == .success else {
        throw FinderSmokeError(description: "无法打开合成目录的右键菜单。")
    }
    var menu: AXUIElement?
    for _ in 0..<100 {
        menu = find(view, role: kAXMenuRole)
        if menu != nil { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    guard let menu else { throw FinderSmokeError(description: "未找到访达右键菜单。") }
    defer { AXUIElementPerformAction(menu, kAXCancelAction as CFString) }
    // 扩展菜单晚于系统菜单异步加入，不能在菜单刚出现时就断言缺少扩展项目。
    let requestedTitle = title.hasPrefix(".") ? "新建文件" : title
    for _ in 0..<100 {
        if children(menu).contains(where: { attribute($0, kAXTitleAttribute) as? String == requestedTitle }) { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    let topItems = children(menu)
    let expectedTitles = CommandLine.arguments.contains("--terminal-only") || CommandLine.arguments.contains("--move-only")
        ? [requestedTitle] : ["新建文件", "复制完整路径", "复制文件名", "在此处打开终端", "访达菜单设置…"]
    for expected in expectedTitles {
        guard topItems.contains(where: { attribute($0, kAXTitleAttribute) as? String == expected }) else {
            throw FinderSmokeError(description: "一级菜单缺少：\(expected)，请启用扩展并保留默认操作。当前项目：\(topItems.compactMap { attribute($0, kAXTitleAttribute) as? String })")
        }
    }
    guard !topItems.contains(where: { attribute($0, kAXTitleAttribute) as? String == "EasyMacOS" }) else {
        throw FinderSmokeError(description: "仍存在旧的外层子菜单。")
    }
    if title.hasPrefix(".") {
        let creation = topItems.first { attribute($0, kAXTitleAttribute) as? String == "新建文件" }!
        try press(creation)
        guard let type = find(creation, role: kAXMenuItemRole, title: title) else {
            throw FinderSmokeError(description: "新建文件子菜单没有 \(title)。")
        }
        try press(type)
    } else {
        guard let item = topItems.first(where: { attribute($0, kAXTitleAttribute) as? String == title }) else {
            throw FinderSmokeError(description: "一级菜单没有预期操作：\(title)")
        }
        try press(item)
    }
}

@MainActor func renameField(for file: URL) -> AXUIElement? {
    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder",
        let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
    else { return nil }
    let app = AXUIElementCreateApplication(finder.processIdentifier)
    guard let focused = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID()
    else { return nil }
    let element = unsafeDowncast(focused, to: AXUIElement.self)
    guard attribute(element, kAXRoleAttribute) as? String == kAXTextFieldRole,
        let value = attribute(element, kAXValueAttribute) as? String,
        value == file.lastPathComponent || value == file.deletingPathExtension().lastPathComponent
    else { return nil }
    return element
}

@MainActor func cancelRename(for file: URL) throws {
    guard renameField(for: file) != nil,
        let finder = NSWorkspace.shared.frontmostApplication, finder.bundleIdentifier == "com.apple.finder",
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true),
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)
    else { throw FinderSmokeError(description: "取消前未确认合成文件正在重命名。") }
    down.postToPid(finder.processIdentifier)
    up.postToPid(finder.processIdentifier)
}

@MainActor func terminalWindows() -> [AXUIElement] {
    guard let terminal = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first else {
        return []
    }
    return attribute(AXUIElementCreateApplication(terminal.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
}

@MainActor func checkTerminal(in directory: URL) async throws {
    let before = terminalWindows()
    let clipboardBefore = NSPasteboard.general.changeCount
    func addedWindows() -> [AXUIElement] {
        terminalWindows().filter { window in !before.contains { CFEqual($0, window) } }
    }
    defer {
        // 仅关闭本次创建且工作目录等于合成目录的终端，不读取或更改已有终端。
        for window in addedWindows() {
            guard let path = attribute(window, kAXDocumentAttribute) as? String,
                let url = URL(string: path), url.resolvingSymlinksInPath().standardizedFileURL.path
                    == directory.resolvingSymlinksInPath().standardizedFileURL.path,
                let close = attribute(window, kAXCloseButtonAttribute), CFGetTypeID(close) == AXUIElementGetTypeID()
            else { continue }
            _ = AXUIElementPerformAction(unsafeDowncast(close, to: AXUIElement.self), kAXPressAction as CFString)
        }
    }
    try await invokeFinderMenu("在此处打开终端", in: directory)
    for _ in 0..<100 {
        if !addedWindows().isEmpty { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    // 多余窗口可能晚于首个窗口出现，继续观察一次完整服务响应时间。
    try await Task.sleep(for: .seconds(1))
    let added = addedWindows()
    guard added.count == 1 else {
        throw FinderSmokeError(description: "一次终端菜单操作产生 \(added.count) 个新窗口，应恰好一个。")
    }
    guard let path = attribute(added[0], kAXDocumentAttribute) as? String,
        let url = URL(string: path), url.resolvingSymlinksInPath().standardizedFileURL.path
            == directory.resolvingSymlinksInPath().standardizedFileURL.path
    else { throw FinderSmokeError(description: "新终端工作目录不是合成测试目录。") }
    guard NSPasteboard.general.changeCount == clipboardBefore else {
        throw FinderSmokeError(description: "打开终端意外改写了用户剪贴板。")
    }
    print("通过：一次菜单点击只打开一个终端窗口，工作目录正确，用户剪贴板未改变。")
}

@MainActor func runSmoke() async throws {
    guard AXIsProcessTrusted() else { throw FinderSmokeError(description: "验证终端尚无辅助功能权限；未请求或修改权限。") }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("EasyMacOS访达检查-' 空格-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let appPath = CommandLine.arguments.dropFirst().first ?? "dist/EasyMacOS.app"
    let appURL = URL(fileURLWithPath: appPath).standardizedFileURL
    guard let bundleID = Bundle(url: appURL)?.bundleIdentifier,
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
        running.bundleURL?.standardizedFileURL == appURL,
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count == 1
    else { throw FinderSmokeError(description: "请先运行且仅运行指定路径的待验证应用。") }
    if CommandLine.arguments.contains("--terminal-only") {
        for _ in 0..<2 { try await checkTerminal(in: root) }
        return
    }
    if CommandLine.arguments.contains("--move-only") {
        try await checkCutAndMove(in: root, host: running)
        return
    }
    if CommandLine.arguments.contains("--office-only") {
        let focus = FinderFocusObservation(bundleID: bundleID)
        for suffix in ["docx", "xlsx", "pptx", "pdf"] {
            let template = appURL.appendingPathComponent("Contents/Resources/EasyMacOS_FinderMenuCore.bundle/OfficeTemplates/blank." + suffix)
            let expected = try Data(contentsOf: template)
            let original = root.appendingPathComponent("未命名." + suffix)
            try Data("需要保留的原内容".utf8).write(to: original)
            for number in 2...3 {
                try await invokeFinderMenu("." + suffix, in: root)
                let output = root.appendingPathComponent("未命名 \(number)." + suffix)
                for _ in 0..<100 {
                    if FileManager.default.fileExists(atPath: output.path) { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard (try? Data(contentsOf: output)) == expected else {
                    throw FinderSmokeError(description: "真实菜单未创建有效模板：" + output.lastPathComponent)
                }
                var editing = false
                for _ in 0..<55 {
                    if renameField(for: output) != nil { editing = true; break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                if CommandLine.arguments.contains("--expect-rename") && !editing {
                    throw FinderSmokeError(description: "办公文档未进入原地重命名：" + suffix)
                }
                if editing { try cancelRename(for: output) }
                guard try Data(contentsOf: output) == expected else {
                    throw FinderSmokeError(description: "取消重命名后文档内容改变：" + suffix)
                }
                print("通过：真实访达菜单创建 \(output.lastPathComponent)，模板内容一致，\(editing ? "原地重命名并取消" : "保留文件")。")
            }
            guard try String(contentsOf: original, encoding: .utf8) == "需要保留的原内容" else {
                throw FinderSmokeError(description: "办公文档覆盖了同名原件：" + suffix)
            }
        }
        guard focus.hostActivations == 0 else { throw FinderSmokeError(description: "办公新建时宿主抢占前台。") }
        print("通过：四种办公文档真实菜单连续新建、同名保护、取消后保留和后台焦点。")
        return
    }
    let contextMenu = CommandLine.arguments.contains("--context-menu")
    let expectBackground = CommandLine.arguments.contains("--expect-background")
    guard !expectBackground || contextMenu else {
        throw FinderSmokeError(description: "后台焦点检查须与真实菜单模式一起运行。")
    }
    let focus = expectBackground ? FinderFocusObservation(bundleID: bundleID) : nil
    let expectRename = CommandLine.arguments.contains("--expect-rename")
    let expectFallback = CommandLine.arguments.contains("--expect-fallback")
    guard !(expectRename && expectFallback) else { throw FinderSmokeError(description: "不能同时要求授权和未授权分支。") }

    func invoke() async throws {
        if contextMenu { try await invokeFinderMenu(".txt", in: root) }
        else {
            var components = URLComponents()
            components.scheme = "easymacos"
            components.host = "finder"
            // 保留不携带后缀的旧链接，验证默认文本类型兼容。
            components.queryItems = [URLQueryItem(name: "action", value: "newText"), URLQueryItem(name: "path", value: root.path)]
            _ = try await NSWorkspace.shared.open([components.url!], withApplicationAt: appURL, configuration: .init())
        }
    }

    for number in 1...2 {
        let output = root.appendingPathComponent(number == 1 ? "未命名.txt" : "未命名 2.txt")
        try await invoke()
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: output.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard FileManager.default.fileExists(atPath: output.path), try Data(contentsOf: output).isEmpty else {
            throw FinderSmokeError(description: "没有直接创建预期的零字节文件：\(output.lastPathComponent)")
        }
        var editing = false
        var hinted = false
        let host = AXUIElementCreateApplication(running.processIdentifier)
        for _ in 0..<55 {
            if renameField(for: output) != nil { editing = true; break }
            for window in attribute(host, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
                if find(window, role: kAXStaticTextRole, title: "文件已创建，可选中后按回车重命名") != nil
                    || find(window, role: kAXStaticTextRole, title: "文件已创建，自动重命名需要辅助功能权限") != nil { hinted = true }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        if expectRename && !editing { throw FinderSmokeError(description: "文件已创建，但没有自动进入原地重命名。") }
        if expectFallback && (editing || !hinted) { throw FinderSmokeError(description: "未观察到预期的未授权提示分支。") }
        guard editing || hinted else { throw FinderSmokeError(description: "既未进入重命名，也未观察到自动关闭提示。") }
        if editing {
            try cancelRename(for: output)
            try await Task.sleep(for: .milliseconds(150))
            guard FileManager.default.fileExists(atPath: output.path) else { throw FinderSmokeError(description: "取消重命名后文件丢失。") }
        }
        print("通过：立即创建 \(output.lastPathComponent)，\(editing ? "已进入原地重命名，取消后保留文件" : "保留文件并提示手动重命名")。")
        if number == 1 { try Data("需要保留的原内容".utf8).write(to: output) }
    }
    let original = root.appendingPathComponent("未命名.txt")
    guard try String(contentsOf: original, encoding: .utf8) == "需要保留的原内容" else {
        throw FinderSmokeError(description: "自动编号时原文件被意外改写。")
    }
    print("通过：重名自动编号且保留原文件内容。")

    if contextMenu {
        let output = root.appendingPathComponent("未命名 2.txt")
        for (title, expected) in [("复制完整路径", output.path), ("复制文件名", output.lastPathComponent)] {
            let before = NSPasteboard.general.changeCount
            try await invokeFinderMenu(title, in: root)
            for _ in 0..<100 {
                if NSPasteboard.general.changeCount != before { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard NSPasteboard.general.changeCount != before,
                NSPasteboard.general.string(forType: .string) == expected else {
                throw FinderSmokeError(description: "\(title)未返回预期的合成结果。")
            }
            print("通过：真实访达一级菜单\(title)。")
        }
    }
    if let focus {
        guard focus.hostActivations == 0 else {
            throw FinderSmokeError(description: "文件操作期间主应用抢占前台焦点 \(focus.hostActivations) 次。")
        }
        print("通过：真实菜单新建与复制期间主应用没有激活，焦点保持在访达。")
    }
}

@MainActor func checkCutAndMove(in root: URL, host: NSRunningApplication) async throws {
    let session = UUID().uuidString
    // 每次窗口标题唯一，防止验收脚本定位到上次测试遗留的同名访达窗口。
    let source = root.appendingPathComponent("剪切源-" + session, isDirectory: true)
    let destination = root.appendingPathComponent("移动目标-" + session, isDirectory: true)
    for directory in [source, destination] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let file = source.appendingPathComponent("中文 空格 ' &$.txt")
    let folder = source.appendingPathComponent("子文件夹", isDirectory: true)
    try Data("合成文件，移动后必须完整".utf8).write(to: file)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: folder.appendingPathComponent("内部文件"))
    let stateURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/EasyMacOS/finder-cut.json")
    func cutState() -> [String: Any]? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    func wait(_ description: String, condition: () throws -> Bool) async throws {
        for _ in 0..<100 {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw FinderSmokeError(description: description)
    }
    func cut(_ files: [URL], in directory: URL) async throws {
        let previous = cutState()?["token"] as? String
        try await invokeFinderMenu("剪切", in: directory, selection: files)
        try await wait("剪切记录未写入。") {
            guard let state = cutState(), let token = state["token"] as? String else { return false }
            return token != previous && state["fileCount"] as? Int == files.count
        }
        guard files.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw FinderSmokeError(description: "剪切阶段意外改变了源文件。")
        }
    }
    func finderKey(_ code: CGKeyCode, flags: CGEventFlags) throws {
        guard let finder = NSWorkspace.shared.frontmostApplication, finder.bundleIdentifier == "com.apple.finder",
            let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
            throw FinderSmokeError(description: "访达未在前台，拒绝发送验证按键。")
        }
        down.flags = flags
        up.flags = flags
        down.postToPid(finder.processIdentifier)
        up.postToPid(finder.processIdentifier)
    }
    let focus = FinderFocusObservation(bundleID: host.bundleIdentifier!)
    try await cut([file, folder], in: source)
    print("通过：文件和文件夹多选剪切只标记，不改动源文件。")
    try await invokeFinderMenu("粘贴（移动）", in: destination)
    let movedFile = destination.appendingPathComponent(file.lastPathComponent)
    let movedFolder = destination.appendingPathComponent(folder.lastPathComponent)
    try await wait("多选粘贴没有完成原生移动。") {
        FileManager.default.fileExists(atPath: movedFile.path) && FileManager.default.fileExists(atPath: movedFolder.path)
            && !FileManager.default.fileExists(atPath: file.path) && !FileManager.default.fileExists(atPath: folder.path)
    }
    guard try String(contentsOf: movedFile, encoding: .utf8) == "合成文件，移动后必须完整",
        try Data(contentsOf: movedFolder.appendingPathComponent("内部文件")) == Data([1, 2, 3]),
        cutState()?["consumed"] as? Bool == true else {
        throw FinderSmokeError(description: "移动后内容或一次性剪切状态不正确。")
    }
    print("通过：一次原生移动完成多选，内容正确，剪切记录已消费。")
    try finderKey(6, flags: .maskCommand)
    try await wait("系统撤销没有还原此次合成移动。") {
        FileManager.default.fileExists(atPath: file.path) && FileManager.default.fileExists(atPath: folder.path)
            && !FileManager.default.fileExists(atPath: movedFile.path)
    }
    print("通过：访达系统撤销恢复了源文件及文件夹。")

    let conflictSource = root.appendingPathComponent("冲突源-" + session, isDirectory: true)
    let conflictTarget = root.appendingPathComponent("冲突目标-" + session, isDirectory: true)
    for directory in [conflictSource, conflictTarget] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    let conflictFile = conflictSource.appendingPathComponent(file.lastPathComponent)
    let conflictExisting = conflictTarget.appendingPathComponent(file.lastPathComponent)
    try Data("合成文件，移动后必须完整".utf8).write(to: conflictFile)
    try Data("目标原内容".utf8).write(to: conflictExisting)
    try await cut([conflictFile], in: conflictSource)
    try await invokeFinderMenu("粘贴（移动）", in: conflictTarget)
    guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
        throw FinderSmokeError(description: "访达已退出。")
    }
    let finderAX = AXUIElementCreateApplication(finder.processIdentifier)
    var stop: AXUIElement?
    try await wait("未观察到访达同名冲突对话框。") {
        var windows: [AXUIElement] = []
        if let focused = attribute(finderAX, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
            windows.insert(unsafeDowncast(focused, to: AXUIElement.self), at: 0)
        }
        for window in windows {
            for title in ["停止", "取消", "Stop", "Cancel"] {
                func conflictButton(_ node: AXUIElement, depth: Int = 0) -> AXUIElement? {
                    guard depth < 10 else { return nil }
                    let role = attribute(node, kAXRoleAttribute) as? String
                    guard role != kAXOutlineRole, role != kAXTableRole else { return nil }
                    if role == kAXButtonRole, attribute(node, kAXTitleAttribute) as? String == title { return node }
                    for child in children(node) {
                        if let found = conflictButton(child, depth: depth + 1) { return found }
                    }
                    return nil
                }
                if let button = conflictButton(window) { stop = button; return true }
            }
        }
        return false
    }
    try press(stop!)
    try await Task.sleep(for: .milliseconds(250))
    guard try String(contentsOf: conflictFile, encoding: .utf8) == "合成文件，移动后必须完整",
        try String(contentsOf: conflictExisting, encoding: .utf8) == "目标原内容" else {
        throw FinderSmokeError(description: "冲突取消后源文件或目标文件被修改。")
    }
    print("通过：冲突由访达提示，取消后源文件及目标原内容均保留。")

    if let volumePath = ProcessInfo.processInfo.environment["EASYMACOS_MOVE_VOLUME"] {
        let volumeRoot = URL(fileURLWithPath: volumePath, isDirectory: true)
        guard volumeRoot.path.hasPrefix(FileManager.default.temporaryDirectory.path),
            FileManager.default.fileExists(atPath: volumeRoot.path) else {
            throw FinderSmokeError(description: "跨卷目标必须是本机临时目录下的合成测试卷。")
        }
        let crossTarget = volumeRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: crossTarget, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: crossTarget) }
        try await cut([file], in: source)
        try await invokeFinderMenu("粘贴（移动）", in: crossTarget)
        let crossFile = crossTarget.appendingPathComponent(file.lastPathComponent)
        try await wait("跨卷移动没有完成。") {
            FileManager.default.fileExists(atPath: crossFile.path) && !FileManager.default.fileExists(atPath: file.path)
        }
        guard try String(contentsOf: crossFile, encoding: .utf8) == "合成文件，移动后必须完整" else {
            throw FinderSmokeError(description: "跨卷移动内容不正确。")
        }
        print("通过：临时测试卷的跨磁盘移动完成，源文件仅在移动成功后消失。")
    }
    guard focus.hostActivations == 0 else { throw FinderSmokeError(description: "剪切或移动时主应用抢占前台。") }
    print("通过：剪切与移动期间主应用未抢占焦点。")
}

Task { @MainActor in
    do {
        try await runSmoke()
        exit(0)
    } catch {
        fputs("验证失败：\(error)\n", stderr)
        exit(1)
    }
}
dispatchMain()
