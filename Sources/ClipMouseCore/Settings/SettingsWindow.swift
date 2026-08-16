import AppKit
import ServiceManagement

/// Окно настроек (§9 Фаза 6): один экран без вкладок, контент в скролле
/// (ревизия 9.1), список заблокированных приложений — со своим скроллом.
/// Сохранение: чекбоксы и попапы — мгновенно, числовые поля — по Enter
/// или при уходе фокуса (NSControl.textDidEndEditingNotification).
@MainActor
public final class SettingsWindowController: NSObject {

    private let store: ClipStore
    private let prefs: Prefs
    private var window: NSWindow?

    private var loginCheckbox: NSButton!
    private var mouseCheckbox: NSButton!
    private var keepLastField: NSTextField!
    private var expireDaysField: NSTextField!
    private var inlineCountField: NSTextField!
    private var autoPasteCheckbox: NSButton!
    private var durationPopup: NSPopUpButton!
    private var batteryField: NSTextField!
    private var blockedTable: NSTableView!
    private var blockedData: [(bundle: String, name: String, icon: NSImage?)] = []
    /// Числовое поле → сеттер значения (controlTextDidEndEditing)
    private var fieldSetters: [ObjectIdentifier: (String) -> Void] = [:]
    private var addButton: NSButton!

    private static let durations: [(String, Int)] =
        [(String(localized: "30 min"), 1800), (String(localized: "1 hour"), 3600),
         (String(localized: "2 hours"), 7200), (String(localized: "5 hours"), 18_000)]

    public init(store: ClipStore, prefs: Prefs) {
        self.store = store
        self.prefs = prefs
        super.init()
    }

    public func show() {
        if window == nil { build() }
        syncFromPrefs()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Сборка

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        func section(_ title: String) {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            stack.addArrangedSubview(label)
            stack.setCustomSpacing(4, after: label)
        }

        func gap(_ v: CGFloat = 14) {
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.heightAnchor.constraint(equalToConstant: v).isActive = true
            stack.addArrangedSubview(spacer)
            stack.setCustomSpacing(0, after: spacer)
        }

        /// Строка «подпись слева, контрол справа».
        @discardableResult
        func row(caption: String, view: NSView, captionWidth: CGFloat = 250) -> NSStackView {
            let label = NSTextField(labelWithString: caption)
            label.translatesAutoresizingMaskIntoConstraints = false
            view.translatesAutoresizingMaskIntoConstraints = false
            let h = NSStackView(views: [label, view])
            h.orientation = .horizontal
            h.spacing = 8
            label.widthAnchor.constraint(equalToConstant: captionWidth).isActive = true
            stack.addArrangedSubview(h)
            return h
        }

        func numberField(value: Int, action: Selector, save: @escaping (Int) -> Void) -> NSTextField {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 70, height: 22))
            field.stringValue = String(value)
            field.target = self
            field.action = action
            bindEndEditing(field) { save(Int($0) ?? value) }
            field.widthAnchor.constraint(equalToConstant: 70).isActive = true
            return field
        }

        // General
        section(String(localized: "General"))
        loginCheckbox = checkbox(String(localized: "Launch at Login"), action: #selector(toggleLogin))
        stack.addArrangedSubview(loginCheckbox)
        mouseCheckbox = checkbox(String(localized: "Middle mouse button → right ⌘"), action: #selector(toggleMouse))
        stack.addArrangedSubview(mouseCheckbox)
        let shortcuts = NSTextField(labelWithString: String(localized: "shortcuts.hint"))
        shortcuts.textColor = .secondaryLabelColor
        stack.addArrangedSubview(shortcuts)
        gap()

        // History
        section(String(localized: "History"))
        keepLastField = numberField(value: prefs.historyLimit,
                                     action: #selector(keepLastChanged)) { self.prefs.setHistoryLimit($0) }
        row(caption: String(localized: "Keep last (10…500)"), view: keepLastField)
        expireDaysField = numberField(value: prefs.historyExpireDays,
                                      action: #selector(expireChanged)) { self.prefs.setHistoryExpireDays($0) }
        row(caption: String(localized: "Delete after days (1…365)"), view: expireDaysField)
        inlineCountField = numberField(value: prefs.menuInlineCount,
                                       action: #selector(inlineChanged)) { self.prefs.setMenuInlineCount($0) }
        row(caption: String(localized: "Show in menu (5…30)"), view: inlineCountField)
        let clear = NSButton(title: String(localized: "Clear All History…"), target: self,
                             action: #selector(clearHistory))
        clear.bezelStyle = .rounded
        clear.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(clear)
        gap()

        // Paste
        section(String(localized: "Paste"))
        autoPasteCheckbox = checkbox(String(localized: "Paste immediately after selecting (⌘V)"),
                                     action: #selector(toggleAutoPaste))
        stack.addArrangedSubview(autoPasteCheckbox)
        let hint = NSTextField(labelWithString: String(localized: "paste.hint"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)
        gap()

        // Security
        section(String(localized: "security.section"))
        blockedTable = makeBlockedTable()
        let scroll = NSScrollView()
        scroll.documentView = blockedTable
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 400).isActive = true
        stack.addArrangedSubview(scroll)
        addButton = NSButton(title: String(localized: "+ Add running app…"), target: self,
                             action: #selector(addBlockedApp))
        addButton.bezelStyle = .rounded
        addButton.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(addButton)
        gap()

        // Awake
        section(String(localized: "Awake"))
        durationPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 160, height: 24), pullsDown: false)
        for (label, _) in Self.durations { durationPopup.addItem(withTitle: label) }
        durationPopup.target = self
        durationPopup.action = #selector(durationChanged)
        row(caption: String(localized: "Icon toggle duration"), view: durationPopup)
        batteryField = numberField(value: prefs.awakeBatteryThreshold,
                                   action: #selector(batteryChanged)) { self.prefs.setAwakeBatteryThreshold($0) }
        row(caption: String(localized: "Turn off below battery % (5…100)"), view: batteryField)

        // Скролл со всем контентом
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        let scrollAll = NSScrollView()
        scrollAll.documentView = document
        scrollAll.hasVerticalScroller = true
        scrollAll.borderType = .noBorder
        scrollAll.translatesAutoresizingMaskIntoConstraints = false

        // Футер: версия и автор (мелко) — весь колонтитул ведёт в репозиторий
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let footerTitle = String(format: String(localized: "footer.version"), version)
        let footer = NSButton(title: footerTitle, target: self,
                              action: #selector(openRepo))
        footer.bezelStyle = .inline
        footer.attributedTitle = NSAttributedString(
            string: footerTitle,
            attributes: [.font: NSFont.systemFont(ofSize: 10),
                         .foregroundColor: NSColor.tertiaryLabelColor])
        footer.toolTip = "https://github.com/zeklop/clipmouse"
        footer.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 520))
        root.addSubview(scrollAll)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            scrollAll.topAnchor.constraint(equalTo: root.topAnchor),
            scrollAll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollAll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollAll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            // ширина контента = ширина скролла (стек не растягивается)
            document.widthAnchor.constraint(equalTo: scrollAll.widthAnchor),
        ])

        let w = NSWindow(contentViewController: NSViewController())
        w.contentViewController?.view = root
        w.title = String(localized: "ClipMouse Settings")
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        window = w
    }

    private func checkbox(_ title: String, action: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: action)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    /// Числовое поле сохраняется и по Enter, и при уходе фокуса (делегат).
    private func bindEndEditing(_ field: NSTextField, save: @escaping (String) -> Void) {
        field.delegate = self
        fieldSetters[ObjectIdentifier(field)] = save
    }

    private func makeBlockedTable() -> NSTableView {
        let table = NSTableView()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        col.width = 390
        table.addTableColumn(col)
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 26
        table.style = .fullWidth
        return table
    }

    // MARK: - Синхронизация

    private func syncFromPrefs() {
        loginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        mouseCheckbox.state = prefs.mouseEnabled ? .on : .off
        keepLastField.stringValue = String(prefs.historyLimit)
        expireDaysField.stringValue = String(prefs.historyExpireDays)
        inlineCountField.stringValue = String(prefs.menuInlineCount)
        autoPasteCheckbox.state = prefs.pasteAutoAfterSelect ? .on : .off
        batteryField.stringValue = String(prefs.awakeBatteryThreshold)
        if let idx = Self.durations.firstIndex(where: { $0.1 == prefs.awakeDefaultDuration }) {
            durationPopup.selectItem(at: idx)
        }
        reloadBlocked()
    }

    private func reloadBlocked() {
        blockedData = prefs.blockedSources.map { bundle in
            var name = bundle
            var icon: NSImage?
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                name = (url.lastPathComponent as NSString).deletingPathExtension
                icon = NSWorkspace.shared.icon(forFile: url.path)
                icon?.size = NSSize(width: 18, height: 18)
            }
            return (bundle, name, icon)
        }
        blockedTable.reloadData()
    }

    // MARK: - Действия

    /// Колонтитул настроек — ссылка на репозиторий.
    @objc private func openRepo() {
        NSWorkspace.shared.open(URL(string: "https://github.com/zeklop/clipmouse")!)
    }

    @objc private func toggleLogin() {
        let on = loginCheckbox.state == .on
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.app.error("SMAppService: \(error.localizedDescription, privacy: .public)")
            loginCheckbox.state = .off
            // Молчаливый откат галочки — тупик «приложение сломано»:
            // показываем причину и подсказку (ревью публикации)
            let alert = NSAlert()
            alert.messageText = String(localized: "Launch at Login failed")
            alert.informativeText = error.localizedDescription
                + "\n\n" + String(localized: "login.failed.hint")
            alert.runModal()
        }
    }

    /// Ревью публикации: тоггл ремапа применяется сразу, а не после
    /// перезапуска. Колбэк подключает main (start/stop + статус в меню).
    var onMouseToggle: ((Bool) -> Void)?

    @objc private func toggleMouse() {
        let on = mouseCheckbox.state == .on
        prefs.setMouseEnabled(on)
        onMouseToggle?(on)
    }

    @objc private func toggleAutoPaste() {
        prefs.setPasteAutoAfterSelect(autoPasteCheckbox.state == .on)
    }

    @objc private func keepLastChanged() {
        prefs.setHistoryLimit(Int(keepLastField.stringValue) ?? prefs.historyLimit)
    }

    @objc private func expireChanged() {
        prefs.setHistoryExpireDays(Int(expireDaysField.stringValue) ?? prefs.historyExpireDays)
    }

    @objc private func inlineChanged() {
        prefs.setMenuInlineCount(Int(inlineCountField.stringValue) ?? prefs.menuInlineCount)
    }

    @objc private func batteryChanged() {
        prefs.setAwakeBatteryThreshold(Int(batteryField.stringValue) ?? prefs.awakeBatteryThreshold)
    }

    @objc private func durationChanged() {
        let idx = durationPopup.indexOfSelectedItem
        guard idx >= 0, idx < Self.durations.count else { return }
        prefs.setAwakeDefaultDuration(Self.durations[idx].1)
    }

    /// Очистка истории: алерт с числом записей, дамп в Backups (3 последних),
    /// физическое удаление (§9 Фаза 1 + ревизия 9: живёт в настройках).
    @objc private func clearHistory() {
        let store = store, prefs = prefs
        Task { @MainActor in
            let count = (try? await store.count()) ?? 0
            guard count > 0 else { return }

            let alert = NSAlert()
            alert.messageText = String(localized: "Clear History")
            alert.informativeText = String(format: String(localized: "clear.history.confirm"), count)
            alert.addButton(withTitle: String(localized: "Delete"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            if let all = try? await store.recent(limit: prefs.historyLimit) {
                MenuBuilder.writePurgeDump(all)
            }
            _ = try? await store.clearAll()
            NotificationCenter.default.post(name: .clipsDidChange, object: nil)
        }
    }

    @objc private func addBlockedApp() {
        let menu = NSMenu()
        let seen = NSMutableSet()
        let running = NSWorkspace.shared.runningApplications.filter { app in
            guard let bid = app.bundleIdentifier,
                  bid != "dev.zeklop.clipmouse",
                  app.activationPolicy == .regular,
                  !seen.contains(bid) else { return false }
            seen.add(bid)
            return true
        }
        for app in running.prefix(30) {
            let item = NSMenuItem(title: app.localizedName ?? app.bundleIdentifier ?? "?",
                                  action: #selector(blockPicked), keyEquivalent: "")
            item.target = self
            item.representedObject = app.bundleIdentifier
            item.image = app.icon
            item.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: .zero, in: addButton)
    }

    @objc private func blockPicked(_ sender: NSMenuItem) {
        guard let bundle = sender.representedObject as? String else { return }
        var list = prefs.blockedSources
        guard !list.contains(bundle) else { return }
        list.append(bundle)
        prefs.setBlockedSources(list)
        reloadBlocked()
    }

    /// Кнопка «−» в строке таблицы — убрать приложение из списка.
    @objc private func removeBlockedRow(_ sender: NSButton) {
        let row = blockedTable.row(for: sender)
        guard row >= 0, row < blockedData.count else { return }
        var list = prefs.blockedSources
        list.remove(at: row)
        prefs.setBlockedSources(list)
        reloadBlocked()
    }
}

// MARK: - Делегат числовых полей: применение при уходе фокуса

extension SettingsWindowController: NSTextFieldDelegate {
    public func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        fieldSetters[ObjectIdentifier(field)]?(field.stringValue)
    }
}

// MARK: - NSTableView (заблокированные источники)

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {

    public func numberOfRows(in tableView: NSTableView) -> Int {
        blockedData.count
    }

    public func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        guard row < blockedData.count else { return nil }
        let entry = blockedData[row]
        let cell = NSTableCellView()
        let icon = NSImageView()
        icon.image = entry.icon ?? NSImage(systemSymbolName: "app.dashed",
                                           accessibilityDescription: nil)
        icon.frame = NSRect(x: 4, y: 3, width: 18, height: 18)
        let label = NSTextField(labelWithString: entry.name)
        label.font = .systemFont(ofSize: 12)
        label.frame = NSRect(x: 28, y: 5, width: 300, height: 18)
        let remove = NSButton(title: "−", target: self, action: #selector(removeBlockedRow(_:)))
        remove.bezelStyle = .rounded
        remove.controlSize = .small
        remove.frame = NSRect(x: 350, y: 1, width: 30, height: 22)
        remove.toolTip = String(localized: "Remove from the list")
        cell.addSubview(icon)
        cell.addSubview(label)
        cell.addSubview(remove)
        return cell
    }
}
