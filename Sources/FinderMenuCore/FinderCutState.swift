import Foundation

public enum FinderMoveError: Error, LocalizedError, Equatable {
    case expiredCut, missingSource, sameDirectory, recursiveDestination, permissionRequired, unsafeFinder, clipboardUnavailable

    public var errorDescription: String? {
        switch self {
        case .expiredCut: "剪切记录已失效或已使用，请重新剪切后再粘贴（移动）。"
        case .missingSource: "部分源文件已不存在，请重新选择并剪切；本次未移动任何项目。"
        case .sameDirectory: "目标就是源文件所在目录，无需移动。"
        case .recursiveDestination: "不能将文件夹移动到自身或其子目录。"
        case .permissionRequired: "粘贴（移动）需要辅助功能权限，请在访达设置中开启；源文件尚未改变。"
        case .unsafeFinder: "未能确认访达目标目录，或当前正在编辑名称、显示对话框；请关闭对话框后重试。"
        case .clipboardUnavailable: "无法写入或读取文件剪贴板，请检查剪贴板访问权限后重试。"
        }
    }
}

public struct FinderCutState: Codable, Sendable, Equatable {
    public let token: UUID
    public let changeCount: Int
    public let fileCount: Int
    public let commandID: Int
    public var consumed: Bool

    public init(token: UUID, changeCount: Int, fileCount: Int, commandID: Int = 1, consumed: Bool = false) {
        self.token = token
        self.changeCount = changeCount
        self.fileCount = fileCount
        self.commandID = commandID
        self.consumed = consumed
    }

    public func availableToken(changeCount: Int) -> UUID? {
        !consumed && self.changeCount == changeCount && (1...1_000).contains(fileCount)
            && (1...Self.maximumCommandID).contains(commandID) ? token : nil
    }

    public func availableToken(changeCount: Int, commandID: Int?) -> UUID? {
        self.commandID == commandID ? availableToken(changeCount: changeCount) : nil
    }

    public static let maximumCommandID = (Int(Int32.max) - 1) / 2
}

public struct FinderCutStateStore: Sendable {
    public let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? FinderConfigurationStore().url.deletingLastPathComponent().appendingPathComponent("finder-cut.json")
    }

    public func load() throws -> FinderCutState? {
        do {
            let state = try JSONDecoder().decode(FinderCutState.self, from: Data(contentsOf: url))
            guard (1...1_000).contains(state.fileCount), (1...FinderCutState.maximumCommandID).contains(state.commandID)
            else { throw FinderMoveError.expiredCut }
            return state
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    public func save(_ state: FinderCutState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: [.atomic])
        // 仅包含随机标记与计数，不在扩展可读状态中保存源文件路径。
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum FinderMoveValidation {
    public static func sources(_ items: [URL]) throws -> [URL] {
        guard !items.isEmpty, items.count <= 1_000,
            items.allSatisfy({ $0.isFileURL && ($0.host == nil || $0.host == "localhost") && !$0.path.contains("\0") })
        else { throw FinderMenuError.invalidRequest }
        let normalized = items.map(\.standardizedFileURL)
        guard Set(normalized.map(\.path)).count == normalized.count else { throw FinderMenuError.invalidRequest }
        for url in normalized {
            // attributesOfItem 检查链接本身，允许移动目标已失效的符号链接。
            guard (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil, url.path != "/" else {
                throw FinderMoveError.missingSource
            }
        }
        return normalized
    }

    public static func destination(_ directory: URL, for items: [URL]) throws {
        _ = try sources(items)
        let destination = try FinderOperations.directory(for: [directory]).resolvingSymlinksInPath().standardizedFileURL
        guard destination.path == directory.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw FinderMenuError.missingDirectory
        }
        for item in items {
            if item.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == destination.path {
                throw FinderMoveError.sameDirectory
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: item.path)
            if attributes[.type] as? FileAttributeType == .typeDirectory {
                let source = item.resolvingSymlinksInPath().standardizedFileURL.path
                if destination.path == source || destination.path.hasPrefix(source + "/") {
                    throw FinderMoveError.recursiveDestination
                }
            }
        }
    }
}
