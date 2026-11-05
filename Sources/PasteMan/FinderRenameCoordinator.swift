import AppKit
@preconcurrency import ApplicationServices

@MainActor enum FinderRenameAccess {
    static var isGranted: Bool { AXIsProcessTrusted() && CGPreflightPostEventAccess() }

    // 只从用户明确点击的授权按钮调用，创建文件时不弹出权限框。
    static func request() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
        if !isGranted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum FinderRenameFailure { case permissionRequired, selectionUnavailable }

struct FinderRenameSnapshot {
    var frontBundleID: String?
    var selection: [URL]?
    var modifiersReleased: Bool

    func matches(_ url: URL) -> Bool {
        frontBundleID == "com.apple.finder" && modifiersReleased
            && selection?.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
                == [url.standardizedFileURL.resolvingSymlinksInPath()]
    }
}

/// 所有系统交互均可替换；等待期间不再次激活访达，也不请求权限。
@MainActor struct FinderRenameEnvironment {
    var trusted: () -> Bool
    var reveal: (URL) -> Void
    var snapshot: () -> FinderRenameSnapshot
    var sendReturn: (URL, Duration) -> Bool
    var isEditingName: (URL) -> Bool
    var hint: (FinderRenameFailure) -> Void
    var now: () -> Duration
    var pause: () async -> Void

    static func live() -> Self {
        let clock = ContinuousClock()
        let start = clock.now
        return Self(
            trusted: { FinderRenameAccess.isGranted },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
            snapshot: { FinderRenameSystem.snapshot() },
            sendReturn: { FinderRenameSystem.sendReturn(for: $0, before: start.advanced(by: $1)) },
            isEditingName: { FinderRenameSystem.isEditingName(for: $0) },
            hint: { FinderCreationNotice.show(reason: $0) },
            now: { start.duration(to: clock.now) },
            pause: { try? await Task.sleep(for: .milliseconds(50)) })
    }
}

@MainActor struct FinderRenameCoordinator {
    var environment: FinderRenameEnvironment = .live()

    @discardableResult func revealAndRename(_ url: URL) async -> Bool {
        environment.reveal(url)
        guard environment.trusted() else { environment.hint(.permissionRequired); return false }
        let deadline = environment.now() + .seconds(2)
        var sawFinder = false
        while environment.now() < deadline, !Task.isCancelled {
            let state = environment.snapshot()
            if state.frontBundleID == "com.apple.finder" { sawFinder = true }
            else if sawFinder || (state.frontBundleID != Bundle.main.bundleIdentifier && state.frontBundleID != nil) {
                break
            }
            guard environment.trusted() else { break }
            if state.matches(url), environment.now() < deadline {
                // 发送前再次确认权限、前台、唯一选区与修饰键；系统实现也会最终复核。
                if environment.trusted(), environment.snapshot().matches(url), environment.trusted(), environment.now() < deadline,
                    environment.sendReturn(url, deadline) {
                    // 按键成功投递不代表访达已经进入编辑，继续确认真实名称输入框。
                    while environment.now() < deadline, !Task.isCancelled {
                        guard environment.trusted() else { break }
                        if environment.isEditingName(url) { return true }
                        guard environment.snapshot().frontBundleID == "com.apple.finder" else { break }
                        await environment.pause()
                    }
                }
                break
            }
            await environment.pause()
        }
        environment.hint(environment.trusted() ? .selectionUnavailable : .permissionRequired)
        return false
    }
}

@MainActor enum FinderRenameSystem {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func selectedURLs(pid: pid_t) -> [URL]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        guard let focused = attribute(app, kAXFocusedUIElementAttribute),
            CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var node = unsafeDowncast(focused, to: AXUIElement.self)
        // 已处于编辑状态时绝不发送回车，防止提交或退出用户正在进行的编辑。
        if attribute(node, kAXRoleAttribute) as? String == kAXTextFieldRole { return nil }
        let deadline = ContinuousClock.now + .milliseconds(150)
        for _ in 0..<12 {
            guard ContinuousClock.now < deadline else { return nil }
            for key in [kAXSelectedChildrenAttribute, kAXSelectedRowsAttribute] {
                if let selected = attribute(node, key) as? [AXUIElement], !selected.isEmpty {
                    guard selected.count == 1 else { return nil }
                    var budget = 64
                    let urls = urls(in: selected[0], budget: &budget, deadline: deadline)
                    return budget >= 0 && ContinuousClock.now < deadline && urls.count == 1 ? Array(urls) : nil
                }
            }
            guard let parent = attribute(node, kAXParentAttribute),
                CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            node = unsafeDowncast(parent, to: AXUIElement.self)
        }
        return nil
    }

    static func isEditingName(for url: URL) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == "com.apple.finder" else {
            return false
        }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.05)
        guard let focused = attribute(app, kAXFocusedUIElementAttribute),
            CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let field = unsafeDowncast(focused, to: AXUIElement.self)
        guard attribute(field, kAXRoleAttribute) as? String == kAXTextFieldRole,
            let value = attribute(field, kAXValueAttribute) as? String else { return false }
        return value == url.lastPathComponent || value == url.deletingPathExtension().lastPathComponent
    }

    static func urls(in element: AXUIElement, budget: inout Int, deadline: ContinuousClock.Instant) -> Set<URL> {
        guard budget > 0, ContinuousClock.now < deadline else { budget = -1; return [] }
        budget -= 1
        var result = Set<URL>()
        if let url = attribute(element, kAXURLAttribute) as? URL, url.isFileURL { result.insert(url) }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            result.formUnion(urls(in: child, budget: &budget, deadline: deadline))
        }
        return result
    }

    static func snapshot() -> FinderRenameSnapshot {
        let front = NSWorkspace.shared.frontmostApplication
        let mask: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]
        return FinderRenameSnapshot(
            frontBundleID: front?.bundleIdentifier,
            selection: front?.bundleIdentifier == "com.apple.finder" ? front.flatMap { selectedURLs(pid: $0.processIdentifier) } : nil,
            modifiersReleased: CGEventSource.flagsState(.combinedSessionState).intersection(mask).isEmpty)
    }

    static func sendReturn(for url: URL, before deadline: ContinuousClock.Instant) -> Bool {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess(), snapshot().matches(url),
            let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == "com.apple.finder",
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false)
        else { return false }
        guard ContinuousClock.now < deadline else { return false }
        down.flags = []
        up.flags = []
        down.postToPid(front.processIdentifier)
        up.postToPid(front.processIdentifier)
        return true
    }
}

@MainActor private final class FinderCreationNotice: NSObject {
    private static let actions = FinderCreationNotice()
    private static var panel: NSPanel?
    private static var dismissal: Task<Void, Never>?

    static func show(reason: FinderRenameFailure) {
        dismissal?.cancel()
        panel?.close()
        let needsPermission = reason == .permissionRequired
        let notice = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: needsPermission ? 112 : 64),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        notice.isReleasedWhenClosed = false
        notice.level = .floating
        notice.ignoresMouseEvents = !needsPermission
        notice.collectionBehavior = [.canJoinAllSpaces, .transient]
        notice.backgroundColor = .windowBackgroundColor
        notice.hasShadow = true
        let text = NSTextField(labelWithString: needsPermission
            ? "文件已创建，自动重命名需要辅助功能权限" : "文件已创建，可选中后按回车重命名")
        text.frame = NSRect(x: 16, y: needsPermission ? 72 : 22, width: 408, height: 22)
        text.alignment = .center
        notice.contentView?.addSubview(text)
        if needsPermission {
            let button = NSButton(title: "开启自动重命名…", target: actions, action: #selector(enableRename))
            button.bezelStyle = .rounded
            button.frame = NSRect(x: 130, y: 20, width: 180, height: 32)
            notice.contentView?.addSubview(button)
        }
        notice.center()
        notice.orderFrontRegardless()
        panel = notice
        dismissal = Task { @MainActor in
            try? await Task.sleep(for: .seconds(needsPermission ? 10 : 3))
            guard !Task.isCancelled else { return }
            notice.close()
            panel = nil
            dismissal = nil
        }
    }

    @objc private func enableRename() {
        Self.dismissal?.cancel()
        Self.dismissal = nil
        Self.panel?.close()
        Self.panel = nil
        FinderRenameAccess.request()
    }
}
