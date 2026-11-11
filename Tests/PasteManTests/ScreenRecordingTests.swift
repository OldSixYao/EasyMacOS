import AppKit
import Carbon
import Foundation
import Testing
@testable import PasteMan

@MainActor private final class RecordingTestEngine: ScreenRecordingEngine {
    var onFailure: ((Error) -> Void)?
    var startContinuation: CheckedContinuation<Void, Never>?
    var stopContinuation: CheckedContinuation<Void, Never>?
    var delayedStart = false
    var delayedStop = false
    var stopCalls = 0
    var url: URL?
    var options: ScreenRecordingOptions?
    func start(target: ScreenRecordingTarget, options: ScreenRecordingOptions, url: URL) async throws {
        self.url = url
        self.options = options
        if delayedStart { await withCheckedContinuation { startContinuation = $0 } }
    }
    func stop() async throws {
        stopCalls += 1
        if delayedStop { await withCheckedContinuation { stopContinuation = $0 } }
        if let url { try Data("synthetic segment".utf8).write(to: url) }
    }
}

@MainActor private final class RecordingTestPool {
    var engines: [RecordingTestEngine] = []
    var delayedStart = false
    var delayedStop = false
    func make() -> RecordingTestEngine {
        let engine = RecordingTestEngine()
        engine.delayedStart = delayedStart
        engine.delayedStop = delayedStop
        engines.append(engine)
        return engine
    }
}

/// 复现系统枚举尚未建立录制流便失败的状态；停止沿用实际系统引擎。
@MainActor private final class EarlyFailureRecordingEngine: ScreenRecordingEngine {
    var onFailure: ((Error) -> Void)?
    private let system = SystemScreenRecordingEngine()
    func start(target: ScreenRecordingTarget, options: ScreenRecordingOptions, url: URL) async throws {
        throw ScreenRecordingError.unavailable
    }
    func stop() async throws { try await system.stop() }
}

private actor RecordingTestExporter: ScreenRecordingExporting {
    var shouldFail = false
    var calls: [[URL]] = []
    func setFailure(_ value: Bool) { shouldFail = value }
    func export(segments: [URL], directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        calls.append(segments)
        if shouldFail { throw ScreenRecordingError.outputDirectory }
        guard !segments.isEmpty else { throw ScreenRecordingError.empty }
        let url = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mp4")
        try Data("saved recording".utf8).write(to: url)
        return url
    }
}

@MainActor private final class RecordingTestClock {
    var date = Date(timeIntervalSince1970: 1000)
}

@MainActor private struct RecordingFixture {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let clock = RecordingTestClock()
    let pool = RecordingTestPool()
    let exporter = RecordingTestExporter()
    let coordinator: ScreenRecordingCoordinator
    var options: ScreenRecordingOptions { ScreenRecordingOptions(directory: root) }
    let target = ScreenRecordingTarget(displayID: 1, displayFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                      scale: 2, rect: CGRect(x: 20, y: 30, width: 640, height: 480))
    init() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenRecordingTests-" + UUID().uuidString)
        suite = "ScreenRecordingTests." + UUID().uuidString
        defaults = try #require(UserDefaults(suiteName: suite))
        let pool = pool
        let clock = clock
        coordinator = ScreenRecordingCoordinator(makeEngine: { pool.make() }, exporter: exporter, defaults: defaults,
                                                 countdownInterval: .milliseconds(1), now: { clock.date })
    }
    func start() async {
        coordinator.select(mode: .region, options: options)
        coordinator.confirm(target)
        await wait { coordinator.phase == .recording || coordinator.phase == .failed || coordinator.phase == .starting && pool.delayedStart }
    }
    func clean() {
        coordinator.cancelSelection()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor private func wait(_ predicate: () -> Bool) async {
    for _ in 0..<600 {
        if predicate() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(predicate(), "等待录屏状态超时")
}

@Suite("录屏状态与配置", .serialized) @MainActor struct ScreenRecordingTests {
    @Test func earlyStartupFailureReleasesSessionAndAllowsAnotherRecording() async throws {
        let f = try RecordingFixture(); defer { f.clean() }
        var failFirst = true
        let coordinator = ScreenRecordingCoordinator(makeEngine: {
            if failFirst { failFirst = false; return EarlyFailureRecordingEngine() }
            return f.pool.make()
        }, exporter: f.exporter, defaults: f.defaults, countdownInterval: .milliseconds(1))
        coordinator.select(mode: .region, options: f.options)
        coordinator.confirm(f.target)
        await wait { coordinator.phase == .failed }
        try #require(coordinator.phase == .failed)
        #expect(coordinator.errorMessage == ScreenRecordingError.unavailable.localizedDescription)
        #expect(coordinator.pendingRecoveries.isEmpty && coordinator.sessionDirectory == nil)
        coordinator.keepForRecovery()
        #expect(!coordinator.isActive)
        coordinator.select(mode: .region, options: f.options)
        coordinator.confirm(f.target)
        await wait { coordinator.phase == .recording }
        coordinator.stop()
        await wait { coordinator.phase == .idle }
        #expect(coordinator.savedURL != nil)
    }

    @Test func stoppingAnUnstartedSystemEngineCompletesRepeatedly() async throws {
        let engine = SystemScreenRecordingEngine()
        var completed = false
        let task = Task {
            try await engine.stop()
            try await engine.stop()
            completed = true
        }
        defer { task.cancel() }
        await wait { completed }
        try #require(completed)
        try await task.value
    }

    @Test func coordinatesRespectNegativeDisplaysScalingClippingAndEvenSize() throws {
        let frame = CGRect(x: -1600, y: -240, width: 1600, height: 1200)
        let region = try #require(ScreenRecordingTarget.region(displayID: 22, frame: frame, scale: 2,
            globalRect: CGRect(x: -1700, y: -100, width: 500, height: 400)))
        #expect(region.rect == CGRect(x: 0, y: 660, width: 400, height: 400))
        #expect(region.pixelSize == CGSize(width: 800, height: 800))
        #expect(ScreenRecordingTarget.region(displayID: 22, frame: frame, scale: 2,
            globalRect: CGRect(x: 100, y: 100, width: 100, height: 100)) == nil)
        let vertical = ScreenRecordingTarget(displayID: 1, displayFrame: frame, scale: 2,
            rect: CGRect(x: 0, y: 0, width: 1801, height: 3201))
        #expect(vertical.pixelSize.width <= 2160 && vertical.pixelSize.height <= 3840)
        #expect(Int(vertical.pixelSize.width) % 2 == 0 && Int(vertical.pixelSize.height) % 2 == 0)
        let small = ScreenRecordingTarget(displayID: 1, displayFrame: frame, scale: 1,
            rect: CGRect(x: 0, y: 0, width: 101, height: 51))
        #expect(small.pixelSize == CGSize(width: 100, height: 50))
    }

    @Test func compactControlsAndClickThroughRegionHighlightFollowRecordingLifecycle() async throws {
        let f = try RecordingFixture(); defer { f.clean() }
        let presentation = ScreenRecordingPresentation(coordinator: f.coordinator)
        defer { presentation.dismissSelection(); presentation.closeControls() }
        await f.start()
        let controls = try #require(presentation.controls)
        #expect(controls.frame.size == CGSize(width: 244, height: 44))
        #expect(!controls.styleMask.contains(.titled) && controls.isMovableByWindowBackground)
        let highlight = try #require(presentation.regionHighlight)
        let region = CGRect(x: f.target.displayFrame.minX + f.target.rect.minX,
                            y: f.target.displayFrame.maxY - f.target.rect.maxY,
                            width: f.target.rect.width, height: f.target.rect.height)
        #expect(highlight.frame == region)
        #expect(highlight.ignoresMouseEvents && !highlight.isOpaque && !highlight.canBecomeKey)
        #expect(!controls.frame.intersects(region))
        #expect(highlight.isVisible && !(highlight.contentView as! RecordingRegionHighlight).paused)
        let moved = controls.frame.offsetBy(dx: 30, dy: -20)
        controls.setFrame(moved, display: false)
        f.coordinator.togglePause()
        await wait { f.coordinator.phase == .paused }
        #expect(presentation.regionHighlight === highlight && highlight.isVisible)
        #expect((highlight.contentView as! RecordingRegionHighlight).paused)
        #expect(controls.frame == moved)
        f.coordinator.togglePause()
        await wait { f.coordinator.phase == .recording }
        #expect(!(highlight.contentView as! RecordingRegionHighlight).paused)
        f.coordinator.stop()
        await wait { f.coordinator.phase == .idle }
        #expect(presentation.regionHighlight == nil && !highlight.isVisible)
        #expect(presentation.controls?.frame.size == CGSize(width: 350, height: 96))

        f.coordinator.select(mode: .fullScreen, options: f.options)
        f.coordinator.confirm(f.target)
        await wait { f.coordinator.phase == .recording }
        #expect(presentation.regionHighlight?.frame == region)
        #expect(presentation.regionHighlight?.ignoresMouseEvents == true)
        #expect(presentation.controls?.frame.size == CGSize(width: 244, height: 44))
        f.coordinator.stop()
        await wait { f.coordinator.phase == .idle }
    }

    @Test func selectionCanMoveResizeAndKeepsToolbarNearItsBoundsUntilConfirmation() throws {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700), styleMask: .borderless,
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let view = RecordingSelectionView(frame: CGRect(x: 0, y: 0, width: 900, height: 700), mode: .region)
        panel.contentView = view
        defer { panel.close() }
        view.claim = { true }
        var confirmed: CGRect?
        view.onConfirm = { confirmed = $0 }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: point.x, y: 700 - point.y),
                modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
        }
        func drag(_ from: CGPoint, _ to: CGPoint) throws {
            view.mouseDown(with: try event(.leftMouseDown, from))
            view.mouseDragged(with: try event(.leftMouseDragged, to))
            #expect(view.selectionToolbar.isHidden)
            view.mouseUp(with: try event(.leftMouseUp, to))
            #expect(!view.selectionToolbar.isHidden && confirmed == nil)
        }
        #expect(view.selectionToolbar.isHidden)
        try drag(CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 350))
        #expect(view.selection == CGRect(x: 100, y: 100, width: 400, height: 250))
        #expect(view.selectionToolbar.frame.minY == view.selection.maxY + 10)
        #expect(view.selectionToolbar.frame.maxX == view.selection.maxX)
        try drag(CGPoint(x: 250, y: 200), CGPoint(x: 300, y: 250))
        #expect(view.selection == CGRect(x: 150, y: 150, width: 400, height: 250))
        try drag(CGPoint(x: 550, y: 400), CGPoint(x: 650, y: 500))
        #expect(view.selection == CGRect(x: 150, y: 150, width: 500, height: 350))
        try drag(CGPoint(x: 400, y: 150), CGPoint(x: 400, y: 80))
        #expect(view.selection == CGRect(x: 150, y: 80, width: 500, height: 420))
        try drag(CGPoint(x: 300, y: 300), CGPoint(x: 1000, y: 1000))
        #expect(view.selection.maxX == 900 && view.selection.maxY == 700)
        #expect(view.selectionToolbar.frame.maxY < view.selection.minY)
        #expect(view.bounds.contains(view.selectionToolbar.frame))
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        view.keyDown(with: key)
        #expect(confirmed == view.selection)
        view.resetSelection()
        #expect(view.selectionToolbar.isHidden)
    }

    @Test func pointerChangesAcrossSelectionEdgesOutsideToolbarAndButtons() throws {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700), styleMask: .borderless,
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let view = RecordingSelectionView(frame: CGRect(x: 0, y: 0, width: 900, height: 700), mode: .region)
        panel.contentView = view
        view.claim = { true }
        defer { view.dispose(); panel.close(); NSCursor.arrow.set() }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: point.x, y: 700 - point.y),
                modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
        }
        #expect(view.pointerCursor(at: CGPoint(x: 50, y: 50)) === NSCursor.crosshair)
        view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 100, y: 100)))
        view.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 500, y: 350)))
        view.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 500, y: 350)))
        view.updateTrackingAreas()
        #expect(view.trackingAreas.contains { $0.options.contains(.mouseMoved) && $0.options.contains(.mouseEnteredAndExited) })
        let middle = CGPoint(x: 300, y: 200), outside = CGPoint(x: 50, y: 50)
        view.mouseMoved(with: try event(.mouseMoved, middle))
        #expect(NSCursor.current === NSCursor.openHand)
        view.mouseMoved(with: try event(.mouseMoved, outside))
        #expect(NSCursor.current === NSCursor.arrow)
        view.mouseMoved(with: try event(.mouseMoved, CGPoint(x: 100, y: 200)))
        #expect(NSCursor.current === NSCursor.resizeLeftRight)
        view.mouseMoved(with: try event(.mouseMoved, CGPoint(x: 300, y: 100)))
        #expect(NSCursor.current === NSCursor.resizeUpDown)
        #expect(view.pointerCursor(at: CGPoint(x: 100, y: 100)) !== NSCursor.crosshair)
        for button in view.selectionButtons {
            let point = view.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
            view.mouseMoved(with: try event(.mouseMoved, point))
            #expect(NSCursor.current === NSCursor.pointingHand && button.hovered)
            #expect(view.selectionButtons.filter { $0.hovered }.count == 1)
            #expect(button.toolTip == button.title)
            view.mouseMoved(with: try event(.mouseMoved, outside))
            #expect(NSCursor.current === NSCursor.arrow && view.selectionButtons.allSatisfy { !$0.hovered })
        }
        view.mouseMoved(with: try event(.mouseMoved, CGPoint(x: view.selectionToolbar.frame.minX + 2, y: view.selectionToolbar.frame.midY)))
        #expect(NSCursor.current === NSCursor.arrow)
        view.mouseDown(with: try event(.leftMouseDown, middle))
        #expect(view.pointerCursor(at: middle) === NSCursor.closedHand)
        view.mouseUp(with: try event(.leftMouseUp, middle))
        #expect(NSCursor.current === NSCursor.openHand)
        view.mouseExited(with: try event(.mouseMoved, outside))
        #expect(NSCursor.current === NSCursor.arrow)
        view.resetSelection()
        #expect(view.selectionButtons.allSatisfy { !$0.hovered })
    }

    @Test func narrowAndSmallSelectionsCanRefreshCursorRectsWithoutCrashing() throws {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700), styleMask: .borderless,
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let view = RecordingSelectionView(frame: CGRect(x: 0, y: 0, width: 900, height: 700), mode: .region)
        panel.contentView = view
        view.claim = { true }
        defer { panel.close() }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: point.x, y: 700 - point.y),
                modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
        }
        for size in [CGSize(width: 1, height: 1), CGSize(width: 8, height: 12), CGSize(width: 15, height: 100),
                     CGSize(width: 100, height: 15), CGSize(width: 16, height: 16), CGSize(width: 40, height: 40)] {
            view.resetSelection()
            view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 100, y: 100)))
            view.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 100 + size.width, y: 100 + size.height)))
            // 用户缓慢拖动时，系统会在选区还很窄的中间帧更新光标区域。
            view.discardCursorRects()
            view.resetCursorRects()
            view.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 100 + size.width, y: 100 + size.height)))
            view.discardCursorRects()
            view.resetCursorRects()
            #expect(view.selection.size == size)
        }
    }

    @Test func fullScreenSelectionWaitsForExplicitStartAndKeepsToolbarInsideDisplay() throws {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700), styleMask: .borderless,
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let view = RecordingSelectionView(frame: CGRect(x: 0, y: 0, width: 900, height: 700), mode: .fullScreen)
        panel.contentView = view
        defer { panel.close() }
        view.claim = { true }
        var confirmed = false
        view.onConfirm = { _ in confirmed = true }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: 300, y: 300),
                modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
        #expect(!confirmed && view.selection == view.bounds && !view.selectionToolbar.isHidden)
        #expect(view.bounds.contains(view.selectionToolbar.frame))
    }

    @Test func countdownCancellationRemovesRegionHighlightAndControls() throws {
        let f = try RecordingFixture(); defer { f.clean() }
        let presentation = ScreenRecordingPresentation(coordinator: f.coordinator)
        defer { presentation.dismissSelection(); presentation.closeControls() }
        f.coordinator.select(mode: .region, options: f.options)
        f.coordinator.confirm(f.target)
        #expect(presentation.regionHighlight?.isVisible == true)
        #expect(presentation.controls?.frame.size == CGSize(width: 244, height: 44))
        f.coordinator.cancelSelection()
        #expect(presentation.regionHighlight == nil && presentation.controls == nil)
    }

    @Test func controlsPlacementAvoidsRegionAndStaysOnNegativeCoordinateDisplay() {
        let visible = CGRect(x: -1600, y: -240, width: 1600, height: 1160)
        let region = CGRect(x: -1500, y: 500, width: 800, height: 400)
        let frame = ScreenRecordingPresentation.controlsFrame(size: CGSize(width: 244, height: 44), visible: visible, region: region)
        #expect(visible.contains(frame) && !frame.intersects(region))
        let fallback = ScreenRecordingPresentation.controlsFrame(size: CGSize(width: 244, height: 44), visible: visible, region: visible)
        #expect(visible.contains(fallback))
    }

    @Test func defaultsPersistAndAllShortcutActionsRemainIndependent() throws {
        let f = try RecordingFixture(); defer { f.clean() }
        let settings = AppSettings(defaults: f.defaults)
        #expect(settings.screenRecordingEnabled)
        #expect(!settings.screenRecordingOptions.systemAudio && !settings.screenRecordingOptions.microphone)
        #expect(settings.shortcut(for: .recordFullScreen).label == "⌃⌥R")
        #expect(settings.shortcut(for: .recordRegion).label == "⌃⌥⇧R")
        #expect(settings.shortcut(for: .recordPause).label == "⌃⌥P")
        #expect(settings.shortcut(for: .recordStop).label == "⌃⌥S")
        settings.screenRecordingEnabled = false
        settings.screenRecordingOptions = ScreenRecordingOptions(systemAudio: true, microphone: true, directory: f.root)
        settings.setShortcut(Shortcut(keyCode: UInt32(kVK_F18), modifiers: UInt32(controlKey | optionKey), keyLabel: "F18"), for: .recordStop)
        let restored = AppSettings(defaults: f.defaults)
        #expect(!restored.screenRecordingEnabled && restored.screenshotEnabled && restored.clipboardEnabled)
        #expect(restored.screenRecordingOptions == settings.screenRecordingOptions)
        #expect(restored.shortcut(for: .recordStop).label == "⌃⌥F18")
        #expect(restored.shortcut(for: .screenshot) == .screenshot)
    }

    @Test func recordingQualityMigratesOldOptionsWithoutResettingAudioOrDestination() throws {
        let f = try RecordingFixture(); defer { f.clean() }
        let legacy = try JSONSerialization.data(withJSONObject: [
            "systemAudio": true, "microphone": true, "directory": f.root.absoluteString,
        ])
        f.defaults.set(legacy, forKey: "screenRecordingOptions")
        let settings = AppSettings(defaults: f.defaults)
        #expect(settings.screenRecordingOptions.quality == .standard)
        #expect(settings.screenRecordingOptions.systemAudio && settings.screenRecordingOptions.microphone)
        #expect(settings.screenRecordingOptions.directory == f.root)
        settings.screenRecordingOptions.quality = .lightweight
        #expect(AppSettings(defaults: f.defaults).screenRecordingOptions == settings.screenRecordingOptions)
        let target = ScreenRecordingTarget(displayID: 1, displayFrame: .zero, scale: 2,
            rect: CGRect(x: 0, y: 0, width: 3000, height: 2000))
        let light = target.pixelSize(for: .lightweight)
        #expect(light.width <= 1920 && light.height <= 1080)
        #expect(Int(light.width) % 2 == 0 && Int(light.height) % 2 == 0)
        #expect(ScreenRecordingQuality.lightweight.framesPerSecond == 15)
        #expect(target.pixelSize == target.pixelSize(for: .standard))
        let config = SystemScreenRecordingEngine.configuration(target: target,
            options: ScreenRecordingOptions(quality: .lightweight))
        #expect(config.width == Int(light.width) && config.height == Int(light.height))
        #expect(config.queueDepth == 6 && config.minimumFrameInterval.timescale == 15)
        #expect(config.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }

    @Test func cancellationDuringValidationCannotStartALateSession() async throws {
        let f = try RecordingFixture(); defer { f.clean() }
        var approval: CheckedContinuation<Void, Never>?
        f.coordinator.validateAccess = { _ in await withCheckedContinuation { approval = $0 } }
        f.coordinator.select(mode: .fullScreen, options: f.options)
        f.coordinator.confirm(f.target)
        await wait { approval != nil }
        f.coordinator.cancelSelection()
        #expect(f.coordinator.phase == .idle)
        approval?.resume()
        try await Task.sleep(for: .milliseconds(30))
        #expect(f.pool.engines.isEmpty && f.coordinator.pendingRecoveries.isEmpty)
    }

    @Test func pauseResumeKeepsOptionsAndExcludesPausedTimeThenSavesAllSegments() async throws {
        let f = try RecordingFixture(); defer { f.clean() }
        var options = f.options
        options.systemAudio = true
        options.microphone = true
        f.coordinator.select(mode: .region, options: options)
        f.coordinator.confirm(f.target)
        await wait { f.coordinator.phase == .recording }
        f.coordinator.select(mode: .fullScreen, options: f.options)
        #expect(f.pool.engines.count == 1)
        f.clock.date += 1
        let oldSegmentCallback = f.pool.engines[0].onFailure
        f.coordinator.togglePause()
        await wait { f.coordinator.phase == .paused }
        let paused = f.coordinator.elapsed
        f.clock.date += 20
        #expect(f.coordinator.elapsed == paused)
        f.coordinator.togglePause()
        await wait { f.coordinator.phase == .recording }
        #expect(f.pool.engines.count == 2)
        oldSegmentCallback?(ScreenRecordingError.interrupted)
        #expect(f.coordinator.phase == .recording)
        #expect(f.pool.engines.allSatisfy { $0.options == options })
        f.clock.date += 2
        f.coordinator.togglePause()
        await wait { f.coordinator.phase == .paused }
        f.coordinator.stop()
        await wait { f.coordinator.phase == .idle }
        let calls = await f.exporter.calls
        #expect(calls.count == 1 && calls[0].count == 2)
        #expect(f.pool.engines.allSatisfy { $0.stopCalls == 1 })
        #expect(f.coordinator.savedURL != nil && f.coordinator.pendingRecoveries.isEmpty)
        #expect(f.coordinator.elapsed == 3)
    }

    @Test func stopDuringStartingAndPausingWaitsForTheActiveOperation() async throws {
        let f = try RecordingFixture(); defer { f.clean() }
        f.pool.delayedStart = true
        f.pool.delayedStop = true
        await f.start()
        await wait { f.pool.engines.first?.startContinuation != nil }
        f.coordinator.stop()
        f.pool.engines[0].startContinuation?.resume()
        await wait { f.pool.engines[0].stopContinuation != nil }
        #expect(f.coordinator.phase == .stopping)
        f.coordinator.stop()
        f.pool.engines[0].stopContinuation?.resume()
        await wait { f.coordinator.phase == .idle }
        #expect(f.pool.engines[0].stopCalls == 1)

        f.pool.delayedStart = false
        await f.start()
        f.coordinator.togglePause()
        await wait { f.pool.engines[1].stopContinuation != nil }
        f.coordinator.stop()
        f.pool.engines[1].stopContinuation?.resume()
        await wait { f.coordinator.phase == .idle }
        #expect(f.pool.engines[1].stopCalls == 1)
    }

    @Test func failedExportPreservesSegmentsAndCanRecoverAfterRestart() async throws {
        let f = try RecordingFixture(); defer { f.clean() }
        await f.exporter.setFailure(true)
        await f.start()
        f.coordinator.stop()
        await wait { f.coordinator.phase == .failed }
        let directory = try #require(f.coordinator.sessionDirectory)
        #expect(f.coordinator.segments.count == 1)
        #expect(FileManager.default.fileExists(atPath: f.coordinator.segments[0].path))
        f.coordinator.keepForRecovery()
        #expect(f.coordinator.phase == .idle && f.coordinator.pendingRecoveries == [directory])
        let restored = ScreenRecordingCoordinator(exporter: f.exporter, defaults: f.defaults)
        restored.recover(directory)
        #expect(restored.phase == .failed && restored.segments.count == 1)
        await f.exporter.setFailure(false)
        restored.retrySave()
        restored.retrySave()
        await wait { restored.phase == .idle }
        #expect(restored.savedURL != nil && restored.pendingRecoveries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func emptyRecoveryFromInterruptedCountdownIsCleared() async throws {
        let f = try RecordingFixture(); defer { f.clean() }
        let directory = f.root.appendingPathComponent(".easymacos-recording-empty")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        f.defaults.set([directory.path], forKey: "screenRecordingRecoveries")
        f.coordinator.recover(directory)
        #expect(f.coordinator.phase == .idle && f.coordinator.pendingRecoveries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func invalidDirectoryAndDeniedPermissionDoNotCapture() async throws {
        let f = try RecordingFixture(); defer { f.clean() }
        f.coordinator.validateAccess = { _ in throw ScreenRecordingError.unavailable }
        await f.start()
        #expect(f.coordinator.phase == .failed && f.pool.engines.isEmpty)
        f.coordinator.keepForRecovery()
        f.coordinator.validateAccess = nil
        try Data("file".utf8).write(to: f.root)
        await f.start()
        #expect(f.coordinator.phase == .failed && f.pool.engines.isEmpty)
        #expect(f.coordinator.pendingRecoveries.isEmpty)
        f.coordinator.keepForRecovery()
    }

    @Test func streamFailureStillFinalizesRecordedDataAndIgnoresOldCallbacks() async throws {
        let f = try RecordingFixture(); defer { f.clean() }
        await f.start()
        let oldCallback = f.pool.engines[0].onFailure
        oldCallback?(ScreenRecordingError.interrupted)
        await wait { f.coordinator.phase == .idle }
        #expect(f.coordinator.savedURL != nil && f.coordinator.errorMessage != nil)
        await f.start()
        oldCallback?(ScreenRecordingError.interrupted)
        #expect(f.coordinator.phase == .recording)
        f.coordinator.stop()
        await wait { f.coordinator.phase == .idle }
    }
}
