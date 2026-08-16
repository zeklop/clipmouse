import AppKit
import CoreGraphics
import Foundation

// Мост C-колбэков (§6, дословно): отдельная top-level функция, НЕ замыкание.
// assumeIsolated корректен: колбэки приходят на главный run loop —
// CFRunLoopAddSource(CFRunLoopGetMain(), …) (§9 Фаза 4).
private func mouseTapCallback(proxy: CGEventTapProxy, type: CGEventType,
                              event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let remapper = Unmanaged<MouseRemapper>.fromOpaque(refcon).takeUnretainedValue()
    // CGEvent не Sendable: в изолированный блок уходит только Int64 (§6)
    let button = event.getIntegerValueField(.mouseEventButtonNumber)
    let swallow = MainActor.assumeIsolated { remapper.handle(type: type, button: button) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

/// Ремап средней кнопки мыши → правый Command для Spokenly (§9 Фаза 4).
/// Правило захардкожено. Karabiner работает уровнем HID-драйвера ДО
/// CGEventTap: если жив — ремап не включаем.
@MainActor
public final class MouseRemapper {

    /// NX_DEVICERCMDKEYMASK (§2): маскаCommand не различает сторону,
    /// правая Command = 0x100000 | 0x10
    private static let rightCommandFlags: CGEventFlags =
        CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)

    /// Маска дословно из §9 Фазы 4 (побитовое «или» rawValue даёт мусор).
    public static let eventMask =
        CGEventMask((1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue))

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    public private(set) var active = false
    private var keyIsDown = false
    private var stuckWatchdog: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []

    private let prefs: Prefs
    private let monitor: ClipboardMonitor

    public init(prefs: Prefs, monitor: ClipboardMonitor) {
        self.prefs = prefs
        self.monitor = monitor
    }

    public static func karabinerRunning() -> Bool {
        let ids = ["org.pqrs.Karabiner-Elements", "org.pqrs.Karabiner-Elements.Menu",
                   "org.pqrs.Karabiner-EventViewer"]
        for id in ids {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
                return true
            }
        }
        return false
    }

    @discardableResult
    public func start() -> Bool {
        guard prefs.mouseEnabled else {
            Log.mouse.info("mouse.enabled = false")
            return false
        }
        if Self.karabinerRunning() {
            Log.mouse.notice("Karabiner жив — ремап не включаем (строка в меню)")
            return false
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: Self.eventMask,
            callback: mouseTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            Log.mouse.error("tapCreate == nil — нет прав (строка в меню + deep-link)")
            return false
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        runLoopSource = src
        active = true
        installLifecycleObservers()
        Log.mouse.info("ремап средней кнопки включён")
        return true
    }

    public func stop() {
        forceModifierUp()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            }
        }
        runLoopSource = nil
        tap = nil
        active = false
        stuckWatchdog?.cancel()
        stuckWatchdog = nil
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers.removeAll()
    }

    // MARK: - Обработка (главный поток)

    /// Возвращает true, если событие проглатывается.
    fileprivate func handle(type: CGEventType, button: Int64) -> Bool {
        // Реанимация тапа + принудительный up (§9 Фаза 4)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            forceModifierUp()
            return true
        }
        guard type == .otherMouseDown || type == .otherMouseUp else {
            return false
        }
        // Фильтр: только средняя кнопка, остальные события проходят дальше
        guard button == 2 else { return false }
        switch type {
        case .otherMouseDown:
            // окно подавления диктовок начинается с постинга keyDown (§9 Фаза 4)
            postRightCommand(down: true)
            keyIsDown = true
            startStuckWatchdog()
            Task { await monitor.suppressDictation(seconds: self.prefs.dictationSuppressSeconds) }
        case .otherMouseUp:
            postRightCommand(down: false)
            keyIsDown = false
            stuckWatchdog?.cancel()
            Task { await monitor.suppressDictation(seconds: self.prefs.dictationSuppressSeconds) }
        default:
            break
        }
        return true // событие проглочено
    }

    private func postRightCommand(down: Bool) {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: 0x36, keyDown: down)
        e?.flags = down ? Self.rightCommandFlags : []
        e?.post(tap: .cghidEventTap)
    }

    /// Watchdog залипшего модификатора: принудительный up через 10 с удержания.
    private func startStuckWatchdog() {
        stuckWatchdog?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 10)
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.keyIsDown else { return }
                Log.mouse.error("модификатор удержан 10 с — принудительный up")
                self.forceModifierUp()
            }
        }
        t.resume()
        stuckWatchdog = t
    }

    private func forceModifierUp() {
        guard keyIsDown else { return }
        keyIsDown = false
        postRightCommand(down: false)
    }

    /// При блокировке экрана и уходе сессии — снимать залипший модификатор.
    private func installLifecycleObservers() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.forceModifierUp() }
            })
        }
    }
}
