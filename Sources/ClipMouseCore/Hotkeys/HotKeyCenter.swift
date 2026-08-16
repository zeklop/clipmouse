import AppKit
import Carbon.HIToolbox
import Foundation

// Мост C-колбэков (§6, дословно): отдельная top-level функция, НЕ замыкание.
// assumeIsolated корректен: колбэки Carbon приходят на главный run loop.
private func hotKeyCallback(nextHandler: EventHandlerCallRef?, event: EventRef?,
                            userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let size = MemoryLayout<EventHotKeyID>.size
    guard GetEventParameter(event,
                            EventParamName(kEventParamDirectObject),
                            EventParamType(typeEventHotKeyID),
                            nil, size, nil, &id) == noErr else {
        return OSStatus(eventNotHandledErr)
    }
    let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
    return MainActor.assumeIsolated { center.handle(id: id.id) }
}

@MainActor
public final class HotKeyCenter {

    static let historyID: UInt32 = 1
    static let snippetsID: UInt32 = 2

    private static let signature = OSType(0x634D_6F75) // 'cmou'
    private static let clipMenuBundle = "com.naotaka.ClipMenu"

    /// Пока жив ClipMenu — временные ⌃⌥V/⌃⌥B, после снятия — постоянные
    /// ⌘⇧V/⌘⇧B из §7. Переключается автоматически (Фаза 2).
    public enum Mode: Equatable {
        case parallel   // ClipMenu запущен: ⌃⌥V / ⌃⌥B
        case permanent  // ClipMenu снят: ⌘⇧V / ⌘⇧B
    }

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private(set) var mode: Mode = .parallel
    public private(set) var historyError = false
    public private(set) var snippetsError = false

    public var onHistory: (() -> Void)?
    public var onSnippets: (() -> Void)?

    private let prefs: Prefs

    public init(prefs: Prefs) {
        self.prefs = prefs
    }

    // MARK: - Установка и переключение

    /// Регистрирует оба хоткея в актуальном режиме.
    public func install() {
        refreshMode(force: true)
    }

    /// Переключает режимы при смене состояния ClipMenu. Звать дёшево —
    /// перерегистрация только при фактическом изменении режима.
    public func refreshMode(force: Bool = false) {
        let clipMenuRunning = !NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.clipMenuBundle).isEmpty
        let newMode: Mode = clipMenuRunning ? .parallel : .permanent
        guard force || newMode != mode else { return }
        mode = newMode
        uninstallAll()

        let (historyMods, snippetsMods): (UInt32, UInt32)
        switch mode {
        case .parallel:
            historyMods = UInt32(controlKey | optionKey)
            snippetsMods = UInt32(controlKey | optionKey)
        case .permanent:
            historyMods = UInt32(prefs.hotkeyHistoryModifiers)   // ⌘⇧ = 768
            snippetsMods = UInt32(prefs.hotkeySnippetsModifiers)
        }

        installHandlerIfNeeded()
        let s1 = register(id: Self.historyID,
                          keyCode: UInt32(prefs.hotkeyHistoryKeyCode),
                          modifiers: historyMods)
        let s2 = register(id: Self.snippetsID,
                          keyCode: UInt32(prefs.hotkeySnippetsKeyCode),
                          modifiers: snippetsMods)
        historyError = s1 != noErr
        snippetsError = s2 != noErr
        if historyError { Log.hotkeys.error("RegisterEventHotKey history: OSStatus \(s1)") }
        if snippetsError { Log.hotkeys.error("RegisterEventHotKey snippets: OSStatus \(s2)") }
        Log.hotkeys.info("режим хоткеев: \(self.mode == .parallel ? "parallel (ClipMenu жив)" : "permanent", privacy: .public)")
    }

    public func uninstallAll() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard handlerInstalled == false else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), nil)
        handlerInstalled = true
    }

    private var handlerInstalled = false

    private func register(id: UInt32, keyCode: UInt32, modifiers: UInt32) -> OSStatus {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[id] = ref
        }
        return status
    }

    fileprivate func handle(id: UInt32) -> OSStatus {
        switch id {
        case Self.historyID:
            onHistory?()
            return noErr
        case Self.snippetsID:
            onSnippets?()
            return noErr
        default:
            return OSStatus(eventNotHandledErr)
        }
    }
}
