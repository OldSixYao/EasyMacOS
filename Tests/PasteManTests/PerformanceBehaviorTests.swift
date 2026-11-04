import AppKit
import PasteManCore
import Testing

@testable import PasteMan

@Suite("Performance behavior", .serialized) @MainActor struct PerformanceBehaviorTests {
    @Test func thumbnailCacheUsesByteBudgetAndLeastRecentlyUsedEviction() throws {
        let image = try #require(
            CGContext(
                data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage())
        let cache = ThumbnailCache(byteLimit: image.bytesPerRow * image.height * 2)
        let a = UUID()
        let b = UUID()
        let c = UUID()
        cache.insert(image, id: a, pixelSize: 16, generation: cache.generation)
        cache.insert(image, id: b, pixelSize: 16, generation: cache.generation)
        #expect(cache.image(id: a, pixelSize: 16) != nil)
        cache.insert(image, id: c, pixelSize: 16, generation: cache.generation)
        #expect(cache.image(id: b, pixelSize: 16) == nil)
        #expect(cache.image(id: a, pixelSize: 16) != nil)
        #expect(cache.image(id: a, pixelSize: 32) == nil)
        let oldGeneration = cache.generation
        cache.remove(a)
        cache.insert(image, id: a, pixelSize: 16, generation: oldGeneration)
        #expect(cache.image(id: a, pixelSize: 16) == nil)
        cache.removeAll()
        #expect(cache.image(id: c, pixelSize: 16) == nil)
    }

    @Test func longTextPreviewPreservesFullTextAndIsSelectableButReadOnly() throws {
        let value = String(repeating: "中文 JSON {\"value\":123} 🙂\n", count: 10_000)
        let scroll = TextPreview.makeScrollView()
        let textView = try #require(scroll.documentView as? NSTextView)
        TextPreview.setText(value, in: scroll)
        #expect(textView.string == value)
        #expect(textView.isSelectable)
        #expect(!textView.isEditable)
        #expect(textView.layoutManager?.allowsNonContiguousLayout == true)
        TextPreview.setText("second item", in: scroll)
        #expect(textView.string == "second item")
    }
}
