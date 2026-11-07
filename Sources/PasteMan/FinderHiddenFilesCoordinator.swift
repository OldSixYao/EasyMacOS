import AppKit
@preconcurrency import ApplicationServices

enum FinderHiddenFilesError: LocalizedError {
    case permissionRequired, unsafeFinder

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            L.t("Enable Accessibility in Permissions to show or hide hidden files.", "显示或隐藏隐藏文件需要辅助功能权限，请在权限设置中开启。")
        case .unsafeFinder:
            L.t("Return to Finder, finish editing or close dialogs, then reopen the context menu and try again.",
                "请返回访达，结束名称编辑或关闭对话框后，重新打开右键菜单再试。")
        }
    }
}

@MainActor struct FinderHiddenFilesEnvironment {
    var trusted: () -> Bool
    var snapshot: () -> FinderMoveSnapshot
    var sendToggle: (Duration) -> Bool
    var now: () -> Duration
    var pause: () async -> Void

    static func live() -> Self {
        let start = ContinuousClock.now
        return Self(
            trusted: { FinderRenameAccess.isGranted }, snapshot: { FinderMoveSystem.snapshot(requiresDirectory: false) },
            sendToggle: { FinderHiddenFilesSystem.sendToggle(before: start.advanced(by: $0)) },
            now: { start.duration(to: .now) }, pause: { try? await Task.sleep(for: .milliseconds(50)) })
    }
}

@MainActor struct FinderHiddenFilesCoordinator {
    var environment: FinderHiddenFilesEnvironment = .live()

    func toggle() async throws {
        let deadline = environment.now() + .seconds(2)
        while environment.now() < deadline {
            try Task.checkCancellation()
            guard environment.trusted() else { throw FinderHiddenFilesError.permissionRequired }
            let state = environment.snapshot()
            guard state.frontBundleID == "com.apple.finder" else { throw FinderHiddenFilesError.unsafeFinder }
            // 系统菜单收起期间稍等，不激活访达或打开其他目录。
            if state.waitingForContext { await environment.pause(); continue }
            guard !state.blocked else { throw FinderHiddenFilesError.unsafeFinder }
            guard state.modifiersReleased else { await environment.pause(); continue }
            // 菜单关闭后焦点可能短暂恢复再变化，跨一次等待确认稳定，避免按键被菜单吞掉。
            await environment.pause()
            try Task.checkCancellation()
            guard environment.trusted() else { throw FinderHiddenFilesError.permissionRequired }
            let confirmed = environment.snapshot()
            guard confirmed.frontBundleID == "com.apple.finder" else { throw FinderHiddenFilesError.unsafeFinder }
            if confirmed.waitingForContext || !confirmed.modifiersReleased { continue }
            guard !confirmed.blocked, environment.now() < deadline, environment.sendToggle(deadline) else {
                throw FinderHiddenFilesError.unsafeFinder
            }
            return
        }
        throw FinderHiddenFilesError.unsafeFinder
    }
}

@MainActor enum FinderHiddenFilesSystem {
    static func canToggle(_ state: FinderMoveSnapshot) -> Bool {
        state.frontBundleID == "com.apple.finder" && !state.blocked && !state.waitingForContext && state.modifiersReleased
    }

    static func sendToggle(before deadline: ContinuousClock.Instant) -> Bool {
        guard FinderRenameAccess.isGranted, canToggle(FinderMoveSystem.snapshot(requiresDirectory: false)),
            let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == "com.apple.finder",
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 47, keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 47, keyDown: false),
            ContinuousClock.now < deadline else { return false }
        down.flags = [.maskShift, .maskCommand]
        up.flags = [.maskShift, .maskCommand]
        down.postToPid(front.processIdentifier)
        up.postToPid(front.processIdentifier)
        return true
    }
}
