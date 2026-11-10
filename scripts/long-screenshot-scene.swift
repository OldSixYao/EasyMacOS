// 长截屏实机验证只显示本脚本生成的行号和图案，不读取用户内容。
import AppKit
import WebKit

func rowColor(_ row: Int) -> NSColor {
    let hash = UInt32(row + 1) &* 2_654_435_761
    return NSColor(srgbRed: CGFloat(32 + (hash & 191)) / 255,
        green: CGFloat(32 + ((hash >> 8) & 191)) / 255, blue: CGFloat(32 + ((hash >> 16) & 191)) / 255, alpha: 1)
}
@MainActor final class LongPageView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        for row in 0..<55 {
            let rect = CGRect(x: 0, y: row * 44, width: Int(bounds.width), height: 44)
            guard rect.intersects(dirtyRect) else { continue }
            (row.isMultiple(of: 2) ? NSColor.white : NSColor(calibratedWhite: 0.95, alpha: 1)).setFill(); rect.fill()
            let color = rowColor(row)
            color.setFill(); CGRect(x: 24, y: row * 44, width: 12, height: 44).fill()
            (String(format: "第 %04d 行  ·  长截屏验证内容", row + 1) as NSString).draw(at: CGPoint(x: 48, y: row * 44 + 12),
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 16, weight: .medium), .foregroundColor: NSColor.black])
            for column in 0..<5 {
                color.setFill()
                CGRect(x: 400 + column * 65, y: row * 44 + 9, width: 24 + row % 19, height: 26).fill()
            }
        }
    }
}
@MainActor final class WebReady: NSObject, WKNavigationDelegate {
    var ready: (() -> Void)?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready?() }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let isWeb = CommandLine.arguments.contains("--web")
    let hasFloatingButton = CommandLine.arguments.contains("--floating-button")
    let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 900)
    let size = CGSize(width: min(820, screen.width - 80), height: min(600, screen.height - 100))
    let window = NSWindow(contentRect: CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
        width: size.width, height: size.height), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = isWeb ? "长截屏验证：合成网页" : "长截屏验证：原生列表"
    window.isReleasedWhenClosed = false
    let delegate = WebReady()
    let eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
        if ProcessInfo.processInfo.environment["EASYMACOS_LONG_CADENCE"] == "1" {
            print("滚轮节奏：\(ProcessInfo.processInfo.systemUptime)，位移：\(event.scrollingDeltaY)")
            fflush(stdout)
        }
        if ProcessInfo.processInfo.environment["EASYMACOS_LONG_TRACE"] == "1" {
            print("滚轮事件：窗口 \(event.windowNumber)，位置 \(event.locationInWindow)，位移 \(event.scrollingDeltaY)")
            if let cg = event.cgEvent {
                let fields = (0...130).compactMap { number -> String? in
                    guard let field = CGEventField(rawValue: UInt32(number)) else { return nil }
                    let value = cg.getDoubleValueField(field)
                    return value == 0 ? nil : "\(number):\(value)"
                }
                print("事件全局坐标：\(cg.location)，字段：\(fields.joined(separator: ", "))")
            }
            fflush(stdout)
        }
        return event
    }
    func ready() {
        window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        let rect = window.convertToScreen(window.contentView!.bounds)
        let destination = ProcessInfo.processInfo.environment["EASYMACOS_LONG_SCENE"] ?? "/tmp/easymacos-long-scene.json"
        let value: [String: Any] = ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height,
            "scale": window.backingScaleFactor, "desktopTop": NSScreen.screens.first!.frame.maxY,
            "expectedHeight": 55 * 44 + (isWeb ? 88 : 0), "top": isWeb ? 56 : 0,
            "bottom": isWeb ? 32 : 0, "pid": ProcessInfo.processInfo.processIdentifier, "web": isWeb,
            "floatingButton": hasFloatingButton]
        try! JSONSerialization.data(withJSONObject: value, options: .prettyPrinted).write(to: URL(fileURLWithPath: destination))
        print("合成画面已就绪：\(destination)"); fflush(stdout)
    }
    if isWeb {
        let web = WKWebView(frame: CGRect(origin: .zero, size: size))
        web.navigationDelegate = delegate
        delegate.ready = ready
        window.contentView = web
        var rows = ""
        for row in 0..<55 {
            let color = rowColor(row).usingColorSpace(.sRGB)!
            let rgb = "rgb(\(Int((color.redComponent * 255).rounded())),\(Int((color.greenComponent * 255).rounded())),\(Int((color.blueComponent * 255).rounded())))"
            rows += "<div class='row'><i style='background:\(rgb)'></i>第 \(String(format: "%04d", row + 1)) 行 · 长截屏验证内容<span style='background:\(rgb);width:\(24 + row % 19)px'></span></div>"
        }
        web.loadHTMLString("""
        <!doctype html><html><meta charset='utf-8'><meta http-equiv='Content-Security-Policy' content="default-src 'none'; style-src 'unsafe-inline'">
        <style>*{box-sizing:border-box}body{margin:0;padding:56px 0 32px;font:16px monospace;color:#111;background:white}
        header,footer{position:fixed;left:0;right:0;z-index:5;color:white;padding:14px 24px;background:#205b72}
        header{top:0;height:56px}footer{bottom:0;height:32px;padding:6px 24px;background:#594577}
        .row{height:44px;position:relative;padding:12px 48px}.row:nth-child(even){background:#f2f2f2}
        .floating-button{position:fixed;z-index:10;left:calc(50% - 20px);bottom:110px;width:40px;height:40px;border:2px solid #12a8eb;border-radius:50%;background:#141414;color:white;line-height:36px;text-align:center}
        i{position:absolute;left:24px;top:0;bottom:0;width:12px}span{position:absolute;left:65%;top:9px;height:26px;box-shadow:80px 0 currentColor,160px 0 currentColor}
        </style><header>固定顶部 · 自动滚动长截屏</header>\(rows)<footer>固定底部 · 仅在成片末尾保留</footer>\(hasFloatingButton ? "<div class='floating-button'>↓</div>" : "")</html>
        """, baseURL: nil)
    } else {
        let scroll = NSScrollView(frame: CGRect(origin: .zero, size: size))
        scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        scroll.documentView = LongPageView(frame: CGRect(x: 0, y: 0, width: size.width, height: 55 * 44))
        window.contentView = scroll
        ready()
    }
    app.run()
    withExtendedLifetime(delegate) {}
    withExtendedLifetime(eventMonitor) {}
}
