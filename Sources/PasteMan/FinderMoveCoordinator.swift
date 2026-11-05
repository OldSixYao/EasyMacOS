import AppKit
@preconcurrency import ApplicationServices
import FinderMenuCore

struct FinderMoveSnapshot {
    var frontBundleID: String?
    var directory: URL?
    var blocked: Bool
    var modifiersReleased: Bool
    var waitingForContext = false

    func matches(_ target: URL) -> Bool {
        frontBundleID == "com.apple.finder" && !blocked && modifiersReleased
            && directory?.resolvingSymlinksInPath().standardizedFileURL.path
                == target.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

@MainActor struct FinderMoveEnvironment {
    var trusted: () -> Bool
    var snapshot: () -> FinderMoveSnapshot
    var openDirectory: (URL) -> Void
    var sendMove: (URL, Duration, () throws -> Void) throws -> Bool
    var now: () -> Duration
    var pause: () async -> Void

    static func live() -> Self {
        let start = ContinuousClock.now
        return Self(
            trusted: { FinderRenameAccess.isGranted }, snapshot: { FinderMoveSystem.snapshot() },
            openDirectory: { NSWorkspace.shared.open($0) },
            sendMove: { try FinderMoveSystem.sendMove(to: $0, before: start.advanced(by: $1), validateClipboard: $2) },
            now: { start.duration(to: .now) }, pause: { try? await Task.sleep(for: .milliseconds(50)) })
    }
}

@MainActor struct FinderMoveCoordinator {
    var environment: FinderMoveEnvironment = .live()

    func move(token: UUID, to directory: URL, clipboard: FinderCutClipboard) async throws {
        let (state, files) = try clipboard.current(token: token)
        try FinderMoveValidation.destination(directory, for: files)
        try await dispatch(
            to: directory,
            validate: {
                let (_, currentFiles) = try clipboard.current(token: token)
                guard currentFiles == files else { throw FinderMoveError.expiredCut }
                try FinderMoveValidation.destination(directory, for: currentFiles)
            },
            consume: { try clipboard.consume(state) }, restore: { try clipboard.restore(state) },
            validateConsumed: {
                guard try clipboard.files(matching: state) == files else { throw FinderMoveError.expiredCut }
            })
    }

    // 请求队列等待到命令提交结束。文件移动、冲突及撤销始终由访达负责。
    func dispatch(
        to directory: URL, validate: () throws -> Void, consume: () throws -> Void,
        restore: () throws -> Void, validateConsumed: () throws -> Void
    ) async throws {
        guard environment.trusted() else { throw FinderMoveError.permissionRequired }
        let initial = environment.snapshot()
        guard !initial.blocked || initial.waitingForContext else { throw FinderMoveError.unsafeFinder }
        let deadline = environment.now() + .seconds(2)
        let initialDirectoryMatches = initial.directory?.resolvingSymlinksInPath().standardizedFileURL.path
            == directory.resolvingSymlinksInPath().standardizedFileURL.path
        if !initialDirectoryMatches && !initial.waitingForContext {
            guard initial.frontBundleID == "com.apple.finder" else { throw FinderMoveError.unsafeFinder }
            environment.openDirectory(directory)
        }
        var opened = !initialDirectoryMatches && !initial.waitingForContext
        while environment.now() < deadline, !Task.isCancelled {
            guard environment.trusted() else { throw FinderMoveError.permissionRequired }
            try validate()
            let state = environment.snapshot()
            guard state.frontBundleID == "com.apple.finder" else { throw FinderMoveError.unsafeFinder }
            if state.waitingForContext { await environment.pause(); continue }
            guard !state.blocked else { throw FinderMoveError.unsafeFinder }
            if state.directory?.resolvingSymlinksInPath().standardizedFileURL.path
                != directory.resolvingSymlinksInPath().standardizedFileURL.path, !opened {
                environment.openDirectory(directory)
                opened = true
                await environment.pause()
                continue
            }
            if state.matches(directory) {
                try validate()
                guard environment.trusted(), environment.snapshot().matches(directory), environment.now() < deadline else {
                    throw FinderMoveError.unsafeFinder
                }
                try consume()
                do {
                    try validateConsumed()
                    guard !Task.isCancelled, environment.trusted(), environment.snapshot().matches(directory),
                        environment.now() < deadline,
                        try environment.sendMove(directory, deadline, validateConsumed) else {
                        throw FinderMoveError.unsafeFinder
                    }
                } catch {
                    try? restore()
                    throw error
                }
                return
            }
            await environment.pause()
        }
        throw FinderMoveError.unsafeFinder
    }
}

@MainActor enum FinderMoveSystem {
    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        FinderRenameSystem.attribute(element, key)
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    static func snapshot() -> FinderMoveSnapshot {
        let front = NSWorkspace.shared.frontmostApplication
        let mask: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]
        let released = CGEventSource.flagsState(.combinedSessionState).intersection(mask).isEmpty
        var result = FinderMoveSnapshot(frontBundleID: front?.bundleIdentifier, blocked: true, modifiersReleased: released)
        guard let front, front.bundleIdentifier == "com.apple.finder" else { return result }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.05)
        guard let focused = element(attribute(app, kAXFocusedUIElementAttribute)),
            let role = attribute(focused, kAXRoleAttribute) as? String else {
            result.waitingForContext = true
            return result
        }
        if [kAXMenuRole, kAXMenuItemRole].contains(role) {
            result.waitingForContext = true
            return result
        }
        // 桌面没有普通窗口，先按目标打开一次普通文件夹窗口再确认。
        guard let window = element(attribute(app, kAXFocusedWindowAttribute)) else {
            if [kAXScrollAreaRole, kAXGroupRole, kAXListRole].contains(role) {
                result.blocked = false
            }
            return result
        }
        guard
            attribute(window, kAXModalAttribute) as? Bool != true,
            !(attribute(window, kAXChildrenAttribute) as? [AXUIElement] ?? []).contains(where: {
                attribute($0, kAXRoleAttribute) as? String == kAXSheetRole
            }),
            attribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole else { return result }
        // 名称、搜索或路径输入框都不接收移动快捷键。
        guard [kAXOutlineRole, kAXTableRole, kAXListRole, kAXBrowserRole, kAXScrollAreaRole, kAXGroupRole,
             kAXRowRole, kAXCellRole, kAXImageRole].contains(role) else { return result }
        let raw = attribute(window, kAXDocumentAttribute)
        let document = (raw as? URL) ?? (raw as? String).flatMap(URL.init(string:))
        var budget = 80
        let directory = document ?? pathBarDirectory(in: window, budget: &budget, depth: 0)
        guard let directory, directory.isFileURL else { return result }
        result.directory = directory
        result.blocked = false
        return result
    }

    private static func pathBarDirectory(in node: AXUIElement, budget: inout Int, depth: Int) -> URL? {
        guard budget > 0, depth < 8 else { return nil }
        budget -= 1
        let role = attribute(node, kAXRoleAttribute) as? String
        // 不遍历文件列表或侧边栏条目，路径仅从窗口路径栏的父子链取得。
        guard role != kAXOutlineRole, role != kAXTableRole, role != kAXBrowserRole else { return nil }
        let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
        if role == kAXListRole, !children.isEmpty {
            let urls = children.compactMap { child -> URL? in
                guard attribute(child, kAXRoleAttribute) as? String == kAXStaticTextRole else { return nil }
                return (attribute(child, kAXURLAttribute) as? NSURL)?.filePathURL
            }
            if urls.count == children.count, zip(urls, urls.dropFirst()).allSatisfy({ parent, child in
                child.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
                    == parent.resolvingSymlinksInPath().standardizedFileURL.path
            }) { return urls.last }
        }
        for child in children {
            if let directory = pathBarDirectory(in: child, budget: &budget, depth: depth + 1) { return directory }
        }
        return nil
    }

    static func sendMove(
        to directory: URL, before deadline: ContinuousClock.Instant, validateClipboard: () throws -> Void
    ) throws -> Bool {
        guard FinderRenameAccess.isGranted, snapshot().matches(directory),
            let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == "com.apple.finder",
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false), ContinuousClock.now < deadline
        else { return false }
        down.flags = [.maskAlternate, .maskCommand]
        up.flags = [.maskAlternate, .maskCommand]
        // 最后的辅助功能跨进程检查完成后再核对剪贴板，避免其间换成其他文件。
        try validateClipboard()
        guard ContinuousClock.now < deadline else { return false }
        down.postToPid(front.processIdentifier)
        up.postToPid(front.processIdentifier)
        return true
    }
}
