import AppKit
import os
import PasteManCore
import Vision

enum ScreenshotTextInput: Sendable {
    case image(CGImage, pointSize: CGSize, annotations: [ScreenshotAnnotation])
    case pinned(PinnedImageStorage)
}

protocol ScreenshotTextRecognizing: Sendable {
    func recognize(_ input: ScreenshotTextInput, progress: @escaping @Sendable (Double) -> Void) async throws -> String
}

struct ScreenshotTextLine: Sendable {
    let text: String
    /// 原图像素坐标，原点在左上角。
    let rect: CGRect
    let confidence: Float
}

enum ScreenshotTextLayout {
    static let stripHeight = 4096
    static let overlap = 256

    static func strips(width: Int, height: Int) -> [CGRect] {
        guard width > 0, height > 0 else { return [] }
        // 过窄的长条会被系统内部缩小；限制纵横比以保留小字号中文细节。
        let maximumHeight = min(stripHeight, max(1024, width * 2))
        var result: [CGRect] = []
        var y = 0
        while y < height {
            let count = min(maximumHeight, height - y)
            result.append(CGRect(x: 0, y: y, width: width, height: count))
            if y + count == height { break }
            y += count - overlap
        }
        return result
    }

    static func merge(_ additions: [ScreenshotTextLine], into lines: inout [ScreenshotTextLine]) {
        for line in additions {
            let key = line.text.filter { !$0.isWhitespace }
            guard !key.isEmpty else { continue }
            if let index = lines.lastIndex(where: { existing in
                let intersection = existing.rect.intersection(line.rect)
                guard !intersection.isNull else { return false }
                let smaller = min(existing.rect.width * existing.rect.height, line.rect.width * line.rect.height)
                return smaller > 0 && intersection.width * intersection.height >= smaller * 0.5
                    && existing.text.filter { !$0.isWhitespace } == key
            }) {
                if line.confidence > lines[index].confidence { lines[index] = line }
            } else { lines.append(line) }
        }
    }

    static func text(from lines: [ScreenshotTextLine]) -> String {
        let sorted = lines.sorted {
            $0.rect.minY == $1.rect.minY ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY
        }
        var rows: [[ScreenshotTextLine]] = []
        for line in sorted {
            if let last = rows.last, let anchor = last.first,
                abs(anchor.rect.midY - line.rect.midY) <= min(anchor.rect.height, line.rect.height) * 0.5 {
                rows[rows.count - 1].append(line)
            } else { rows.append([line]) }
        }
        return rows.map { row in
            row.sorted { $0.rect.minX < $1.rect.minX }.map(\.text).joined(separator: " ")
        }.joined(separator: "\n")
    }
}

/// 系统请求允许从其他线程取消；锁内发布请求，覆盖取消早于请求创建的情况。
private final class ScreenshotTextCancellation: Sendable {
    private struct State {
        var cancelled = false
        var request: VNRecognizeTextRequest?
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    func install(_ request: VNRecognizeTextRequest) throws {
        try state.withLockUnchecked { state in
            guard !state.cancelled else { throw CancellationError() }
            state.request = request
        }
    }
    func clear() { state.withLock { $0.request = nil } }
    func cancel() {
        state.withLock {
            $0.cancelled = true
            $0.request?.cancel()
        }
    }
}

/// 所有识别会话共用后台执行器，同步系统识别不会占用主线程。
actor SystemScreenshotTextRecognizer: ScreenshotTextRecognizing {
    static let shared = SystemScreenshotTextRecognizer()

    func recognize(_ input: ScreenshotTextInput, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let cancellation = ScreenshotTextCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let base: CGImage
            let pointSize: CGSize
            let annotations: [ScreenshotAnnotation]
            switch input {
            case .image(let image, let size, let marks):
                base = image; pointSize = size; annotations = marks
            case .pinned(let storage):
                base = try await storage.loadImage(); pointSize = storage.pointSize; annotations = []
            }
            guard base.width > 0, base.height > 0, base.width <= 100_000_000 / base.height,
                pointSize.width.isFinite, pointSize.height.isFinite, pointSize.width > 0, pointSize.height > 0
            else { throw ScreenshotImageError.allocationFailed }
            let strips = ScreenshotTextLayout.strips(width: base.width, height: base.height)
            var lines: [ScreenshotTextLine] = []
            for (index, strip) in strips.enumerated() {
                try Task.checkCancellation()
                let cost = Int(strip.width * strip.height) * 12 + ScreenshotRenderer.mosaicCacheLimit
                let additions = try await ImageWorkBudget.shared.withPermit(estimatedBytes: cost, priority: .userInitiated) {
                    try await self.recognizeStrip(base: base, pointSize: pointSize, annotations: annotations,
                        strip: strip, cancellation: cancellation)
                }
                try Task.checkCancellation()
                ScreenshotTextLayout.merge(additions, into: &lines)
                progress(Double(index + 1) / Double(strips.count))
            }
            try Task.checkCancellation()
            return ScreenshotTextLayout.text(from: lines)
        } onCancel: { cancellation.cancel() }
    }

    private func recognizeStrip(base: CGImage, pointSize: CGSize, annotations: [ScreenshotAnnotation],
                                strip: CGRect, cancellation: ScreenshotTextCancellation) throws -> [ScreenshotTextLine] {
        try Task.checkCancellation()
        return try autoreleasepool {
            let image = try Self.renderStrip(base: base, pointSize: pointSize, annotations: annotations, strip: strip)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.minimumTextHeight = 0
            request.automaticallyDetectsLanguage = true
            request.usesLanguageCorrection = true
            let supported = try request.supportedRecognitionLanguages()
            let preferred = ["zh-Hans", "zh-Hant", "en-US"].filter { supported.contains($0) }
            if !preferred.isEmpty { request.recognitionLanguages = preferred }
            try cancellation.install(request)
            defer { cancellation.clear() }
            do { try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request]) }
            catch { try Task.checkCancellation(); throw error }
            try Task.checkCancellation()
            return (request.results ?? []).compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let box = observation.boundingBox
                return ScreenshotTextLine(text: text, rect: CGRect(x: box.minX * strip.width,
                    y: strip.minY + (1 - box.maxY) * strip.height,
                    width: box.width * strip.width, height: box.height * strip.height), confidence: candidate.confidence)
            }
        }
    }

    static func renderStrip(base: CGImage, pointSize: CGSize, annotations: [ScreenshotAnnotation], strip: CGRect) throws -> CGImage {
        if annotations.isEmpty {
            guard let crop = base.cropping(to: strip) else { throw ScreenshotImageError.invalidSelection }
            return crop
        }
        let sx = pointSize.width / CGFloat(base.width), sy = pointSize.height / CGFloat(base.height)
        return try ScreenshotRenderer.render(base: base, pointSize: pointSize, annotations: annotations,
            region: CGRect(x: strip.minX * sx, y: strip.minY * sy, width: strip.width * sx, height: strip.height * sy))
    }
}
