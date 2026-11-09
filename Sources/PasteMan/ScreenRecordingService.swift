import AppKit
@preconcurrency import AVFoundation
import ScreenCaptureKit

struct ScreenRecordingOptions: Codable, Equatable, Sendable {
    var systemAudio = false
    var microphone = false
    var directory: URL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("EasyMacOS", isDirectory: true)
    var quality: ScreenRecordingQuality = .standard
}

enum ScreenRecordingQuality: String, Codable, CaseIterable, Sendable {
    case standard, lightweight
    var longEdge: CGFloat { self == .standard ? 3840 : 1920 }
    var shortEdge: CGFloat { self == .standard ? 2160 : 1080 }
    var framesPerSecond: Int32 { self == .standard ? 30 : 15 }
    var title: String { self == .standard ? L.t("Standard", "标准") : L.t("Lightweight", "轻量") }
    var detail: String {
        self == .standard ? L.t("30 fps · Up to 4K", "每秒三十帧 · 最高四千像素级画质")
            : L.t("15 fps · Up to 1080p", "每秒十五帧 · 最高一千零八十线画质")
    }
}

extension ScreenRecordingOptions {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        systemAudio = try values.decodeIfPresent(Bool.self, forKey: .systemAudio) ?? false
        microphone = try values.decodeIfPresent(Bool.self, forKey: .microphone) ?? false
        directory = try values.decodeIfPresent(URL.self, forKey: .directory) ?? directory
        quality = try values.decodeIfPresent(ScreenRecordingQuality.self, forKey: .quality) ?? .standard
    }
}

struct ScreenRecordingTarget: Sendable, Equatable {
    let displayID: CGDirectDisplayID
    let displayFrame: CGRect
    let scale: CGFloat
    /// 相对于显示器左上角的逻辑坐标。
    let rect: CGRect

    var pixelSize: CGSize {
        pixelSize(for: .standard)
    }

    func pixelSize(for quality: ScreenRecordingQuality) -> CGSize {
        let w = rect.width * scale, h = rect.height * scale
        guard w > 0, h > 0 else { return .zero }
        let ratio = min(1, quality.longEdge / max(w, h), quality.shortEdge / min(w, h))
        return CGSize(width: max(2, floor(w * ratio / 2) * 2), height: max(2, floor(h * ratio / 2) * 2))
    }

    static func region(displayID: CGDirectDisplayID, frame: CGRect, scale: CGFloat, globalRect: CGRect) -> Self? {
        let clipped = globalRect.standardized.intersection(frame)
        guard !clipped.isNull, clipped.width >= 8, clipped.height >= 8, scale > 0 else { return nil }
        return Self(displayID: displayID, displayFrame: frame, scale: scale,
                    rect: CGRect(x: clipped.minX - frame.minX, y: frame.maxY - clipped.maxY,
                                 width: clipped.width, height: clipped.height))
    }
}

enum ScreenRecordingError: LocalizedError {
    case unavailable, empty, outputDirectory, interrupted
    var errorDescription: String? {
        switch self {
        case .unavailable: L.t("The selected display is unavailable.", "所选显示器不可用。")
        case .empty: L.t("No playable video was recorded.", "没有录下可播放的视频。")
        case .outputDirectory: L.t("The recording folder cannot be written. Choose another folder.", "无法写入录屏目录，请选择其他文件夹。")
        case .interrupted: L.t("Screen recording was interrupted. Completed segments have been preserved.", "屏幕录制已中断，已完成的片段已保留。")
        }
    }
}

@MainActor protocol ScreenRecordingEngine: AnyObject {
    var onFailure: ((Error) -> Void)? { get set }
    func start(target: ScreenRecordingTarget, options: ScreenRecordingOptions, url: URL) async throws
    func stop() async throws
}

/// 每个片段使用一个实例，系统回调只影响所属片段。
@MainActor final class SystemScreenRecordingEngine: NSObject, ScreenRecordingEngine, SCRecordingOutputDelegate, SCStreamDelegate, SCStreamOutput {
    var onFailure: ((Error) -> Void)?
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var startWaiter: CheckedContinuation<Void, Error>?
    private var finishWaiter: CheckedContinuation<Void, Error>?
    private var finishResult: Result<Void, Error>?
    private var stopping = false
    private let sampleQueue = DispatchQueue(label: "app.easymacos.recording.samples", qos: .userInitiated)
    private let queueDepth: Int
    private let pixelFormat: OSType
    nonisolated private let observeFrame: (@Sendable (OSType, Int) -> Void)?

    init(queueDepth: Int = 6, pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
         observeFrame: (@Sendable (OSType, Int) -> Void)? = nil) {
        self.queueDepth = max(3, min(8, queueDepth))
        self.pixelFormat = pixelFormat
        self.observeFrame = observeFrame
        super.init()
    }

    static func configuration(target: ScreenRecordingTarget, options: ScreenRecordingOptions) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.sourceRect = target.rect
        let size = target.pixelSize(for: options.quality)
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: options.quality.framesPerSecond)
        // 六帧为编码器保留余量；不降到短暂静止画面下可能不足的最小队列。
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.captureDynamicRange = .SDR
        config.capturesAudio = options.systemAudio
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = options.microphone
        config.sampleRate = 48_000
        config.channelCount = 2
        return config
    }

    func start(target: ScreenRecordingTarget, options: ScreenRecordingOptions, url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == target.displayID }) else {
            throw ScreenRecordingError.unavailable
        }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let config = Self.configuration(target: target, options: options)
        config.queueDepth = queueDepth
        config.pixelFormat = pixelFormat
        let recordingConfig = SCRecordingOutputConfiguration()
        recordingConfig.outputURL = url
        recordingConfig.videoCodecType = .h264
        recordingConfig.outputFileType = .mp4
        let output = SCRecordingOutput(configuration: recordingConfig, delegate: self)
        self.output = output
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try stream.addRecordingOutput(output)
        do {
            try await withCheckedThrowingContinuation { continuation in
                startWaiter = continuation
                Task { [weak self] in
                    do { try await stream.startCapture() }
                    catch { self?.complete(.failure(error)) }
                }
            }
        } catch {
            try? await stream.stopCapture()
            self.stream = nil
            self.output = nil
            throw error
        }
    }

    func stop() async throws {
        stopping = true
        defer { stream = nil; output = nil }
        if let stream {
            do { try await stream.stopCapture() }
            catch { complete(.failure(error)) }
        }
        if let finishResult { try finishResult.get() }
        else {
            try await withCheckedThrowingContinuation { finishWaiter = $0 }
        }
    }

    private func complete(_ result: Result<Void, Error>) {
        guard finishResult == nil else { return }
        finishResult = result
        if let waiter = startWaiter {
            startWaiter = nil
            switch result {
            case .success: waiter.resume(throwing: ScreenRecordingError.empty)
            case .failure(let error): waiter.resume(throwing: error)
            }
        }
        finishWaiter?.resume(with: result)
        finishWaiter = nil
        if !stopping {
            switch result {
            case .failure(let error): onFailure?(error)
            case .success: onFailure?(ScreenRecordingError.interrupted)
            }
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // 及时消费屏幕缓冲，文件输出由 SCRecordingOutput 处理，不在界面线程搬运像素。
        if let observeFrame, type == .screen, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) {
            observeFrame(CVPixelBufferGetPixelFormatType(pixels), CVPixelBufferGetDataSize(pixels))
        }
    }

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        let identity = ObjectIdentifier(recordingOutput)
        Task { @MainActor [weak self] in
            guard let self, self.output.map(ObjectIdentifier.init) == identity else { return }
            self.startWaiter?.resume()
            self.startWaiter = nil
        }
    }
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        let identity = ObjectIdentifier(recordingOutput)
        Task { @MainActor [weak self] in
            guard let self, self.output.map(ObjectIdentifier.init) == identity else { return }
            self.complete(.success(()))
        }
    }
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        let identity = ObjectIdentifier(recordingOutput)
        Task { @MainActor [weak self] in
            guard let self, self.output.map(ObjectIdentifier.init) == identity else { return }
            self.complete(.failure(error))
        }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let identity = ObjectIdentifier(stream)
        Task { @MainActor [weak self] in
            guard let self, self.stream.map(ObjectIdentifier.init) == identity else { return }
            self.complete(.failure(error))
        }
    }
}
