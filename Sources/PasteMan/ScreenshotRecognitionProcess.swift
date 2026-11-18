import AppKit
import os
import PasteManCore

private struct ScreenshotRecognitionRequest: Codable {
    let kind: ScreenshotRecognitionKind
    let imageURL: URL
    let rawSize: CGSize?
    let pointSize: CGSize
    let annotations: [ScreenshotAnnotation]
}

private struct ScreenshotRecognitionResponse: Codable {
    var text: String?
    var error: String?
}

enum ScreenshotRecognitionProcessError: Error, LocalizedError {
    case unavailable, invalidResponse, failed(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: L.t("The recognition helper is unavailable. Restart the app and try again.", "识别辅助程序不可用，请重新启动应用后重试。")
        case .invalidResponse: L.t("The recognition helper exited without a result. Try again.", "识别辅助程序未返回结果，请重试。")
        case .failed(let message): message
        }
    }
}

/// 文字和条码共用串行队列；每个识别子进程结束后，系统模型缓存随之释放。
final class ScreenshotRecognitionProcess: Sendable {
    static let shared = ScreenshotRecognitionProcess()
    static let argument = "--recognition-worker"
    private let executableURL: URL?
    private let temporaryDirectory: URL
    private let queue = DispatchQueue(label: "EasyMacOS.RecognitionProcess", qos: .userInitiated)
    private let activePID = OSAllocatedUnfairLock<pid_t?>(initialState: nil)
    var processIdentifier: pid_t? { activePID.withLock { $0 } }

    init(executableURL: URL? = nil, temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.executableURL = executableURL ?? Self.findExecutable()
        self.temporaryDirectory = temporaryDirectory
    }

    func recognize(_ input: ScreenshotTextInput, kind: ScreenshotRecognitionKind,
                   progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        try Task.checkCancellation()
        guard let executableURL, FileManager.default.isExecutableFile(atPath: executableURL.path)
        else { throw ScreenshotRecognitionProcessError.unavailable }
        let storage: PinnedImageStorage
        let annotations: [ScreenshotAnnotation]
        switch input {
        case .image(let image, let pointSize, let marks):
            // 只写原始像素；标注由子进程按现有分段流程渲染，避免提前展平整张长图。
            storage = try await PinnedImageWorker.shared.archiveForRecognition(base: image, pointSize: pointSize)
            annotations = marks
        case .pinned(let image):
            storage = image
            annotations = []
        }
        try Task.checkCancellation()
        let source = try await storage.recognitionFile()
        let directory = temporaryDirectory.appendingPathComponent("EasyMacOS-Recognition-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let requestURL = directory.appendingPathComponent("request.json")
        let request = ScreenshotRecognitionRequest(kind: kind, imageURL: source.url, rawSize: source.rawSize,
            pointSize: storage.pointSize, annotations: annotations)
        try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
        let width = Int(source.pixelSize.width), height = Int(source.pixelSize.height)
        let strips = kind == .text ? ScreenshotTextLayout.strips(width: width, height: height)
            : ScreenshotBarcodeLayout.strips(width: width, height: height)
        let stripPixels = strips.map { Int($0.width * $0.height) }.max() ?? 0
        // 父进程仍为识别保留预算，避免把辅助进程与其他图片任务的并发开销漏算。
        let estimatedBytes = stripPixels * 12 + ScreenshotRenderer.mosaicCacheLimit + 96 * 1_048_576
        let cancellation = RecognitionProcessCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await ImageWorkBudget.shared.withPermit(estimatedBytes: estimatedBytes, priority: .userInitiated) {
                try await withCheckedThrowingContinuation { continuation in
                    self.queue.async { [self, storage] in
                        defer { withExtendedLifetime(storage) {} }
                        do {
                            continuation.resume(returning: try run(executableURL: executableURL, requestURL: requestURL,
                                cancellation: cancellation, progress: progress))
                        } catch { continuation.resume(throwing: error) }
                    }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private func run(executableURL: URL, requestURL: URL, cancellation: RecognitionProcessCancellation,
                     progress: @escaping @Sendable (Double) -> Void) throws -> String {
        try cancellation.check()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [Self.argument, requestURL.path]
        // 系统框架可能写诊断信息；结果走私有文件，避免管道填满或输出用户内容。
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try cancellation.launch(process)
        activePID.withLock { $0 = process.processIdentifier }
        defer { activePID.withLock { $0 = nil }; cancellation.clear() }
        let directory = requestURL.deletingLastPathComponent()
        let progressURL = directory.appendingPathComponent("progress")
        var lastProgress = 0.0
        var reportedCount = 0
        func reportProgress() {
            guard let data = try? Data(contentsOf: progressURL),
                let values = try? JSONDecoder().decode([Double].self, from: data) else { return }
            for value in values.dropFirst(reportedCount) where value.isFinite && value > lastProgress && value <= 1 {
                lastProgress = value
                progress(value)
            }
            reportedCount = values.count
        }
        while process.isRunning {
            reportProgress()
            // 仅阻塞专用串行队列，不占用主线程或协作线程池。
            Thread.sleep(forTimeInterval: 0.025)
        }
        process.waitUntilExit()
        try cancellation.check()
        reportProgress()
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("response.json")),
            let response = try? JSONDecoder().decode(ScreenshotRecognitionResponse.self, from: data)
        else { throw ScreenshotRecognitionProcessError.invalidResponse }
        if let error = response.error { throw ScreenshotRecognitionProcessError.failed(error) }
        guard process.terminationStatus == 0, let text = response.text else { throw ScreenshotRecognitionProcessError.invalidResponse }
        if lastProgress < 1 { progress(1) }
        return text
    }

    private static func findExecutable() -> URL? {
        let locations = [Bundle.main.executableURL, Bundle(for: RecognitionBundleMarker.self).executableURL,
            URL(fileURLWithPath: CommandLine.arguments[0])].compactMap { $0 }
        for current in locations {
            if current.lastPathComponent == "EasyMacOS", FileManager.default.isExecutableFile(atPath: current.path) {
                return URL(fileURLWithPath: current.path)
            }
            // 包测试由独立测试宿主运行，使用同一构建目录的应用可执行文件。
            var directory = current.deletingLastPathComponent()
            for _ in 0..<5 {
                let candidate = directory.appendingPathComponent("EasyMacOS")
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return URL(fileURLWithPath: candidate.path) }
                directory.deleteLastPathComponent()
            }
        }
        return nil
    }

    /// 在创建应用、菜单栏和各模块之前进入，只运行这一个识别请求。
    static func runWorker(requestURL: URL) -> Never {
        Task.detached(priority: .userInitiated) {
            let directory = requestURL.deletingLastPathComponent()
            let response: ScreenshotRecognitionResponse
            do {
                let request = try JSONDecoder().decode(ScreenshotRecognitionRequest.self, from: Data(contentsOf: requestURL))
                let image = try await PinnedImageWorker.shared.load(url: request.imageURL, rawSize: request.rawSize)
                let input = ScreenshotTextInput.image(image, pointSize: request.pointSize, annotations: request.annotations)
                let values = OSAllocatedUnfairLock(initialState: [Double]())
                let progress: @Sendable (Double) -> Void = { value in
                    let history = values.withLock { $0.append(value); return $0 }
                    try? JSONEncoder().encode(history).write(to: directory.appendingPathComponent("progress"), options: .atomic)
                }
                let text: String
                switch request.kind {
                case .text: text = try await InProcessScreenshotTextRecognizer.shared.recognize(input, progress: progress)
                case .barcodes: text = try await InProcessScreenshotBarcodeRecognizer.shared.recognize(input, progress: progress)
                }
                response = ScreenshotRecognitionResponse(text: text)
            } catch { response = ScreenshotRecognitionResponse(error: error.localizedDescription) }
            do {
                try JSONEncoder().encode(response).write(to: directory.appendingPathComponent("response.json"), options: .atomic)
                exit(response.error == nil ? EXIT_SUCCESS : EXIT_FAILURE)
            } catch { exit(EXIT_FAILURE) }
        }
        dispatchMain()
    }
}

private final class RecognitionBundleMarker: NSObject {}

private final class RecognitionProcessCancellation: Sendable {
    private struct State {
        var cancelled = false
        var process: Process?
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    func check() throws {
        try state.withLock { if $0.cancelled { throw CancellationError() } }
    }
    func launch(_ process: Process) throws {
        try state.withLockUnchecked {
            guard !$0.cancelled else { throw CancellationError() }
            try process.run()
            $0.process = process
        }
    }
    func clear() { state.withLock { $0.process = nil } }
    func cancel() {
        state.withLockUnchecked {
            $0.cancelled = true
            if let process = $0.process, process.isRunning { process.terminate() }
        }
    }
}
