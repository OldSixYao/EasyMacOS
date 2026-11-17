import AppKit
import CoreImage
import os
import PasteManCore
import Testing

@testable import PasteMan

private func generatedBarcode(_ payload: String, filter name: String = "CIQRCodeGenerator") throws -> CGImage {
    let filter = try #require(CIFilter(name: name))
    filter.setValue(Data(payload.utf8), forKey: "inputMessage")
    let image = try #require(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 4, y: 4))
    return try #require(CIContext().createCGImage(image, from: image.extent))
}

private func barcodeScene(width: Int = 800, height: Int = 600, codes: [(CGImage, CGRect)] = []) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.interpolationQuality = .none
    for (image, rect) in codes {
        context.draw(image, in: CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height))
    }
    return try #require(context.makeImage())
}

@Suite("条形码与二维码原生识别") struct ScreenshotBarcodeRecognitionTests {
    @Test func largeCodeAcrossEveryStripBoundaryStillDecodesAlongsideSmallCodes() async throws {
        let large = try generatedBarcode("large-boundary"), small = try generatedBarcode("small-bottom")
        let scene = try barcodeScene(width: 3000, height: 6000, codes: [
            (large, CGRect(x: 200, y: 1800, width: 2600, height: 2600)),
            (small, CGRect(x: 200, y: 5400, width: 200, height: 200)),
        ])
        let text = try await SystemScreenshotBarcodeRecognizer.shared.recognize(
            .image(scene, pointSize: CGSize(width: 1500, height: 3000), annotations: []), progress: { _ in })
        #expect(text == "large-boundary\nsmall-bottom")
        let covering = ScreenshotAnnotation(tool: .pen, points: [CGPoint(x: 0, y: 1500), CGPoint(x: 1500, y: 1500)],
            color: AnnotationColor.palette[5], width: 1500)
        let hidden = try await SystemScreenshotBarcodeRecognizer.shared.recognize(
            .image(scene, pointSize: CGSize(width: 1500, height: 3000), annotations: [covering]), progress: { _ in })
        #expect(hidden == "small-bottom")
    }

    @Test(arguments: ["CIQRCodeGenerator", "CICode128BarcodeGenerator", "CIAztecCodeGenerator", "CIPDF417BarcodeGenerator"])
    func systemRecognizerDecodesCommonFormats(_ filter: String) async throws {
        let payload = "0123456789012"
        let code = try generatedBarcode(payload, filter: filter)
        let scene = try barcodeScene(codes: [(code, CGRect(x: 80, y: 80, width: code.width, height: code.height))])
        let text = try await SystemScreenshotBarcodeRecognizer.shared.recognize(
            .image(scene, pointSize: CGSize(width: 400, height: 300), annotations: []), progress: { _ in })
        #expect(text == payload)
    }

    @Test func multipleCodesKeepPayloadsAndImageOrderWithoutReadingPrintedText() async throws {
        let payload = "https://example.com/截图?value=123"
        let qr = try generatedBarcode(payload)
        let barcode = try generatedBarcode("ABC-123-456", filter: "CICode128BarcodeGenerator")
        let scene = try barcodeScene(width: 1000, height: 1100, codes: [
            (qr, CGRect(x: 40, y: 40, width: 320, height: 320)),
            (qr, CGRect(x: 560, y: 430, width: 320, height: 320)),
            (barcode, CGRect(x: 40, y: 850, width: 700, height: 160)),
        ])
        let text = try await SystemScreenshotBarcodeRecognizer.shared.recognize(
            .image(scene, pointSize: CGSize(width: 1000, height: 1100), annotations: []), progress: { _ in })
        #expect(text == "\(payload)\n\(payload)\nABC-123-456")
    }

    @Test func longImageReadsAcrossBoundaryDeduplicatesOverlapsAndReportsProgress() async throws {
        let first = try generatedBarcode("first"), boundary = try generatedBarcode("boundary"), last = try generatedBarcode("last")
        let scene = try barcodeScene(width: 800, height: 4800, codes: [
            (first, CGRect(x: 40, y: 60, width: 320, height: 320)),
            (boundary, CGRect(x: 40, y: 1450, width: 360, height: 360)),
            (boundary, CGRect(x: 40, y: 2300, width: 360, height: 360)),
            (last, CGRect(x: 40, y: 4250, width: 320, height: 320)),
        ])
        let values = OSAllocatedUnfairLock(initialState: [Double]())
        let text = try await SystemScreenshotBarcodeRecognizer.shared.recognize(
            .image(scene, pointSize: CGSize(width: 400, height: 2400), annotations: []), progress: { value in
                values.withLock { $0.append(value) }
            })
        #expect(text == "first\nboundary\nboundary\nlast")
        let progress = values.withLock { $0 }
        #expect(progress.count == ScreenshotBarcodeLayout.strips(width: 800, height: 4800).count)
        #expect(progress == progress.sorted() && progress.last == 1)
    }

    @Test func pinnedStorageUsesOriginalPixelsAndCommittedMarksHideCodes() async throws {
        let code = try generatedBarcode("original-pinned-payload")
        let scene = try barcodeScene(codes: [(code, CGRect(x: 80, y: 60, width: 320, height: 320))])
        let storage = PinnedImageStorage(png: try ScreenshotRenderer.encode(scene), pointSize: CGSize(width: 400, height: 300))
        let text = try await SystemScreenshotBarcodeRecognizer.shared.recognize(.pinned(storage), progress: { _ in })
        #expect(text == "original-pinned-payload")
        let covering = ScreenshotAnnotation(tool: .pen, points: [CGPoint(x: 0, y: 110), CGPoint(x: 400, y: 110)],
            color: AnnotationColor.palette[5], width: 260)
        let hidden = try await SystemScreenshotBarcodeRecognizer.shared.recognize(
            .image(scene, pointSize: storage.pointSize, annotations: [covering]), progress: { _ in })
        #expect(hidden.isEmpty)
    }

    @Test func blankImageCancellationAndInvalidSizeAreHandled() async throws {
        let scene = try barcodeScene()
        let text = try await SystemScreenshotBarcodeRecognizer.shared.recognize(
            .image(scene, pointSize: CGSize(width: 800, height: 600), annotations: []), progress: { _ in })
        #expect(text.isEmpty)
        let task = Task {
            try await SystemScreenshotBarcodeRecognizer.shared.recognize(
                .image(scene, pointSize: CGSize(width: 800, height: 600), annotations: []), progress: { _ in })
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await #expect(throws: ScreenshotImageError.self) {
            try await SystemScreenshotBarcodeRecognizer.shared.recognize(
                .image(scene, pointSize: .zero, annotations: []), progress: { _ in })
        }
    }

    @Test func overlapMergingPreservesExactPayloadWhitespaceAndSeparatePositions() {
        var codes: [ScreenshotBarcode] = []
        ScreenshotBarcodeLayout.merge([
            ScreenshotBarcode(payload: " a b ", rect: CGRect(x: 10, y: 10, width: 100, height: 100), confidence: 0.7),
            ScreenshotBarcode(payload: " a b ", rect: CGRect(x: 11, y: 11, width: 100, height: 100), confidence: 0.9),
            ScreenshotBarcode(payload: "ab", rect: CGRect(x: 10, y: 10, width: 100, height: 100), confidence: 0.8),
            ScreenshotBarcode(payload: " a b ", rect: CGRect(x: 10, y: 400, width: 100, height: 100), confidence: 0.8),
        ], into: &codes)
        #expect(codes.count == 3 && codes[0].confidence == 0.9)
        #expect(ScreenshotBarcodeLayout.text(from: codes) == "ab\n a b \n a b ")
    }
}
