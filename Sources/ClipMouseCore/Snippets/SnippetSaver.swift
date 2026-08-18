import AppKit

/// Общая точка входа «сохранить как сниппет»: правый клик по клипу в меню
/// и в панели поиска ведёт сюда, чтобы поведение не расходилось.
/// Ревизия 18: собственных диалогов больше нет — открывается инлайн-редактор
/// таба Snippets с предзаполнением (onEditRequest подключает MenuBuilder).
@MainActor
public final class SnippetSaver: NSObject {

    /// Правый клик по клипу: предзаполненный редактор добавления сниппета —
    /// заголовок — превью клипа, контент — его текст, категория — выделенная
    /// слева в табе Snippets. Тупик «нет категорий»: двухкнопочный алерт
    /// с переходом в таб Snippets — создать категорию из меню нельзя.
    public static func saveClipAsSnippet(_ clip: Clip, store: SnippetStore) {
        guard let text = clip.text, !text.isEmpty else { return }
        Task { @MainActor in
            let folders = (try? await store.folders()) ?? []
            guard !folders.isEmpty else {
                noCategoriesAlert()
                return
            }
            onEditRequest?(clip)
        }
    }

    /// Открыть инлайн-редактор сниппета с предзаполнением из клипа;
    /// подключает MenuBuilder при создании окна настроек.
    public static var onEditRequest: (@MainActor (Clip) -> Void)?

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
