import AppKit
import PasteManCore

enum PinnedImageTransform: Sendable {
    case clockwise, counterclockwise, halfTurn, horizontalMirror, verticalMirror

    var swapsDimensions: Bool { self == .clockwise || self == .counterclockwise }

    func render(_ image: CGImage) throws -> CGImage {
        try Task.checkCancellation()
        let width = swapsDimensions ? image.height : image.width
        let height = swapsDimensions ? image.width : image.height
        guard width > 0, height > 0, width <= 100_000_000 / height,
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ScreenshotImageError.allocationFailed }
        // 在左上角坐标系中进行整像素变换，不随贴图窗口的显示比例缩小原图。
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let transform: CGAffineTransform
        switch self {
        case .clockwise: transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(image.height), ty: 0)
        case .counterclockwise: transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: CGFloat(image.width))
        case .halfTurn: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: CGFloat(image.width), ty: CGFloat(image.height))
        case .horizontalMirror: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: CGFloat(image.width), ty: 0)
        case .verticalMirror: transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(image.height))
        }
        context.concatenate(transform)
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        ScreenshotRenderer.drawImage(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), context: context)
        try Task.checkCancellation()
        guard let result = context.makeImage() else { throw ScreenshotImageError.allocationFailed }
        return result
    }
}

extension PinnedImageWorker {
    func transform(base: CGImage, pointSize: CGSize, operation: PinnedImageTransform) async throws -> PinnedImageStorage {
        try await ImageWorkBudget.shared.withPermit(estimatedBytes: base.bytesPerRow * base.height * 2, priority: .userInitiated) {
            try await self.transformAdmitted(base: base, pointSize: pointSize, operation: operation)
        }
    }

    private func transformAdmitted(base: CGImage, pointSize: CGSize, operation: PinnedImageTransform) throws -> PinnedImageStorage {
        try autoreleasepool {
            let transformed = try operation.render(base)
            let size = operation.swapsDimensions ? CGSize(width: pointSize.height, height: pointSize.width) : pointSize
            return try PinnedImageStorage(image: transformed, pointSize: size)
        }
    }

    func crop(base: CGImage, pointSize: CGSize, selection: CGRect) async throws -> PinnedImageStorage {
        try await ImageWorkBudget.shared.withPermit(estimatedBytes: base.bytesPerRow * base.height, priority: .userInitiated) {
            try await self.cropAdmitted(base: base, pointSize: pointSize, selection: selection)
        }
    }

    private func cropAdmitted(base: CGImage, pointSize: CGSize, selection: CGRect) throws -> PinnedImageStorage {
        try Task.checkCancellation()
        guard selection.origin.x.isFinite, selection.origin.y.isFinite,
            selection.width.isFinite, selection.height.isFinite,
            pointSize.width.isFinite, pointSize.height.isFinite, pointSize.width > 0, pointSize.height > 0
        else { throw ScreenshotImageError.invalidSelection }
        let pixels = ScreenshotGeometry.pixelRect(selection, pointSize: pointSize,
            pixelSize: CGSize(width: base.width, height: base.height))
        guard pixels.width >= 1, pixels.height >= 1, let cropped = base.cropping(to: pixels) else {
            throw ScreenshotImageError.invalidSelection
        }
        let size = CGSize(width: pixels.width * pointSize.width / CGFloat(base.width),
            height: pixels.height * pointSize.height / CGFloat(base.height))
        return try autoreleasepool { try PinnedImageStorage(image: cropped, pointSize: size) }
    }
}
