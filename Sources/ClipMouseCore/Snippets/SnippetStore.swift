import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Сниппеты (§9 Фаза 2): те же таблицы folders/snippets в общей БД,
/// своё соединение (WAL это разрешает).
/// Пять сниппетов из папки «ВСТАВКА» заносятся первичным посевом —
/// парсер CoreData XML не пишется (план Фазы 2).
public actor SnippetStore {

    public struct Folder: Identifiable, Sendable, Equatable {
        public let id: Int64
        public let title: String
    }

    public struct Snippet: Identifiable, Sendable, Equatable {
        public let id: Int64
        public let folderID: Int64
        public let title: String
        public let content: String
    }

    private var db: OpaquePointer?

    public init(path: String) throws {
        // открытие — в статике: init актора не зовёт изолированные методы
        let handle = try Self.openRaw(path)
        try Self.exec(handle, "PRAGMA journal_mode=WAL;")
        try Self.exec(handle, "PRAGMA foreign_keys=ON;")
        // Второе соединение к тому же файлу: без таймаута конкурентная
        // запись падает SQLITE_BUSY сразу, а не ждёт писателя
        try Self.exec(handle, "PRAGMA busy_timeout=2000;")
        db = handle
    }

    public func close() {
        if db != nil {
            sqlite3_close_v2(db)
            db = nil
        }
    }

    // MARK: - Первичный посев

    /// Демо-сниппеты: один раз в пустую БД. Личные значения автора
    /// (телефон, t.me) убраны перед публикацией — чужим установкам
    /// они не нужны (ревью публикации 2026-08-16).
    public func seedInitialIfEmpty() throws {
        guard try folders().isEmpty else { return }
        try Self.exec(db, """
        INSERT INTO folders (id, title, position) VALUES (1, 'Examples', 0);
        INSERT INTO snippets (folder_id, title, content, position) VALUES
          (1, 'Time',          '{date:HH:mm}', 0),
          (1, 'UUID',          '{uuid}',        1),
          (1, 'From clipboard','{clipboard}',   2),
          (1, 'Thanks!',       'Thanks!',       3),
          (1, 'ClipMouse',     'ClipMouse — clipboard, snippets & keep-awake', 4);
        """)
        Log.store.info("выполнен первичный посев сниппетов (5 шт., папка Examples)")
    }

    // MARK: - Чтение

    public func folders() throws -> [Folder] {
        let stmt = try Self.prepare(db, "SELECT id, title FROM folders ORDER BY position;")
        defer { sqlite3_finalize(stmt) }
        var out: [Folder] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Folder(id: sqlite3_column_int64(stmt, 0),
                              title: String(cString: sqlite3_column_text(stmt, 1))))
        }
        return out
    }

    public func snippets(folderID: Int64) throws -> [Snippet] {
        let stmt = try Self.prepare(db, """
        SELECT id, folder_id, title, content FROM snippets
        WHERE folder_id = ?1 ORDER BY position;
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, folderID)
        var out: [Snippet] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Snippet(id: sqlite3_column_int64(stmt, 0),
                               folderID: sqlite3_column_int64(stmt, 1),
                               title: String(cString: sqlite3_column_text(stmt, 2)),
                               content: String(cString: sqlite3_column_text(stmt, 3))))
        }
        return out
    }

    // MARK: - Управление (ревизия 8: меню категорий и сниппетов)

    public func insertCategory(title: String) throws -> Int64 {
        let stmt = try Self.prepare(db, "INSERT INTO folders (title, position) VALUES (?1, (SELECT COALESCE(MAX(position), -1) + 1 FROM folders));")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, title, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ClipStore.StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_last_insert_rowid(db)
    }

    /// Переименование категории (ревизия 18: инлайн в таблице).
    public func updateCategory(id: Int64, title: String) throws {
        let stmt = try Self.prepare(db, "UPDATE folders SET title = ?1 WHERE id = ?2;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, id)
        _ = sqlite3_step(stmt)
    }

    /// Удаляет категорию вместе со сниппетами.
    public func deleteCategory(id: Int64) throws {
        let s1 = try Self.prepare(db, "DELETE FROM snippets WHERE folder_id = ?1;")
        defer { sqlite3_finalize(s1) }
        sqlite3_bind_int64(s1, 1, id)
        _ = sqlite3_step(s1)
        let s2 = try Self.prepare(db, "DELETE FROM folders WHERE id = ?1;")
        defer { sqlite3_finalize(s2) }
        sqlite3_bind_int64(s2, 1, id)
        _ = sqlite3_step(s2)
    }

    @discardableResult
    public func insertSnippet(folderID: Int64, title: String, content: String) throws -> Int64 {
        let stmt = try Self.prepare(db, """
        INSERT INTO snippets (folder_id, title, content, position)
        VALUES (?1, ?2, ?3, (SELECT COALESCE(MAX(position), -1) + 1 FROM snippets WHERE folder_id = ?1));
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, folderID)
        sqlite3_bind_text(stmt, 2, title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, content, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ClipStore.StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_last_insert_rowid(db)
    }

    public func updateSnippet(id: Int64, title: String, content: String) throws {
        let stmt = try Self.prepare(db, "UPDATE snippets SET title = ?1, content = ?2 WHERE id = ?3;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, content, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 3, id)
        _ = sqlite3_step(stmt)
    }

    public func deleteSnippet(id: Int64) throws {
        let stmt = try Self.prepare(db, "DELETE FROM snippets WHERE id = ?1;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        _ = sqlite3_step(stmt)
    }

    // MARK: - SQL-примитивы

    private static func openRaw(_ path: String) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "?"
            sqlite3_close(handle)
            throw ClipStore.StoreError.cannotOpen(msg)
        }
        return handle
    }

    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "неизвестная ошибка"
            sqlite3_free(err)
            throw ClipStore.StoreError.sql(msg)
        }
    }

    private static func prepare(_ db: OpaquePointer?, _ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ClipStore.StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }
}
