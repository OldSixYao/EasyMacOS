import AppKit
import PasteManCore
import SwiftUI

struct HistoryView: View {
    @Bindable var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let preview = model.preview {
                DetailView(entry: preview, model: model)
            } else {
                header
                filters
                if model.settings.paused {
                    notice(L.t("Recording paused", "已暂停记录"), symbol: "pause.circle", action: { model.onPause?() })
                } else if model.permissions.clipboard != .allowed {
                    notice(
                        L.t("Allow clipboard access to record history", "允许访问剪贴板后即可记录历史"), symbol: "lock.shield",
                        action: model.permissions.requestClipboardAccess)
                }
                if let message = model.message ?? model.recordingIssue {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle").foregroundStyle(.orange)
                        Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button(L.t("Retry", "重试")) { model.retryHistory() }.buttonStyle(.plain)
                        Button {
                            model.message = nil
                            model.recordingIssue = nil
                        } label: {
                            Image(systemName: "xmark")
                        }.buttonStyle(.plain)
                    }.padding(10).background(.orange.opacity(0.08))
                }
                history
                footer
            }
        }
        .frame(width: 440, height: 590)
        .background(.regularMaterial)
        .onAppear { searchFocused = true }
        .onChange(of: model.search) { model.refresh() }
        .onChange(of: model.filter) { model.refresh() }
        .onChange(of: model.source) { model.refresh() }
        .onChange(of: model.panelVisible) {
            if model.panelVisible { searchFocused = true }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L.t("Search your clipboard…", "搜索剪贴板历史…"), text: $model.search)
                .textFieldStyle(.plain).font(.system(size: 15)).focused($searchFocused)
                .accessibilityLabel(L.t("Search clipboard history", "搜索剪贴板历史"))
            if !model.search.isEmpty {
                Button {
                    model.search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }.buttonStyle(.plain)
            }
            Text(model.settings.shortcut.label).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
        }.padding(16)
    }
    private var filters: some View {
        HStack(spacing: 5) {
            ForEach(HistoryFilter.allCases, id: \.self) { filter in
                Button {
                    model.filter = filter
                } label: {
                    Text(L.filter(filter)).font(
                        .system(size: 12, weight: model.filter == filter ? .semibold : .regular)
                    )
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(model.filter == filter ? Color.accentColor.opacity(0.12) : .clear, in: Capsule())
                    .foregroundStyle(model.filter == filter ? Color.accentColor : .secondary)
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(model.filter == filter ? .isSelected : [])
            }
            Spacer(minLength: 0)
            Menu {
                Button(L.t("All applications", "所有应用")) { model.source = "" }
                Divider()
                ForEach(model.sources) { app in
                    Button {
                        model.source = app.bundleID
                    } label: {
                        if model.source == app.bundleID {
                            Label(app.name, systemImage: "checkmark")
                        } else {
                            Text(app.name)
                        }
                    }
                }
            } label: {
                Image(
                    systemName: model.source.isEmpty
                        ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill"
                )
                .font(.system(size: 17)).foregroundStyle(model.source.isEmpty ? Color.secondary : Color.accentColor)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(L.t("Filter by application", "按来源应用筛选"))
        }.padding(.horizontal, 12).padding(.bottom, 10)
    }
    private func notice(_ text: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: symbol)
                Text(text)
                Spacer()
                Image(systemName: "chevron.right")
            }
            .font(.caption).padding(10).foregroundStyle(.secondary)
        }.buttonStyle(.plain).background(.quaternary.opacity(0.4))
    }
    private var history: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.entries) { entry in
                        HistoryRow(entry: entry, model: model).id(entry.id)
                            .onAppear { if entry.id == model.entries.last?.id { model.loadMore() } }
                    }
                }.padding(.horizontal, 8).padding(.vertical, 6)
            }
            .overlay {
                if model.entries.isEmpty {
                    ContentUnavailableView {
                        Label(
                            model.search.isEmpty && model.filter == .all && model.source.isEmpty
                                ? L.t("A little space for your copies", "留住每一次复制")
                                : L.t("No matching items", "没有匹配的记录"),
                            systemImage: "doc.on.clipboard")
                    } description: {
                        Text(
                            model.search.isEmpty && model.filter == .all && model.source.isEmpty
                                ? L.t(
                                    "Copy text or an image in any app.\nIt will be waiting here.",
                                    "在任意应用复制文本或图片，\n稍后都能在这里找到。")
                                : L.t("Try another search or filter.", "试试其他关键词或筛选条件。"))
                    }
                }
            }
            .onChange(of: model.selection) {
                if let id = model.selection {
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }
    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Text("\(model.entries.count)" + (model.hasMore ? "+ " : " ") + L.t("items", "条记录")).font(.caption).foregroundStyle(.tertiary)
                if model.loading || model.loadingMore { ProgressView().controlSize(.mini) }
                Spacer()
                Text(L.t("↑↓ select   ↩ paste", "↑↓ 选择   ↩ 粘贴")).font(.system(size: 10)).foregroundStyle(.tertiary)
                Button {
                    model.onMenu?()
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 15))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(L.t("More actions", "更多操作"))
            }.padding(.horizontal, 16).padding(.vertical, 12)
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    @Bindable var model: AppModel
    @ViewState private var hovering = false
    var selected: Bool { model.selection == entry.id }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                if entry.kind == .image {
                    StoredImage(id: entry.id, repository: model.repository, thumbnail: true)
                        .frame(width: 40, height: 40).clipped().clipShape(RoundedRectangle(cornerRadius: 7))
                } else {
                    Image(systemName: "text.alignleft").font(.system(size: 20, weight: .light)).foregroundStyle(
                        .secondary
                    )
                    .frame(width: 40, height: 40).background(
                        .quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                }
            }.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                if entry.kind == .text {
                    Text(entry.preview).lineLimit(2).font(.system(size: 13)).frame(
                        maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(L.t("Image", "图片")).font(.system(size: 13))
                }
                Text(entry.sourceName).lineLimit(1)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            VStack(spacing: 10) {
                Button {
                    model.toggleFavorite(entry)
                } label: {
                    Image(systemName: entry.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(entry.isFavorite ? Color.orange : .secondary)
                }.help(entry.isFavorite ? L.t("Remove favorite", "取消收藏") : L.t("Favorite", "收藏"))
                Button {
                    model.activate(entry)
                } label: {
                    Image(systemName: "return").foregroundStyle(.secondary)
                }
                .help(L.t("Paste", "粘贴"))
            }.buttonStyle(.plain).opacity(hovering || selected || entry.isFavorite ? 1 : 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selected ? Color.accentColor.opacity(0.10) : (hovering ? Color.primary.opacity(0.035) : .clear),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            model.selection = entry.id
            model.activate(entry)
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: L.t("Paste", "粘贴")) { model.activate(entry) }
        .contextMenu {
            Button(L.t("Paste", "粘贴"), systemImage: "return") { model.activate(entry) }
            Button(L.t("Copy only", "仅复制"), systemImage: "doc.on.doc") { model.activate(entry, copyOnly: true) }
            Button(L.t("View full content", "查看完整内容"), systemImage: "eye") { model.preview = entry }
            Divider()
            Button(
                entry.isFavorite ? L.t("Remove favorite", "取消收藏") : L.t("Favorite", "收藏"),
                systemImage: entry.isFavorite ? "star.slash" : "star"
            ) { model.toggleFavorite(entry) }
            Button(L.t("Delete", "删除"), systemImage: "trash", role: .destructive) { model.delete(entry) }
        }
    }
}

struct StoredImage: View {
    let id: UUID
    let repository: any HistoryRepository
    let thumbnail: Bool
    @Environment(\.displayScale) private var displayScale
    @ViewState private var image: NSImage?
    @ViewState private var failed = false
    var body: some View {
        GeometryReader { geometry in
            let pixelSize = max(1, Int(ceil(max(geometry.size.width, geometry.size.height) * displayScale)))
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else if failed {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: ImageRequest(id: id, maximumPixelSize: pixelSize)) {
                do {
                    try Task.checkCancellation()
                    let cache = ThumbnailCache.shared
                    if thumbnail, let cached = cache.image(id: id, pixelSize: pixelSize) {
                        image = NSImage(cgImage: cached, size: .zero)
                        failed = false
                        return
                    }
                    let cacheGeneration = cache.generation
                    let data = try await repository.imageData(for: id, thumbnail: thumbnail)
                    try Task.checkCancellation()
                    let decoded = try await DisplayImageDecoder.shared.decode(data, maximumPixelSize: pixelSize)
                    try Task.checkCancellation()
                    if thumbnail {
                        cache.insert(decoded, id: id, pixelSize: pixelSize, generation: cacheGeneration)
                    }
                    image = NSImage(cgImage: decoded, size: .zero)
                    failed = false
                } catch is CancellationError {
                    // Closing a panel is normal; do not display a broken-image state.
                } catch {
                    guard !Task.isCancelled else { return }
                    failed = true
                }
            }
            .onDisappear {
                image = nil
            }
        }
    }

    private struct ImageRequest: Equatable {
        let id: UUID
        let maximumPixelSize: Int
    }
}

private struct DetailView: View {
    let entry: HistoryEntry
    @Bindable var model: AppModel
    @ViewState private var text: String?
    @ViewState private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    model.preview = nil
                } label: {
                    Label(L.t("Back", "返回"), systemImage: "chevron.left")
                }.buttonStyle(.plain)
                Spacer()
                Text(entry.sourceName).font(.caption).foregroundStyle(.secondary)
            }.padding(16)
            Divider()
            if entry.kind == .image {
                StoredImage(id: entry.id, repository: model.repository, thumbnail: false).padding().frame(
                    maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Group {
                    if let text {
                        TextPreview(text: text)
                    } else if let error {
                        Text(error).padding()
                    } else {
                        ProgressView().padding()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Spacer()
                Button(L.t("Copy only", "仅复制")) { model.activate(entry, copyOnly: true) }
                Button(L.t("Paste", "粘贴")) { model.activate(entry) }.buttonStyle(.borderedProminent)
            }.padding(16)
        }
        .task(id: entry.id) {
            guard entry.kind == .text else { return }
            text = nil
            error = nil
            do {
                let content = try await model.repository.content(for: entry)
                try Task.checkCancellation()
                if case .text(let value) = content { text = value }
            } catch is CancellationError {} catch {
                self.error = L.error(error)
            }
        }
    }
}
