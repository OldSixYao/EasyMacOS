import Foundation

/// Always read the installed bundle, including versions supplied by release packaging.
struct AppVersion: Equatable {
    let version: String?
    let build: String?

    static var current: Self { Self(info: Bundle.main.infoDictionary ?? [:]) }

    init(info: [String: Any]) {
        func value(_ key: String) -> String? {
            guard let text = info[key] as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        version = value("CFBundleShortVersionString")
        build = value("CFBundleVersion")
    }

    var display: String {
        guard let version else { return L.t("Development build", "开发构建") }
        guard let build else { return version }
        return version + L.t(" (Build \(build))", "（构建 \(build)）")
    }

    var applicationLabel: String { "EasyMacOS " + display }
}
