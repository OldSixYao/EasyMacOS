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
        try db.execute("CREATE INDEX IF NOT EXISTS history_source ON history(source_id)")
        try db.execute("CREATE INDEX IF NOT EXISTS history_ordinary ON history(copied_at DESC) WHERE favorite = 0")
        let database = db
        try database.transaction {
            try database.execute("CREATE TABLE IF NOT EXISTS history_totals (id INTEGER PRIMARY KEY CHECK(id=1), bytes INTEGER NOT NULL, pinned INTEGER NOT NULL, ordinary INTEGER NOT NULL)")
            let columns = try database.rows("PRAGMA table_info(history_totals)") { Database.text($0, 1) }
            if !columns.contains("ordinary") {
                try database.execute("ALTER TABLE history_totals ADD COLUMN ordinary INTEGER NOT NULL DEFAULT 0")
                try database.execute("UPDATE history_totals SET ordinary=(SELECT count(*) FROM history WHERE favorite=0)")
                for name in ["history_insert_total", "history_delete_total", "history_update_total"] {
                    try database.execute("DROP TRIGGER IF EXISTS \(name)")
                }
            }
            // 聚合由触发器与数据修改在同一事务中维护，旧库只在首次打开时计算一次。
            try database.execute("INSERT OR IGNORE INTO history_totals SELECT 1, coalesce(sum(bytes),0), coalesce(sum(CASE WHEN favorite=1 THEN bytes ELSE 0 END),0), coalesce(sum(1-favorite),0) FROM history")
            try database.execute("CREATE TRIGGER IF NOT EXISTS history_insert_total AFTER INSERT ON history BEGIN UPDATE history_totals SET bytes=bytes+NEW.bytes, pinned=pinned+NEW.favorite*NEW.bytes, ordinary=ordinary+1-NEW.favorite WHERE id=1; END")
            try database.execute("CREATE TRIGGER IF NOT EXISTS history_delete_total AFTER DELETE ON history BEGIN UPDATE history_totals SET bytes=bytes-OLD.bytes, pinned=pinned-OLD.favorite*OLD.bytes, ordinary=ordinary-1+OLD.favorite WHERE id=1; END")
            try database.execute("CREATE TRIGGER IF NOT EXISTS history_update_total AFTER UPDATE OF bytes,favorite ON history BEGIN UPDATE history_totals SET bytes=bytes+NEW.bytes-OLD.bytes, pinned=pinned+NEW.favorite*NEW.bytes-OLD.favorite*OLD.bytes, ordinary=ordinary+OLD.favorite-NEW.favorite WHERE id=1; END")
        }
        try db.execute("PRAGMA user_version = 1")
        let known = Set(try db.rows("SELECT id FROM history WHERE kind = 'image'") { Database.text($0, 0) })
        for file in try fm.contentsOfDirectory(at: imageDirectory, includingPropertiesForKeys: nil) {
            let id = file.lastPathComponent.components(separatedBy: ".").first ?? ""
            if !known.contains(id) { try fm.removeItem(at: file) }
        }
    }

    public func list(search: String = "", filter: HistoryFilter = .all, source: String? = nil) throws -> [HistoryEntry]
    {
        try query(search: search, filter: filter, source: source, after: nil, limit: nil).entries
    }

    public func page(search: String = "", filter: HistoryFilter = .all, source: String? = nil,
                     after: HistoryCursor? = nil, limit: Int = 100) throws -> HistoryPage {
        try query(search: search, filter: filter, source: source, after: after, limit: max(1, min(500, limit)))
    }
    private func query(search: String, filter: HistoryFilter, source: String?, after: HistoryCursor?, limit: Int?) throws -> HistoryPage {
        let interval = PerformanceTrace.signposter.beginInterval("HistoryQuery", id: PerformanceTrace.signposter.makeSignpostID())
        defer { PerformanceTrace.signposter.endInterval("HistoryQuery", interval) }
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
        if let after {
            clauses.append("(favorite, copied_at, rowid) < (?, ?, ?)")
            values += [.int(after.favorite), .real(after.timestamp), .int(Int(after.rowID))]
        }
        let fields = "id, kind, preview, copied_at, source_id, source_name, favorite, bytes"
        let tail = " FROM history WHERE \(clauses.joined(separator: " AND ")) ORDER BY favorite DESC, copied_at DESC, rowid DESC"
        guard let limit else {
            return HistoryPage(entries: try db.rows("SELECT " + fields + tail, values, cancellable: true,
                map: Self.decodeEntry), next: nil)
        }
        var rowIndex = 0
        var lastCursor: HistoryCursor?
        let rows = try db.rows("SELECT " + fields + ", rowid" + tail + " LIMIT \(limit + 1)", values, cancellable: true) { row in
            let entry = try Self.decodeEntry(row)
            rowIndex += 1
            if rowIndex <= limit {
                lastCursor = HistoryCursor(favorite: entry.isFavorite ? 1 : 0, timestamp: sqlite3_column_double(row, 3),
                    rowID: sqlite3_column_int64(row, 8), id: entry.id)
            }
            return entry
        }
        let visible = Array(rows.prefix(limit))
        let next = rows.count > limit ? lastCursor : nil
        return HistoryPage(entries: visible, next: next)
    }

    private static func decodeEntry(_ row: OpaquePointer) throws -> HistoryEntry {
        guard let id = UUID(uuidString: Database.text(row, 0)), let kind = ContentKind(rawValue: Database.text(row, 1))
        else { throw StoreError.missingContent }
        return HistoryEntry(id: id, kind: kind, preview: Database.text(row, 2),
            copiedAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 3)), sourceBundleID: Database.text(row, 4),
            sourceName: Database.text(row, 5), isFavorite: sqlite3_column_int(row, 6) != 0,
            byteCount: Int(sqlite3_column_int64(row, 7)))
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
        let interval = PerformanceTrace.signposter.beginInterval("HistorySave", id: PerformanceTrace.signposter.makeSignpostID())
        defer { PerformanceTrace.signposter.endInterval("HistorySave", interval) }
        try Task.checkCancellation()
        try prune(policy: policy, now: now)
        let hash = content.hash
        if let existing = try db.rows(
            "SELECT id FROM history WHERE hash = ?", [.text(hash)], map: { Database.text($0, 0) }
        ).first {
            if case .image(let png, let thumbnail) = content {
                guard let id = UUID(uuidString: existing) else { throw StoreError.missingContent }
                try restoreMissingImages(id, png: png, thumbnail: thumbnail)
            }
            try db.execute(
                "UPDATE history SET copied_at = ?, source_id = ?, source_name = ? WHERE id = ?",
                [.real(now.timeIntervalSince1970), .text(sourceBundleID), .text(sourceName), .text(existing)])
            return
        }
        let pinnedBytes = try totals().pinned
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
        do {
            try db.transaction {
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
        try prune(policy: policy, now: now)
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
        _ = try pruneIfNeeded(policy: policy, now: now)
    }
    public func nextCleanup(policy: RetentionPolicy, now: Date) throws -> Date {
        let oldest = try db.rows("SELECT min(copied_at) FROM history WHERE favorite=0") { row -> Double? in
            sqlite3_column_type(row, 0) == SQLITE_NULL ? nil : sqlite3_column_double(row, 0)
        }.first ?? nil
        return min(now.addingTimeInterval(3600), oldest.map {
            Date(timeIntervalSince1970: $0 + Double(policy.days) * 86400 + 1)
        } ?? now.addingTimeInterval(3600))
    }
    public func pruneIfNeeded(policy: RetentionPolicy, now: Date = Date()) throws -> Bool {
        let cutoff = now.addingTimeInterval(-Double(policy.days) * 86400).timeIntervalSince1970
        var removed: [RetentionEntry] = []
        try db.transaction {
            // 仅返回需要删除的记录，不再为每次复制装载所有历史。
            let expired = try retentionEntries(whereSQL: "favorite = 0 AND copied_at < ?", values: [.real(cutoff)])
            try deleteRows(expired)
            removed += expired
            if try totals().ordinary > policy.count {
                let overflow = try retentionEntries(whereSQL: "rowid IN (SELECT rowid FROM history WHERE favorite=0 ORDER BY copied_at DESC, rowid DESC LIMIT -1 OFFSET ?)", values: [.int(policy.count)])
                try deleteRows(overflow)
                removed += overflow
            }
            let excess = try totals().bytes - policy.byteLimit
            if excess > 0 {
                let capacity = try retentionEntries(whereSQL: "rowid IN (SELECT rowid FROM (SELECT rowid, sum(bytes) OVER (ORDER BY copied_at ASC, rowid ASC ROWS UNBOUNDED PRECEDING)-bytes AS previous FROM history WHERE favorite=0) WHERE previous < ?)", values: [.int(excess)])
                try deleteRows(capacity)
                removed += capacity
            }
        }
        try removeImages(removed)
        return !removed.isEmpty
    }
    private func totals() throws -> (bytes: Int, pinned: Int, ordinary: Int) {
        try db.rows("SELECT bytes, pinned, ordinary FROM history_totals WHERE id=1") {
            (Int(sqlite3_column_int64($0, 0)), Int(sqlite3_column_int64($0, 1)), Int(sqlite3_column_int64($0, 2)))
        }.first ?? (0, 0, 0)
    }
    private func deleteRows(_ entries: [RetentionEntry]) throws {
        for entry in entries { try db.execute("DELETE FROM history WHERE id=?", [.text(entry.id.uuidString)]) }
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
    private func restoreMissingImages(_ id: UUID, png: Data, thumbnail: Data) throws {
        let fm = FileManager.default
        var restored: [URL] = []
        do {
            for (url, data) in [(imageURL(id, thumbnail: false), png), (imageURL(id, thumbnail: true), thumbnail)] {
                // 去重只检查存在性，不读取或重写有效的大图；缺失文件从本次复制的数据恢复。
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                    guard !isDirectory.boolValue else { throw StoreError.missingContent }
                    continue
                }
                try data.write(to: url, options: .atomic)
                restored.append(url)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        } catch {
            // 仅回滚本次补写的文件，原有图片、记录标识和收藏状态不受影响。
            for url in restored { try? fm.removeItem(at: url) }
            throw error
        }
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
    private func retentionEntries(whereSQL: String = "1=1", values: [Database.Value] = []) throws -> [RetentionEntry] {
        try db.rows(
            "SELECT id, kind, copied_at, favorite, bytes FROM history WHERE \(whereSQL)", values
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
