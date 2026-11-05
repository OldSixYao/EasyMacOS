import AppKit
import FinderMenuCore
import Testing

@testable import PasteMan

@Suite("访达文件剪切", .serialized) @MainActor struct FinderCutClipboardTests {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func fileObjectsOnlyMultiSelectionAndRestartPreserveCut() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("中文 空格 ' &$.txt")
        try Data("文件内容".utf8).write(to: file)
        let directory = root.appendingPathComponent("文件夹", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = FinderCutStateStore(url: root.appendingPathComponent("state.json"))
        let clipboard = FinderCutClipboard(board: board, store: store)
        let state = try clipboard.cut([file, directory])
        #expect(board.pasteboardItems?.count == 2)
        #expect(board.pasteboardItems?.allSatisfy { Set($0.types) == [.fileURL, FinderCutClipboard.markerType] } == true)
        #expect(board.string(forType: .string) == nil)
        #expect(SystemClipboard(pasteboard: board).capture() == nil)
        let restarted = FinderCutClipboard(board: board, store: store)
        #expect(try restarted.current(token: state.token).1.map(\.path) == [file.path, directory.path])
        #expect(try String(contentsOf: file, encoding: .utf8) == "文件内容")
        #expect(FileManager.default.fileExists(atPath: directory.path))
        let saved = try Data(contentsOf: store.url)
        #expect(!String(decoding: saved, as: UTF8.self).contains(root.path))
    }

    @Test func replacesPreviousCutAndClipboardChangesInvalidateIt() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("文件.txt")
        try Data().write(to: file)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let clipboard = FinderCutClipboard(board: board, store: FinderCutStateStore(url: root.appendingPathComponent("state.json")))
        let old = try clipboard.cut([file])
        let current = try clipboard.cut([file])
        #expect(current.commandID > old.commandID)
        #expect(current.token != old.token)
        #expect(throws: FinderMoveError.expiredCut) { try clipboard.current(token: old.token) }
        try clipboard.consume(current)
        #expect(throws: FinderMoveError.expiredCut) { try clipboard.current(token: current.token) }
        try clipboard.restore(current)
        #expect(try clipboard.current(token: current.token).0 == current)
        board.clearContents()
        board.setString("其他复制", forType: .string)
        #expect(throws: FinderMoveError.expiredCut) { try clipboard.current(token: current.token) }
        try clipboard.restore(current)
        #expect(try clipboard.store.load()?.availableToken(changeCount: board.changeCount) == nil)
    }

    @Test func changedItemOrFailedStateSaveNeverProducesValidCut() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("文件.txt")
        try Data("保留".utf8).write(to: file)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let blocked = root.appendingPathComponent("阻塞")
        try Data().write(to: blocked)
        let clipboard = FinderCutClipboard(board: board, store: FinderCutStateStore(url: blocked.appendingPathComponent("state.json")))
        #expect(throws: (any Error).self) { try clipboard.cut([file]) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "保留")
        let valid = FinderCutClipboard(board: board, store: FinderCutStateStore(url: root.appendingPathComponent("state.json")))
        let state = try valid.cut([file])
        board.clearContents()
        let forged = NSPasteboardItem()
        forged.setString(file.absoluteString, forType: .fileURL)
        forged.setString(UUID().uuidString, forType: FinderCutClipboard.markerType)
        board.writeObjects([forged])
        let mismatched = FinderCutState(token: state.token, changeCount: board.changeCount, fileCount: 1)
        try valid.store.save(mismatched)
        #expect(throws: FinderMoveError.expiredCut) { try valid.current(token: state.token) }
    }
}
