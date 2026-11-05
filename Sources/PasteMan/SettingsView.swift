import AppKit
import PasteManCore
import ServiceManagement
import SwiftUI

enum SettingsTab: Int, CaseIterable {
    case general, finder, privacy, permissions

    var title: String {
        switch self {
        case .general: L.t("General", "通用")
        case .finder: L.t("Finder", "访达")
        case .privacy: L.t("Privacy", "隐私")
        case .permissions: L.t("Permissions", "权限")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .finder: "cursorarrow.click.2"
        case .privacy: "hand.raised"
        case .permissions: "checkmark.shield"
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @ViewState private var recording = false
    @ViewState private var recordingScreenshot = false
    @ViewState private var shortcutError: String?
    @ViewState private var newBundleID = ""
    @ViewState private var error: String?
    @ViewState private var selectedTab: SettingsTab

    init(model: AppModel, initialTab: SettingsTab = .general) {
        self.model = model
        _selectedTab = ViewState(initialValue: initialTab)
    }

    var body: some View {
        @Bindable var settings = model.settings
        VStack(spacing: 0) {
            Picker(L.t("Settings section", "设置分类"), selection: $selectedTab) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Label(tab.title, systemImage: tab.symbol).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .textSelection(.disabled)
            .frame(width: 430)
            .padding(.vertical, 16)
            Divider()
            Group {
                if selectedTab == .general {
                    Form {
                        Section {
                            HStack {
                                Text(L.t("Clipboard history shortcut", "剪贴板历史快捷键"))
                                Spacer()
                                Button(
                                    recording
                                        ? L.t("Press shortcut… Esc to cancel", "按下快捷键… Esc 取消")
                                        : settings.shortcut.label
                                ) {
                                    recordingScreenshot = false
                                    recording = true
                                    shortcutError = nil
                                    model.hotKeys.record { shortcut in
                                        recording = false
                                        recordingScreenshot = false
                                        if let shortcut, !model.applyShortcut(shortcut) {
                                            shortcutError = model.message
                                        }
                                    }
                                }.font(.system(.body, design: .monospaced))
                            }
                            if let shortcutError { Text(shortcutError).font(.caption).foregroundStyle(.orange) }
                            Button(L.t("Restore history shortcut", "恢复历史默认快捷键")) {
                                if !model.applyShortcut(.default) { shortcutError = model.message }
                            }
                            HStack {
                                Text(L.t("Screenshot shortcut", "截图快捷键"))
                                Spacer()
                                Button(
                                    recordingScreenshot
                                        ? L.t("Press shortcut… Esc to cancel", "按下快捷键… Esc 取消")
                                        : settings.screenshotShortcut.label
                                ) {
                                    recording = false
                                    recordingScreenshot = true
                                    shortcutError = nil
                                    model.hotKeys.record { shortcut in
                                        recordingScreenshot = false
                                        if let shortcut, !model.applyShortcut(shortcut, for: .screenshot) {
                                            shortcutError = model.message
                                        }
                                    }
                                }.font(.system(.body, design: .monospaced))
                            }
                            Button(L.t("Restore screenshot shortcut", "恢复截图默认快捷键")) {
                                if !model.applyShortcut(.screenshot, for: .screenshot) { shortcutError = model.message }
                            }
                            Toggle(
                                L.t("Launch at login", "开机启动"),
                                isOn: Binding(
                                    get: { model.permissions.loginStatus == .enabled },
                                    set: { enabled in
                                        do { try model.permissions.setLoginEnabled(enabled) } catch {
                                            self.error = L.t(
                                                "Could not update login item. Run the signed app from Applications and check System Settings.",
                                                "无法修改开机启动项，请将已签名的应用放入「应用程序」，并检查系统设置。")
                                        }
                                    }))
                            if model.permissions.loginStatus == .requiresApproval {
                                Button(L.t("Approve in Login Items…", "在登录项中允许…")) {
                                    SMAppService.openSystemSettingsLoginItems()
                                }
                            }
                        } header: {
                            Text(L.t("General", "通用"))
                        }
                        Section {
                            Picker(L.t("Keep ordinary history", "普通历史保留时间"), selection: $settings.retentionDays) {
                                ForEach([1, 7, 14, 30, 90, 365], id: \.self) {
                                    Text("\($0) " + L.t("days", "天")).tag($0)
                                }
                            }
                            Picker(L.t("Ordinary history limit", "普通历史条数上限"), selection: $settings.historyLimit) {
                                ForEach([100, 250, 500, 1000, 2000], id: \.self) { Text("\($0)").tag($0) }
                            }
                            LabeledContent(L.t("Content storage budget", "内容存储预算"), value: "512 MiB")
                            Text(
                                L.t(
                                    "Favorites remain until you delete them. When storage is full, ordinary items are removed first. If favorites fill the budget, new copies are skipped.",
                                    "收藏会一直保留，直到手动删除。空间不足时优先清理普通记录；收藏占满预算时，暂停保存新内容。")
                            )
                            .font(.caption).foregroundStyle(.secondary)
                            Button(L.t("Clear history…", "清空历史…")) { model.onClear?() }
                        } header: {
                            Text(L.t("History", "历史记录"))
                        }
                        Section {
                            Text("EasyMacOS").font(.headline)
                            LabeledContent(L.t("Version", "版本"), value: AppVersion.current.display)
                            Text(
                                L.t(
                                    "Clipboard, screenshots and Finder tools.\nStored locally. No cloud sync or analytics.",
                                    "剪贴板、截图与访达工具，三合一。\n仅在本机保存，无云同步与使用追踪。")
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }.formStyle(.grouped)
                } else if selectedTab == .finder {
                    FinderSettingsView(model: model.finderModel)
                } else if selectedTab == .privacy {
                    Form {
                        Section {
                            Label(
                                L.t("Your clipboard stays on this Mac", "剪贴板内容仅保存在这台 Mac"), systemImage: "lock.shield")
                            Text(
                                L.t(
                                    "Marked sensitive or transient content is ignored. App exclusions use the foreground app at detection time. Copies not yet detected are discarded when switching apps to avoid assigning them to the wrong source. This cannot identify every password. Pause recording before copying unmarked secrets. Local history is not additionally encrypted.",
                                    "自动忽略带敏感或临时标记的内容。应用排除根据检测时的前台应用判断；切换应用时丢弃尚未检测的内容，避免来源误判。仍无法识别所有密码，复制未标记的敏感内容前请暂停记录。本地历史未额外加密。")
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Section {
                            ScrollView {
                                VStack(spacing: 6) {
                                    ForEach(settings.excludedApps.sorted(), id: \.self) { bundle in
                                        HStack {
                                            Text(bundle).font(.system(size: 11, design: .monospaced)).textSelection(
                                                .enabled)
                                            Spacer()
                                            Button {
                                                settings.excludedApps.remove(bundle)
                                            } label: {
                                                Image(systemName: "minus.circle")
                                            }
                                            .buttonStyle(.plain).accessibilityLabel(
                                                L.t("Remove exclusion", "移除排除项") + " " + bundle)
                                        }
                                    }
                                }
                            }.frame(height: 170)
                            HStack {
                                TextField(L.t("Application bundle ID", "应用 Bundle ID"), text: $newBundleID)
                                Button(L.t("Add", "添加")) { addBundleID() }.disabled(
                                    newBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            HStack {
                                Button(L.t("Choose application…", "选择应用…")) { chooseApplication() }
                                Button(L.t("Restore defaults", "恢复默认名单")) {
                                    settings.excludedApps = PrivacyPolicy.defaultExcludedApps
                                }
                            }
                        } header: {
                            Text(L.t("Excluded applications", "不记录这些应用"))
                        }
                    }.formStyle(.grouped)
                } else {
                    Form {
                        Section {
                            PermissionStatusRow(
                                title: L.t("Clipboard recording", "剪贴板记录"),
                                status: clipboardLabel, granted: model.permissions.allowsMonitoring)
                            Text(
                                model.permissions.allowsMonitoring
                                    ? L.t(
                                        "Clipboard access is enabled. Copied text and images are saved locally; you can pause recording from the menu bar.",
                                        "已允许访问剪贴板。复制的文本和图片会保存在本机，可随时从菜单栏暂停记录。")
                                    : L.t(
                                        "On recent macOS versions, choose Always Allow for EasyMacOS in System Settings → Privacy & Security → Paste from Other Apps. Background recording waits until access is allowed.",
                                        "在新版 macOS 的「系统设置 → 隐私与安全性 → 从其他应用粘贴」中，为 EasyMacOS 选择「始终允许」。允许访问后才会在后台记录。")
                            )
                            .font(.caption).foregroundStyle(.secondary)
                            if !model.permissions.allowsMonitoring {
                                Button(L.t("Allow clipboard access…", "允许访问剪贴板…")) {
                                    model.permissions.requestClipboardAccess()
                                }
                            }
                        }
                        Section {
                            PermissionStatusRow(
                                title: L.t("Automatic paste", "自动粘贴"),
                                status: model.permissions.accessibility
                                    ? L.t("Enabled", "已启用") : L.t("Permission needed", "需要授权"),
                                granted: model.permissions.accessibility)
                            Text(
                                model.permissions.accessibility
                                    ? L.t(
                                        "Accessibility access is enabled. Select a history item to paste into the previous application. New Finder files can also enter inline rename.",
                                        "已允许辅助功能访问。选择历史记录后可粘贴到之前使用的应用；访达新建文件后也可自动进入原地重命名。")
                                    : L.t(
                                        "Accessibility access allows automatic paste and inline rename after creating Finder files. Without it, copying and file creation remain available.",
                                        "辅助功能权限用于自动粘贴，以及访达新建后的原地重命名。未授权时，仍可复制历史内容和新建文件。")
                            )
                            .font(.caption).foregroundStyle(.secondary)
                            if !model.permissions.accessibility {
                                Button(L.t("Allow Accessibility…", "允许辅助功能…")) {
                                    model.permissions.requestAccessibility()
                                }
                                Text(
                                    L.t(
                                        "Already enabled in System Settings? First quit and reopen EasyMacOS. When migrating from an ad-hoc build or changing signing certificates, remove the old entry and add the currently running app below. Rebuilds using the same fixed certificate and app identity keep the signing identity stable.",
                                        "系统开关已开启但这里仍未授权？请先退出并重新打开。首次从临时签名迁移或更换证书时，需要移除旧条目并添加下方定位的当前应用。使用相同固定证书和应用标识重新构建时，签名身份保持稳定。"
                                    )
                                )
                                .font(.caption).foregroundStyle(.secondary)
                                Button(L.t("Show current EasyMacOS in Finder", "在 Finder 中定位当前 EasyMacOS")) {
                                    model.permissions.revealRunningApplication()
                                }
                            }
                        }
                        Section {
                            PermissionStatusRow(
                                title: L.t("Screenshots", "屏幕截图"),
                                status: model.permissions.screenRecording
                                    ? L.t("Enabled", "已启用") : L.t("Permission needed", "需要授权"),
                                granted: model.permissions.screenRecording)
                            Text(
                                L.t(
                                    "Screen Recording access is used only when you take a screenshot. Screenshots and pinned images stay on this Mac.",
                                    "仅在主动截图时捕获屏幕。截图及钉图均留在本机。")
                            )
                            .font(.caption).foregroundStyle(.secondary)
                            if !model.permissions.screenRecording {
                                Button(L.t("Allow Screen Recording…", "允许屏幕录制…")) {
                                    model.permissions.requestScreenRecording()
                                }
                                Text(
                                    L.t(
                                        "If macOS requests it, quit and reopen EasyMacOS after granting access.",
                                        "若 macOS 提示需要，请在授权后退出并重新打开 EasyMacOS。")
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button(L.t("Refresh permission status", "刷新权限状态")) { model.permissions.refresh() }
                    }.formStyle(.grouped)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 550, height: 610)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: settings.retentionDays) { model.applyRetention() }
        .onChange(of: settings.historyLimit) { model.applyRetention() }
        .onChange(of: selectedTab) {
            model.hotKeys.cancelRecording()
            recording = false
            recordingScreenshot = false
            model.permissions.refresh()
        }
        .onDisappear {
            model.hotKeys.cancelRecording()
            recording = false
            recordingScreenshot = false
        }
        .onAppear { model.permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.permissions.refresh()
        }
        .alert(
            L.t("EasyMacOS", "EasyMacOS"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
        ) {
            Button(L.t("OK", "好")) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }
    private var clipboardLabel: String {
        switch model.permissions.clipboard {
        case .allowed: L.t("Allowed", "已允许")
        case .needsApproval: L.t("Always Allow needed", "需要始终允许")
        case .denied: L.t("Denied", "已拒绝")
        }
    }
    private func addBundleID() {
        let bundle = newBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundle.isEmpty, bundle.contains("."), !bundle.contains(where: \.isWhitespace) else {
            error = L.t(
                "Enter a valid application bundle ID, such as com.apple.Safari.",
                "请输入有效的应用 Bundle ID，例如 com.apple.Safari。")
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
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url)?.bundleIdentifier else {
            return
        }
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
