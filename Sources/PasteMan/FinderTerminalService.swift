import AppKit

@MainActor struct FinderTerminalService {
    var performService: (String, NSPasteboard) -> Bool = { NSPerformService($0, $1) }

    func open(directory: URL) throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        // 系统终端会分别消费文件对象和纯文本路径；同时提供会打开两个窗口。
        // 只提供一个目录对象，保留特殊字符路径，也不改写用户剪贴板。
        guard board.writeObjects([directory as NSURL]), performService("New Terminal at Folder", board) else {
            throw NSError(
                domain: "EasyMacOS.Finder", code: 1,
                userInfo: [NSLocalizedDescriptionKey: L.t("The Terminal service is unavailable. Try again later.", "系统终端服务不可用，请稍后重试。")])
        }
    }
}
