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
                Toggle(L.t("Enable context menu", "启用右键菜单"), isOn: Binding(get: { model.configuration.enabled }, set: model.setEnabled))
            }
            Section {
                ForEach(FinderAction.menuOrder) { action in
                    Toggle(
                        action.title(in: L.language),
                        isOn: Binding(
                            get: { !model.configuration.disabledActions.contains(action.rawValue) },
                            set: { model.set(action, enabled: $0) })
                    )
                    .disabled(!model.configuration.enabled)
                }
            } header: {
                Text(L.t("Actions", "常用操作"))
            }
            Section {
                ForEach(model.configuration.fileTypes) { type in
                    HStack {
                        Image(nsImage: FinderFileTypeIcon.image(for: type, store: model.iconStore, size: 24))
                            .accessibilityHidden(true)
                        Text("." + type.suffix)
                        Spacer()
                        Button(L.t("Choose Image", "选择图片")) { model.chooseIcon(id: type.id) }
                            .accessibilityLabel(L.t("Choose icon for .", "选择图标 .") + type.suffix)
                        Button(L.t("Default Icon", "恢复默认图标")) { model.restoreIcon(id: type.id) }
                            .disabled(type.iconResource == nil)
                            .accessibilityLabel(L.t("Restore default icon for .", "恢复默认图标 .") + type.suffix)
                        Button(L.t("Remove", "删除")) { model.removeFileType(id: type.id) }
                            .accessibilityLabel(L.t("Remove .", "删除 .") + type.suffix)
                    }
                }
                HStack {
                    TextField(L.t("File suffix", "文件后缀"), text: $newSuffix)
                        .onSubmit { addFileType() }
                    Button(L.t("Add", "添加")) { addFileType() }
                        .disabled(newSuffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if model.configuration.fileTypes.isEmpty {
                    Text(L.t("No file types", "暂无文件类型"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(L.t("Restore defaults", "恢复默认设置")) { model.restoreDefaults() }
            } header: {
                Text(L.t("New file types", "新建文件类型"))
            }
            .disabled(!model.configuration.enabled)
            if let message = model.message {
                Section { Text(message).font(.callout).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
    }
}
