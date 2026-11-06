import Foundation

public enum AppLanguage: String, Codable, CaseIterable, Sendable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }

    public static func resolve(_ stored: String?, preferredLanguages: [String] = Locale.preferredLanguages) -> Self {
        if let stored, let language = Self(rawValue: stored) { return language }
        return preferredLanguages.first?.hasPrefix("zh") == true ? .simplifiedChinese : .english
    }

    public func text(_ english: String, _ chinese: String) -> String {
        self == .simplifiedChinese ? chinese : english
    }
}
