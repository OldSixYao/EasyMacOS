import AppKit

struct RecordingStatusAppearance {
    let paused: Bool
    let applicationLabel: String
    var clipboardEnabled = true

    var symbol: String { !clipboardEnabled ? "doc.on.clipboard" : (paused ? "pause.circle" : "doc.on.clipboard") }
    var toolTip: String {
        if !clipboardEnabled { return applicationLabel + L.t(" — Clipboard disabled", " — 剪贴板已关闭") }
        return applicationLabel + (paused ? L.t(" — Paused", " — 已暂停") : "")
    }

    @MainActor func apply(to button: NSStatusBarButton) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "EasyMacOS")
        button.image?.isTemplate = true
        button.toolTip = toolTip
    }
}
