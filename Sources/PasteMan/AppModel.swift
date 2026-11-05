import AppKit
import Observation
import PasteManCore

@MainActor @Observable final class AppModel {
    let repository: any HistoryRepository
    let settings: AppSettings
    let permissions: PermissionService
    let hotKeys: HotKeyService
    @ObservationIgnored let finderModel: FinderModel
    private(set) var entries: [HistoryEntry] = []
    private(set) var sources: [SourceApplication] = []
    private(set) var loading = false
    var search = ""
    var filter = HistoryFilter.all
    var source = ""
    var selection: UUID?
    var message: String?
    var recordingIssue: String?
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
    private let pasteExecutor: any PasteExecuting
    private let clipboardWriter: any ClipboardWriting

    init(
        repository: any HistoryRepository, settings: AppSettings, permissions: PermissionService,
        hotKeys: HotKeyService, pasteExecutor: any PasteExecuting = SystemPasteExecutor(),
        clipboardWriter: any ClipboardWriting = SystemClipboard()
    ) {
        self.repository = repository
        self.settings = settings
        self.permissions = permissions
        self.hotKeys = hotKeys
        self.finderModel = FinderModel()
        self.pasteExecutor = pasteExecutor
        self.clipboardWriter = clipboardWriter
    }
    func refresh() {
        revision += 1
        let version = revision
        loadTask?.cancel()
        loading = true
        let query = search
        let filter = filter
        let sourceID = source.isEmpty ? nil : source
        let sourceVersion = dataRevision
        let needsSources = sourcesRevision != sourceVersion
        loadTask = Task {
            do {
                if !query.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
                let rows = try await repository.list(search: query, filter: filter, source: sourceID)
                try Task.checkCancellation()
                let apps = needsSources ? try await repository.sources() : nil
                guard !Task.isCancelled, version == revision else { return }
                entries = rows
                if query.isEmpty, filter == .all, sourceID == nil {
                    ThumbnailCache.shared.retain(Set(rows.map(\.id)))
                }
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
    func cancelRefresh() {
        revision += 1
        loadTask?.cancel()
        loadTask = nil
        loading = false
    }
    func moveSelection(_ offset: Int) {
        guard !entries.isEmpty else { return }
        let current = entries.firstIndex { $0.id == selection } ?? (offset > 0 ? -1 : entries.count)
        selection = entries[min(max(current + offset, 0), entries.count - 1)].id
    }
    func performSelected() {
        if let entry = entries.first(where: { $0.id == selection }) { activate(entry) }
    }
    func toggleFavorite(_ entry: HistoryEntry) {
        Task {
            do {
                try await repository.setFavorite(entry.id, value: !entry.isFavorite)
                try await repository.prune(policy: settings.policy, now: Date())
                changed()
            } catch { message = L.error(error) }
        }
    }
    func delete(_ entry: HistoryEntry) {
        Task {
            do {
                try await repository.delete(entry.id)
                ThumbnailCache.shared.remove(entry.id)
                changed()
            } catch { message = L.error(error) }
        }
    }
    func clear(includingFavorites: Bool) {
        Task {
            do {
                try await repository.clear(includingFavorites: includingFavorites)
                ThumbnailCache.shared.removeAll()
                changed()
            } catch { message = L.error(error) }
        }
    }
    func applyRetention() {
        Task {
            do {
                try await repository.prune(policy: settings.policy, now: Date())
                changed()
            } catch { message = L.error(error) }
        }
    }
    func activate(_ entry: HistoryEntry, copyOnly: Bool = false) {
        guard !pasteInProgress else { return }
        pasteInProgress = true
        // Capture the intended recipient before any async work or window dismissal.
        let recipient = target
        Task {
            defer { pasteInProgress = false }
            do {
                let content = try await repository.content(for: entry)
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
        let other = action == .history ? settings.screenshotShortcut : settings.shortcut
        if !shortcut.matches(other), hotKeys.register(shortcut, for: action) {
            if action == .history { settings.shortcut = shortcut } else { settings.screenshotShortcut = shortcut }
            message = nil
            return true
        }
        message = L.t("This shortcut is already in use. Choose another combination.", "此快捷键已被占用，请选择其他组合。")
        return false
    }
}
