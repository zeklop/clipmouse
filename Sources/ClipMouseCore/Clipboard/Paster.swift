import AppKit
import ApplicationServices
import Carbon.HIToolbox  // IsSecureEventInputEnabled

/// Вставка (§9 Фаза 3). Оба пути — и «только в буфер», и авто-⌘V —
/// через один Paster (§8.4).
@MainActor
enum Paster {

    enum PasteMode {
        case rich       // как есть
        case plain      // только текст
        case posixPath  // текст как путь
    }

    /// Кладёт клип в буфер; при включённом авто-режиме эмулирует ⌘V.
    /// Возвращает false, если вставка не состоялась (Secure Input, нет прав,
    /// таймаут активации) — вызывающий показывает подсказку.
    @discardableResult
    static func paste(_ clip: Clip, mode: PasteMode,
                      into target: NSRunningApplication?,
                      monitor: ClipboardMonitor,
                      autoAfterSelect: Bool) async -> Bool {
        Log.app.info("paster: старт auto=\(autoAfterSelect, privacy: .public) secure=\(IsSecureEventInputEnabled()) ax=\(AXIsProcessTrusted())")
        // Шаг 1. Secure Input или нет Accessibility — только буфер,
        // буфер не подменять нельзя: кладём и подсказываем (§9 Фаза 3)
        if IsSecureEventInputEnabled() || !AXIsProcessTrusted() {
            await monitor.ignoreNextChange()
            ClipboardIO.write(content(clip, mode: mode))
            Toast.show(String(localized: "Press ⌘V manually"))
            Log.app.notice("paster: выход по Secure Input или нет AX")
            return false
        }

        if !autoAfterSelect {
            await monitor.ignoreNextChange()
            ClipboardIO.write(content(clip, mode: mode))
            return true
        }

        // Шаг 2. Активировать цель и дождаться didActivateApplicationNotification
        // с совпадающим bundle id, таймаут 300 мс; таймаут → отменить вставку
        guard let target else {
            await monitor.ignoreNextChange()
            ClipboardIO.write(content(clip, mode: mode))
            Toast.show(String(localized: "Press ⌘V manually"))
            Log.app.notice("paster: цель вставки неизвестна")
            return false
        }
        let activated = await activate(target)
        Log.app.info("paster: активация \(target.bundleIdentifier ?? "?", privacy: .public) → \(activated)")
        guard activated else {
            await monitor.ignoreNextChange()
            ClipboardIO.write(content(clip, mode: mode))
            Toast.show(String(localized: "Press ⌘V manually"))
            return false
        }

        // Шаг 3. Дождаться отпускания модификаторов: остаток ⌘⇧ от хоткея
        // превратил бы ⌘V в Paste and Match Style. Шаг 10 мс, таймаут 500 мс
        let modifiersOK = await waitModifiersReleased()
        Log.app.info("paster: модификаторы отпущены = \(modifiersOK)")
        guard modifiersOK else {
            // Буфер всё равно наполняем — иначе «Press ⌘V manually»
            // предложит вставить СТАРЫЙ буфер (ревью публикации)
            await monitor.ignoreNextChange()
            ClipboardIO.write(content(clip, mode: mode))
            Toast.show(String(localized: "Press ⌘V manually"))
            return false
        }

        // Шаг 4. Монитор в игнор, клип в буфер, пауза 40 мс
        await monitor.ignoreNextChange()
        ClipboardIO.write(content(clip, mode: mode))
        try? await Task.sleep(for: .milliseconds(40))

        // Шаг 5. Синтетический ⌘V: 0x09, 60 мс между down и up, ⌘ на обоих
        postCommandV()
        Log.app.info("paster: ⌘V отправлен")

        // Шаг 6. Снять игнор через 200 мс (lastChangeCount монитор двигает сам)
        try? await Task.sleep(for: .milliseconds(200))
        return true
    }

    /// Контент по режиму.
    private static func content(_ clip: Clip, mode: PasteMode) -> Clip {
        switch mode {
        case .rich:
            return clip
        case .plain:
            let text = clip.text ?? clip.preview
            return Clip(kind: .string, hash: ClipboardIO.sha256Hex(Data(text.utf8)),
                        preview: ClipboardIO.normalizedPreview(text), text: text, blob: nil,
                        sourceBundle: nil, createdAt: Date(), lastUsedAt: Date())
        case .posixPath:
            let path = clip.text ?? clip.preview
            let url = URL(fileURLWithPath: path)
            return Clip(kind: .url, hash: ClipboardIO.sha256Hex(Data(url.absoluteString.utf8)),
                        preview: ClipboardIO.normalizedPreview(url.absoluteString),
                        text: url.absoluteString, blob: nil,
                        sourceBundle: nil, createdAt: Date(), lastUsedAt: Date())
        }
    }

    private static func activate(_ target: NSRunningApplication) async -> Bool {
        guard let wanted = target.bundleIdentifier else { return false }
        let box = ActivationBox()
        // Наблюдатель регистрируется ДО activate: иначе уведомление
        // успевает прийти раньше подписки и шаг всегда падает в таймаут
        let observer = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier else { return }
            MainActor.assumeIsolated { box.arrived(bid) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // macOS 14+: activate() без опций; ignoringOtherApps deprecated и no-op
        target.activate()

        // Цель могла активироваться мгновенно — проверяем и это
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == wanted {
            return true
        }
        // 500 мс, не 300: Electron-приложения (zcode, Chrome) активируются дольше
        return await withCheckedContinuation { cont in
            box.wait(bundle: wanted, timeout: 0.5) { ok in cont.resume(returning: ok) }
        }
    }

    private static func waitModifiersReleased() async -> Bool {
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
            if flags.intersection(relevant).isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private static func postCommandV() {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.06)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)
    }
}

/// Маленькое ожидание активации нужного приложения с таймаутом.
@MainActor
private final class ActivationBox {
    private var wantedBundle: String?
    private var handler: ((Bool) -> Void)?
    private var workItem: DispatchWorkItem?

    func arrived(_ bundle: String) {
        guard bundle == wantedBundle else { return }
        handler?(true)
        finish()
    }

    func wait(bundle: String, timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        wantedBundle = bundle
        handler = completion
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.handler?(false)
                self?.finish()
            }
        }
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)
    }

    private func finish() {
        workItem?.cancel()
        workItem = nil
        handler = nil
        wantedBundle = nil
    }
}

/// Неактивирующая всплывашка на 1.8 с.
@MainActor
enum Toast {
    private static var panel: NSPanel?

    static func show(_ text: String) {
        if let panel { panel.orderOut(nil) }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 44),
                        styleMask: [.borderless], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = NSColor.windowBackgroundColor
        p.level = .floating
        p.hasShadow = true
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.frame = NSRect(x: 8, y: 12, width: 224, height: 20)
        p.contentView?.addSubview(label)
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: visible.midX - 120, y: visible.maxY - 60))
        }
        p.orderFrontRegardless()
        panel = p
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1800))
            p.orderOut(nil)
        }
    }
}
