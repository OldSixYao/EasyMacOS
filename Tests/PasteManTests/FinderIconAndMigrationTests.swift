import AppKit
import FinderMenuCore
import Testing

@testable import PasteMan

private actor DelayedIconImport {
    private var continuation: CheckedContinuation<Void, Never>?
    var started: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func resume() { continuation?.resume(); continuation = nil }
}

@Suite("文件类型图标与办公升级", .serialized) @MainActor struct FinderIconAndMigrationTests {
    @Test(arguments: ["restore", "remove", "defaults", "cancel"])
    func pendingImportCannotUndoNewerUserActions(_ action: String) async throws {
        let store = store()
        let root = store.url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("输入.png")
        try image(at: source)
        let delayed = DelayedIconImport()
        let model = FinderModel(store: store, importIconResource: { url, icons in
            await delayed.wait()
            return try await FinderIconImportWorker.shared.importImage(at: url, store: icons)
        })
        let importing = Task { await model.importIcon(at: source, id: 1) }
        defer { importing.cancel(); Task { await delayed.resume() } }
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await delayed.started), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await delayed.started)
        switch action {
        case "restore": model.restoreIcon(id: 1)
        case "remove": model.removeFileType(id: 1)
        case "defaults": model.restoreDefaults()
        default: importing.cancel()
        }
        let expected = model.configuration
        await delayed.resume()
        #expect(!(await importing.value))
        #expect(model.configuration == expected)
        #expect(try store.load() == expected)
        if FileManager.default.fileExists(atPath: model.iconStore.directory.path) {
            #expect(try FileManager.default.contentsOfDirectory(atPath: model.iconStore.directory.path).isEmpty)
        }
    }

    @Test func unchangedIconsReuseBitmapsAndRemovalInvalidatesCustomPixels() throws {
        let store = store()
        let root = store.url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let icons = FinderFileTypeIconStore(configurationStore: store)
        let type = FinderFileType(id: 1, suffix: "docx")
        let first = FinderFileTypeIcon.image(for: type, store: icons)
        #expect(first === FinderFileTypeIcon.image(for: type, store: icons))
        #expect(first !== FinderFileTypeIcon.image(for: type, store: icons, size: 24))
        let source = root.appendingPathComponent("输入.png")
        try image(at: source)
        let resource = try icons.importImage(at: source)
        let custom = FinderFileType(id: 1, suffix: "docx", iconResource: resource)
        let pixels = FinderFileTypeIcon.image(for: custom, store: icons)
        #expect(pixels === FinderFileTypeIcon.image(for: custom, store: icons))
        icons.remove(resource: resource)
        #expect(FinderFileTypeIcon.image(for: custom, store: icons).tiffRepresentation == first.tiffRepresentation)
    }

    private func store() -> FinderConfigurationStore {
        FinderConfigurationStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderIcons-" + UUID().uuidString).appendingPathComponent("menu.json"))
    }

    private func image(at url: URL) throws {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 640, height: 320, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.2, blue: 0.1, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 320))
        let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    @Test(arguments: ["defaults", "custom", "empty", "existing", "switchesOnly"])
    func hostMigratesOnceAndNeverReusesIDs(_ scenario: String) throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        var types: [[String: Any]] = []
        switch scenario {
        case "defaults": types = FinderConfiguration.legacySuffixes.enumerated().map { ["id": $0.offset + 1, "suffix": $0.element] }
        case "custom": types = [["id": 2, "suffix": "yaml"], ["id": 8, "suffix": "tar.gz"]]
        case "existing": types = [["id": 4, "suffix": "pptx"], ["id": 7, "suffix": "docx"]]
        default: break
        }
        var object: [String: Any] = ["enabled": false, "disabledActions": ["newText", "copyName"],
                                    "fileTypes": types, "nextFileTypeID": 40]
        if scenario == "switchesOnly" { object.removeValue(forKey: "fileTypes"); object.removeValue(forKey: "nextFileTypeID") }
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: store.url)
        let original = try store.load()
        #expect(!original.officeTypesMigrated)
        // 仅读取不升级，也不改变磁盘。
        #expect(try store.load() == original)
        let model = FinderModel(store: store)
        #expect(model.configuration.officeTypesMigrated)
        #expect(!model.configuration.enabled)
        #expect(model.configuration.disabledActions == ["newText", "copyName"])
        #expect(Array(model.configuration.fileTypes.prefix(original.fileTypes.count)) == original.fileTypes)
        #expect(Set(model.configuration.fileTypes.map(\.suffix)).isSuperset(of: FinderConfiguration.officeSuffixes))
        let added = model.configuration.fileTypes.dropFirst(original.fileTypes.count)
        #expect(added.allSatisfy { $0.id >= original.nextFileTypeID })
        #expect(try store.load() == model.configuration)
        let office = try #require(model.configuration.fileTypes.first { $0.suffix == "docx" })
        let nextID = model.configuration.nextFileTypeID
        model.removeFileType(id: office.id)
        let restarted = FinderModel(store: store)
        #expect(!restarted.configuration.fileTypes.contains { $0.suffix == "docx" })
        #expect(restarted.configuration.nextFileTypeID == nextID)
        #expect(restarted.addFileType("new-type"))
        #expect(restarted.configuration.fileTypes.last?.id == nextID)
    }

    @Test func failedMigrationDoesNotRecordCompletion() throws {
        let store = store()
        let root = store.url.deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = Data(#"{"enabled":false,"disabledActions":[],"fileTypes":[],"nextFileTypeID":20}"#.utf8)
        try data.write(to: store.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        let model = FinderModel(store: store)
        #expect(!model.configuration.officeTypesMigrated)
        #expect(model.configuration.fileTypes.isEmpty)
        #expect(model.message != nil)
        #expect(try Data(contentsOf: store.url) == data)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        #expect(FinderModel(store: store).configuration.officeTypesMigrated)
    }

    @Test func importedIconsSurviveRestartAndOriginalRemovalAndCleanAfterSave() async throws {
        let store = store()
        let root = store.url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("原始图片.png")
        try image(at: source)
        let model = FinderModel(store: store)
        #expect(await model.importIcon(at: source, id: 1))
        let first = try #require(model.configuration.fileTypes.first?.iconResource)
        let firstURL = try #require(model.iconStore.url(for: first))
        let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: firstURL)))
        #expect(bitmap.pixelsWide == 128)
        #expect(bitmap.pixelsHigh == 64)
        #expect(bitmap.hasAlpha)
        let color = try #require(bitmap.colorAt(x: 20, y: 20)?.usingColorSpace(.deviceRGB))
        #expect(color.redComponent > 0.8 && color.greenComponent < 0.3)
        #expect(abs(color.alphaComponent - 0.5) < 0.03)
        #expect(try #require(bitmap.colorAt(x: 100, y: 20)).alphaComponent == 0)
        let restart = FinderModel(store: store)
        try FileManager.default.removeItem(at: source)
        #expect(restart.iconStore.image(resource: first) != nil)
        #expect(restart.configuration.fileTypes.first?.iconResource == first)
        #expect(!(await restart.importIcon(at: source, id: 1)))
        #expect(restart.configuration.fileTypes.first?.iconResource == first)
        try image(at: source)
        #expect(await restart.importIcon(at: source, id: 1))
        let second = try #require(restart.configuration.fileTypes.first?.iconResource)
        #expect(second != first)
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
        restart.restoreIcon(id: 1)
        #expect(restart.configuration.fileTypes.first?.iconResource == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: restart.iconStore.directory.path).isEmpty)
        #expect(await restart.importIcon(at: source, id: 1))
        restart.removeFileType(id: 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: restart.iconStore.directory.path).isEmpty)
        #expect(await restart.importIcon(at: source, id: 2))
        restart.restoreDefaults()
        #expect(restart.configuration.fileTypes.allSatisfy { $0.iconResource == nil })
        #expect(try FileManager.default.contentsOfDirectory(atPath: restart.iconStore.directory.path).isEmpty)
    }

    @Test func iconFailuresPreserveConfigurationAndOldResource() async throws {
        let store = store()
        let root = store.url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("输入.png")
        try image(at: source)
        let model = FinderModel(store: store)
        #expect(await model.importIcon(at: source, id: 1))
        let previous = model.configuration
        let savedData = try Data(contentsOf: store.url)
        await model.applyIconSelection(nil, id: 1)
        #expect(model.configuration == previous)
        #expect(try Data(contentsOf: store.url) == savedData)
        let resource = try #require(previous.fileTypes.first?.iconResource)
        let previousData = try Data(contentsOf: #require(model.iconStore.url(for: resource)))
        try Data("不是图片".utf8).write(to: source)
        #expect(!(await model.importIcon(at: source, id: 1)))
        #expect(model.configuration == previous)
        try image(at: source)
        // 资源写入成功、配置保存失败：回滚新资源，保留旧资源。
        try FileManager.default.removeItem(at: store.url)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: false)
        #expect(!(await model.importIcon(at: source, id: 1)))
        model.restoreIcon(id: 1)
        model.removeFileType(id: 1)
        model.restoreDefaults()
        #expect(model.configuration == previous)
        #expect(try Data(contentsOf: #require(model.iconStore.url(for: resource))) == previousData)
        #expect(try FileManager.default.contentsOfDirectory(atPath: model.iconStore.directory.path) == [resource])
        // 图片目录不可保存，同样不影响原配置。
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: model.iconStore.directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: model.iconStore.directory.path) }
        #expect(!(await model.importIcon(at: source, id: 1)))
        #expect(model.configuration == previous)
    }

    @Test func missingCorruptAndEscapingResourcesFallBackToDefault() throws {
        let store = store()
        let icons = FinderFileTypeIconStore(configurationStore: store)
        let root = store.url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: icons.directory, withIntermediateDirectories: true)
        let type = FinderFileType(id: 1, suffix: "docx", iconResource: "missing.png")
        let defaultData = try #require(FinderFileTypeIcon.image(for: FinderFileType(id: 1, suffix: "docx"), store: icons).tiffRepresentation)
        #expect(FinderFileTypeIcon.image(for: type, store: icons).tiffRepresentation == defaultData)
        try Data("损坏".utf8).write(to: icons.directory.appendingPathComponent("missing.png"))
        #expect(FinderFileTypeIcon.image(for: type, store: icons).tiffRepresentation == defaultData)
        let outside = root.appendingPathComponent("outside.png")
        try image(at: outside)
        try FileManager.default.createSymbolicLink(at: icons.directory.appendingPathComponent("escape.png"), withDestinationURL: outside)
        #expect(icons.url(for: "escape.png") == nil)
        #expect(icons.image(resource: "escape.png") == nil)
    }

    @Test func customBitmapPreservesColorAndAlphaAcrossProcessArchiving() throws {
        let store = store()
        let root = store.url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("图片.png")
        try image(at: source)
        let icons = FinderFileTypeIconStore(configurationStore: store)
        let resource = try icons.importImage(at: source)
        let type = FinderFileType(id: 1, suffix: "unknown", iconResource: resource)
        let image = FinderFileTypeIcon.image(for: type, store: icons)
        let data = try NSKeyedArchiver.archivedData(withRootObject: image, requiringSecureCoding: true)
        let decoded = try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: NSImage.self, from: data))
        #expect(!decoded.isTemplate)
        #expect(decoded.representations.count == 2)
        let bitmap = try #require(decoded.representations.last as? NSBitmapImageRep)
        var colored = 0
        var transparent = 0
        for x in 0..<bitmap.pixelsWide { for y in 0..<bitmap.pixelsHigh {
            let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            if color.alphaComponent > 0.4 {
                #expect(color.redComponent > 0.8 && color.greenComponent < 0.3)
                #expect(color.alphaComponent < 0.55)
                colored += 1
            } else if color.alphaComponent == 0 { transparent += 1 }
        } }
        #expect(colored > 0 && transparent > 0)
    }
}
