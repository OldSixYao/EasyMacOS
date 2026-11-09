import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PasteManCore

@Suite("图片无损清理与方向") struct ImagePreparationTests {
    @Test func losslessPNGRemovesPrivateMetadataAndPreservesPixelsAlphaAndProfile() throws {
        let marker = "PRIVATE-EASYMACOS-SOURCE"
        let image = try makeImage()
        let input = try encode(image, type: .png, properties: [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 31.2, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyPNGDictionary: [
                kCGImagePropertyPNGAuthor: marker, kCGImagePropertyPNGComment: marker,
                kCGImagePropertyPNGTitle: marker, kCGImagePropertyPNGCopyright: marker,
                kCGImagePropertyPNGDescription: marker, kCGImagePropertyPNGSoftware: marker,
            ],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: marker],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: marker],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: marker],
        ])
        let source = try #require(CGImageSourceCreateWithData(input as CFData, nil))
        let before = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        guard case .image(let png, let thumbnail) = try ImageProcessor.prepare(input) else {
            Issue.record("应得到清理后的图片"); return
        }
        let cleanSource = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let after = try #require(CGImageSourceCreateImageAtIndex(cleanSource, 0, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(cleanSource, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(!String(describing: properties).contains(marker))
        #expect(png.range(of: Data(marker.utf8)) == nil)
        #expect(after.width == before.width && after.height == before.height)
        #expect(after.colorSpace?.name == before.colorSpace?.name)
        #expect(try pixels(after) == pixels(before))
        let thumbSource = try #require(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        let thumb = try #require(CGImageSourceCreateImageAtIndex(thumbSource, 0, nil))
        #expect(max(thumb.width, thumb.height) <= 240)
    }

    @Test func rotatedTIFFStillTransformsPixelsAndDropsSourceMetadata() throws {
        let image = try makeImage()
        let input = try encode(image, type: .tiff, properties: [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFOrientation: 6, kCGImagePropertyTIFFArtist: "PRIVATE-ROTATED"],
        ])
        guard case .image(let png, _) = try ImageProcessor.prepare(input) else { Issue.record("应得到图片"); return }
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let rotated = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(rotated.width == image.height && rotated.height == image.width)
        #expect(!String(describing: CGImageSourceCopyPropertiesAtIndex(source, 0, nil)).contains("PRIVATE-ROTATED"))
    }

    @Test func identicalPNGWithDifferentPrivateMetadataStillDeduplicatesInHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try makeImage()
        let store = try HistoryStore(directory: directory)
        for author in ["PRIVATE-AUTHOR-A", "PRIVATE-AUTHOR-B"] {
            let input = try encode(image, type: .png, properties: [
                kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGAuthor: author],
            ])
            let prepared = try ImageProcessor.prepare(input)
            try await store.save(prepared, sourceBundleID: "test", sourceName: "合成应用", policy: RetentionPolicy())
        }
        #expect(try await store.list().count == 1)
    }

    @Test func chunkFilteringRejectsTruncationOversizedLengthsAndAnimationAndSupportsSlices() throws {
        let png = try encode(makeImage(), type: .png, properties: [:])
        #expect(PNGPixelData.sanitized(Data(png.prefix(20))) == nil)
        var invalid = png
        invalid.replaceSubrange(8..<12, with: [255, 255, 255, 255])
        #expect(PNGPixelData.sanitized(invalid) == nil)
        var animated = png
        animated.insert(contentsOf: [0, 0, 0, 0] + Array("acTL".utf8) + [0, 0, 0, 0], at: 33)
        #expect(PNGPixelData.sanitized(animated) == nil)
        let withPrefix = Data([1, 2, 3]) + png
        #expect(PNGPixelData.sanitized(withPrefix.dropFirst(3)) == PNGPixelData.sanitized(png))
        var withPrivateChunk = png
        let privateBytes = Array("PRIVATE-UNKNOWN-CHUNK".utf8)
        // 未知附属块不会进入输出；不信任其内容，也不让它携带到持久化图片。
        let chunk = [UInt8(0), 0, 0, UInt8(privateBytes.count)] + Array("paSt".utf8) + privateBytes + [0, 0, 0, 0]
        withPrivateChunk.insert(contentsOf: chunk, at: 33)
        #expect(PNGPixelData.sanitized(withPrivateChunk) == PNGPixelData.sanitized(png))
    }

    private func makeImage() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 600, height: 300, bitsPerComponent: 8, bytesPerRow: 2400,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.4, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
        context.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 300, y: 0, width: 300, height: 300))
        return try #require(context.makeImage())
    }
    private func encode(_ image: CGImage, type: UTType, properties: [CFString: Any]) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }
    private func pixels(_ image: CGImage) throws -> Data {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try #require(context.data), count: context.bytesPerRow * context.height)
    }
}
