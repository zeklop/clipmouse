import AppKit
import ApplicationServices
import Carbon.HIToolbox  // IsSecureEventInputEnabled
import ClipMouseCore
import CoreGraphics

// Всё, что процесс создаёт на диске (БД, -wal/-shm, дампы Backups),
// рождается с 0600 — до каких-либо chmod'ов (ревью публикации 2026-08-16)
umask(0o077)

// --selftest разбирается ДО single-instance guard:
// иначе тесты нельзя гонять при запущенном приложении
if CommandLine.arguments.contains("--selftest") {
    exit(await SelfTest.run())
}

// Диагностика Фазы 3 и спайк Ч3 — синхронные функции:
// верхний уровень main.swift асинхронный, Thread.sleep там запрещён
func runPasteTest() -> Never {
    let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true)
    down?.flags = .maskCommand
    down?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.06)
    let up = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false)
    up?.flags = .maskCommand
    up?.post(tap: .cghidEventTap)
    print("⌘V отправлен (Accessibility: \(AXIsProcessTrusted() ? "есть" : "НЕТ"))")
    exit(0)
}

// Ч3 (Фаза 4): спайк правого Command — 5 повторов down(0x100010)/up(0),
// пауза 60 мс, интервал 1 с (§9). Запускать при выключенном правиле Karabiner.
func runSpikeRightCmd() -> Never {
    let rcmd: UInt64 = 0x10 // NX_DEVICERCMDKEYMASK
    for i in 1...5 {
        let d = CGEvent(keyboardEventSource: nil, virtualKey: 0x36, keyDown: true)
        d?.flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | rcmd)
        d?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.06)
        let u = CGEvent(keyboardEventSource: nil, virtualKey: 0x36, keyDown: false)
        u?.flags = []
        u?.post(tap: .cghidEventTap)
        print("повтор \(i)/5: right Command down/up (Accessibility: \(AXIsProcessTrusted() ? "есть" : "НЕТ"))")
        fflush(stdout)
        if i < 5 { Thread.sleep(forTimeInterval: 1.0) }
    }
    exit(0)
}

if CommandLine.arguments.contains("--paste-test") { runPasteTest() }
if CommandLine.arguments.contains("--spike-right-cmd") { runSpikeRightCmd() }

// Single-instance guard (Фаза 0): вторая копия активирует первую и выходит.
// Без этого отладочная и установленная копии дадут две иконки
// и двойной правый Command (§9)
let ownPID = ProcessInfo.processInfo.processIdentifier
if let other = NSRunningApplication
    .runningApplications(withBundleIdentifier: "dev.zeklop.clipmouse")
    .first(where: { $0.processIdentifier != ownPID }) {
    other.activate()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

/// Сборка приложения (§3: тонкий исполнитель, вся логика в ClipMouseCore).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var store: ClipStore?
    private var monitor: ClipboardMonitor?
    private var snippets: SnippetStore?
    private var search: SearchController?
    private var watcher: PermissionsWatcher?
    private var awake: AwakeController?
    private var remapper: MouseRemapper?
    private var controller: StatusItemController?
    private var hotkeys: HotKeyCenter?

    func applicationDidFinishLaunching(_ notification: Notification) {
        boot()
    }

    private func boot() {
        // Ч3: спайк правого Command. Запуск: open --env CLIPMOUSE_SPIKE=1 …
        // Posting должен идти из GUI-инстанса: CLI-запуск из терминала
        // не имеет права (TCC приписывается responsible-процессу)
        if ProcessInfo.processInfo.environment["CLIPMOUSE_SPIKE"] == "1" {
            Log.app.info("спайк Ч3: запуск по CLIPMOUSE_SPIKE=1")
            runSpikeRightCmd()
        }
        // Диагностика вставки: через 4 с постит ⌘V в активное приложение.
        // За это время тест-скрипт активирует цель (TextEdit)
        if ProcessInfo.processInfo.environment["CLIPMOUSE_PASTE_TEST"] == "1" {
            Log.app.info("тест вставки: ⌘V через 4 с")
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                Log.app.info("тест вставки: ax=\(AXIsProcessTrusted()) secure=\(IsSecureEventInputEnabled())")
                let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true)
                down?.flags = .maskCommand
                down?.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.06)
                let up = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false)
                up?.flags = .maskCommand
                up?.post(tap: .cghidEventTap)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }
            }
        }
        let prefs = Prefs()
        Task { @MainActor in
            do {
                let store = try ClipStore.openDefault()
                self.store = store
                if await store.recoveredFromCorruption {
                    Self.oneShotAlert(
                        messageText: String(localized: "Clipboard history was damaged"),
                        informativeText: String(localized: "corruption.info"))
                }

                let tracker = SourceTracker()
                // Prefs не Sendable: монитор и main держат свои экземпляры
                // (дефолты регистрируются в каждом, читают один UserDefaults)
                let monitor = ClipboardMonitor(store: store, tracker: tracker, prefs: Prefs())
                self.monitor = monitor

                let snippets = try SnippetStore(path: ClipStore.defaultDatabasePath())
                // Маркер, а не пустота папок: юзер мог удалить все категории —
                // воскресать они не должны (ревью публикации 2026-08-16)
                if !prefs.snippetsSeeded {
                    try await snippets.seedInitialIfEmpty()
                    prefs.markSnippetsSeeded()
                }
                self.snippets = snippets

                let search = SearchController(store: store, monitor: monitor, prefs: Prefs(),
                                              snippetsStore: snippets)
                self.search = search

                let awake = AwakeController(prefs: Prefs())
                self.awake = awake

                let controller = StatusItemController(store: store, monitor: monitor,
                                                      snippetsStore: snippets,
                                                      search: search, awake: awake,
                                                      prefs: Prefs())
                self.controller = controller

                // URL-схема (§9 Фаза 5): /caffeine/activate, /caffeine/deactivate,
                // /settings/<tab>; один CFBundleURLTypes ничего не вызывает
                NSAppleEventManager.shared().setEventHandler(
                    self, andSelector: #selector(handleGetURL(_:replyEvent:)),
                    forEventClass: AEEventClass(kInternetEventClass),
                    andEventID: AEEventID(kAEGetURL))

                // Права: опрос раз в 2 с и на didBecomeActive; false→true —
                // пересоздать хоткеи и включить ремап (§9 Фаза 3/4)
                let remapper = MouseRemapper(prefs: Prefs(), monitor: monitor)
                self.remapper = remapper

                // Тоггл ремапа в настройках применяется сразу: start/stop
                // и честный статус в меню (ревью публикации 2026-08-16)
                controller.onMouseToggle = { [weak remapper, weak controller] on in
                    guard let remapper else { return }
                    if on {
                        if remapper.start() {
                            controller?.setMouseStatus(nil)
                        } else {
                            controller?.setMouseStatus(
                                MouseRemapper.karabinerRunning() ? .karabiner : .noAccess)
                        }
                    } else {
                        remapper.stop()
                        controller?.setMouseStatus(nil)
                    }
                }

                let watcher = PermissionsWatcher()
                watcher.onAXGranted = { [weak self, weak remapper] in
                    self?.hotkeys?.refreshMode(force: true)
                    guard let remapper else { return }
                    // выключено юзером — тап не поднимаем и не шумим про права
                    guard Prefs().mouseEnabled else { return }
                    _ = remapper.start()
                    self?.controller?.setMouseStatus(
                        MouseRemapper.karabinerRunning() ? .karabiner
                        : (remapper.active ? nil : .noAccess))
                }
                watcher.start()
                self.watcher = watcher

                if MouseRemapper.karabinerRunning() {
                    controller.setMouseStatus(.karabiner)
                } else if watcher.axGranted {
                    // выключено юзером — не «no access», просто молчим
                    if prefs.mouseEnabled, !remapper.start() {
                        controller.setMouseStatus(.noAccess)
                    }
                } else {
                    controller.setMouseStatus(.noAccess)
                }

                let hotkeys = HotKeyCenter(prefs: prefs)
                hotkeys.onHistory = { [weak controller] in controller?.showMenu() }
                hotkeys.onSnippets = { [weak controller] in controller?.showSnippetsMenu() }
                hotkeys.install()
                self.hotkeys = hotkeys
                controller.setHotKeyCenter(hotkeys)
                controller.setHotkeyError(hotkeys.historyError || hotkeys.snippetsError)

                await monitor.start()

                // Первый запуск (§9 Фаза 1): окно про иконку, приватность буфера
                // и будущий Accessibility
                if !prefs.didOnboard {
                    Self.showOnboarding()
                    prefs.markOnboarded()
                }
                Log.app.info("ClipMouse запущен")
            } catch {
                Log.app.fault("старт не удался: \(error.localizedDescription, privacy: .public)")
                Self.oneShotAlert(messageText: String(localized: "ClipMouse failed to start"),
                                  informativeText: error.localizedDescription)
            }
        }
    }

    /// clipmouse://caffeine/activate?seconds=300, /caffeine/deactivate
    /// и /settings/<tab>. seconds клампится в 60…86400, остальное игнорируется (§9 Фаза 5).
    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let raw = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: raw),
              url.scheme?.lowercased() == "clipmouse"
        else { return }
        // clipmouse://caffeine/activate → host = "caffeine", path = "/activate"
        let host = url.host?.lowercased() ?? ""
        let actions = url.pathComponents.filter { $0 != "/" }
        // clipmouse://settings/<tab> — открыть настройки на табе:
        // тесты раскладки и внешняя автоматизация
        if host == "settings", actions.count == 1 {
            let tab = SettingsWindowController.Tab(rawValue: actions[0]) ?? .general
            controller?.showSettings(tab: tab)
            return
        }
        guard host == "caffeine", actions.count == 1 else {
            Log.awake.notice("URL-схема: \(url.absoluteString, privacy: .public) игнорируется")
            return
        }
        switch actions[0] {
        case "activate":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems ?? []
            let rawSeconds = query.first { $0.name == "seconds" }?.value
            let requested = Int(rawSeconds ?? "") ?? Prefs().awakeDefaultDuration
            let clamped = min(max(requested, 60), 86_400)
            awake?.enable(seconds: clamped)
        case "deactivate":
            awake?.disable()
        default:
            Log.awake.notice("URL-схема: действие \(actions[0], privacy: .public) игнорируется")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        remapper?.stop()  // снять залипший модификатор и тап
        hotkeys?.uninstallAll()
        // Лучшее усилие: WAL переживает и жёсткий выход
        if let store { Task { await store.close() } }
        if let snippets { Task { await snippets.close() } }
    }

    private static func showOnboarding() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Welcome to ClipMouse")
        alert.informativeText = String(localized: "onboarding.text")
        alert.addButton(withTitle: String(localized: "Open Privacy Settings\u{2026}"))
        alert.addButton(withTitle: String(localized: "OK"))
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.openClipboardPrivacySettings()
        }
    }

    private static func oneShotAlert(messageText: String, informativeText: String) {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.runModal()
    }
}
