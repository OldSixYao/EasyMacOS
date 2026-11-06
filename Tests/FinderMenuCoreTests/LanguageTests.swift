import Foundation
import Testing
@testable import FinderMenuCore

@Suite("访达语言配置") struct LanguageTests {
    @Test func oldConfigurationMigratesAndLanguageSurvivesRestore() throws {
        let data = Data(#"{"disabledActions":["copyPath"],"enabled":true}"#.utf8)
        var configuration = try JSONDecoder().decode(FinderConfiguration.self, from: data)
        #expect(configuration.language == nil)
        #expect(!configuration.contains(.copyPath))
        configuration.language = .english
        try configuration.restoreDefaults()
        #expect(configuration.language == .english)
        let reloaded = try JSONDecoder().decode(FinderConfiguration.self, from: JSONEncoder().encode(configuration))
        #expect(reloaded.language == .english)
        #expect(reloaded.contains(.copyPath))
        #expect(FinderAction.menuOrder.map { $0.title(in: .english) }
            == ["New File", "Cut", "Paste (Move)", "Copy Full Path", "Copy File Name", "Open Terminal Here"])
    }
}
