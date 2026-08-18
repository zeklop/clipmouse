import AppKit

/// Общий код сниппет-диалогов: правый клик по клипу в меню и в панели
/// поиска ведёт сюда, чтобы поведение не расходилось. Хранит слабую
/// ссылку на поле контента открытого диалога — плейсхолдеры вставляются
/// по клику (диалог модальный, поле одно).
@MainActor
public final class SnippetSaver: NSObject {

    /// Правый клик по клипу: предзаполненный диалог добавления сниппета —
    /// заголовок — превью клипа, контент — его текст, категория — попапом.
    /// Тупик «нет категорий» (ревизия 16): двухкнопочный алерт с переходом
    /// в таб Snippets — создать категорию из меню больше нельзя.
    public static func saveClipAsSnippet(_ clip: Clip, store: SnippetStore) {
        guard let text = clip.text, !text.isEmpty else { return }
        Task { @MainActor in
            let folders = (try? await store.folders()) ?? []
            guard !folders.isEmpty else {
                noCategoriesAlert()
                return
            }
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 24),
                                      pullsDown: false)
            for folder in folders { popup.addItem(withTitle: folder.title) }
            guard let (title, content) = dialog(title: clip.preview, content: text,
                                                accessory: popup)
            else { return }
            let folder = folders[popup.indexOfSelectedItem]
            let folderTitle = folder.title
            try? await store.insertSnippet(folderID: folder.id, title: title, content: content)
            Log.menu.info("клип сохранён как сниппет в «\(folderTitle, privacy: .public)»")
            NotificationCenter.default.post(name: .clipsDidChange, object: nil)
        }
    }

    /// Поле контента открытого диалога — для вставки плейсхолдеров по клику.
    private static weak var dialogContentField: NSTextField?

    /// Диалог «заголовок + контент» (+ опциональный выбор категории сверху
    /// и списком плейсхолдеров с вставкой по клику — ревизия 8.1).
    public static func dialog(title: String, content: String,
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
        for token in ["{clipboard}", "{uuid}", "{date:HH:mm}", "{date:yyyy-MM-dd}",
                      "{date:dd.MM.yyyy}", "{date:yyyy-MM-dd HH:mm}"] {
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

    @objc static func insertPlaceholder(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem > 0,
              let token = sender.titleOfSelectedItem else { return }
        dialogContentField?.stringValue += token
        sender.selectItem(at: 0)
    }

    /// Переход в настройки (таб Snippets) из тупика «нет категорий»;
    /// подключает MenuBuilder при создании окна настроек.
    public static var onOpenSettings: (@MainActor () -> Void)?

    /// Тупик «нет категорий»: [Open Settings] ведёт в таб Snippets,
    /// контекст клипа теряется — правый клик повторяется после создания.
    private static func noCategoriesAlert() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Add a category first.")
        alert.addButton(withTitle: String(localized: "open.settings"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            onOpenSettings?()
        }
    }
}
