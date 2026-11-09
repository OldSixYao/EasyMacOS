import Foundation

/// 滚动独立于图像匹配；未确认的距离达到预算时暂停，保证仍有足够重叠。
@MainActor final class LongScreenshotScrollPump {
    var paused = false
    private(set) var failure: Error?
    private(set) var pendingPoints: CGFloat = 0
    let maximumPendingPoints: CGFloat
    let step: Int
    private let send: (Int) throws -> Void
    private var task: Task<Void, Never>?

    init(viewportHeight: CGFloat, send: @escaping (Int) throws -> Void) {
        maximumPendingPoints = max(1, viewportHeight / 4)
        step = max(1, min(10, Int(viewportHeight / 100)))
        self.send = send
    }
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(16))
                    try Task.checkCancellation()
                    guard let self else { return }
                    if !self.paused, self.pendingPoints + CGFloat(self.step) <= self.maximumPendingPoints {
                        try self.send(self.step)
                        self.pendingPoints += CGFloat(self.step)
                    }
                } catch is CancellationError { return }
                catch { self?.failure = error; return }
            }
        }
    }
    func acknowledge(_ points: CGFloat) { pendingPoints = max(0, pendingPoints - max(0, points)) }
    func stop() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}
