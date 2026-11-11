import AppKit
import PasteManCore

@MainActor final class ClipboardMonitor {
    private let clipboard: any ClipboardReading
    private let repository: any HistoryRepository
    private let settings: AppSettings
    private let permissions: any ClipboardPermissionChecking
    private let sourceApplication: () -> (id: String, name: String)
    private let prepareImage: @Sendable (Data) async throws -> PreparedContent
    private var gate: CaptureGate
    private var generation = 0
    private var sourceRevision = 0
    private var reading = false
    private var screenshotGeneration = 0
    private var monitoringEnabled: Bool
    private var task: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var cleanupRevision = 0
    private var processingTask: Task<Void, Never>?
    private var screenshotTasks: [UUID: Task<Void, Error>] = [:]
    private struct Capture {
        let snapshot: ClipboardSnapshot
        let sourceID: String
        let sourceName: String
        let date: Date
        let generation: Int
        let bytes: Int
    }
    private var pending: [Capture] = []
    private var queuedBytes = 0
    private var processingBytes = 0
    private var running = false
    private var sessionActive = true
    private var suspensionReasons: Set<String> = []
    var onChange: (() -> Void)?
    var onCaptureSucceeded: (() -> Void)?
    var onError: ((Error) -> Void)?

    init(
        clipboard: any ClipboardReading, repository: any HistoryRepository, settings: AppSettings,
        permissions: any ClipboardPermissionChecking,
        sourceApplication: @escaping () -> (id: String, name: String) = {
            let app = NSWorkspace.shared.frontmostApplication
            return (app?.bundleIdentifier ?? "", app?.localizedName ?? L.unknownApp)
        },
        prepareImage: @escaping @Sendable (Data) async throws -> PreparedContent = { data in
            try await ImagePreparationWorker.shared.prepare(data)
        }
    ) {
        self.clipboard = clipboard
        self.repository = repository
        self.settings = settings
        self.permissions = permissions
        self.sourceApplication = sourceApplication
        self.prepareImage = prepareImage
        monitoringEnabled = settings.clipboardEnabled && settings.hasOnboarded && !settings.paused && permissions.allowsMonitoring
        gate = CaptureGate(count: clipboard.changeCount)
    }
    var pollInterval: Duration {
        if !settings.clipboardEnabled || !settings.hasOnboarded || settings.paused { return .seconds(60) }
        return permissions.allowsMonitoring ? .milliseconds(500) : .seconds(5)
    }
    func recordingStateChanged() {
        resetBaseline()
        monitoringEnabled = settings.clipboardEnabled && settings.hasOnboarded && !settings.paused && permissions.allowsMonitoring
        // Wake immediately on resume/onboarding; inactive periods never backfill.
        if running { start() }
    }
    func setSessionActive(_ active: Bool, reason: String = "session") {
        if active { suspensionReasons.remove(reason) } else { suspensionReasons.insert(reason) }
        let enabled = suspensionReasons.isEmpty
        guard enabled != sessionActive else { return }
        sessionActive = enabled
        recordingStateChanged()
    }
    func start() {
        task?.cancel()
        cleanupTask?.cancel()
        running = true
        task = nil
        cleanupTask = nil
        guard settings.clipboardEnabled, sessionActive else { return }
        scheduleCleanup()
        guard settings.hasOnboarded, !settings.paused else { task = nil; return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.pollInterval else { return }
                do { try await Task.sleep(for: interval) } catch { return }
                guard !Task.isCancelled, let self else { return }
                await self.enqueueCapture()
            }
        }
    }
    func stop() {
        running = false
        task?.cancel()
        task = nil
        cleanupTask?.cancel()
        cleanupTask = nil
        resetBaseline()
    }
    func resetBaseline(invalidateScreenshots: Bool = true) {
        generation += 1
        if invalidateScreenshots {
            screenshotGeneration += 1
            for task in screenshotTasks.values { task.cancel() }
            screenshotTasks.removeAll()
        }
        gate.reset(to: clipboard.changeCount)
        pending.removeAll()
        queuedBytes = 0
        processingTask?.cancel()
    }
    func ignoreOwnWrite() { resetBaseline(invalidateScreenshots: false) }

    func sourceApplicationChanged() {
        // 切换前尚未检测的内容无法再确认来源，不按新前台应用回填。
        // 已捕获的图片已有确定来源，显式截图也携带来源，不能因切换而取消。
        gate.reset(to: clipboard.changeCount)
        sourceRevision += 1
    }

    /// The caller synchronously resets the baseline immediately after its successful write.
    /// This explicit path records user-requested screenshots without rereading the pasteboard.
    func screenshotTicket(sourceID: String) -> Int? {
        guard settings.clipboardEnabled else { return nil }
        permissions.refreshClipboard()
        guard settings.clipboardEnabled, sessionActive, settings.hasOnboarded, !settings.paused, permissions.allowsMonitoring,
            !settings.excludedApps.contains(sourceID)
        else { return nil }
        return screenshotGeneration
    }
    func recordScreenshot(_ png: Data, sourceID: String, sourceName: String, ticket: Int) async throws {
        try await recordScreenshot(sourceID: sourceID, sourceName: sourceName, ticket: ticket) { [prepareImage] in
            try await prepareImage(png)
        }
    }

    func recordScreenshot(_ image: ScreenshotImage, sourceID: String, sourceName: String, ticket: Int) async throws {
        try await recordScreenshot(sourceID: sourceID, sourceName: sourceName, ticket: ticket) {
            try await ScreenshotRenderWorker.shared.prepareHistory(image)
        }
    }

    private func recordScreenshot(sourceID: String, sourceName: String, ticket: Int,
                                  prepare: @escaping @Sendable () async throws -> PreparedContent) async throws {
        guard screenshotTicket(sourceID: sourceID) == ticket else { return }
        let id = UUID()
        // 取消覆盖图片处理及数据库打开、排队阶段，不能只在入库前检查一次票据。
        let task = Task {
            try Task.checkCancellation()
            let content = try await prepare()
            guard !Task.isCancelled, screenshotTicket(sourceID: sourceID) == ticket else { return }
            try await repository.save(content, sourceBundleID: sourceID, sourceName: sourceName,
                policy: settings.policy, now: Date())
            guard !Task.isCancelled, screenshotTicket(sourceID: sourceID) == ticket else { return }
            onCaptureSucceeded?()
            onChange?()
        }
        screenshotTasks[id] = task
        defer { screenshotTasks[id] = nil }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
        } catch is CancellationError {
            // 暂停、关闭或清空使旧截图失效，不作为保存失败提示。
        }
    }

    func poll() async {
        guard let capture = await takeCapture() else { return }
        await process(capture)
    }

    private func takeCapture(canRead: Bool = true) async -> Capture? {
        guard settings.clipboardEnabled, !reading, !Task.isCancelled else { return nil }
        permissions.refreshClipboard()
        let enabled = sessionActive && settings.clipboardEnabled && settings.hasOnboarded && !settings.paused && permissions.allowsMonitoring
        let captureCount = clipboard.changeCount
        if enabled != monitoringEnabled {
            monitoringEnabled = enabled
            resetBaseline()
        }
        guard gate.consume(count: captureCount, enabled: enabled) else { return nil }
        let app = sourceApplication()
        let sourceID = app.id.isEmpty ? "unknown" : app.id
        guard sourceID != Bundle.main.bundleIdentifier,
            !PrivacyPolicy.shouldIgnore(types: clipboard.types, source: sourceID, excluded: settings.excludedApps)
        else { return nil }
        // 满载时先消耗变更计数，不再向来源应用同步索取完整图片。
        guard canRead else { onError?(StoreError.processingBusy); return nil }
        let version = generation
        let sourceVersion = sourceRevision
        let date = Date()
        reading = true
        defer { reading = false }
        guard let snapshot = await clipboard.capture(expectedChangeCount: captureCount) else { return nil }
        permissions.refreshClipboard()
        guard !Task.isCancelled, generation == version, sourceRevision == sourceVersion,
            clipboard.changeCount == captureCount, settings.clipboardEnabled, sessionActive,
            settings.hasOnboarded, !settings.paused, permissions.allowsMonitoring,
            !settings.excludedApps.contains(sourceID) else { return nil }
        let bytes: Int
        switch snapshot {
        case .image(let data): bytes = data.count
        case .text(let value): bytes = value.utf8.count
        }
        return Capture(snapshot: snapshot, sourceID: sourceID, sourceName: app.name, date: date, generation: version, bytes: bytes)
    }
    var isPolling: Bool { task != nil }
    var isCleanupScheduled: Bool { cleanupTask != nil }
    var pendingCaptureCount: Int { pending.count }
    var retainedCaptureBytes: Int { queuedBytes + processingBytes }
    func enqueueCapture() async {
        let available = 32 * 1024 * 1024 - retainedCaptureBytes
        guard let capture = await takeCapture(canRead: pending.count < 8 && available > 0) else { return }
        guard pending.count < 8, capture.bytes <= 32 * 1024 * 1024 - retainedCaptureBytes else {
            onError?(StoreError.processingBusy)
            return
        }
        pending.append(capture)
        queuedBytes += capture.bytes
        startProcessingPending()
    }
    private func startProcessingPending() {
        guard processingTask == nil, !pending.isEmpty else { return }
        processingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.pending.isEmpty else { break }
                let capture = self.pending.removeFirst()
                self.queuedBytes -= capture.bytes
                self.processingBytes = capture.bytes
                await self.process(capture)
                self.processingBytes = 0
            }
            self?.processingTask = nil
            if let self, !self.pending.isEmpty { self.startProcessingPending() }
        }
    }
    private func process(_ capture: Capture) async {
        guard settings.clipboardEnabled, !Task.isCancelled, capture.generation == generation, sessionActive, settings.hasOnboarded,
            !settings.paused, permissions.allowsMonitoring, !settings.excludedApps.contains(capture.sourceID) else { return }
        let interval = PerformanceTrace.signposter.beginInterval("ClipboardProcessing", id: PerformanceTrace.signposter.makeSignpostID())
        defer { PerformanceTrace.signposter.endInterval("ClipboardProcessing", interval) }
        do {
            let content: PreparedContent
            switch capture.snapshot {
            case .text(let string): content = .text(string)
            case .image(let data): content = try await prepareImage(data)
            }
            // Settings may change while a large image is being processed. Never persist after a privacy pause.
            permissions.refreshClipboard()
            guard settings.clipboardEnabled, !Task.isCancelled, capture.generation == generation, sessionActive, settings.hasOnboarded, !settings.paused,
                permissions.allowsMonitoring, !settings.excludedApps.contains(capture.sourceID)
            else { return }
            try await repository.save(
                content, sourceBundleID: capture.sourceID, sourceName: capture.sourceName, policy: settings.policy, now: capture.date)
            onCaptureSucceeded?()
            onChange?()
        } catch is CancellationError {} catch {
            if settings.clipboardEnabled, capture.generation == generation { onError?(error) }
        }
    }
    func scheduleCleanup() {
        cleanupTask?.cancel()
        cleanupTask = nil
        cleanupRevision += 1
        let revision = cleanupRevision
        guard settings.clipboardEnabled, running, sessionActive else { return }
        cleanupTask = Task { [weak self] in
            defer { if self?.cleanupRevision == revision { self?.cleanupTask = nil } }
            var retrying = false
            var retryDelay: Double = 1
            // 启动或重新开启后先恢复保留策略，随后按实际过期时间调度。
            while !Task.isCancelled {
                guard let repository = self?.repository else { return }
                do {
                    if retrying {
                        try await Task.sleep(for: .seconds(retryDelay))
                        retryDelay = min(60, retryDelay * 2)
                        try await repository.retry()
                    }
                    try Task.checkCancellation()
                    guard let policy = self?.settings.policy, self?.settings.clipboardEnabled == true,
                          self?.running == true, self?.sessionActive == true else { return }
                    if try await repository.pruneIfNeeded(policy: policy, now: Date()), !Task.isCancelled {
                        self?.onChange?()
                    }
                    let date = try await repository.nextCleanup(policy: policy, now: Date())
                    retrying = false
                    retryDelay = 1
                    try await Task.sleep(for: .seconds(max(1, date.timeIntervalSinceNow)), tolerance: .seconds(1))
                } catch is CancellationError { return } catch {
                    if !Task.isCancelled, self?.settings.clipboardEnabled == true { self?.onError?(error) }
                    retrying = true
                }
            }
        }
    }
}
