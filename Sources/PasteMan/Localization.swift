import Foundation
import PasteManCore
import SwiftUI

// Explicit type alias selects the macOS 15 property wrapper on SDKs that also expose a State macro.
typealias ViewState<Value> = SwiftUI.State<Value>

enum L {
    static var chinese: Bool { Locale.preferredLanguages.first?.hasPrefix("zh") == true }
    static func t(_ en: String, _ zh: String) -> String { chinese ? zh : en }
    static var unknownApp: String { t("Unknown application", "未知应用") }
    static func error(_ error: Error) -> String {
        guard let error = error as? StoreError else {
            return t("Operation failed. Check available disk space and try again.", "操作失败，请检查磁盘空间后重试。")
        }
        switch error {
        case .storageFull:
            return t("Storage is full. Remove some favorites to resume recording.", "存储空间已满，请删除部分收藏以恢复记录。")
        case .missingContent: return t("This item is missing or damaged. You can delete it.", "这条记录的内容已丢失或损坏，可以将其删除。")
        case .invalidImage: return t("Image skipped: this format could not be decoded.", "已跳过图片：无法解码此格式。")
        case .imageTooLarge:
            return t("Image skipped: maximum 20 MiB / 40 million pixels.", "已跳过图片：上限为 20 MiB / 4000 万像素。")
        case .unsupportedVersion:
            return t("This history requires a newer version of EasyMacOS.", "此历史数据库需要更新版本的 EasyMacOS。")
        case .database:
            return t(
                "History database unavailable. Your existing data has been preserved. Please restart EasyMacOS.",
                "历史数据库不可用，现有数据已保留，请重启 EasyMacOS。")
        }
    }
    static func filter(_ filter: HistoryFilter) -> String {
        switch filter {
        case .all: t("All", "全部")
        case .text: t("Text", "文本")
        case .image: t("Images", "图片")
        case .favorites: t("Favorites", "收藏")
        }
    }
}
