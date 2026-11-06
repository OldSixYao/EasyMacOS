import AppKit
import FinderMenuCore

@MainActor struct FinderCutClipboard {
    static let markerType = NSPasteboard.PasteboardType("app.pasteman.PasteMan.finder-cut-token")
    let board: NSPasteboard
    let store: FinderCutStateStore

    init(board: NSPasteboard = .general, store: FinderCutStateStore = FinderCutStateStore()) {
        self.board = board
        self.store = store
    }

    @discardableResult func cut(_ sources: [URL], validateFiles: Bool = true) throws -> FinderCutState {
        let sources = validateFiles ? try FinderMoveValidation.sources(sources) : sources
        let previousID = try store.load()?.commandID ?? 0
        guard previousID < FinderCutState.maximumCommandID else { throw FinderMoveError.expiredCut }
        let token = UUID()
        let items = sources.map { url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            item.setString(token.uuidString, forType: Self.markerType)
            return item
        }
        board.clearContents()
        guard board.writeObjects(items) else { throw FinderMoveError.clipboardUnavailable }
        let state = FinderCutState(
            token: token, changeCount: board.changeCount, fileCount: sources.count, commandID: previousID + 1)
        try store.save(state)
        return state
    }

    func current(token: UUID, validateFiles: Bool = true) throws -> (FinderCutState, [URL]) {
        guard let state = try store.load(), state.availableToken(changeCount: board.changeCount) == token else {
            throw FinderMoveError.expiredCut
        }
        return (state, try files(matching: state, validateFiles: validateFiles))
    }

    func files(matching state: FinderCutState, validateFiles: Bool = true) throws -> [URL] {
        guard board.changeCount == state.changeCount,
            let items = board.pasteboardItems, items.count == state.fileCount else { throw FinderMoveError.expiredCut }
        let files = try items.map { item -> URL in
            guard item.string(forType: Self.markerType) == state.token.uuidString,
                let value = item.string(forType: .fileURL), let url = URL(string: value), url.isFileURL
            else { throw FinderMoveError.expiredCut }
            return url
        }
        guard board.changeCount == state.changeCount else { throw FinderMoveError.expiredCut }
        return validateFiles ? try FinderMoveValidation.sources(files) : files.map(\.standardizedFileURL)
    }

    func consume(_ state: FinderCutState, validateFiles: Bool = true) throws {
        guard try store.load() == state else { throw FinderMoveError.expiredCut }
        _ = try files(matching: state, validateFiles: validateFiles)
        var consumed = state
        consumed.consumed = true
        try store.save(consumed)
    }

    func restore(_ state: FinderCutState) throws {
        guard let current = try store.load(), current.token == state.token, current.consumed,
            board.changeCount == state.changeCount, (try? files(matching: state)) != nil else { return }
        try store.save(state)
    }
}
