import AppKit
import Foundation
import PasteManCore
import SwiftUI
import Testing

@testable import PasteMan

@Suite("Native view rendering", .serialized) @MainActor struct RenderingTests {
    /// Opt in with PASTEMAN_RENDER_TESTS=1; no windows are shown and no system clipboard is read.
    @Test func renderScreens() async throws {
        guard ProcessInfo.processInfo.environment["PASTEMAN_RENDER_TESTS"] == "1" else { return }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PasteManRendering-" + UUID().uuidString)
        let suite = "PasteManRendering." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let keys = HotKeyService()
        defer {
            keys.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = try HistoryStore(directory: directory)
        let settings = AppSettings(defaults: defaults)
        let permissions = PermissionService()
        let model = AppModel(repository: store, settings: settings, permissions: permissions, hotKeys: keys)
        settings.hasOnboarded = true
        let now = Date()
        for (index, text) in [
            "轻量、原生，让每一次复制都有迹可循。",
            "https://developer.apple.com/documentation/appkit/nspasteboard",
            "func greet(name: String) -> String {\n    return \"Hello, \\(name)\"\n}",
            "Meeting notes\n• Review the menu bar interaction\n• Ship a quieter clipboard tool",
        ].enumerated() {
            try await store.save(
                .text(text), sourceBundleID: index == 1 ? "com.apple.Safari" : "com.apple.TextEdit",
                sourceName: index == 1 ? "Safari" : "TextEdit", policy: RetentionPolicy(),
                now: now.addingTimeInterval(Double(-index * 60)))
        }
        let sample = NSImage(size: NSSize(width: 2400, height: 1600))
        sample.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 2400, height: 1600).fill()
        NSColor.systemTeal.setFill()
        NSRect(x: 200, y: 200, width: 2000, height: 1200).fill()
        sample.unlockFocus()
        let tiff = try #require(sample.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let sampleData = try #require(bitmap.representation(using: .png, properties: [:]))
        try await store.save(
            try ImageProcessor.prepare(sampleData), sourceBundleID: "test.image",
            sourceName: "Synthetic image", policy: RetentionPolicy(), now: now)
        if let first = try await store.list().first { try await store.setFavorite(first.id, value: true) }
        model.panelVisible = true
        model.refresh()
        for _ in 0..<100 {
            if !model.loading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.entries.count == 5)
        let output = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["PASTEMAN_RENDER_DIR"] ?? "/tmp/pasteman-rendering",
            isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await snapshot(
            HistoryView(model: model), size: NSSize(width: 440, height: 590), appearance: .aqua,
            to: output.appendingPathComponent("history-light.png"))
        try await snapshot(
            HistoryView(model: model), size: NSSize(width: 440, height: 590), appearance: .darkAqua,
            to: output.appendingPathComponent("history-dark.png"))
        model.preview = model.entries.first(where: { $0.kind == .image })
        try await snapshot(
            HistoryView(model: model), size: NSSize(width: 440, height: 590), appearance: .darkAqua,
            to: output.appendingPathComponent("image-preview-dark.png"))
        try await store.save(
            .text(String(repeating: "中文日志 {\"value\":123} 🙂 — full text remains selectable\n", count: 10_000)),
            sourceBundleID: "test.logs", sourceName: "Synthetic logs", policy: RetentionPolicy(), now: now)
        model.preview = try await store.list().first(where: { $0.sourceBundleID == "test.logs" })
        try await snapshot(
            HistoryView(model: model), size: NSSize(width: 440, height: 590), appearance: .aqua,
            to: output.appendingPathComponent("long-text-preview-light.png"))
        model.preview = nil
        try await snapshot(
            SettingsView(model: model), size: NSSize(width: 550, height: 610), appearance: .aqua,
            to: output.appendingPathComponent("settings.png"))
        try await snapshot(
            SettingsView(model: model, initialTab: .privacy), size: NSSize(width: 550, height: 610),
            appearance: .darkAqua, to: output.appendingPathComponent("settings-privacy-dark.png"))
        try await snapshot(
            SettingsView(model: model, initialTab: .permissions), size: NSSize(width: 550, height: 610),
            appearance: .darkAqua, to: output.appendingPathComponent("settings-permissions-dark.png"))
        try await snapshot(
            Form {
                Section {
                    PermissionStatusRow(
                        title: L.t("Clipboard recording", "剪贴板记录"), status: L.t("Allowed", "已允许"), granted: true)
                }
                Section {
                    PermissionStatusRow(
                        title: L.t("Automatic paste", "自动粘贴"), status: L.t("Enabled", "已启用"), granted: true)
                }
            }.formStyle(.grouped), size: NSSize(width: 550, height: 180),
            appearance: .darkAqua, to: output.appendingPathComponent("permissions-granted-dark.png"))
        let editorState = ScreenshotEditorState()
        editorState.tool = .arrow
        try await snapshot(
            ScreenshotToolbar(state: editorState), size: NSSize(width: 492, height: 56),
            appearance: .aqua, to: output.appendingPathComponent("screenshot-toolbar-light.png"))
        try await snapshot(
            ScreenshotToolbar(state: editorState), size: NSSize(width: 492, height: 56),
            appearance: .darkAqua, to: output.appendingPathComponent("screenshot-toolbar-dark.png"))
        editorState.optionsExpanded = true
        try await snapshot(
            ScreenshotToolbar(state: editorState), size: NSSize(width: 492, height: 92),
            appearance: .darkAqua, to: output.appendingPathComponent("screenshot-toolbar-options-dark.png"))
        let screen = ScreenshotScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 800, height: 600), scale: 1)
        let capture = CapturedScreen(
            screen: screen, image: try #require(sample.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        let coordinator = ScreenshotCoordinator(presentWindow: { _ in })
        let overlay = ScreenshotOverlay(capture: capture, coordinator: coordinator)
        let overlayWindow = NSWindow(
            contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        overlayWindow.isReleasedWhenClosed = false
        overlayWindow.contentView = overlay
        defer {
            overlayWindow.contentView = nil
            overlayWindow.close()
            coordinator.cancel()
        }
        overlay.layoutSubtreeIfNeeded()
        let movement = try #require(
            NSEvent.mouseEvent(
                with: .mouseMoved, location: CGPoint(x: 390, y: 370),
                modifierFlags: [], timestamp: 0, windowNumber: overlayWindow.windowNumber, context: nil,
                eventNumber: 0, clickCount: 0, pressure: 0))
        overlay.mouseMoved(with: movement)
        let cursorBitmap = try #require(overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds))
        overlay.cacheDisplay(in: overlay.bounds, to: cursorBitmap)
        try #require(cursorBitmap.representation(using: .png, properties: [:])).write(
            to: output.appendingPathComponent("screenshot-cursor.png"))
        try await snapshot(
            WelcomeView(permissions: permissions, onFinish: {}), size: NSSize(width: 470, height: 540),
            appearance: .aqua, to: output.appendingPathComponent("welcome.png"))
    }

    private func snapshot<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, to url: URL) async throws {
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        hosting.appearance = NSAppearance(named: appearance)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = hosting.appearance
        window.contentView = hosting
        defer {
            window.contentView = nil
            window.close()
        }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url)
        #expect(png.count > 1000)
    }
}
