import AppKit
import Testing

@testable import PasteMan

@Suite("访达打开终端", .serialized) @MainActor struct FinderTerminalTests {
    @Test func invokesOnceWithOnlyOneDirectoryObjectAndPreservesClipboard() throws {
        let directory = URL(fileURLWithPath: "/tmp/中文 空格 ' 引号 & $().目录", isDirectory: true)
        let before = NSPasteboard.general.changeCount
        var calls = 0
        let service = FinderTerminalService { name, board in
            calls += 1
            #expect(name == "New Terminal at Folder")
            #expect(board.name != NSPasteboard.general.name)
            #expect(board.pasteboardItems?.count == 1)
            #expect(board.string(forType: .string) == nil)
            let objects = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
            #expect(objects == [directory])
            return true
        }
        try service.open(directory: directory)
        #expect(calls == 1)
        #expect(NSPasteboard.general.changeCount == before)
    }

    @Test func serviceFailurePropagatesWithoutRetry() {
        var calls = 0
        let service = FinderTerminalService { _, _ in calls += 1; return false }
        #expect(throws: (any Error).self) { try service.open(directory: URL(fileURLWithPath: "/tmp")) }
        #expect(calls == 1)
    }
}
