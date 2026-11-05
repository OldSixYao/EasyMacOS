import AppKit
import FinderMenuCore
import SwiftUI

struct FinderSettingsView: View {
    @Bindable var model: FinderModel
    @ViewState private var newSuffix = ""

    init(model: FinderModel) { self.model = model }

    private func addFileType() {
        if model.addFileType(newSuffix) { newSuffix = "" }
    }

    var body: some View {
        Form {
            Section {
                PermissionStatusRow(
                    title: "访达右键菜单", status: model.extensionEnabled ? "已启用" : "尚未启用",
                    granted: model.extensionEnabled)
                Text("在系统设置中启用「EasyMacOS 访达菜单」，随后右键文件、文件夹或空白处即可使用。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("管理访达扩展…") { model.manageExtension() }
            }
            Section {
                PermissionStatusRow(
                    title: "新建后直接重命名", status: model.automaticRenameEnabled ? "已启用" : "需要辅助功能权限",
                    granted: model.automaticRenameEnabled)
                Text("新建后立即在访达中编辑文件名，保留文件后缀；「粘贴（移动）」也使用同一辅助功能权限。请为当前运行的 EasyMacOS 授权。")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.automaticRenameEnabled {
                    Button("开启自动重命名…") { model.enableAutomaticRename() }
                }
            }
            Section {
                Toggle("显示右键菜单", isOn: Binding(get: { model.configuration.enabled }, set: model.setEnabled))
                ForEach(FinderAction.menuOrder) { action in
                    Toggle(
                        action.title,
                        isOn: Binding(
                            get: { !model.configuration.disabledActions.contains(action.rawValue) },
                            set: { model.set(action, enabled: $0) })
                    )
                    .disabled(!model.configuration.enabled)
                }
            } header: {
                Text("常用操作")
            } footer: {
                Text("剪切后，在目标目录选择「粘贴（移动）」或按 ⌥⌘V；普通粘贴仍是复制。移动需要辅助功能权限，冲突与撤销由访达处理。修改后，下次右键生效。")
            }
            Section {
                ForEach(model.configuration.fileTypes) { type in
                    HStack {
                        Text("." + type.suffix)
                        Spacer()
                        Button("删除") { model.removeFileType(id: type.id) }
                            .accessibilityLabel("删除 ." + type.suffix)
                    }
                }
                HStack {
                    TextField("后缀，例如 txt 或 tar.gz", text: $newSuffix)
                        .onSubmit { addFileType() }
                    Button("添加") { addFileType() }
                }
                if model.configuration.fileTypes.isEmpty {
                    Text("请添加至少一种文件类型；当前右键菜单隐藏「新建文件」。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("恢复默认设置") { model.restoreDefaults() }
            } header: {
                Text("新建文件类型")
            } footer: {
                Text("按上方顺序显示，支持复合后缀。选择类型后立即创建空文件，重名自动编号。已有辅助功能权限时会尝试进入访达原地重命名；可在「权限」中授权，未授权仍可创建。")
            }
            if let message = model.message {
                Section { Text(message).font(.callout).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.refreshExtensionStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshExtensionStatus()
        }
    }
}
