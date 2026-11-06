import AppKit
import FinderMenuCore

@MainActor final class FinderActionHandler {
    func perform(_ request: FinderRequest) async {
        do {
            switch request.action {
            case .cut:
                _ = try await FinderFileWorker.shared.validateSources(request.items)
                try FinderCutClipboard().cut(request.items, validateFiles: false)
            case .pasteMove:
                guard let token = request.cutToken else { throw FinderMenuError.invalidRequest }
                let directory = try await FinderFileWorker.shared.directory(for: request.items)
                try await FinderMoveCoordinator().move(token: token, to: directory, clipboard: FinderCutClipboard())
            case .newText:
                let created = try await FinderFileWorker.shared.create(suffix: request.suffix ?? "txt", items: request.items)
                await FinderRenameCoordinator().revealAndRename(created)
            case .openTerminal:
                let directory = try await FinderFileWorker.shared.directory(for: request.items)
                try FinderTerminalService().open(directory: directory)
            case .copyPath, .copyName:
                let value = try FinderOperations.clipboardText(for: request.action, items: request.items)
                NSPasteboard.general.clearContents()
                if !NSPasteboard.general.setString(value, forType: .string) {
                    throw NSError(
                        domain: "EasyMacOS.Finder", code: 2, userInfo: [NSLocalizedDescriptionKey: L.t("Could not write to the clipboard. Try again.", "无法写入剪贴板，请重试。")])
                }
            }
        } catch { Self.show(error) }
    }

    static func show(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L.t("Action not completed", "操作未完成")
        alert.informativeText = (error as? FinderMenuError)?.description(in: L.language)
            ?? (error as? FinderMoveError)?.description(in: L.language) ?? error.localizedDescription
        NSApp.activate()
        alert.runModal()
    }
}
