import CoreGraphics
import Foundation

enum ScreenshotMosaicMode: String, CaseIterable, Sendable, Codable {
    case rectangle, brush
    var title: String { self == .rectangle ? L.t("Area", "框选") : L.t("Brush", "涂抹") }
    var symbol: String { self == .rectangle ? "rectangle.dashed" : "paintbrush.pointed" }
}

struct ScreenshotMosaicOptions: Sendable, Equatable, Codable {
    var mode = ScreenshotMosaicMode.rectangle
    var brushSize: CGFloat = 32
    var blockSize: CGFloat = 12
    var resolvedBrushSize: CGFloat { brushSize.isFinite ? min(160, max(8, brushSize)) : 32 }
    var resolvedBlockSize: CGFloat { blockSize.isFinite ? min(40, max(4, blockSize)) : 12 }
}

extension ScreenshotAnnotation {
    var isMosaicBrush: Bool { tool == .mosaic && mosaic?.mode == .brush }
    var followsPointerPath: Bool { tool == .pen || isMosaicBrush }
    var canCommit: Bool {
        if followsPointerPath { return !points.isEmpty }
        if tool == .mosaic { return rect.width > 0 && rect.height > 0 }
        return rect.width > 0 || rect.height > 0
    }
    var coverageBounds: CGRect {
        guard followsPointerPath, let first = points.first else { return rect }
        var left = first.x, right = first.x, top = first.y, bottom = first.y
        for point in points.dropFirst() {
            left = min(left, point.x); right = max(right, point.x)
            top = min(top, point.y); bottom = max(bottom, point.y)
        }
        let radius = (isMosaicBrush ? mosaic!.resolvedBrushSize : width) / 2
        return CGRect(x: left - radius, y: top - radius,
            width: right - left + radius * 2, height: bottom - top + radius * 2)
    }
    mutating func extend(to point: CGPoint) {
        guard let first = points.first else { return }
        if followsPointerPath {
            if let last = points.last, hypot(last.x - point.x, last.y - point.y) >= 0.75 { points.append(point) }
        } else { points = [first, point] }
    }
    func clipMosaic(in context: CGContext) {
        context.setShouldAntialias(false)
        guard isMosaicBrush, let first = points.first else { context.clip(to: rect); return }
        let diameter = mosaic!.resolvedBrushSize
        let path = CGMutablePath()
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        if points.count == 1 {
            path.addEllipse(in: CGRect(x: first.x - diameter / 2, y: first.y - diameter / 2,
                width: diameter, height: diameter))
        } else {
            let outline = path.copy(strokingWithWidth: diameter, lineCap: .round, lineJoin: .round, miterLimit: 10)
            // 先在逻辑坐标中固定曲线细分，避免各预览片段按自身边界产生不同的曲线近似。
            context.addPath(outline.flattened(threshold: 1.0 / 64))
            context.clip()
            return
        }
        context.addPath(path.flattened(threshold: 1.0 / 64))
        context.clip()
    }
}

/// 每片最多一百二十八格；图片末端不足一格的行、列单独取样，保留透明度和固定格距。
struct ScreenshotMosaicTile: Hashable, Sendable {
    static let cells = 128
    let column: Int
    let row: Int
    let columns: Int
    let rows: Int

    func rect(pointSize: CGSize, blockSize: CGFloat) -> CGRect {
        let x = CGFloat(column) * blockSize, y = CGFloat(row) * blockSize
        return CGRect(x: x, y: y, width: min(CGFloat(columns) * blockSize, pointSize.width - x),
            height: min(CGFloat(rows) * blockSize, pointSize.height - y))
    }
    static func covering(_ region: CGRect, pointSize: CGSize, blockSize: CGFloat) -> [Self] {
        let area = region.intersection(CGRect(origin: .zero, size: pointSize))
        guard !area.isNull, area.width > 0, area.height > 0 else { return [] }
        let horizontal = segments(length: pointSize.width, start: area.minX, end: area.maxX, block: blockSize)
        let vertical = segments(length: pointSize.height, start: area.minY, end: area.maxY, block: blockSize)
        return vertical.flatMap { y in horizontal.map { x in
            Self(column: x.start, row: y.start, columns: x.count, rows: y.count)
        } }.filter { $0.rect(pointSize: pointSize, blockSize: blockSize).intersects(area) }
    }
    private static func segments(length: CGFloat, start: CGFloat, end: CGFloat, block: CGFloat) -> [(start: Int, count: Int)] {
        let fullCells = Int(floor(length / block))
        let first = Int(floor(start / block)) / cells
        let last = Int(ceil(end / block) - 1) / cells
        var result: [(start: Int, count: Int)] = []
        for index in first...max(first, last) {
            let cell = index * cells, count = min(cells, fullCells - cell)
            if count > 0 { result.append((cell, count)) }
        }
        let edge = CGFloat(fullCells) * block
        if edge < length, end > edge { result.append((fullCells, 1)) }
        return result
    }
}

struct ScreenshotMosaicPatch: Sendable {
    let tile: ScreenshotMosaicTile
    let rect: CGRect
    let image: CGImage
    var cost: Int { image.bytesPerRow * image.height }
    func draw(in context: CGContext) {
        context.saveGState()
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        ScreenshotRenderer.drawImage(image, in: rect, context: context)
        context.restoreGState()
    }
}

enum ScreenshotMosaicCursor {
    static func rect(at point: CGPoint, diameter: CGFloat, zoom: CGFloat = 1) -> CGRect {
        CGRect(x: (point.x - diameter / 2) * zoom, y: (point.y - diameter / 2) * zoom,
            width: diameter * zoom, height: diameter * zoom)
    }
    static func draw(_ rect: CGRect, in context: CGContext) {
        context.saveGState()
        context.setLineWidth(3)
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.8))
        context.strokeEllipse(in: rect)
        context.setLineWidth(1)
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.strokeEllipse(in: rect)
        context.restoreGState()
    }
}

extension ScreenshotRenderer {
    static func drawMosaicPatch(_ patch: ScreenshotMosaicPatch, annotation: ScreenshotAnnotation,
                               pointSize: CGSize, pixelSize: CGSize, area: CGRect, context: CGContext) throws {
        guard annotation.isMosaicBrush else { patch.draw(in: context); return }
        // 使用原图像素中固定的五百一十二像素片段栅格化圆头路径。
        // 同一边缘始终在同一画布上取样，避免整图与长图条带的曲线裁剪精度差异。
        let scaleX = pixelSize.width / pointSize.width, scaleY = pixelSize.height / pointSize.height
        let affected = patch.rect.intersection(annotation.coverageBounds).intersection(area)
        guard !affected.isNull, affected.width > 0, affected.height > 0 else { return }
        let pixels = ScreenshotGeometry.pixelRect(affected, pointSize: pointSize, pixelSize: pixelSize)
        let length = 512
        for row in Int(pixels.minY) / length...max(Int(pixels.minY) / length, (Int(pixels.maxY) - 1) / length) {
            for column in Int(pixels.minX) / length...max(Int(pixels.minX) / length, (Int(pixels.maxX) - 1) / length) {
                try Task.checkCancellation()
                try autoreleasepool {
                    let x = column * length, y = row * length
                    let width = min(length, Int(pixelSize.width) - x), height = min(length, Int(pixelSize.height) - y)
                    guard let maskContext = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
                    else { throw ScreenshotImageError.allocationFailed }
                    let rect = CGRect(x: CGFloat(x) / scaleX, y: CGFloat(y) / scaleY,
                        width: CGFloat(width) / scaleX, height: CGFloat(height) / scaleY)
                    maskContext.translateBy(x: 0, y: CGFloat(height)); maskContext.scaleBy(x: scaleX, y: -scaleY)
                    maskContext.translateBy(x: -rect.minX, y: -rect.minY)
                    annotation.clipMosaic(in: maskContext)
                    maskContext.setFillColor(CGColor(gray: 1, alpha: 1)); maskContext.fill(rect)
                    guard let mask = maskContext.makeImage() else { throw ScreenshotImageError.allocationFailed }
                    context.saveGState()
                    context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
                    context.clip(to: CGRect(origin: .zero, size: rect.size), mask: mask)
                    context.scaleBy(x: 1, y: -1); context.translateBy(x: -rect.minX, y: -rect.maxY)
                    patch.draw(in: context)
                    context.restoreGState()
                }
            }
        }
    }
}
