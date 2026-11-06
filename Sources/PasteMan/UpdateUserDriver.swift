import AppKit
import Observation
import Sparkle
import SwiftUI

/// 界面使用应用自己的翻译，运行时切换语言不依赖系统缓存的框架语言。
/// 下载、解包、校验、替换及重新启动仍全部交由 Sparkle 处理。
@MainActor final class UpdateUserDriver: NSObject, SPUUserDriver {
    let progress = UpdateProgress()
    private var window: NSWindow?
    private var alert: NSAlert?

    static func present(_ feedback: UpdateFeedback) {
        let alert = NSAlert()
        alert.messageText = feedback.title
        alert.informativeText = feedback.message
        alert.addButton(withTitle: L.t("OK", "好"))
        NSApp.activate()
        alert.runModal()
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        showProgress(.checking, cancellation: cancellation)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        hideProgress()
        let alert = NSAlert()
        alert.messageText = L.t("EasyMacOS \(appcastItem.displayVersionString) is available", "发现 EasyMacOS \(appcastItem.displayVersionString)")
        let description = String((appcastItem.itemDescription ?? "").prefix(12_000))
        alert.informativeText = L.t("Current version: ", "当前版本：") + AppVersion.current.display
        if !description.isEmpty {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            let text = NSTextView(frame: scroll.bounds)
            text.isEditable = false
            text.isSelectable = true
            text.isVerticallyResizable = true
            text.isHorizontallyResizable = false
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            text.textContainerInset = NSSize(width: 8, height: 8)
            text.font = .systemFont(ofSize: 13)
            text.textColor = .labelColor
            text.string = description
            scroll.documentView = text
            alert.accessoryView = scroll
        }
        if appcastItem.isInformationOnlyUpdate {
            alert.informativeText += "\n\n" + L.t("This release does not contain an installable update.", "此版本未提供可安装的更新包。")
            alert.addButton(withTitle: L.t("OK", "好"))
            run(alert)
            reply(.dismiss)
        } else {
            alert.addButton(withTitle: L.t("Download update", "下载更新"))
                .setAccessibilityIdentifier("update.download")
            alert.addButton(withTitle: L.t("Later", "稍后"))
            let choice = run(alert)
            reply(choice == .alertFirstButtonReturn ? .install : .dismiss)
        }
    }

    // 发布脚本把说明以纯文本嵌入清单，不加载网页或执行远端内容。
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        hideProgress()
        let nsError = error as NSError
        let noItems = nsError.userInfo[SPULatestAppcastItemFoundKey] == nil
        if noItems {
            showFeedback(.unpublished)
        } else {
            let reason = (nsError.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.int32Value ?? 0
            let systemTooOld = reason == SPUNoUpdateFoundReason.systemIsTooOld.rawValue
            showFeedback(UpdateFeedback(
                title: systemTooOld ? L.t("A newer macOS is required", "需要更新系统") : L.t("You're up to date", "已是最新版本"),
                message: systemTooOld
                    ? L.t("The available update requires a newer version of macOS.", "可用更新需要更高版本的系统。")
                    : L.t("You are running the latest compatible version of EasyMacOS.", "当前已是适用于此系统的最新版本。")))
        }
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        hideProgress()
        showFeedback(.failure(error))
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        progress.received = 0
        progress.expected = 0
        showProgress(.downloading, cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        progress.expected = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        let (value, overflow) = progress.received.addingReportingOverflow(length)
        progress.received = overflow ? UInt64.max : value
    }

    func showDownloadDidStartExtractingUpdate() { showProgress(.extracting) }
    func showExtractionReceivedProgress(_ value: Double) { progress.extraction = min(1, max(0, value)) }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        hideProgress()
        let alert = NSAlert()
        alert.messageText = L.t("Ready to install", "更新已准备就绪")
        alert.informativeText = L.t("EasyMacOS will quit, install the update, and reopen.", "EasyMacOS 将退出、安装更新并重新打开。")
        alert.addButton(withTitle: L.t("Install and relaunch", "安装并重新启动"))
            .setAccessibilityIdentifier("update.install")
        alert.addButton(withTitle: L.t("Cancel update", "取消更新"))
        // 不选择延后安装，取消时同时取消退出安装，避免无声替换。
        reply(run(alert) == .alertFirstButtonReturn ? .install : .skip)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        showProgress(.installing)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        hideProgress()
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        hideProgress()
        if let alert {
            if NSApp.modalWindow === alert.window { NSApp.abortModal() }
            alert.window.orderOut(nil)
        }
        alert = nil
    }

    func showUpdateInFocus() {
        NSApp.activate()
        (alert?.window ?? window)?.makeKeyAndOrderFront(nil)
    }

    private func showFeedback(_ feedback: UpdateFeedback) {
        let alert = NSAlert()
        alert.messageText = feedback.title
        alert.informativeText = feedback.message
        alert.addButton(withTitle: L.t("OK", "好"))
        run(alert)
    }

    @discardableResult private func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        self.alert = alert
        NSApp.activate()
        let response = alert.runModal()
        self.alert = nil
        return response
    }

    private func showProgress(_ stage: UpdateProgress.Stage, cancellation: (() -> Void)? = nil) {
        progress.stage = stage
        progress.cancellation = cancellation
        progress.extraction = 0
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: UpdateProgressView(progress: progress))
            window.center()
            self.window = window
        }
        window?.title = "EasyMacOS"
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func hideProgress() {
        progress.cancellation = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
    }
}

@MainActor @Observable final class UpdateProgress {
    enum Stage {
        case checking, downloading, extracting, installing

        var title: String {
            switch self {
            case .checking: L.t("Checking for updates…", "正在检查更新…")
            case .downloading: L.t("Downloading update…", "正在下载更新…")
            case .extracting: L.t("Preparing update…", "正在准备更新…")
            case .installing: L.t("Installing update…", "正在安装更新…")
            }
        }
    }

    var stage = Stage.checking
    var received: UInt64 = 0
    var expected: UInt64 = 0
    var extraction: Double = 0
    var cancellation: (() -> Void)?

    var fraction: Double? {
        if stage == .extracting { return extraction }
        guard stage == .downloading, expected > 0 else { return nil }
        return min(1, Double(received) / Double(expected))
    }
}

struct UpdateProgressView: View {
    let progress: UpdateProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(progress.stage.title).font(.headline)
            ProgressView(value: progress.fraction).progressViewStyle(.linear)
            HStack {
                if progress.stage == .downloading {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: progress.received), countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let cancel = progress.cancellation {
                    Button(L.t("Cancel", "取消")) {
                        progress.cancellation = nil
                        cancel()
                    }.keyboardShortcut(.cancelAction)
                }
            }
        }.padding(24).frame(width: 400, height: 160)
    }
}
