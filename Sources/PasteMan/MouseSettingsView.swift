import AppKit
import SwiftUI

struct MouseSettingsView: View {
    @Bindable var settings: AppSettings
    let service: MouseScrollService
    let permissions: PermissionService
    @ViewState private var newBundleID = ""
    @ViewState private var error: String?

    var body: some View {
        Form {
            Section {
                Toggle(L.t("Enable mouse enhancement", "启用鼠标增强"), isOn: $settings.mouse.enabled)
                HStack {
                    Label(statusLabel, systemImage: service.status == .running ? "checkmark.circle.fill" : "info.circle")
                        .foregroundStyle(service.status == .running ? Color.green : .secondary)
                    Spacer()
                    if service.status == .permissionRequired {
                        Button(L.t("Enable Accessibility…", "开启辅助功能…")) {
                            permissions.requestAccessibility()
                            service.refresh()
                        }
                    } else if service.status == .failed {
                        Button(L.t("Retry", "重试")) { service.refresh() }
                    }
                }.font(.callout)
            } footer: {
                Text(L.t(
                    "Enhances mouse wheels. Trackpad gestures and momentum keep their system behavior.",
                    "增强鼠标滚轮，触控板手势与惯性沿用系统行为。"))
            }
            Section {
                Toggle(L.t("Smooth scrolling", "平滑滚动"), isOn: $settings.mouse.smooth)
                Toggle(L.t("Reverse mouse scrolling", "反向鼠标滚动"), isOn: $settings.mouse.reversed)
                    .help(L.t("Reverses the current system direction for the mouse only.", "仅将鼠标滚动方向相对于系统当前方向翻转。"))
                Toggle(L.t("Remote wheel compatibility", "远程滚轮兼容"), isOn: $settings.mouse.remoteCompatibility)
                    .help(L.t(
                        "Enable if a remote desktop sends mouse wheels as continuous scrolling. Trackpad gestures and momentum remain unchanged.",
                        "远程桌面将鼠标滚轮转换为连续滚动、导致增强无效时开启。触控板手势和惯性保持原样。"))
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent(L.t("Scroll speed", "滚动速度"), value: String(format: "%.1f×", settings.mouse.speed))
                    Slider(value: $settings.mouse.speed, in: 0.5...3, step: 0.1)
                        .accessibilityLabel(L.t("Scroll speed", "滚动速度"))
                }
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent(L.t("Smoothing duration", "平滑时长"), value: "\(Int((settings.mouse.duration * 1000).rounded())) " + L.t("ms", "毫秒"))
                    Slider(value: $settings.mouse.duration, in: 0.08...0.4, step: 0.01)
                        .accessibilityLabel(L.t("Smoothing duration", "平滑时长"))
                }.disabled(!settings.mouse.smooth)
            } footer: {
                if settings.mouse.remoteCompatibility {
                    Text(L.t(
                        "Also enhances continuous wheel events without a gesture or momentum phase. Turn off when using other scrolling enhancers.",
                        "兼容远程桌面传入的无手势连续滚轮；使用其他滚动增强工具时请关闭。"))
                }
            }
            Section {
                if !settings.mouse.excludedApps.isEmpty {
                    ForEach(settings.mouse.excludedApps.sorted(), id: \.self) { bundle in
                        HStack {
                            Text(bundle).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            Button {
                                settings.mouse.excludedApps.remove(bundle)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L.t("Remove exclusion", "移除排除项") + " " + bundle)
                        }
                    }
                }
                HStack {
                    TextField(L.t("Application bundle ID", "应用标识"), text: $newBundleID)
                        .onSubmit { addBundleID() }
                    Button(L.t("Add", "添加")) { addBundleID() }
                        .disabled(newBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Button(L.t("Choose application…", "选择应用…")) { chooseApplication() }
            } header: {
                Text(L.t("Excluded applications", "不增强这些应用"))
            } footer: {
                Text(L.t("Excluded apps use native scrolling, including direction and speed.", "排除的应用使用原生滚动，包括原有方向与速度。"))
            }
            Button(L.t("Restore mouse defaults", "恢复鼠标默认设置")) { settings.mouse = .init() }
        }
        .formStyle(.grouped)
        .alert(L.t("Invalid application", "应用标识无效"), isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } })
        ) {
            Button(L.t("OK", "好")) { error = nil }
        } message: { Text(error ?? "") }
    }

    private var statusLabel: String {
        switch service.status {
        case .disabled: L.t("Disabled", "已关闭")
        case .starting: L.t("Starting…", "正在启动…")
        case .running: L.t("Running", "运行中")
        case .permissionRequired: L.t("Accessibility permission required", "需要辅助功能授权")
        case .failed: L.t("Could not start mouse enhancement", "鼠标增强启动失败")
        case .paused: L.t("Paused while session is inactive", "会话未激活，已暂停")
        }
    }

    private func addBundleID() {
        let bundle = newBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard bundle.contains("."), !bundle.contains(where: \.isWhitespace) else {
            error = L.t("Enter a valid application bundle ID.", "请输入有效的应用标识。")
            return
        }
        settings.mouse.excludedApps.insert(bundle)
        newBundleID = ""
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
            let bundle = Bundle(url: url)?.bundleIdentifier else { return }
        settings.mouse.excludedApps.insert(bundle)
    }
}
