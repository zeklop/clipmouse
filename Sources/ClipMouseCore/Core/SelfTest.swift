import Foundation
import SQLite3

/// Режим --selftest: чистые функции и миграции на временной БД.
/// XCTest и swift-testing в среде CLT недоступны (замерено, §1),
/// поэтому тесты живут внутри исполняемого файла.
public enum SelfTest {

    /// Запускает все тесты. Возвращает код выхода: 0 — успех, 1 — провал.
    @discardableResult
    public static func run() async -> Int32 {
        var failures: [String] = []

        func expect(_ name: String, _ condition: Bool) {
            if condition {
                print("ok   \(name)")
            } else {
                failures.append(name)
                print("FAIL \(name)")
            }
        }

        func tempDir() -> String {
            let d = FileManager.default.temporaryDirectory
                .appendingPathComponent("clipmouse-selftest-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            return d.path
        }

        func makeClip(_ s: String, at date: Date = Date()) -> Clip {
            Clip(kind: .string, hash: ClipboardIO.sha256Hex(Data(s.utf8)),
                 preview: ClipboardIO.normalizedPreview(s), text: s, blob: nil,
                 sourceBundle: "test.app", createdAt: date, lastUsedAt: date)
        }

        // MARK: Превью
        expect("превью: схлопывает \\n, \\t и пробелы",
               ClipboardIO.normalizedPreview("a \n\t b   c") == "a b c")
        expect("превью: потолок 200 символов",
               ClipboardIO.normalizedPreview(String(repeating: "x", count: 500)).count <= 201)

        // MARK: Превью богатых типов (ревизия 12)
        expect("превью rtf: текст вместо ярлыка",
               ClipboardIO.richPreview(kind: .rtf, text: "a \n b", blob: Data(count: 10)) == "a b")
        expect("превью rtf: без текста — байтовый ярлык",
               ClipboardIO.richPreview(kind: .rtf, text: nil, blob: Data(count: 10)).hasPrefix("RTF ·"))
        expect("превью rtfd: пустой текст — байтовый ярлык",
               ClipboardIO.richPreview(kind: .rtfd, text: "", blob: Data(count: 3)).hasPrefix("RTFD ·"))

        // MARK: Эвристики секретов (§12)
        expect("секрет: путь — НЕ секрет", SecretHeuristics.check("/Users/example/dev/clipmenu") == nil)
        expect("секрет: hex-40 — НЕ секрет", SecretHeuristics.check(String(repeating: "ab", count: 20)) == nil)
        expect("секрет: ghp_-префикс", SecretHeuristics.check("ghp_16C7e42F291cZv5xE3D4F8b742a4cD9") != nil)
        expect("секрет: AKIA-префикс", SecretHeuristics.check("AKIAIOSFODNN7EXAMPLE") != nil)
        expect("секрет: Луна 16 цифр", SecretHeuristics.check("4111111111111111") != nil)
        expect("секрет: Луна с ошибкой — мимо", SecretHeuristics.check("4111111111111112") == nil)
        expect("секрет: PEM", SecretHeuristics.check("-----BEGIN PRIVATE KEY-----") != nil)
        expect("секрет: обычная фраза — НЕ секрет", SecretHeuristics.check("correct horse battery staple") == nil)
        expect("секрет: энтропия+3 класса", SecretHeuristics.check("Zx9$vkQ2pLm4A") != nil)

        // MARK: Плейсхолдеры сниппетов (Фаза 2)
        expect("плейсхолдеры: clipboard",
               Placeholders.expand("x{clipboard}y", clipboardText: "Z") == "xZy")
        expect("плейсхолдеры: clipboard nil",
               Placeholders.expand("{clipboard}", clipboardText: nil) == "")
        let uuid = Placeholders.expand("{uuid}", clipboardText: nil)
        expect("плейсхолдеры: uuid",
               uuid.count == 36 && uuid.filter { $0 != "-" }.count == 32
                   && uuid.filter { $0 != "-" }.allSatisfy(\.isHexDigit))
        let dated = Placeholders.expand("{date:HH}", clipboardText: nil)
        expect("плейсхолдеры: date HH",
               dated.range(of: "^[0-9]{2}$", options: .regularExpression) != nil)
        expect("плейсхолдеры: без плейсхолдеров",
               Placeholders.expand("plain text", clipboardText: "Q") == "plain text")

        // MARK: ClipStore на временной БД
        do {
            let dir = tempDir()
            let store = try ClipStore(path: dir + "/t.sqlite")

            try await store.upsert(makeClip("первый"), limit: 200, expireDays: 30)
            try await store.upsert(makeClip("второй"), limit: 200, expireDays: 30)
            try await store.upsert(makeClip("первый"), limit: 200, expireDays: 30) // дубль по hash
            expect("upsert: дубль по hash не растит счётчик", (try await store.count()) == 2)

            var clips = try await store.recent(limit: 10)
            expect("recent: порядок по last_used_at", clips.first?.text == "первый")

            let id = clips[1].id
            try await store.markUsed(id: id)
            clips = try await store.recent(limit: 10)
            expect("markUsed: поднимает наверх", clips.first?.id == id)

            // ретеншен по числу
            try await store.upsert(makeClip("третий"), limit: 2, expireDays: 30)
            expect("ретеншен: limit=2 оставляет 2", (try await store.count()) == 2)
            let afterLimit = try await store.recent(limit: 10)
            // после markUsed наверху «второй», поэтому выкинут «первый»
            expect("ретеншен: выкинут самый невостребованный",
                   !afterLimit.contains { $0.text == "первый" })

            // ретеншен по времени
            let old = makeClip("древний", at: Date().addingTimeInterval(-90 * 86_400))
            try await store.upsert(old, limit: 200, expireDays: 30)
            let afterExpire = try await store.recent(limit: 10)
            expect("ретеншен: expireDays=30 выкидывает 90-дневный",
                   !afterExpire.contains { $0.text == "древний" })

            // pinned переживает ретеншен: вставляем «свежий по сроку», закрепляем,
            // затем ужесточаем ретеншен — pinned остаётся
            let pinnedClip = makeClip("важный", at: Date().addingTimeInterval(-2 * 86_400))
            try await store.upsert(pinnedClip, limit: 200, expireDays: 30)
            if let row = (try await store.recent(limit: 10)).first(where: { $0.text == "важный" }) {
                try await store.pin(id: row.id, pinned: true)
            }
            try await store.enforceRetention(limit: 200, expireDays: 1)
            let afterPinned = try await store.recent(limit: 10)
            expect("ретеншен: pinned не трогается", afterPinned.contains { $0.text == "важный" })

            expect("clearAll: возвращает число удалённых", (try await store.clearAll()) >= 3)

            // MARK: миграция v2 (ревизия 12): лечение превью rtf
            let migPath = dir + "/mig.sqlite"
            var mig: OpaquePointer?
            sqlite3_open(migPath, &mig)
            sqlite3_exec(mig, """
            CREATE TABLE clips (id INTEGER PRIMARY KEY AUTOINCREMENT, hash TEXT NOT NULL UNIQUE,
              kind TEXT NOT NULL, preview TEXT NOT NULL, text TEXT, blob BLOB, source_bundle TEXT,
              created_at REAL NOT NULL, last_used_at REAL NOT NULL, pinned INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE folders (id INTEGER PRIMARY KEY, title TEXT NOT NULL, position INTEGER NOT NULL);
            CREATE TABLE snippets (id INTEGER PRIMARY KEY, folder_id INTEGER NOT NULL,
              title TEXT NOT NULL, content TEXT NOT NULL, position INTEGER NOT NULL);
            INSERT INTO clips (hash,kind,preview,text,created_at,last_used_at)
              VALUES ('h1','rtf','RTF · 360 bytes','залеченный текст',1,1);
            PRAGMA user_version=1;
            """, nil, nil, nil)
            sqlite3_close(mig)
            let migStore = try ClipStore(path: migPath)
            let healed = try await migStore.recent(limit: 1)
            expect("миграция: rtf-превью заменено текстом", healed.first?.preview == "залеченный текст")

            // MARK: восстановление после повреждения
            let corruptPath = dir + "/corrupt.sqlite"
            FileManager.default.createFile(atPath: corruptPath, contents: Data("это не sqlite".utf8))
            let recovered = try ClipStore(path: corruptPath)
            expect("повреждение: флаг восстановления", await recovered.recoveredFromCorruption)
            expect("повреждение: новая БД пустая", (try await recovered.count()) == 0)
            let dirContents = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            expect("повреждение: старый файл лежит рядом как .corrupt-*",
                   dirContents.contains { $0.hasPrefix("corrupt.sqlite.corrupt-") })

            // MARK: SnippetStore: CRUD на той же БД (ревизия 8)
            let snippets = try SnippetStore(path: dir + "/t.sqlite")
            let folderID = try await snippets.insertCategory(title: "Новая категория")
            try await snippets.insertSnippet(folderID: folderID, title: "t1", content: "c1")
            try await snippets.insertSnippet(folderID: folderID, title: "t2", content: "{date:HH}")
            let loaded = try await snippets.snippets(folderID: folderID)
            expect("сниппеты: вставка двух", loaded.count == 2 && loaded[1].content == "{date:HH}")
            try await snippets.updateSnippet(id: loaded[0].id, title: "t1b", content: "c1b")
            let afterUpdate = try await snippets.snippets(folderID: folderID)
            expect("сниппеты: правка", afterUpdate.first { $0.id == loaded[0].id }?.title == "t1b")
            try await snippets.deleteSnippet(id: loaded[1].id)
            expect("сниппеты: удаление одного", (try await snippets.snippets(folderID: folderID)).count == 1)
            try await snippets.deleteCategory(id: folderID)
            let afterCategoryDelete = try await snippets.snippets(folderID: folderID)
            let remainingFolders = try await snippets.folders()
            expect("сниппеты: категория удалена вместе с содержимым",
                   afterCategoryDelete.isEmpty && remainingFolders.allSatisfy { $0.id != folderID })
            // Посев не должен выполняться повторно поверх существующих
            try await snippets.seedInitialIfEmpty()
            expect("сниппеты: посев не затирает существующее",
                   (try await snippets.folders()).count == 1)
        } catch {
            failures.append("ClipStore: неожиданное исключение \(error)")
            print("FAIL ClipStore: \(error)")
        }

        if failures.isEmpty {
            print("SELFTEST OK")
            return 0
        }
        print("SELFTEST FAILED (\(failures.count)): \(failures.joined(separator: ", "))")
        return 1
    }
}
