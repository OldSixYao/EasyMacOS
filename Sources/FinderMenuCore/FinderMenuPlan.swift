import Foundation

/// 仅在需要目录的功能启用时检查元数据；不读取文件内容、不遍历子目录。
public struct FinderMenuPlan {
    public let items: [URL]
    public let actions: [FinderAction]
    public let hasDirectory: Bool
    public let cutToken: UUID?
    public let cutCommandID: Int?

    public init?(
        items: [URL], configuration: FinderConfiguration, hasSelection: Bool = false, cutToken: UUID? = nil,
        cutCommandID: Int? = nil,
        resolveDirectory: ([URL]) throws -> URL = { try FinderOperations.directory(for: $0) }
    ) {
        guard configuration.enabled, !items.isEmpty, items.count <= 1_000, items.allSatisfy(\.isFileURL) else {
            return nil
        }
        self.items = items
        self.cutToken = cutToken
        self.cutCommandID = cutCommandID
        actions = FinderAction.menuOrder.filter {
            configuration.contains($0) && ($0 != .newText || !configuration.fileTypes.isEmpty)
                && ($0 != .cut || hasSelection) && ($0 != .pasteMove || cutToken != nil)
        }
        let needsDirectory = actions.contains(where: \.needsDirectory)
        hasDirectory = needsDirectory && (try? resolveDirectory(items)) != nil
    }

    public func allows(_ action: FinderAction) -> Bool {
        actions.contains(action) && (!action.needsDirectory || hasDirectory)
    }
}
