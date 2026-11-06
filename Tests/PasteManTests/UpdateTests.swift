import AppKit
import FinderMenuCore
import Foundation
import Observation
import PasteManCore
import Sparkle
import SwiftUI
import Testing
import os

@testable import PasteMan

@MainActor private final class TestUpdateEngine: UpdateEngine {
    var starts = 0
    var checks = 0
    var startError: (any Error)?
    func start() throws {
        starts += 1
        if let startError { throw startError }
    }
    func checkForUpdates() { checks += 1 }
}

@MainActor @Observable private final class TestUpdateService: UpdateChecking {
    var canCheckForUpdates = true
    var checks = 0
    func checkForUpdates() { if canCheckForUpdates { checks += 1 } }
}

@MainActor private final class TestUpdateProbe {
    var calls = 0
    var published = false
    var networkError = false
    var messages: [UpdateFeedback] = []
}

private final class UpdateHTTPStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let code = Int(request.url!.lastPathComponent)!
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("应用内更新", .serialized) @MainActor struct UpdateTests {
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(predicate())
    }

    @Test func explicitCheckStartsOnceAndCycleCompletionAllowsRetry() async throws {
        let engine = TestUpdateEngine()
        let probe = TestUpdateProbe()
        let controller = UpdateController(makeEngine: { _ in engine }, availability: { probe.calls += 1; return true },
                                          present: { _ in Issue.record("不应出现错误提示") })
        #expect(engine.starts == 0 && probe.calls == 0 && controller.canCheckForUpdates)
        controller.checkForUpdates()
        controller.checkForUpdates()
        #expect(!controller.canCheckForUpdates)
        try await wait { engine.checks == 1 }
        #expect(probe.calls == 1 && engine.starts == 1)
        let driver = UpdateUserDriver()
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)
        controller.updater(updater, didFinishUpdateCycleFor: .updates, error: nil)
        #expect(controller.canCheckForUpdates)
        controller.checkForUpdates()
        try await wait { engine.checks == 2 }
        #expect(probe.calls == 2 && engine.starts == 1)
        controller.updater(updater, didFinishUpdateCycleFor: .updates, error: URLError(.networkConnectionLost))
        #expect(controller.canCheckForUpdates)
        #expect(controller.allowedChannels(for: updater).isEmpty)
        #expect(throws: CancellationError.self) { try controller.updater(updater, mayPerform: .updatesInBackground) }
        try controller.updater(updater, mayPerform: .updates)
    }

    @Test func unpublishedNetworkAndStartupFailuresReleaseBusyState() async throws {
        let engine = TestUpdateEngine()
        let probe = TestUpdateProbe()
        let controller = UpdateController(makeEngine: { _ in engine }, availability: {
            if probe.networkError { throw URLError(.notConnectedToInternet) }
            return probe.published
        }, present: { probe.messages.append($0) })
        controller.checkForUpdates()
        try await wait { controller.canCheckForUpdates }
        #expect(probe.messages.count == 1 && engine.starts == 0)
        probe.published = true
        probe.networkError = true
        controller.checkForUpdates()
        try await wait { controller.canCheckForUpdates }
        #expect(probe.messages.count == 2 && engine.starts == 0)
        probe.networkError = false
        engine.startError = URLError(.cannotLoadFromNetwork)
        controller.checkForUpdates()
        try await wait { controller.canCheckForUpdates }
        #expect(probe.messages.count == 3 && engine.starts == 1 && engine.checks == 0)
        engine.startError = nil
        controller.checkForUpdates()
        try await wait { engine.checks == 1 }
        #expect(engine.starts == 2)
    }

    @Test func missingFeedIsDistinctFromServerFailure() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateHTTPStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        #expect(try await UpdateAvailability.check(url: URL(string: "https://updates.invalid/200")!, session: session))
        #expect(try await !UpdateAvailability.check(url: URL(string: "https://updates.invalid/404")!, session: session))
        do {
            _ = try await UpdateAvailability.check(url: URL(string: "https://updates.invalid/503")!, session: session)
            Issue.record("服务器故障不能误报为暂无版本")
        } catch { #expect((error as NSError).code == URLError.badServerResponse.rawValue) }
    }

    @Test func allEntrypointsShareTheInjectedServiceAndValidateMenus() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateTests-" + UUID().uuidString)
        let suite = "UpdateTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let service = TestUpdateService()
        let delegate = AppDelegate(updates: service)
        let model = AppModel(repository: try HistoryStore(directory: directory), settings: AppSettings(defaults: defaults),
                             permissions: PermissionService(), hotKeys: HotKeyService(),
                             finderModel: FinderModel(store: FinderConfigurationStore(url: directory.appendingPathComponent("finder.json"))),
                             updates: service)
        #expect(delegate.updates === model.updates)
        // 设置按钮直接调用该服务；两个菜单均通过同一代理动作进入该服务。
        model.updates.checkForUpdates()
        for menu in [delegate.makeApplicationMenu(), delegate.makeStatusMenu(for: model)] {
            let item = try #require(menu.items.first { $0.action == #selector(AppDelegate.checkForUpdates) })
            #expect(item.target === delegate)
            #expect(delegate.validateMenuItem(item))
            delegate.perform(item.action)
        }
        #expect(service.checks == 3)
        service.canCheckForUpdates = false
        let mainItem = try #require(delegate.makeApplicationMenu().items.first { $0.action == #selector(AppDelegate.checkForUpdates) })
        #expect(!delegate.validateMenuItem(mainItem))
        let statusItem = try #require(delegate.makeStatusMenu(for: model).items.first { $0.action == #selector(AppDelegate.checkForUpdates) })
        #expect(!statusItem.isEnabled)
    }

    @Test func progressAndFeedbackFollowApplicationLanguageAndClampProgress() {
        let original = L.language
        defer { InterfaceLocalization.shared.setLanguage(original) }
        InterfaceLocalization.shared.setLanguage(.simplifiedChinese)
        let progress = UpdateProgress()
        #expect(progress.stage.title == "正在检查更新…")
        #expect(UpdateFeedback.unpublished.title == "暂时没有可用版本")
        let changes = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking { _ = progress.stage.title } onChange: { changes.withLock { $0 += 1 } }
        InterfaceLocalization.shared.setLanguage(.english)
        #expect(changes.withLock { $0 } == 1)
        #expect(progress.stage.title == "Checking for updates…")
        #expect(UpdateFeedback.unpublished.title == "No releases available")
        #expect(UpdateFeedback.failure(URLError(.notConnectedToInternet)).message.contains("connection"))
        progress.stage = .downloading
        #expect(progress.fraction == nil)
        progress.expected = 100
        progress.received = 500
        #expect(progress.fraction == 1)
    }

    @Test func settingsRenderInBothLanguages() async throws {
        guard ProcessInfo.processInfo.environment["EASYMACOS_UPDATE_UI"] == "1" else { return }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateUI-" + UUID().uuidString)
        let suite = "UpdateUI." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let original = L.language
        defer {
            InterfaceLocalization.shared.setLanguage(original)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let service = TestUpdateService()
        let model = AppModel(repository: try HistoryStore(directory: directory), settings: AppSettings(defaults: defaults),
                             permissions: PermissionService(), hotKeys: HotKeyService(),
                             finderModel: FinderModel(store: FinderConfigurationStore(url: directory.appendingPathComponent("finder.json"))),
                             updates: service)
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EASYMACOS_UPDATE_UI_OUTPUT"] ?? "/tmp/easymacos-update-ui")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for language in [AppLanguage.simplifiedChinese, .english] {
            InterfaceLocalization.shared.setLanguage(language)
            let hosting = NSHostingView(rootView: SettingsView(model: model))
            hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 580)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.center()
            window.makeKeyAndOrderFront(nil)
            defer { window.contentView = nil; window.close() }
            try await Task.sleep(for: .milliseconds(200))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(png.count > 1000)
            try png.write(to: output.appendingPathComponent("settings-\(language.rawValue).png"))
        }
    }
}
