import Foundation

/// 外部图片处理串行执行，等待中的请求可取消，不再创建无法取消的分离任务。
public actor ImagePreparationWorker {
    public static let shared = ImagePreparationWorker()
    public func prepare(_ data: Data) async throws -> PreparedContent {
        try Task.checkCancellation()
        let cost = try ImageProcessor.pixelByteCount(data) * 2 + data.count
        if let result = try ImageWorkBudget.shared.performIfAvailable(estimatedBytes: cost, operation: {
            try prepareAdmitted(data)
        }) { return result }
        return try await ImageWorkBudget.shared.withPermit(estimatedBytes: cost, priority: .background) {
            try await self.prepareAdmitted(data)
        }
    }
    private func prepareAdmitted(_ data: Data) throws -> PreparedContent {
        try Task.checkCancellation()
        let content = try autoreleasepool { try ImageProcessor.prepare(data) }
        try Task.checkCancellation()
        return content
    }
}
