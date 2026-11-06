import AppKit
import Carbon
import Observation
import PasteManCore

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var keyLabel: String
    static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey), keyLabel: "V")
    static let screenshot = Shortcut(
        keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey | optionKey), keyLabel: "A")
    func matches(_ other: Shortcut) -> Bool { keyCode == other.keyCode && modifiers == other.modifiers }
    var label: String {
        [(UInt32(controlKey), "⌃"), (UInt32(optionKey), "⌥"), (UInt32(shiftKey), "⇧"), (UInt32(cmdKey), "⌘")]
            .filter { modifiers & $0.0 != 0 }.map(\.1).joined() + keyLabel
    }
}

@MainActor @Observable final class AppSettings {
    private let defaults: UserDefaults
    var retentionDays: Int { didSet { defaults.set(retentionDays, forKey: "retentionDays") } }
    var historyLimit: Int { didSet { defaults.set(historyLimit, forKey: "historyLimit") } }
    var excludedApps: Set<String> { didSet { defaults.set(excludedApps.sorted(), forKey: "excludedApps") } }
    @ObservationIgnored var onClipboardChanged: (() -> Void)?
    @ObservationIgnored var onScreenshotChanged: (() -> Void)?
    var clipboardEnabled: Bool {
        didSet {
            defaults.set(clipboardEnabled, forKey: "clipboardEnabled")
            if oldValue != clipboardEnabled { onClipboardChanged?() }
        }
    }
    var screenshotEnabled: Bool {
        didSet {
            defaults.set(screenshotEnabled, forKey: "screenshotEnabled")
            if oldValue != screenshotEnabled { onScreenshotChanged?() }
        }
    }
    @ObservationIgnored var onMouseChanged: (() -> Void)?
    var mouse: MouseScrollConfiguration {
        didSet {
            if let data = try? JSONEncoder().encode(mouse.normalized) {
                defaults.set(data, forKey: "mouseScrollConfiguration")
            }
            if oldValue != mouse { onMouseChanged?() }
        }
    }
    var shortcut: Shortcut {
        didSet { if let data = try? JSONEncoder().encode(shortcut) { defaults.set(data, forKey: "shortcut") } }
    }
    var screenshotShortcut: Shortcut {
        didSet {
            if let data = try? JSONEncoder().encode(screenshotShortcut) {
                defaults.set(data, forKey: "screenshotShortcut")
            }
        }
    }
    @ObservationIgnored var onRecordingChanged: (() -> Void)?
    var paused: Bool {
        didSet {
            defaults.set(paused, forKey: "paused")
            if oldValue != paused { onRecordingChanged?() }
        }
    }
    var hasOnboarded: Bool {
        didSet {
            defaults.set(hasOnboarded, forKey: "hasOnboarded")
            if oldValue != hasOnboarded { onRecordingChanged?() }
        }
    }
    var policy: RetentionPolicy { RetentionPolicy(days: retentionDays, count: historyLimit) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        retentionDays = max(1, defaults.object(forKey: "retentionDays") as? Int ?? 30)
        historyLimit = max(1, defaults.object(forKey: "historyLimit") as? Int ?? 500)
        excludedApps = defaults.stringArray(forKey: "excludedApps").map(Set.init) ?? PrivacyPolicy.defaultExcludedApps
        clipboardEnabled = defaults.object(forKey: "clipboardEnabled") as? Bool ?? true
        screenshotEnabled = defaults.object(forKey: "screenshotEnabled") as? Bool ?? true
        mouse = defaults.data(forKey: "mouseScrollConfiguration")
            .flatMap { try? JSONDecoder().decode(MouseScrollConfiguration.self, from: $0) }?.normalized ?? .init()
        shortcut =
            defaults.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .default
        screenshotShortcut =
            defaults.data(forKey: "screenshotShortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
            ?? .screenshot
        paused = defaults.bool(forKey: "paused")
        hasOnboarded = defaults.bool(forKey: "hasOnboarded")
    }
}
