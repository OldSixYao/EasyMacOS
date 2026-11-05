import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PasteManCore

private struct Fixture {
    let directory: URL
    let store: HistoryStore
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PasteManTests-" + UUID().uuidString)
        store = try HistoryStore(directory: directory)
    }
    func clean() { try? FileManager.default.removeItem(at: directory) }
    func save(
        _ text: String, at: Date? = nil, policy: RetentionPolicy = RetentionPolicy(), app: String = "test.editor",
        name: String = "Editor"
    ) async throws {
        try await store.save(.text(text), sourceBundleID: app, sourceName: name, policy: policy, now: at ?? now)
    }
}

@Suite("History repository") struct HistoryStoreTests {
    @Test func preservesTextAndReopensDatabase() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let value = "  中文\nhttps://example.com/?q='_%\nline\tend\u{0}after-null  "
        try await f.save(value)
        let reopened = try HistoryStore(directory: f.directory)
        let entries = try await reopened.list()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        guard case .text(let result) = try await reopened.content(for: entry) else {
            Issue.record("Expected text")
            return
        }
        #expect(result == value)
        #expect(entry.byteCount == value.utf8.count)
    }

    @Test func duplicateKeepsIdentityAndFavoriteButUpdatesSource() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try await f.save("same")
        let original = try #require(try await f.store.list().first)
        try await f.store.setFavorite(original.id, value: true)
        try await f.save("same", at: f.now.addingTimeInterval(20), app: "test.browser", name: "Browser")
        let entries = try await f.store.list()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.id == original.id)
        #expect(entry.isFavorite)
        #expect(entry.sourceName == "Browser")
        #expect(entry.copiedAt == f.now.addingTimeInterval(20))
    }

    @Test func searchIsLiteralAndFindsFullTextBeyondPreview() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try await f.save(String(repeating: "x", count: 350) + "唯一token %_'")
        try await f.save("unrelated", app: "test.browser", name: "Safari")
        #expect(try await f.store.list(search: "唯一token").count == 1)
        #expect(try await f.store.list(search: "%_'").count == 1)
        #expect(try await f.store.list(search: "SAFARI").count == 1)
        #expect(try await f.store.list(source: "test.editor").count == 1)
        #expect(try await f.store.list(filter: .image).isEmpty)
        #expect(try await f.store.sources().count == 2)
    }

    @Test func favoritesSortBeforeRecentOrdinaryItems() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try await f.save("older")
        let favorite = try #require(try await f.store.list().first)
        try await f.store.setFavorite(favorite.id, value: true)
        try await f.save("newer", at: f.now.addingTimeInterval(1))
        #expect(try await f.store.list().first?.id == favorite.id)
        #expect(try await f.store.list(filter: .favorites).count == 1)
    }

    @Test func countAndAgeDoNotDeleteFavorites() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try await f.save("favorite")
        let favorite = try #require(try await f.store.list().first)
        try await f.store.setFavorite(favorite.id, value: true)
        let policy = RetentionPolicy(days: 1, count: 2)
        for index in 0..<4 {
            try await f.save("item\(index)", at: f.now.addingTimeInterval(Double(index)), policy: policy)
        }
        let entries = try await f.store.list()
        #expect(entries.count == 3)
        #expect(Set(entries.map(\.preview)) == ["favorite", "item2", "item3"])
        try await f.store.prune(policy: policy, now: f.now.addingTimeInterval(2 * 86400))
        #expect(try await f.store.list().map(\.id) == [favorite.id])
    }

    @Test func storageEvictsOldestOrdinaryAndRejectsWhenPinnedFull() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let policy = RetentionPolicy(byteLimit: 10)
        try await f.save("12345", policy: policy)
        let pinned = try #require(try await f.store.list().first)
        try await f.store.setFavorite(pinned.id, value: true)
        try await f.save("abcde", at: f.now.addingTimeInterval(1), policy: policy)
        try await f.save("vwxyz", at: f.now.addingTimeInterval(2), policy: policy)
        #expect(Set(try await f.store.list().map(\.preview)) == ["12345", "vwxyz"])
        await #expect(throws: StoreError.self) { try await f.save("123456", policy: policy) }
        #expect(try await f.store.list().count == 2)
        try await f.store.setFavorite(
            try #require(try await f.store.list().first(where: { !$0.isFavorite })).id, value: true)
        await #expect(throws: StoreError.self) { try await f.save("z", policy: policy) }
        #expect(try await f.store.list().allSatisfy(\.isFavorite))
    }

    @Test func clearKeepsFavoritesUnlessExplicitlyIncluded() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try await f.save("keep")
        let entry = try #require(try await f.store.list().first)
        try await f.store.setFavorite(entry.id, value: true)
        try await f.save("remove")
        try await f.store.clear(includingFavorites: false)
        #expect(try await f.store.list().map(\.id) == [entry.id])
        try await f.store.clear(includingFavorites: true)
        #expect(try await f.store.list().isEmpty)
    }

    @Test func imageRoundTripDeletionAndOrphanCleanup() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let prepared = try ImageProcessor.prepare(makePNG())
        try await f.store.save(
            prepared, sourceBundleID: "test.image", sourceName: "Image App", policy: RetentionPolicy(), now: f.now)
        let image = try #require(try await f.store.list(filter: .image).first)
        #expect(!(try await f.store.imageData(for: image.id, thumbnail: true)).isEmpty)
        #expect(try await f.store.list(search: "Image App").count == 1)
        guard case .image(let png, _) = try await f.store.content(for: image) else {
            Issue.record("Expected image")
            return
        }
        #expect(CGImageSourceCreateWithData(png as CFData, nil) != nil)
        let orphan = f.directory.appendingPathComponent("Images/\(UUID().uuidString).png")
        try Data([1, 2, 3]).write(to: orphan)
        _ = try HistoryStore(directory: f.directory)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(
            FileManager.default.fileExists(
                atPath: f.directory.appendingPathComponent("Images/\(image.id.uuidString).png").path))
        try await f.store.delete(image.id)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: f.directory.appendingPathComponent("Images").path)
                .isEmpty)
        await #expect(throws: StoreError.self) { _ = try await f.store.content(for: image) }
    }

    @Test func missingImageIsRecoverableAndRecordCanBeDeleted() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try await f.store.save(
            try ImageProcessor.prepare(makePNG()), sourceBundleID: "test", sourceName: "test",
            policy: RetentionPolicy(), now: f.now)
        let entry = try #require(try await f.store.list().first)
        try FileManager.default.removeItem(at: f.directory.appendingPathComponent("Images/\(entry.id.uuidString).png"))
        await #expect(throws: StoreError.self) { _ = try await f.store.content(for: entry) }
        try await f.store.delete(entry.id)
        #expect(try await f.store.list().isEmpty)
    }

    @Test(arguments: [1, 2, 3]) func recopyingImageRestoresMissingFilesWithoutReplacingFavorite(_ missing: Int) async throws {
        let f = try Fixture()
        defer { f.clean() }
        let content = try ImageProcessor.prepare(makePNG())
        guard case .image(let png, let thumbnail) = content else { return }
        try await f.store.save(
            content, sourceBundleID: "test.original", sourceName: "Original", policy: RetentionPolicy(), now: f.now)
        let original = try #require(try await f.store.list().first)
        try await f.store.setFavorite(original.id, value: true)
        let imageURL = f.directory.appendingPathComponent("Images/\(original.id.uuidString).png")
        let thumbURL = f.directory.appendingPathComponent("Images/\(original.id.uuidString).thumb.png")
        let files = [(imageURL, png, 1), (thumbURL, thumbnail, 2)]
        let oldDate = f.now.addingTimeInterval(-100)
        for (url, _, bit) in files {
            if missing & bit != 0 { try FileManager.default.removeItem(at: url) }
            else { try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path) }
        }
        let copiedAt = f.now.addingTimeInterval(20)
        try await f.store.save(
            content, sourceBundleID: "test.recopy", sourceName: "Recopy", policy: RetentionPolicy(), now: copiedAt)
        let entries = try await f.store.list()
        let restored = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(restored.id == original.id)
        #expect(restored.isFavorite)
        #expect(restored.copiedAt == copiedAt)
        #expect(restored.sourceBundleID == "test.recopy")
        #expect(restored.byteCount == original.byteCount)
        for (url, expected, bit) in files {
            #expect(try Data(contentsOf: url) == expected)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            if missing & bit == 0 { #expect(attributes[.modificationDate] as? Date == oldDate) }
        }
        guard case .image(let restoredPNG, _) = try await f.store.content(for: restored) else {
            Issue.record("重新复制后应恢复图片内容")
            return
        }
        #expect(restoredPNG == png)
        #expect(try await f.store.imageData(for: restored.id, thumbnail: true) == thumbnail)
    }

    @Test(arguments: [1, 2, 3]) func failedImageRepairKeepsExistingFilesAndRecord(_ missing: Int) async throws {
        let f = try Fixture()
        let images = f.directory.appendingPathComponent("Images")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: images.path)
            f.clean()
        }
        let content = try ImageProcessor.prepare(makePNG())
        guard case .image(let png, let thumbnail) = content else { return }
        try await f.store.save(
            content, sourceBundleID: "test.original", sourceName: "Original", policy: RetentionPolicy(), now: f.now)
        let original = try #require(try await f.store.list().first)
        try await f.store.setFavorite(original.id, value: true)
        let before = try await f.store.list()
        let imageURL = images.appendingPathComponent("\(original.id.uuidString).png")
        let thumbURL = images.appendingPathComponent("\(original.id.uuidString).thumb.png")
        let files = [(imageURL, png, 1), (thumbURL, thumbnail, 2)]
        for (url, _, bit) in files where missing & bit != 0 { try FileManager.default.removeItem(at: url) }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: images.path)
        await #expect(throws: (any Error).self) {
            try await f.store.save(
                content, sourceBundleID: "test.failed", sourceName: "Failed", policy: RetentionPolicy(),
                now: f.now.addingTimeInterval(20))
        }
        #expect(try await f.store.list() == before)
        for (url, expected, bit) in files {
            if missing & bit != 0 { #expect(!FileManager.default.fileExists(atPath: url.path)) }
            else { #expect(try Data(contentsOf: url) == expected) }
        }
    }

    @Test func failedThumbnailRepairRollsBackOnlyNewOriginalFile() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let content = try ImageProcessor.prepare(makePNG())
        try await f.store.save(
            content, sourceBundleID: "test.original", sourceName: "Original", policy: RetentionPolicy(), now: f.now)
        let original = try #require(try await f.store.list().first)
        try await f.store.setFavorite(original.id, value: true)
        let before = try await f.store.list()
        let image = f.directory.appendingPathComponent("Images/\(original.id.uuidString).png")
        let blockedThumbnail = f.directory.appendingPathComponent("Images/\(original.id.uuidString).thumb.png")
        try FileManager.default.removeItem(at: image)
        try FileManager.default.removeItem(at: blockedThumbnail)
        try FileManager.default.createDirectory(at: blockedThumbnail, withIntermediateDirectories: false)
        let sentinel = blockedThumbnail.appendingPathComponent("必须保留")
        try Data([42]).write(to: sentinel)
        await #expect(throws: StoreError.missingContent) {
            try await f.store.save(
                content, sourceBundleID: "test.failed", sourceName: "Failed", policy: RetentionPolicy(),
                now: f.now.addingTimeInterval(20))
        }
        #expect(try await f.store.list() == before)
        #expect(!FileManager.default.fileExists(atPath: image.path))
        #expect(try Data(contentsOf: sentinel) == Data([42]))
    }
}

@Suite("Capture privacy and image limits") struct CaptureTests {
    @Test func countGateDoesNotReplayPausedOrSelfWrittenContent() {
        var gate = CaptureGate(count: 10)
        let consumed1 = gate.consume(count: 10, enabled: true)
        #expect(!consumed1)
        let consumed2 = gate.consume(count: 11, enabled: true)
        #expect(consumed2)
        let consumed3 = gate.consume(count: 12, enabled: false)
        #expect(!consumed3)
        let consumed4 = gate.consume(count: 12, enabled: true)
        #expect(!consumed4)
        gate.reset(to: 13)
        let consumed5 = gate.consume(count: 13, enabled: true)
        #expect(!consumed5)
        let consumed6 = gate.consume(count: 14, enabled: true)
        #expect(consumed6)
        let consumed7 = gate.consume(count: 15, enabled: false)
        #expect(!consumed7)  // denied clipboard permission
        let consumed8 = gate.consume(count: 15, enabled: true)
        #expect(!consumed8)
    }
    @Test func sensitiveTypesAndPasswordManagersAreExcluded() {
        for type in PrivacyPolicy.sensitiveTypes {
            #expect(PrivacyPolicy.shouldIgnore(types: [type, "public.utf8-plain-text"], source: "test", excluded: []))
        }
        #expect(
            PrivacyPolicy.shouldIgnore(
                types: [], source: "com.apple.Passwords", excluded: PrivacyPolicy.defaultExcludedApps))
        #expect(PrivacyPolicy.shouldIgnore(types: [], source: "custom.app", excluded: ["custom.app"]))
        #expect(
            !PrivacyPolicy.shouldIgnore(
                types: ["public.png"], source: "com.apple.Safari", excluded: PrivacyPolicy.defaultExcludedApps))
    }
    @Test func malformedAndOversizedImagesAreRejected() throws {
        #expect(throws: StoreError.self) { try ImageProcessor.prepare(Data([0, 1, 2])) }
        #expect(throws: StoreError.self) {
            try ImageProcessor.prepare(Data(count: ImageProcessor.maximumInputBytes + 1))
        }
    }
    @Test func pngPreservesAlphaAndThumbnailIsBounded() throws {
        let content = try ImageProcessor.prepare(makePNG(width: 600, height: 300))
        guard case .image(let png, let thumb) = content else {
            Issue.record("Expected image")
            return
        }
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 600 && image.height == 300)
        #expect(image.alphaInfo != .none && image.alphaInfo != .noneSkipFirst && image.alphaInfo != .noneSkipLast)
        let thumbSource = try #require(CGImageSourceCreateWithData(thumb as CFData, nil))
        let small = try #require(CGImageSourceCreateImageAtIndex(thumbSource, 0, nil))
        #expect(max(small.width, small.height) <= 240)
    }
}

private func makePNG(width: Int = 8, height: Int = 8) throws -> Data {
    let context = try #require(
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 0.5))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}
