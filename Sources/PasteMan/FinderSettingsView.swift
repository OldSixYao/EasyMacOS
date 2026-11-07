import AppKit
import FinderMenuCore
import SwiftUI

struct FinderSettingsView: View {
    @Bindable var model: FinderModel
    @ViewState private var newSuffix = ""
    @ViewState private var isAddingFileType = false
    @FocusState private var isSuffixFocused: Bool

    private let fileTypeRowHeight: CGFloat = 44

    init(model: FinderModel) { self.model = model }

    private func saveFileType() {
        if model.addFileType(newSuffix) { cancelAddingFileType() }
        else { isSuffixFocused = true }
    }

    private func cancelAddingFileType() {
        isSuffixFocused = false
        isAddingFileType = false
        newSuffix = ""
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
                if !model.configuration.fileTypes.isEmpty {
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            ForEach(model.configuration.fileTypes) { type in
                                HStack {
                                    Image(nsImage: FinderFileTypeIcon.image(for: type, store: model.iconStore, size: 24))
                                        .accessibilityHidden(true)
                                    Text(type.suffix)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Button(L.t("Choose Image", "选择图片")) { model.chooseIcon(id: type.id) }
                                        .accessibilityLabel(L.t("Choose icon for ", "选择图标 ") + type.suffix)
                                    Button(L.t("Default Icon", "恢复默认图标")) { model.restoreIcon(id: type.id) }
                                        .disabled(type.iconResource == nil)
                                        .accessibilityLabel(L.t("Restore default icon for ", "恢复默认图标 ") + type.suffix)
                                    Button(L.t("Remove", "删除")) { model.removeFileType(id: type.id) }
                                        .accessibilityLabel(L.t("Remove ", "删除 ") + type.suffix)
                                }
                                .padding(.trailing, 12)
                                .frame(height: fileTypeRowHeight)
                                .overlay(alignment: .bottom) { Divider() }
                            }
                        }
                    }
                    .scrollIndicators(.visible)
                    .frame(height: fileTypeRowHeight * CGFloat(min(model.configuration.fileTypes.count, 5)))
                }
                if isAddingFileType {
                    HStack {
                        TextField(L.t("File type", "文件类型"), text: $newSuffix)
                            .focused($isSuffixFocused)
                            .task {
                                await Task.yield()
                                guard !Task.isCancelled else { return }
                                isSuffixFocused = true
                            }
                            .onSubmit { saveFileType() }
                        Button(L.t("Save", "保存")) { saveFileType() }
                            .disabled(newSuffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button(L.t("Cancel", "取消")) { cancelAddingFileType() }
                    }
                } else {
                    Button(L.t("Add", "添加")) { isAddingFileType = true }
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
        .onChange(of: model.configuration.enabled) {
            if !model.configuration.enabled { cancelAddingFileType() }
        }
    }
}
