import AppKit
import ServiceManagement

/// Окно настроек с табами (ревизия 16): NSTabView — General / Snippets /
/// Security / About, футер с версией под табами. Таб Snippets — master-detail
/// в SnippetsTab. Сохранение: чекбоксы и попапы — мгновенно, числовые
/// поля — по Enter или при уходе фокуса (controlTextDidEndEditing).
@MainActor
public final class SettingsWindowController: NSObject {

    /// Табы настроек для show(tab:) — «Manage Snippets…» и тупик
    /// «нет категорий» ведут сразу на нужный таб.
    public enum Tab: String {
        case general, snippets, security, about
    }

    private let store: ClipStore
    private let snippetsStore: SnippetStore
    private let prefs: Prefs
    private var window: NSWindow?
    private var tabView: NSTabView?
    private var snippetsTab: SnippetsTab?

    // General
    private var loginCheckbox: NSButton!
    private var mouseCheckbox: NSButton!
    private var autoPasteCheckbox: NSButton!
    private var keepLastField: NSTextField!
    private var expireDaysField: NSTextField!
    private var inlineCountField: NSTextField!
    private var durationPopup: NSPopUpButton!
    private var batteryField: NSTextField!

    // Security
    private var blockedTable: NSTableView!
    private var blockedData: [(bundle: String, name: String, icon: NSImage?)] = []
    private var addButton: NSButton!
    private var secretsCheckbox: NSButton!
    private var secretTTLField: NSTextField!

    /// Числовое поле → сеттер значения (controlTextDidEndEditing)
    private var fieldSetters: [ObjectIdentifier: (String) -> Void] = [:]

    private static let durations: [(String, Int)] =
        [(String(localized: "30 min"), 1800), (String(localized: "1 hour"), 3600),
         (String(localized: "2 hours"), 7200), (String(localized: "5 hours"), 18_000)]

    public init(store: ClipStore, snippetsStore: SnippetStore, prefs: Prefs) {
        self.store = store
        self.snippetsStore = snippetsStore
        self.prefs = prefs
        super.init()
    }

    /// Открыть окно на данном табе (по умолчанию General). Таб Snippets
    /// перечитывает данные при каждом показе.
    public func show(tab: Tab = .general) {
        if window == nil { build() }
        syncFromPrefs()
        snippetsTab?.reload()
        tabView?.selectTabViewItem(withIdentifier: tab.rawValue)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Сборка

    private func build() {
        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false

        let general = NSTabViewItem(identifier: Tab.general.rawValue)
        general.label = String(localized: "General")
        general.view = buildGeneralTab()
        tabView.addTabViewItem(general)

        let snippetsItem = NSTabViewItem(identifier: Tab.snippets.rawValue)
        snippetsItem.label = String(localized: "Snippets")
        let snippetsTab = SnippetsTab(store: snippetsStore)
        self.snippetsTab = snippetsTab
        snippetsItem.view = snippetsTab.root
        tabView.addTabViewItem(snippetsItem)

        let security = NSTabViewItem(identifier: Tab.security.rawValue)
        security.label = String(localized: "Security")
        security.view = buildSecurityTab()
        tabView.addTabViewItem(security)

        let about = NSTabViewItem(identifier: Tab.about.rawValue)
        about.label = String(localized: "About")
        about.view = buildAboutTab()
        tabView.addTabViewItem(about)

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

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 540))
        root.addSubview(tabView)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            tabView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            tabView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            tabView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])

        let w = NSWindow(contentViewController: NSViewController())
        w.contentViewController?.view = root
        w.title = String(localized: "ClipMouse Settings")
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 620, height: 540))
        window = w
        self.tabView = tabView
    }

    /// Вертикальный стек в скролле — паттерн дотабового окна настроек.
    /// Ширина документа равна ширине скролла, чтобы полноширинные
    /// контролы можно было прижать к документу.
    private func makeScrollStack(alignment: NSLayoutConstraint.Attribute = .leading)
        -> (scroll: NSScrollView, stack: NSStackView, document: NSView) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = alignment
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        return (scroll, stack, document)
    }

    private func section(_ title: String, in stack: NSStackView) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(label)
        stack.setCustomSpacing(4, after: label)
    }

    private func gap(_ v: CGFloat = 14, in stack: NSStackView) {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: v).isActive = true
        stack.addArrangedSubview(spacer)
        stack.setCustomSpacing(0, after: spacer)
    }

    /// Строка «подпись слева, контрол справа».
    @discardableResult
    private func row(caption: String, view: NSView, in stack: NSStackView,
                     captionWidth: CGFloat = 250) -> NSStackView {
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

    private func numberField(value: Int, action: Selector,
                             save: @escaping (Int) -> Void) -> NSTextField {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 70, height: 22))
        field.stringValue = String(value)
        field.target = self
        field.action = action
        bindEndEditing(field) { save(Int($0) ?? value) }
        field.widthAnchor.constraint(equalToConstant: 70).isActive = true
        return field
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

    // MARK: - Таб General

    private func buildGeneralTab() -> NSView {
        let (scroll, stack, _) = makeScrollStack()

        // General: три чекбокса подряд, без хинтов (ревизия 16)
        section(String(localized: "General"), in: stack)
        loginCheckbox = checkbox(String(localized: "Launch at Login"), action: #selector(toggleLogin))
        stack.addArrangedSubview(loginCheckbox)
        mouseCheckbox = checkbox(String(localized: "Middle mouse button → right ⌘"), action: #selector(toggleMouse))
        stack.addArrangedSubview(mouseCheckbox)
        autoPasteCheckbox = checkbox(String(localized: "Paste immediately after selecting (⌘V)"),
                                     action: #selector(toggleAutoPaste))
        stack.addArrangedSubview(autoPasteCheckbox)
        gap(in: stack)

        // History
        section(String(localized: "History"), in: stack)
        keepLastField = numberField(value: prefs.historyLimit,
                                     action: #selector(keepLastChanged)) { self.prefs.setHistoryLimit($0) }
        row(caption: String(localized: "Keep last (10…500)"), view: keepLastField, in: stack)
        expireDaysField = numberField(value: prefs.historyExpireDays,
                                      action: #selector(expireChanged)) { self.prefs.setHistoryExpireDays($0) }
        row(caption: String(localized: "Delete after days (1…365)"), view: expireDaysField, in: stack)
        inlineCountField = numberField(value: prefs.menuInlineCount,
                                       action: #selector(inlineChanged)) { self.prefs.setMenuInlineCount($0) }
        let inlineRow = row(caption: String(localized: "Show in menu (5…30)"), view: inlineCountField, in: stack)
        let clear = NSButton(title: String(localized: "Clear All History…"), target: self,
                             action: #selector(clearHistory))
        clear.bezelStyle = .rounded
        clear.translatesAutoresizingMaskIntoConstraints = false
        inlineRow.addArrangedSubview(clear)
        gap(in: stack)

        // Awake
        section(String(localized: "Awake"), in: stack)
        durationPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 160, height: 24), pullsDown: false)
        for (label, _) in Self.durations { durationPopup.addItem(withTitle: label) }
        durationPopup.target = self
        durationPopup.action = #selector(durationChanged)
        row(caption: String(localized: "Icon toggle duration"), view: durationPopup, in: stack)
        batteryField = numberField(value: prefs.awakeBatteryThreshold,
                                   action: #selector(batteryChanged)) { self.prefs.setAwakeBatteryThreshold($0) }
        row(caption: String(localized: "Turn off below battery % (5…100)"), view: batteryField, in: stack)

        return scroll
    }

    // MARK: - Таб Security

    private func buildSecurityTab() -> NSView {
        let (scroll, stack, document) = makeScrollStack()

        // Blocked apps: таблица на всю ширину вкладки (ревизия 16)
        section(String(localized: "security.blocked.header"), in: stack)
        let hint = NSTextField(labelWithString: String(localized: "security.blocked.hint"))
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)
        blockedTable = makeBlockedTable()
        let blockedScroll = NSScrollView()
        blockedScroll.documentView = blockedTable
        blockedScroll.hasVerticalScroller = true
        blockedScroll.translatesAutoresizingMaskIntoConstraints = false
        blockedScroll.heightAnchor.constraint(equalToConstant: 140).isActive = true
        blockedScroll.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -40).isActive = true
        stack.addArrangedSubview(blockedScroll)
        addButton = NSButton(title: String(localized: "+ Add running app…"), target: self,
                             action: #selector(addBlockedApp))
        addButton.bezelStyle = .rounded
        addButton.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(addButton)
        gap(in: stack)

        // Temporary secrets (ревизия 15): чекбокс над полем TTL,
        // поле дизейблится вместе с тумблером
        section(String(localized: "security.secrets.header"), in: stack)
        secretsCheckbox = checkbox(String(localized: "security.secrets.toggle"),
                                   action: #selector(toggleSecrets))
        stack.addArrangedSubview(secretsCheckbox)
        secretTTLField = numberField(value: prefs.secretTTLMinutes,
                                     action: #selector(secretTTLChanged)) { self.prefs.setSecretTTLMinutes($0) }
        row(caption: String(localized: "security.ttl"), view: secretTTLField, in: stack)
        let secretsHint = NSTextField(labelWithString: String(localized: "security.secrets.hint"))
        secretsHint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(secretsHint)

        return scroll
    }

    private func makeBlockedTable() -> NSTableView {
        let table = NSTableView()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 26
        table.style = .fullWidth
        return table
    }

    // MARK: - Таб About

    private func buildAboutTab() -> NSView {
        let (scroll, stack, document) = makeScrollStack(alignment: .centerX)

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        stack.addArrangedSubview(icon)

        let name = NSTextField(labelWithString: String(localized: "ClipMouse"))
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        stack.addArrangedSubview(name)

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        stack.addArrangedSubview(NSTextField(
            labelWithString: String(format: String(localized: "about.version"), version)))

        let tagline = NSTextField(labelWithString: String(localized: "about.tagline"))
        tagline.textColor = .secondaryLabelColor
        stack.addArrangedSubview(tagline)

        let github = NSButton(title: String(localized: "GitHub"), target: self,
                              action: #selector(openRepo))
        github.bezelStyle = .rounded
        stack.addArrangedSubview(github)

        let license = NSTextField(labelWithString: String(localized: "MIT License"))
        license.font = .systemFont(ofSize: 10)
        license.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(license)
        stack.setCustomSpacing(16, after: license)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -80).isActive = true
        stack.addArrangedSubview(separator)
        stack.setCustomSpacing(12, after: separator)

        // Shortcuts: список пар «модификаторы — описание»
        let header = NSTextField(labelWithString: String(localized: "about.shortcuts.header"))
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        let headerRow = NSStackView(views: [header])
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -80).isActive = true
        stack.addArrangedSubview(headerRow)
        stack.setCustomSpacing(4, after: headerRow)
        // Ключи — литералы: String(localized:) не принимает динамическую строку
        for value in [String(localized: "about.shortcuts.history"),
                      String(localized: "about.shortcuts.snippets"),
                      String(localized: "about.shortcuts.awake"),
                      String(localized: "about.shortcuts.plain"),
                      String(localized: "about.shortcuts.posix"),
                      String(localized: "about.shortcuts.saveSnippet"),
                      String(localized: "about.shortcuts.settings")] {
            stack.addArrangedSubview(shortcutRow(value, document: document))
        }

        return scroll
    }

    /// Строка шортката: символы правой колонкой фиксированной ширины,
    /// описание — вторичным цветом; значение ключа — «символы — описание».
    private func shortcutRow(_ value: String, document: NSView) -> NSView {
        let parts = value.components(separatedBy: " — ")
        let symLabel = NSTextField(labelWithString: parts.count == 2 ? parts[0] : "")
        symLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        symLabel.alignment = .right
        symLabel.translatesAutoresizingMaskIntoConstraints = false
        symLabel.widthAnchor.constraint(equalToConstant: 170).isActive = true
        let descLabel = NSTextField(labelWithString: parts.count == 2 ? parts[1] : value)
        descLabel.textColor = .secondaryLabelColor
        let rowStack = NSStackView(views: [symLabel, descLabel])
        rowStack.orientation = .horizontal
        rowStack.spacing = 12
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -80).isActive = true
        return rowStack
    }

    // MARK: - Синхронизация

    private func syncFromPrefs() {
        loginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        mouseCheckbox.state = prefs.mouseEnabled ? .on : .off
        autoPasteCheckbox.state = prefs.pasteAutoAfterSelect ? .on : .off
        keepLastField.stringValue = String(prefs.historyLimit)
        expireDaysField.stringValue = String(prefs.historyExpireDays)
        inlineCountField.stringValue = String(prefs.menuInlineCount)
        batteryField.stringValue = String(prefs.awakeBatteryThreshold)
        secretsCheckbox.state = prefs.temporarySecretsEnabled ? .on : .off
        secretTTLField.isEnabled = prefs.temporarySecretsEnabled
        secretTTLField.stringValue = String(prefs.secretTTLMinutes)
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

    /// Колонтитул настроек и кнопка GitHub — ссылка на репозиторий.
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

    /// Ревизия 15: тумблер временного хранения секретов; поле TTL
    /// дизейблится вместе с тумблером.
    @objc private func toggleSecrets() {
        let on = secretsCheckbox.state == .on
        prefs.setTemporarySecretsEnabled(on)
        secretTTLField.isEnabled = on
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

    @objc private func secretTTLChanged() {
        prefs.setSecretTTLMinutes(Int(secretTTLField.stringValue) ?? prefs.secretTTLMinutes)
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
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: entry.name)
        label.font = .systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        let remove = NSButton(title: "−", target: self, action: #selector(removeBlockedRow(_:)))
        remove.bezelStyle = .rounded
        remove.controlSize = .small
        remove.translatesAutoresizingMaskIntoConstraints = false
        remove.toolTip = String(localized: "Remove from the list")
        cell.addSubview(icon)
        cell.addSubview(label)
        cell.addSubview(remove)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: remove.leadingAnchor, constant: -8),
            remove.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            remove.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
