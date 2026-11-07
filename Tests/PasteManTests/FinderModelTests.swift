import AppKit
import FinderMenuCore
import SwiftUI
import Testing

@testable import PasteMan

@Suite("访达菜单配置", .serialized) @MainActor struct FinderModelTests {
    @Test func changesPersistAndDefaultsRestore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FinderModel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FinderConfigurationStore(url: root.appendingPathComponent("menu.json"))
        let model = FinderModel(store: store)
        model.set(.copyName, enabled: false)
        #expect(!model.configuration.contains(.copyName))
        #expect(try store.load() == model.configuration)
        model.setEnabled(false)
        #expect(!model.configuration.contains(.newText))
        model.restoreDefaults()
        #expect(model.configuration == FinderConfiguration())
        #expect(try store.load() == FinderConfiguration())
    }

    @Test func failedSaveRetainsPreviousConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FinderModel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("不是目录")
        try Data().write(to: parent)
        let model = FinderModel(store: FinderConfigurationStore(url: parent.appendingPathComponent("menu.json")))
        model.setEnabled(false)
        #expect(model.configuration.enabled)
        #expect(model.message != nil)
    }

    /// Optional native snapshots; output stays under the caller's ignored report directory.
    @Test func renderSettings() async throws {
        guard let output = ProcessInfo.processInfo.environment["EASYMACOS_FINDER_RENDER_DIR"] else { return }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FinderRender-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = FinderModel(store: FinderConfigurationStore(url: root.appendingPathComponent("menu.json")))
        let outputURL = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let previousLanguage = L.language
        defer { InterfaceLocalization.shared.setLanguage(previousLanguage) }
        for (name, appearance, language) in [("light", NSAppearance.Name.aqua, AppLanguage.simplifiedChinese),
                ("dark", NSAppearance.Name.darkAqua, .simplifiedChinese), ("english", NSAppearance.Name.aqua, .english),
                ("long-list", NSAppearance.Name.aqua, .simplifiedChinese), ("disabled", NSAppearance.Name.darkAqua, .simplifiedChinese)] {
            InterfaceLocalization.shared.setLanguage(language)
            if name == "long-list" { for index in 1...20 { _ = model.addFileType("custom-\(index)") } }
            if name == "disabled" { model.setEnabled(false) }
            let view = NSHostingView(
                rootView: FinderSettingsView(model: model)
                    .background(Color(nsColor: .windowBackgroundColor)))
            view.frame = NSRect(x: 0, y: 0, width: 550, height: 1000)
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: outputURL.appendingPathComponent("finder-\(name).png"))
            if name == "long-list" {
                func scrollView(in parent: NSView) -> NSScrollView? {
                    if let nested = parent.subviews.lazy.compactMap({ scrollView(in: $0) }).first { return nested }
                    if let scroll = parent as? NSScrollView { return scroll }
                    return nil
                }
                let scroll = try #require(scrollView(in: view))
                let document = try #require(scroll.documentView)
                #expect(abs(scroll.contentView.bounds.height - 220) < 1)
                #expect(scroll.hasVerticalScroller)
                #expect(document.frame.height > scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: document.frame.height - scroll.contentView.bounds.height))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await Task.sleep(for: .milliseconds(150))
                view.layoutSubtreeIfNeeded()
                #expect(scroll.contentView.bounds.minY > 0)
                let bottom = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bottom)
                try #require(bottom.representation(using: .png, properties: [:]))
                    .write(to: outputURL.appendingPathComponent("finder-long-list-bottom.png"))
            }
            window.contentView = nil
            window.close()
        }
    }
}

extension FinderModelTests {
    @Test func fileTypeEditingPersistsAndInvalidInputKeepsConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FinderConfigurationStore(url: root.appendingPathComponent("menu.json"))
        let model = FinderModel(store: store)
        #expect(model.addFileType(" .YAML "))
        #expect(model.configuration.fileTypes.last?.suffix == "yaml")
        let previous = model.configuration
        #expect(!model.addFileType("a/b"))
        #expect(model.configuration == previous)
        #expect(try store.load() == previous)
        for type in model.configuration.fileTypes { model.removeFileType(id: type.id) }
        #expect(model.configuration.fileTypes.isEmpty)
        #expect(try store.load().fileTypes.isEmpty)
        model.restoreDefaults()
        #expect(model.configuration.fileTypes.map(\.suffix) == FinderConfiguration.defaultSuffixes)
        #expect(try store.load() == model.configuration)
    }

    @Test func fileTypeSaveFailureRetainsOriginalAndNextID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FinderConfigurationStore(url: root.appendingPathComponent("menu.json"))
        let model = FinderModel(store: store)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: false)
        let previous = model.configuration
        #expect(!model.addFileType("yaml"))
        #expect(model.configuration == previous)
        model.removeFileType(id: previous.fileTypes[0].id)
        #expect(model.configuration == previous)
        model.restoreDefaults()
        #expect(model.configuration == previous)
        #expect(model.message != nil)
    }
}


extension FinderModelTests {
    @Test func languagePersistsAlongsideMenuConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FinderLanguage-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FinderConfigurationStore(url: root.appendingPathComponent("menu.json"))
        let model = FinderModel(store: store)
        model.setLanguage(.english)
        model.set(.copyName, enabled: false)
        #expect(try store.load().language == .english)
        #expect(!model.configuration.contains(.copyName))
        model.restoreDefaults()
        #expect(model.configuration.language == .english)
        model.setLanguage(.simplifiedChinese)
        #expect(try store.load().language == .simplifiedChinese)
    }
}
