// 仅供隔离升级验证的宿主；与正式应用复用 UpdateUserDriver 和 AppVersion 源码。
// 不启动剪贴板、截图、鼠标增强或访达服务。
import AppKit
import Foundation
import Sparkle

enum L {
    static func t(_ en: String, _ zh: String) -> String { zh }
}

@MainActor final class UpdateSmokeDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    private var updater: SPUUpdater?
    private var driver: UpdateUserDriver?
    private var timer: Timer?
    private var actions: [String] = []
    private var started = Date()
    private var finished = false
    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let expectedBuild = info["UpdateSmokeTargetBuild"] as! String
        if AppVersion.current.build == expectedBuild {
            complete("installed", error: nil)
            return
        }
        UserDefaults.standard.set("保留更新前偏好", forKey: "UpdateSmokeSentinel")
        started = Date()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        let driver = UpdateUserDriver()
        self.driver = driver
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        self.updater = updater
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
        updater.sendsSystemProfile = false
        do {
            try updater.start()
            updater.checkForUpdates()
        } catch { complete("startupError", error: error) }
    }

    private func tick() {
        if Date().timeIntervalSince(started) > 45 {
            complete("timeout", error: nil)
            return
        }
        guard let modal = NSApp.modalWindow, let content = modal.contentView else { return }
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        let all = buttons(content)
        if info["UpdateSmokeCancelInstall"] as? Bool == true,
           let cancel = all.first(where: { $0.title == "取消更新" }) {
            actions.append(cancel.title)
            cancel.performClick(nil)
            return
        }
        let button = all.first { $0.accessibilityIdentifier() == "update.download" }
            ?? all.first { $0.accessibilityIdentifier() == "update.install" }
            ?? all.first { $0.title == "好" }
        if let button {
            actions.append(button.title)
            button.performClick(nil)
        }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        complete("finished", error: error)
    }

    private func complete(_ outcome: String, error: (any Error)?) {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        let result: [String: Any] = [
            "outcome": outcome,
            "version": AppVersion.current.version ?? "",
            "build": AppVersion.current.build ?? "",
            "preferencesPreserved": UserDefaults.standard.string(forKey: "UpdateSmokeSentinel") == "保留更新前偏好",
            "errorCode": (error as NSError?)?.code ?? 0,
            "errorDomain": (error as NSError?)?.domain ?? "",
            "actions": actions,
        ]
        let path = info["UpdateSmokeResult"] as! String
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: path), options: .atomic)
        // 不在回调中同步退出，让更新组件先完成本次会话的收尾。
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}

@main struct UpdateSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = UpdateSmokeDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
