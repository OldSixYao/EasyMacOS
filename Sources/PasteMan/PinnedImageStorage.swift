import AppKit
import ImageIO
import PasteManCore

/// 原图由私有临时目录持有；显示缓存只拥有缩小后的位图。
final class PinnedImageStorage: Sendable {
    let id = UUID()
    let pointSize: CGSize
    private let directory: URL
    private let stored: Task<URL, Error>
    private let rawSize: CGSize?

    init(png: Data, pointSize: CGSize) {
        self.pointSize = pointSize
        rawSize = nil
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EasyMacOS-Pin-" + UUID().uuidString)
        self.directory = directory
        stored = Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("image.png")
            try png.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        }
    }

    /// 工作线程写出选区像素，既解除对整屏裁剪缓冲的引用，也避免钉图时立即压缩。
    init(image: CGImage, pointSize: CGSize) throws {
        self.pointSize = pointSize
        rawSize = CGSize(width: image.width, height: image.height)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EasyMacOS-Pin-" + UUID().uuidString)
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: directory) } }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScreenshotImageError.allocationFailed }
        context.draw(image, in: CGRect(origin: .zero, size: rawSize!))
        guard let bytes = context.data else { throw ScreenshotImageError.allocationFailed }
        let url = directory.appendingPathComponent("pixels.rgba")
        do {
            try Data(bytesNoCopy: bytes, count: context.bytesPerRow * image.height, deallocator: .none).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
        stored = Task { url }
        completed = true
    }

    deinit {
        let directory = directory
        let stored = stored
        Task.detached(priority: .utility) {
            _ = await stored.result
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func loadImage() async throws -> CGImage {
        defer { withExtendedLifetime(self) {} }
        let url = try await stored.value
        return try await PinnedImageWorker.shared.load(url: url, rawSize: rawSize)
    }
    func png() async throws -> Data {
        defer { withExtendedLifetime(self) {} }
        let url = try await stored.value
        return try await PinnedImageWorker.shared.png(url: url, rawSize: rawSize)
    }
    func display(maximumPixels: Int) async throws -> CGImage {
        defer { withExtendedLifetime(self) {} }
        let url = try await stored.value
        return try await PinnedImageWorker.shared.display(url: url, rawSize: rawSize, maximumPixels: maximumPixels)
    }
}

actor PinnedImageWorker {
    static let shared = PinnedImageWorker()
    func archive(base: CGImage, pointSize: CGSize, annotations: [ScreenshotAnnotation]) async throws -> PinnedImageStorage {
        let cost = base.bytesPerRow * base.height * (annotations.isEmpty ? 1 : 2)
        if let result = try ImageWorkBudget.shared.performIfAvailable(estimatedBytes: cost, operation: {
            try archiveAdmitted(base: base, pointSize: pointSize, annotations: annotations)
        }) { return result }
        return try await ImageWorkBudget.shared.withPermit(estimatedBytes: cost, priority: .userInitiated) {
            try await self.archiveAdmitted(base: base, pointSize: pointSize, annotations: annotations)
        }
    }
    private func archiveAdmitted(base: CGImage, pointSize: CGSize, annotations: [ScreenshotAnnotation]) throws -> PinnedImageStorage {
        try Task.checkCancellation()
        guard pointSize.width.isFinite, pointSize.height.isFinite, pointSize.width > 0, pointSize.height > 0,
            base.height > 0, base.width <= 100_000_000 / base.height else { throw ScreenshotImageError.allocationFailed }
        return try autoreleasepool {
            let image = annotations.isEmpty ? base : try ScreenshotRenderer.render(base: base, pointSize: pointSize, annotations: annotations)
            return try PinnedImageStorage(image: image, pointSize: pointSize)
        }
    }
    func load(url: URL, rawSize: CGSize?) throws -> CGImage {
        try Task.checkCancellation()
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        if let rawSize {
            guard let provider = CGDataProvider(data: data as CFData),
                let image = CGImage(width: Int(rawSize.width), height: Int(rawSize.height), bitsPerComponent: 8,
                    bitsPerPixel: 32, bytesPerRow: Int(rawSize.width) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { throw ScreenshotImageError.allocationFailed }
            return image
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ScreenshotImageError.allocationFailed }
        return image
    }
    func png(url: URL, rawSize: CGSize?) async throws -> Data {
        let cost = rawSize.map { Int($0.width) * Int($0.height) * 4 } ?? 1
        if let result = try ImageWorkBudget.shared.performIfAvailable(estimatedBytes: cost, operation: {
            try pngAdmitted(url: url, rawSize: rawSize)
        }) { return result }
        return try await ImageWorkBudget.shared.withPermit(estimatedBytes: cost, priority: .userInitiated) {
            try await self.pngAdmitted(url: url, rawSize: rawSize)
        }
    }
    private func pngAdmitted(url: URL, rawSize: CGSize?) throws -> Data {
        try Task.checkCancellation()
        if rawSize == nil { return try Data(contentsOf: url, options: .alwaysMapped) }
        let encoded = url.deletingLastPathComponent().appendingPathComponent("image.png")
        if !FileManager.default.fileExists(atPath: encoded.path) {
            let data = try autoreleasepool { try ScreenshotRenderer.encode(load(url: url, rawSize: rawSize)) }
            try data.write(to: encoded, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: encoded.path)
        }
        return try Data(contentsOf: encoded, options: .alwaysMapped)
    }
    func display(url: URL, rawSize: CGSize?, maximumPixels: Int) async throws -> CGImage {
        let pixels = max(1, min(4096, maximumPixels))
        let sourceBytes = rawSize.map { Int($0.width) * Int($0.height) * 4 } ?? 0
        let cost = sourceBytes + pixels * pixels * 4
        if let result = try ImageWorkBudget.shared.performIfAvailable(estimatedBytes: cost, operation: {
            try displayAdmitted(url: url, rawSize: rawSize, maximumPixels: maximumPixels)
        }) { return result }
        return try await ImageWorkBudget.shared.withPermit(estimatedBytes: cost, priority: .display) {
            try await self.displayAdmitted(url: url, rawSize: rawSize, maximumPixels: maximumPixels)
        }
    }
    private func displayAdmitted(url: URL, rawSize: CGSize?, maximumPixels: Int) throws -> CGImage {
        try autoreleasepool {
            try Task.checkCancellation()
            guard maximumPixels > 0 else { throw ScreenshotImageError.allocationFailed }
            if rawSize == nil {
                // 压缩后备直接按显示尺寸解码，不先还原完整原图再缩放。
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                    let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
                        kCGImageSourceShouldCacheImmediately: true,
                    ] as CFDictionary) else { throw ScreenshotImageError.allocationFailed }
                try Task.checkCancellation()
                return image
            }
            let image = try load(url: url, rawSize: rawSize)
            let ratio = min(1, Double(maximumPixels) / Double(max(image.width, image.height)))
            let size = CGSize(width: max(1, Int(Double(image.width) * ratio)), height: max(1, Int(Double(image.height) * ratio)))
            guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScreenshotImageError.allocationFailed }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(origin: .zero, size: size))
            try Task.checkCancellation()
            guard let result = context.makeImage() else { throw ScreenshotImageError.allocationFailed }
            return result
        }
    }
}
