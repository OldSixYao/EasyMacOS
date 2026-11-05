import Foundation

/// 访达跨进程重建菜单项时保留 tag，不依赖原菜单项携带的自定义对象。
public struct FinderMenuCommand: Sendable, Equatable {
    public let action: FinderAction
    public let usesTarget: Bool
    public let fileTypeID: Int?
    public let cutCommandID: Int?

    public init(action: FinderAction, usesTarget: Bool, fileTypeID: Int? = nil, cutCommandID: Int? = nil) {
        self.action = action
        self.usesTarget = usesTarget
        self.fileTypeID = fileTypeID
        self.cutCommandID = cutCommandID
    }

    public var tag: Int {
        if action == .pasteMove, let cutCommandID { return -(cutCommandID * 2 + (usesTarget ? 1 : 0)) }
        if action == .newText, let fileTypeID { return 1024 + fileTypeID * 2 + (usesTarget ? 1 : 0) }
        return action.commandID * 2 + (usesTarget ? 1 : 0)
    }

    public init?(tag: Int) {
        if tag <= -2, tag >= -Int(Int32.max) {
            action = .pasteMove
            usesTarget = (-tag) % 2 == 1
            cutCommandID = (-tag) / 2
            fileTypeID = nil
            return
        }
        cutCommandID = nil
        if tag >= 1026, tag <= 1025 + FinderConfiguration.maximumFileTypeID * 2 {
            action = .newText
            usesTarget = tag % 2 == 1
            fileTypeID = (tag - 1024) / 2
            return
        }
        fileTypeID = nil
        guard tag >= 2, let decoded = FinderAction.allCases.first(where: { $0.commandID == tag / 2 }) else { return nil }
        action = decoded
        usesTarget = tag % 2 == 1
    }

    public func request(
        target: URL?, selection: [URL], configuration: FinderConfiguration = FinderConfiguration(), cutToken: UUID? = nil
    ) throws -> FinderRequest {
        if action == .cut, usesTarget || selection.isEmpty { throw FinderMenuError.invalidRequest }
        let items = usesTarget || selection.isEmpty ? target.map { [$0] } ?? [] : selection
        guard configuration.contains(action) else { throw FinderMenuError.invalidRequest }
        let suffix: String?
        if let fileTypeID {
            guard let type = configuration.fileTypes.first(where: { $0.id == fileTypeID })
            else { throw FinderMenuError.invalidRequest }
            suffix = type.suffix
        } else { suffix = nil }
        return try FinderRequest(action: action, items: items, suffix: suffix, cutToken: cutToken)
    }
}
