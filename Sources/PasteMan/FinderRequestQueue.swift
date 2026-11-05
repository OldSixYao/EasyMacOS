import Foundation

/// 串行覆盖创建、定位和重命名等待，避免连续请求交叉发送按键。
@MainActor final class FinderRequestQueue {
    private var pending: [URL] = []
    private var handler: ((URL) async -> Void)?
    private var processing = false
    var hasPending: Bool { !pending.isEmpty }

    func enqueue(_ urls: [URL]) {
        pending.append(contentsOf: urls)
        drain()
    }

    func start(handler: @escaping (URL) async -> Void) {
        self.handler = handler
        drain()
    }

    private func drain() {
        guard let handler, !processing else { return }
        processing = true
        Task { @MainActor in
            while !pending.isEmpty { await handler(pending.removeFirst()) }
            processing = false
        }
    }
}
