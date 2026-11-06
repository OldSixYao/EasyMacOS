import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 图标只用于设置和菜单，不修改创建文件的系统图标。
public struct FinderFileTypeIconStore: Sendable {
    public let directory: URL

    public init(configurationStore: FinderConfigurationStore = FinderConfigurationStore()) {
        directory = configurationStore.url.deletingLastPathComponent().appendingPathComponent("file-type-icons", isDirectory: true)
    }

    public func url(for resource: String) -> URL? {
        guard FinderFileType.isValidIconResource(resource) else { return nil }
        let url = directory.appendingPathComponent(resource)
        guard url.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath() else { return nil }
        return url
    }

    /// 直接在解码阶段缩小，避免先载入完整大图；输出统一为带透明通道的标准图片。
    public func importImage(at sourceURL: URL) throws -> String {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
            let image = Self.thumbnail(source: source, maximumSize: 128),
            let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw FinderMenuError.invalidIcon }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let output = context.makeImage() else { throw FinderMenuError.invalidIcon }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw FinderMenuError.invalidIcon
        }
        CGImageDestinationAddImage(destination, output, nil)
        guard CGImageDestinationFinalize(destination) else { throw FinderMenuError.invalidIcon }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let resource = UUID().uuidString + ".png"
        try (data as Data).write(to: directory.appendingPathComponent(resource), options: .atomic)
        return resource
    }

    public func image(resource: String) -> NSImage? {
        guard let url = url(for: resource), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = Self.thumbnail(source: source, maximumSize: 128) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    public func remove(resource: String) {
        guard let url = url(for: resource) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func thumbnail(source: CGImageSource, maximumSize: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }
}

public enum FinderFileTypeIcon {
    /// 菜单跨进程传递时使用实体位图；彩色图标不能带模板着色标记。
    public static func image(for type: FinderFileType, store: FinderFileTypeIconStore = FinderFileTypeIconStore(), size: Int = 18) -> NSImage {
        let custom = type.iconResource.flatMap { store.image(resource: $0) }
        let style = defaultStyle(for: type.suffix)
        let source = custom ?? NSImage(systemSymbolName: style.symbol, accessibilityDescription: nil)
        let image = NSImage(size: NSSize(width: size, height: size))
        for scale in [1, 2] {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size * scale, pixelsHigh: size * scale,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
            bitmap.size = image.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            if let source, source.size.width > 0, source.size.height > 0 {
                let available = CGFloat(size - 2)
                let ratio = min(available / source.size.width, available / source.size.height)
                source.draw(in: NSRect(x: (CGFloat(size) - source.size.width * ratio) / 2,
                    y: (CGFloat(size) - source.size.height * ratio) / 2,
                    width: source.size.width * ratio, height: source.size.height * ratio))
                if custom == nil {
                    style.color.setFill()
                    NSRect(origin: .zero, size: image.size).fill(using: .sourceIn)
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(bitmap)
        }
        image.isTemplate = false
        return image
    }

    private static func defaultStyle(for suffix: String) -> (symbol: String, color: NSColor) {
        switch suffix {
        case "docx": ("doc.text.fill", NSColor(srgbRed: 0.15, green: 0.40, blue: 0.82, alpha: 1))
        case "xlsx": ("tablecells.fill", NSColor(srgbRed: 0.12, green: 0.57, blue: 0.32, alpha: 1))
        case "pptx": ("rectangle.on.rectangle.fill", NSColor(srgbRed: 0.86, green: 0.35, blue: 0.14, alpha: 1))
        case "pdf": ("doc.richtext.fill", NSColor(srgbRed: 0.84, green: 0.19, blue: 0.24, alpha: 1))
        case "txt": ("doc.text", .systemGray)
        case "json": ("curlybraces", .systemOrange)
        case "xml": ("chevron.left.forwardslash.chevron.right", .systemTeal)
        case "md": ("text.alignleft", .systemBlue)
        case "csv": ("tablecells", .systemGreen)
        case "html": ("globe", .systemOrange)
        case "css": ("paintbrush.pointed", .systemPurple)
        case "js": ("curlybraces.square", .systemYellow)
        default: ("doc", .systemGray)
        }
    }
}
