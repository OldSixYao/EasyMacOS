// Synthetic receiver for the opt-in paste integration test. Never reads the clipboard.
import AppKit
import Foundation

let readyURL = URL(fileURLWithPath: CommandLine.arguments[1])
let resultURL = URL(fileURLWithPath: CommandLine.arguments[2])
let token = CommandLine.arguments[3]

@MainActor final class SyntheticInput: NSTextView {
    override func paste(_ sender: Any?) {
        insertText(token, replacementRange: selectedRange())
        try? string.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

@MainActor final class RecipientDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 360, height: 180),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "EasyMacOS synthetic paste test"
        let input = SyntheticInput(frame: NSRect(x: 0, y: 0, width: 360, height: 180))
        input.isEditable = true
        window.contentView = input
        let menu = NSMenu()
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Edit")
        submenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.submenu = submenu
        menu.addItem(edit)
        NSApp.mainMenu = menu
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(input)
        try? String(ProcessInfo.processInfo.processIdentifier).write(to: readyURL, atomically: true, encoding: .utf8)
    }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = RecipientDelegate()
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
