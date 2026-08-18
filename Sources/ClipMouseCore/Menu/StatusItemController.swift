import AppKit

/// Один NSStatusItem на всё (§2). statusItem.menu не присваивается никогда:
/// при присвоенном меню button.action не вызывается и правый клик
/// перехватить нечем (§8.1).
@MainActor
public final class StatusItemController: NSObject {

    private let item: NSStatusItem
    private let menuBuilder: MenuBuilder
    private let store: ClipStore
    private let snippetsStore: SnippetStore
    private let search: SearchController
    private let prefs: Prefs
    private var observers: [NSObjectProtocol] = []
    private weak var hotkeysRef: HotKeyCenter?
    private let awake: AwakeController?
    /// Тоггл ремапа из настроек — проброс в main (ревью публикации)
    public var onMouseToggle: ((Bool) -> Void)? {
        get { menuBuilder.onMouseToggle }
        set { menuBuilder.onMouseToggle = newValue }
    }

    public init(store: ClipStore, monitor: ClipboardMonitor,
                snippetsStore: SnippetStore, search: SearchController,
                awake: AwakeController?, prefs: Prefs) {
        self.store = store
        self.snippetsStore = snippetsStore
        self.search = search
        self.awake = awake
        self.prefs = prefs
        self.menuBuilder = MenuBuilder(store: store, monitor: monitor,
                                       snippetsStore: snippetsStore, prefs: prefs)
        menuBuilder.awake = awake
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menuBuilder.onSearch = { [weak self] in self?.showSearch() }
        awake?.onStateChange = { [weak self] in
            MainActor.assumeIsolated {
                self?.syncTooltipTimer()
                self?.refreshAwakeIndicators()
            }
        }

        if let button = item.button {
            button.image = StatusIcon.make(awake: false)
            button.imageScaling = .scaleNone
            button.target = self
            button.action = #selector(click)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: .clipsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCache() }
        })

        refreshCache()
    }

    // deinit не трогает item/observers: не-Sendable из deinit нельзя (Swift 6),
    // объект живёт всё время процесса, блоки держат weak self

    private func refreshCache() {
        let store = store, snippetsStore = snippetsStore, prefs = prefs
        Task { @MainActor in
            do {
                menuBuilder.recentClips = try await store.recent(limit: prefs.historyLimit)
            } catch {
                Log.menu.error("recent: \(error.localizedDescription, privacy: .public)")
            }
            do {
                let folders = try await snippetsStore.folders()
                menuBuilder.snippetsByFolder = try await withThrowingTaskGroup(
                    of: (SnippetStore.Folder, [SnippetStore.Snippet]).self) { group in
                    for folder in folders {
                        group.addTask {
                            (folder, try await snippetsStore.snippets(folderID: folder.id))
                        }
                    }
                    var out: [(folder: SnippetStore.Folder, items: [SnippetStore.Snippet])] = []
                    for try await pair in group { out.append((pair.0, pair.1)) }
                    return out.sorted { $0.folder.title < $1.folder.title }
                }
            } catch {
                Log.menu.error("snippets: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Левый клик и ⌘⇧V — меню истории; правый клик и ⌥+клик — тумблер Awake
    /// (§8.1): любое активное состояние, включая Indefinitely, снимается
    /// тем же кликом. Модификатор читается только в момент клика.
    @objc private func click() {
        guard let event = NSApp.currentEvent, let button = item.button else { return }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .rightMouseUp || mods.contains(.option) {
            toggleAwake()
            return
        }
        syncHotkeyMode()
        capturePasteTarget()
        menuBuilder.build().popUp(positioning: nil, at: .zero, in: button)
    }

    /// Куда вставлять из меню: приложение, бывшее фронтом ДО клика по иконке
    /// (клик по статус-айтему frontmost не меняет).
    private func capturePasteTarget() {
        let front = NSWorkspace.shared.frontmostApplication
        menuBuilder.pasteTarget = front?.bundleIdentifier == "dev.zeklop.clipmouse" ? nil : front
    }

    private func toggleAwake() {
        guard let awake else { return }
        if awake.isActive {
            awake.disable()
        } else {
            awake.enable(seconds: prefs.awakeDefaultDuration)
        }
    }

    /// Обратная связь Awake: кольца иконки + toolTip. Показ остатка
    /// в тайтле убран по решению пользователя (ревизия 8.2).
    public func refreshAwakeIndicators() {
        guard let button = item.button else { return }
        let active = awake?.isActive ?? false
        button.image = StatusIcon.make(awake: active)
        if active, let rem = awake?.remaining() {
            button.toolTip = String(format: String(localized: "awake.remaining"), rem.label)
        } else if active {
            button.toolTip = String(localized: "Awake: indefinite")
        } else {
            button.toolTip = nil
        }
    }

    // MARK: Живой тултип Awake (§13.1, ревизия 13)

    /// DispatchSourceTimer на main queue: обычный Timer замирает в
    /// tracking-режиме (§2). Живёт только пока Awake активен с конечным
    /// сроком; Indefinitely — статичный тултип без таймера.
    private var tooltipTimer: DispatchSourceTimer?

    /// Старт/стоп таймера тултипа по состоянию Awake: вызывается из
    /// onStateChange. Из deinit не гасим (не-Sendable, Swift 6) —
    /// стоп всегда проходит через onStateChange самого Awake.
    private func syncTooltipTimer() {
        if awake?.isActive == true, awake?.remaining() != nil {
            startTooltipTimer()
        } else {
            stopTooltipTimer()
        }
    }

    private func startTooltipTimer() {
        stopTooltipTimer()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tooltipTick() }
        }
        t.resume()
        tooltipTimer = t
    }

    private func stopTooltipTimer() {
        tooltipTimer?.cancel()
        tooltipTimer = nil
    }

    /// Тик раз в секунду: обновляет остаток в тултипе. Паттерн как в
    /// MenuBuilder.awakeTick — стоп по выключению, истечению и нулю.
    private func tooltipTick() {
        guard let awake, awake.isActive else {
            stopTooltipTimer()
            refreshAwakeIndicators()
            return
        }
        guard let rem = awake.remaining() else {
            // стал бессрочным — статичный тултип, таймер не нужен
            stopTooltipTimer()
            refreshAwakeIndicators()
            return
        }
        guard rem.seconds > 0 else {
            // ноль: остаток гасим; кольца синхронизирует periodicCheck
            stopTooltipTimer()
            item.button?.toolTip = nil
            return
        }
        refreshAwakeIndicators()
    }

    /// Точка входа для глобального хоткея ⌘⇧V: открытая панель — закрыть,
    /// меню не открывать (§8.1).
    public func showMenu() {
        if search.isVisible {
            search.hide()
            return
        }
        guard let button = item.button else { return }
        syncHotkeyMode()
        capturePasteTarget()
        menuBuilder.build().popUp(positioning: nil, at: .zero, in: button)
    }

    /// Панель поиска: Search… из меню или тоггл.
    public func showSearch() {
        search.toggle()
    }

    /// Точка входа для хоткея ⌘⇧B — только сниппеты.
    public func showSnippetsMenu() {
        guard let button = item.button else { return }
        syncHotkeyMode()
        capturePasteTarget()
        menuBuilder.buildSnippetsMenu().popUp(positioning: nil, at: .zero, in: button)
    }

    public func setHotkeyError(_ flag: Bool) {
        menuBuilder.hotkeyError = flag
    }

    public func setMouseStatus(_ status: MenuBuilder.MouseStatus?) {
        menuBuilder.mouseStatus = status
    }

    public func setHotKeyCenter(_ center: HotKeyCenter) {
        hotkeysRef = center
    }

    /// Переключение ⌃⌥ ↔ ⌘⇧ при смене состояния ClipMenu (Фаза 2) —
    /// проверяем при каждом открытии меню, перерегистрация только по факту.
    private func syncHotkeyMode() {
        hotkeysRef?.refreshMode()
        if let hotkeysRef {
            setHotkeyError(hotkeysRef.historyError || hotkeysRef.snippetsError)
        }
    }
}
