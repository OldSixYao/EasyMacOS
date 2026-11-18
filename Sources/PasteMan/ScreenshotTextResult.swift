import AppKit

enum ScreenshotRecognitionKind: String, Sendable, CaseIterable, Codable {
    case text, barcodes

    var title: String {
        switch self {
        case .text: L.t("Recognize text", "识别文字")
        case .barcodes: L.t("Recognize barcodes / QR codes", "识别条码/二维码")
        }
    }
    var progressMessage: String {
        switch self {
        case .text: L.t("Recognizing text…", "正在识别文字…")
        case .barcodes: L.t("Recognizing barcodes / QR codes…", "正在识别条码/二维码…")
        }
    }
    var emptyMessage: String {
        switch self {
        case .text: L.t("No text was found. Return to the image or try again.", "未发现可识别的文字，可返回原图或重试。")
        case .barcodes: L.t("No readable barcodes or QR codes were found. Include the complete code and try again.",
            "未发现可识别的条形码或二维码，请框选完整码图后重试。")
        }
    }
    var failurePrefix: String {
        switch self {
        case .text: L.t("Text recognition failed: ", "文字识别失败：")
        case .barcodes: L.t("Barcode recognition failed: ", "条码识别失败：")
        }
    }
}

@MainActor final class ScreenshotTextSession: NSObject, NSWindowDelegate, NSTextViewDelegate {
    enum State: Equatable { case idle, recognizing, ready, empty, failed(String), closed }
    enum CloseReason { case back, copied }
    let window: NSPanel
    let textView = ScreenshotRecognitionTextView()
    let kind: ScreenshotRecognitionKind
    private(set) var state = State.idle
    private(set) var progress: Double = 0
    var onClose: ((CloseReason) -> Void)?
    var onCopy: ((String) -> Bool)?
    private var input: ScreenshotTextInput?
    private let recognizer: any ScreenshotTextRecognizing
    private let presentWindow: (NSPanel) -> Void
    private var task: Task<Void, Never>?
    private var revision = 0
    private var languageObserver: NSObjectProtocol?
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let copyButton = NSButton()
    private let retryButton = NSButton()
    private let backButton = NSButton()
    private var copyMessage: String?

    init(input: ScreenshotTextInput, kind: ScreenshotRecognitionKind = .text,
         recognizer: any ScreenshotTextRecognizing = SystemScreenshotTextRecognizer.shared,
         presentWindow: @escaping (NSPanel) -> Void = {
             NSApp.activate(); $0.makeKeyAndOrderFront(nil)
         }) {
        self.input = input; self.kind = kind; self.recognizer = recognizer; self.presentWindow = presentWindow
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 700)
        let size = CGSize(width: min(660, visible.width - 40), height: min(500, visible.height - 40))
        let panel = ScreenshotTextResultPanel(contentRect: CGRect(x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window = panel
        super.init()
        panel.onCancel = { [weak self] in self?.close() }
        panel.delegate = self
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.minSize = CGSize(width: 440, height: 300)
        buildContent()
        languageObserver = NotificationCenter.default.addObserver(forName: InterfaceLocalization.didChange,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        refresh()
    }

    func show() {
        guard state != .closed else { return }
        presentWindow(window)
        if state == .idle { retry() }
    }

    func retry() {
        guard state != .closed, state != .recognizing, let input else { return }
        revision += 1
        let version = revision
        state = .recognizing; progress = 0; copyMessage = nil
        textView.string = ""
        textView.undoManager?.removeAllActions()
        refresh()
        task = Task { [weak self, recognizer] in
            do {
                let text = try await recognizer.recognize(input) { [weak self] value in
                    Task { @MainActor [weak self] in
                        guard let self, self.revision == version, self.state == .recognizing else { return }
                        self.progress = value; self.refresh()
                    }
                }
                try Task.checkCancellation()
                guard let self, self.revision == version, self.state != .closed else { return }
                self.task = nil
                self.textView.string = text
                self.state = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .ready
                self.refresh()
                self.window.makeFirstResponder(self.textView)
            } catch {
                guard !Task.isCancelled, let self, self.revision == version, self.state != .closed else { return }
                self.task = nil; self.state = .failed(error.localizedDescription); self.refresh()
            }
        }
    }

    @discardableResult func copyAll() -> Bool {
        guard copy(textView.string) else { return false }
        close(reason: .copied)
        return true
    }

    @discardableResult private func copy(_ text: String) -> Bool {
        guard state != .closed, state != .recognizing,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let written = onCopy?(text) == true
        copyMessage = written ? L.t("Copied", "已复制") : L.t("Could not write to the clipboard. Try again.", "无法写入剪贴板，请重试。")
        refresh()
        return written
    }

    func close(reason: CloseReason = .back, notify: Bool = true) {
        guard state != .closed else { return }
        revision += 1; task?.cancel(); task = nil
        state = .closed; input = nil
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
        languageObserver = nil
        let callback = notify ? onClose : nil
        onClose = nil; onCopy = nil
        textView.onCopy = nil; textView.delegate = nil
        textView.string = ""; textView.undoManager?.removeAllActions()
        window.delegate = nil; window.contentView = nil; window.close()
        callback?(reason)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
    func textDidChange(_ notification: Notification) {
        guard state != .recognizing, state != .closed else { return }
        state = textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .ready
        copyMessage = nil; refresh()
    }

    private func buildContent() {
        guard let content = window.contentView else { return }
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = CGSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = CGSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.delegate = self
        textView.onCopy = { [weak self] in self?.copy($0) ?? false }
        textView.setAccessibilityIdentifier("screenshot.recognition.text")
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        textView.frame = CGRect(x: 0, y: 0, width: 600, height: 300)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.maximumNumberOfLines = 3
        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0; progressIndicator.maxValue = 1
        for (button, action) in [(retryButton, #selector(retryAction)), (copyButton, #selector(copyAction)), (backButton, #selector(backAction))] {
            button.bezelStyle = .rounded; button.target = self; button.action = action
        }
        copyButton.setAccessibilityIdentifier("screenshot.recognition.copyAll")
        let spacer = NSView()
        let buttons = NSStackView(views: [spacer, retryButton, copyButton, backButton])
        buttons.spacing = 8
        let stack = NSStackView(views: [statusLabel, progressIndicator, scroll, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            progressIndicator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    private func refresh() {
        window.title = kind.title
        copyButton.title = L.t("Copy all", "复制全部")
        retryButton.title = L.t("Retry", "重试")
        backButton.title = L.t("Back to image", "返回原图")
        let busy = state == .recognizing
        progressIndicator.isHidden = !busy
        progressIndicator.doubleValue = progress
        textView.isEditable = !busy
        copyButton.isEnabled = !busy && !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch state {
        case .idle, .recognizing:
            statusLabel.stringValue = kind.progressMessage + " \(Int(progress * 100))%"
            retryButton.isHidden = true
        case .ready:
            statusLabel.stringValue = ""
            retryButton.isHidden = true
        case .empty:
            statusLabel.stringValue = kind.emptyMessage
            retryButton.isHidden = false
        case .failed(let message):
            statusLabel.stringValue = kind.failurePrefix + message
            retryButton.isHidden = false
        case .closed: return
        }
        if let copyMessage { statusLabel.stringValue = copyMessage }
        statusLabel.isHidden = statusLabel.stringValue.isEmpty
    }

    @objc private func retryAction() { retry() }
    @objc private func copyAction() { copyAll() }
    @objc private func backAction() { close() }
}

@MainActor final class ScreenshotRecognitionTextView: NSTextView {
    var onCopy: ((String) -> Bool)?
    override func copy(_ sender: Any?) { _ = copySelection() }
    override func cut(_ sender: Any?) {
        if copySelection() { insertText("", replacementRange: selectedRange()) }
    }
    private func copySelection() -> Bool {
        let range = selectedRange()
        guard range.length > 0, NSMaxRange(range) <= (string as NSString).length else { return false }
        return onCopy?((string as NSString).substring(with: range)) == true
    }
}

@MainActor private final class ScreenshotTextResultPanel: NSPanel {
    var onCancel: (() -> Void)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53,
            (firstResponder as? NSTextView)?.hasMarkedText() != true {
            onCancel?(); return
        }
        super.sendEvent(event)
    }
}
