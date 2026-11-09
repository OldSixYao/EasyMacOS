import AppKit
import Observation

@MainActor @Observable final class ScreenRecordingCoordinator {
    enum Phase: Equatable {
        case idle, selecting, countdown, starting, recording, pausing, paused, stopping, saving, failed
    }
    enum Mode { case fullScreen, region }
    private(set) var phase: Phase = .idle { didSet { onPresentationChanged?(); onChange?() } }
    private(set) var elapsed: TimeInterval = 0 {
        didSet { if Int(oldValue) != Int(elapsed) { onChange?() } }
    }
    private(set) var countdown = 3
    private(set) var saveProgress = 0.0
    private(set) var errorMessage: String?
    private(set) var savedURL: URL?
    private(set) var sessionDirectory: URL?
    private(set) var segments: [URL] = []
    private(set) var target: ScreenRecordingTarget?
    private(set) var mode: Mode = .fullScreen
    private var options = ScreenRecordingOptions()
    private var engine: (any ScreenRecordingEngine)?
    private var currentURL: URL?
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var began: Date?
    private var accumulated: TimeInterval = 0
    private var generation = UUID()
    private var stopRequested = false
    private var pendingFailure: Error?
    private let makeEngine: () -> any ScreenRecordingEngine
    private let exporter: any ScreenRecordingExporting
    private let defaults: UserDefaults
    private let countdownInterval: Duration
    private let now: () -> Date
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onPresentationChanged: (() -> Void)?
    @ObservationIgnored var onSelection: ((Mode) -> Void)?
    @ObservationIgnored var onDismissSelection: (() -> Void)?
    @ObservationIgnored var onShowControls: (() -> Void)?
    @ObservationIgnored var onFinished: (() -> Void)?
    @ObservationIgnored var validateAccess: ((ScreenRecordingOptions) async throws -> Void)?
    var isActive: Bool { phase != .idle }
    var isCapturing: Bool { phase == .recording || phase == .paused }
    var timeLabel: String {
        let seconds = Int(elapsed)
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    var pendingRecoveries: [URL] {
        (defaults.stringArray(forKey: "screenRecordingRecoveries") ?? []).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    init(makeEngine: @escaping () -> any ScreenRecordingEngine = { SystemScreenRecordingEngine() },
         exporter: any ScreenRecordingExporting = ScreenRecordingExporter(),
         defaults: UserDefaults = .standard, countdownInterval: Duration = .seconds(1), now: @escaping () -> Date = Date.init) {
        self.makeEngine = makeEngine
        self.exporter = exporter
        self.defaults = defaults
        self.countdownInterval = countdownInterval
        self.now = now
    }

    func select(mode: Mode, options: ScreenRecordingOptions) {
        guard phase == .idle else { return }
        generation = UUID()
        self.options = options
        self.mode = mode
        savedURL = nil
        errorMessage = nil
        stopRequested = false
        pendingFailure = nil
        accumulated = 0
        elapsed = 0
        phase = .selecting
        onSelection?(mode)
    }

    func confirm(_ target: ScreenRecordingTarget) {
        guard phase == .selecting else { return }
        self.target = target
        onDismissSelection?()
        phase = .countdown
        countdown = 3
        onShowControls?()
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.validateAccess?(self.options)
                guard self.generation == token, !Task.isCancelled else { return }
                let directory = self.options.directory.standardizedFileURL
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let session = directory.appendingPathComponent(".easymacos-recording-" + UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false)
                    self.sessionDirectory = session
                    self.remember(session)
                } catch { throw ScreenRecordingError.outputDirectory }
                for count in stride(from: 3, through: 1, by: -1) {
                    self.countdown = count
                    try await Task.sleep(for: self.countdownInterval)
                }
                guard self.generation == token, !Task.isCancelled else { return }
                await self.beginSegment()
            } catch is CancellationError { }
            catch {
                guard self.generation == token else { return }
                self.fail(error)
            }
        }
    }

    func cancelSelection() {
        guard phase == .selecting || phase == .countdown else { return }
        generation = UUID()
        task?.cancel()
        task = nil
        onDismissSelection?()
        if let sessionDirectory { clearEmptySession(sessionDirectory) }
        reset()
    }

    func togglePause() {
        if phase == .recording {
            freezeClock()
            phase = .pausing
            task = Task { [weak self] in
                guard let self else { return }
                await self.endSegment()
                if self.phase == .failed { return }
                if self.stopRequested { await self.finish() }
                else { self.phase = .paused }
            }
        } else if phase == .paused {
            phase = .starting
            task = Task { [weak self] in
                guard let self else { return }
                do { try await self.validateAccess?(self.options) }
                catch { self.fail(error); return }
                await self.beginSegment()
            }
        }
    }

    func stop() {
        if phase == .selecting || phase == .countdown { cancelSelection(); return }
        guard phase != .idle && phase != .saving && phase != .failed else { return }
        stopRequested = true
        if phase == .starting || phase == .pausing || phase == .stopping { return }
        freezeClock()
        phase = .stopping
        task = Task { [weak self] in
            guard let self else { return }
            await self.endSegment()
            if self.phase != .failed { await self.finish() }
        }
    }

    private func beginSegment() async {
        guard let target, let sessionDirectory else { return }
        phase = .starting
        let token = generation
        let engine = makeEngine()
        self.engine = engine
        let url = sessionDirectory.appendingPathComponent(String(format: "segment-%06d.mp4", segments.count))
        currentURL = url
        let identity = ObjectIdentifier(engine)
        engine.onFailure = { [weak self] error in
            guard let self, self.generation == token, self.engine.map(ObjectIdentifier.init) == identity else { return }
            self.pendingFailure = error
            self.stop()
        }
        do {
            try await engine.start(target: target, options: options, url: url)
            guard generation == token else { try? await engine.stop(); return }
            began = now()
            phase = .recording
            startClock()
            if stopRequested { stop() }
        } catch {
            try? await engine.stop()
            self.engine = nil
            preserveCurrentFile()
            fail(error)
        }
    }

    private func endSegment() async {
        guard let engine else { return }
        engine.onFailure = nil
        do {
            try await engine.stop()
            if let currentURL { segments.append(currentURL) }
            self.currentURL = nil
            self.engine = nil
        } catch {
            self.engine = nil
            preserveCurrentFile()
            fail(error)
        }
    }

    private func preserveCurrentFile() {
        if let currentURL, FileManager.default.fileExists(atPath: currentURL.path), !segments.contains(currentURL) {
            segments.append(currentURL)
        }
        currentURL = nil
    }

    private func finish() async {
        guard let sessionDirectory else { reset(); return }
        phase = .saving
        saveProgress = 0
        let token = generation
        do {
            let result = try await exporter.export(segments: segments, directory: sessionDirectory) { [weak self] value in
                Task { @MainActor in
                    guard let self, self.generation == token, self.phase == .saving else { return }
                    self.saveProgress = min(1, max(self.saveProgress, value))
                }
            }
            savedURL = result
            forget(sessionDirectory)
            try? FileManager.default.removeItem(at: sessionDirectory)
            self.sessionDirectory = nil
            segments = []
            let issue = pendingFailure
            reset()
            if let issue { errorMessage = issue.localizedDescription }
            onFinished?()
        } catch { fail(error) }
    }

    func retrySave() {
        guard phase == .failed, sessionDirectory != nil, !segments.isEmpty else { return }
        errorMessage = nil
        phase = .saving
        task = Task { [weak self] in await self?.finish() }
    }

    /// 关闭错误界面只结束会话，片段及恢复记录继续保留。
    func keepForRecovery() {
        guard phase == .failed else { return }
        reset()
    }

    func recover(_ directory: URL) {
        guard phase == .idle, pendingRecoveries.contains(where: { $0.standardizedFileURL.path == directory.standardizedFileURL.path }) else { return }
        generation = UUID()
        savedURL = nil
        pendingFailure = nil
        stopRequested = false
        sessionDirectory = directory
        segments = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("segment-") && $0.pathExtension == "mp4" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if segments.isEmpty {
            clearEmptySession(directory)
            reset()
            return
        }
        phase = .failed
        errorMessage = L.t("An unfinished recording can be recovered.", "发现未完成的录制，可重新保存已有片段。")
        onShowControls?()
    }

    private func fail(_ error: Error) {
        freezeClock()
        errorMessage = error.localizedDescription
        if segments.isEmpty, let sessionDirectory { clearEmptySession(sessionDirectory) }
        phase = .failed
        onShowControls?()
    }
    private func startClock() {
        timer?.invalidate()
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.elapsed = self.accumulated + (self.began.map { self.now().timeIntervalSince($0) } ?? 0)
            }
        }
        timer?.tolerance = 0.1
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    private func freezeClock() {
        if let began { accumulated += now().timeIntervalSince(began) }
        began = nil
        elapsed = accumulated
        timer?.invalidate()
        timer = nil
    }
    private func reset() {
        freezeClock()
        engine = nil
        currentURL = nil
        target = nil
        sessionDirectory = nil
        segments = []
        stopRequested = false
        phase = .idle
    }
    private func remember(_ url: URL) {
        var paths = defaults.stringArray(forKey: "screenRecordingRecoveries") ?? []
        if !paths.contains(url.path) { paths.append(url.path) }
        defaults.set(paths, forKey: "screenRecordingRecoveries")
    }
    private func forget(_ url: URL) {
        defaults.set((defaults.stringArray(forKey: "screenRecordingRecoveries") ?? []).filter { $0 != url.path },
                     forKey: "screenRecordingRecoveries")
    }
    private func clearEmptySession(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        forget(url)
        sessionDirectory = nil
    }
}
