import CryptoKit
import Foundation

public enum ContentKind: String, Sendable, Codable { case text, image }
public enum HistoryFilter: String, CaseIterable, Sendable { case all, text, image, favorites }

public struct HistoryEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let kind: ContentKind
    public let preview: String
    public let copiedAt: Date
    public let sourceBundleID: String
    public let sourceName: String
    public let isFavorite: Bool
    public let byteCount: Int
}

public struct SourceApplication: Identifiable, Sendable, Equatable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
}

public struct HistoryCursor: Sendable {
    let favorite: Int
    let timestamp: Double
    let rowID: Int64
    let id: UUID
}

public struct HistoryPage: Sendable {
    public let entries: [HistoryEntry]
    public let next: HistoryCursor?
}

public enum PreparedContent: Sendable {
    case text(String)
    case image(png: Data, thumbnail: Data)

    var kind: ContentKind {
        switch self {
        case .text: .text
        case .image: .image
        }
    }
    var hash: String {
        let bytes: Data
        switch self {
        case .text(let text): bytes = Data(text.utf8)
        case .image(let png, _): bytes = png
        }
        return kind.rawValue + ":" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    var byteCount: Int {
        switch self {
        case .text(let text): text.utf8.count
        case .image(let png, let thumb): png.count + thumb.count
        }
    }
}

public struct RetentionPolicy: Sendable {
    public var days: Int
    public var count: Int
    public var byteLimit: Int
    public init(days: Int = 30, count: Int = 500, byteLimit: Int = 512 * 1024 * 1024) {
        self.days = max(1, days)
        self.count = max(1, count)
        self.byteLimit = max(1, byteLimit)
    }
}

public enum StoreError: Error, LocalizedError, Sendable, Equatable {
    case database(String)
    case storageFull, processingBusy, missingContent, invalidImage, imageTooLarge, unsupportedVersion
    public var errorDescription: String? {
        switch self {
        case .database(let message): "History database: \(message)"
        case .storageFull: "The storage budget is full. Remove some favorites or increase available space."
        case .processingBusy: "Clipboard processing is busy. This copy was skipped; copy it again when processing finishes."
        case .missingContent: "This item is missing or damaged."
        case .invalidImage: "This image could not be decoded."
        case .imageTooLarge: "Image skipped: maximum 20 MiB and 40 million pixels."
        case .unsupportedVersion: "This history was created by a newer version of EasyMacOS."
        }
    }
}

public protocol HistoryRepository: Sendable {
    func retry() async throws
    func nextCleanup(policy: RetentionPolicy, now: Date) async throws -> Date
    func page(search: String, filter: HistoryFilter, source: String?, after: HistoryCursor?, limit: Int) async throws -> HistoryPage
    func pruneIfNeeded(policy: RetentionPolicy, now: Date) async throws -> Bool
    func list(search: String, filter: HistoryFilter, source: String?) async throws -> [HistoryEntry]
    func sources() async throws -> [SourceApplication]
    func save(
        _ content: PreparedContent, sourceBundleID: String, sourceName: String, policy: RetentionPolicy, now: Date)
        async throws
    func setFavorite(_ id: UUID, value: Bool) async throws
    func delete(_ id: UUID) async throws
    func clear(includingFavorites: Bool) async throws
    func prune(policy: RetentionPolicy, now: Date) async throws
    func content(for entry: HistoryEntry) async throws -> PreparedContent
    func imageData(for id: UUID, thumbnail: Bool) async throws -> Data
}

public extension HistoryRepository {
    func retry() async throws {}
    func nextCleanup(policy: RetentionPolicy, now: Date) async throws -> Date { now.addingTimeInterval(3600) }
    func page(search: String, filter: HistoryFilter, source: String?, after: HistoryCursor?, limit: Int) async throws -> HistoryPage {
        let all = try await list(search: search, filter: filter, source: source)
        let start = after.flatMap { cursor in all.firstIndex(where: { $0.id == cursor.id }).map { $0 + 1 } } ?? 0
        let rows = Array(all.dropFirst(start).prefix(max(1, limit)))
        let next = start + rows.count < all.count ? rows.last.map {
            HistoryCursor(favorite: $0.isFavorite ? 1 : 0, timestamp: $0.copiedAt.timeIntervalSince1970, rowID: 0, id: $0.id)
        } : nil
        return HistoryPage(entries: rows, next: next)
    }
    func pruneIfNeeded(policy: RetentionPolicy, now: Date) async throws -> Bool {
        let before = try await list(search: "", filter: .all, source: nil).map(\.id)
        try await prune(policy: policy, now: now)
        return try await list(search: "", filter: .all, source: nil).map(\.id) != before
    }
}

/// A count is consumed even when a copy is ignored, so paused/blocked contents are never replayed.
public struct CaptureGate: Sendable {
    public private(set) var lastCount: Int
    public init(count: Int) { lastCount = count }
    public mutating func reset(to count: Int) { lastCount = count }
    public mutating func consume(count: Int, enabled: Bool) -> Bool {
        guard count != lastCount else { return false }
        lastCount = count
        return enabled
    }
}

public enum PrivacyPolicy {
    public static let sensitiveTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword",
        "com.typeit4me.clipping", "de.petermaurer.TransientPasteboardType",
    ]
    public static let defaultExcludedApps: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.dashlane.Dashlane", "com.keepassxc.keepassxc",
        "org.keepassxc.keepassxc", "com.apple.Passwords", "com.lastpass.LastPass",
    ]
    public static func shouldIgnore(types: Set<String>, source: String, excluded: Set<String>) -> Bool {
        !types.isDisjoint(with: sensitiveTypes) || excluded.contains(source)
    }
}
