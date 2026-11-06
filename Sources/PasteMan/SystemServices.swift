import AppKit
@preconcurrency import ApplicationServices
import Carbon
import Observation
import PasteManCore
import ServiceManagement
import UniformTypeIdentifiers

@MainActor protocol ClipboardReading: AnyObject {
    var changeCount: Int { get }
    var types: Set<String> { get }
    func capture() -> ClipboardSnapshot?
}

@MainActor protocol ClipboardWriting {
    func write(_ content: PreparedContent) -> Bool
}

@MainActor protocol ClipboardPermissionChecking {
    var allowsMonitoring: Bool { get }
    func refreshClipboard()
}

enum ClipboardSnapshot: Sendable {
    case text(String)
    case image(Data)
}

@MainActor final class SystemClipboard: ClipboardReading, ClipboardWriting {
    let pasteboard: NSPasteboard
    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }
    var changeCount: Int { pasteboard.changeCount }
    var types: Set<String> {
        Set((pasteboard.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) })
    }
    func capture() -> ClipboardSnapshot? {
        let interval = PerformanceTrace.signposter.beginInterval("ClipboardRead", id: PerformanceTrace.signposter.makeSignpostID())
        defer { PerformanceTrace.signposter.endInterval("ClipboardRead", interval) }
        for item in pasteboard.pasteboardItems ?? [] {
            // A Finder file copy may expose text or promised thumbnails. Do not record either.
            if item.types.contains(.fileURL)
                || item.types.contains(NSPasteboard.PasteboardType("NSFilenamesPboardType"))
            {
                continue
            }
            let preferred: [NSPasteboard.PasteboardType] = [.png, .tiff]
            let otherImages = item.types.filter {
                !preferred.contains($0) && UTType($0.rawValue)?.conforms(to: .image) == true
            }
            for type in preferred + otherImages where item.types.contains(type) {
                if let data = item.data(forType: type) { return .image(data) }
            }
            if let text = item.string(forType: .string), !text.isEmpty { return .text(text) }
        }
        return nil
    }
    func write(_ content: PreparedContent) -> Bool {
        pasteboard.clearContents()
        switch content {
        case .text(let text): return pasteboard.setString(text, forType: .string)
        case .image(let png, _): return pasteboard.setData(png, forType: .png)
        }
    }
}

@MainActor @Observable final class PermissionService: ClipboardPermissionChecking {
    enum ClipboardAccess { case allowed, needsApproval, denied }
    // Automatic paste synthesizes events; test that capability rather than AX object access.
    private(set) var accessibility = CGPreflightPostEventAccess()
    private(set) var clipboard: ClipboardAccess = .needsApproval
    private(set) var screenRecording = CGPreflightScreenCaptureAccess()
    private(set) var loginStatus = SMAppService.mainApp.status
    var allowsMonitoring: Bool { clipboard == .allowed }

    func refresh() {
        accessibility = CGPreflightPostEventAccess()
        screenRecording = CGPreflightScreenCaptureAccess()
        refreshClipboard()
        loginStatus = SMAppService.mainApp.status
    }
    func refreshClipboard() {
        if #available(macOS 15.4, *) {
            switch NSPasteboard.general.accessBehavior {
            case .alwaysAllow: clipboard = .allowed
            case .alwaysDeny: clipboard = .denied
            default: clipboard = .needsApproval
            }
        } else {
            clipboard = .allowed
        }
    }
    func requestClipboardAccess() {
        // Only an explicit user action attempts the first read; the background monitor never prompts.
        _ = NSPasteboard.general.string(forType: .string)
        refresh()
        if clipboard != .allowed { openPrivacy("Privacy_Pasteboard") }
    }
    func requestScreenRecording() {
        screenRecording = CGRequestScreenCaptureAccess()
        if !screenRecording { openPrivacy("Privacy_ScreenCapture") }
    }
    func requestAccessibility() {
        FinderRenameAccess.request()
        accessibility = CGPreflightPostEventAccess()
    }
    func revealRunningApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
    func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
    func setLoginEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        refresh()
        if loginStatus == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}

enum HotKeyAction: UInt32, CaseIterable {
    case history = 1
    case screenshot = 2
}

@MainActor final class HotKeyService {
    var onInvoke: (() -> Void)?
    var onScreenshot: (() -> Void)?
    private var hotKeys: [HotKeyAction: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var recorder: Any?
    private var recordingCompletion: ((Shortcut?) -> Void)?
    private var current: [HotKeyAction: Shortcut] = [:]

    init() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let context, let event else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                guard
                    GetEventParameter(
                        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                        nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                    id.signature == 0x5053_4D4E, let action = HotKeyAction(rawValue: id.id)
                else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated {
                    Unmanaged<HotKeyService>.fromOpaque(context).takeUnretainedValue().invoke(action)
                }
                return noErr
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func invoke(_ action: HotKeyAction) {
        if recorder != nil {
            if let shortcut = current[action], let completion = recordingCompletion {
                cancelRecording()
                completion(shortcut)
            }
            return
        }
        switch action {
        case .history: onInvoke?()
        case .screenshot: onScreenshot?()
        }
    }
    func register(_ shortcut: Shortcut, for action: HotKeyAction = .history) -> Bool {
        guard !current.contains(where: { $0.key != action && $0.value.matches(shortcut) }) else { return false }
        if current[action]?.matches(shortcut) == true { return true }
        var candidate: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x5053_4D4E, id: action.rawValue)
        guard
            RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &candidate)
                == noErr,
            let candidate
        else { return false }
        if let previous = hotKeys[action] { UnregisterEventHotKey(previous) }
        hotKeys[action] = candidate
        current[action] = shortcut
        return true
    }
    func record(completion: @escaping (Shortcut?) -> Void) {
        cancelRecording()
        recordingCompletion = completion
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.cancelRecording()
                completion(nil)
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !flags.intersection([.command, .control, .option]).isEmpty,
                let label = event.charactersIgnoringModifiers, !label.isEmpty
            else {
                NSSound.beep()
                return nil
            }
            var modifiers: UInt32 = 0
            if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
            if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
            if flags.contains(.option) { modifiers |= UInt32(optionKey) }
            if flags.contains(.control) { modifiers |= UInt32(controlKey) }
            self.cancelRecording()
            completion(Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label.uppercased()))
            return nil
        }
    }
    func unregister(for action: HotKeyAction) {
        if let ref = hotKeys.removeValue(forKey: action) { UnregisterEventHotKey(ref) }
        current.removeValue(forKey: action)
    }
    func cancelRecording() {
        if let recorder { NSEvent.removeMonitor(recorder) }
        recorder = nil
        recordingCompletion = nil
    }
    func stop() {
        cancelRecording()
        for ref in hotKeys.values { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        hotKeys.removeAll()
        current.removeAll()
        handler = nil
    }
}

enum PasteOutcome: Equatable {
    case sent, permissionRequired, targetUnavailable, activationFailed, eventCreationFailed

    var recoveryMessage: String {
        switch self {
        case .sent: ""
        case .permissionRequired:
            L.t(
                "Copied. macOS has not granted keyboard-event access to this running version. If EasyMacOS is already enabled in System Settings, remove its old entry and add the current app again, then quit and reopen EasyMacOS. You can paste manually with ⌘V.",
                "已复制。macOS 尚未允许当前版本发送键盘事件。若系统设置中 EasyMacOS 已开启，请移除旧条目并重新添加当前应用，然后退出并重新打开 EasyMacOS。也可按 ⌘V 手动粘贴。")
        case .targetUnavailable:
            L.t(
                "Copied. The destination app is no longer available. Click the intended input field and press ⌘V.",
                "已复制。原目标应用已不可用，请点击目标输入框并按 ⌘V。")
        case .activationFailed:
            L.t(
                "Copied. The destination app could not regain keyboard focus. Click the intended input field and press ⌘V.",
                "已复制。目标应用未能恢复键盘焦点，请点击目标输入框并按 ⌘V。")
        case .eventCreationFailed:
            L.t(
                "Copied. Could not create the paste keystroke. Press ⌘V in the destination app.",
                "已复制。无法创建粘贴按键事件，请在目标应用按 ⌘V。")
        }
    }
}

@MainActor protocol PasteExecuting {
    func paste(to target: NSRunningApplication?) async -> PasteOutcome
}

@MainActor struct SystemPasteExecutor: PasteExecuting {
    func paste(to target: NSRunningApplication?) async -> PasteOutcome {
        guard let target, !target.isTerminated,
            target.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return .targetUnavailable }
        guard CGPreflightPostEventAccess() else { return .permissionRequired }
        NSApp.yieldActivation(to: target)
        target.activate(from: .current, options: [])
        // Order-out of the nonactivating history panel releases keyboard focus asynchronously.
        // Require a stable recipient and released modifiers before delivering Cmd-V.
        var stableChecks = 0
        for _ in 0..<15 {
            do { try await Task.sleep(for: .milliseconds(40)) } catch { return .activationFailed }
            guard CGPreflightPostEventAccess() else { return .permissionRequired }
            guard !target.isTerminated else { return .targetUnavailable }
            let modifiers = CGEventSource.flagsState(.combinedSessionState)
                .intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                modifiers.isEmpty
            {
                stableChecks += 1
            } else {
                stableChecks = 0
            }
            if stableChecks >= 2 {
                guard let source = CGEventSource(stateID: .combinedSessionState),
                    let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
                    let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
                else { return .eventCreationFailed }
                guard CGPreflightPostEventAccess() else { return .permissionRequired }
                guard
                    NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
                else { return .activationFailed }
                down.flags = .maskCommand
                up.flags = .maskCommand
                down.postToPid(target.processIdentifier)
                up.postToPid(target.processIdentifier)
                return .sent
            }
        }
        return .activationFailed
    }
}
