import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageProcessor {
    public static let maximumInputBytes = 20 * 1024 * 1024
    public static let maximumPixels = 40_000_000

    public static func prepare(_ data: Data) throws -> PreparedContent {
        try Task.checkCancellation()
        guard data.count <= maximumInputBytes else { throw StoreError.imageTooLarge }
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0
        else { throw StoreError.invalidImage }
        guard width <= maximumPixels / height else { throw StoreError.imageTooLarge }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
            let thumb = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 240,
                ] as CFDictionary)
        else { throw StoreError.invalidImage }
        return .image(png: try encode(image), thumbnail: try encode(thumb))
    }

    /// 仅供应用自身渲染、已经去除元数据的截图使用；不接收外部剪贴板位图。
    public static func prepareRenderedImage(_ image: CGImage, png: Data) throws -> PreparedContent {
        try Task.checkCancellation()
        guard png.count <= maximumInputBytes, image.height > 0, image.width <= maximumPixels / image.height else {
            throw StoreError.imageTooLarge
        }
        let ratio = min(1, 240 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * ratio))
        let height = max(1, Int(Double(image.height) * ratio))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw StoreError.invalidImage }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let thumbnail = context.makeImage() else { throw StoreError.invalidImage }
        return .image(png: png, thumbnail: try encode(thumbnail))
    }

    private static func encode(_ image: CGImage) throws -> Data {
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw StoreError.invalidImage
        }
        // Encode pixels only: source metadata (including location) is not retained.
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw StoreError.invalidImage }
        return data as Data
    }

    /// Decode only the pixels needed for display, never a full-resolution preview buffer.
    public static func decodeForDisplay(_ data: Data, maximumPixelSize: Int) throws -> CGImage {
        try Task.checkCancellation()
        guard maximumPixelSize > 0,
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0, width <= maximumPixels / height,
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: min(maximumPixelSize, max(width, height)),
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        else { throw StoreError.invalidImage }
        try Task.checkCancellation()
        return image
    }
}
