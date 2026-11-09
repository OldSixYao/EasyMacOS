import Foundation
import Synchronization

/// 各工作器共享临时缓冲预算；准入只操作小型状态，不切换图片工作的执行器。
public final class ImageWorkBudget: Sendable {
    public static let shared = ImageWorkBudget(observesPressure: true)
    public enum Priority: Int, Sendable { case background, display, userInitiated }
    private struct Request {
        let id: UUID
        let bytes: Int
        let priority: Priority
        let queuedAt: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, Error>
    }
    private struct State {
        var byteLimit: Int
        var active: [UUID: Int] = [:]
        var pending: [Request] = []
    }
    private let normalLimit: Int
    private let state: Mutex<State>
    private let pressureSource: DispatchSourceMemoryPressure?
    private static let smallAllowance = 8 * 1024 * 1024
    var activeByteCount: Int { state.withLock { $0.active.values.reduce(0, +) } }
    var pendingCount: Int { state.withLock { $0.pending.count } }

    public init(byteLimit: Int = 384 * 1024 * 1024, observesPressure: Bool = false) {
        normalLimit = max(1, byteLimit)
        state = Mutex(State(byteLimit: max(1, byteLimit)))
        pressureSource = observesPressure
            ? DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility)) : nil
        pressureSource?.setEventHandler { [weak self] in
            if let self, let pressureSource = self.pressureSource { self.setMemoryPressure(pressureSource.data) }
        }
        pressureSource?.resume()
    }
    deinit { pressureSource?.cancel() }

    /// 无等待且预算充足时原地处理，保持各工作器原有的串行顺序。
    public func performIfAvailable<T>(estimatedBytes: Int, operation: () throws -> T) throws -> T? {
        try Task.checkCancellation()
        let id = UUID()
        let bytes = max(1, min(Int.max / 4, estimatedBytes))
        let admitted = state.withLock { state in
            guard state.pending.isEmpty, Self.fits(bytes, in: state) else { return false }
            state.active[id] = bytes
            return true
        }
        guard admitted else { return nil }
        defer { release(id) }
        let result = try operation()
        try Task.checkCancellation()
        return result
    }

    public func withPermit<T: Sendable>(estimatedBytes: Int, priority: Priority,
                                       operation: @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let id = UUID()
        let canceled = Mutex(false)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let admitted = state.withLock { state -> [Request]? in
                    // 取消可能早于入队；标记与队列检查一起防止遗漏唤醒。
                    guard !canceled.withLock({ $0 }) else { return nil }
                    state.pending.append(Request(id: id, bytes: max(1, min(Int.max / 4, estimatedBytes)), priority: priority,
                        queuedAt: .now, continuation: continuation))
                    return Self.admitPending(&state)
                }
                if let admitted { Self.resume(admitted) }
                else { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            canceled.withLock { $0 = true }
            self.cancelPending(id)
        }
        // 已进入同步系统调用的任务必须返回后才归还预算。
        defer { release(id) }
        try Task.checkCancellation()
        let result = try await operation()
        try Task.checkCancellation()
        return result
    }

    public func setMemoryPressure(_ pressure: DispatchSource.MemoryPressureEvent) {
        let admitted = state.withLock { state in
            state.byteLimit = pressure.contains(.critical) ? max(1, normalLimit / 4)
                : pressure.contains(.warning) ? max(1, normalLimit / 2) : normalLimit
            return Self.admitPending(&state)
        }
        Self.resume(admitted)
    }
    private func release(_ id: UUID) {
        let admitted = state.withLock { state in
            state.active[id] = nil
            return Self.admitPending(&state)
        }
        Self.resume(admitted)
    }
    private func cancelPending(_ id: UUID) {
        let (canceled, admitted) = state.withLock { state -> (Request?, [Request]) in
            guard let index = state.pending.firstIndex(where: { $0.id == id }) else { return (nil, []) }
            let canceled = state.pending.remove(at: index)
            return (canceled, Self.admitPending(&state))
        }
        canceled?.continuation.resume(throwing: CancellationError())
        Self.resume(admitted)
    }
    private static func resume(_ requests: [Request]) {
        // 恢复任务不在锁内执行，避免任务调度持有预算状态锁。
        for request in requests { request.continuation.resume() }
    }
    private static func admitPending(_ state: inout State) -> [Request] {
        let now = ContinuousClock.now
        state.pending.sort {
            let first = $0.queuedAt.duration(to: now) >= .seconds(1) ? Priority.userInitiated.rawValue : $0.priority.rawValue
            let second = $1.queuedAt.duration(to: now) >= .seconds(1) ? Priority.userInitiated.rawValue : $1.priority.rawValue
            return first == second ? $0.queuedAt < $1.queuedAt : first > second
        }
        var admitted: [Request] = []
        var index = 0
        while index < state.pending.count {
            let request = state.pending[index]
            if fits(request.bytes, in: state) {
                state.active[request.id] = request.bytes
                admitted.append(state.pending.remove(at: index))
            } else {
                index += 1
            }
        }
        return admitted
    }
    private static func fits(_ requested: Int, in state: State) -> Bool {
        let bytes = state.active.values.reduce(0, +)
        let smallBytes = state.active.values.filter { $0 <= smallAllowance }.reduce(0, +)
        return state.active.isEmpty || (requested <= state.byteLimit && bytes <= state.byteLimit - requested)
            || (requested <= smallAllowance && smallBytes <= smallAllowance - requested)
    }
}
