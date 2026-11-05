import AppKit
import ApplicationServices
import FinderMenuCore
import Testing

@testable import PasteMan

@MainActor private final class RenameFixture {
    let url = URL(fileURLWithPath: "/tmp/未命名.txt")
    var permission = true
    var elapsed: Duration = .zero
    var revealed: [URL] = []
    var sent = 0
    var hints = 0
    var failures: [FinderRenameFailure] = []
    var opensEditor = true
    var editorOpened = false
    var reads = 0
    var state = FinderRenameSnapshot(frontBundleID: "com.apple.finder", selection: nil, modifiersReleased: true)
    var onPause: (() -> Void)?
    var onRead: (() -> Void)?

    func coordinator() -> FinderRenameCoordinator {
        FinderRenameCoordinator(environment: FinderRenameEnvironment(
            trusted: { self.permission }, reveal: { self.revealed.append($0) },
            snapshot: { self.reads += 1; self.onRead?(); return self.state },
            sendReturn: { _, _ in self.sent += 1; self.editorOpened = self.opensEditor; return true },
            isEditingName: { _ in self.editorOpened },
            hint: { self.hints += 1; self.failures.append($0) },
            now: { self.elapsed }, pause: { self.elapsed += .milliseconds(50); self.onPause?() }))
    }
}

@Suite("访达原地重命名", .serialized) @MainActor struct FinderRenameTests {
    @Test func realFinderRenameWithExistingRunnerPermission() async throws {
        guard ProcessInfo.processInfo.environment["EASYMACOS_FINDER_RENAME_LIVE"] == "1" else { return }
        try #require(AXIsProcessTrusted() && CGPreflightPostEventAccess())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FinderRename-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try FinderOperations.createFile(suffix: "txt", in: root)
        let renamed = await FinderRenameCoordinator().revealAndRename(file)
        let snapshot = FinderRenameSystem.snapshot()
        try #require(renamed, "前台：\(snapshot.frontBundleID ?? "无")；选区：\(String(describing: snapshot.selection))")
        for _ in 0..<20 {
            if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == "com.apple.finder" {
                let app = AXUIElementCreateApplication(front.processIdentifier)
                if let focused = FinderRenameSystem.attribute(app, kAXFocusedUIElementAttribute),
                    CFGetTypeID(focused) == AXUIElementGetTypeID() {
                    let element = unsafeDowncast(focused, to: AXUIElement.self)
                    let value = FinderRenameSystem.attribute(element, kAXValueAttribute) as? String
                    if FinderRenameSystem.attribute(element, kAXRoleAttribute) as? String == kAXTextFieldRole,
                        value == file.lastPathComponent || value == file.deletingPathExtension().lastPathComponent {
                        CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.postToPid(front.processIdentifier)
                        CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.postToPid(front.processIdentifier)
                        #expect(FileManager.default.fileExists(atPath: file.path))
                        return
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("发送回车后未观察到合成文件的原地重命名输入框。")
    }

    @Test func existingPermissionAndUniqueSelectionSendReturnOnce() async {
        let fixture = RenameFixture()
        fixture.state.selection = [fixture.url]
        #expect(await fixture.coordinator().revealAndRename(fixture.url))
        #expect(fixture.revealed == [fixture.url])
        #expect(fixture.sent == 1)
        #expect(fixture.hints == 0)
    }

    @Test func deniedPermissionStillRevealsButDoesNotInspectOrSend() async {
        let fixture = RenameFixture()
        fixture.permission = false
        #expect(await !fixture.coordinator().revealAndRename(fixture.url))
        #expect(fixture.revealed == [fixture.url])
        #expect(fixture.failures == [.permissionRequired])
        #expect(fixture.reads == 0)
        #expect(fixture.sent == 0)
        #expect(fixture.hints == 1)
    }

    @Test(arguments: [0, 1, 2, 3]) func unconfirmedSelectionOrHeldModifiersTimesOut(_ mode: Int) async {
        let fixture = RenameFixture()
        switch mode {
        case 0: fixture.state.selection = nil
        case 1: fixture.state.selection = [URL(fileURLWithPath: "/tmp/其他.txt")]
        case 2: fixture.state.selection = [fixture.url, URL(fileURLWithPath: "/tmp/其他.txt")]
        default: fixture.state.selection = [fixture.url]; fixture.state.modifiersReleased = false
        }
        #expect(await !fixture.coordinator().revealAndRename(fixture.url))
        #expect(fixture.elapsed == .seconds(2))
        #expect(fixture.sent == 0)
        #expect(fixture.hints == 1)
        #expect(fixture.revealed.count == 1)
    }

    @Test func waitsForSelectionAndModifierRelease() async {
        let fixture = RenameFixture()
        fixture.state.modifiersReleased = false
        fixture.onPause = {
            fixture.state.selection = [fixture.url]
            if fixture.elapsed >= .milliseconds(100) { fixture.state.modifiersReleased = true }
        }
        #expect(await fixture.coordinator().revealAndRename(fixture.url))
        #expect(fixture.sent == 1)
        #expect(fixture.elapsed == .milliseconds(100))
    }

    @Test func postedReturnMustActuallyOpenNameEditor() async {
        let fixture = RenameFixture()
        fixture.state.selection = [fixture.url]
        fixture.opensEditor = false
        #expect(await !fixture.coordinator().revealAndRename(fixture.url))
        #expect(fixture.sent == 1)
        #expect(fixture.elapsed == .seconds(2))
        #expect(fixture.failures == [.selectionUnavailable])
    }

    @Test func waitsForRealNameEditorWithoutSendingAnotherKey() async {
        let fixture = RenameFixture()
        fixture.state.selection = [fixture.url]
        fixture.opensEditor = false
        fixture.onPause = {
            if fixture.elapsed >= .milliseconds(100) { fixture.editorOpened = true }
        }
        #expect(await fixture.coordinator().revealAndRename(fixture.url))
        #expect(fixture.sent == 1)
        #expect(fixture.hints == 0)
    }

    @Test func focusChangeAbortsWithoutReactivation() async {
        let fixture = RenameFixture()
        fixture.onPause = { fixture.state.frontBundleID = "com.apple.TextEdit" }
        #expect(await !fixture.coordinator().revealAndRename(fixture.url))
        #expect(fixture.sent == 0)
        #expect(fixture.revealed.count == 1)
        #expect(fixture.elapsed < .seconds(2))
    }

    @Test func lastMomentSelectionChangeOrPermissionRevocationPreventsKey() async {
        for revokePermission in [false, true] {
            let fixture = RenameFixture()
            fixture.state.selection = [fixture.url]
            fixture.onRead = {
                if fixture.reads == 2 {
                    if revokePermission { fixture.permission = false }
                    else { fixture.state.selection = [] }
                }
            }
            #expect(await !fixture.coordinator().revealAndRename(fixture.url))
            #expect(fixture.sent == 0)
        }
    }

    @Test func finalSelectionCheckCannotSendPastDeadline() async {
        let fixture = RenameFixture()
        fixture.state.selection = [fixture.url]
        fixture.onRead = {
            if fixture.reads == 2 { fixture.elapsed = .seconds(2) }
        }
        #expect(await !fixture.coordinator().revealAndRename(fixture.url))
        #expect(fixture.sent == 0)
        #expect(fixture.hints == 1)
    }

    @Test func queueWaitsForEntireAsynchronousOperation() async throws {
        let queue = FinderRequestQueue()
        let first = URL(fileURLWithPath: "/tmp/first")
        let second = URL(fileURLWithPath: "/tmp/second")
        var events: [String] = []
        var resume: CheckedContinuation<Void, Never>?
        queue.enqueue([first])
        queue.start { url in
            events.append("开始" + url.lastPathComponent)
            if url == first { await withCheckedContinuation { resume = $0 } }
            events.append("完成" + url.lastPathComponent)
        }
        for _ in 0..<100 where resume == nil { await Task.yield() }
        #expect(resume != nil)
        queue.enqueue([second])
        await Task.yield()
        #expect(events == ["开始first"])
        resume?.resume()
        for _ in 0..<100 where events.count < 4 { await Task.yield() }
        #expect(events == ["开始first", "完成first", "开始second", "完成second"])
    }
}
