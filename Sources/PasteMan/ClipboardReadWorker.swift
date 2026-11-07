import AppKit
import PasteManCore
import Synchronization
import UniformTypeIdentifiers

/// 剪贴板可能等待外部应用提供数据；专用串行队列避免阻塞主线程和协作线程池。
/// 仅传递名称、变更计数及值类型快照，系统剪贴板对象不跨线程传递。
final class ClipboardReadWorker: Sendable {
    static let shared = ClipboardReadWorker()
    private let queue = DispatchQueue(label: "EasyMacOS.ClipboardRead", qos: .userInitiated)
    private let readSnapshot: @Sendable (String, Int) -> ClipboardSnapshot?

    init(readSnapshot: @escaping @Sendable (String, Int) -> ClipboardSnapshot? = { name, count in
        let board = NSPasteboard(name: .init(name))
        guard board.changeCount == count else { return nil }
        let snapshot = read(board)
        return board.changeCount == count ? snapshot : nil
    }) {
        self.readSnapshot = readSnapshot
    }

    func capture(name: String, expectedChangeCount: Int) async -> ClipboardSnapshot? {
        let canceled = Mutex(false)
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { continuation in
                queue.async { [readSnapshot] in
                    let result: ClipboardSnapshot? = autoreleasepool {
                        guard !canceled.withLock({ $0 }) else { return nil }
                        let result = readSnapshot(name, expectedChangeCount)
                        // 系统同步读取不能中断；取消后直接丢弃迟到内容。
                        return canceled.withLock({ $0 }) ? nil : result
                    }
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            canceled.withLock { $0 = true }
        }
    }

    private static func read(_ board: NSPasteboard) -> ClipboardSnapshot? {
        let interval = PerformanceTrace.signposter.beginInterval("ClipboardRead", id: PerformanceTrace.signposter.makeSignpostID())
        defer { PerformanceTrace.signposter.endInterval("ClipboardRead", interval) }
        for item in board.pasteboardItems ?? [] {
            let types = item.types
            if types.contains(.fileURL) || types.contains(.init("NSFilenamesPboardType")) { continue }
            let preferred: [NSPasteboard.PasteboardType] = [.png, .tiff]
            let otherImages = types.filter {
                !preferred.contains($0) && UTType($0.rawValue)?.conforms(to: .image) == true
            }
            for type in preferred + otherImages where types.contains(type) {
                if let data = item.data(forType: type) { return .image(data) }
            }
            if let text = item.string(forType: .string), !text.isEmpty { return .text(text) }
        }
        return nil
    }
}
