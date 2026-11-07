import Foundation
import Darwin

public enum FinderOperations {
    public static func directory(for items: [URL], fileManager: FileManager = .default) throws -> URL {
        guard !items.isEmpty else { throw FinderMenuError.missingDirectory }
        var directory: URL?
        for url in items {
            guard url.isFileURL else { throw FinderMenuError.missingDirectory }
            // 普通文件只取一次属性；目录才检查应用包，符号链接才解析目标。
            var attributes = stat()
            let status = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return lstat(path, &attributes)
            }
            guard status == 0 else { throw FinderMenuError.missingDirectory }
            let type = attributes.st_mode & mode_t(S_IFMT)
            var itemIsDirectory = type == mode_t(S_IFDIR)
            if type == mode_t(S_IFLNK) {
                var targetIsDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &targetIsDirectory) else {
                    throw FinderMenuError.missingDirectory
                }
                itemIsDirectory = targetIsDirectory.boolValue
            }
            var isPackage = false
            if itemIsDirectory {
                var inspected = type == mode_t(S_IFLNK) ? url.resolvingSymlinksInPath() : url
                inspected.removeAllCachedResourceValues()
                isPackage = try inspected.resourceValues(forKeys: [.isPackageKey]).isPackage == true
            }
            let folder =
                itemIsDirectory && !isPackage
                ? url : url.deletingLastPathComponent()
            let candidate = URL(fileURLWithPath: folder.path, isDirectory: true).standardizedFileURL
            if let directory, directory != candidate { throw FinderMenuError.ambiguousDirectory }
            directory = candidate
        }
        guard let directory else { throw FinderMenuError.missingDirectory }
        // 同一目录的多选只验证父目录一次，实际执行操作时仍会重新调用本方法校验。
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FinderMenuError.missingDirectory
        }
        return directory
    }

    public static func clipboardText(for action: FinderAction, items: [URL]) throws -> String {
        guard !items.isEmpty, items.allSatisfy(\.isFileURL) else { throw FinderMenuError.invalidRequest }
        switch action {
        case .copyPath: return items.map(\.path).joined(separator: "\n")
        case .copyName: return items.map(\.lastPathComponent).joined(separator: "\n")
        default: throw FinderMenuError.unsupportedAction
        }
    }

    public static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            name != ".", name != "..", name.lengthOfBytes(using: .utf8) <= 255,
            !name.contains("/"), !name.contains(":"),
            name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { throw FinderMenuError.invalidName }
    }

    public static func createFile(suffix: String, in directory: URL, templateDirectory: URL? = nil) throws -> URL {
        let suffix = try FinderFileType.normalize(suffix)
        // 先读取模板，失败时不得留下零字节办公文档。
        let data = try FinderDocumentTemplates.data(for: suffix, resourceDirectory: templateDirectory)
        var number = 1
        while true {
            let name = "未命名" + (number == 1 ? "" : " \(number)") + "." + suffix
            do { return try write(data, named: name, in: directory) }
            catch FinderMenuError.itemExists {
                guard number < Int.max else { throw FinderMenuError.itemExists }
                number += 1
            }
        }
    }

    /// `.withoutOverwriting` makes the existence check atomic, including concurrent requests.
    @discardableResult
    public static func create(_ action: FinderAction, named name: String, in directory: URL) throws -> URL {
        guard action.createsItem else { throw FinderMenuError.unsupportedAction }
        return try write(FinderDocumentTemplates.data(for: URL(fileURLWithPath: name).pathExtension.lowercased()), named: name, in: directory)
    }

    private static func write(_ data: Data, named name: String, in directory: URL) throws -> URL {
        try validateName(name)
        var isDirectory: ObjCBool = false
        guard directory.isFileURL,
            FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw FinderMenuError.missingDirectory }
        let destination = directory.appendingPathComponent(name, isDirectory: false)
        do {
            try data.write(to: destination, options: .withoutOverwriting)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw FinderMenuError.itemExists
        }
        return destination
    }
}
