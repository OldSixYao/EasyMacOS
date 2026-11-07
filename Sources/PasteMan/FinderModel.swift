import AppKit
import FinderMenuCore
import FinderSync
import Observation

@MainActor @Observable final class FinderModel {
    private(set) var configuration = FinderConfiguration()
    private(set) var extensionEnabled = false
    private(set) var automaticRenameEnabled = FinderRenameAccess.isGranted
    var message: String?
    private let store: FinderConfigurationStore
    private let importIconResource: @Sendable (URL, FinderFileTypeIconStore) async throws -> String
    @ObservationIgnored private var iconImports: [Int: UUID] = [:]

    init(store: FinderConfigurationStore = FinderConfigurationStore(),
         importIconResource: @escaping @Sendable (URL, FinderFileTypeIconStore) async throws -> String = { url, store in
             try await FinderIconImportWorker.shared.importImage(at: url, store: store)
         }) {
        self.store = store
        self.importIconResource = importIconResource
        do {
            configuration = try store.load()
            var updated = configuration
            if try updated.migrateOfficeTypes() { save(updated) }
        } catch { message = L.t("Could not read or upgrade menu settings. Save them again.", "菜单配置无法读取或升级，请重新设置后保存。") }
        refreshExtensionStatus()
    }

    func refreshExtensionStatus() {
        extensionEnabled = FIFinderSyncController.isExtensionEnabled
        automaticRenameEnabled = FinderRenameAccess.isGranted
    }

    func enableAutomaticRename() {
        FinderRenameAccess.request()
        refreshExtensionStatus()
    }

    func setLanguage(_ language: AppLanguage) {
        guard configuration.language != language else { return }
        var updated = configuration
        updated.language = language
        save(updated)
    }

    func setEnabled(_ enabled: Bool) {
        var updated = configuration
        updated.enabled = enabled
        save(updated)
    }

    func set(_ action: FinderAction, enabled: Bool) {
        var updated = configuration
        updated.set(action, enabled: enabled)
        save(updated)
    }

    @discardableResult func addFileType(_ input: String) -> Bool {
        var updated = configuration
        do { try updated.addFileType(input) }
        catch { message = (error as? FinderMenuError)?.description(in: L.language) ?? error.localizedDescription; return false }
        return save(updated)
    }

    func removeFileType(id: Int) {
        var updated = configuration
        updated.removeFileType(id: id)
        if save(updated) { iconImports[id] = nil }
    }

    func restoreDefaults() {
        var updated = configuration
        do { try updated.restoreDefaults(); if save(updated) { iconImports.removeAll() } }
        catch { message = (error as? FinderMenuError)?.description(in: L.language) ?? error.localizedDescription }
    }

    var iconStore: FinderFileTypeIconStore { FinderFileTypeIconStore(configurationStore: store) }

    func chooseIcon(id: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = L.t("Choose Image", "选择图片")
        panel.begin { [weak self] response in
            let url = response == .OK ? panel.url : nil
            Task { [weak self] in await self?.applyIconSelection(url, id: id) }
        }
    }

    func applyIconSelection(_ url: URL?, id: Int) async {
        guard let url else { return }
        await importIcon(at: url, id: id)
    }

    @discardableResult func importIcon(at url: URL, id: Int) async -> Bool {
        guard configuration.fileTypes.contains(where: { $0.id == id }) else { return false }
        let ticket = UUID()
        iconImports[id] = ticket
        defer { if iconImports[id] == ticket { iconImports[id] = nil } }
        let icons = iconStore
        do {
            let resource = try await importIconResource(url, icons)
            guard !Task.isCancelled, iconImports[id] == ticket,
                configuration.fileTypes.contains(where: { $0.id == id }) else {
                icons.remove(resource: resource)
                return false
            }
            var updated = configuration
            do { try updated.setIconResource(resource, for: id) }
            catch { iconStore.remove(resource: resource); throw error }
            guard save(updated) else { iconStore.remove(resource: resource); return false }
            return true
        } catch is CancellationError { return false } catch {
            guard iconImports[id] == ticket else { return false }
            message = L.t("Could not import the icon: ", "无法导入图标：")
                + ((error as? FinderMenuError)?.description(in: L.language) ?? error.localizedDescription)
            return false
        }
    }

    func restoreIcon(id: Int) {
        var updated = configuration
        do { try updated.setIconResource(nil, for: id); if save(updated) { iconImports[id] = nil } }
        catch { message = (error as? FinderMenuError)?.description(in: L.language) ?? error.localizedDescription }
    }

    @discardableResult private func save(_ updated: FinderConfiguration) -> Bool {
        do {
            try store.save(updated)
            let unused = Set(configuration.fileTypes.compactMap(\.iconResource))
                .subtracting(updated.fileTypes.compactMap(\.iconResource))
            configuration = updated
            for resource in unused { iconStore.remove(resource: resource) }
            message = nil
            return true
        } catch { message = L.t("Could not save menu settings: \(error.localizedDescription)", "无法保存菜单配置：\(error.localizedDescription)"); return false }
    }

    func manageExtension() { FIFinderSyncController.showExtensionManagementInterface() }
}
