import Foundation

/// 系统取帧可能不响应任务取消；先结束调用方等待，再丢弃晚到回调。
/// 不使用等待所有子任务退出的任务组，避免停止操作继续被系统回调卡住。
@MainActor enum LongScreenshotOperation {
    static func run<Value: Sendable>(timeout: Duration = .seconds(8),
                                    operation: @escaping @MainActor @Sendable () async throws -> Value) async throws -> Value {
        let pending = Pending<Value>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending.continuation = continuation
                pending.operation = Task {
                    do { pending.finish(.success(try await operation())) }
                    catch { pending.finish(.failure(error)) }
                }
                pending.deadline = Task {
                    do {
                        try await Task.sleep(for: timeout)
                        pending.finish(.failure(LongScreenshotError.captureTimedOut))
                    } catch {}
                }
            }
        } onCancel: {
            Task { @MainActor in pending.finish(.failure(CancellationError())) }
        }
    }

    @MainActor private final class Pending<Value: Sendable> {
        var continuation: CheckedContinuation<Value, Error>?
        var operation: Task<Void, Never>?
        var deadline: Task<Void, Never>?

        func finish(_ result: Result<Value, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            operation?.cancel(); operation = nil
            deadline?.cancel(); deadline = nil
            continuation.resume(with: result)
        }
    }
}
