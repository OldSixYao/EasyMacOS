import AppKit
import Testing

@testable import PasteMan

@MainActor private final class HiddenFilesFixture {
    var permission = true
    var state = FinderMoveSnapshot(frontBundleID: "com.apple.finder", blocked: false, modifiersReleased: true)
    var elapsed: Duration = .zero
    var sends = 0
    var reads = 0
    var sendResult = true
    var onPause: (() -> Void)?
    var onRead: (() -> Void)?

    func run() async throws {
        try await FinderHiddenFilesCoordinator(environment: FinderHiddenFilesEnvironment(
            trusted: { self.permission },
            snapshot: { self.reads += 1; self.onRead?(); return self.state },
            sendToggle: { _ in self.sends += 1; return self.sendResult }, now: { self.elapsed },
            pause: { self.elapsed += .milliseconds(50); self.onPause?() })).toggle()
    }
}

@Suite("访达隐藏文件切换", .serialized) @MainActor struct FinderHiddenFilesTests {
    @Test func safeFinderAndDesktopSendOnce() async throws {
        let fixture = HiddenFilesFixture()
        try await fixture.run()
        #expect(fixture.sends == 1)
        #expect(fixture.elapsed >= .milliseconds(50))
    }

    @Test func deniedPermissionDoesNotInspectOrSend() async {
        let fixture = HiddenFilesFixture()
        fixture.permission = false
        await #expect(throws: FinderHiddenFilesError.permissionRequired) { try await fixture.run() }
        #expect(fixture.reads == 0)
        #expect(fixture.sends == 0)
    }

    @Test func menuDismissalAndHeldModifiersWaitUntilReady() async throws {
        let fixture = HiddenFilesFixture()
        fixture.state.waitingForContext = true
        fixture.state.blocked = true
        fixture.state.modifiersReleased = false
        fixture.onPause = {
            fixture.state.waitingForContext = false
            fixture.state.blocked = false
            if fixture.elapsed >= .milliseconds(100) { fixture.state.modifiersReleased = true }
        }
        try await fixture.run()
        #expect(fixture.sends == 1)
        #expect(fixture.elapsed >= .milliseconds(100))
    }

    @Test(arguments: [0, 1, 2, 3]) func changedContextAndTimeoutNeverSend(_ mode: Int) async {
        let fixture = HiddenFilesFixture()
        fixture.state.modifiersReleased = false
        fixture.onPause = {
            switch mode {
            case 0: fixture.state.frontBundleID = "com.apple.TextEdit"
            case 1: fixture.permission = false
            case 2: fixture.state.blocked = true
            default: break
            }
        }
        await #expect(throws: (any Error).self) { try await fixture.run() }
        #expect(fixture.sends == 0)
        if mode == 3 { #expect(fixture.elapsed == .seconds(2)) }
    }

    @Test(arguments: [0, 1, 2]) func finalSnapshotMustStillBeSafe(_ mode: Int) async {
        let fixture = HiddenFilesFixture()
        fixture.onRead = {
            guard fixture.reads == 2 else { return }
            switch mode {
            case 0: fixture.state.frontBundleID = "com.apple.TextEdit"
            case 1: fixture.state.blocked = true
            default: fixture.elapsed = .seconds(2)
            }
        }
        await #expect(throws: FinderHiddenFilesError.unsafeFinder) { try await fixture.run() }
        #expect(fixture.sends == 0)
    }

    @Test func failedSendDoesNotRetryOrToggleTwice() async {
        let fixture = HiddenFilesFixture()
        fixture.sendResult = false
        await #expect(throws: FinderHiddenFilesError.unsafeFinder) { try await fixture.run() }
        #expect(fixture.sends == 1)
    }

    @Test func cancellationNeverSends() async {
        let fixture = HiddenFilesFixture()
        let task = Task { try await fixture.run() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fixture.sends == 0)
    }

    @Test func menuReappearingDuringFinalInspectionWaitsAndSendsOnce() async throws {
        let fixture = HiddenFilesFixture()
        fixture.onRead = {
            if fixture.reads == 2 { fixture.state.waitingForContext = true }
        }
        fixture.onPause = {
            if fixture.reads >= 2 { fixture.state.waitingForContext = false }
        }
        try await fixture.run()
        #expect(fixture.sends == 1)
        #expect(fixture.elapsed >= .milliseconds(100))
    }

    @Test func modifiersPressedDuringFinalInspectionAreReleasedBeforeSending() async throws {
        let fixture = HiddenFilesFixture()
        fixture.onRead = {
            if fixture.reads == 2 { fixture.state.modifiersReleased = false }
        }
        fixture.onPause = {
            if fixture.reads >= 2 { fixture.state.modifiersReleased = true }
        }
        try await fixture.run()
        #expect(fixture.sends == 1)
        #expect(fixture.elapsed >= .milliseconds(100))
    }
}
