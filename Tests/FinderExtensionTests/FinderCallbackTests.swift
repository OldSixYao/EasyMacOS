import AppKit
import FinderMenuCore
import Testing

@testable import FinderExtension

@Suite("访达后台回调") struct FinderCallbackTests {
    @Test func fileOperationsDoNotActivateHostButSettingsDo() throws {
        for action in FinderAction.allCases {
            let request = try FinderRequest(action: action, items: [URL(fileURLWithPath: "/tmp")], cutToken: action == .pasteMove ? UUID() : nil)
            let configuration = FinderExtension.hostConfiguration(for: request.url)
            #expect(!configuration.activates)
            #expect(!configuration.hides)
            #expect(!configuration.hidesOthers)
        }
        #expect(FinderExtension.hostConfiguration(for: FinderRequest.settingsURL).activates)
    }

    @Test func backgroundCallbackDispatchesEveryActionToMainActor() async throws {
        for action in FinderAction.allCases {
            let request = try FinderRequest(action: action, items: [URL(fileURLWithPath: "/tmp")], cutToken: action == .pasteMove ? UUID() : nil)
            let received = await withCheckedContinuation { continuation in
                let dispatcher = FinderCommandDispatcher { value in
                    MainActor.assertIsolated()
                    continuation.resume(returning: value)
                }
                Task.detached { dispatcher.submit(request) }
            }
            #expect(received == request)
        }
    }

    @Test func objectiveCEntriesHaveNoMainThreadPrecondition() async {
        // 真实系统入口从后台队列进入；无效 tag 不执行操作，也不应触发线程断言。
        await Task.detached {
            let extensionObject = FinderExtension()
            let item = NSMenuItem(title: "无效测试项", action: nil, keyEquivalent: "")
            item.tag = -1
            extensionObject.performMenuAction(item)
        }.value
    }
}

@Suite("访达菜单层级") struct FinderMenuLayoutTests {
    @Test func menuUsesConfiguredLanguageWithoutChangingCommands() throws {
        var configuration = FinderConfiguration()
        configuration.language = .english
        let plan = try #require(FinderMenuPlan(items: [URL(fileURLWithPath: "/tmp")], configuration: configuration))
        let menu = FinderExtension().makeMenu(plan: plan, configuration: configuration, usesTarget: true)
        #expect(menu.items.map(\.title) == ["New File", "Copy Full Path", "Copy File Name", "Open Terminal Here", "Show/Hide Hidden Files"])
        #expect(menu.items[1].tag == FinderMenuCommand(action: .copyPath, usesTarget: true).tag)
        #expect(menu.items.first?.submenu?.items.map(\.title) == FinderConfiguration.defaultSuffixes)
    }

    @Test func cutSelectionAndPasteOnlyAppearInTheirContexts() throws {
        let configuration = FinderConfiguration()
        let cut = FinderCutState(token: UUID(), changeCount: 20, fileCount: 2, commandID: 16)
        let plan = try #require(FinderMenuPlan(
            items: [URL(fileURLWithPath: "/tmp")], configuration: configuration, hasSelection: true,
            cutToken: cut.token, cutCommandID: cut.commandID))
        let menu = FinderExtension().makeMenu(plan: plan, configuration: configuration, usesTarget: false)
        #expect(menu.items.map(\.title) == ["新建文件", "剪切", "粘贴（移动）", "复制完整路径", "复制文件名", "在此处打开终端", "显示／隐藏隐藏文件"])
        let paste = try #require(menu.items.first { $0.title == "粘贴（移动）" })
        #expect(FinderMenuCommand(tag: paste.tag)?.cutCommandID == cut.commandID)
        var disabled = configuration
        disabled.set(.cut, enabled: false)
        disabled.set(.pasteMove, enabled: false)
        let disabledPlan = try #require(FinderMenuPlan(
            items: [URL(fileURLWithPath: "/tmp")], configuration: disabled, hasSelection: true, cutToken: cut.token))
        #expect(!disabledPlan.actions.contains(.cut))
        #expect(!disabledPlan.actions.contains(.pasteMove))
    }

    @Test func menuIconsResolveColorsForLightAndDarkAppearance() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            let image = try #require(FinderMenuIcon.image(symbol: "doc.badge.plus", appearance: appearance))
            let data = try NSKeyedArchiver.archivedData(withRootObject: image, requiringSecureCoding: true)
            let decoded = try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: NSImage.self, from: data))
            let bitmap = try #require(decoded.representations.first as? NSBitmapImageRep)
            var samples = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    guard color.alphaComponent > 0.5 else { continue }
                    #expect(name == .darkAqua ? color.redComponent > 0.9 : color.redComponent < 0.1)
                    samples += 1
                }
            }
            #expect(samples > 0)
        }
    }

    @Test func menuIconsRemainBitmapTemplatesAcrossProcessArchiving() throws {
        for action in FinderAction.allCases {
            let image = try #require(FinderMenuIcon.image(symbol: action.symbol))
            let data = try NSKeyedArchiver.archivedData(withRootObject: image, requiringSecureCoding: true)
            let decoded = try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: NSImage.self, from: data))
            #expect(decoded.isTemplate)
            #expect(decoded.size == NSSize(width: 18, height: 18))
            #expect(decoded.representations.count == 2)
            #expect(decoded.representations.allSatisfy { $0 is NSBitmapImageRep })
            for bitmap in decoded.representations.compactMap({ $0 as? NSBitmapImageRep }) {
                var filled = 0
                var clear = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                        if color.alphaComponent > 0.1 { filled += 1 }
                        else { clear += 1 }
                    }
                }
                #expect(filled > 0)
                #expect(clear > filled)
            }
        }
    }

    @Test func actionsAreTopLevelAndOnlyCreationHasSubmenu() throws {
        let configuration = FinderConfiguration()
        let plan = try #require(FinderMenuPlan(items: [URL(fileURLWithPath: "/tmp")], configuration: configuration))
        let menu = FinderExtension().makeMenu(plan: plan, configuration: configuration, usesTarget: true)
        #expect(menu.items.map(\.title) == ["新建文件", "复制完整路径", "复制文件名", "在此处打开终端", "显示／隐藏隐藏文件"])
        #expect(menu.items.filter { $0.submenu != nil }.map(\.title) == ["新建文件"])
        let types = try #require(menu.items.first?.submenu).items
        #expect(types.map(\.title) == FinderConfiguration.defaultSuffixes)
        for (type, item) in zip(configuration.fileTypes, types) {
            let image = try #require(item.image)
            let data = try NSKeyedArchiver.archivedData(withRootObject: image, requiringSecureCoding: true)
            let decoded = try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: NSImage.self, from: data))
            #expect(!decoded.isTemplate)
            #expect(decoded.representations.count == 2)
            #expect(decoded.representations.allSatisfy { $0 is NSBitmapImageRep })
            #expect(decoded.representations.compactMap { $0 as? NSBitmapImageRep }.allSatisfy { bitmap in
                (0..<bitmap.pixelsWide).contains { x in
                    (0..<bitmap.pixelsHigh).contains { y in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 }
                }
            })
            let command = try #require(FinderMenuCommand(tag: item.tag))
            #expect(command.usesTarget)
            #expect(command.fileTypeID == type.id)
            #expect(try command.request(target: URL(fileURLWithPath: "/tmp"), selection: [], configuration: configuration).suffix == type.suffix)
        }
    }

    @Test func switchesEmptyTypesAndAmbiguousDirectory() throws {
        var configuration = FinderConfiguration()
        let url = URL(fileURLWithPath: "/tmp")
        configuration.set(.newText, enabled: false)
        var plan = try #require(FinderMenuPlan(items: [url], configuration: configuration))
        #expect(!plan.actions.contains(.newText))
        configuration.set(.newText, enabled: true)
        for type in configuration.fileTypes { configuration.removeFileType(id: type.id) }
        plan = try #require(FinderMenuPlan(items: [url], configuration: configuration))
        #expect(!plan.actions.contains(.newText))
        configuration.enabled = false
        #expect(FinderMenuPlan(items: [url], configuration: configuration) == nil)
        configuration = FinderConfiguration()
        configuration.set(.copyName, enabled: false)
        plan = try #require(FinderMenuPlan(items: [url], configuration: configuration,
                                         resolveDirectory: { _ in throw FinderMenuError.ambiguousDirectory }))
        let menu = FinderExtension().makeMenu(plan: plan, configuration: configuration, usesTarget: false)
        #expect(!menu.items.contains { $0.title == "复制文件名" })
        #expect(menu.items.first?.isEnabled == false)
        #expect(menu.items.first?.submenu?.items.allSatisfy { !$0.isEnabled } == true)
        #expect(menu.items.first { $0.title == "在此处打开终端" }?.isEnabled == false)
        #expect(menu.items.first { $0.title == "复制完整路径" }?.isEnabled == true)
        #expect(menu.items.first { $0.title == "显示／隐藏隐藏文件" }?.isEnabled == true)
    }

    @Test func hiddenFilesToggleCanBeDisabledAndNeverAddsSettingsEntry() throws {
        var configuration = FinderConfiguration()
        configuration.set(.toggleHiddenFiles, enabled: false)
        var plan = try #require(FinderMenuPlan(items: [URL(fileURLWithPath: "/tmp")], configuration: configuration))
        var menu = FinderExtension().makeMenu(plan: plan, configuration: configuration, usesTarget: true)
        #expect(!menu.items.contains { $0.title == "显示／隐藏隐藏文件" })
        for action in FinderAction.allCases { configuration.set(action, enabled: false) }
        plan = try #require(FinderMenuPlan(items: [URL(fileURLWithPath: "/tmp")], configuration: configuration))
        menu = FinderExtension().makeMenu(plan: plan, configuration: configuration, usesTarget: true)
        #expect(menu.items.isEmpty)
    }
}
