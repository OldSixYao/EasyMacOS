import AppKit
import Testing

@testable import PasteMan

@Suite("History panel") @MainActor struct HistoryPanelTests {
    @Test func menuBarPanelCanFocusWithoutActivatingItsApp() {
        _ = NSApplication.shared
        let panel = HistoryPanel()
        defer { panel.close() }
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.hidesOnDeactivate)
        #expect(!panel.becomesKeyOnlyIfNeeded)
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
    }
}
