import AppKit

/// 历史面板可见时才接收全局点击，隐藏后不再为其他应用的点击唤醒宿主。
@MainActor final class HistoryOutsideClickMonitor {
    private var token: Any?
    private let install: (@escaping () -> Void) -> Any?
    private let remove: (Any) -> Void

    init(
        install: @escaping (@escaping () -> Void) -> Any? = { dismiss in
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in dismiss() }
        },
        remove: @escaping (Any) -> Void = NSEvent.removeMonitor
    ) {
        self.install = install
        self.remove = remove
    }

    func start(dismiss: @escaping () -> Void) {
        guard token == nil else { return }
        token = install(dismiss)
    }

    func stop() {
        if let token { remove(token) }
        token = nil
    }
}
