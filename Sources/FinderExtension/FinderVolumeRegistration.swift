import AppKit
import FinderSync

/// 根目录的观察范围不一定跨越挂载卷；显式注册卷根，并跟随挂载变化刷新。
@MainActor final class FinderVolumeRegistration {
    static let shared = FinderVolumeRegistration()
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        refresh()
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Self.shared.refresh() }
            })
        }
    }

    private func refresh() {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        FIFinderSyncController.default().directoryURLs = Set([URL(fileURLWithPath: "/", isDirectory: true)] + volumes)
    }
}
