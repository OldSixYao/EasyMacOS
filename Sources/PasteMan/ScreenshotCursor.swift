import AppKit

struct ScreenshotCursorSample {
    let x: Int
    let y: Int
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
}

/// Samples the frozen source, so neither the selection mask nor the magnifier affects the value.
/// Only a single source pixel is converted to sRGB; no full-display buffer is allocated on mouse movement.
final class ScreenshotPixelSampler {
    let image: CGImage
    private let context: CGContext
    init?(image: CGImage) {
        guard
            let context = CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        self.image = image
        self.context = context
        context.interpolationQuality = .none
    }
    func sample(at point: CGPoint, pointSize: CGSize) -> ScreenshotCursorSample? {
        guard pointSize.width > 0, pointSize.height > 0, point.x.isFinite, point.y.isFinite else { return nil }
        let x = Int(min(max(0, floor(point.x / pointSize.width * CGFloat(image.width))), CGFloat(image.width - 1)))
        let y = Int(min(max(0, floor(point.y / pointSize.height * CGFloat(image.height))), CGFloat(image.height - 1)))
        guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)), let data = context.data else {
            return nil
        }
        context.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        func component(_ index: Int) -> UInt8 {
            guard bytes[3] != 0 else { return 0 }
            return UInt8(min(255, Int(bytes[index]) * 255 / Int(bytes[3])))
        }
        return ScreenshotCursorSample(x: x, y: y, red: component(0), green: component(1), blue: component(2))
    }
}

extension ScreenshotGeometry {
    static func cursorCard(at point: CGPoint, bounds: CGRect, size: CGSize = CGSize(width: 166, height: 218)) -> CGRect
    {
        var x = point.x + 22
        var y = point.y + 22
        if x + size.width > bounds.maxX - 8 { x = point.x - size.width - 22 }
        if y + size.height > bounds.maxY - 8 { y = point.y - size.height - 22 }
        return CGRect(
            x: max(bounds.minX + 8, min(x, bounds.maxX - size.width - 8)),
            y: max(bounds.minY + 8, min(y, bounds.maxY - size.height - 8)), width: size.width, height: size.height)
    }
}
