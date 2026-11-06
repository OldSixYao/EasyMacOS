import Foundation
import FinderMenuCore
import Observation
import Testing
import os

@testable import PasteMan

@Suite("界面语言", .serialized) @MainActor struct LocalizationTests {
    @Test func choicePersistsAcrossRelaunchAndOverridesSystemLanguage() throws {
        let suite = "InterfaceLanguage." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = InterfaceLocalization(defaults: defaults, preferredLanguages: ["zh-Hans-CN"])
        #expect(preferences.language == .simplifiedChinese)
        preferences.setLanguage(.english)
        #expect(preferences.language.text("General", "通用") == "General")
        #expect(InterfaceLocalization(defaults: defaults, preferredLanguages: ["zh-Hans"]).language == .english)
        preferences.setLanguage(.simplifiedChinese)
        #expect(InterfaceLocalization(defaults: defaults, preferredLanguages: ["en-US"]).language == .simplifiedChinese)
    }

    @Test func changingLanguageInvalidatesObservedTranslations() throws {
        let suite = "InterfaceLanguage." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = InterfaceLocalization(defaults: defaults, preferredLanguages: ["zh-Hans"])
        let changes = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            #expect(preferences.language.text("General", "通用") == "通用")
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        preferences.setLanguage(.english)
        #expect(changes.withLock { $0 } == 1)
        #expect(preferences.language.text("General", "通用") == "General")
    }

    @Test func missingOrInvalidPreferenceUsesSystemAndExplicitSameChoicePersists() throws {
        #expect(AppLanguage.resolve(nil, preferredLanguages: ["zh-TW"]) == .simplifiedChinese)
        #expect(AppLanguage.resolve("invalid", preferredLanguages: ["en-US"]) == .english)
        #expect(AppLanguage.resolve(nil, preferredLanguages: ["fr-FR"]) == .english)
        let suite = "InterfaceLanguage." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = InterfaceLocalization(defaults: defaults, preferredLanguages: ["en-US"])
        preferences.setLanguage(.english)
        #expect(defaults.string(forKey: InterfaceLocalization.defaultsKey) == "en")
        #expect(InterfaceLocalization(defaults: defaults, preferredLanguages: ["zh-Hans"]).language == .english)
    }
}
