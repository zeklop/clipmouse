import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Хранилище истории (§4): actor поверх sqlite3, FULLMUTEX, WAL.
/// Вставка — только upsert, иначе повтор того же текста роняет на UNIQUE.
public actor ClipStore {

    enum StoreError: Error, CustomStringConvertible {
        case cannotOpen(String)
        case sql(String)

        var description: String {
            switch self {
            case .cannotOpen(let msg): "не открывается БД: \(msg)"
            case .sql(let msg): "SQL: \(msg)"
            }
        }
    }

    private var db: OpaquePointer?
    public private(set) var recoveredFromCorruption = false
    private let path: String

    // MARK: - Жизненный цикл

    init(path: String) throws {
        self.path = path
        // Открытие и миграции — в статике с явным хендлом: init актора
        // не может звать изолированные методы
        var handle: OpaquePointer?
        do {
            handle = try Self.openRaw(path)
            try Self.migrate(handle)
        } catch {
            if handle != nil { sqlite3_close(handle) }
            Self.moveAsideCorrupt(path)
            recoveredFromCorruption = true
            Log.store.fault("БД повреждена (\(error)), начата новая: \(path, privacy: .public)")
            handle = try Self.openRaw(path)
            try Self.migrate(handle)
        }
        db = handle
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        // -wal/-shm несут свежие записи до чекпойнта и создаются SQLite
        // с umask: закрываем права на уже существующие (новые накрывает
        // umask(0o077) в main.swift) — ревью публикации 2026-08-16
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: path + suffix)
        }
    }

    /// Стандартное расположение (§2): ~/Library/Application Support/ClipMouse/
    /// каталог 0700, файл 0600, флаг NSURLIsExcludedFromBackupKey.
    public static func defaultDatabasePath() -> String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("ClipMouse/clipmouse.sqlite").path
    }

    public static func openDefault() throws -> ClipStore {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: defaultDatabasePath()).deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? (dir as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
        return try ClipStore(path: defaultDatabasePath())
    }

    deinit {
        // OpaquePointer не Sendable — из deinit БД не закрыть (Swift 6).
        // Явное закрытие делает close() на applicationWillTerminate;
        // при крашже WAL восстанавливается sqlite при следующем открытии
    }

    /// Явное закрытие соединения на выходе приложения.
    public func close() {
        if db != nil {
            sqlite3_close_v2(db)
            db = nil
        }
    }

    // MARK: - Статические SQL-примитивы (используются и из init)

    private static func openRaw(_ path: String) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "?"
            sqlite3_close(handle)
            throw StoreError.cannotOpen(msg)
        }
        try exec(handle, "PRAGMA journal_mode=WAL;")
        try exec(handle, "PRAGMA foreign_keys=ON;")
        // Сниппеты живут вторым соединением к этому же файлу:
        // без таймаута конкурентная запись сразу падает SQLITE_BUSY
        try exec(handle, "PRAGMA busy_timeout=2000;")
        return handle
    }

    private static func migrate(_ db: OpaquePointer?) throws {
        let v = try userVersion(db)
        guard v < 1 else { return }
        try exec(db, """
        CREATE TABLE clips (
          id            INTEGER PRIMARY KEY AUTOINCREMENT,
          hash          TEXT    NOT NULL UNIQUE,
          kind          TEXT    NOT NULL,
          preview       TEXT    NOT NULL,
          text          TEXT,
          blob          BLOB,
          source_bundle TEXT,
          created_at    REAL    NOT NULL,
          last_used_at  REAL    NOT NULL,
          pinned        INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX idx_clips_recent ON clips(pinned DESC, last_used_at DESC);
        CREATE TABLE folders  (id INTEGER PRIMARY KEY, title TEXT NOT NULL, position INTEGER NOT NULL);
        CREATE TABLE snippets (id INTEGER PRIMARY KEY, folder_id INTEGER NOT NULL,
                               title TEXT NOT NULL, content TEXT NOT NULL, position INTEGER NOT NULL);
        """)
        try exec(db, "PRAGMA user_version=1;")
    }

    private static func userVersion(_ db: OpaquePointer?) throws -> Int {
        let stmt = try prepare(db, "PRAGMA user_version;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw StoreError.sql("user_version") }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Ошибка открытия/миграции → переименовать в .corrupt-<ts>,
    /// создать новую, не падать (§9 Фаза 1).
    private static func moveAsideCorrupt(_ path: String) {
        let fm = FileManager.default
        let ts = Int(Date().timeIntervalSince1970)
        for suffix in ["", "-wal", "-shm"] {
            let from = path + suffix
            guard fm.fileExists(atPath: from) else { continue }
            try? fm.moveItem(atPath: from, toPath: "\(path).corrupt-\(ts)\(suffix)")
        }
    }

    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "неизвестная ошибка"
            sqlite3_free(err)
            throw StoreError.sql(msg)
        }
    }

    private static func prepare(_ db: OpaquePointer?, _ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    // MARK: - Изолированные обёртки

    private func exec(_ sql: String) throws {
        try Self.exec(db, sql)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        try Self.prepare(db, sql)
    }

    // MARK: - Биндинги

    private func bind(_ stmt: OpaquePointer, _ idx: Int32, _ text: String?) {
        if let text {
            sqlite3_bind_text(stmt, idx, text, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func bindBlob(_ stmt: OpaquePointer, _ idx: Int32, _ data: Data?) {
        if let data, !data.isEmpty {
            data.withUnsafeBytes { buf in
                _ = sqlite3_bind_blob(stmt, idx, buf.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func bindDate(_ stmt: OpaquePointer, _ idx: Int32, _ date: Date) {
        sqlite3_bind_double(stmt, idx, date.timeIntervalSince1970)
    }

    // MARK: - Операции

    /// Upsert (§4) + enforceRetention после каждой вставки.
    func upsert(_ clip: Clip, limit: Int, expireDays: Int) throws {
        let stmt = try prepare("""
        INSERT INTO clips (hash,kind,preview,text,blob,source_bundle,created_at,last_used_at)
        VALUES (?,?,?,?,?,?,?,?)
        ON CONFLICT(hash) DO UPDATE SET last_used_at = excluded.last_used_at;
        """)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, clip.hash)
        bind(stmt, 2, clip.kind.rawValue)
        bind(stmt, 3, clip.preview)
        bind(stmt, 4, clip.text)
        bindBlob(stmt, 5, clip.blob)
        bind(stmt, 6, clip.sourceBundle)
        bindDate(stmt, 7, clip.createdAt)
        bindDate(stmt, 8, clip.lastUsedAt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        try enforceRetention(limit: limit, expireDays: expireDays)
    }

    /// Ретеншен по числу и по времени, что раньше (§8.3). pinned не трогает.
    func enforceRetention(limit: Int, expireDays: Int) throws {
        let stmt = try prepare("""
        DELETE FROM clips WHERE pinned = 0 AND (
          id NOT IN (SELECT id FROM clips WHERE pinned = 0 ORDER BY last_used_at DESC LIMIT ?1)
          OR last_used_at < ?2
        );
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(max(limit, 1)))
        sqlite3_bind_double(stmt, 2, Date().addingTimeInterval(-Double(expireDays) * 86_400).timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
    }

    func recent(limit: Int) throws -> [Clip] {
        let stmt = try prepare("""
        SELECT id,kind,preview,text,blob,source_bundle,created_at,last_used_at,pinned
        FROM clips ORDER BY pinned DESC, last_used_at DESC LIMIT ?1;
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(max(limit, 0)))
        var out: [Clip] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(rowToClip(stmt))
        }
        return out
    }

    func count() throws -> Int {
        let stmt = try prepare("SELECT count(*) FROM clips;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw StoreError.sql("count") }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    func delete(id: Int64) throws {
        let stmt = try prepare("DELETE FROM clips WHERE id = ?1;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        _ = sqlite3_step(stmt)
    }

    @discardableResult
    func clearAll() throws -> Int {
        let n = try count()
        try exec("DELETE FROM clips;")
        return n
    }

    func markUsed(id: Int64) throws {
        let stmt = try prepare("UPDATE clips SET last_used_at = ?1 WHERE id = ?2;")
        defer { sqlite3_finalize(stmt) }
        bindDate(stmt, 1, Date())
        sqlite3_bind_int64(stmt, 2, id)
        _ = sqlite3_step(stmt)
    }

    func pin(id: Int64, pinned: Bool) throws {
        let stmt = try prepare("UPDATE clips SET pinned = ?1 WHERE id = ?2;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, pinned ? 1 : 0)
        sqlite3_bind_int64(stmt, 2, id)
        _ = sqlite3_step(stmt)
    }

    private func rowToClip(_ stmt: OpaquePointer) -> Clip {
        func text(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        var blob: Data?
        if let p = sqlite3_column_blob(stmt, 4), sqlite3_column_bytes(stmt, 4) > 0 {
            blob = Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, 4)))
        }
        guard let kindRaw = text(1),
              let kind = Clip.Kind(rawValue: kindRaw),
              let preview = text(2) else {
            return Clip(kind: .string, hash: "", preview: "?", text: nil, blob: nil,
                        sourceBundle: nil, createdAt: .distantPast, lastUsedAt: .distantPast)
        }
        return Clip(id: sqlite3_column_int64(stmt, 0), kind: kind, hash: "", preview: preview,
                    text: text(3), blob: blob, sourceBundle: text(5),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
                    lastUsedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)),
                    pinned: sqlite3_column_int64(stmt, 8) != 0)
    }
}
