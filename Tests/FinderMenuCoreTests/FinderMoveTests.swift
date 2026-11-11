import Foundation
import Testing

@testable import FinderMenuCore

@Suite("访达剪切核心") struct FinderMoveTests {
    @Test func fixedActionIDsAndCutTagsAreIndependentOfMenuOrder() throws {
        #expect(FinderAction.allCases.map(\.commandID) == [1, 2, 3, 4, 5, 6, 7])
        #expect(FinderAction.menuOrder == [.newText, .cut, .pasteMove, .copyPath, .copyName, .openTerminal, .toggleHiddenFiles])
        for id in [1, 2, 57, FinderCutState.maximumCommandID] {
            for usesTarget in [false, true] {
                let command = FinderMenuCommand(action: .pasteMove, usesTarget: usesTarget, cutCommandID: id)
                #expect(command.tag < 0)
                #expect(FinderMenuCommand(tag: command.tag) == command)
            }
        }
        #expect(FinderMenuCommand(tag: Int.min) == nil)
        #expect(FinderMenuCommand(tag: -1) == nil)
    }

    @Test func pasteRequiresTokenAndOtherActionsRejectIt() throws {
        let directory = URL(fileURLWithPath: "/tmp/目标 空格")
        let token = UUID()
        let request = try FinderRequest(action: .pasteMove, items: [directory], cutToken: token)
        #expect(try FinderRequest(url: request.url) == request)
        #expect(throws: FinderMenuError.invalidRequest) { try FinderRequest(action: .pasteMove, items: [directory]) }
        for action in FinderAction.allCases where action != .pasteMove {
            #expect(throws: FinderMenuError.invalidRequest) {
                try FinderRequest(action: action, items: [directory], cutToken: token)
            }
        }
        for query in ["cutToken=invalid", "cutToken=", "cutToken", "cutToken=\(token)&cutToken=\(token)"] {
            let url = try #require(URL(string: "easymacos://finder?action=pasteMove&path=/tmp&" + query))
            #expect(throws: FinderMenuError.invalidRequest) { try FinderRequest(url: url) }
        }
    }

    @Test func menuContextAndCutStateValidity() throws {
        let url = URL(fileURLWithPath: "/tmp")
        let configuration = FinderConfiguration()
        let state = FinderCutState(token: UUID(), changeCount: 20, fileCount: 3, commandID: 7)
        #expect(state.availableToken(changeCount: 20) == state.token)
        #expect(state.availableToken(changeCount: 21) == nil)
        #expect(state.availableToken(changeCount: 20, commandID: 7) == state.token)
        #expect(state.availableToken(changeCount: 20, commandID: 6) == nil)
        #expect(state.availableToken(changeCount: 20, commandID: nil) == nil)
        var consumed = state
        consumed.consumed = true
        #expect(consumed.availableToken(changeCount: 20) == nil)
        let selection = try #require(FinderMenuPlan(
            items: [url], configuration: configuration, hasSelection: true, cutToken: state.token, cutCommandID: state.commandID))
        #expect(selection.actions == FinderAction.menuOrder)
        let background = try #require(FinderMenuPlan(items: [url], configuration: configuration))
        #expect(!background.actions.contains(.cut))
        #expect(!background.actions.contains(.pasteMove))
        let ambiguous = try #require(FinderMenuPlan(
            items: [url], configuration: configuration, hasSelection: true, cutToken: state.token,
            resolveDirectory: { _ in throw FinderMenuError.ambiguousDirectory }))
        #expect(ambiguous.allows(.cut))
        #expect(!ambiguous.allows(.pasteMove))
    }

    @Test func preservesLinksAndRejectsInvalidDestinationsWithoutChangingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("源", isDirectory: true)
        let nested = source.appendingPathComponent("子目录", isDirectory: true)
        let destination = root.appendingPathComponent("目标", isDirectory: true)
        for url in [nested, destination] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let file = source.appendingPathComponent("中文 ' &.txt")
        try Data("原始内容".utf8).write(to: file)
        let link = source.appendingPathComponent("悬空链接")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("不存在"))
        #expect(try FinderMoveValidation.sources([file, link]).count == 2)
        try FinderMoveValidation.destination(destination, for: [file, link])
        #expect(throws: FinderMoveError.sameDirectory) { try FinderMoveValidation.destination(source, for: [file]) }
        #expect(throws: FinderMoveError.recursiveDestination) { try FinderMoveValidation.destination(nested, for: [source]) }
        #expect(throws: FinderMoveError.recursiveDestination) { try FinderMoveValidation.destination(source, for: [source]) }
        #expect(throws: FinderMoveError.missingSource) {
            try FinderMoveValidation.destination(destination, for: [file, root.appendingPathComponent("丢失")])
        }
        #expect(throws: FinderMenuError.invalidRequest) { try FinderMoveValidation.sources([file, file]) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "原始内容")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == root.appendingPathComponent("不存在").path)
    }

    @Test func stateStoreRoundTripsAndRejectsCorruption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FinderCutStateStore(url: root.appendingPathComponent("cut.json"))
        #expect(try store.load() == nil)
        let state = FinderCutState(token: UUID(), changeCount: 10, fileCount: 2, commandID: 10)
        try store.save(state)
        #expect(try store.load() == state)
        try store.save(FinderCutState(token: UUID(), changeCount: 1, fileCount: 0))
        #expect(throws: FinderMoveError.expiredCut) { try store.load() }
    }

    @Test func cutCommandReservationSurvivesMissingStateAndMigratesLegacyCounters() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FinderCutStateStore(url: root.appendingPathComponent("cut.json"))
        let legacy = FinderCutState(token: UUID(), changeCount: 10, fileCount: 1, commandID: 80)
        try store.save(legacy)
        let first = try store.reserveCommandID(pasteboardChangeCount: 10)
        #expect(first == 81)
        // 即使新状态写入失败或丢失，已经预留的编号也不能重新使用。
        try FileManager.default.removeItem(at: store.url)
        let restarted = FinderCutStateStore(url: store.url)
        let second = try restarted.reserveCommandID(pasteboardChangeCount: 2)
        #expect(second == 82)
        try store.save(FinderCutState(token: UUID(), changeCount: 3, fileCount: 0, commandID: second))
        #expect(try store.reserveCommandID(pasteboardChangeCount: 3) == 83)
    }

    @Test func cutRecoveryWithoutSequenceAdvancesPastCurrentClipboardAndPreservesReadErrors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FinderCutStateStore(url: root.appendingPathComponent("cut.json"))
        try Data("损坏的旧版状态".utf8).write(to: store.url)
        #expect(try store.reserveCommandID(pasteboardChangeCount: 200) == 201)
        let blocked = root.appendingPathComponent("不是文件")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let unreadable = FinderCutStateStore(url: blocked)
        #expect(throws: (any Error).self) { try unreadable.reserveCommandID(pasteboardChangeCount: 201) }
        #expect(FileManager.default.fileExists(atPath: blocked.path))
        try store.save(FinderCutState(token: UUID(), changeCount: 202, fileCount: 1, commandID: FinderCutState.maximumCommandID))
        #expect(throws: FinderMoveError.expiredCut) { try store.reserveCommandID(pasteboardChangeCount: 202) }
    }
}
