import AppKit

/// Вкладка Snippets (ревизия 16): master-detail — слева категории,
/// справа сниппеты выбранной категории; весь CRUD живёт здесь.
/// Ревизия 18: редактирование без внешних диалогов — категории
/// переименовываются прямо в таблице (даблклик или «+»), сниппеты правятся
/// в панели-редакторе справа вместо списка; правый клик по клипу в меню
/// и в поиске открывает редактор с предзаполнением (beginSnippetAdd
/// в SettingsWindowController). Подтверждения удалений — алерты (деструктив).
@MainActor
final class SnippetsTab: NSObject {

    let root: NSView

    private let store: SnippetStore
    private var folders: [SnippetStore.Folder] = []
    private var snippets: [SnippetStore.Snippet] = []
    private var observer: NSObjectProtocol?

    // Список: левая колонка категорий и правая колонка сниппетов
    private let categoriesTable = NSTableView()
    private let snippetsTable = NSTableView()
    private let snippetsScroll = NSScrollView()
    private let snippetsHeader = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: String(localized: "Add a category first."))
    private let listStack = NSStackView()
    private let catRemoveButton = NSButton(title: "−", target: nil, action: nil)
    private let snipAddButton = NSButton(title: String(localized: "+ Add"), target: nil, action: nil)
    private let snipEditButton = NSButton(title: String(localized: "Edit…"), target: nil, action: nil)
    private let snipRemoveButton = NSButton(title: "−", target: nil, action: nil)

    // Редактор (ревизия 18): правая колонка в режимах .add/.edit
    private let editorStack = NSStackView()
    private let editorHeader = NSTextField(labelWithString: "")
    private let titleField = NSTextField()
    private let contentScroll = NSScrollView()
    private let contentText = NSTextView()
    private let insertPopup = NSPopUpButton()
    private let saveButton = NSButton(title: String(localized: "Save"), target: nil, action: nil)
    private let cancelButton = NSButton(title: String(localized: "Cancel"), target: nil, action: nil)

    /// Состояние правой колонки: список сниппетов или редактор.
    private enum Mode { case list, add, edit(SnippetStore.Snippet) }
    private var mode: Mode = .list

    init(store: SnippetStore) {
        self.store = store
        self.root = NSView()
        super.init()
        configureTables()

        root.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
        snippetsHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        // замерено пробой: в стеке с alignment .width лейблы с дефолтным
        // hugging (250) не растягиваются и прижимаются к правому краю —
        // снижаем hugging, чтобы стретч стека (приоритет между 1 и 250)
        // выиграл, а alignment .left прижал текст к ведущему краю
        snippetsHeader.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        snippetsHeader.alignment = .left
        emptyLabel.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        emptyLabel.alignment = .left

        // левая панель: категории + компактные «+»/«−»
        let left = NSStackView()
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 6
        left.translatesAutoresizingMaskIntoConstraints = false
        let catHeader = NSTextField(labelWithString: String(localized: "Categories"))
        catHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        let catScroll = NSScrollView()
        catScroll.documentView = categoriesTable
        catScroll.hasVerticalScroller = true
        catScroll.borderType = .bezelBorder
        catScroll.translatesAutoresizingMaskIntoConstraints = false
        categoriesTable.setContentHuggingPriority(.defaultLow, for: .vertical)
        let catAddButton = NSButton(title: "+", target: self, action: #selector(addCategory))
        catAddButton.controlSize = .small
        catAddButton.bezelStyle = .rounded
        catRemoveButton.controlSize = .small
        catRemoveButton.bezelStyle = .rounded
        left.addArrangedSubview(catHeader)
        left.addArrangedSubview(catScroll)
        left.addArrangedSubview(NSStackView(views: [catAddButton, catRemoveButton]))

        // правая панель: список (заголовок, таблица, кнопки) и редактор
        let right = NSStackView()
        right.orientation = .vertical
        right.alignment = .width
        right.spacing = 6
        right.translatesAutoresizingMaskIntoConstraints = false

        listStack.orientation = .vertical
        listStack.alignment = .width
        listStack.spacing = 6
        listStack.translatesAutoresizingMaskIntoConstraints = false
        snippetsScroll.documentView = snippetsTable
        snippetsScroll.hasVerticalScroller = true
        snippetsScroll.borderType = .bezelBorder
        snippetsScroll.translatesAutoresizingMaskIntoConstraints = false
        snippetsTable.setContentHuggingPriority(.defaultLow, for: .vertical)
        snipAddButton.bezelStyle = .rounded
        snipEditButton.bezelStyle = .rounded
        snipRemoveButton.bezelStyle = .rounded
        listStack.addArrangedSubview(snippetsHeader)
        listStack.addArrangedSubview(emptyLabel)
        listStack.addArrangedSubview(snippetsScroll)
        listStack.addArrangedSubview(NSStackView(views: [snipAddButton, snipEditButton, snipRemoveButton]))

        buildEditor()
        right.addArrangedSubview(listStack)
        right.addArrangedSubview(editorStack)

        root.addSubview(left)
        root.addSubview(right)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            left.topAnchor.constraint(equalTo: root.topAnchor),
            left.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            left.widthAnchor.constraint(equalToConstant: 200),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 12),
            right.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            right.topAnchor.constraint(equalTo: root.topAnchor),
            right.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        catRemoveButton.target = self
        catRemoveButton.action = #selector(removeCategory)
        catRemoveButton.toolTip = String(localized: "Delete the category and its snippets")
        snipAddButton.target = self
        snipAddButton.action = #selector(addSnippet)
        snipEditButton.target = self
        snipEditButton.action = #selector(editSelected)
        snipRemoveButton.target = self
        snipRemoveButton.action = #selector(deleteSelected)

        // правый клик по клипу и прочие мутации обновляют обе таблицы
        observer = NotificationCenter.default.addObserver(
            forName: .clipsDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.reload() }
        }
        Task { [weak self] in await self?.reload() }
    }

    // deinit не снимает observer: не-Sendable из deinit нельзя (Swift 6),
    // объект живёт вместе с окном настроек, блок держит weak self

    // MARK: - Редактор (ревизия 18)

    /// Панель редактирования сниппета: заголовок, поле заголовка,
    /// многострочный контент, попап плейсхолдеров, Save/Cancel.
    private func buildEditor() {
        editorStack.orientation = .vertical
        editorStack.alignment = .width
        editorStack.spacing = 8
        editorStack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 0, right: 0)
        editorStack.translatesAutoresizingMaskIntoConstraints = false
        editorStack.isHidden = true

        editorHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        editorHeader.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        editorHeader.alignment = .left

        titleField.placeholderString = String(localized: "Title")
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.delegate = self

        let titleCaption = caption(String(localized: "Title"))
        let contentCaption = caption(String(localized: "Content"))

        contentText.isRichText = false
        contentText.font = .systemFont(ofSize: 12)
        contentText.isVerticallyResizable = true
        contentText.isHorizontallyResizable = false
        contentText.autoresizingMask = [.width]
        contentText.textContainer?.widthTracksTextView = true
        contentText.delegate = self
        contentScroll.documentView = contentText
        contentScroll.hasVerticalScroller = true
        contentScroll.borderType = .bezelBorder
        contentScroll.translatesAutoresizingMaskIntoConstraints = false
        contentScroll.heightAnchor.constraint(equalToConstant: 150).isActive = true

        // Список плейсхолдеров: выбор пункта вставляет токен в позицию курсора
        insertPopup.addItem(withTitle: String(localized: "Insert placeholder…"))
        for token in ["{clipboard}", "{uuid}", "{date:HH:mm}", "{date:yyyy-MM-dd}",
                      "{date:dd.MM.yyyy}", "{date:yyyy-MM-dd HH:mm}"] {
            insertPopup.addItem(withTitle: token)
        }
        insertPopup.target = self
        insertPopup.action = #selector(insertPlaceholder(_:))

        saveButton.target = self
        saveButton.action = #selector(saveEditor)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancelEditor)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [saveButton, cancelButton])
        buttons.spacing = 8

        editorStack.addArrangedSubview(editorHeader)
        editorStack.addArrangedSubview(titleCaption)
        editorStack.addArrangedSubview(titleField)
        editorStack.addArrangedSubview(contentCaption)
        editorStack.addArrangedSubview(contentScroll)
        editorStack.addArrangedSubview(insertPopup)
        editorStack.addArrangedSubview(buttons)
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        label.alignment = .left
        return label
    }

    /// Вход в редактор извне: правый клик по клипу в меню/поиске —
    /// предзаполненное добавление в выбранную категорию.
    func beginAdd(title: String, content: String) {
        setMode(.add)
        titleField.stringValue = title
        contentText.string = content
        refreshSaveEnabled()
    }

    private func setMode(_ new: Mode) {
        mode = new
        switch new {
        case .list:
            editorStack.isHidden = true
            listStack.isHidden = false
        case .add:
            editorHeader.stringValue = String(localized: "Add Snippet")
            titleField.stringValue = ""
            contentText.string = ""
            enterEditor()
        case .edit(let snippet):
            editorHeader.stringValue = String(localized: "Edit Snippet")
            titleField.stringValue = snippet.title
            contentText.string = snippet.content
            enterEditor()
        }
        updateChrome()
    }

    private func enterEditor() {
        listStack.isHidden = true
        editorStack.isHidden = false
        insertPopup.selectItem(at: 0)
        refreshSaveEnabled()
        titleField.window?.makeFirstResponder(titleField)
    }

    @objc private func addSnippet() {
        setMode(.add)
    }

    @objc private func editSelected() {
        guard let snippet = selectedSnippet() else { return }
        setMode(.edit(snippet))
    }

    @objc private func cancelEditor() {
        setMode(.list)
    }

    /// Save активна только при непустых заголовке и контенте
    /// (для добавления — и при выбранной категории).
    private func refreshSaveEnabled() {
        let titleOK = !titleField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        let contentOK = !contentText.string.isEmpty
        switch mode {
        case .add:
            saveButton.isEnabled = titleOK && contentOK && selectedFolder() != nil
        case .edit:
            saveButton.isEnabled = titleOK && contentOK
        case .list:
            saveButton.isEnabled = false
        }
    }

    @objc private func insertPlaceholder(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem > 0, let token = sender.titleOfSelectedItem else { return }
        contentText.insertText(token, replacementRange: contentText.selectedRange())
        sender.selectItem(at: 0)
        refreshSaveEnabled()
    }

    @objc private func saveEditor() {
        let title = titleField.stringValue.trimmingCharacters(in: .whitespaces)
        let content = contentText.string
        guard !title.isEmpty, !content.isEmpty else { return }
        let store = store
        let current = mode
        Task { @MainActor [weak self] in
            do {
                switch current {
                case .add:
                    guard let folder = self?.selectedFolder() else { return }
                    _ = try await store.insertSnippet(folderID: folder.id, title: title, content: content)
                    Log.menu.info("сниппет «\(title, privacy: .public)» сохранён в «\(folder.title, privacy: .public)»")
                case .edit(let snippet):
                    try await store.updateSnippet(id: snippet.id, title: title, content: content)
                case .list:
                    return
                }
                NotificationCenter.default.post(name: .clipsDidChange, object: nil)
                self?.setMode(.list)
            } catch {
                Log.store.error("save snippet: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Таблицы

    private func configureTables() {
        let catCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        catCol.resizingMask = .autoresizingMask
        categoriesTable.addTableColumn(catCol)
        categoriesTable.headerView = nil
        categoriesTable.rowHeight = 22
        categoriesTable.delegate = self
        categoriesTable.dataSource = self

        let titleCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        titleCol.title = String(localized: "Title")
        titleCol.width = 160
        let contentCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("content"))
        contentCol.title = String(localized: "Content")
        contentCol.resizingMask = .autoresizingMask
        snippetsTable.addTableColumn(titleCol)
        snippetsTable.addTableColumn(contentCol)
        snippetsTable.rowHeight = 22
        snippetsTable.delegate = self
        snippetsTable.dataSource = self
        snippetsTable.target = self
        snippetsTable.doubleAction = #selector(editSelected)
    }

    // MARK: - Данные

    /// Перечитывает категории и сниппеты, сохраняя выделение по id;
    /// если прошлого выделения нет — выделяет первую категорию
    /// (ревизия 18: правая колонка не пустует при входе).
    func reload() async {
        let previous = selectedFolder()?.id
        do {
            self.folders = try await store.folders()
        } catch {
            Log.store.error("folders: \(error.localizedDescription, privacy: .public)")
            self.folders = []
        }
        self.categoriesTable.reloadData()
        if let previous, let idx = self.folders.firstIndex(where: { $0.id == previous }) {
            self.categoriesTable.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        } else if !self.folders.isEmpty {
            self.categoriesTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            self.categoriesTable.deselectAll(nil)
        }
        await self.loadSnippets()
        self.updateChrome()
    }

    private func loadSnippets() async {
        guard let folder = selectedFolder() else {
            snippets = []
            snippetsTable.reloadData()
            snippetsHeader.stringValue = ""
            return
        }
        do {
            snippets = try await store.snippets(folderID: folder.id)
        } catch {
            Log.store.error("snippets: \(error.localizedDescription, privacy: .public)")
            snippets = []
        }
        snippetsHeader.stringValue =
            String(format: String(localized: "snippets.in.folder"), folder.title)
        snippetsTable.reloadData()
    }

    private func selectedFolder() -> SnippetStore.Folder? {
        let row = categoriesTable.selectedRow
        guard row >= 0, row < folders.count else { return nil }
        return folders[row]
    }

    private func selectedSnippet() -> SnippetStore.Snippet? {
        let row = snippetsTable.selectedRow
        guard row >= 0, row < snippets.count else { return nil }
        return snippets[row]
    }

    /// Пустое состояние и доступность кнопок по текущему выбору.
    private func updateChrome() {
        let hasFolders = !folders.isEmpty
        emptyLabel.isHidden = hasFolders
        snippetsScroll.isHidden = !hasFolders
        catRemoveButton.isEnabled = hasFolders
        snipAddButton.isEnabled = hasFolders
        snipEditButton.isEnabled = selectedSnippet() != nil
        snipRemoveButton.isEnabled = selectedSnippet() != nil
        // в режиме добавления категория-приёмник — выделенная слева:
        // смена выделения меняет доступность Save
        if case .add = mode { refreshSaveEnabled() }
    }

    // MARK: - Категории

    /// «+»: категория создаётся сразу и переименовывается прямо в строке.
    @objc private func addCategory() {
        let store = store
        Task { @MainActor [weak self] in
            guard let self,
                  let id = try? await store.insertCategory(title: String(localized: "New Category"))
            else { return }
            NotificationCenter.default.post(name: .clipsDidChange, object: nil)
            await self.reload()
            if let idx = self.folders.firstIndex(where: { $0.id == id }) {
                self.categoriesTable.selectRowIndexes(IndexSet(integer: idx),
                                                      byExtendingSelection: false)
                self.categoriesTable.editColumn(0, row: idx, with: nil, select: true)
            }
        }
    }

    @objc private func removeCategory() {
        guard let folder = selectedFolder() else { return }
        let alert = NSAlert()
        alert.messageText = String(format: String(localized: "delete.category"), folder.title)
        alert.informativeText = String(format: String(localized: "delete.category.snippets"),
                                       snippets.count)
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let store = store
        Task { @MainActor in
            try? await store.deleteCategory(id: folder.id)
            NotificationCenter.default.post(name: .clipsDidChange, object: nil)
        }
    }

    // MARK: - Сниппеты (удаление; добавление/правка — в редакторе)

    @objc private func deleteSelected() {
        guard let snippet = selectedSnippet() else { return }
        let alert = NSAlert()
        alert.messageText = String(format: String(localized: "snippet.delete.confirm"),
                                   snippet.title)
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let store = store
        Task { @MainActor in
            try? await store.deleteSnippet(id: snippet.id)
            NotificationCenter.default.post(name: .clipsDidChange, object: nil)
        }
    }
}

// MARK: - NSTableView

extension SnippetsTab: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView == categoriesTable ? folders.count : snippets.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView == categoriesTable {
            guard row < folders.count else { return nil }
            return categoryCell(text: folders[row].title)
        }
        guard row < snippets.count else { return nil }
        let text = tableColumn?.identifier.rawValue == "title"
            ? snippets[row].title
            : snippets[row].content
        return Self.cellView(text: text)
    }

    /// Строка категории с редактируемым полем: даблклик (или editColumn
    /// после «+») переименовывает прямо в таблице (ревизия 18).
    private func categoryCell(text: String) -> NSTableCellView {
        let cell = NSTableCellView()
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingTail
        field.isEditable = true
        field.isSelectable = true
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private static func cellView(text: String) -> NSTableCellView {
        let cell = NSTableCellView()
        // В таблице — одна строка с обрезанием: переносы заменяем пробелом,
        // иначе многострочный контент расползается по соседним строкам
        let flat = text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let label = NSTextField(labelWithString: flat)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// Инлайн-переименование разрешаем только категориям.
    func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool {
        tableView == categoriesTable
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table == categoriesTable {
            Task { @MainActor [weak self] in
                await self?.loadSnippets()
                self?.updateChrome()
            }
        } else {
            updateChrome()
        }
    }
}

// MARK: - Делегаты полей редактора и переименования категории

extension SnippetsTab: NSTextFieldDelegate, NSTextViewDelegate {

    /// Живая валидация Save по полю заголовка.
    public func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSTextField === titleField { refreshSaveEnabled() }
    }

    /// Коммит переименования категории при завершении правки строки.
    public func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field !== titleField else { return }
        let row = categoriesTable.row(for: field)
        guard row >= 0, row < folders.count else { return }
        let old = folders[row].title
        let new = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != old else {
            field.stringValue = old
            return
        }
        let id = folders[row].id
        let store = store
        Task { @MainActor in
            try? await store.updateCategory(id: id, title: new)
            NotificationCenter.default.post(name: .clipsDidChange, object: nil)
        }
    }

    /// Живая валидация Save по контенту.
    public func textDidChange(_ notification: Notification) {
        refreshSaveEnabled()
    }
}
