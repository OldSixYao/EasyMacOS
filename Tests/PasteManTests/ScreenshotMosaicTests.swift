import AppKit
import ImageIO
import Testing

@testable import PasteMan

func mosaicImage(width: Int = 160, height: Int = 120) -> CGImage {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * 4
            bytes[offset] = UInt8((x * 47 + y * 23) % 256)
            bytes[offset + 1] = UInt8((x * 17 + y * 59) % 256)
            bytes[offset + 2] = UInt8((x * 31 + y * 7) % 256)
        }
    }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

func mosaicPixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
    let data = image.dataProvider!.data!
    let bytes = CFDataGetBytePtr(data)!
    defer { withExtendedLifetime(data) {} }
    return Array(UnsafeBufferPointer(start: bytes + y * image.bytesPerRow + x * 4, count: 4))
}

private func mosaicBytes(_ image: CGImage) -> Data {
    let source = image.dataProvider!.data!
    let bytes = CFDataGetBytePtr(source)!
    defer { withExtendedLifetime(source) {} }
    var data = Data()
    for row in 0..<image.height { data.append(bytes + row * image.bytesPerRow, count: image.width * 4) }
    return data
}

private func mosaicMark(_ points: [CGPoint], mode: ScreenshotMosaicMode = .brush,
                        diameter: CGFloat = 16, block: CGFloat = 12) -> ScreenshotAnnotation {
    ScreenshotAnnotation(tool: .mosaic, points: points, color: AnnotationColor.palette[0], width: 3,
        mosaic: ScreenshotMosaicOptions(mode: mode, brushSize: diameter, blockSize: block))
}

@Suite("马赛克像素与分段") struct ScreenshotMosaicTests {
    @Test(arguments: [1, 2]) func rectangleUsesImageGridAndChangesOnlySelectedPixels(_ scale: Int) throws {
        let base = mosaicImage(width: 160 * scale, height: 120 * scale)
        let size = CGSize(width: 160, height: 120)
        let mark = mosaicMark([CGPoint(x: 13, y: 11), CGPoint(x: 137, y: 105)], mode: .rectangle)
        let original = try ScreenshotRenderer.render(base: base, pointSize: size, annotations: [])
        let result = try ScreenshotRenderer.export(base: base, pointSize: size, annotations: [mark])
        #expect(mosaicPixel(result.image, 25 * scale, 25 * scale) == mosaicPixel(result.image, 34 * scale, 34 * scale))
        #expect(mosaicPixel(result.image, 25 * scale, 25 * scale) != mosaicPixel(original, 25 * scale, 25 * scale))
        #expect(mosaicPixel(result.image, 12 * scale, 30 * scale) == mosaicPixel(original, 12 * scale, 30 * scale))
        #expect(mosaicPixel(result.image, 145 * scale, 110 * scale) == mosaicPixel(original, 145 * scale, 110 * scale))
        let source = try #require(CGImageSourceCreateWithData(result.png as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == base.width && decoded.height == base.height)
        #expect(mosaicPixel(decoded, 25 * scale, 25 * scale) == mosaicPixel(result.image, 25 * scale, 25 * scale))
    }

    @Test func closedBrushPathIncludesEverySegmentButLeavesItsInteriorUntouched() throws {
        let base = mosaicImage()
        let mark = mosaicMark([CGPoint(x: 20, y: 20), CGPoint(x: 130, y: 20), CGPoint(x: 130, y: 90),
            CGPoint(x: 20, y: 90), CGPoint(x: 20, y: 20)])
        #expect(mark.coverageBounds == CGRect(x: 12, y: 12, width: 126, height: 86))
        let result = try ScreenshotRenderer.render(base: base, pointSize: CGSize(width: 160, height: 120), annotations: [mark])
        for point in [CGPoint(x: 60, y: 20), CGPoint(x: 130, y: 60), CGPoint(x: 60, y: 90), CGPoint(x: 20, y: 60)] {
            #expect(mosaicPixel(result, Int(point.x), Int(point.y)) != mosaicPixel(base, Int(point.x), Int(point.y)))
        }
        #expect(mosaicPixel(result, 75, 55) == mosaicPixel(base, 75, 55))
        #expect(mosaicPixel(result, 5, 5) == mosaicPixel(base, 5, 5))
    }

    @Test func dotClipsAtImageEdgeAndBrushDiameterIsIndependentOfBlocks() throws {
        let base = mosaicImage(), size = CGSize(width: 160, height: 120)
        let dot = mosaicMark([CGPoint(x: 1, y: 1)], diameter: 32)
        let result = try ScreenshotRenderer.render(base: base, pointSize: size, annotations: [dot])
        #expect(dot.canCommit)
        #expect(mosaicPixel(result, 2, 2) != mosaicPixel(base, 2, 2))
        #expect(mosaicPixel(result, 30, 30) == mosaicPixel(base, 30, 30))
        let path = [CGPoint(x: 20, y: 50), CGPoint(x: 130, y: 50)]
        let narrow = try ScreenshotRenderer.render(base: base, pointSize: size, annotations: [mosaicMark(path)])
        let wide = try ScreenshotRenderer.render(base: base, pointSize: size, annotations: [mosaicMark(path, diameter: 40)])
        let coarse = try ScreenshotRenderer.render(base: base, pointSize: size, annotations: [mosaicMark(path, diameter: 40, block: 24)])
        #expect(mosaicPixel(narrow, 60, 65) == mosaicPixel(base, 60, 65))
        #expect(mosaicPixel(wide, 60, 65) != mosaicPixel(base, 60, 65))
        #expect(mosaicPixel(wide, 60, 50) != mosaicPixel(coarse, 60, 50))
        #expect(mosaicPixel(coarse, 60, 80) == mosaicPixel(base, 60, 80))
        #expect(!mosaicMark([CGPoint(x: 10, y: 10)], mode: .rectangle).canCommit)
    }

    @Test func previewSourcesMatchExportAndHonorPreviousAnnotations() throws {
        let base = mosaicImage(width: 257, height: 120), size = CGSize(width: 257, height: 120)
        let stroke = ScreenshotAnnotation(tool: .pen, points: [CGPoint(x: 10, y: 40), CGPoint(x: 250, y: 65)],
            color: AnnotationColor.palette[2], width: 14)
        let mark = mosaicMark([CGPoint(x: 15, y: 50), CGPoint(x: 255, y: 60)], diameter: 36, block: 7)
        let patches = try ScreenshotRenderer.mosaicSources(base: base, pointSize: size, annotations: [stroke],
            tiles: ScreenshotMosaicTile.covering(mark.coverageBounds, pointSize: size, blockSize: 7), blockSize: 7)
        let prior = try ScreenshotRenderer.render(base: base, pointSize: size, annotations: [stroke])
        let context = try #require(CGContext(data: nil, width: 257, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: 120); context.scaleBy(x: 1, y: -1)
        ScreenshotRenderer.drawImage(prior, in: CGRect(origin: .zero, size: size), context: context)
        mark.clipMosaic(in: context)
        for patch in patches { patch.draw(in: context) }
        let preview = try #require(context.makeImage())
        let output = try ScreenshotRenderer.render(base: base, pointSize: size, annotations: [stroke, mark])
        #expect(mosaicBytes(preview) == mosaicBytes(output))
        let reversed = try ScreenshotRenderer.render(base: base, pointSize: size, annotations: [mark, stroke])
        #expect(mosaicBytes(output) != mosaicBytes(reversed))
    }

    @Test func brushAndRectangleRemainSeamlessAcrossLongImageTiles() throws {
        let base = mosaicImage(width: 514, height: 2200), size = CGSize(width: 257, height: 1100)
        let marks = [mosaicMark([CGPoint(x: 4, y: 450), CGPoint(x: 253, y: 545), CGPoint(x: 20, y: 920),
            CGPoint(x: 250, y: 1098)], diameter: 28, block: 7),
            mosaicMark([CGPoint(x: 3, y: 493), CGPoint(x: 255, y: 1065)], mode: .rectangle, block: 13)]
        let full = try ScreenshotRenderer.render(base: base, pointSize: size, annotations: marks)
        for y in [0, 1024, 2048] {
            let height = min(1024, 2200 - y)
            let tile = try ScreenshotRenderer.render(base: base, pointSize: size, annotations: marks,
                region: CGRect(x: 0, y: CGFloat(y) / 2, width: 257, height: CGFloat(height) / 2))
            let expected = try #require(full.cropping(to: CGRect(x: 0, y: y, width: 514, height: height)))
            let actualBytes = mosaicBytes(tile), expectedBytes = mosaicBytes(expected)
            let mismatch = actualBytes.indices.first { actualBytes[$0] != expectedBytes[$0] }
            let differences = actualBytes.indices.filter { actualBytes[$0] != expectedBytes[$0] }
            let detail = mismatch.map { "坐标 \(($0 / 4) % 514), \(($0 / 4) / 514)，值 \(actualBytes[$0]) / \(expectedBytes[$0])" } ?? ""
            #expect(actualBytes == expectedBytes, "分段起点 \(y)，差异字节 \(differences.count)，\(detail)")
        }
    }

    @Test func annotationCodingPreservesNewSettingsAndAcceptsLegacyMosaics() throws {
        let legacy = ScreenshotAnnotation(tool: .mosaic, points: [.zero, CGPoint(x: 80, y: 60)],
            color: AnnotationColor.palette[0], width: 6)
        let legacyData = try JSONEncoder().encode(legacy)
        let legacyObject = try #require(JSONSerialization.jsonObject(with: legacyData) as? [String: Any])
        #expect(legacyObject["mosaic"] == nil)
        let decoded = try JSONDecoder().decode(ScreenshotAnnotation.self, from: legacyData)
        #expect(decoded.mosaic == nil && decoded == legacy)
        for mode in ScreenshotMosaicMode.allCases {
            let mark = mosaicMark([CGPoint(x: 10, y: 20), CGPoint(x: 150, y: 90)], mode: mode, diameter: 64, block: 25)
            #expect(try JSONDecoder().decode(ScreenshotAnnotation.self, from: JSONEncoder().encode(mark)) == mark)
        }
    }

    @Test func pixelReplacementKeepsTransparencyWithoutBlendingOriginalDetails() throws {
        let width = 80, height = 60
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                bytes[offset] = UInt8((x * 31 + y * 17) % 128)
                bytes[offset + 1] = UInt8((x * 11 + y * 41) % 128)
                bytes[offset + 2] = UInt8((x * 7 + y * 23) % 128)
                bytes[offset + 3] = 128
            }
        }
        let base = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        for mode in ScreenshotMosaicMode.allCases {
            let mark = mosaicMark([CGPoint(x: 12, y: 22), CGPoint(x: 65, y: 36)], mode: mode, diameter: 40)
            let result = try ScreenshotRenderer.render(base: base, pointSize: CGSize(width: width, height: height), annotations: [mark])
            #expect(mosaicPixel(result, 28, 28)[3] == 128)
            #expect(mosaicPixel(result, 28, 28) == mosaicPixel(result, 32, 32))
            #expect(mosaicPixel(result, 2, 58) == mosaicPixel(base, 2, 58))
        }
    }

    @Test func incrementalWorkerHandlesBothNewMosaicModesAndHistoryBranches() async throws {
        let base = mosaicImage(), size = CGSize(width: 160, height: 120), session = UUID()
        var history = AnnotationHistory()
        let marks = [mosaicMark([CGPoint(x: 10, y: 10), CGPoint(x: 145, y: 75)], mode: .rectangle),
            mosaicMark([CGPoint(x: 12, y: 70), CGPoint(x: 150, y: 85)], diameter: 40, block: 24)]
        for mark in marks {
            history.append(mark)
            let incremental = try await ScreenshotRenderWorker.shared.preview(base: base, pointSize: size,
                annotations: history.annotations, session: session)
            let expected = try ScreenshotRenderer.render(base: base, pointSize: size, annotations: history.annotations)
            #expect(mosaicBytes(incremental) == mosaicBytes(expected))
        }
        history.undo(); history.undo(); history.redo()
        let branch = try await ScreenshotRenderWorker.shared.preview(base: base, pointSize: size,
            annotations: history.annotations, session: session)
        let expected = try ScreenshotRenderer.render(base: base, pointSize: size, annotations: [marks[0]])
        #expect(mosaicBytes(branch) == mosaicBytes(expected))
        await ScreenshotRenderWorker.shared.releasePreview(session: session)
    }
}
