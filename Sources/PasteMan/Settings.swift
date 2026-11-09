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
    private var storedRetentionDays: Int
    private var storedHistoryLimit: Int
    @ObservationIgnored var onRetentionChanged: (() -> Void)?
    var retentionDays: Int {
        get { storedRetentionDays }
        set {
            let value = max(1, newValue)
            guard storedRetentionDays != value else { return }
            storedRetentionDays = value
            defaults.set(value, forKey: "retentionDays")
            onRetentionChanged?()
        }
    }
    var historyLimit: Int {
        get { storedHistoryLimit }
        set {
            let value = max(1, newValue)
            guard storedHistoryLimit != value else { return }
            storedHistoryLimit = value
            defaults.set(value, forKey: "historyLimit")
            onRetentionChanged?()
        }
    }
    var excludedApps: Set<String> { didSet { defaults.set(excludedApps.sorted(), forKey: "excludedApps") } }
    @ObservationIgnored var onDockVisibilityChanged: (() -> Void)?
    var showInDock: Bool {
        didSet {
            guard oldValue != showInDock else { return }
            defaults.set(showInDock, forKey: "showInDock")
            onDockVisibilityChanged?()
        }
    }
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
    @ObservationIgnored var onScreenRecordingChanged: (() -> Void)?
    var screenRecordingEnabled: Bool {
        didSet {
            defaults.set(screenRecordingEnabled, forKey: "screenRecordingEnabled")
            if oldValue != screenRecordingEnabled { onScreenRecordingChanged?() }
        }
    }
    var screenRecordingOptions: ScreenRecordingOptions {
        didSet {
            if let data = try? JSONEncoder().encode(screenRecordingOptions) { defaults.set(data, forKey: "screenRecordingOptions") }
        }
    }
    private var recordingShortcuts: [String: Shortcut]
    func shortcut(for action: HotKeyAction) -> Shortcut {
        switch action {
        case .history: shortcut
        case .screenshot: screenshotShortcut
        default: recordingShortcuts[String(action.rawValue)] ?? action.defaultShortcut
        }
    }
    func moduleEnabled(for action: HotKeyAction) -> Bool {
        switch action {
        case .history: clipboardEnabled
        case .screenshot: screenshotEnabled
        default: screenRecordingEnabled
        }
    }
    func setShortcut(_ value: Shortcut, for action: HotKeyAction) {
        switch action {
        case .history: shortcut = value
        case .screenshot: screenshotShortcut = value
        default:
            recordingShortcuts[String(action.rawValue)] = value
            if let data = try? JSONEncoder().encode(recordingShortcuts) { defaults.set(data, forKey: "recordingShortcuts") }
        }
    }
    @ObservationIgnored var onMouseChanged: (() -> Void)?
    private var storedMouse: MouseScrollConfiguration
    var mouse: MouseScrollConfiguration {
        get { storedMouse }
        set {
            let value = newValue.normalized
            guard storedMouse != value else { return }
            storedMouse = value
            if let data = try? JSONEncoder().encode(value) {
                defaults.set(data, forKey: "mouseScrollConfiguration")
            }
            onMouseChanged?()
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
        storedRetentionDays = max(1, defaults.object(forKey: "retentionDays") as? Int ?? 30)
        storedHistoryLimit = max(1, defaults.object(forKey: "historyLimit") as? Int ?? 500)
        excludedApps = defaults.stringArray(forKey: "excludedApps").map(Set.init) ?? PrivacyPolicy.defaultExcludedApps
        showInDock = defaults.bool(forKey: "showInDock")
        clipboardEnabled = defaults.object(forKey: "clipboardEnabled") as? Bool ?? true
        screenshotEnabled = defaults.object(forKey: "screenshotEnabled") as? Bool ?? true
        screenRecordingEnabled = defaults.object(forKey: "screenRecordingEnabled") as? Bool ?? true
        screenRecordingOptions = defaults.data(forKey: "screenRecordingOptions")
            .flatMap { try? JSONDecoder().decode(ScreenRecordingOptions.self, from: $0) } ?? .init()
        recordingShortcuts = defaults.data(forKey: "recordingShortcuts")
            .flatMap { try? JSONDecoder().decode([String: Shortcut].self, from: $0) } ?? [:]
        storedMouse = defaults.data(forKey: "mouseScrollConfiguration")
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
