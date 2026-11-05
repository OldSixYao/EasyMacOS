import AppKit

enum FinderMenuIcon {
    static func image(symbol: String, appearance: NSAppearance? = nil) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
        else { return nil }
        // 访达跨进程重建菜单时可能丢失模板着色。保留模板标记，同时按当前系统
        // 外观预绘制语义颜色；每次打开菜单重新生成，不缓存固定黑色符号。
        let appearance = appearance ?? NSAppearance(
            named: UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? .darkAqua : .aqua)!
        var color = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? .labelColor
        }
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        for scale in [1, 2] {
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 18 * scale, pixelsHigh: 18 * scale,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: bitmap)
            else { return nil }
            bitmap.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            let ratio = min(16 / symbol.size.width, 16 / symbol.size.height)
            let bounds = NSRect(
                x: (18 - symbol.size.width * ratio) / 2, y: (18 - symbol.size.height * ratio) / 2,
                width: symbol.size.width * ratio, height: symbol.size.height * ratio)
            symbol.draw(in: bounds)
            color.setFill()
            NSRect(origin: .zero, size: size).fill(using: .sourceIn)
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(bitmap)
        }
        image.isTemplate = true
        return image
    }
}
