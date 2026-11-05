import AppKit
import FinderMenuCore

@MainActor final class FinderActionHandler {
    func perform(_ request: FinderRequest) async {
        do {
            switch request.action {
            case .cut:
                try FinderCutClipboard().cut(request.items)
            case .pasteMove:
                guard let token = request.cutToken else { throw FinderMenuError.invalidRequest }
                let directory = try FinderOperations.directory(for: request.items)
                try await FinderMoveCoordinator().move(token: token, to: directory, clipboard: FinderCutClipboard())
            case .newText:
                let directory = try FinderOperations.directory(for: request.items)
                let created = try FinderOperations.createFile(suffix: request.suffix ?? "txt", in: directory)
                await FinderRenameCoordinator().revealAndRename(created)
            case .openTerminal:
                let directory = try FinderOperations.directory(for: request.items)
                try FinderTerminalService().open(directory: directory)
            case .copyPath, .copyName:
                let value = try FinderOperations.clipboardText(for: request.action, items: request.items)
                NSPasteboard.general.clearContents()
                if !NSPasteboard.general.setString(value, forType: .string) {
                    throw NSError(
                        domain: "EasyMacOS.Finder", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法写入剪贴板，请重试。"])
                }
            }
        } catch { Self.show(error) }
    }

    static func show(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "操作未完成"
        alert.informativeText = error.localizedDescription
        NSApp.activate()
        alert.runModal()
    }
}
