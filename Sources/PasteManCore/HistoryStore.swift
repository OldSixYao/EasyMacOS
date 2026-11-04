import CSQLite
import Foundation

public actor HistoryStore: HistoryRepository {
    private let db: Database
    private let imageDirectory: URL

    public init(directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        imageDirectory = directory.appendingPathComponent("Images", isDirectory: true)
        try fm.createDirectory(
            at: imageDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        db = try Database(path: directory.appendingPathComponent("history.sqlite").path)
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute("PRAGMA secure_delete = ON")
        let version = try db.rows("PRAGMA user_version") { sqlite3_column_int($0, 0) }.first ?? 0
        guard version <= 1 else { throw StoreError.unsupportedVersion }
        try db.execute(
            """
            CREATE TABLE IF NOT EXISTS history (
              id TEXT PRIMARY KEY, kind TEXT NOT NULL, hash TEXT NOT NULL UNIQUE,
              text TEXT, preview TEXT NOT NULL, copied_at REAL NOT NULL,
              source_id TEXT NOT NULL, source_name TEXT NOT NULL,
              favorite INTEGER NOT NULL DEFAULT 0, bytes INTEGER NOT NULL
            )
            """)
        try db.execute("CREATE INDEX IF NOT EXISTS history_recency ON history(favorite DESC, copied_at DESC)")
        try db.execute("PRAGMA user_version = 1")
        let known = Set(try db.rows("SELECT id FROM history WHERE kind = 'image'") { Database.text($0, 0) })
        for file in try fm.contentsOfDirectory(at: imageDirectory, includingPropertiesForKeys: nil) {
            let id = file.lastPathComponent.components(separatedBy: ".").first ?? ""
            if !known.contains(id) { try fm.removeItem(at: file) }
        }
    }

    public func list(search: String = "", filter: HistoryFilter = .all, source: String? = nil) throws -> [HistoryEntry]
    {
        var clauses = ["1=1"]
        var values: [Database.Value] = []
        if !search.isEmpty {
            clauses.append("(instr(lower(coalesce(text,'')), lower(?)) > 0 OR instr(lower(source_name), lower(?)) > 0)")
            values += [.text(search), .text(search)]
        }
        switch filter {
        case .all: break
        case .favorites: clauses.append("favorite = 1")
        case .text, .image:
            clauses.append("kind = ?")
            values.append(.text(filter.rawValue))
        }
        if let source {
            clauses.append("source_id = ?")
            values.append(.text(source))
        }
        return try db.rows(
            "SELECT id, kind, preview, copied_at, source_id, source_name, favorite, bytes FROM history WHERE \(clauses.joined(separator: " AND ")) ORDER BY favorite DESC, copied_at DESC, rowid DESC",
            values, cancellable: true
        ) { row in
            guard let id = UUID(uuidString: Database.text(row, 0)),
                let kind = ContentKind(rawValue: Database.text(row, 1))
            else { throw StoreError.missingContent }
            return HistoryEntry(
                id: id, kind: kind, preview: Database.text(row, 2),
                copiedAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 3)),
                sourceBundleID: Database.text(row, 4), sourceName: Database.text(row, 5),
                isFavorite: sqlite3_column_int(row, 6) != 0, byteCount: Int(sqlite3_column_int64(row, 7)))
        }
    }

    public func sources() throws -> [SourceApplication] {
        try db.rows(
            "SELECT source_id, max(source_name) FROM history GROUP BY source_id ORDER BY lower(max(source_name))",
            cancellable: true
        ) {
            SourceApplication(bundleID: Database.text($0, 0), name: Database.text($0, 1))
        }
    }

    public func save(
        _ content: PreparedContent, sourceBundleID: String, sourceName: String, policy: RetentionPolicy,
        now: Date = Date()
    ) throws {
        // Read only retention fields once; reuse the surviving snapshot for admission
        // and eviction instead of materializing UI previews/source strings twice.
        let entries = try prune(retentionEntries(), policy: policy, now: now)
        let hash = content.hash
        if let existing = try db.rows(
            "SELECT id FROM history WHERE hash = ?", [.text(hash)], map: { Database.text($0, 0) }
        ).first {
            try db.execute(
                "UPDATE history SET copied_at = ?, source_id = ?, source_name = ? WHERE id = ?",
                [.real(now.timeIntervalSince1970), .text(sourceBundleID), .text(sourceName), .text(existing)])
            return
        }
        let pinnedBytes = entries.filter(\.isFavorite).reduce(0) { $0 + $1.byteCount }
        guard content.byteCount <= policy.byteLimit - pinnedBytes else { throw StoreError.storageFull }
        let id = UUID()
        var created: [URL] = []
        if case .image(let png, let thumbnail) = content {
            do {
                for (url, bytes) in [(imageURL(id, thumbnail: false), png), (imageURL(id, thumbnail: true), thumbnail)]
                {
                    try bytes.write(to: url, options: .atomic)
                    created.append(url)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                }
            } catch {
                for url in created { try? FileManager.default.removeItem(at: url) }
                throw error
            }
        }
        var removed: [RetentionEntry] = []
        do {
            try db.transaction {
                var total = entries.reduce(0) { $0 + $1.byteCount } + content.byteCount
                var count = entries.filter { !$0.isFavorite }.count + 1
                for entry in entries.filter({ !$0.isFavorite }).reversed() {
                    guard total > policy.byteLimit || count > policy.count else { break }
                    try db.execute("DELETE FROM history WHERE id = ?", [.text(entry.id.uuidString)])
                    removed.append(entry)
                    total -= entry.byteCount
                    count -= 1
                }
                let text: Database.Value
                let preview: String
                switch content {
                case .text(let string):
                    text = .text(string)
                    preview = String(string.prefix(300))
                case .image:
                    text = .null
                    preview = ""
                }
                try db.execute(
                    "INSERT INTO history (id, kind, hash, text, preview, copied_at, source_id, source_name, bytes) VALUES (?,?,?,?,?,?,?,?,?)",
                    [
                        .text(id.uuidString), .text(content.kind.rawValue), .text(hash), text, .text(preview),
                        .real(now.timeIntervalSince1970), .text(sourceBundleID), .text(sourceName),
                        .int(content.byteCount),
                    ])
            }
        } catch {
            for url in created { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        try removeImages(removed)
    }

    public func setFavorite(_ id: UUID, value: Bool) throws {
        try db.execute("UPDATE history SET favorite = ? WHERE id = ?", [.int(value ? 1 : 0), .text(id.uuidString)])
    }
    public func delete(_ id: UUID) throws {
        try db.execute("DELETE FROM history WHERE id = ?", [.text(id.uuidString)])
        try removeImage(id)
    }
    public func clear(includingFavorites: Bool) throws {
        let removed = try retentionEntries().filter { includingFavorites || !$0.isFavorite }
        try db.execute(includingFavorites ? "DELETE FROM history" : "DELETE FROM history WHERE favorite = 0")
        try removeImages(removed)
        // Best effort: compact deleted text out of the database and WAL. This is not a secure-erase guarantee.
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try db.execute("VACUUM")
    }
    public func prune(policy: RetentionPolicy, now: Date = Date()) throws {
        _ = try prune(retentionEntries(), policy: policy, now: now)
    }
    private func prune(_ entries: [RetentionEntry], policy: RetentionPolicy, now: Date) throws -> [RetentionEntry] {
        let cutoff = now.addingTimeInterval(-Double(policy.days) * 86400)
        var ordinaryCount = 0
        var removed: [RetentionEntry] = []
        var kept: [RetentionEntry] = []
        for entry in entries {
            if !entry.isFavorite {
                ordinaryCount += 1
                if entry.copiedAt < cutoff || ordinaryCount > policy.count {
                    removed.append(entry)
                    continue
                }
            }
            kept.append(entry)
        }
        var total = kept.reduce(0) { $0 + $1.byteCount }
        for entry in kept.reversed() where !entry.isFavorite && total > policy.byteLimit {
            removed.append(entry)
            total -= entry.byteCount
        }
        guard !removed.isEmpty else { return kept }
        try db.transaction {
            for entry in removed { try db.execute("DELETE FROM history WHERE id = ?", [.text(entry.id.uuidString)]) }
        }
        try removeImages(removed)
        let removedIDs = Set(removed.map(\.id))
        return kept.filter { !removedIDs.contains($0.id) }
    }
    public func content(for entry: HistoryEntry) throws -> PreparedContent {
        guard
            let text = try db.rows(
                "SELECT coalesce(text,'') FROM history WHERE id = ?", [.text(entry.id.uuidString)],
                map: { Database.text($0, 0) }
            ).first
        else { throw StoreError.missingContent }
        switch entry.kind {
        case .text: return .text(text)
        case .image: return .image(png: try imageData(for: entry.id, thumbnail: false), thumbnail: Data())
        }
    }
    public func imageData(for id: UUID, thumbnail: Bool) throws -> Data {
        do { return try Data(contentsOf: imageURL(id, thumbnail: thumbnail)) } catch { throw StoreError.missingContent }
    }
    private func imageURL(_ id: UUID, thumbnail: Bool) -> URL {
        imageDirectory.appendingPathComponent(id.uuidString + (thumbnail ? ".thumb.png" : ".png"))
    }
    private func removeImage(_ id: UUID) throws {
        for thumbnail in [false, true] {
            let url = imageURL(id, thumbnail: thumbnail)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
    private struct RetentionEntry {
        let id: UUID
        let kind: ContentKind
        let copiedAt: Date
        let isFavorite: Bool
        let byteCount: Int
    }
    private func retentionEntries() throws -> [RetentionEntry] {
        try db.rows(
            "SELECT id, kind, copied_at, favorite, bytes FROM history ORDER BY favorite DESC, copied_at DESC, rowid DESC"
        ) { row in
            guard let id = UUID(uuidString: Database.text(row, 0)),
                let kind = ContentKind(rawValue: Database.text(row, 1))
            else { throw StoreError.missingContent }
            return RetentionEntry(
                id: id, kind: kind, copiedAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 2)),
                isFavorite: sqlite3_column_int(row, 3) != 0, byteCount: Int(sqlite3_column_int64(row, 4)))
        }
    }
    private func removeImages(_ entries: [RetentionEntry]) throws {
        for entry in entries where entry.kind == .image { try removeImage(entry.id) }
    }
}
