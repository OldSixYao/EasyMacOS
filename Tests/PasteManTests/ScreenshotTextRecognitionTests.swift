import AppKit
import PasteManCore
import Testing

@testable import PasteMan

private func recognitionImage(width: Int = 800, height: Int = 400, texts: [(String, CGPoint)] = []) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try ScreenshotRenderer.render(base: #require(context.makeImage()), pointSize: CGSize(width: width, height: height),
        annotations: texts.map { text, point in
            ScreenshotAnnotation(tool: .text, points: [point, point], color: AnnotationColor.palette[5], width: 6, text: text)
        })
}

private struct ImmediateTextRecognizer: ScreenshotTextRecognizing {
    var text = "识别结果 Hello 123"
    func recognize(_ input: ScreenshotTextInput, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        progress(1); return text
    }
}

@MainActor private final class PendingTextRecognizer: ScreenshotTextRecognizing {
    var inputs: [ScreenshotTextInput] = []
    var pending: [CheckedContinuation<String, Error>] = []
    var completed = 0
    var cancelled = 0
    func recognize(_ input: ScreenshotTextInput, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        inputs.append(input)
        defer { completed += 1; if Task.isCancelled { cancelled += 1 } }
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
}

@MainActor private func waitForRecognition(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    try #require(condition())
}

@Suite("原生文字识别与长图分段") struct ScreenshotTextRecognitionTests {
    @Test func stripsKeepNativeWidthAndCoverLongImagesWithOverlap() {
        let strips = ScreenshotTextLayout.strips(width: 1600, height: 12_345)
        #expect(strips.first == CGRect(x: 0, y: 0, width: 1600, height: 3200))
        #expect(strips.last?.maxY == 12_345)
        for (previous, next) in zip(strips, strips.dropFirst()) {
            #expect(previous.maxY - next.minY == 256)
            #expect(next.width == 1600 && next.height <= 4096)
        }
        #expect(ScreenshotTextLayout.strips(width: 0, height: 500).isEmpty)
    }

    @Test func overlappingCopiesAreMergedButRepeatedTextAtOtherPositionsRemains() {
        var lines = [ScreenshotTextLine(text: "重复文字", rect: CGRect(x: 10, y: 3900, width: 200, height: 40), confidence: 0.7)]
        ScreenshotTextLayout.merge([
            ScreenshotTextLine(text: "重复文字", rect: CGRect(x: 11, y: 3902, width: 200, height: 40), confidence: 0.9),
            ScreenshotTextLine(text: "重复文字", rect: CGRect(x: 10, y: 4100, width: 200, height: 40), confidence: 0.9),
            ScreenshotTextLine(text: "首行", rect: CGRect(x: 10, y: 10, width: 100, height: 40), confidence: 1),
            ScreenshotTextLine(text: "同行右侧", rect: CGRect(x: 250, y: 3903, width: 200, height: 40), confidence: 1),
        ], into: &lines)
        #expect(lines.count == 4)
        #expect(ScreenshotTextLayout.text(from: lines) == "首行\n重复文字 同行右侧\n重复文字")
    }

    @Test func recognitionStripRendersCommittedMarksAtOriginalResolution() throws {
        let base = try recognitionImage(width: 400, height: 5000)
        let annotation = ScreenshotAnnotation(tool: .rectangle,
            points: [CGPoint(x: 10, y: 1950), CGPoint(x: 100, y: 2050)], color: AnnotationColor.palette[0], width: 6)
        let strip = CGRect(x: 0, y: 3840, width: 400, height: 1160)
        let actual = try SystemScreenshotTextRecognizer.renderStrip(base: base, pointSize: CGSize(width: 200, height: 2500),
            annotations: [annotation], strip: strip)
        let complete = try ScreenshotRenderer.render(base: base, pointSize: CGSize(width: 200, height: 2500), annotations: [annotation])
        let expected = try #require(complete.cropping(to: strip))
        #expect(actual.width == 400 && actual.height == 1160)
        #expect(try ScreenshotRenderer.encode(actual) == ScreenshotRenderer.encode(expected))
    }

    @Test func systemRecognizerReadsChineseEnglishAndLongImageBoundaryWithoutDuplicates() async throws {
        let image = try recognitionImage(width: 900, height: 4700, texts: [
            ("中文文字识别 Hello 123", CGPoint(x: 35, y: 45)),
            ("Boundary text 456", CGPoint(x: 35, y: 1660)),
            ("最后一行 Finish 789", CGPoint(x: 35, y: 4400)),
        ])
        let text = try await SystemScreenshotTextRecognizer.shared.recognize(
            .image(image, pointSize: CGSize(width: 900, height: 4700), annotations: []), progress: { _ in })
        #expect(text.contains("中文文字识别"))
        #expect(text.contains("Hello 123") && text.contains("Finish 789"))
        #expect(text.components(separatedBy: "Boundary text 456").count == 2)
        let first = try #require(text.range(of: "Hello")), last = try #require(text.range(of: "Finish"))
        #expect(first.lowerBound < last.lowerBound)
    }

    @Test func blankImageHasNoTextAndPreCancelledWorkDoesNotRecognize() async throws {
        let image = try recognitionImage()
        let text = try await SystemScreenshotTextRecognizer.shared.recognize(
            .image(image, pointSize: CGSize(width: 800, height: 400), annotations: []), progress: { _ in })
        #expect(text.isEmpty)
        let task = Task {
            try Task.checkCancellation()
            return try await SystemScreenshotTextRecognizer.shared.recognize(
                .image(image, pointSize: CGSize(width: 800, height: 400), annotations: []), progress: { _ in })
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

@Suite("文字识别结果窗口", .serialized) @MainActor struct ScreenshotTextResultTests {
    private func session(recognizer: any ScreenshotTextRecognizing = ImmediateTextRecognizer()) throws -> ScreenshotTextSession {
        _ = NSApplication.shared
        return ScreenshotTextSession(input: .image(try recognitionImage(), pointSize: CGSize(width: 800, height: 400), annotations: []),
            recognizer: recognizer, presentWindow: { _ in })
    }

    @Test func selectionCopyAndFailedCopyKeepResultWhileCopyAllClosesIt() async throws {
        let session = try session()
        defer { session.close() }
        var copied: [String] = []
        session.onCopy = { copied.append($0); return true }
        session.show()
        try await waitForRecognition { session.state == .ready }
        session.textView.string = "已编辑的结果 Hello"
        session.textView.setSelectedRange(NSRange(location: 0, length: 3))
        session.textView.copy(nil)
        #expect(copied == ["已编辑"])
        #expect(session.state == .ready && session.window.contentView != nil)
        session.onCopy = { _ in false }
        #expect(!session.copyAll())
        #expect(session.textView.string == "已编辑的结果 Hello" && session.state == .ready)
        var reasons: [ScreenshotTextSession.CloseReason] = []
        session.onClose = { reasons.append($0) }
        session.onCopy = { copied.append($0); return true }
        #expect(session.copyAll())
        #expect(copied == ["已编辑", "已编辑的结果 Hello"])
        #expect(session.state == .closed && session.window.contentView == nil && reasons == [.copied])
        #expect(!session.copyAll())
        #expect(copied.count == 2 && reasons.count == 1)
    }

    @Test func closingCancelsPendingWorkDiscardsLateResultAndReleasesController() async throws {
        let recognizer = PendingTextRecognizer()
        var session: ScreenshotTextSession? = try session(recognizer: recognizer)
        let isReleased = { [weak session] in session == nil }
        var closed = 0
        session?.onClose = { _ in closed += 1 }
        session?.show()
        try await waitForRecognition { recognizer.pending.count == 1 }
        session?.close()
        #expect(session?.state == .closed && session?.window.contentView == nil && closed == 1)
        session = nil
        try await waitForRecognition { isReleased() }
        recognizer.pending.removeFirst().resume(returning: "迟到结果")
        try await waitForRecognition { recognizer.completed == 1 }
        #expect(recognizer.cancelled == 1 && closed == 1)
    }

    @Test func duplicateShowDoesNotStartAgainAndFailureCanRetryToEmptyThenSuccess() async throws {
        let recognizer = PendingTextRecognizer()
        let session = try session(recognizer: recognizer)
        defer { session.close() }
        session.show(); session.show(); session.retry()
        try await waitForRecognition { recognizer.pending.count == 1 }
        #expect(recognizer.inputs.count == 1)
        recognizer.pending.removeFirst().resume(throwing: CocoaError(.fileReadUnknown))
        try await waitForRecognition { if case .failed = session.state { return true }; return false }
        session.retry()
        try await waitForRecognition { recognizer.pending.count == 1 }
        recognizer.pending.removeFirst().resume(returning: "")
        try await waitForRecognition { session.state == .empty }
        #expect(!session.copyAll())
        session.retry()
        try await waitForRecognition { recognizer.pending.count == 1 }
        recognizer.pending.removeFirst().resume(returning: "恢复成功")
        try await waitForRecognition { session.state == .ready }
        #expect(session.textView.string == "恢复成功")
    }

    @Test func escapeClosesOnlyResultAndDoesNotDismissActiveComposition() async throws {
        let session = try session()
        session.show()
        try await waitForRecognition { session.state == .ready }
        session.window.makeFirstResponder(session.textView)
        session.textView.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: session.window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53))
        session.window.sendEvent(event)
        #expect(session.state != .closed)
        session.textView.unmarkText()
        session.window.sendEvent(event)
        #expect(session.state == .closed)
    }
}

@MainActor private struct RecognitionScreenCapture: ScreenCapturing {
    func capture(_ screens: [ScreenshotScreen]) async throws -> [CapturedScreen] {
        try screens.map { CapturedScreen(screen: $0, image: try recognitionImage(width: 800, height: 600)) }
    }
}

@Suite("截图与钉图文字识别接入", .serialized) @MainActor struct ScreenshotTextIntegrationTests {
    private func editor(recognizer: any ScreenshotTextRecognizing,
                        screens: [ScreenshotScreen] = [ScreenshotScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 800, height: 600), scale: 1)],
                        presentWindow: @escaping (NSPanel) -> Void = { _ in }) async throws -> (ScreenshotCoordinator, ScreenshotOverlay) {
        _ = NSApplication.shared
        let coordinator = ScreenshotCoordinator(captureService: RecognitionScreenCapture(), presentWindow: presentWindow,
            textRecognizer: recognizer, presentTextWindow: { _ in })
        coordinator.start(screens: screens, sourceID: "test.source", sourceName: "原始来源")
        try await waitForRecognition { coordinator.phase == .selecting }
        let view = try #require(coordinator.windows.first?.contentView as? ScreenshotOverlay)
        func event(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 600 - y), modifierFlags: [], timestamp: 0,
                windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, x: 50, y: 60))
        view.mouseUp(with: try event(.leftMouseUp, x: 450, y: 300))
        return (coordinator, view)
    }

    @Test func returningFromResultRestoresSelectedDisplayAndKeyboardFocus() async throws {
        var presented: [NSPanel] = []
        let (coordinator, view) = try await editor(recognizer: ImmediateTextRecognizer(), screens: [
            ScreenshotScreen(id: 1, frame: CGRect(x: -800, y: 0, width: 800, height: 600), scale: 1),
            ScreenshotScreen(id: 2, frame: CGRect(x: 0, y: 0, width: 800, height: 600), scale: 1),
        ], presentWindow: { presented.append($0) })
        defer { coordinator.cancel() }
        let active = try #require(view.window)
        view.state.action?(.recognizeText)
        let session = try #require(coordinator.textSession)
        try await waitForRecognition { session.state == .ready }
        session.close()
        #expect(presented.last === active && active.firstResponder === view)
        #expect(coordinator.selectedScreen == 1 && coordinator.phase == .editing)
    }

    @Test func selectionAndAnnotationsSurvivePreviewAndSelectionCopyKeepsSessionActive() async throws {
        let recognizer = PendingTextRecognizer()
        let (coordinator, view) = try await editor(recognizer: recognizer)
        defer { coordinator.cancel() }
        let annotation = ScreenshotAnnotation(tool: .mosaic, points: [.zero, CGPoint(x: 60, y: 40)],
            color: AnnotationColor.palette[0], width: 6)
        view.state.history.append(annotation)
        var copied: [String] = []
        coordinator.onCopyText = { text, id, name in
            #expect(id == "test.source" && name == "原始来源"); copied.append(text); return true
        }
        let selection = view.selection
        view.state.action?(.recognizeText)
        let result = try #require(coordinator.textSession)
        try await waitForRecognition { recognizer.pending.count == 1 }
        if case .image(let image, let size, let marks) = recognizer.inputs[0] {
            #expect(image.width == 400 && image.height == 240 && size == selection.size && marks == [annotation])
        } else { Issue.record("普通截图未使用选区原图") }
        recognizer.pending.removeFirst().resume(returning: "原始识别")
        try await waitForRecognition { result.state == .ready }
        result.textView.string = "编辑后复制"
        result.textView.selectAll(nil)
        result.textView.copy(nil)
        #expect(copied == ["编辑后复制"])
        #expect(coordinator.phase == .recognizingText && coordinator.isActive)
        result.close()
        #expect(coordinator.textSession == nil && coordinator.phase == .editing && !view.state.busy)
        #expect(view.selection == selection && view.state.history.annotations == [annotation])
    }

    @Test func copyAllButtonClosesResultAndEndsScreenshotWithoutRestoringEditor() async throws {
        var presented: [NSPanel] = []
        let (coordinator, view) = try await editor(recognizer: ImmediateTextRecognizer(), presentWindow: { presented.append($0) })
        defer { coordinator.cancel() }
        let window = try #require(view.window)
        view.state.action?(.recognizeText)
        let result = try #require(coordinator.textSession)
        try await waitForRecognition { result.state == .ready }
        let presentations = presented.count
        var copied = ""
        coordinator.onCopyText = { text, _, _ in copied = text; return true }
        result.textView.string = "最终复制内容"
        func copyButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.accessibilityIdentifier() == "screenshot.recognition.copyAll" { return button }
            return view.subviews.lazy.compactMap { copyButton(in: $0) }.first
        }
        let content = try #require(result.window.contentView)
        let button = try #require(copyButton(in: content))
        button.performClick(nil)
        #expect(copied == "最终复制内容" && result.state == .closed && result.window.contentView == nil)
        #expect(coordinator.phase == .idle && !coordinator.isActive && coordinator.textSession == nil)
        #expect(coordinator.windows.isEmpty && window.contentView == nil && presented.count == presentations)
    }

    @Test func disablingScreenshotClosesResultWithoutRestoringCancelledEditor() async throws {
        let recognizer = PendingTextRecognizer()
        let (coordinator, view) = try await editor(recognizer: recognizer)
        view.state.action?(.recognizeText)
        let result = try #require(coordinator.textSession)
        try await waitForRecognition { recognizer.pending.count == 1 }
        coordinator.isEnabled = false
        #expect(result.state == .closed && coordinator.phase == .idle && coordinator.windows.isEmpty)
        recognizer.pending.removeFirst().resume(returning: "迟到")
        try await waitForRecognition { recognizer.completed == 1 }
        #expect(coordinator.phase == .idle && coordinator.textSession == nil)
    }

    @Test func pinnedSessionsUseOriginalStorageAndAreCancelledIndependently() async throws {
        _ = NSApplication.shared
        let recognizer = PendingTextRecognizer()
        let pins = PinnedScreenshotManager(presentWindow: { _ in })
        pins.textRecognizer = recognizer
        var results: [NSPanel] = []
        pins.presentTextWindow = { results.append($0) }
        defer { pins.closeAll() }
        for id in ["first", "second"] {
            let bitmap = try recognitionImage()
            pins.show(try ScreenshotRenderer.export(base: bitmap, pointSize: CGSize(width: 800, height: 400), annotations: []),
                sourceID: id, sourceName: id, origin: .zero)
        }
        func recognize(_ window: NSWindow) throws {
            let event = try #require(NSEvent.mouseEvent(with: .rightMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
            let item = try #require(window.contentView?.menu(for: event)?.items.first { $0.action == NSSelectorFromString("recognizeText") })
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        }
        let first = pins.windows[0], second = pins.windows[1]
        first.setContentSize(CGSize(width: 160, height: 80))
        try recognize(first); try recognize(second)
        try await waitForRecognition { recognizer.pending.count == 2 }
        for input in recognizer.inputs {
            if case .pinned(let storage) = input { #expect(storage.pointSize == CGSize(width: 800, height: 400)) }
            else { Issue.record("钉图识别未使用原图存储") }
        }
        #expect(results.count == 2)
        first.close()
        #expect(results[0].contentView == nil && results[1].contentView != nil && pins.count == 1)
        recognizer.pending.removeFirst().resume(returning: "已关闭钉图的结果")
        pins.closeAll()
        recognizer.pending.removeFirst().resume(returning: "全部关闭后的结果")
        try await waitForRecognition { recognizer.completed == 2 }
        #expect(recognizer.cancelled == 2 && results.allSatisfy { $0.contentView == nil })
    }

    @Test func pinnedCopyAllClosesOnlyResultAndAllowsRecognitionAgain() async throws {
        _ = NSApplication.shared
        let pins = PinnedScreenshotManager(presentWindow: { _ in })
        pins.textRecognizer = ImmediateTextRecognizer()
        var results: [NSPanel] = []
        pins.presentTextWindow = { results.append($0) }
        var copied = ""
        pins.onCopyText = { text, id, _ in #expect(id == "test.pin"); copied = text; return true }
        defer { pins.closeAll() }
        pins.show(try ScreenshotRenderer.export(base: recognitionImage(), pointSize: CGSize(width: 800, height: 400), annotations: []),
            sourceID: "test.pin", sourceName: "钉图来源", origin: .zero)
        let window = try #require(pins.windows.first)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        let item = try #require(window.contentView?.menu(for: event)?.items.first { $0.action == NSSelectorFromString("recognizeText") })
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        let session = try #require(results.first?.delegate as? ScreenshotTextSession)
        try await waitForRecognition { session.state == .ready }
        #expect(session.copyAll())
        #expect(copied == "识别结果 Hello 123" && session.state == .closed)
        #expect(pins.count == 1 && window.contentView != nil)
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        #expect(results.count == 2 && results[1].contentView != nil)
    }
}

@MainActor private final class RecognitionHistoryPermissions: ClipboardPermissionChecking {
    var allowsMonitoring = true
    func refreshClipboard() {}
}

@Suite("识别文字复制与历史策略", .serialized) @MainActor struct ScreenshotTextHistoryTests {
    @Test func explicitTextCopyRecordsOnceWithOriginalSourceAndRespectsAllRecordingGates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "RecognitionHistory." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let board = NSPasteboard.withUniqueName()
        defer {
            board.releaseGlobally(); defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = AppSettings(defaults: defaults)
        settings.hasOnboarded = true
        let clipboard = SystemClipboard(pasteboard: board)
        let permissions = RecognitionHistoryPermissions()
        let store = try HistoryStore(directory: directory)
        let monitor = ClipboardMonitor(clipboard: clipboard, repository: store, settings: settings,
            permissions: permissions, sourceApplication: { ("other.frontmost", "其他应用") })
        settings.onRecordingChanged = { monitor.recordingStateChanged() }
        #expect(clipboard.write(.text("已编辑的识别文字")))
        monitor.ignoreOwnWrite()
        let ticket = try #require(monitor.screenshotTicket(sourceID: "original.app"))
        try await monitor.recordRecognizedText("已编辑的识别文字", sourceID: "original.app", sourceName: "原始应用", ticket: ticket)
        await monitor.poll()
        let entries = try await store.list()
        #expect(entries.count == 1 && entries.first?.kind == .text)
        #expect(entries.first?.sourceBundleID == "original.app" && entries.first?.sourceName == "原始应用")
        if case .text(let text) = try await store.content(for: #require(entries.first)) { #expect(text == "已编辑的识别文字") }
        else { Issue.record("识别结果未保存为文字") }
        settings.paused = true
        #expect(monitor.screenshotTicket(sourceID: "original.app") == nil)
        settings.paused = false
        try await monitor.recordRecognizedText("旧票据的文字", sourceID: "original.app", sourceName: "原始应用", ticket: ticket)
        #expect(try await store.list().count == 1)
        settings.excludedApps.insert("original.app")
        #expect(monitor.screenshotTicket(sourceID: "original.app") == nil)
        settings.excludedApps.remove("original.app")
        permissions.allowsMonitoring = false
        #expect(monitor.screenshotTicket(sourceID: "original.app") == nil)
        permissions.allowsMonitoring = true
        settings.clipboardEnabled = false
        #expect(clipboard.write(.text("关闭记录仍可复制")))
        monitor.ignoreOwnWrite()
        #expect(board.string(forType: .string) == "关闭记录仍可复制")
        #expect(monitor.screenshotTicket(sourceID: "original.app") == nil)
        #expect(try await store.list().count == 1)
    }
}
