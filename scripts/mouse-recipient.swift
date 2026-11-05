// 可选跨进程滚动验证的合成接收窗口，只保存自身收到的合成事件元数据。
import AppKit

let readyURL = URL(fileURLWithPath: CommandLine.arguments[1])
let resultURL = URL(fileURLWithPath: CommandLine.arguments[2])

@MainActor final class MouseInput: NSView {
    private var events: [[String: Any]] = []
    override func scrollWheel(with event: NSEvent) {
        events.append([
            "x": event.scrollingDeltaX, "y": event.scrollingDeltaY,
            "precise": event.hasPreciseScrollingDeltas,
            "marker": event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0,
        ])
        if let data = try? JSONSerialization.data(withJSONObject: events) {
            try? data.write(to: resultURL, options: .atomic)
        }
    }
}

@MainActor final class MouseRecipient: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: CGRect(x: 120, y: 140, width: 360, height: 220),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "鼠标滚动合成验证"
        window.contentView = MouseInput(frame: CGRect(x: 0, y: 0, width: 360, height: 220))
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let point = window.convertPoint(toScreen: CGPoint(x: 180, y: 110))
        let ready: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "x": point.x, "y": (NSScreen.screens.first?.frame.maxY ?? 0) - point.y,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: ready) {
            try? data.write(to: readyURL, options: .atomic)
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = MouseRecipient()
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
