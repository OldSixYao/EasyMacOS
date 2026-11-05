import Foundation

public enum FinderOperations {
    public static func directory(for items: [URL], fileManager: FileManager = .default) throws -> URL {
        guard !items.isEmpty else { throw FinderMenuError.missingDirectory }
        var directory: URL?
        for url in items {
            guard url.isFileURL else { throw FinderMenuError.missingDirectory }
            var itemIsDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &itemIsDirectory) else {
                throw FinderMenuError.missingDirectory
            }
            let values = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.isPackageKey])
            let folder =
                itemIsDirectory.boolValue && values.isPackage != true
                ? url : url.deletingLastPathComponent()
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw FinderMenuError.missingDirectory
            }
            let candidate = URL(fileURLWithPath: folder.path, isDirectory: true).standardizedFileURL
            if let directory, directory != candidate { throw FinderMenuError.ambiguousDirectory }
            directory = candidate
        }
        guard let directory else { throw FinderMenuError.missingDirectory }
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

    public static func createFile(suffix: String, in directory: URL) throws -> URL {
        let suffix = try FinderFileType.normalize(suffix)
        var number = 1
        while true {
            let name = "未命名" + (number == 1 ? "" : " \(number)") + "." + suffix
            do { return try create(.newText, named: name, in: directory) }
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
        try validateName(name)
        var isDirectory: ObjCBool = false
        guard directory.isFileURL,
            FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw FinderMenuError.missingDirectory }
        let destination = directory.appendingPathComponent(name, isDirectory: false)
        do {
            try Data().write(to: destination, options: .withoutOverwriting)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw FinderMenuError.itemExists
        }
        return destination
    }
}
