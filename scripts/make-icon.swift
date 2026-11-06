import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

// 三合一标识：截图取景框、剪贴板卡片与菜单指针。
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let tile = NSBezierPath(
    roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904), xRadius: 206, yRadius: 206)
NSGraphicsContext.saveGraphicsState()
let tileShadow = NSShadow()
tileShadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
tileShadow.shadowBlurRadius = 20
tileShadow.shadowOffset = NSSize(width: 0, height: -8)
tileShadow.set()
NSColor(srgbRed: 0.12, green: 0.30, blue: 0.76, alpha: 1).setFill()
tile.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(colors: [
    NSColor(srgbRed: 0.12, green: 0.68, blue: 0.96, alpha: 1),
    NSColor(srgbRed: 0.16, green: 0.40, blue: 0.94, alpha: 1),
    NSColor(srgbRed: 0.29, green: 0.23, blue: 0.78, alpha: 1),
])!.draw(in: tile, angle: -65)
NSColor.white.withAlphaComponent(0.24).setStroke()
let rim = NSBezierPath(
    roundedRect: NSRect(x: 63, y: 63, width: 898, height: 898), xRadius: 203, yRadius: 203)
rim.lineWidth = 3
rim.stroke()

// 断开的四角轮廓让截图意象在小尺寸下也清晰。
let frame = NSBezierPath()
for (x, y, dx, dy) in [(242.0, 774.0, 1.0, -1.0), (782, 774, -1, -1),
                        (242, 250, 1, 1), (782, 250, -1, 1)] {
    frame.move(to: NSPoint(x: x, y: y + dy * 100))
    frame.line(to: NSPoint(x: x, y: y + dy * 22))
    frame.curve(to: NSPoint(x: x + dx * 22, y: y),
                controlPoint1: NSPoint(x: x, y: y + dy * 8),
                controlPoint2: NSPoint(x: x + dx * 8, y: y))
    frame.line(to: NSPoint(x: x + dx * 100, y: y))
}
frame.lineWidth = 32
frame.lineCapStyle = .round
NSColor.white.withAlphaComponent(0.90).setStroke()
frame.stroke()

let card = NSBezierPath(
    roundedRect: NSRect(x: 346, y: 319, width: 332, height: 385), xRadius: 42, yRadius: 42)
NSGraphicsContext.saveGraphicsState()
let cardShadow = NSShadow()
cardShadow.shadowColor = NSColor(srgbRed: 0.06, green: 0.12, blue: 0.40, alpha: 0.25)
cardShadow.shadowBlurRadius = 25
cardShadow.shadowOffset = NSSize(width: 0, height: -12)
cardShadow.set()
NSColor.white.setFill()
card.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: .white, ending: NSColor(srgbRed: 0.89, green: 0.94, blue: 1, alpha: 1))!
    .draw(in: card, angle: -90)
let clip = NSBezierPath(
    roundedRect: NSRect(x: 436, y: 664, width: 152, height: 69), xRadius: 23, yRadius: 23)
NSColor(srgbRed: 0.22, green: 0.42, blue: 0.87, alpha: 1).setFill()
clip.fill()
for (width, y) in [(192.0, 554.0), (142, 469)] {
    NSColor(srgbRed: 0.31, green: 0.51, blue: 0.87, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 416, y: y, width: width, height: 25), xRadius: 12.5, yRadius: 12.5).fill()
}

// 使用深色细边分离前景指针与白色卡片。
let pointer = NSBezierPath()
pointer.move(to: NSPoint(x: 623, y: 491))
for point in [NSPoint(x: 638, y: 249), NSPoint(x: 699, y: 302),
              NSPoint(x: 758, y: 196), NSPoint(x: 809, y: 225),
              NSPoint(x: 749, y: 330), NSPoint(x: 831, y: 340)] {
    pointer.line(to: point)
}
pointer.close()
NSGraphicsContext.saveGraphicsState()
let pointerShadow = NSShadow()
pointerShadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
pointerShadow.shadowBlurRadius = 14
pointerShadow.shadowOffset = NSSize(width: 0, height: -8)
pointerShadow.set()
NSColor.white.setFill()
pointer.fill()
NSGraphicsContext.restoreGraphicsState()
NSColor(srgbRed: 0.20, green: 0.31, blue: 0.67, alpha: 1).setStroke()
pointer.lineWidth = 12
pointer.lineJoinStyle = .round
pointer.stroke()
image.unlockFocus()

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let data = bitmap.representation(using: .png, properties: [:])!
        try data.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
