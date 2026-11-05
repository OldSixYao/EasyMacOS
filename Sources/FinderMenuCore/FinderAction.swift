import Foundation

public enum FinderAction: String, Codable, CaseIterable, Sendable, Identifiable {
    case newText, copyPath, copyName, openTerminal, cut, pasteMove

    public static let menuOrder: [Self] = [.newText, .cut, .pasteMove, .copyPath, .copyName, .openTerminal]

    // 动作编号与显示顺序分离，已发布菜单的编号不能随增删动作变化。
    public var commandID: Int {
        switch self {
        case .newText: 1
        case .copyPath: 2
        case .copyName: 3
        case .openTerminal: 4
        case .cut: 5
        case .pasteMove: 6
        }
    }

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .newText: "新建文件"
        case .copyPath: "复制完整路径"
        case .copyName: "复制文件名"
        case .openTerminal: "在此处打开终端"
        case .cut: "剪切"
        case .pasteMove: "粘贴（移动）"
        }
    }

    public var detail: String {
        switch self {
        case .newText: "选择文件类型后立即创建空文件，并尝试进入访达重命名。"
        case .copyPath: "多选时逐行复制每个项目的完整路径。"
        case .copyName: "保留扩展名，多选时每个名称占一行。"
        case .openTerminal: "打开所选文件夹，或文件所在的目录。"
        case .cut: "标记所选文件，在目标目录使用粘贴（移动）或 ⌥⌘V。"
        case .pasteMove: "由访达移动已剪切的文件，沿用系统冲突处理与撤销。"
        }
    }

    public var symbol: String {
        switch self {
        case .newText: "doc.badge.plus"
        case .copyPath: "link"
        case .copyName: "character"
        case .openTerminal: "terminal"
        case .cut: "scissors"
        case .pasteMove: "doc.on.clipboard"
        }
    }

    public var createsItem: Bool { self == .newText }
    public var needsDirectory: Bool { self == .newText || self == .openTerminal || self == .pasteMove }

    public var defaultName: String? {
        switch self {
        case .newText: "未命名.txt"
        default: nil
        }
    }
}

public enum FinderMenuError: Error, LocalizedError, Equatable {
    case invalidRequest, invalidName, invalidFileType, missingDirectory, ambiguousDirectory, itemExists, unsupportedAction

    public var errorDescription: String? {
        switch self {
        case .invalidFileType: "请输入有效后缀：支持点分隔的复合后缀，不能包含路径分隔符、冒号、空白或控制字符，且名称不能过长。"
        case .invalidRequest: "无法识别访达传来的操作，请重新打开右键菜单。"
        case .invalidName: "名称不能为空、包含斜杠、冒号、换行，或使用「.」与「..」。"
        case .missingDirectory: "目标目录已不存在，或当前没有可用的文件夹。"
        case .ambiguousDirectory: "请选择一个文件夹，或同一目录中的文件后再执行此操作。"
        case .itemExists: "同名项目已存在，请使用其他名称。"
        case .unsupportedAction: "当前操作不支持创建项目。"
        }
    }
}
