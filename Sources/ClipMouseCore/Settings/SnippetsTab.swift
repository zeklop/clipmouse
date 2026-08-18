import AppKit

/// Вкладка Snippets (ревизия 16): master-detail — слева категории,
/// справа сниппеты выбранной категории; весь CRUD сниппетов и категорий
/// живёт здесь (из меню бар-иконки управление убрано). Перечитывает данные
/// при каждом показе окна и по .clipsDidChange — правый клик по клипу
/// «сохранить как сниппет» сразу виден в таблицах.
@MainActor
final class SnippetsTab: NSObject {

    let root: NSView

    private let store: SnippetStore
    private var folders: [SnippetStore.Folder] = []
    private var snippets: [SnippetStore.Snippet] = []
    private var observer: NSObjectProtocol?

    private let categoriesTable = NSTableView()
    private let snippetsTable = NSTableView()
    private let snippetsScroll = NSScrollView()
    private let snippetsHeader = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: String(localized: "Add a category first."))
    private let catRemoveButton = NSButton(title: "−", target: nil, action: nil)
    private let snipAddButton = NSButton(title: String(localized: "+ Add"), target: nil, action: nil)
    private let snipEditButton = NSButton(title: String(localized: "Edit…"), target: nil, action: nil)
    private let snipRemoveButton = NSButton(title: "−", target: nil, action: nil)

    init(store: SnippetStore) {
        self.store = store
        self.root = NSView()
        super.init()
        configureTables()

        root.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
        snippetsHeader.font = .systemFont(ofSize: 12, weight: .semibold)

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

        // правая панель: заголовок «Snippets in …», таблица (или серый
        // лейбл при отсутствии категорий), кнопки + Add / Edit / −
        let right = NSStackView()
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 6
        right.translatesAutoresizingMaskIntoConstraints = false
        snippetsScroll.documentView = snippetsTable
        snippetsScroll.hasVerticalScroller = true
        snippetsScroll.borderType = .bezelBorder
        snippetsScroll.translatesAutoresizingMaskIntoConstraints = false
        snippetsTable.setContentHuggingPriority(.defaultLow, for: .vertical)
        snipAddButton.bezelStyle = .rounded
        snipEditButton.bezelStyle = .rounded
        snipRemoveButton.bezelStyle = .rounded
        right.addArrangedSubview(snippetsHeader)
        right.addArrangedSubview(emptyLabel)
        right.addArrangedSubview(snippetsScroll)
        right.addArrangedSubview(NSStackView(views: [snipAddButton, snipEditButton, snipRemoveButton]))

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
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    // deinit не снимает observer: не-Sendable из deinit нельзя (Swift 6),
    // объект живёт вместе с окном настроек, блок держит weak self

    private func configureTables() {
        categoriesTable.addTableColumn(
            NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title")))
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

    /// Перечитывает категории и сниппеты, сохраняя выделение по id
    /// (или выделяя первую категорию).
    func reload() {
        let store = store
        let previous = selectedFolder()?.id
        Task { @MainActor in
            do {
                self.folders = try await store.folders()
            } catch {
                Log.store.error("folders: \(error.localizedDescription, privacy: .public)")
                self.folders = []
            }
            self.categoriesTable.reloadData()
            if let previous, let idx = self.folders.firstIndex(where: { $0.id == previous }) {
                self.categoriesTable.selectRowIndexes(IndexSet(integer: idx),
                                                      byExtendingSelection: false)
            } else {
                self.categoriesTable.deselectAll(nil)
            }
            await self.loadSnippets()
            self.updateChrome()
        }
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
    }

    // MARK: - Категории

    @objc private func addCategory() {
        guard let name = Self.textDialog(message: String(localized: "New Category"),
                                         placeholder: String(localized: "Category name"))
        else { return }
        let store = store
        Task { @MainActor in
            _ = try? await store.insertCategory(title: name)
            NotificationCenter.default.post(name: .clipsDidChange, object: nil)
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

    // MARK: - Сниппеты

    @objc private func addSnippet() {
        guard let folder = selectedFolder() else { return }
        guard let (title, content) = SnippetSaver.dialog(title: "", content: "", accessory: nil)
        else { return }
        let store = store
        Task { @MainActor in
            try? await store.insertSnippet(folderID: folder.id, title: title, content: content)
            NotificationCenter.default.post(name: .clipsDidChange, object: nil)
        }
    }

    @objc private func editSelected() {
        guard let snippet = selectedSnippet() else { return }
        guard let (title, content) = SnippetSaver.dialog(title: snippet.title,
                                                         content: snippet.content,
                                                         accessory: nil)
        else { return }
        let store = store
        Task { @MainActor in
            try? await store.updateSnippet(id: snippet.id, title: title, content: content)
            NotificationCenter.default.post(name: .clipsDidChange, object: nil)
        }
    }

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

    /// Диалог имени категории: NSAlert с текстовым полем, пустое имя — отмена.
    private static func textDialog(message: String, placeholder: String) -> String? {
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
}

// MARK: - NSTableView

extension SnippetsTab: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView == categoriesTable ? folders.count : snippets.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView == categoriesTable {
            guard row < folders.count else { return nil }
            return Self.cellView(text: folders[row].title)
        }
        guard row < snippets.count else { return nil }
        let text = tableColumn?.identifier.rawValue == "title"
            ? snippets[row].title
            : snippets[row].content
        return Self.cellView(text: text)
    }

    private static func cellView(text: String) -> NSTableCellView {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table == categoriesTable {
            Task { @MainActor in
                await self.loadSnippets()
                self.updateChrome()
            }
        } else {
            updateChrome()
        }
    }
}
