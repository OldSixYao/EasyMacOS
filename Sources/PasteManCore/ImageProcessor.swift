import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageProcessor {
    public static let maximumInputBytes = 20 * 1024 * 1024
    public static let maximumPixels = 40_000_000

    public static func prepare(_ data: Data) throws -> PreparedContent {
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

    private static func encode(_ image: CGImage) throws -> Data {
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
