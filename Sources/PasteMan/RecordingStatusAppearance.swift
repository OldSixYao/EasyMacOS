import AppKit

struct RecordingStatusAppearance {
    let paused: Bool
    let applicationLabel: String

    var symbol: String { paused ? "pause.circle" : "doc.on.clipboard" }
    var toolTip: String { applicationLabel + (paused ? L.t(" — Paused", " — 已暂停") : "") }

    @MainActor func apply(to button: NSStatusBarButton) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "EasyMacOS")
        button.image?.isTemplate = true
        button.toolTip = toolTip
    }
}
