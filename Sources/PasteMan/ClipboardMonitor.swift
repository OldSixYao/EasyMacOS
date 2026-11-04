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
    private var screenshotGeneration = 0
    private var monitoringEnabled: Bool
    private var task: Task<Void, Never>?
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
            try await Task.detached(priority: .utility) { try ImageProcessor.prepare(data) }.value
        }
    ) {
        self.clipboard = clipboard
        self.repository = repository
        self.settings = settings
        self.permissions = permissions
        self.sourceApplication = sourceApplication
        self.prepareImage = prepareImage
        monitoringEnabled = settings.hasOnboarded && !settings.paused && permissions.allowsMonitoring
        gate = CaptureGate(count: clipboard.changeCount)
    }
    var pollInterval: Duration {
        if !settings.hasOnboarded || settings.paused { return .seconds(60) }
        return permissions.allowsMonitoring ? .milliseconds(500) : .seconds(5)
    }
    func recordingStateChanged() {
        resetBaseline()
        monitoringEnabled = settings.hasOnboarded && !settings.paused && permissions.allowsMonitoring
        // Wake immediately on resume/onboarding; inactive periods never backfill.
        if task != nil { start() }
    }
    func start() {
        task?.cancel()
        task = Task { [weak self] in
            let clock = ContinuousClock()
            var nextCleanup = clock.now.advanced(by: .seconds(60))
            while !Task.isCancelled {
                guard let interval = self?.pollInterval else { return }
                do { try await Task.sleep(for: interval) } catch { return }
                guard !Task.isCancelled, let self else { return }
                if self.settings.hasOnboarded && !self.settings.paused { await self.poll() }
                guard !Task.isCancelled else { return }
                if clock.now >= nextCleanup {
                    do {
                        try await self.repository.prune(policy: self.settings.policy, now: Date())
                        self.onChange?()
                    } catch { self.onError?(error) }
                    nextCleanup = clock.now.advanced(by: .seconds(60))
                }
            }
        }
    }
    func stop() {
        task?.cancel()
        task = nil
    }
    func resetBaseline(invalidateScreenshots: Bool = true) {
        generation += 1
        if invalidateScreenshots { screenshotGeneration += 1 }
        gate.reset(to: clipboard.changeCount)
    }
    func ignoreOwnWrite() { resetBaseline(invalidateScreenshots: false) }

    /// The caller synchronously resets the baseline immediately after its successful write.
    /// This explicit path records user-requested screenshots without rereading the pasteboard.
    func screenshotTicket(sourceID: String) -> Int? {
        permissions.refreshClipboard()
        guard settings.hasOnboarded, !settings.paused, permissions.allowsMonitoring,
            !settings.excludedApps.contains(sourceID)
        else { return nil }
        return screenshotGeneration
    }
    func recordScreenshot(_ png: Data, sourceID: String, sourceName: String, ticket: Int) async throws {
        guard screenshotTicket(sourceID: sourceID) == ticket else { return }
        let content = try await prepareImage(png)
        permissions.refreshClipboard()
        guard ticket == screenshotGeneration, settings.hasOnboarded, !settings.paused, permissions.allowsMonitoring,
            !settings.excludedApps.contains(sourceID)
        else { return }
        try await repository.save(
            content, sourceBundleID: sourceID, sourceName: sourceName,
            policy: settings.policy, now: Date())
        onCaptureSucceeded?()
        onChange?()
    }

    func poll() async {
        permissions.refreshClipboard()
        let enabled = settings.hasOnboarded && !settings.paused && permissions.allowsMonitoring
        let captureCount = clipboard.changeCount
        if enabled != monitoringEnabled {
            monitoringEnabled = enabled
            resetBaseline()
        }
        guard gate.consume(count: captureCount, enabled: enabled) else { return }
        let app = sourceApplication()
        let sourceID = app.id.isEmpty ? "unknown" : app.id
        guard sourceID != Bundle.main.bundleIdentifier,
            !PrivacyPolicy.shouldIgnore(types: clipboard.types, source: sourceID, excluded: settings.excludedApps),
            let snapshot = clipboard.capture(), clipboard.changeCount == captureCount
        else { return }
        let sourceName = app.name
        let capturedAt = Date()
        let captureGeneration = generation
        do {
            let content: PreparedContent
            switch snapshot {
            case .text(let string): content = .text(string)
            case .image(let data): content = try await prepareImage(data)
            }
            // Settings may change while a large image is being processed. Never persist after a privacy pause.
            permissions.refreshClipboard()
            guard captureGeneration == generation, settings.hasOnboarded, !settings.paused,
                permissions.allowsMonitoring, !settings.excludedApps.contains(sourceID)
            else { return }
            try await repository.save(
                content, sourceBundleID: sourceID, sourceName: sourceName, policy: settings.policy, now: capturedAt)
            onCaptureSucceeded?()
            onChange?()
        } catch { onError?(error) }
    }
}
