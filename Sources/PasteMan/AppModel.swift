import AppKit
import Observation
import PasteManCore

@MainActor @Observable final class AppModel {
    let repository: any HistoryRepository
    let settings: AppSettings
    let permissions: PermissionService
    let hotKeys: HotKeyService
    let updates: any UpdateChecking
    let mouseScroll: MouseScrollService
    @ObservationIgnored let finderModel: FinderModel
    private(set) var entries: [HistoryEntry] = []
    private(set) var sources: [SourceApplication] = []
    private(set) var loading = false
    private(set) var loadingMore = false
    private(set) var hasMore = false
    private var nextPage: HistoryCursor?
    private var pageTask: Task<Void, Never>?
    var search = ""
    var filter = HistoryFilter.all
    var source = ""
    var selection: UUID?
    var message: String?
    var recordingIssue: String?
    var shortcutIssues: [HotKeyAction: String] = [:]
    var preview: HistoryEntry?
    var panelVisible = false
    var onClose: (() -> Void)?
    var onSettings: (() -> Void)?
    var onMenu: (() -> Void)?
    var onClear: (() -> Void)?
    var onPause: (() -> Void)?
    var onIgnoreWrite: (() -> Void)?
    var target: NSRunningApplication?
    private var loadTask: Task<Void, Never>?
    private var revision = 0
    private var dataRevision = 0
    private var sourcesRevision = -1
    private var pasteInProgress = false
    private var clipboardRevision = 0
    private let pasteExecutor: any PasteExecuting
    private let clipboardWriter: any ClipboardWriting

    init(
        repository: any HistoryRepository, settings: AppSettings, permissions: PermissionService,
        hotKeys: HotKeyService, pasteExecutor: any PasteExecuting = SystemPasteExecutor(),
        clipboardWriter: any ClipboardWriting = SystemClipboard(), finderModel: FinderModel = FinderModel(),
        updates: any UpdateChecking = UpdateController()
    ) {
        self.repository = repository
        self.settings = settings
        self.permissions = permissions
        self.hotKeys = hotKeys
        self.updates = updates
        let mouseScroll = MouseScrollService(configuration: settings.mouse)
        self.mouseScroll = mouseScroll
        settings.onMouseChanged = { [weak settings, weak mouseScroll] in
            if let settings { mouseScroll?.apply(settings.mouse) }
        }
        self.finderModel = finderModel
        self.pasteExecutor = pasteExecutor
        self.clipboardWriter = clipboardWriter
    }
    func refresh() {
        guard settings.clipboardEnabled else { return }
        revision += 1
        let version = revision
        loadTask?.cancel()
        pageTask?.cancel()
        loadingMore = false
        nextPage = nil
        hasMore = false
        loading = true
        let query = search
        let filter = filter
        let sourceID = source.isEmpty ? nil : source
        let sourceVersion = dataRevision
        let needsSources = sourcesRevision != sourceVersion
        loadTask = Task {
            let interval = PerformanceTrace.signposter.beginInterval("HistoryFirstPage", id: PerformanceTrace.signposter.makeSignpostID())
            defer { PerformanceTrace.signposter.endInterval("HistoryFirstPage", interval) }
            do {
                if !query.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
                let page = try await repository.page(search: query, filter: filter, source: sourceID, after: nil, limit: 100)
                let rows = page.entries
                try Task.checkCancellation()
                let apps = needsSources ? try await repository.sources() : nil
                guard !Task.isCancelled, version == revision else { return }
                entries = rows
                nextPage = page.next
                hasMore = page.next != nil
                if let apps {
                    sources = apps
                    sourcesRevision = sourceVersion
                }
                if !rows.contains(where: { $0.id == selection }) { selection = rows.first?.id }
                loading = false
            } catch is CancellationError {} catch {
                guard version == revision else { return }
                loading = false
                message = L.error(error)
            }
        }
    }
    func changed() {
        dataRevision += 1
        if panelVisible { refresh() }
    }
    func retryHistory() {
        guard settings.clipboardEnabled else { return }
        Task {
            do {
                try await repository.retry()
                guard settings.clipboardEnabled else { return }
                message = nil
                recordingIssue = nil
                changed()
                if !panelVisible { refresh() }
            } catch { message = L.error(error) }
        }
    }
    func cancelRefresh() {
        revision += 1
        loadTask?.cancel()
        loadTask = nil
        loading = false
        pageTask?.cancel()
        pageTask = nil
        loadingMore = false
    }
    func suspendClipboard() {
        clipboardRevision += 1
        panelVisible = false
        preview = nil
        cancelRefresh()
    }
    func loadMore(selectNext: Bool = false) {
        guard settings.clipboardEnabled, !loading, !loadingMore, let cursor = nextPage else { return }
        let version = revision
        let query = search
        let currentFilter = filter
        let sourceID = source.isEmpty ? nil : source
        loadingMore = true
        pageTask = Task {
            defer { if version == revision { loadingMore = false } }
            do {
                let page = try await repository.page(search: query, filter: currentFilter, source: sourceID,
                    after: cursor, limit: 100)
                guard !Task.isCancelled, version == revision else { return }
                let known = Set(entries.map(\.id))
                entries += page.entries.filter { !known.contains($0.id) }
                nextPage = page.next
                hasMore = page.next != nil
                if selectNext { selection = page.entries.first?.id ?? selection }
            } catch is CancellationError {} catch {
                guard version == revision else { return }
                message = L.error(error)
            }
        }
    }
    func moveSelection(_ offset: Int) {
        guard !entries.isEmpty else { return }
        let current = entries.firstIndex { $0.id == selection } ?? (offset > 0 ? -1 : entries.count)
        if offset > 0, current + offset >= entries.count, hasMore { loadMore(selectNext: true); return }
        selection = entries[min(max(current + offset, 0), entries.count - 1)].id
    }
    func performSelected() {
        if let entry = entries.first(where: { $0.id == selection }) { activate(entry) }
    }
    func toggleFavorite(_ entry: HistoryEntry) {
        guard settings.clipboardEnabled else { return }
        Task {
            do {
                try await repository.setFavorite(entry.id, value: !entry.isFavorite)
                try await repository.prune(policy: settings.policy, now: Date())
                changed()
            } catch { message = L.error(error) }
        }
    }
    func delete(_ entry: HistoryEntry) {
        guard settings.clipboardEnabled else { return }
        Task {
            do {
                try await repository.delete(entry.id)
                ThumbnailCache.shared.remove(entry.id)
                changed()
            } catch { message = L.error(error) }
        }
    }
    func clear(includingFavorites: Bool) {
        guard settings.clipboardEnabled else { return }
        Task {
            do {
                try await repository.clear(includingFavorites: includingFavorites)
                ThumbnailCache.shared.removeAll()
                changed()
            } catch { message = L.error(error) }
        }
    }
    func applyRetention() {
        guard settings.clipboardEnabled else { return }
        Task {
            do {
                try await repository.prune(policy: settings.policy, now: Date())
                changed()
            } catch { message = L.error(error) }
        }
    }
    func activate(_ entry: HistoryEntry, copyOnly: Bool = false) {
        guard settings.clipboardEnabled, !pasteInProgress else { return }
        pasteInProgress = true
        let version = clipboardRevision
        // Capture the intended recipient before any async work or window dismissal.
        let recipient = target
        Task {
            defer { pasteInProgress = false }
            do {
                let content = try await repository.content(for: entry)
                guard settings.clipboardEnabled, version == clipboardRevision else { return }
                let written = clipboardWriter.write(content)
                onIgnoreWrite?()
                guard written else {
                    message = L.t("Could not write to the clipboard. Try again.", "无法写入剪贴板，请重试。")
                    return
                }
                preview = nil
                onClose?()
                if copyOnly { return }
                let outcome = await pasteExecutor.paste(to: recipient)
                permissions.refresh()
                if outcome != .sent {
                    message = outcome.recoveryMessage
                    // A visible alert is needed because the history panel has already closed.
                    let alert = NSAlert()
                    alert.messageText = L.t("Ready to paste", "内容已准备好")
                    alert.informativeText = message ?? ""
                    alert.addButton(withTitle: L.t("OK", "好"))
                    alert.runModal()
                }
            } catch { message = L.error(error) }
        }
    }
    func applyShortcut(_ shortcut: Shortcut, for action: HotKeyAction = .history) -> Bool {
        let enabled = action == .history ? settings.clipboardEnabled : settings.screenshotEnabled
        let other = action == .history ? settings.screenshotShortcut : settings.shortcut
        if !shortcut.matches(other), !enabled || hotKeys.register(shortcut, for: action) {
            if action == .history { settings.shortcut = shortcut } else { settings.screenshotShortcut = shortcut }
            shortcutIssues[action] = nil
            message = nil
            return true
        }
        message = L.t("This shortcut is already in use. Choose another combination.", "此快捷键已被占用，请选择其他组合。")
        shortcutIssues[action] = message
        return false
    }
}
