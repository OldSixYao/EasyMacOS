import AppKit
import CoreText
import ImageIO
import PasteManCore
import UniformTypeIdentifiers

/// All annotation coordinates are measured in points from the selection's top-left corner.
enum AnnotationTool: String, CaseIterable, Sendable {
    case select, rectangle, ellipse, arrow, pen, text, mosaic
    var title: String {
        switch self {
        case .select: L.t("Adjust selection", "调整选区")
        case .rectangle: L.t("Rectangle", "矩形")
        case .ellipse: L.t("Ellipse", "椭圆")
        case .arrow: L.t("Arrow", "箭头")
        case .pen: L.t("Pen", "画笔")
        case .text: L.t("Text", "文字")
        case .mosaic: L.t("Mosaic", "马赛克")
        }
    }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .rectangle: "rectangle"
        case .ellipse: "oval"
        case .arrow: "arrow.up.right"
        case .pen: "pencil.tip"
        case .text: "t.square"
        case .mosaic: "square.grid.3x3.fill"
        }
    }
}

struct AnnotationColor: Sendable, Equatable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    var cgColor: CGColor { CGColor(red: red, green: green, blue: blue, alpha: 1) }
    static let palette: [Self] = [
        Self(red: 1, green: 0.2, blue: 0.25), Self(red: 1, green: 0.75, blue: 0),
        Self(red: 0.2, green: 0.8, blue: 0.35), Self(red: 0.1, green: 0.55, blue: 1),
        Self(red: 1, green: 1, blue: 1), Self(red: 0, green: 0, blue: 0),
    ]
}

struct ScreenshotAnnotation: Sendable, Equatable {
    var tool: AnnotationTool
    var points: [CGPoint]
    var color: AnnotationColor
    var width: CGFloat
    var text = ""
    var rect: CGRect { ScreenshotGeometry.rect(from: points.first ?? .zero, to: points.last ?? .zero) }
}

struct AnnotationHistory: Sendable {
    private(set) var annotations: [ScreenshotAnnotation] = []
    private(set) var undone: [ScreenshotAnnotation] = []
    mutating func append(_ value: ScreenshotAnnotation) {
        annotations.append(value)
        undone.removeAll()
    }
    mutating func undo() { if let last = annotations.popLast() { undone.append(last) } }
    mutating func redo() { if let last = undone.popLast() { annotations.append(last) } }
}

enum ScreenshotGeometry {
    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    static func localPoint(_ screenPoint: CGPoint, in screen: CGRect) -> CGPoint {
        CGPoint(x: screenPoint.x - screen.minX, y: screen.maxY - screenPoint.y)
    }
    static func pixelRect(_ selection: CGRect, pointSize: CGSize, pixelSize: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: pointSize)
        let rect = selection.standardized.intersection(bounds)
        guard !rect.isNull, pointSize.width > 0, pointSize.height > 0 else { return .zero }
        let sx = pixelSize.width / pointSize.width
        let sy = pixelSize.height / pointSize.height
        return CGRect(
            x: floor(rect.minX * sx), y: floor(rect.minY * sy),
            width: ceil(rect.maxX * sx) - floor(rect.minX * sx),
            height: ceil(rect.maxY * sy) - floor(rect.minY * sy))
    }
}

struct ScreenshotImage: Sendable {
    let image: CGImage
    let png: Data
    let pointSize: CGSize
}

enum ScreenshotImageError: Error, LocalizedError {
    case invalidSelection, allocationFailed, captureUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidSelection: L.t("Select a larger area and try again.", "请选择有效的截图区域。")
        case .allocationFailed:
            L.t("The screenshot is too large to process. Select a smaller area.", "截图过大，无法处理，请缩小选区。")
        case .captureUnavailable:
            L.t(
                "Could not capture the display. Check Screen Recording permission and try again.",
                "无法捕获屏幕，请检查屏幕录制权限后重试。")
        }
    }
}

/// Shared by preview and export. Uses Core Graphics / Core Text only, safe off the main actor.
enum ScreenshotRenderer {
    static func render(
        base: CGImage, pointSize: CGSize, annotations: [ScreenshotAnnotation],
        maximumDimension: Int? = nil
    ) throws -> CGImage {
        let reduction = maximumDimension.map { min(1, CGFloat($0) / CGFloat(max(base.width, base.height))) } ?? 1
        let w = max(1, Int(CGFloat(base.width) * reduction))
        let h = max(1, Int(CGFloat(base.height) * reduction))
        // Bound allocation separately from the clipboard history's admission limits.
        guard w <= 100_000_000 / h, pointSize.width > 0, pointSize.height > 0,
            let context = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ScreenshotImageError.allocationFailed }
        context.translateBy(x: 0, y: CGFloat(h))
        context.scaleBy(x: CGFloat(w) / pointSize.width, y: -CGFloat(h) / pointSize.height)
        drawImage(base, in: CGRect(origin: .zero, size: pointSize), context: context)
        for annotation in annotations {
            try Task.checkCancellation()
            if annotation.tool == .mosaic {
                let rect = annotation.rect.intersection(CGRect(origin: .zero, size: pointSize))
                guard !rect.isNull, rect.width > 0, rect.height > 0, let snapshot = context.makeImage() else {
                    continue
                }
                let pixels = ScreenshotGeometry.pixelRect(
                    rect, pointSize: pointSize,
                    pixelSize: CGSize(width: w, height: h))
                guard let crop = snapshot.cropping(to: pixels) else { throw ScreenshotImageError.allocationFailed }
                let block = max(8, annotation.width * 4)
                let cols = max(1, Int(rect.width / block))
                let rows = max(1, Int(rect.height / block))
                guard
                    let small = CGContext(
                        data: nil, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else {
                    throw ScreenshotImageError.allocationFailed
                }
                small.interpolationQuality = .low
                small.draw(crop, in: CGRect(x: 0, y: 0, width: cols, height: rows))
                guard let pixelated = small.makeImage() else { throw ScreenshotImageError.allocationFailed }
                context.saveGState()
                context.interpolationQuality = .none
                drawImage(pixelated, in: rect, context: context)
                context.restoreGState()
            } else {
                draw(annotation, in: context)
            }
        }
        guard let result = context.makeImage() else { throw ScreenshotImageError.allocationFailed }
        return result
    }

    static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    static func draw(_ annotation: ScreenshotAnnotation, in context: CGContext) {
        guard let first = annotation.points.first, let last = annotation.points.last else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(annotation.color.cgColor)
        context.setFillColor(annotation.color.cgColor)
        context.setLineWidth(annotation.width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch annotation.tool {
        case .rectangle: context.stroke(annotation.rect)
        case .ellipse: context.strokeEllipse(in: annotation.rect)
        case .pen, .arrow:
            context.beginPath()
            context.move(to: first)
            for point in annotation.points.dropFirst() { context.addLine(to: point) }
            if annotation.points.count == 1 { context.addLine(to: CGPoint(x: first.x + 0.1, y: first.y)) }
            context.strokePath()
            if annotation.tool == .arrow {
                let angle = atan2(last.y - first.y, last.x - first.x)
                let length = max(12, annotation.width * 4)
                context.beginPath()
                context.move(
                    to: CGPoint(x: last.x - length * cos(angle - .pi / 6), y: last.y - length * sin(angle - .pi / 6)))
                context.addLine(to: last)
                context.addLine(
                    to: CGPoint(x: last.x - length * cos(angle + .pi / 6), y: last.y - length * sin(angle + .pi / 6)))
                context.strokePath()
            }
        case .text:
            let font = CTFontCreateWithName("Helvetica" as CFString, max(16, annotation.width * 6), nil)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): annotation.color.cgColor,
            ]
            var y = first.y
            for text in annotation.text.components(separatedBy: "\n") {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
                context.saveGState()
                context.translateBy(x: first.x, y: y + CTFontGetAscent(font))
                context.scaleBy(x: 1, y: -1)
                context.textMatrix = .identity
                context.textPosition = .zero
                CTLineDraw(line, context)
                context.restoreGState()
                y += CTFontGetAscent(font) + CTFontGetDescent(font) + 4
            }
        case .mosaic, .select: break
        }
    }

    static func encode(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ScreenshotImageError.allocationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ScreenshotImageError.allocationFailed }
        return data as Data
    }

    static func export(base: CGImage, pointSize: CGSize, annotations: [ScreenshotAnnotation]) throws -> ScreenshotImage
    {
        try Task.checkCancellation()
        guard pointSize.width.isFinite, pointSize.height.isFinite, pointSize.width > 0, pointSize.height > 0,
            base.height > 0, base.width <= 100_000_000 / base.height else { throw ScreenshotImageError.allocationFailed }
        let image = annotations.isEmpty ? base : try render(base: base, pointSize: pointSize, annotations: annotations)
        return ScreenshotImage(image: image, png: try encode(image), pointSize: pointSize)
    }
}

/// A single worker bounds simultaneous bitmap allocations from previews and exports.
actor ScreenshotRenderWorker {
    static let shared = ScreenshotRenderWorker()
    func prepareHistory(_ image: ScreenshotImage) throws -> PreparedContent {
        try autoreleasepool { try ImageProcessor.prepareRenderedImage(image.image, png: image.png) }
    }
    private struct PreviewCheckpoint {
        let session: UUID
        let size: CGSize
        let annotations: [ScreenshotAnnotation]
        let image: CGImage
    }
    private var checkpoint: PreviewCheckpoint?
    func releasePreview(session: UUID) {
        if checkpoint?.session == session { checkpoint = nil }
    }
    func preview(base: CGImage, pointSize: CGSize, annotations: [ScreenshotAnnotation], session: UUID? = nil) throws -> CGImage {
        try Task.checkCancellation()
        let image = try autoreleasepool {
            if let session, let previous = checkpoint, previous.session == session, previous.size == pointSize,
                annotations.starts(with: previous.annotations) {
                return try ScreenshotRenderer.render(base: previous.image, pointSize: pointSize,
                    annotations: Array(annotations.dropFirst(previous.annotations.count)), maximumDimension: 1800)
            }
            return try ScreenshotRenderer.render(
                base: base, pointSize: pointSize, annotations: annotations, maximumDimension: 1800)
        }
        try Task.checkCancellation()
        if let session { checkpoint = PreviewCheckpoint(session: session, size: pointSize, annotations: annotations, image: image) }
        return image
    }
    func export(base: CGImage, pointSize: CGSize, annotations: [ScreenshotAnnotation]) throws -> ScreenshotImage {
        let interval = PerformanceTrace.signposter.beginInterval("ScreenshotExport", id: PerformanceTrace.signposter.makeSignpostID())
        defer { PerformanceTrace.signposter.endInterval("ScreenshotExport", interval) }
        try Task.checkCancellation()
        let image = try autoreleasepool {
            try ScreenshotRenderer.export(base: base, pointSize: pointSize, annotations: annotations)
        }
        try Task.checkCancellation()
        return image
    }
}
