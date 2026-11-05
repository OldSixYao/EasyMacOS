import AppKit
import Testing

@testable import PasteMan

@Suite("录制状态菜单栏显示", .serialized) @MainActor struct RecordingStatusAppearanceTests {
    @Test func persistedPauseUsesPausedIconAndTooltipAfterRelaunch() throws {
        let suite = "RecordingStatus." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        AppSettings(defaults: defaults).paused = true
        let reloaded = AppSettings(defaults: defaults)
        let appearance = RecordingStatusAppearance(paused: reloaded.paused, applicationLabel: "EasyMacOS 测试")
        #expect(appearance.symbol == "pause.circle")
        #expect(appearance.toolTip == "EasyMacOS 测试" + L.t(" — Paused", " — 已暂停"))
        reloaded.paused = false
        let resumed = RecordingStatusAppearance(paused: reloaded.paused, applicationLabel: "EasyMacOS 测试")
        #expect(resumed.symbol == "doc.on.clipboard")
        #expect(resumed.toolTip == "EasyMacOS 测试")
    }

    @Test func changingStatusUpdatesRealButtonAndKeepsTemplateImage() throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try #require(item.button)
        for paused in [true, false, true] {
            let appearance = RecordingStatusAppearance(paused: paused, applicationLabel: "测试")
            appearance.apply(to: button)
            #expect(button.image?.isTemplate == true)
            #expect(button.toolTip == appearance.toolTip)
        }
    }
}
