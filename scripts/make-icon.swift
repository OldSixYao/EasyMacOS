import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: 1024, height: 1024))
        image.lockFocus()
        let background = NSBezierPath(
            roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904), xRadius: 210, yRadius: 210)
        let gradient = NSGradient(
            starting: NSColor(srgbRed: 0.21, green: 0.57, blue: 0.98, alpha: 1),
            ending: NSColor(srgbRed: 0.18, green: 0.32, blue: 0.80, alpha: 1))!
        gradient.draw(in: background, angle: -60)
        NSColor.white.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: NSRect(x: 270, y: 240, width: 415, height: 535), xRadius: 52, yRadius: 52).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 340, y: 180, width: 415, height: 535), xRadius: 52, yRadius: 52).fill()
        NSColor(srgbRed: 0.2, green: 0.43, blue: 0.9, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 440, y: 675, width: 215, height: 70), xRadius: 26, yRadius: 26).fill()
        for (width, y) in [(230, 535), (230, 445), (155, 355)] {
            NSBezierPath(roundedRect: NSRect(x: 430, y: y, width: width, height: 25), xRadius: 12, yRadius: 12).fill()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let data = bitmap.representation(using: .png, properties: [:])!
        try data.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
