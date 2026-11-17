import AppKit

/// 文字与条码共用输入校验和标注渲染，图像始终由所属会话持有。
struct ScreenshotRecognitionImage: Sendable {
    let base: CGImage
    let pointSize: CGSize
    let annotations: [ScreenshotAnnotation]

    static func load(_ input: ScreenshotTextInput) async throws -> Self {
        try Task.checkCancellation()
        let source: Self
        switch input {
        case .image(let image, let size, let marks):
            source = Self(base: image, pointSize: size, annotations: marks)
        case .pinned(let storage):
            source = Self(base: try await storage.loadImage(), pointSize: storage.pointSize, annotations: [])
        }
        guard source.base.width > 0, source.base.height > 0, source.base.width <= 100_000_000 / source.base.height,
            source.pointSize.width.isFinite, source.pointSize.height.isFinite,
            source.pointSize.width > 0, source.pointSize.height > 0 else { throw ScreenshotImageError.allocationFailed }
        try Task.checkCancellation()
        return source
    }

    func render(_ region: CGRect, maximumDimension: Int? = nil) throws -> CGImage {
        if annotations.isEmpty, maximumDimension == nil {
            guard let crop = base.cropping(to: region) else { throw ScreenshotImageError.invalidSelection }
            return crop
        }
        let sx = pointSize.width / CGFloat(base.width), sy = pointSize.height / CGFloat(base.height)
        return try ScreenshotRenderer.render(base: base, pointSize: pointSize, annotations: annotations,
            maximumDimension: maximumDimension,
            region: CGRect(x: region.minX * sx, y: region.minY * sy, width: region.width * sx, height: region.height * sy))
    }
}
