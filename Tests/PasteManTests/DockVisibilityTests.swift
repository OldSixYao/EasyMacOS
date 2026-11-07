import Foundation
import Testing

@testable import PasteMan

@Suite("程序坞显示偏好") @MainActor struct DockVisibilityTests {
    @Test func defaultsToHiddenAndRestoresBothChoices() throws {
        let suite = "DockVisibility." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // 模拟已有其他偏好的旧版本升级。
        defaults.set(true, forKey: "hasOnboarded")
        defaults.set(true, forKey: "paused")
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.showInDock)
        settings.showInDock = true
        let reopened = AppSettings(defaults: defaults)
        #expect(reopened.showInDock)
        #expect(reopened.hasOnboarded && reopened.paused)
        reopened.showInDock = false
        #expect(!AppSettings(defaults: defaults).showInDock)
        #expect(defaults.object(forKey: "showInDock") as? Bool == false)
    }

    @Test func changesNotifyAfterPersistenceAndSkipIdenticalValues() throws {
        let suite = "DockVisibility." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        var observed: [Bool] = []
        settings.onDockVisibilityChanged = { [weak settings] in
            guard let settings else { return }
            #expect(defaults.object(forKey: "showInDock") as? Bool == settings.showInDock)
            observed.append(settings.showInDock)
        }
        settings.showInDock = false
        settings.showInDock = true
        settings.showInDock = true
        settings.showInDock = false
        settings.showInDock = false
        #expect(observed == [true, false])
    }
}
