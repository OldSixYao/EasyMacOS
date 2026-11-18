import AppKit

/// 手势只更新裁剪路径，低分辨率取样片段在后台按需生成；提交后等对应预览就绪再移除。
@MainActor final class ScreenshotMosaicPreview {
    private struct Layer {
        let id = UUID()
        let preceding: [ScreenshotAnnotation]
        var annotation: ScreenshotAnnotation
        var committed = false
        var patches: [ScreenshotMosaicTile: ScreenshotMosaicPatch] = [:]
    }
    private struct Request {
        let layer: UUID
        let preceding: [ScreenshotAnnotation]
        let tiles: [ScreenshotMosaicTile]
        let blockSize: CGFloat
    }
    private var layers: [Layer] = []
    private var active: UUID?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var failed = false
    private var visibleRegion = CGRect.zero
    private var pointSize = CGSize.zero
    var onChange: (() -> Void)?
    var onError: ((Error) -> Void)?
    var hasLayers: Bool { !layers.isEmpty }
    var cachedBytes: Int { layers.reduce(0) { $0 + $1.patches.values.reduce(0) { $0 + $1.cost } } }

    func begin(_ annotation: ScreenshotAnnotation, preceding: [ScreenshotAnnotation]) {
        guard annotation.tool == .mosaic, annotation.mosaic != nil else { return }
        let layer = Layer(preceding: preceding, annotation: annotation)
        layers.append(layer); active = layer.id; failed = false
    }
    func update(_ annotation: ScreenshotAnnotation) {
        if let index = layers.firstIndex(where: { $0.id == active }) { layers[index].annotation = annotation }
    }
    func end(commit: Bool) {
        if let index = layers.firstIndex(where: { $0.id == active }) {
            if commit { layers[index].committed = true }
            else { layers.remove(at: index) }
        }
        active = nil
    }
    func reconcile(history: [ScreenshotAnnotation]) {
        layers.removeAll { layer in
            if !layer.committed { return history != layer.preceding }
            return !contains(layer, in: history)
        }
        if !layers.contains(where: { $0.id == active }) { active = nil }
        if layers.isEmpty { cancelTask() }
    }
    func acknowledge(_ rendered: [ScreenshotAnnotation]) {
        layers.removeAll { $0.committed && contains($0, in: rendered) }
        if layers.isEmpty { cancelTask() }
    }
    private func contains(_ layer: Layer, in history: [ScreenshotAnnotation]) -> Bool {
        history.count > layer.preceding.count && history.starts(with: layer.preceding)
            && history[layer.preceding.count] == layer.annotation
    }

    func request(base: CGImage, pointSize: CGSize, visibleRegion: CGRect) {
        self.pointSize = pointSize; self.visibleRegion = visibleRegion
        let wanted = desiredTiles()
        for index in layers.indices {
            let keep = Set(wanted[layers[index].id] ?? [])
            layers[index].patches = layers[index].patches.filter { keep.contains($0.key) }
        }
        guard task == nil, !failed, hasLayers else { return }
        let version = generation
        task = Task { [weak self] in
            while !Task.isCancelled, let request = self?.nextRequest() {
                do {
                    let patches = try await ScreenshotRenderWorker.shared.mosaicSources(base: base, pointSize: pointSize,
                        annotations: request.preceding, tiles: request.tiles, blockSize: request.blockSize)
                    guard !Task.isCancelled, let self, self.generation == version else { return }
                    if let index = self.layers.firstIndex(where: { $0.id == request.layer }) {
                        let wanted = Set(self.desiredTiles()[request.layer] ?? [])
                        for patch in patches where wanted.contains(patch.tile) { self.layers[index].patches[patch.tile] = patch }
                        self.onChange?()
                    }
                } catch {
                    guard !Task.isCancelled, let self, self.generation == version else { return }
                    self.failed = true; self.onError?(error)
                    break
                }
            }
            guard let self, self.generation == version else { return }
            self.task = nil
        }
    }
    private func desiredTiles() -> [UUID: [ScreenshotMosaicTile]] {
        // 每片至多占六万五千五百三十六字节，所有待提交图层共用十六兆字节上限。
        var remaining = ScreenshotRenderer.mosaicCacheLimit / (ScreenshotMosaicTile.cells * ScreenshotMosaicTile.cells * 4)
        var wanted: [UUID: [ScreenshotMosaicTile]] = [:]
        for layer in layers.reversed() {
            let region = layer.annotation.coverageBounds.intersection(visibleRegion)
            let tiles = ScreenshotMosaicTile.covering(region, pointSize: pointSize,
                blockSize: layer.annotation.mosaic!.resolvedBlockSize)
            wanted[layer.id] = Array(tiles.prefix(remaining))
            remaining -= min(remaining, tiles.count)
        }
        return wanted
    }
    private func nextRequest() -> Request? {
        let wanted = desiredTiles()
        for layer in layers {
            let missing = (wanted[layer.id] ?? []).filter { layer.patches[$0] == nil }
            if !missing.isEmpty {
                return Request(layer: layer.id, preceding: layer.preceding,
                    tiles: Array(missing.prefix(8)), blockSize: layer.annotation.mosaic!.resolvedBlockSize)
            }
        }
        return nil
    }
    func draw(in context: CGContext) {
        context.saveGState()
        context.clip(to: CGRect(origin: .zero, size: pointSize))
        for layer in layers {
            context.saveGState()
            layer.annotation.clipMosaic(in: context)
            for patch in layer.patches.values { patch.draw(in: context) }
            context.restoreGState()
        }
        context.restoreGState()
    }
    func waitForSources() async { await task?.value }
    private func cancelTask() {
        generation += 1; task?.cancel(); task = nil
    }
    func clear() {
        cancelTask(); layers.removeAll(); active = nil; failed = false
    }
    func dispose() { clear(); onChange = nil; onError = nil }
}
