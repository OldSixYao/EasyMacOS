import AppKit
import FinderMenuCore
import FinderSync

@objc(EasyMacOSFinderSync) final class FinderExtension: FIFinderSync {
    override init() {
        super.init()
        // Registering a root does not enumerate files or read their contents.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/", isDirectory: true)]
        Task { @MainActor in FinderVolumeRegistration.shared.start() }
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let controller = FIFinderSyncController.default()
        let items: [URL]
        let hasSelection: Bool
        if menuKind == .contextualMenuForContainer || menuKind == .contextualMenuForSidebar {
            items = controller.targetedURL().map { [$0] } ?? []
            hasSelection = false
        } else {
            let selected = controller.selectedItemURLs() ?? []
            items = selected.isEmpty ? controller.targetedURL().map { [$0] } ?? [] : selected
            hasSelection = !selected.isEmpty
        }
        guard !items.isEmpty, items.allSatisfy(\.isFileURL) else { return nil }
        let configuration: FinderConfiguration
        do { configuration = try FinderConfigurationStore().load() } catch {
            return settingsMenu(title: "访达菜单配置无法读取…")
        }
        let cutState = try? FinderCutStateStore().load()
        let cutToken = cutState?.availableToken(changeCount: NSPasteboard.general.changeCount)
        guard let plan = FinderMenuPlan(
            items: items, configuration: configuration, hasSelection: hasSelection, cutToken: cutToken,
            cutCommandID: cutState?.commandID
        ) else { return nil }

        return makeMenu(plan: plan, configuration: configuration,
                        usesTarget: menuKind == .contextualMenuForContainer || menuKind == .contextualMenuForSidebar)
    }

    func makeMenu(plan: FinderMenuPlan, configuration: FinderConfiguration, usesTarget: Bool) -> NSMenu {
        let menu = NSMenu(title: "EasyMacOS")
        menu.autoenablesItems = false
        for action in plan.actions {
            let item = NSMenuItem(title: action.title, action: nil, keyEquivalent: "")
            item.image = FinderMenuIcon.image(symbol: action.symbol)
            item.isEnabled = plan.allows(action)
            if !item.isEnabled { item.toolTip = "请选择一个文件夹，或同一目录中的文件。" }
            if action == .newText {
                let types = NSMenu(title: action.title)
                types.autoenablesItems = false
                for type in configuration.fileTypes {
                    let child = NSMenuItem(title: "." + type.suffix, action: #selector(performMenuAction(_:)), keyEquivalent: "")
                    child.target = self
                    child.tag = FinderMenuCommand(action: action, usesTarget: usesTarget, fileTypeID: type.id).tag
                    child.isEnabled = item.isEnabled
                    types.addItem(child)
                }
                item.submenu = types
            } else {
                item.action = #selector(performMenuAction(_:))
                item.target = self
                item.tag = FinderMenuCommand(
                    action: action, usesTarget: usesTarget, cutCommandID: action == .pasteMove ? plan.cutCommandID : nil).tag
            }
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        addSettings(to: menu)
        return menu
    }

    private func settingsMenu(title: String) -> NSMenu {
        let menu = NSMenu()
        addSettings(to: menu, title: title)
        return menu
    }

    private func addSettings(to menu: NSMenu, title: String = "访达菜单设置…") {
        let item = NSMenuItem(title: title, action: #selector(openSettings(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc func performMenuAction(_ sender: NSMenuItem) {
        // 目标与选区仅在同步菜单回调期间有效，必须先捕获再切换线程。
        let controller = FIFinderSyncController.default()
        guard let command = FinderMenuCommand(tag: sender.tag),
            let configuration = try? FinderConfigurationStore().load(),
            let token = Self.tokenForCommand(command),
            let request = try? command.request(
                target: controller.targetedURL(), selection: controller.selectedItemURLs() ?? [],
                configuration: configuration, cutToken: token.value)
        else { return }
        FinderCommandDispatcher(perform: Self.execute).submit(request)
    }

    // 标记只从与菜单 tag 中持久编号一致的记录取得，旧菜单不能粘贴后来剪切的文件。
    private struct CutToken { let value: UUID? }

    private static func tokenForCommand(_ command: FinderMenuCommand) -> CutToken? {
        guard command.action == .pasteMove else { return CutToken(value: nil) }
        guard let state = try? FinderCutStateStore().load(),
            let token = state.availableToken(
                changeCount: NSPasteboard.general.changeCount, commandID: command.cutCommandID) else { return nil }
        return CutToken(value: token)
    }

    @MainActor private static func execute(_ request: FinderRequest) {
        switch request.action {
        case .copyPath, .copyName:
            guard let value = try? FinderOperations.clipboardText(for: request.action, items: request.items)
            else {
                return
            }
            NSPasteboard.general.clearContents()
            if !NSPasteboard.general.setString(value, forType: .string) { NSSound.beep() }
        default:
            openHost(request.url)
        }
    }

    @objc func openSettings(_ sender: NSMenuItem) {
        Task { @MainActor in Self.openHost(FinderRequest.settingsURL) }
    }

    @MainActor private static func openHost(_ url: URL) {
        NSWorkspace.shared.open([url], withApplicationAt: containingApp, configuration: hostConfiguration(for: url)) { _, error in
            if error != nil { DispatchQueue.main.async { NSSound.beep() } }
        }
    }

    static func hostConfiguration(for url: URL) -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        // 文件操作在后台交给宿主，避免先激活宿主、再定位访达造成窗口与菜单栏闪动。
        configuration.activates = url == FinderRequest.settingsURL
        return configuration
    }

    private static var containingApp: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
