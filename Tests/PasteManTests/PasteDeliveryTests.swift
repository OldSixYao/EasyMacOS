import AppKit
import Foundation
import PasteManCore
import SwiftUI
import Testing

@testable import PasteMan

@Suite("Paste delivery", .serialized) @MainActor struct PasteDeliveryTests {
    /// Opt in to an interactive test with a separate, disposable text-field app.
    /// The receiver inserts a synthetic token on Cmd-V, without accessing the clipboard.
    @Test func deliversPasteAfterHistoryPanelReleasesFocus() async throws {
        guard ProcessInfo.processInfo.environment["PASTEMAN_PASTE_TESTS"] == "1" else { return }
        try #require(
            CGPreflightPostEventAccess(), "Existing event-posting permission required; no prompt is requested.")
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PasteDelivery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ready = directory.appendingPathComponent("ready")
        let result = directory.appendingPathComponent("result")
        let token = "PasteMan synthetic " + UUID().uuidString
        let receiver = Process()
        receiver.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/paste-recipient.swift")
        receiver.arguments = [script.path, ready.path, result.path, token]
        let errors = Pipe()
        receiver.standardError = errors
        try receiver.run()
        let panel = HistoryPanel()
        defer {
            panel.close()
            if receiver.isRunning { receiver.terminate() }
            try? FileManager.default.removeItem(at: directory)
        }
        for _ in 0..<250 {
            if FileManager.default.fileExists(atPath: ready.path) || !receiver.isRunning { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(FileManager.default.fileExists(atPath: ready.path), "Synthetic receiver failed to launch.")
        let target = try #require(NSRunningApplication(processIdentifier: receiver.processIdentifier))
        panel.contentView = NSHostingView(rootView: Text("Synthetic history").frame(width: 440, height: 590))
        panel.makeKeyAndOrderFront(nil)
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(20))
            if panel.isKeyWindow { break }
        }
        #expect(panel.isKeyWindow)
        panel.orderOut(nil)
        let outcome = await SystemPasteExecutor().paste(to: target)
        #expect(outcome == .sent)
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: result.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(
            FileManager.default.fileExists(atPath: result.path), "Receiver did not insert the synthetic paste.")
        #expect(try String(contentsOf: result, encoding: .utf8) == token)
    }

    @Test func permissionAndFocusFailuresHaveDifferentRecoveryMessages() {
        #expect(PasteOutcome.permissionRequired.recoveryMessage != PasteOutcome.activationFailed.recoveryMessage)
        #expect(PasteOutcome.targetUnavailable.recoveryMessage != PasteOutcome.permissionRequired.recoveryMessage)
    }
}
