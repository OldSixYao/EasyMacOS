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
    static let mosaicCacheLimit = 16 * 1024 * 1024
    static func render(
        base: CGImage, pointSize: CGSize, annotations: [ScreenshotAnnotation],
        maximumDimension: Int? = nil, region: CGRect? = nil
    ) throws -> CGImage {
        let area = region ?? CGRect(origin: .zero, size: pointSize)
        guard pointSize.width > 0, pointSize.height > 0, area.width > 0, area.height > 0 else {
            throw ScreenshotImageError.invalidSelection
        }
        let pixelWidth = area.width * CGFloat(base.width) / pointSize.width
        let pixelHeight = area.height * CGFloat(base.height) / pointSize.height
        let reduction = maximumDimension.map { min(1, CGFloat($0) / max(pixelWidth, pixelHeight)) } ?? 1
        var mosaics: [Int: CGImage] = [:]
        return try renderRegion(base: base, pointSize: pointSize, annotations: annotations, count: annotations.count,
            area: area, width: max(1, Int((pixelWidth * reduction).rounded())),
            height: max(1, Int((pixelHeight * reduction).rounded())), mosaics: &mosaics)
    }

    private static func renderRegion(base: CGImage, pointSize: CGSize, annotations: [ScreenshotAnnotation], count: Int,
                                     area: CGRect, width: Int, height: Int, mosaics: inout [Int: CGImage]) throws -> CGImage {
        try Task.checkCancellation()
        guard width > 0, height > 0, width <= 100_000_000 / height,
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ScreenshotImageError.allocationFailed }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / area.width, y: -CGFloat(height) / area.height)
        context.translateBy(x: -area.minX, y: -area.minY)
        let pixels = ScreenshotGeometry.pixelRect(area, pointSize: pointSize,
            pixelSize: CGSize(width: base.width, height: base.height))
        guard let crop = base.cropping(to: pixels) else { throw ScreenshotImageError.invalidSelection }
        let baseRect = CGRect(x: pixels.minX * pointSize.width / CGFloat(base.width),
            y: pixels.minY * pointSize.height / CGFloat(base.height),
            width: pixels.width * pointSize.width / CGFloat(base.width),
            height: pixels.height * pointSize.height / CGFloat(base.height))
        drawImage(crop, in: baseRect, context: context)
        for index in 0..<count {
            try Task.checkCancellation()
            let annotation = annotations[index]
            if annotation.tool == .mosaic {
                let rect = annotation.rect.intersection(CGRect(origin: .zero, size: pointSize))
                guard !rect.isNull, rect.width > 0, rect.height > 0, rect.intersects(area) else { continue }
                let pixelated: CGImage
                if let cached = mosaics[index] { pixelated = cached }
                else {
                    // 在全局标注坐标中生成马赛克格子。预览片段与整图导出使用相同格点，
                    // 跨片段滚动时不会重新起格，也不需要为整个马赛克区域分配原尺寸位图。
                    let block = max(8, annotation.width * 4)
                    pixelated = try renderRegion(base: base, pointSize: pointSize, annotations: annotations, count: index,
                        area: rect, width: max(1, Int(rect.width / block)), height: max(1, Int(rect.height / block)), mosaics: &mosaics)
                    let cost = pixelated.bytesPerRow * pixelated.height
                    let cachedBytes = mosaics.values.reduce(0) { $0 + $1.bytesPerRow * $1.height }
                    if cachedBytes > mosaicCacheLimit - min(cost, mosaicCacheLimit) { mosaics.removeAll() }
                    if cost <= mosaicCacheLimit { mosaics[index] = pixelated }
                }
                context.saveGState()
                context.interpolationQuality = .none
                drawImage(pixelated, in: rect, context: context)
                context.restoreGState()
            } else { draw(annotation, in: context) }
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
    func prepareHistory(_ image: ScreenshotImage) async throws -> PreparedContent {
        if let result = try ImageWorkBudget.shared.performIfAvailable(estimatedBytes: 1_048_576, operation: {
            try prepareHistoryAdmitted(image)
        }) { return result }
        return try await ImageWorkBudget.shared.withPermit(estimatedBytes: 1_048_576, priority: .background) {
            try await self.prepareHistoryAdmitted(image)
        }
    }
    private func prepareHistoryAdmitted(_ image: ScreenshotImage) throws -> PreparedContent {
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
    func preview(base: CGImage, pointSize: CGSize, annotations: [ScreenshotAnnotation], session: UUID? = nil) async throws -> CGImage {
        let dimension = min(1800, max(base.width, base.height))
        if let result = try ImageWorkBudget.shared.performIfAvailable(estimatedBytes: dimension * dimension * 8, operation: {
            try previewAdmitted(base: base, pointSize: pointSize, annotations: annotations, session: session)
        }) { return result }
        return try await ImageWorkBudget.shared.withPermit(estimatedBytes: dimension * dimension * 8, priority: .display) {
            try await self.previewAdmitted(base: base, pointSize: pointSize, annotations: annotations, session: session)
        }
    }
    private func previewAdmitted(base: CGImage, pointSize: CGSize, annotations: [ScreenshotAnnotation], session: UUID?) throws -> CGImage {
        try Task.checkCancellation()
        let image = try autoreleasepool {
            if let session, let previous = checkpoint, previous.session == session, previous.size == pointSize,
                annotations.starts(with: previous.annotations),
                !annotations.dropFirst(previous.annotations.count).contains(where: { $0.tool == .mosaic }) {
                return try ScreenshotRenderer.render(base: previous.image, pointSize: pointSize,
                    annotations: Array(annotations.dropFirst(previous.annotations.count)), maximumDimension: 1800)
            }
            // 新增马赛克必须从原图和此前标注生成格点，不能再次采样已缩小的预览。
            return try ScreenshotRenderer.render(
                base: base, pointSize: pointSize, annotations: annotations, maximumDimension: 1800)
        }
        try Task.checkCancellation()
        if let session { checkpoint = PreviewCheckpoint(session: session, size: pointSize, annotations: annotations, image: image) }
        return image
    }
    func export(base: CGImage, pointSize: CGSize, annotations: [ScreenshotAnnotation]) async throws -> ScreenshotImage {
        let cost = base.bytesPerRow * base.height * (annotations.isEmpty ? 1 : 2)
        if let result = try ImageWorkBudget.shared.performIfAvailable(estimatedBytes: cost, operation: {
            try exportAdmitted(base: base, pointSize: pointSize, annotations: annotations)
        }) { return result }
        return try await ImageWorkBudget.shared.withPermit(estimatedBytes: cost, priority: .userInitiated) {
            try await self.exportAdmitted(base: base, pointSize: pointSize, annotations: annotations)
        }
    }
    private func exportAdmitted(base: CGImage, pointSize: CGSize, annotations: [ScreenshotAnnotation]) throws -> ScreenshotImage {
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
