import AppKit

/// Контроллер панели поиска (§9 Фаза 3).
/// Пустой запрос — вся история; непустой — фильтр localizedStandardRange
/// по первым 4096 символам. Единственное окно на полный список.
/// Правый клик по строке: Delete / Never save from "<App>".
@MainActor
public final class SearchController: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    private let store: ClipStore
    private let monitor: ClipboardMonitor
    private let prefs: Prefs
    private let panel = SearchPanel()
    private var searchField: NSSearchField!
    private var tableView: NSTableView!
    private var items: [Clip] = []
    private var targetApp: NSRunningApplication?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var clipsObserver: NSObjectProtocol?

    public var isVisible: Bool { panel.isVisible }

    public init(store: ClipStore, monitor: ClipboardMonitor, prefs: Prefs) {
        self.store = store
        self.monitor = monitor
        self.prefs = prefs
        super.init()
        buildUI()
        clipsObserver = NotificationCenter.default.addObserver(
            forName: .clipsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                Task { @MainActor in await self.reload() }
            }
        }
    }

    // MARK: - Показ/скрытие

    public func toggle() {
        if panel.isVisible { hide() } else { show() }
    }

    private func show() {
        // Цель вставки — фронтальное приложение до нас (§9 Фаза 3)
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != "dev.zeklop.clipmouse" {
            targetApp = front
        }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        windowDidBecomeKey()

        // Глобальный клик мимо — закрыть; правый клик по таблице —
        // контекстное меню Delete / Never save from (§9 Фаза 3)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            guard let self else { return event }
            if event.window === self.panel {
                if event.type == .rightMouseDown, self.handleRightClick(event) {
                    return nil
                }
                return event
            }
            self.hide()
            return event
        }
    }

    public func hide() {
        panel.orderOut(nil)
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func windowDidBecomeKey() {
        searchField.stringValue = ""
        Task { @MainActor in
            await reload()
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            window?.makeFirstResponder(searchField)
        }
    }

    private var window: NSWindow? { panel }

    // MARK: - Данные

    private func reload() async {
        items = (try? await store.recent(limit: prefs.historyLimit)) ?? []
        tableView.reloadData()
        updateEmptyState()
    }

    private var filtered: [Clip] {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        // матч по превью, первым 4096 символам текста или источнику:
        // «Telegram» покажет всё из ru.keepcoder.Telegram (ревизия 8)
        return items.filter { clip in
            if clip.preview.localizedStandardContains(query) { return true }
            if let source = clip.sourceBundle, source.localizedStandardContains(query) { return true }
            guard let text = clip.text else { return false }
            return String(text.prefix(4096)).localizedStandardContains(query)
        }
    }

    // MARK: - UI

    private func buildUI() {
        let field = NSSearchField()
        field.placeholderString = String(localized: "Search clipboard history")
        field.target = self
        field.action = #selector(queryChanged)
        self.searchField = field

        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip"))
        column.width = 520
        table.addTableColumn(column)
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        table.usesAlternatingRowBackgroundColors = false
        table.rowHeight = 34
        table.doubleAction = #selector(chooseRow)
        table.target = self
        table.style = .fullWidth
        self.tableView = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true

        let empty = NSTextField(labelWithString: String(localized: "No clips"))
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        empty.isHidden = true
        self.emptyLabel = empty

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 440))
        field.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        empty.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(field)
        root.addSubview(scroll)
        root.addSubview(empty)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        panel.contentView = root
    }

    private var emptyLabel: NSTextField!

    private func updateEmptyState() {
        emptyLabel.isHidden = !filtered.isEmpty
        emptyLabel.stringValue = searchField.stringValue.isEmpty
            ? String(localized: "No clips yet") : String(localized: "Nothing found")
    }

    // MARK: - Действия

    @objc private func queryChanged() {
        tableView.reloadData()
        updateEmptyState()
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    /// Модификаторы читаются в момент Enter/клика, не при открытии панели:
    /// ⌥ — plain, ⌘ — posix path (§9 Фаза 3).
    @objc private func chooseRow() {
        let row = tableView.selectedRow
        guard row >= 0, row < filtered.count else { return }
        let clip = filtered[row]
        let mods = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let mode: Paster.PasteMode
        if mods.contains(.option) {
            mode = .plain
        } else if mods.contains(.command) {
            mode = .posixPath
        } else {
            mode = .rich
        }
        hide()
        let monitor = monitor, store = store, prefs = prefs
        let target = targetApp
        Task { @MainActor in
            await Paster.paste(clip, mode: mode, into: target,
                               monitor: monitor, autoAfterSelect: prefs.pasteAutoAfterSelect)
            try? await store.markUsed(id: clip.id)
        }
    }

    // MARK: - NSTableViewDataSource / Delegate

    public func numberOfRows(in tableView: NSTableView) -> Int {
        filtered.count
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        nil
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let list = filtered
        guard row < list.count else { return nil }
        let clip = list[row]

        let cell = NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier("clip-cell")
        let title = NSTextField(labelWithString: clip.preview)
        title.font = .systemFont(ofSize: 12)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingHead
        title.maximumNumberOfLines = 1
        let detail = NSTextField(labelWithString: detailLine(clip))
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor

        cell.addSubview(title)
        cell.addSubview(detail)
        title.translatesAutoresizingMaskIntoConstraints = false
        detail.translatesAutoresizingMaskIntoConstraints = false
        cell.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5),
            detail.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            detail.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
        ])
        return cell
    }

    private func detailLine(_ clip: Clip) -> String {
        var parts = [clip.kind.rawValue]
        if let source = clip.sourceBundle { parts.append(source) }
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        parts.append(df.string(from: clip.lastUsedAt))
        return parts.joined(separator: " · ")
    }

    /// Контекстное меню строки: Delete / Never save from "<App>" (§9 Фаза 3).
    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        true
    }

    /// Правый клик по строке — контекстное меню (§9 Фаза 3).
    private func handleRightClick(_ event: NSEvent) -> Bool {
        let point = tableView.convert(event.locationInWindow, from: nil)
        let row = tableView.row(at: point)
        guard row >= 0, row < filtered.count else { return false }
        let clip = filtered[row]

        let menu = NSMenu()
	        let del = NSMenuItem(title: String(localized: "Delete"), action: #selector(deleteClip(_:)), keyEquivalent: "")
        del.target = self
        del.tag = Int(clip.id)
        menu.addItem(del)
        if let bundle = clip.sourceBundle, !bundle.isEmpty {
	            let never = NSMenuItem(
	                title: String(format: String(localized: "never.save.from"), bundle),
	                action: #selector(blockSource(_:)), keyEquivalent: "")
            never.target = self
            never.representedObject = bundle
            menu.addItem(never)
        }
        // point уже в координатах tableView — без повторного конверта
        // (двойной конверт уводил меню в низ экрана)
        menu.popUp(positioning: nil, at: point, in: tableView)
        return true
    }

    @objc private func deleteClip(_ sender: NSMenuItem) {
        let id = Int64(sender.tag)
        let store = store
        Task { @MainActor in
            try? await store.delete(id: id)
            await reload()
            NotificationCenter.default.post(name: .clipsDidChange, object: nil)
        }
    }

    /// Дописывает bundle id в security.blockedSources, действует без
    /// перезапуска (§9 Фаза 3).
    @objc private func blockSource(_ sender: NSMenuItem) {
        guard let bundle = sender.representedObject as? String else { return }
        let current = UserDefaults.standard.stringArray(forKey: DefaultsKey.securityBlockedSources)
            ?? Prefs().blockedSources
        guard !current.contains(bundle) else { return }
        UserDefaults.standard.set(current + [bundle], forKey: DefaultsKey.securityBlockedSources)
        Log.monitor.notice("источник добавлен в чёрный список: \(bundle, privacy: .public)")
    }
}
