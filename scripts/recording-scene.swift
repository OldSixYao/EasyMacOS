// 录屏实机验证的合成画面；不访问剪贴板或用户文件。
import AppKit

@MainActor final class RecordingScene: NSView {
    var tick = 0
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.05, green: 0.35, blue: 0.5, alpha: 1).setFill()
        bounds.fill()
        for row in 0..<5 {
            for column in 0..<8 where (row + column).isMultiple(of: 2) {
                NSColor.white.withAlphaComponent(0.15).setFill()
                NSRect(x: column * 80, y: row * 80, width: 80, height: 80).fill()
            }
        }
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: NSRect(x: 40 + tick % 500, y: 90, width: 60, height: 60)).fill()
        ("录屏验证画面  \(tick)" as NSString).draw(at: NSPoint(x: 30, y: 300), withAttributes: [
            .font: NSFont.systemFont(ofSize: 30, weight: .bold), .foregroundColor: NSColor.white,
        ])
    }
}
MainActor.assumeIsolated {
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let fullScreen = ProcessInfo.processInfo.environment["EASYMACOS_RECORDING_SCENE_FULLSCREEN"] == "1"
let frames = fullScreen ? NSScreen.screens.map(\.frame) : [NSRect(x: 100, y: 100, width: 640, height: 400)]
let windows = frames.map { frame -> NSWindow in
let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
window.level = fullScreen ? NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1) : .floating
window.isReleasedWhenClosed = false
window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
let view = RecordingScene(frame: NSRect(origin: .zero, size: frame.size))
window.contentView = view
window.orderFrontRegardless()
return window
}
let timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { _ in
    MainActor.assumeIsolated {
        for window in windows {
            if let view = window.contentView as? RecordingScene { view.tick += 4; view.needsDisplay = true }
        }
    }
}
print(fullScreen ? "合成画面已覆盖所有显示器" : "合成画面已就绪：100,100,640,400")
fflush(stdout)
app.run()

}
