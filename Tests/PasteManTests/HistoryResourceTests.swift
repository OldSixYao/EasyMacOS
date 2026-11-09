import AppKit
import FinderMenuCore
import PasteManCore
import Testing

@testable import PasteMan

@Suite("历史后台资源回收", .serialized) @MainActor struct HistoryResourceTests {
    @Test func hiddenHistoryKeepsOnlyFirstPageThenExpiresAndReopens() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "HistoryResources." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let keys = HotKeyService()
        defer {
            keys.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = try HistoryStore(directory: directory)
        for index in 0..<213 {
            try await store.save(.text("历史 \(index)"), sourceBundleID: "test", sourceName: "合成应用", policy: RetentionPolicy())
        }
        let settings = AppSettings(defaults: defaults)
        let model = AppModel(repository: store, settings: settings, permissions: PermissionService(), hotKeys: keys,
            finderModel: FinderModel(store: FinderConfigurationStore(url: directory.appendingPathComponent("finder.json"))),
            hiddenRetention: .milliseconds(80))
        model.panelVisible = true
        model.refresh()
        try await wait { !model.loading }
        model.loadMore()
        try await wait { !model.loadingMore }
        #expect(model.entries.count == 200 && !model.sources.isEmpty)
        model.panelVisible = false
        #expect(model.entries.count == 100 && model.hasMore)
        model.panelVisible = true
        try await Task.sleep(for: .milliseconds(120))
        #expect(model.entries.count == 100, "快速重开应取消回收")
        model.loadMore()
        try await wait { !model.loadingMore }
        #expect(model.entries.count == 200 && Set(model.entries.map(\.id)).count == 200)
        model.panelVisible = false
        try await wait { model.entries.isEmpty }
        #expect(model.sources.isEmpty && !model.hasMore && model.selection == nil)
        model.panelVisible = true
        model.refresh()
        try await wait { !model.loading }
        #expect(model.entries.count == 100 && !model.sources.isEmpty)
        model.suspendClipboard()
        #expect(model.entries.isEmpty && model.sources.isEmpty)
        model.releaseHiddenResources()
    }

    @Test func pressureReclaimsHiddenDataButKeepsVisibleSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let keys = HotKeyService()
        defer { keys.stop(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(directory: directory)
        try await store.save(.text("可见历史"), sourceBundleID: "test", sourceName: "合成应用", policy: RetentionPolicy())
        let model = AppModel(repository: store, settings: AppSettings(defaults: defaults), permissions: PermissionService(), hotKeys: keys)
        model.panelVisible = true
        model.refresh()
        try await wait { !model.loading }
        let selected = model.selection
        model.releaseHiddenResources()
        #expect(model.entries.count == 1 && model.selection == selected)
        model.panelVisible = false
        model.releaseHiddenResources()
        #expect(model.entries.isEmpty && model.sources.isEmpty)
    }

    @Test func outsideClickSubscriptionExistsOnlyDuringPresentation() {
        var installed = 0, removed = 0, dismissed = 0
        var callback: (() -> Void)?
        let monitor = HistoryOutsideClickMonitor(install: { action in
            installed += 1
            callback = action
            return installed
        }, remove: { _ in removed += 1; callback = nil })
        #expect(installed == 0)
        monitor.start { dismissed += 1 }
        monitor.start { dismissed += 100 }
        callback?()
        #expect(installed == 1 && dismissed == 1)
        monitor.stop()
        monitor.stop()
        #expect(removed == 1 && callback == nil)
        monitor.start { dismissed += 1 }
        #expect(installed == 2)
        monitor.stop()
    }

    private func wait(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(ready())
    }
}
