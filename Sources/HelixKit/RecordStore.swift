import CryptoKit
import Foundation
import SQLite3

/// Native, editable storage for a collection's data.
///
/// On first use every record of every relation is copied from the Helix heap into a
/// SQLite database; from then on the database is the source of truth and the Helix
/// file is never written. Schema:
/// ```
/// relations(id, name, data_id)
/// fields(relation_id, field_id, object_id, name, type)
/// records(relation_id, record_id, modified)       -- modified: 0 imported, 1 edited/new
/// field_values(relation_id, record_id, field_id, kind, text, number, int1, int2, blob)
/// history(seq, time, relation_id, record_id, action, before, after, note)  -- JSON record values
/// ```
public final class RecordStore {
    public struct HistoryEntry: Identifiable, Hashable {
        public enum Action: String { case insert, update, delete, design }
        public let id: Int
        public let date: Date
        public let relationID: Int
        public let recordID: UInt32
        public let action: Action
        public let before: Record?
        public let after: Record?
        public let note: String

        /// Field ids whose value differs between before and after.
        public var changedFields: [UInt16] {
            let b = before?.values ?? [:], a = after?.values ?? [:]
            return Set(b.keys).union(a.keys).filter { b[$0] != a[$0] }.sorted()
        }
    }

    public let url: URL
    private var db: OpaquePointer?

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw storeError("Cannot open \(url.path)") }
        try exec("""
            PRAGMA journal_mode = WAL;
            PRAGMA foreign_keys = ON;
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE IF NOT EXISTS relations(id INTEGER PRIMARY KEY, name TEXT, data_id INTEGER);
            CREATE TABLE IF NOT EXISTS fields(relation_id INTEGER, field_id INTEGER, object_id INTEGER, name TEXT, type TEXT,
                PRIMARY KEY(relation_id, field_id));
            CREATE TABLE IF NOT EXISTS records(relation_id INTEGER, record_id INTEGER, modified INTEGER DEFAULT 0,
                PRIMARY KEY(relation_id, record_id));
            CREATE TABLE IF NOT EXISTS field_values(relation_id INTEGER, record_id INTEGER, field_id INTEGER,
                kind TEXT, text TEXT, number REAL, int1 INTEGER, int2 INTEGER, blob BLOB,
                PRIMARY KEY(relation_id, record_id, field_id),
                FOREIGN KEY(relation_id, record_id) REFERENCES records ON DELETE CASCADE);
            CREATE TABLE IF NOT EXISTS helix_base(relation_id INTEGER, record_id INTEGER, json TEXT,
                PRIMARY KEY(relation_id, record_id));
            CREATE TABLE IF NOT EXISTS history(seq INTEGER PRIMARY KEY AUTOINCREMENT, time REAL, relation_id INTEGER,
                record_id INTEGER, action TEXT, before TEXT, after TEXT, note TEXT);
            """)
        try migrate()
    }

    /// Adds columns introduced after the first release.
    private func migrate() throws {
        var hasEdited = false
        try query("PRAGMA table_info(records)", []) { s in
            if sqlite3_column_text(s, 1).map({ String(cString: $0) }) == "edited" { hasEdited = true }
        }
        if !hasEdited {
            try exec("ALTER TABLE records ADD COLUMN edited INTEGER DEFAULT 0; UPDATE records SET edited = modified;")
        }
    }

    deinit {
        statements.values.forEach { sqlite3_finalize($0) }
        sqlite3_close(db)
    }

    /// Default location: `~/Library/Application Support/Faulix/<name>-<content hash>.sqlite`.
    /// Databases from before the rename (`Not Helix/`) are moved there on first use.
    /// Keyed by content so the same collection file finds its edits even if moved.
    public static func defaultURL(for heap: HeapFile, name: String) -> URL {
        let digest = SHA256.hash(data: Data(heap.bytes)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("Faulix", isDirectory: true)
        let legacy = support.appendingPathComponent("Not Helix", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: folder.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: folder)
        }
        // A newer Helix file brought in with "Update from Helix File" maps to the same database.
        if let target = aliases(in: folder)[digest] { return folder.appendingPathComponent(target) }
        return folder.appendingPathComponent("\(safe)-\(digest).sqlite")
    }

    static func aliases(in folder: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("aliases.json")) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    /// Makes opening `heap` (a newer Helix file) open this database.
    public func registerAlias(for heap: HeapFile) {
        let digest = SHA256.hash(data: Data(heap.bytes)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let folder = url.deletingLastPathComponent()
        var map = Self.aliases(in: folder)
        map[digest] = url.lastPathComponent
        if let data = try? JSONEncoder().encode(map) { try? data.write(to: folder.appendingPathComponent("aliases.json")) }
    }

    // MARK: Backups

    public var backupFolder: URL { url.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true) }

    /// Copies the database into Backups/ (at most once per `minimumInterval`), keeping the newest `keep`.
    @discardableResult
    public func backupIfNeeded(minimumInterval: TimeInterval = 86_400, keep: Int = 15, force: Bool = false) throws -> URL? {
        let fm = FileManager.default
        try fm.createDirectory(at: backupFolder, withIntermediateDirectories: true)
        let base = url.deletingPathExtension().lastPathComponent
        let existing = (try fm.contentsOfDirectory(at: backupFolder, includingPropertiesForKeys: [.creationDateKey]))
            .filter { $0.lastPathComponent.hasPrefix(base) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        if !force, let newest = existing.first,
           let date = try newest.resourceValues(forKeys: [.creationDateKey]).creationDate,
           Date().timeIntervalSince(date) < minimumInterval { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmmss"
        let dest = backupFolder.appendingPathComponent("\(base) \(f.string(from: Date())).sqlite")
        try backup(to: dest)
        for old in existing.dropFirst(max(0, keep - 1)) { try? fm.removeItem(at: old) }
        return dest
    }

    public var isImported: Bool { (try? metaValue("imported")) == "1" }

    /// Copies all relations, fields and records from the Helix file (once).
    public func importIfNeeded(from collection: HelixCollection) throws {
        guard !isImported else { return }
        try transaction {
            try exec("DELETE FROM field_values; DELETE FROM records; DELETE FROM fields; DELETE FROM relations;")
            for rel in collection.relations {
                try run("INSERT INTO relations VALUES (?, ?, ?)", [.int(rel.id), .text(rel.name), .int(Int(rel.dataID))])
                for f in rel.fields {
                    try run("INSERT INTO fields VALUES (?, ?, ?, ?, ?)",
                            [.int(rel.id), .int(Int(f.fieldID)), .int(f.id), .text(f.name), .text(f.type.description)])
                }
                for r in try collection.records(of: rel) {
                    try insert(r, relationID: rel.id, modified: false)
                }
            }
            try run("INSERT OR REPLACE INTO meta VALUES ('imported', '1')", [])
            try run("INSERT OR REPLACE INTO meta VALUES ('source', ?)", [.text(collection.name)])
        }
    }

    public func records(ofRelation relationID: Int) throws -> [Record] {
        var byID: [UInt32: Record] = [:]
        var order: [UInt32] = []
        try query("SELECT record_id FROM records WHERE relation_id = ? ORDER BY record_id", [.int(relationID)]) { s in
            let id = UInt32(sqlite3_column_int64(s, 0))
            order.append(id)
            byID[id] = Record(id: id, values: [:])
        }
        try query("SELECT record_id, field_id, kind, text, number, int1, int2, blob FROM field_values WHERE relation_id = ?",
                  [.int(relationID)]) { s in
            let rid = UInt32(sqlite3_column_int64(s, 0)), fid = UInt16(sqlite3_column_int(s, 1))
            byID[rid]?.values[fid] = Self.value(s)
        }
        return order.compactMap { byID[$0] }
    }

    public func modifiedRecordIDs(ofRelation relationID: Int) throws -> Set<UInt32> {
        var ids = Set<UInt32>()
        try query("SELECT record_id FROM records WHERE relation_id = ? AND modified = 1", [.int(relationID)]) { s in
            ids.insert(UInt32(sqlite3_column_int64(s, 0)))
        }
        return ids
    }

    public func record(_ recordID: UInt32, relationID: Int) throws -> Record? {
        var found = false
        var r = Record(id: recordID, values: [:])
        try query("SELECT 1 FROM records WHERE relation_id = ? AND record_id = ?", [.int(relationID), .int(Int(recordID))]) { _ in
            found = true
        }
        guard found else { return nil }
        try query("SELECT record_id, field_id, kind, text, number, int1, int2, blob FROM field_values WHERE relation_id = ? AND record_id = ?",
                  [.int(relationID), .int(Int(recordID))]) { s in
            r.values[UInt16(sqlite3_column_int(s, 1))] = Self.value(s)
        }
        return r
    }

    /// Inserts or replaces a record (Helix "Enter" / "Replace") and logs the change.
    /// Returns the history entry, or nil if nothing changed.
    @discardableResult
    public func save(_ record: Record, relationID: Int, note: String = "") throws -> HistoryEntry? {
        try put(record, recordID: record.id, relationID: relationID, note: note)
    }

    @discardableResult
    public func delete(recordID: UInt32, relationID: Int, note: String = "") throws -> HistoryEntry? {
        try put(nil, recordID: recordID, relationID: relationID, note: note)
    }

    /// Sets a record to a given state (nil = absent). Used for saving, deleting, undo and restore.
    /// `userEdit` marks the record as changed in Faulix (updates from Helix pass false), so a later
    /// update from a newer Helix file will not overwrite it.
    @discardableResult
    public func put(_ record: Record?, recordID: UInt32, relationID: Int, note: String = "", userEdit: Bool = true) throws -> HistoryEntry? {
        var entry: HistoryEntry?
        try transaction { entry = try putInTransaction(record, recordID: recordID, relationID: relationID, note: note, userEdit: userEdit) }
        return entry
    }

    private func putInTransaction(_ record: Record?, recordID: UInt32, relationID: Int, note: String, userEdit: Bool) throws -> HistoryEntry? {
        let before = try self.record(recordID, relationID: relationID)
        guard before?.values != record?.values || (before == nil) != (record == nil) else { return nil }
        let wasEdited = try isEdited(recordID, relationID: relationID)
        try run("DELETE FROM records WHERE relation_id = ? AND record_id = ?", [.int(relationID), .int(Int(recordID))])
        if let record {
            try insert(record, relationID: relationID, modified: true)
            try run("UPDATE records SET edited = ? WHERE relation_id = ? AND record_id = ?",
                    [.int(userEdit || wasEdited ? 1 : 0), .int(relationID), .int(Int(recordID))])
        }
        if record == nil, userEdit {
            // Remember deletions made in Faulix so a Helix update does not bring the record back.
            try run("INSERT OR REPLACE INTO meta VALUES (?, '1')", [.text("deleted-\(relationID)-\(recordID)")])
        }
        let action: HistoryEntry.Action = before == nil ? .insert : record == nil ? .delete : .update
        let now = Date()
        try run("INSERT INTO history(time, relation_id, record_id, action, before, after, note) VALUES (?, ?, ?, ?, ?, ?, ?)",
                [.real(now.timeIntervalSince1970), .int(relationID), .int(Int(recordID)), .text(action.rawValue),
                 Self.json(before), Self.json(record), .text(note)])
        return HistoryEntry(id: Int(sqlite3_last_insert_rowid(db)), date: now, relationID: relationID, recordID: recordID,
                            action: action, before: before, after: record, note: note)
    }

    func isEdited(_ recordID: UInt32, relationID: Int) throws -> Bool {
        var e = false
        try query("SELECT edited FROM records WHERE relation_id = ? AND record_id = ?", [.int(relationID), .int(Int(recordID))]) { s in
            e = sqlite3_column_int(s, 0) != 0
        }
        return e
    }

    public func editedRecordIDs(ofRelation relationID: Int) throws -> Set<UInt32> {
        var ids = Set<UInt32>()
        try query("SELECT record_id FROM records WHERE relation_id = ? AND edited = 1", [.int(relationID)]) { s in
            ids.insert(UInt32(sqlite3_column_int64(s, 0)))
        }
        return ids
    }

    // MARK: Updating from a newer Helix file

    public struct MergeReport {
        public var added = 0, updated = 0, deleted = 0, unchanged = 0
        /// Records changed both in Faulix and in Helix: the Faulix version was kept.
        public var conflicts: [(relation: String, recordID: UInt32)] = []
        public var newFields: [String] = []
    }

    /// The Helix version a record had when it was last brought in (for three-way comparison).
    func helixBase(relationID: Int) throws -> [UInt32: Record] {
        var out: [UInt32: Record] = [:]
        try query("SELECT record_id, json FROM helix_base WHERE relation_id = ?", [.int(relationID)]) { s in
            let id = UInt32(sqlite3_column_int64(s, 0))
            if let j = sqlite3_column_text(s, 1).map({ String(cString: $0) }), let r = Self.record(json: j, id: id) { out[id] = r }
        }
        return out
    }

    /// Brings in records from a newer copy of the same Helix collection. Records not edited in
    /// Faulix take the Helix version; records edited in Faulix are kept (and reported if Helix
    /// changed them too). New fields are added to the design.
    public func merge(from newer: HelixCollection, original: HelixCollection, design: inout DesignModel) throws -> MergeReport {
        var report = MergeReport()
        try transaction {
            for newRel in newer.relations {
                guard let r = design.relations.firstIndex(where: { $0.id == newRel.id })
                        ?? design.relations.firstIndex(where: { $0.name == newRel.name }) else { continue }
                let relID = design.relations[r].id
                // New fields (by Helix object id).
                for f in newRel.fields where !design.relations[r].fields.contains(where: { $0.id == f.id || $0.fieldID == f.fieldID }) {
                    design.relations[r].fields.append(f)
                    let p = newRel.icons.first { $0.objectID == f.id } ?? IconPlacement(objectID: f.id, v: 0, h: 0)
                    design.relations[r].icons.append(p)
                    report.newFields.append(f.name)
                }
                var base = try helixBase(relationID: relID)
                if base.isEmpty, let oldRel = original.relations.first(where: { $0.id == newRel.id }) {
                    for rec in try original.records(of: oldRel) { base[rec.id] = rec }
                }
                let edited = try editedRecordIDs(ofRelation: relID)
                let incoming = try newer.records(of: newRel)
                let incomingIDs = Set(incoming.map(\.id))
                let note = "Updated from Helix file"
                for n in incoming {
                    let cur = try record(n.id, relationID: relID)
                    let b = base[n.id]
                    if cur == nil {
                        if (try? metaValue("deleted-\(relID)-\(n.id)")) == "1", b?.values == n.values { continue }
                        _ = try putInTransaction(n, recordID: n.id, relationID: relID, note: note, userEdit: false)
                        report.added += 1
                    } else if cur!.values == n.values {
                        report.unchanged += 1
                    } else if !edited.contains(n.id) {
                        _ = try putInTransaction(n, recordID: n.id, relationID: relID, note: note, userEdit: false)
                        report.updated += 1
                    } else if b?.values != n.values {
                        report.conflicts.append((design.relations[r].name, n.id))
                    }
                }
                for (id, _) in base where !incomingIDs.contains(id) {
                    guard try record(id, relationID: relID) != nil else { continue }
                    if edited.contains(id) {
                        report.conflicts.append((design.relations[r].name, id))
                    } else {
                        _ = try putInTransaction(nil, recordID: id, relationID: relID, note: note, userEdit: false)
                        report.deleted += 1
                    }
                }
                try run("DELETE FROM helix_base WHERE relation_id = ?", [.int(relID)])
                for n in incoming {
                    try run("INSERT INTO helix_base VALUES (?, ?, ?)", [.int(relID), .int(Int(n.id)), Self.json(n)])
                }
            }
            let data = try JSONEncoder().encode(design)
            try run("INSERT OR REPLACE INTO meta VALUES ('design', ?)", [.text(String(decoding: data, as: UTF8.self))])
        }
        return report
    }

    /// Most recent changes first.
    public func history(relationID: Int? = nil, limit: Int = 500) throws -> [HistoryEntry] {
        var out: [HistoryEntry] = []
        let sql = "SELECT seq, time, relation_id, record_id, action, before, after, note FROM history"
            + (relationID == nil ? "" : " WHERE relation_id = ?") + " ORDER BY seq DESC LIMIT ?"
        try query(sql, (relationID.map { [Param.int($0)] } ?? []) + [.int(limit)]) { s in
            func text(_ i: Int32) -> String? { sqlite3_column_text(s, i).map { String(cString: $0) } }
            let rid = UInt32(sqlite3_column_int64(s, 3))
            out.append(HistoryEntry(
                id: Int(sqlite3_column_int64(s, 0)), date: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)),
                relationID: Int(sqlite3_column_int64(s, 2)), recordID: rid,
                action: HistoryEntry.Action(rawValue: text(4) ?? "") ?? .update,
                before: text(5).flatMap { Self.record(json: $0, id: rid) }, after: text(6).flatMap { Self.record(json: $0, id: rid) },
                note: text(7) ?? ""))
        }
        return out
    }

    private static func json(_ r: Record?) -> Param {
        guard let r, let data = try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: r.values.map { (String($0.key), $0.value) }))
        else { return .null }
        return .text(String(decoding: data, as: UTF8.self))
    }

    private static func record(json: String, id: UInt32) -> Record? {
        guard let dict = try? JSONDecoder().decode([String: Value].self, from: Data(json.utf8)) else { return nil }
        return Record(id: id, values: Dictionary(uniqueKeysWithValues: dict.compactMap { k, v in UInt16(k).map { ($0, v) } }))
    }

    // MARK: Design

    /// The editable design (see `DesignModel`), or nil if not imported yet.
    public func loadDesign() -> DesignModel? {
        guard let json = try? metaValue("design") else { return nil }
        return try? JSONDecoder().decode(DesignModel.self, from: Data(json.utf8))
    }

    public func saveDesign(_ model: DesignModel) throws {
        let data = try JSONEncoder().encode(model)
        try run("INSERT OR REPLACE INTO meta VALUES ('design', ?)", [.text(String(decoding: data, as: UTF8.self))])
    }

    /// Saves the design and records a line in the history log.
    public func saveDesign(_ model: DesignModel, note: String) throws {
        try transaction {
            try saveDesign(model)
            try run("INSERT INTO history(time, relation_id, record_id, action, before, after, note) VALUES (?, ?, 0, 'design', NULL, NULL, ?)",
                    [.real(Date().timeIntervalSince1970), .int(-1), .text(note)])
        }
    }

    /// Writes a consistent standalone copy of the database (for backup or use in other tools).
    public func backup(to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try run("VACUUM INTO ?", [.text(destination.path)])
    }

    public func nextRecordID(relationID: Int) throws -> UInt32 {
        var next: UInt32 = 1
        try query("SELECT COALESCE(MAX(record_id), 0) + 1 FROM records WHERE relation_id = ?", [.int(relationID)]) { s in
            next = UInt32(sqlite3_column_int64(s, 0))
        }
        return next
    }

    // MARK: Values

    private func insert(_ r: Record, relationID: Int, modified: Bool) throws {
        try run("INSERT INTO records(relation_id, record_id, modified) VALUES (?, ?, ?)", [.int(relationID), .int(Int(r.id)), .int(modified ? 1 : 0)])
        for (fid, v) in r.values {
            var p: [Param] = [.int(relationID), .int(Int(r.id)), .int(Int(fid))]
            switch v {
            case .text(let s): p += [.text("t"), .text(s), .null, .null, .null, .null]
            case .number(let n): p += [.text("n"), .null, .real(n), .null, .null, .null]
            case .date(let d): p += [.text("d"), .null, .null, .int(d.julianDay), .int(d.seconds), .null]
            case .flag(let b): p += [.text("f"), .null, .null, .int(b ? 1 : 0), .null, .null]
            case .picture(let data): p += [.text("p"), .null, .null, .null, .null, .blob(data)]
            case .raw(let data): p += [.text("r"), .null, .null, .null, .null, .blob(data)]
            }
            try run("INSERT INTO field_values VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", p)
        }
    }

    private static func value(_ s: OpaquePointer) -> Value? {
        func text(_ i: Int32) -> String { sqlite3_column_text(s, i).map { String(cString: $0) } ?? "" }
        func blob(_ i: Int32) -> Data {
            guard let p = sqlite3_column_blob(s, i) else { return Data() }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(s, i)))
        }
        switch text(2) {
        case "t": return .text(text(3))
        case "n": return .number(sqlite3_column_double(s, 4))
        case "d": return .date(HelixDate(julianDay: Int(sqlite3_column_int64(s, 5)), seconds: Int(sqlite3_column_int64(s, 6))))
        case "f": return .flag(sqlite3_column_int(s, 5) != 0)
        case "p": return .picture(blob(7))
        case "r": return .raw(blob(7))
        default: return nil
        }
    }

    // MARK: SQLite plumbing

    enum Param { case int(Int), real(Double), text(String), blob(Data), null }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func storeError(_ context: String) -> HelixFormatError {
        HelixFormatError("\(context): \(String(cString: sqlite3_errmsg(db)))")
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw storeError("SQL failed") }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private var statements: [String: OpaquePointer] = [:]

    private func prepare(_ sql: String, _ params: [Param]) throws -> OpaquePointer {
        let s: OpaquePointer
        if let cached = statements[sql] {
            s = cached
            sqlite3_reset(s)
            sqlite3_clear_bindings(s)
        } else {
            var p: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &p, nil) == SQLITE_OK, let p else { throw storeError("Prepare failed") }
            statements[sql] = p
            s = p
        }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .int(let v): sqlite3_bind_int64(s, idx, Int64(v))
            case .real(let v): sqlite3_bind_double(s, idx, v)
            case .text(let v): sqlite3_bind_text(s, idx, v, -1, Self.transient)
            case .blob(let v): _ = v.withUnsafeBytes { sqlite3_bind_blob(s, idx, $0.baseAddress, Int32(v.count), Self.transient) }
            case .null: sqlite3_bind_null(s, idx)
            }
        }
        return s
    }

    private func run(_ sql: String, _ params: [Param]) throws {
        let s = try prepare(sql, params)
        guard sqlite3_step(s) == SQLITE_DONE else { throw storeError("Step failed") }
    }

    private func query(_ sql: String, _ params: [Param], row: (OpaquePointer) -> Void) throws {
        let s = try prepare(sql, params)
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw storeError("Query failed") }
            row(s)
        }
    }

    private func metaValue(_ key: String) throws -> String? {
        var v: String?
        try query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { s in
            v = sqlite3_column_text(s, 0).map { String(cString: $0) }
        }
        return v
    }
}
