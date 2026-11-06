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

    init(store: FinderConfigurationStore = FinderConfigurationStore()) {
        self.store = store
        do { configuration = try store.load() } catch { message = L.t("Could not read menu settings. Save them again.", "菜单配置无法读取，请重新设置后保存。") }
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
        save(updated)
    }

    func restoreDefaults() {
        var updated = configuration
        do { try updated.restoreDefaults(); save(updated) }
        catch { message = (error as? FinderMenuError)?.description(in: L.language) ?? error.localizedDescription }
    }

    @discardableResult private func save(_ updated: FinderConfiguration) -> Bool {
        do {
            try store.save(updated)
            configuration = updated
            message = nil
            return true
        } catch { message = L.t("Could not save menu settings: \(error.localizedDescription)", "无法保存菜单配置：\(error.localizedDescription)"); return false }
    }

    func manageExtension() { FIFinderSyncController.showExtensionManagementInterface() }
}
