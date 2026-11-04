import AppKit

/// Panel lifetimes are short; keep a small, bounded working set of decoded thumbnails.
/// Full-size previews are deliberately owned only by their views.
@MainActor final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private struct Key: Hashable {
        let id: UUID
        let pixelSize: Int
    }
    private struct Value {
        let image: CGImage
        let cost: Int
        var access: UInt64
    }
    private let byteLimit: Int
    private var values: [Key: Value] = [:]
    private var bytes = 0
    private var access: UInt64 = 0
    private(set) var generation = 0
    private var pressureSource: DispatchSourceMemoryPressure?

    init(byteLimit: Int = 8 * 1024 * 1024) {
        self.byteLimit = max(0, byteLimit)
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.removeAll() }
        }
        source.resume()
        pressureSource = source
    }

    deinit { pressureSource?.cancel() }

    func image(id: UUID, pixelSize: Int) -> CGImage? {
        let key = Key(id: id, pixelSize: pixelSize)
        guard var value = values[key] else { return nil }
        access &+= 1
        value.access = access
        values[key] = value
        return value.image
    }

    func insert(_ image: CGImage, id: UUID, pixelSize: Int, generation: Int) {
        // An asynchronous decode started before clear/delete must not repopulate the cache.
        guard generation == self.generation else { return }
        let cost = image.bytesPerRow * image.height
        guard cost <= byteLimit else { return }
        let key = Key(id: id, pixelSize: pixelSize)
        if let previous = values.removeValue(forKey: key) { bytes -= previous.cost }
        while bytes + cost > byteLimit,
            let oldest = values.min(by: { $0.value.access < $1.value.access })?.key,
            let removed = values.removeValue(forKey: oldest)
        {
            bytes -= removed.cost
        }
        access &+= 1
        values[key] = Value(image: image, cost: cost, access: access)
        bytes += cost
    }

    func remove(_ id: UUID) {
        generation += 1
        for key in values.keys.filter({ $0.id == id }) {
            if let removed = values.removeValue(forKey: key) { bytes -= removed.cost }
        }
    }

    func retain(_ ids: Set<UUID>) {
        let removed = Set(values.keys.map(\.id)).subtracting(ids)
        for id in removed { remove(id) }
    }

    func removeAll() {
        generation += 1
        values.removeAll()
        bytes = 0
    }
}
