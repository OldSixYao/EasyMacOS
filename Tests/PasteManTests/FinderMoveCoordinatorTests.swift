import AppKit
import FinderMenuCore
import Testing

@testable import PasteMan

@MainActor private final class MoveFixture {
    let directory = URL(fileURLWithPath: "/tmp/目标", isDirectory: true)
    var permission = true
    var state: FinderMoveSnapshot
    var elapsed: Duration = .zero
    var opens = 0
    var sends = 0
    var consumed = 0
    var restored = 0
    var valid = true
    var sendResult = true
    var onPause: (() -> Void)?
    var onConsume: (() -> Void)?
    var beforeSend: (() -> Void)?

    init() {
        state = FinderMoveSnapshot(frontBundleID: "com.apple.finder", directory: directory, blocked: false, modifiersReleased: true)
    }

    func coordinator() -> FinderMoveCoordinator {
        FinderMoveCoordinator(environment: FinderMoveEnvironment(
            trusted: { self.permission }, snapshot: { self.state },
            openDirectory: { _ in self.opens += 1 },
            sendMove: { _, _, check in self.beforeSend?(); try check(); self.sends += 1; return self.sendResult }, now: { self.elapsed },
            pause: { self.elapsed += .milliseconds(50); self.onPause?() }))
    }

    func run() async throws {
        try await coordinator().dispatch(
            to: directory,
            validate: { if !self.valid { throw FinderMoveError.expiredCut } },
            consume: { self.consumed += 1; self.onConsume?() }, restore: { self.restored += 1 },
            validateConsumed: { if !self.valid { throw FinderMoveError.expiredCut } })
    }
}

@Suite("访达原生移动保护", .serialized) @MainActor struct FinderMoveCoordinatorTests {
    @Test func realFinderMovesSyntheticSelectionAndCanUndo() async throws {
        guard ProcessInfo.processInfo.environment["EASYMACOS_FINDER_MOVE_LIVE"] == "1" else { return }
        try #require(FinderRenameAccess.isGranted)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FinderMove-" + UUID().uuidString)
        let source = root.appendingPathComponent("源目录", isDirectory: true)
        let target = root.appendingPathComponent("目标目录", isDirectory: true)
        for directory in [source, target] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let file = source.appendingPathComponent("中文 空格 ' &$.txt")
        let folder = source.appendingPathComponent("多选文件夹", isDirectory: true)
        try Data("必须保留的合成内容".utf8).write(to: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let clipboard = FinderCutClipboard(store: FinderCutStateStore(url: root.appendingPathComponent("state.json")))
        let state = try clipboard.cut([file, folder])
        NSWorkspace.shared.open(target)
        for _ in 0..<100 {
            if FinderMoveSystem.snapshot().matches(target) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let context = FinderMoveSystem.snapshot()
        try #require(context.matches(target), "目录：\(String(describing: context.directory))，阻塞：\(context.blocked)")
        try await FinderMoveCoordinator().move(token: state.token, to: target, clipboard: clipboard)
        let moved = target.appendingPathComponent(file.lastPathComponent)
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: moved.path), !FileManager.default.fileExists(atPath: file.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent(folder.lastPathComponent).path))
        #expect(try String(contentsOf: moved, encoding: .utf8) == "必须保留的合成内容")
        #expect(try clipboard.store.load()?.consumed == true)
        try #require(FinderMoveSystem.snapshot().matches(target))
        let front = try #require(NSWorkspace.shared.frontmostApplication)
        let down = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 6, keyDown: true))
        let up = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 6, keyDown: false))
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(front.processIdentifier)
        up.postToPid(front.processIdentifier)
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: file.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "必须保留的合成内容")
        #expect(FileManager.default.fileExists(atPath: folder.path))

        try Data("同名目标原内容".utf8).write(to: moved)
        let conflictState = try clipboard.cut([file])
        try await FinderMoveCoordinator().move(token: conflictState.token, to: target, clipboard: clipboard)
        let finderAX = AXUIElementCreateApplication(front.processIdentifier)
        func cancelButton(_ node: AXUIElement, depth: Int = 0) -> AXUIElement? {
            guard depth < 10 else { return nil }
            let role = FinderRenameSystem.attribute(node, kAXRoleAttribute) as? String
            if role == kAXButtonRole,
                let title = FinderRenameSystem.attribute(node, kAXTitleAttribute) as? String,
                ["停止", "取消", "Stop", "Cancel"].contains(title) { return node }
            guard role != kAXOutlineRole, role != kAXTableRole else { return nil }
            for child in FinderRenameSystem.attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                if let button = cancelButton(child, depth: depth + 1) { return button }
            }
            return nil
        }
        var stop: AXUIElement?
        for _ in 0..<100 {
            if let focused = FinderRenameSystem.attribute(finderAX, kAXFocusedWindowAttribute),
                CFGetTypeID(focused) == AXUIElementGetTypeID() {
                stop = cancelButton(unsafeDowncast(focused, to: AXUIElement.self))
            }
            if stop != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let stopButton = try #require(stop, "必须观察到原生重名冲突，不能自动覆盖")
        #expect(FinderMoveSystem.snapshot().blocked)
        #expect(AXUIElementPerformAction(stopButton, kAXPressAction as CFString) == .success)
        try await Task.sleep(for: .milliseconds(150))
        #expect(try String(contentsOf: file, encoding: .utf8) == "必须保留的合成内容")
        #expect(try String(contentsOf: moved, encoding: .utf8) == "同名目标原内容")

        if let volume = ProcessInfo.processInfo.environment["EASYMACOS_MOVE_VOLUME"] {
            let base = URL(fileURLWithPath: volume, isDirectory: true).resolvingSymlinksInPath()
            try #require(base.path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path))
            let cross = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: cross, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: cross) }
            let crossState = try clipboard.cut([file])
            try await FinderMoveCoordinator().move(token: crossState.token, to: cross, clipboard: clipboard)
            let crossFile = cross.appendingPathComponent(file.lastPathComponent)
            for _ in 0..<100 {
                if FileManager.default.fileExists(atPath: crossFile.path), !FileManager.default.fileExists(atPath: file.path) { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(try String(contentsOf: crossFile, encoding: .utf8) == "必须保留的合成内容")
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func matchingDirectoryConsumesAndSendsExactlyOnce() async throws {
        let fixture = MoveFixture()
        try await fixture.run()
        #expect(fixture.opens == 0)
        #expect(fixture.sends == 1)
        #expect(fixture.consumed == 1)
        #expect(fixture.restored == 0)
    }

    @Test(arguments: [0, 1, 2, 3]) func unsafeInitialContextNeverSends(_ mode: Int) async {
        let fixture = MoveFixture()
        switch mode {
        case 0: fixture.permission = false
        case 1: fixture.state.frontBundleID = "com.apple.TextEdit"
        case 2: fixture.state.blocked = true
        default: fixture.valid = false
        }
        await #expect(throws: (any Error).self) { try await fixture.run() }
        #expect(fixture.sends == 0)
        #expect(fixture.consumed == 0)
    }

    @Test func opensDestinationOnlyOnceAndWaitsForReleasedModifiers() async throws {
        let fixture = MoveFixture()
        fixture.state.directory = URL(fileURLWithPath: "/tmp/其他")
        fixture.state.modifiersReleased = false
        fixture.onPause = {
            fixture.state.directory = fixture.directory
            if fixture.elapsed >= .milliseconds(100) { fixture.state.modifiersReleased = true }
        }
        try await fixture.run()
        #expect(fixture.opens == 1)
        #expect(fixture.sends == 1)
        #expect(fixture.elapsed == .milliseconds(100))
    }

    @Test(arguments: [0, 1, 2, 3, 4]) func contextChangesWhileWaitingDoNotSend(_ mode: Int) async {
        let fixture = MoveFixture()
        fixture.state.modifiersReleased = false
        fixture.onPause = {
            switch mode {
            case 0: fixture.state.frontBundleID = "com.apple.TextEdit"
            case 1: fixture.permission = false
            case 2: fixture.valid = false
            case 3: fixture.state.blocked = true
            default: break
            }
        }
        await #expect(throws: (any Error).self) { try await fixture.run() }
        #expect(fixture.sends == 0)
        #expect(fixture.consumed == 0)
        if mode == 4 { #expect(fixture.elapsed == .seconds(2)) }
    }

    @Test(arguments: [0, 1, 2, 3, 4]) func finalChangesRestoreRecordWithoutWrongKeystroke(_ mode: Int) async {
        let fixture = MoveFixture()
        fixture.onConsume = {
            switch mode {
            case 0: fixture.valid = false
            case 1: fixture.state.directory = URL(fileURLWithPath: "/tmp/其他")
            case 2: fixture.state.blocked = true
            case 3: fixture.permission = false
            default: fixture.elapsed = .seconds(2)
            }
        }
        await #expect(throws: (any Error).self) { try await fixture.run() }
        #expect(fixture.consumed == 1)
        #expect(fixture.sends == 0)
        #expect(fixture.restored == 1)
    }

    @Test func unsuccessfulSendRestoresCutForRetry() async {
        let fixture = MoveFixture()
        fixture.sendResult = false
        await #expect(throws: FinderMoveError.unsafeFinder) { try await fixture.run() }
        #expect(fixture.sends == 1)
        #expect(fixture.restored == 1)
    }

    @Test func menuDismissalTransitionWaitsWithoutReopeningMatchingDirectory() async throws {
        let fixture = MoveFixture()
        fixture.state.waitingForContext = true
        fixture.state.blocked = true
        fixture.onPause = {
            fixture.state.waitingForContext = false
            fixture.state.blocked = false
        }
        try await fixture.run()
        #expect(fixture.sends == 1)
        #expect(fixture.opens == 0)
    }

    @Test func matchingDirectoryWithHeldModifierWaitsWithoutOpeningWindow() async throws {
        let fixture = MoveFixture()
        fixture.state.modifiersReleased = false
        fixture.onPause = { fixture.state.modifiersReleased = true }
        try await fixture.run()
        #expect(fixture.sends == 1)
        #expect(fixture.opens == 0)
    }

    @Test func clipboardChangedDuringFinalSystemInspectionNeverSends() async {
        let fixture = MoveFixture()
        fixture.beforeSend = { fixture.valid = false }
        await #expect(throws: FinderMoveError.expiredCut) { try await fixture.run() }
        #expect(fixture.sends == 0)
        #expect(fixture.restored == 1)
    }
}
