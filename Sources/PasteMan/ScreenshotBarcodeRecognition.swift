import AppKit
import PasteManCore
import Vision

struct ScreenshotBarcode: Sendable {
    let payload: String
    /// 原图像素坐标，原点在左上角。
    let rect: CGRect
    let confidence: Float
}

enum ScreenshotBarcodeLayout {
    static func strips(width: Int, height: Int) -> [CGRect] {
        guard width > 0, height > 0 else { return [] }
        let stripHeight = min(4096, max(1024, width * 2))
        var result: [CGRect] = []
        var y = 0
        while y < height {
            let count = min(stripHeight, height - y)
            result.append(CGRect(x: 0, y: y, width: width, height: count))
            if y + count == height { break }
            // 二维码需要完整图案；保留半段重叠，覆盖跨越分段边界的常见码图。
            y += stripHeight / 2
        }
        return result
    }

    static func merge(_ additions: [ScreenshotBarcode], into codes: inout [ScreenshotBarcode]) {
        for code in additions {
            guard !code.payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if let index = codes.lastIndex(where: { existing in
                guard existing.payload == code.payload else { return false }
                let intersection = existing.rect.intersection(code.rect)
                guard !intersection.isNull else { return false }
                let smaller = min(existing.rect.width * existing.rect.height, code.rect.width * code.rect.height)
                return smaller > 0 && intersection.width * intersection.height >= smaller * 0.5
            }) {
                if code.confidence > codes[index].confidence { codes[index] = code }
            } else { codes.append(code) }
        }
    }

    static func text(from codes: [ScreenshotBarcode]) -> String {
        codes.sorted {
            $0.rect.minY == $1.rect.minY ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY
        }.map(\.payload).joined(separator: "\n")
    }
}

struct SystemScreenshotBarcodeRecognizer: ScreenshotTextRecognizing {
    static let shared = SystemScreenshotBarcodeRecognizer()

    func recognize(_ input: ScreenshotTextInput, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        try await ScreenshotRecognitionProcess.shared.recognize(input, kind: .barcodes, progress: progress)
    }
}

/// 在辅助进程中使用原始像素和已提交标注检测，不访问网络。
actor InProcessScreenshotBarcodeRecognizer: ScreenshotTextRecognizing {
    static let shared = InProcessScreenshotBarcodeRecognizer()

    func recognize(_ input: ScreenshotTextInput, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let cancellation = ScreenshotRecognitionCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let source = try await ScreenshotRecognitionImage.load(input)
            let strips = ScreenshotBarcodeLayout.strips(width: source.base.width, height: source.base.height)
            var regions = strips
            if strips.count > 1 {
                let candidates = try await ImageWorkBudget.shared.withPermit(
                    estimatedBytes: 2048 * 2048 * 12 + ScreenshotRenderer.mosaicCacheLimit, priority: .userInitiated) {
                        try await self.boundaryRegions(source, strips: strips, cancellation: cancellation)
                    }
                regions += candidates
            }
            var codes: [ScreenshotBarcode] = []
            for (index, strip) in regions.enumerated() {
                try Task.checkCancellation()
                let cost = Int(strip.width * strip.height) * 12 + ScreenshotRenderer.mosaicCacheLimit
                let additions = try await ImageWorkBudget.shared.withPermit(estimatedBytes: cost, priority: .userInitiated) {
                    try await self.recognizeStrip(source, strip: strip, cancellation: cancellation)
                }
                try Task.checkCancellation()
                ScreenshotBarcodeLayout.merge(additions, into: &codes)
                progress(Double(index + 1) / Double(regions.count))
            }
            try Task.checkCancellation()
            return ScreenshotBarcodeLayout.text(from: codes)
        } onCancel: { cancellation.cancel() }
    }

    private func boundaryRegions(_ source: ScreenshotRecognitionImage, strips: [CGRect],
                                 cancellation: ScreenshotRecognitionCancellation) throws -> [CGRect] {
        try Task.checkCancellation()
        return try autoreleasepool {
            let bounds = CGRect(x: 0, y: 0, width: source.base.width, height: source.base.height)
            let image = try source.render(bounds, maximumDimension: 2048)
            let request = VNDetectBarcodesRequest()
            try cancellation.install(request)
            defer { cancellation.clear() }
            do { try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request]) }
            catch { try Task.checkCancellation(); throw error }
            try Task.checkCancellation()
            // 缩略图只定位跨分段的大码，最终内容仍从带当前标注的原始像素解码。
            return (request.results ?? []).compactMap { observation in
                let box = observation.boundingBox
                let rect = CGRect(x: box.minX * bounds.width, y: (1 - box.maxY) * bounds.height,
                    width: box.width * bounds.width, height: box.height * bounds.height)
                guard !strips.contains(where: { $0.contains(rect) }) else { return nil }
                return rect.insetBy(dx: -max(12, rect.width * 0.1), dy: -max(12, rect.height * 0.1))
                    .intersection(bounds).integral
            }
        }
    }

    private func recognizeStrip(_ source: ScreenshotRecognitionImage, strip: CGRect,
                                cancellation: ScreenshotRecognitionCancellation) throws -> [ScreenshotBarcode] {
        try Task.checkCancellation()
        return try autoreleasepool {
            let image = try source.render(strip)
            // 默认检测当前系统支持的全部码制，包含二维码及常见一维条形码。
            let request = VNDetectBarcodesRequest()
            try cancellation.install(request)
            defer { cancellation.clear() }
            do { try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request]) }
            catch { try Task.checkCancellation(); throw error }
            try Task.checkCancellation()
            return (request.results ?? []).compactMap { observation in
                guard let payload = observation.payloadStringValue,
                    !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                let box = observation.boundingBox
                return ScreenshotBarcode(payload: payload, rect: CGRect(x: box.minX * strip.width,
                    y: strip.minY + (1 - box.maxY) * strip.height,
                    width: box.width * strip.width, height: box.height * strip.height), confidence: observation.confidence)
            }
        }
    }
}
