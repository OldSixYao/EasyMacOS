import AppKit
import FinderMenuCore
import PasteManCore
import ServiceManagement
import SwiftUI

enum SettingsTab: Int, CaseIterable {
    case general, screenshot, clipboard, finder, mouse, permissions

    var title: String {
        switch self {
        case .general: L.t("General", "通用")
        case .screenshot: L.t("Screenshots", "截图")
        case .clipboard: L.t("Clipboard", "剪贴板")
        case .finder: L.t("Context Menu", "右键菜单")
        case .mouse: L.t("Mouse", "鼠标")
        case .permissions: L.t("Permissions", "权限")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .screenshot: "viewfinder"
        case .clipboard: "doc.on.clipboard"
        case .finder: "cursorarrow.click.2"
        case .mouse: "computermouse"
        case .permissions: "checkmark.shield"
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @ViewState private var recording: HotKeyAction?
    @ViewState private var shortcutError: String?
    @ViewState private var newBundleID = ""
    @ViewState private var error: String?
    @ViewState private var selectedTab: SettingsTab
    @FocusState private var focusedTab: SettingsTab?

    init(model: AppModel, initialTab: SettingsTab = .general) {
        self.model = model
        _selectedTab = ViewState(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Button {
                        selectedTab = tab
                        focusedTab = tab
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: tab.symbol).font(.system(size: 20)).frame(height: 24)
                            Text(tab.title).font(.system(size: 12, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 60)
                        .foregroundStyle(selectedTab == tab ? Color.accentColor : .secondary)
                        .background(selectedTab == tab ? Color.accentColor.opacity(0.10) : .clear,
                                    in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .focused($focusedTab, equals: tab)
                    .accessibilityAddTraits(selectedTab == tab ? [.isSelected] : [])
                    .accessibilityRemoveTraits(selectedTab == tab ? [] : [.isSelected])
                    .accessibilityLabel(tab.title)
                }
            }
            .onMoveCommand { direction in
                let offset: Int
                switch direction {
                case .left: offset = -1
                case .right: offset = 1
                default: return
                }
                let tabs = SettingsTab.allCases
                let index = (selectedTab.rawValue + offset + tabs.count) % tabs.count
                focusedTab = tabs[index]
                selectedTab = tabs[index]
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            Divider()
            Group {
                switch selectedTab {
                case .general: generalSettings
                case .screenshot: screenshotSettings
                case .clipboard: clipboardSettings
                case .finder: FinderSettingsView(model: model.finderModel)
                case .mouse: MouseSettingsView(settings: model.settings, service: model.mouseScroll, permissions: model.permissions)
                case .permissions: permissionSettings
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 600, height: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.settings.screenshotEnabled) { cancelRecording(); shortcutError = nil }
        .onChange(of: model.settings.clipboardEnabled) { cancelRecording(); shortcutError = nil }
        .onChange(of: focusedTab) { previous, current in
            guard let current else { return }
            if previous == nil {
                // 初次进入标签栏时，焦点跟随当前页面，保留指定标签打开的行为。
                focusedTab = selectedTab
            } else {
                selectedTab = current
            }
        }
        .onChange(of: selectedTab) {
            if focusedTab != nil { focusedTab = selectedTab }
            cancelRecording()
            shortcutError = nil
            refreshPermissions()
        }
        .onDisappear { cancelRecording() }
        .onAppear { refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
        .alert(L.t("EasyMacOS", "EasyMacOS"), isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } })
        ) {
            Button(L.t("OK", "好")) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var generalSettings: some View {
        @Bindable var settings = model.settings
        return Form {
            Section {
                Picker(L.t("Interface language", "界面语言"), selection: Binding(
                    get: { L.language },
                    set: { InterfaceLocalization.shared.setLanguage($0) }
                )) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.name).tag(language)
                    }
                }
                Toggle(L.t("Launch at login", "开机启动"), isOn: Binding(
                    get: { model.permissions.loginStatus == .enabled },
                    set: { enabled in
                        do { try model.permissions.setLoginEnabled(enabled) }
                        catch { self.error = L.t("Could not update login item.", "无法修改开机启动项。") }
                    }))
                if model.permissions.loginStatus == .requiresApproval {
                    Button(L.t("Approve in Login Items…", "在登录项中允许…")) {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
                Toggle(L.t("Show in Dock", "在程序坞中显示"), isOn: $settings.showInDock)
                    .accessibilityIdentifier("settings.showInDock")
            }
            Section {
                LabeledContent(L.t("Version", "版本")) {
                    Text(AppVersion.current.display)
                    Button(L.t("Check for Updates…", "检查更新…")) { model.updates.checkForUpdates() }
                        .disabled(!model.updates.canCheckForUpdates)
                        .accessibilityIdentifier("update.check")
                }
            }
        }.formStyle(.grouped)
    }

    private var screenshotSettings: some View {
        @Bindable var settings = model.settings
        return Form {
            Section {
                Toggle(L.t("Enable screenshots", "启用截图"), isOn: $settings.screenshotEnabled)
            }
            Section {
                shortcutRow(for: .screenshot)
                shortcutFeedback(for: .screenshot)
            } header: {
                Text(L.t("Capture", "截图"))
            }
            .disabled(!settings.screenshotEnabled)
        }.formStyle(.grouped)
    }

    private var clipboardSettings: some View {
        @Bindable var settings = model.settings
        return Form {
            Section {
                Toggle(L.t("Enable clipboard", "启用剪贴板"), isOn: $settings.clipboardEnabled)
            }
            Section {
                shortcutRow(for: .history)
                shortcutFeedback(for: .history)
            } header: {
                Text(L.t("History panel", "历史面板"))
            }
            .disabled(!settings.clipboardEnabled)
            Section {
                Picker(L.t("Keep history", "保留时间"), selection: $settings.retentionDays) {
                    ForEach([1, 7, 14, 30, 90, 365], id: \.self) {
                        Text("\($0) " + L.t("days", "天")).tag($0)
                    }
                }
                Picker(L.t("History limit", "条数上限"), selection: $settings.historyLimit) {
                    ForEach([100, 250, 500, 1000, 2000], id: \.self) { Text("\($0)").tag($0) }
                }
                Button(L.t("Clear history…", "清空历史…")) { model.onClear?() }
            } header: {
                Text(L.t("History", "历史记录"))
            }
            .disabled(!settings.clipboardEnabled)
            Section {
                if !settings.excludedApps.isEmpty {
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(settings.excludedApps.sorted(), id: \.self) { bundle in
                                HStack {
                                    Text(bundle).font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                    Spacer()
                                    Button {
                                        settings.excludedApps.remove(bundle)
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(L.t("Remove exclusion", "移除排除项") + " " + bundle)
                                }
                            }
                        }.padding(.vertical, 2)
                    }.frame(height: min(132, CGFloat(settings.excludedApps.count) * 26))
                }
                HStack {
                    TextField(L.t("Application bundle ID", "应用标识"), text: $newBundleID)
                        .onSubmit { addBundleID() }
                    Button(L.t("Add", "添加")) { addBundleID() }
                        .disabled(newBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                HStack {
                    Button(L.t("Choose application…", "选择应用…")) { chooseApplication() }
                    Spacer()
                    Button(L.t("Restore defaults", "恢复默认")) {
                        settings.excludedApps = PrivacyPolicy.defaultExcludedApps
                    }
                }
            } header: {
                Text(L.t("Excluded applications", "不记录这些应用"))
            }
            .disabled(!settings.clipboardEnabled)
        }.formStyle(.grouped)
    }

    private func shortcutRow(for action: HotKeyAction) -> some View {
        let shortcut = action == .history ? model.settings.shortcut : model.settings.screenshotShortcut
        return HStack {
            Text(L.t("Shortcut", "快捷键"))
            Spacer()
            Button(recording == action ? L.t("Press shortcut…", "按下快捷键…") : shortcut.label) {
                cancelRecording()
                recording = action
                shortcutError = nil
                model.hotKeys.record { shortcut in
                    recording = nil
                    if let shortcut, !model.applyShortcut(shortcut, for: action) {
                        shortcutError = model.message
                    }
                }
            }
            .font(.system(.body, design: .monospaced))
            .frame(minWidth: 88)
            Button(L.t("Restore default", "恢复默认")) {
                cancelRecording()
                shortcutError = nil
                if !model.applyShortcut(action == .history ? .default : .screenshot, for: action) {
                    shortcutError = model.message
                }
            }
        }
    }

    @ViewBuilder private func shortcutFeedback(for action: HotKeyAction) -> some View {
        if let issue = shortcutError ?? model.shortcutIssues[action] {
            Text(issue).font(.caption).foregroundStyle(.orange)
        }
    }

    private var permissionSettings: some View {
        Form {
            Section {
                permissionRow(
                    title: L.t("Clipboard", "剪贴板"), status: clipboardLabel,
                    granted: model.permissions.allowsMonitoring
                ) {
                    if model.permissions.allowsMonitoring { model.permissions.openPrivacy("Privacy_Pasteboard") }
                    else { model.permissions.requestClipboardAccess() }
                }
                permissionRow(
                    title: L.t("Screen Recording", "屏幕录制"),
                    status: model.permissions.screenRecording ? L.t("Allowed", "已允许") : L.t("Not allowed", "未授权"),
                    granted: model.permissions.screenRecording
                ) {
                    if model.permissions.screenRecording { model.permissions.openPrivacy("Privacy_ScreenCapture") }
                    else { model.permissions.requestScreenRecording() }
                }
                permissionRow(
                    title: L.t("Accessibility", "辅助功能"),
                    status: accessibilityGranted ? L.t("Allowed", "已允许") : L.t("Not allowed", "未授权"),
                    granted: accessibilityGranted
                ) {
                    if accessibilityGranted { model.permissions.openPrivacy("Privacy_Accessibility") }
                    else { model.permissions.requestAccessibility() }
                }
                permissionRow(
                    title: L.t("Finder Extension", "访达扩展"),
                    status: model.finderModel.extensionEnabled ? L.t("Enabled", "已启用") : L.t("Not enabled", "未启用"),
                    granted: model.finderModel.extensionEnabled
                ) { model.finderModel.manageExtension() }
            }
            HStack {
                Button(L.t("Show application", "定位当前应用")) { model.permissions.revealRunningApplication() }
                Spacer()
                Button(L.t("Refresh status", "刷新状态")) { refreshPermissions() }
            }
        }.formStyle(.grouped)
    }

    private func permissionRow(title: String, status: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            PermissionStatusRow(title: title, status: status, granted: granted)
            Button(granted ? L.t("Manage…", "管理…") : L.t("Enable…", "开启…"), action: action)
        }
    }

    private var accessibilityGranted: Bool {
        model.permissions.accessibility && model.finderModel.automaticRenameEnabled
    }

    private var clipboardLabel: String {
        switch model.permissions.clipboard {
        case .allowed: L.t("Allowed", "已允许")
        case .needsApproval: L.t("Approval needed", "待授权")
        case .denied: L.t("Denied", "已拒绝")
        }
    }

    private func refreshPermissions() {
        model.permissions.refresh()
        model.finderModel.refreshExtensionStatus()
        model.mouseScroll.refresh()
    }

    private func cancelRecording() {
        model.hotKeys.cancelRecording()
        recording = nil
    }

    private func addBundleID() {
        let bundle = newBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundle.isEmpty, bundle.contains("."), !bundle.contains(where: \.isWhitespace) else {
            error = L.t("Enter a valid application bundle ID.", "请输入有效的应用标识。")
            return
        }
        model.settings.excludedApps.insert(bundle)
        newBundleID = ""
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url)?.bundleIdentifier else { return }
        model.settings.excludedApps.insert(bundle)
    }
}

struct PermissionStatusRow: View {
    let title: String
    let status: String
    let granted: Bool

    var body: some View {
        LabeledContent(title) {
            Label(status, systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(granted ? Color.green : Color.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    (granted ? Color.green : Color.orange).opacity(0.13),
                    in: Capsule())
        }
    }
}

struct WelcomeView: View {
    let permissions: PermissionService
    let onFinish: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "doc.on.clipboard").font(.system(size: 44, weight: .light)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 8) {
                Text(L.t("Meet EasyMacOS", "欢迎使用 EasyMacOS")).font(.system(size: 27, weight: .semibold))
                Text(L.t("A little space for your copies.", "留住每一次复制。")).foregroundStyle(.secondary)
            }
            Label(L.t("Find copied text and images with ⌘⇧V", "用 ⌘⇧V 找回复制过的文本和图片"), systemImage: "magnifyingglass")
            Label(L.t("Keep favorites. Everything stays on this Mac.", "收藏常用内容，数据仅存本机"), systemImage: "star")
            Text(
                L.t(
                    "Ordinary history is kept for 30 days, up to 500 items. Sensitive markers and common password managers are excluded. Filtering cannot detect every secret; pause recording when needed.",
                    "普通历史默认保留 30 天，最多 500 条。自动排除敏感标记和常见密码管理器，但无法识别所有敏感内容，请按需暂停记录。")
            )
            .font(.callout).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button(L.t("Clipboard access…", "剪贴板权限…")) { permissions.requestClipboardAccess() }
                Button(L.t("Automatic paste…", "自动粘贴权限…")) { permissions.requestAccessibility() }
            }
            Text(
                L.t(
                    "Permissions can also be configured later in Settings. Automatic paste needs Accessibility access.",
                    "也可稍后在设置中授权。自动粘贴需要辅助功能权限。")
            )
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L.t("Get started", "开始使用"), action: onFinish).buttonStyle(.borderedProminent).controlSize(.large)
            }
        }.padding(32).frame(width: 470)
    }
}
