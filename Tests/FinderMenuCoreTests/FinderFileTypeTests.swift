import Foundation
import PDFKit
import Testing

@testable import FinderMenuCore

@Suite("访达文件类型") struct FinderFileTypeTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func migratesOldSwitchesAndPreservesEmptyList() throws {
        let old = Data(#"{"enabled":false,"disabledActions":["copyName","newText"]}"#.utf8)
        let migrated = try JSONDecoder().decode(FinderConfiguration.self, from: old)
        #expect(!migrated.enabled)
        #expect(migrated.disabledActions == ["copyName", "newText"])
        #expect(migrated.fileTypes.map(\.suffix) == FinderConfiguration.legacySuffixes)
        #expect(!migrated.officeTypesMigrated)
        var empty = FinderConfiguration()
        for type in empty.fileTypes { empty.removeFileType(id: type.id) }
        #expect(try JSONDecoder().decode(FinderConfiguration.self, from: JSONEncoder().encode(empty)) == empty)
    }

    @Test func normalizesDeduplicatesAndNeverReusesIDs() throws {
        var configuration = FinderConfiguration()
        try configuration.addFileType(" .TXT \n")
        #expect(configuration.fileTypes.count == 12)
        try configuration.addFileType(" .Tar.GZ ")
        let custom = try #require(configuration.fileTypes.last)
        #expect(custom.suffix == "tar.gz")
        let command = FinderMenuCommand(action: .newText, usesTarget: false, fileTypeID: custom.id)
        let restored = try #require(FinderMenuCommand(tag: command.tag))
        let target = URL(fileURLWithPath: "/tmp")
        #expect(try restored.request(target: target, selection: [], configuration: configuration).suffix == "tar.gz")
        configuration.removeFileType(id: custom.id)
        try configuration.addFileType("yaml")
        #expect(try #require(configuration.fileTypes.last).id > custom.id)
        #expect(throws: FinderMenuError.invalidRequest) {
            try restored.request(target: target, selection: [], configuration: configuration)
        }
        let txt = try #require(configuration.fileTypes.first)
        configuration.removeFileType(id: txt.id)
        let next = configuration.nextFileTypeID
        try configuration.restoreDefaults()
        #expect(configuration.fileTypes.map(\.suffix) == FinderConfiguration.defaultSuffixes)
        #expect(configuration.fileTypes.first?.id == next)
        #expect(!configuration.fileTypes.contains { $0.id == txt.id || $0.id == custom.id })
        let persisted = try JSONDecoder().decode(FinderConfiguration.self, from: JSONEncoder().encode(configuration))
        #expect(persisted == configuration)
    }

    @Test(arguments: ["", " ", ".", "..txt", "txt.", "tar..gz", "a/b", "a\\b", "a:b", "a b", "a\tb", "a\nb", "a\0b", String(repeating: "甲", count: 80)])
    func rejectsInvalidSuffix(_ input: String) {
        #expect(throws: FinderMenuError.invalidFileType) { try FinderFileType.normalize(input) }
    }

    @Test func requestRoundTripAndLegacyFallback() throws {
        let target = URL(fileURLWithPath: "/tmp/中文 空格")
        for suffix in FinderConfiguration.defaultSuffixes + ["tar.gz", "自定义"] {
            let request = try FinderRequest(action: .newText, items: [target], suffix: suffix)
            #expect(try FinderRequest(url: request.url) == request)
        }
        let old = try FinderRequest(url: #require(URL(string: "easymacos://finder?action=newText&path=/tmp")))
        #expect(old.suffix == nil)
    }

    @Test(arguments: [
        #"{"fileTypes":[{"id":1,"suffix":"txt"},{"id":1,"suffix":"json"}],"nextFileTypeID":2}"#,
        #"{"fileTypes":[{"id":1,"suffix":"txt"},{"id":2,"suffix":"txt"}],"nextFileTypeID":3}"#,
        #"{"fileTypes":[{"id":0,"suffix":"txt"}],"nextFileTypeID":1}"#,
        #"{"fileTypes":[{"id":1,"suffix":"TXT"}],"nextFileTypeID":2}"#,
        #"{"fileTypes":[{"id":1,"suffix":"a/b"}],"nextFileTypeID":2}"#,
        #"{"fileTypes":[{"id":2,"suffix":"txt"}],"nextFileTypeID":2}"#,
        #"{"fileTypes":[],"nextFileTypeID":0}"#,
    ]) func rejectsCorruptedPersistentIdentifiers(_ fragment: String) throws {
        var object = try #require(JSONSerialization.jsonObject(with: Data(fragment.utf8)) as? [String: Any])
        object["enabled"] = true
        object["disabledActions"] = [] as [String]
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(FinderConfiguration.self, from: data) }
    }

    @Test(arguments: [
        "action=copyName&suffix=txt", "action=openTerminal&suffix=txt", "action=copyPath&suffix=txt",
        "action=newText&suffix=", "action=newText&suffix", "action=newText&suffix=txt&suffix=json",
        "action=newText&suffix=../txt", "action=newText&suffix=.txt", "action=newText&suffix=TXT",
        "action=newText&suffix=a%00b", "action=newText&suffix=tar..gz",
    ]) func rejectsMalformedSuffixRequest(_ query: String) throws {
        let url = try #require(URL(string: "easymacos://finder?path=/tmp&" + query))
        #expect(throws: FinderMenuError.invalidRequest) { try FinderRequest(url: url) }
    }

    @Test func createsAllDefaultsAndCompoundSuffixWithoutContents() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        for suffix in FinderConfiguration.legacySuffixes + ["tar.gz"] {
            let file = try FinderOperations.createFile(suffix: suffix, in: root)
            #expect(file.lastPathComponent == "未命名." + suffix)
            #expect(try Data(contentsOf: file).isEmpty)
        }
    }

    @Test func numbersPastFilesDirectoriesAndDanglingLinks() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try FinderOperations.createFile(suffix: "txt", in: root)
        try Data("保留".utf8).write(to: original)
        let existingDirectory = root.appendingPathComponent("未命名 2.txt")
        try FileManager.default.createDirectory(at: existingDirectory, withIntermediateDirectories: false)
        let outside = root.appendingPathComponent("不应写入")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("未命名 3.txt"), withDestinationURL: outside)
        let file = try FinderOperations.createFile(suffix: "txt", in: root)
        #expect(file.lastPathComponent == "未命名 4.txt")
        #expect(try String(contentsOf: original, encoding: .utf8) == "保留")
        #expect(!FileManager.default.fileExists(atPath: outside.path))
        #expect(try existingDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
    }

    @Test(arguments: ["json", "docx", "xlsx", "pptx", "pdf"]) func concurrentCreatesProduceDistinctFiles(_ suffix: String) async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<20 { group.addTask { try FinderOperations.createFile(suffix: suffix, in: root) } }
            var files = Set<URL>()
            for try await file in group { files.insert(file) }
            return files
        }
        #expect(files.count == 20)
        #expect(files.contains { $0.lastPathComponent == "未命名 20." + suffix })
        let expected = try FinderDocumentTemplates.data(for: suffix)
        for file in files { #expect(try Data(contentsOf: file) == expected) }
    }

    @Test(arguments: ["txt", "docx", "xlsx", "pptx", "pdf"]) func writeFailureDoesNotRetryAsCollision(_ suffix: String) throws {
        let root = try folder()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        #expect(throws: (any Error).self) { try FinderOperations.createFile(suffix: suffix, in: root) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}

extension FinderFileTypeTests {
    @Test(arguments: FinderConfiguration.officeSuffixes) func officeTemplatesNeverOverwrite(_ suffix: String) throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = try FinderDocumentTemplates.data(for: suffix)
        #expect(!expected.isEmpty)
        let original = root.appendingPathComponent("未命名." + suffix)
        try Data("保留原件".utf8).write(to: original)
        let directory = root.appendingPathComponent("未命名 2." + suffix)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let outside = root.appendingPathComponent("链接目标")
        try Data("链接内容".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("未命名 3." + suffix), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("未命名 4." + suffix), withDestinationURL: root.appendingPathComponent("缺失目标"))
        let created = try FinderOperations.createFile(suffix: suffix, in: root)
        #expect(created.lastPathComponent == "未命名 5." + suffix)
        #expect(try Data(contentsOf: created) == expected)
        #expect(try String(contentsOf: original, encoding: .utf8) == "保留原件")
        #expect(try String(contentsOf: outside, encoding: .utf8) == "链接内容")
        #expect(try FinderOperations.createFile(suffix: suffix, in: root).lastPathComponent == "未命名 6." + suffix)
    }

    @Test(arguments: FinderConfiguration.officeSuffixes) func missingTemplateLeavesNoFile(_ suffix: String) throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: FinderMenuError.templateUnavailable) {
            try FinderOperations.createFile(suffix: suffix, in: root, templateDirectory: root)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func blankPDFHasOneEmptyPage() throws {
        let pdf = try #require(PDFDocument(data: FinderDocumentTemplates.data(for: "pdf")))
        #expect(pdf.pageCount == 1)
        #expect((pdf.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(pdf.page(at: 0)?.bounds(for: .mediaBox) == CGRect(x: 0, y: 0, width: 595, height: 842))
    }

    @Test(arguments: ["../other.png", "/tmp/other.png", "dir/a.png", "a\\b.png", "a:b.png", ".png", "a.jpg", ""]) func rejectsUnsafeIconReferences(_ resource: String) throws {
        var configuration = FinderConfiguration()
        #expect(throws: FinderMenuError.invalidFileType) { try configuration.setIconResource(resource, for: 1) }
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
        object["fileTypes"] = [["id": 1, "suffix": "txt", "iconResource": resource]]
        #expect(throws: (any Error).self) { try JSONDecoder().decode(FinderConfiguration.self, from: JSONSerialization.data(withJSONObject: object)) }
    }
}
