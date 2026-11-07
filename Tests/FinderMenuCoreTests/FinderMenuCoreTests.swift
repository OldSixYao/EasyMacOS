import Foundation
import Testing

@testable import FinderMenuCore

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("EasyMacOSTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("访达菜单核心") struct FinderMenuCoreTests {
    @Test func reconstructedMenuTagsPreserveActionAndContext() throws {
        let folder = URL(fileURLWithPath: "/tmp/目标目录")
        let staleSelection = URL(fileURLWithPath: "/tmp/其他目录/先前选中的文件.txt")
        for action in FinderAction.allCases {
            for useTarget in [false, true] {
                let command = FinderMenuCommand(action: action, usesTarget: useTarget)
                let received = try #require(FinderMenuCommand(tag: command.tag))
                #expect(received == command)
                if action == .cut && useTarget {
                    #expect(throws: FinderMenuError.invalidRequest) { try received.request(target: folder, selection: [staleSelection]) }
                    continue
                }
                let request = try received.request(target: folder, selection: [staleSelection],
                                                   cutToken: action == .pasteMove ? UUID() : nil)
                #expect(request.items == [useTarget ? folder : staleSelection])
                #expect(request.action == action)
            }
        }
        for tag in [-1, 0, 1, 100, Int.max] { #expect(FinderMenuCommand(tag: tag) == nil) }
        #expect(throws: FinderMenuError.invalidRequest) {
            try FinderMenuCommand(action: .newText, usesTarget: true).request(target: nil, selection: [staleSelection])
        }
    }

    @Test func requestRoundTripsUnusualPaths() throws {
        let names = ["空 格&问号?.txt", "百分号%和#号.md", "引'号\"与$(echo test).txt", "多行\n文件.txt", "🙂.json"]
        let items = names.map { URL(fileURLWithPath: "/tmp/" + $0) }
        for action in FinderAction.allCases {
            let request = try FinderRequest(action: action, items: items, cutToken: action == .pasteMove ? UUID() : nil)
            #expect(try FinderRequest(url: request.url) == request)
        }
    }

    @Test(arguments: [
        "https://perform?action=copyPath&path=/tmp", "easymacos://finder?action=missing&path=/tmp",
        "easymacos://finder?action=copyPath", "easymacos://finder?action=copyPath&path=relative",
        "easymacos://finder?action=copyPath&path=/tmp&action=newText",
        "easymacos://finder?action=copyPath&path=/tmp&command=rm",
        "easymacos://finder?action=copyPath&path=/tmp%00bad",
        "easymacos://user@finder?action=copyPath&path=/tmp",
    ]) func rejectsMalformedRequests(_ value: String) throws {
        #expect(throws: FinderMenuError.invalidRequest) { try FinderRequest(url: #require(URL(string: value))) }
    }

    @Test func rejectsNonFileOrExcessiveInput() throws {
        #expect(throws: FinderMenuError.invalidRequest) { try FinderRequest(action: .newText, items: []) }
        #expect(throws: FinderMenuError.invalidRequest) {
            try FinderRequest(action: .openTerminal, items: [#require(URL(string: "https://example.com"))])
        }
        #expect(throws: FinderMenuError.invalidRequest) {
            try FinderRequest(action: .copyPath, items: Array(repeating: URL(fileURLWithPath: "/tmp"), count: 1001))
        }
    }

    @Test func clipboardPreservesSpecialCharacters() throws {
        let items = [URL(fileURLWithPath: "/tmp/甲 乙.txt"), URL(fileURLWithPath: "/tmp/a'b$(echo c).md")]
        #expect(try FinderOperations.clipboardText(for: .copyName, items: items) == "甲 乙.txt\na'b$(echo c).md")
        #expect(
            try FinderOperations.clipboardText(for: .copyPath, items: items) == "/tmp/甲 乙.txt\n/tmp/a'b$(echo c).md")
    }

    @Test func choosesDirectoryAndRejectsAmbiguity() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try FinderOperations.create(.newText, named: "a.txt", in: root)
        let second = try FinderOperations.create(.newText, named: "b.txt", in: root)
        let subfolder = root.appendingPathComponent("子目录", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: false)
        #expect(try FinderOperations.directory(for: [root]).path == root.path)
        #expect(try FinderOperations.directory(for: [first, second]).path == root.path)
        #expect(try FinderOperations.directory(for: [subfolder]).path == subfolder.path)
        #expect(throws: FinderMenuError.ambiguousDirectory) { try FinderOperations.directory(for: [first, subfolder]) }
        #expect(throws: (any Error).self) {
            try FinderOperations.directory(for: [root.appendingPathComponent("不存在")])
        }
    }

    @Test func createsTemplatesWithoutOverwriting() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "未命名.txt"
        let file = try FinderOperations.create(.newText, named: name, in: root)
        #expect(try Data(contentsOf: file).isEmpty)
        try Data("已有内容".utf8).write(to: file)
        #expect(throws: FinderMenuError.itemExists) { try FinderOperations.create(.newText, named: name, in: root) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "已有内容")
        let folder = root.appendingPathComponent("已存在目录", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try FinderOperations.create(.newText, named: "已存在目录", in: root) }
        #expect(try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        let link = root.appendingPathComponent("链接.txt")
        let outside = root.appendingPathComponent("不应创建.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: FinderMenuError.itemExists) { try FinderOperations.create(.newText, named: "链接.txt", in: root) }
        #expect(!FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func directoryRejectsDeletedItemsAndDanglingLinksDespiteCachedMetadata() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try FinderOperations.create(.newText, named: "将被删除.txt", in: root)
        _ = try item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        #expect(try FinderOperations.directory(for: [item]) == root.standardizedFileURL)
        let link = root.appendingPathComponent("链接")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: item)
        #expect(try FinderOperations.directory(for: [link]) == root.standardizedFileURL)
        try FileManager.default.removeItem(at: item)
        #expect(throws: FinderMenuError.missingDirectory) { try FinderOperations.directory(for: [item]) }
        #expect(throws: FinderMenuError.missingDirectory) { try FinderOperations.directory(for: [link]) }
    }

    @Test func directoryLinksAndApplicationPackagesUseTheExpectedLocation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("目标目录", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("目录链接")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        #expect(
            try FinderOperations.directory(for: [link]).resolvingSymlinksInPath().path
                == folder.resolvingSymlinksInPath().path)
        let package = root.appendingPathComponent("示例.app", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        let packageLink = root.appendingPathComponent("应用链接")
        try FileManager.default.createSymbolicLink(at: packageLink, withDestinationURL: package)
        #expect(try FinderOperations.directory(for: [package]).path == root.path)
        #expect(try FinderOperations.directory(for: [packageLink]).path == root.path)
        // Foundation normalizes /private/tmp back to /tmp, even when resolving symbolic links.
        #expect(try FinderOperations.directory(for: [URL(fileURLWithPath: "/tmp")]).path == "/tmp")
    }

    @Test(arguments: ["", " ", ".", "..", "../越界", "a/b", "a:b", "换\n行", "空\0值", String(repeating: "甲", count: 86)])
    func rejectsInvalidNames(_ name: String) {
        #expect(throws: FinderMenuError.invalidName) { try FinderOperations.validateName(name) }
    }

    @Test func configurationPersistenceAndCorruption() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FinderConfigurationStore(url: root.appendingPathComponent("配置/menu.json"))
        #expect(try store.load() == FinderConfiguration())
        var configuration = FinderConfiguration()
        configuration.set(.copyPath, enabled: false)
        try store.save(configuration)
        #expect(try store.load() == configuration)
        #expect(!configuration.contains(.copyPath))
        #expect(configuration.contains(.newText))
        configuration.enabled = false
        #expect(!configuration.contains(.newText))
        try Data("损坏".utf8).write(to: store.url)
        #expect(throws: (any Error).self) { try store.load() }
    }
}
