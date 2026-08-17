import AppKit

/// Сборка NSMenu (§8.2). Строки локализованы через String(localized:) / Localizable.strings.
/// Меню строится заново на каждый показ из кеша, который обновляет
/// StatusItemController по .clipsDidChange.
@MainActor
public final class MenuBuilder: NSObject {

    private let store: ClipStore
    private let monitor: ClipboardMonitor
    private let snippetsStore: SnippetStore
    private let prefs: Prefs
    /// Тоггл ремапа из настроек — проброс наверх, в main (ревью публикации)
    var onMouseToggle: ((Bool) -> Void)?
    private lazy var settings = {
        let s = SettingsWindowController(store: store, prefs: prefs)
        s.onMouseToggle = { [weak self] on in self?.onMouseToggle?(on) }
        return s
    }()

    public var recentClips: [Clip] = []
    public var snippetsByFolder: [(folder: SnippetStore.Folder, items: [SnippetStore.Snippet])] = []
    public var secretNotice: (clip: Clip, at: Date)?
    public var hotkeyError = false
    public weak var awake: AwakeController?
    /// Куда вставлять из меню — фронтом до клика по иконке (§8.4)
    public var pasteTarget: NSRunningApplication?
    /// Статус ремапа: nil — работает, иначе строка в меню (§9 Фаза 4)
    public var mouseStatus: MouseStatus?

    public enum MouseStatus {
        case karabiner   // "Karabiner is running"
        case noAccess    // "Remap off: no accessibility access" + deep-link
    }

    init(store: ClipStore, monitor: ClipboardMonitor, snippetsStore: SnippetStore, prefs: Prefs) {
        self.store = store
        self.monitor = monitor
        self.snippetsStore = snippetsStore
        self.prefs = prefs
        super.init()
    }

    public func build() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = 280
        fillHistory(in: menu)
        menu.addItem(.separator())
        addAwakeSection(to: menu)
        addSnippetsSection(to: menu)
        menu.addItem(.separator())
        addFixedBottom(to: menu)
        return menu
    }

    /// Меню только со сниппетами — для хоткея ⌘⇧B.
    public func buildSnippetsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = 240
        addSnippetsSection(to: menu)
        return menu
    }

    // MARK: - Секции

    private func fillHistory(in menu: NSMenu) {
        // Первым пунктом 120 с висит предупреждение о секрете (§12)
        if let notice = secretNotice,
           Date().timeIntervalSince(notice.at) <= 120 {
            let item = NSMenuItem(
                title: String(localized: "Not saved: looks like a secret (⌥ — save anyway)"),
                action: #selector(secretNoticeAction), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }

        let inline = recentClips.prefix(max(prefs.menuInlineCount, 0))
        if inline.isEmpty {
            let empty = NSMenuItem(title: String(localized: "History is empty"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for clip in inline {
                menu.addItem(historyItem(for: clip))
            }
        }
    }

    // MARK: - Awake (§9 Фаза 5, §8.2)

    /// Таймеры 5/10/15/30 мин, 1/2/5 ч, Indefinitely, Turn Off — дубль
    /// тумблера из §8.1. Обратный отсчёт — в заголовке пункта; пока меню
    /// открыто, тикает живьём (startAwakeTick).
    private func addAwakeSection(to menu: NSMenu) {
        guard let awake else { return } // Фаза 5 срезана — секции нет

        let durations: [(String, Int?)] = [
            (String(localized: "5 min"), 300), (String(localized: "10 min"), 600),
            (String(localized: "15 min"), 900), (String(localized: "30 min"), 1800),
            (String(localized: "1 hour"), 3600), (String(localized: "2 hours"), 7200),
            (String(localized: "5 hours"), 18_000),
            (String(localized: "Indefinitely"), nil),
        ]
        let suffix: String
        if awake.isActive, let rem = awake.remaining() {
            suffix = "   " + String(format: String(localized: "remaining.suffix"), rem.label)
        } else if awake.isActive {
            suffix = "   ∞"
        } else {
            suffix = ""
        }

        let root = NSMenuItem(title: String(localized: "Awake ▸") + suffix, action: nil, keyEquivalent: "")
        // Активный awake подсвечивается системным оранжевым (#FF9F0A — палитра колец)
        if awake.isActive {
            root.attributedTitle = Self.awakeTitle(String(localized: "Awake ▸") + suffix)
        }
        let sub = NSMenu()
        for (title, seconds) in durations {
            let item = NSMenuItem(title: title, action: #selector(awakeDuration(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = seconds ?? -1
            sub.addItem(item)
        }
        sub.addItem(.separator())
        let off = NSMenuItem(title: String(localized: "Turn Off"), action: #selector(awakeOff), keyEquivalent: "")
        off.target = self
        off.isEnabled = awake.isActive
        sub.addItem(off)
        menu.setSubmenu(sub, for: root)
        menu.addItem(root)
        // Живой отсчёт, пока меню открыто (бессрочный режим — только подсветка)
        if awake.isActive, awake.remaining() != nil {
            startAwakeTick(root: root, menu: menu)
        }

        // два ассерта: выключение в ClipMouse не снимет чужой (§9 Фаза 5)
        if !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.marci-mh.KeepingYouAwake").isEmpty {
            let row = NSMenuItem(title: String(localized: "KeepingYouAwake is running"),
                                 action: nil, keyEquivalent: "")
            row.isEnabled = false
            menu.addItem(row)
        }
    }

    @objc private func awakeDuration(_ sender: NSMenuItem) {
        let seconds = sender.tag == -1 ? nil : sender.tag
        awake?.enable(seconds: seconds)
    }

    @objc private func awakeOff() {
        awake?.disable()
    }

    // MARK: Живой отсчёт Awake в открытом меню

    private var awakeTickTimer: DispatchSourceTimer?
    private var awakeTickObserver: NSObjectProtocol?

    /// Оранжевый моноширинно-цифровой тайтл: «10:00 → 9:59» без дёргания ширины.
    private static func awakeTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.systemOrange,
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize,
                                                     weight: .regular),
        ])
    }

    /// DispatchSourceTimer на main queue: обычный Timer замирает в tracking-режиме
    /// run loop (AGENTS.md), этот — нет. Паттерн как в AwakeController.startPolling.
    private func startAwakeTick(root: NSMenuItem, menu: NSMenu) {
        stopAwakeTick()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self, weak root] in
            MainActor.assumeIsolated { self?.awakeTick(root: root) }
        }
        t.resume()
        awakeTickTimer = t
        awakeTickObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: menu, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAwakeTick() }
        }
    }

    private func stopAwakeTick() {
        awakeTickTimer?.cancel()
        awakeTickTimer = nil
        if let awakeTickObserver {
            NotificationCenter.default.removeObserver(awakeTickObserver)
            self.awakeTickObserver = nil
        }
    }

    private func awakeTick(root: NSMenuItem?) {
        let base = String(localized: "Awake ▸")
        // Выключили извне (батарея/таймаут PM) — вернуть обычный тайтл
        guard let awake, awake.isActive else {
            root?.title = base
            stopAwakeTick()
            return
        }
        guard let rem = awake.remaining() else { return } // бессрочный — тик не должен работать
        if rem.seconds <= 0 {
            // Состояние синхронизирует AwakeController.periodicCheck
            root?.title = base
            stopAwakeTick()
            return
        }
        let suffix = "   " + String(format: String(localized: "remaining.suffix"), rem.label)
        root?.attributedTitle = Self.awakeTitle(base + suffix)
    }

    /// Секция сниппетов (ревизия 8): `Snippets ▸` — меню управления
    /// категориями и сниппетами, категории — пунктами основного уровня.
    private func addSnippetsSection(to menu: NSMenu) {
        // Управление
        let manage = NSMenuItem(title: String(localized: "Snippets ▸"), action: nil, keyEquivalent: "")
        let manageMenu = NSMenu()
        let addSnippet = NSMenuItem(title: String(localized: "Add Snippet…"),
                                    action: #selector(addSnippetDialog), keyEquivalent: "")
        addSnippet.target = self
        manageMenu.addItem(addSnippet)
        let addCategory = NSMenuItem(title: String(localized: "Add Category…"),
                                     action: #selector(addCategoryDialog), keyEquivalent: "")
        addCategory.target = self
        manageMenu.addItem(addCategory)
        if !snippetsByFolder.isEmpty {
            manageMenu.addItem(.separator())
            let delRoot = NSMenuItem(title: String(localized: "Delete Category ▸"), action: nil, keyEquivalent: "")
            let delMenu = NSMenu()
            for group in snippetsByFolder {
                let item = NSMenuItem(title: group.folder.title,
                                      action: #selector(deleteCategoryAction), keyEquivalent: "")
                item.target = self
                item.tag = Int(group.folder.id)
                item.toolTip = String(localized: "Delete the category and its snippets")
                delMenu.addItem(item)
            }
            manageMenu.setSubmenu(delMenu, for: delRoot)
            manageMenu.addItem(delRoot)
        }
        menu.setSubmenu(manageMenu, for: manage)
        menu.addItem(manage)

        // Категории на основном уровне
        for group in snippetsByFolder {
            let cat = NSMenuItem(title: group.folder.title, action: nil, keyEquivalent: "")
            let catMenu = NSMenu()
            for snippet in group.items {
                catMenu.addItem(snippetItem(snippet))
                // ⌥-альтернативы: правка и удаление конкретного сниппета
                let edit = NSMenuItem(
                    title: String(format: String(localized: "edit.snippet"), snippet.title),
                    action: #selector(editSnippetDialog), keyEquivalent: "")
                edit.target = self
                edit.tag = Int(snippet.id)
                edit.isAlternate = true
                edit.keyEquivalentModifierMask = .option
                catMenu.addItem(edit)
                let del = NSMenuItem(
                    title: String(format: String(localized: "delete.snippet"), snippet.title),
                    action: #selector(deleteSnippetAction), keyEquivalent: "")
                del.target = self
                del.tag = Int(snippet.id)
                del.isAlternate = true
                del.keyEquivalentModifierMask = [.option, .shift]
                catMenu.addItem(del)
            }
            addCategoryHint(to: catMenu)
            menu.setSubmenu(catMenu, for: cat)
            menu.addItem(cat)
        }
    }

    /// Нижняя строка подменю категории: подсказка про ⌥/⌥⇧ (ревизия 8.1).
    private func addCategoryHint(to menu: NSMenu) {
        guard !menu.items.isEmpty else { return }
        menu.addItem(.separator())
        let hint = NSMenuItem(title: String(localized: "Hold ⌥ to edit · ⌥⇧ to delete"),
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
    }

    private func snippetItem(_ snippet: SnippetStore.Snippet) -> NSMenuItem {
        let item = NSMenuItem(title: snippet.title,
                              action: #selector(selectSnippet), keyEquivalent: "")
        item.target = self
        item.tag = Int(snippet.id)
        item.toolTip = snippet.content
        return item
    }

    /// Фиксированный низ меню (§8.2). Search — без шортката.
    private func addFixedBottom(to menu: NSMenu) {
        let search = NSMenuItem(title: String(localized: "Search…"), action: #selector(openSearch), keyEquivalent: "")
        search.target = self
        menu.addItem(search)

        let settingsItem = NSMenuItem(title: String(localized: "Settings…"),
                                      action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)

        let quit = NSMenuItem(title: String(localized: "Quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        quit.keyEquivalentModifierMask = .command
        menu.addItem(quit)

        // Видимая строка при ошибке регистрации хоткея (§9 Фаза 1)
        if hotkeyError {
            let item = NSMenuItem(title: String(localized: "Hotkey is taken by another application"),
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        // Статус ремапа средней кнопки (§9 Фаза 4)
        switch mouseStatus {
        case .karabiner?:
            let item = NSMenuItem(title: String(localized: "Karabiner is running"),
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        case .noAccess?:
            let item = NSMenuItem(title: String(localized: "Remap off: no accessibility access"),
                                  action: #selector(openAccessibility), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        case nil:
            break
        }
    }

    @objc private func openAccessibility() {
        Permissions.openAccessibilitySettings()
    }

    private func historyItem(for clip: Clip) -> NSMenuItem {
        var title = clip.preview
        let cap = prefs.menuTitleLength
        if title.count > cap { title = String(title.prefix(cap)) + "…" }
        let item = NSMenuItem(title: title, action: #selector(selectClip), keyEquivalent: "")
        item.target = self
        item.representedObject = clip.id
        item.toolTip = clip.sourceBundle

        if let blob = clip.blob, let img = NSImage(data: blob) {
            img.size = NSSize(width: 18, height: 18)
            item.image = img
        }
        return item
    }

    // MARK: - Действия

    /// Оба пути — из меню и из панели — через один Paster (§8.4).
    /// Удаление клипа — правым кликом в панели поиска (⌘⌫ из меню убрано
    /// по решению пользователя, ревизия 9).
    @objc private func selectClip(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int64,
              let clip = recentClips.first(where: { $0.id == id }) else { return }
        let store = store, monitor = monitor, prefs = prefs
        let target = pasteTarget
        Task { @MainActor in
            await Paster.paste(clip, mode: .rich, into: target,
                               monitor: monitor, autoAfterSelect: prefs.pasteAutoAfterSelect)
            try? await store.markUsed(id: clip.id)
        }
    }

    @objc private func deleteClip(_ sender: NSMenuItem) {
        // больше не зовётся из меню (⌘⌫ убран, ревизия 9);
        // удаление живёт в контекстном меню панели поиска
    }

    /// Очистка истории (ревизия 9): убрана из меню в настройки —
    /// опасность случайного нажатия. Логика в SettingsWindowController.

    // MARK: - Дампы

    /// Выбор сниппета: плейсхолдеры разворачиваются, эвристики секретов
    /// к сниппетам не применяются никогда (§9 Фаза 2). Через Paster (§8.4).
    @objc private func selectSnippet(_ sender: NSMenuItem) {
        let snippet = snippetsByFolder.flatMap(\.items).first { $0.id == Int64(sender.tag) }
        guard let snippet else { return }
        let text = Placeholders.expand(
            snippet.content,
            clipboardText: NSPasteboard.general.string(forType: .string))
        let clip = Clip(kind: .string, hash: ClipboardIO.sha256Hex(Data(text.utf8)),
                        preview: ClipboardIO.normalizedPreview(text), text: text, blob: nil,
                        sourceBundle: nil, createdAt: Date(), lastUsedAt: Date())
        let monitor = monitor, prefs = prefs
        let target = pasteTarget
        Task { @MainActor in
            await Paster.paste(clip, mode: .rich, into: target,
                               monitor: monitor, autoAfterSelect: prefs.pasteAutoAfterSelect)
        }
    }

    /// Обычный клик — убрать предупреждение, ⌥+клик — сохранить всё-таки (§12).
    @objc private func secretNoticeAction() {
        let mods = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.option) {
            Task { @MainActor in await monitor.saveBlockedSecret() }
        } else {
            Task { @MainActor in await monitor.clearBlockedSecretNotice() }
        }
    }

    @objc private func openSettings() {
        settings.show()
    }

    // MARK: - Управление сниппетами (ревизия 8)

    @objc private func addSnippetDialog() {
        guard !snippetsByFolder.isEmpty else {
            Self.infoAlert(String(localized: "Add a category first."))
            return
        }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 24), pullsDown: false)
        for group in snippetsByFolder { popup.addItem(withTitle: group.folder.title) }
        guard let (title, content) = snippetDialog(title: "", content: "", accessory: popup)
        else { return }
        let folder = snippetsByFolder[popup.indexOfSelectedItem].folder
        let store = snippetsStore
        let idx = popup.indexOfSelectedItem
        Task { @MainActor in
            try? await store.insertSnippet(folderID: folder.id, title: title, content: content)
            Log.menu.info("сниппет добавлен в «\(self.snippetsByFolder[idx].folder.title, privacy: .public)»")
            NotificationCenter.default.post(name: .clipsDidChange, object: nil)
        }
    }

    @objc private func addCategoryDialog() {
        guard let name = Self.textDialog(
            message: String(localized: "New Category"),
            label: String(localized: "Name:"),
            placeholder: String(localized: "Category name"))
        else { return }
        let store = snippetsStore
        Task { @MainActor in
            _ = try? await store.insertCategory(title: name)
            NotificationCenter.default.post(name: .clipsDidChange, object: nil)
        }
    }

    @objc private func deleteCategoryAction(_ sender: NSMenuItem) {
        let id = Int64(sender.tag)
        guard let group = snippetsByFolder.first(where: { $0.folder.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = String(format: String(localized: "delete.category"), group.folder.title)
        alert.informativeText = String(format: String(localized: "delete.category.snippets"), group.items.count)
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let store = snippetsStore
        Task { @MainActor in
            try? await store.deleteCategory(id: id)
            NotificationCenter.default.post(name: .clipsDidChange, object: nil)
        }
    }

    @objc private func editSnippetDialog(_ sender: NSMenuItem) {
        let id = Int64(sender.tag)
        guard let snippet = snippetsByFolder.flatMap(\.items).first(where: { $0.id == id }) else { return }
        guard let (title, content) = snippetDialog(title: snippet.title,
                                                   content: snippet.content, accessory: nil)
        else { return }
        let store = snippetsStore
        Task { @MainActor in
            try? await store.updateSnippet(id: id, title: title, content: content)
            NotificationCenter.default.post(name: .clipsDidChange, object: nil)
        }
    }

    @objc private func deleteSnippetAction(_ sender: NSMenuItem) {
        let id = Int64(sender.tag)
        let store = snippetsStore
        Task { @MainActor in
            try? await store.deleteSnippet(id: id)
            NotificationCenter.default.post(name: .clipsDidChange, object: nil)
        }
    }

    /// Поле контента открытого диалога — для вставки плейсхолдеров
    /// по клику (диалог модальный, поле одно).
    private weak var dialogContentField: NSTextField?

    /// Диалог «заголовок + контент» (+ опциональный выбор категории сверху
    /// и списком плейсхолдеров с вставкой по клику — ревизия 8.1).
    private func snippetDialog(title: String, content: String,
                               accessory: NSView?) -> (String, String)? {
        let alert = NSAlert()
        alert.messageText = title.isEmpty ? String(localized: "Add Snippet") : String(localized: "Edit Snippet")
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 320, height: 168))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        if let accessory { stack.addArrangedSubview(accessory) }

        let titleField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        titleField.placeholderString = String(localized: "Title")
        titleField.stringValue = title
        let contentField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        contentField.placeholderString = String(localized: "Content")
        contentField.stringValue = content

        // Список плейсхолдеров: выбор пункта дописывает токен в контент
        let insertPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 24),
                                        pullsDown: false)
        insertPopup.addItem(withTitle: String(localized: "Insert placeholder…"))
        for token in ["{clipboard}", "{uuid}", "{date:yyyy-MM-dd}",
                      "{date:HH:mm}", "{date:yyyy-MM-dd HH:mm}"] {
            insertPopup.addItem(withTitle: token)
        }
        insertPopup.target = self
        insertPopup.action = #selector(insertPlaceholder(_:))

        stack.addArrangedSubview(titleField)
        stack.addArrangedSubview(contentField)
        stack.addArrangedSubview(insertPopup)
        alert.accessoryView = stack
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        dialogContentField = contentField
        defer { dialogContentField = nil }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let t = titleField.stringValue.trimmingCharacters(in: .whitespaces)
        let c = contentField.stringValue
        guard !t.isEmpty, !c.isEmpty else { return nil }
        return (t, c)
    }

    @objc private func insertPlaceholder(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem > 0,
              let token = sender.titleOfSelectedItem else { return }
        dialogContentField?.stringValue += token
        sender.selectItem(at: 0)
    }

    private static func textDialog(message: String, label: String, placeholder: String) -> String? {
        let alert = NSAlert()
        alert.messageText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static func infoAlert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.runModal()
    }

    @objc private func openSearch() {
        onSearch?()
    }

    /// Открывает панель поиска (проксируется через StatusItemController).
    public var onSearch: (() -> Void)?

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Дампы

    /// ~/Library/Application Support/ClipMouse/Backups/purge-<ts>.json (§11).
    /// Дамп — та же история клипов: каталог 0700, файлы 0600.
    static func backupsDirectory() -> URL? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = support.appendingPathComponent("ClipMouse/Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }

    static func writePurgeDump(_ clips: [Clip]) {
        guard let dir = backupsDirectory() else { return }
        let ts = DateFormatter(format: "yyyyMMdd-HHmmss").string(from: Date())
        let url = dir.appendingPathComponent("purge-\(ts).json")
        if let data = try? JSONEncoder().encode(clips) {
            try? data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: url.path)
        }
        // храним 3 последних
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("purge-") && $0.hasSuffix(".json") }
            .sorted().reversed()
        for old in names.dropFirst(3) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(old))
        }
    }
}

private extension DateFormatter {
    convenience init(format: String) {
        self.init()
        self.dateFormat = format
    }
}
