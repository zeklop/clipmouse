import Foundation

/// Все ключи Defaults (§7), домен dev.zeklop.clipmouse. Ничего мимо.
enum DefaultsKey {
    static let historyLimit = "history.limit"
    static let historyExpireDays = "history.expireDays"
    static let historyPollInterval = "history.pollInterval"
    static let historyMaxClipTextBytes = "history.maxClipTextBytes"
    static let historyMaxBlobBytes = "history.maxBlobBytes"
    static let menuInlineCount = "menu.inlineCount"
    static let menuTitleLength = "menu.titleLength"
    static let pasteAutoAfterSelect = "paste.autoAfterSelect"
    static let pasteRestoreClipboard = "paste.restoreClipboard"
    static let hotkeyHistoryKeyCode = "hotkey.history.keyCode"
    static let hotkeyHistoryModifiers = "hotkey.history.modifiers"
    static let hotkeySnippetsKeyCode = "hotkey.snippets.keyCode"
    static let hotkeySnippetsModifiers = "hotkey.snippets.modifiers"
    static let securityBlockedSources = "security.blockedSources"
    static let securityDictationSuppressSeconds = "security.dictationSuppressSeconds"
    static let securitySecretTTLMinutes = "security.secretTTLMinutes"
    static let awakeBatteryThreshold = "awake.batteryThreshold"
    static let awakeDefaultDuration = "awake.defaultDuration"
    static let mouseEnabled = "mouse.enabled"
    static let snippetsSeeded = "snippets.seeded"
    static let didOnboard = "didOnboard"
}

/// Настройки приложения. В init регистрирует дефолты §7, дальше — чтение.
/// Чёрный список перечитывается при каждом обращении: правка из настроек
/// или через defaults write действует без перезапуска (Фаза 1).
/// Не Sendable: UserDefaults не заявляет конформность; каждый остров
/// изоляции (main, монитор) держит свой экземпляр.
public struct Prefs {
    private let d: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.d = defaults
        d.register(defaults: [
            DefaultsKey.historyLimit: 200,
            DefaultsKey.historyExpireDays: 30,
            DefaultsKey.historyPollInterval: 0.5,
            DefaultsKey.historyMaxClipTextBytes: 2_097_152,
            DefaultsKey.historyMaxBlobBytes: 20_971_520,
            DefaultsKey.menuInlineCount: 10,
            DefaultsKey.menuTitleLength: 60,
            DefaultsKey.pasteAutoAfterSelect: false,
            DefaultsKey.pasteRestoreClipboard: false,
            DefaultsKey.hotkeyHistoryKeyCode: 9,      // V
            DefaultsKey.hotkeyHistoryModifiers: 768,  // ⌘⇧ (Carbon: cmdKey 256 + shiftKey 512)
            DefaultsKey.hotkeySnippetsKeyCode: 11,    // B
            DefaultsKey.hotkeySnippetsModifiers: 768,
            DefaultsKey.securityBlockedSources: [
                "com.bitwarden.desktop",
                "com.apple.Passwords",
                "com.apple.Terminal",
            ],
            DefaultsKey.securityDictationSuppressSeconds: 5.0,
            DefaultsKey.securitySecretTTLMinutes: 60,
            DefaultsKey.awakeBatteryThreshold: 20,
            DefaultsKey.awakeDefaultDuration: 3600,
            DefaultsKey.mouseEnabled: true,
            DefaultsKey.snippetsSeeded: false,
            DefaultsKey.didOnboard: false,
        ])
    }

    var historyLimit: Int { d.integer(forKey: DefaultsKey.historyLimit) }
    var historyExpireDays: Int { d.integer(forKey: DefaultsKey.historyExpireDays) }
    var historyPollInterval: Double { d.double(forKey: DefaultsKey.historyPollInterval) }
    var historyMaxClipTextBytes: Int { d.integer(forKey: DefaultsKey.historyMaxClipTextBytes) }
    var historyMaxBlobBytes: Int { d.integer(forKey: DefaultsKey.historyMaxBlobBytes) }
    var menuInlineCount: Int { d.integer(forKey: DefaultsKey.menuInlineCount) }
    var menuTitleLength: Int { min(max(d.integer(forKey: DefaultsKey.menuTitleLength), 1), 200) }
    var pasteAutoAfterSelect: Bool { d.bool(forKey: DefaultsKey.pasteAutoAfterSelect) }
    var pasteRestoreClipboard: Bool { d.bool(forKey: DefaultsKey.pasteRestoreClipboard) }
    var hotkeyHistoryKeyCode: Int { d.integer(forKey: DefaultsKey.hotkeyHistoryKeyCode) }
    var hotkeyHistoryModifiers: Int { d.integer(forKey: DefaultsKey.hotkeyHistoryModifiers) }
    var hotkeySnippetsKeyCode: Int { d.integer(forKey: DefaultsKey.hotkeySnippetsKeyCode) }
    var hotkeySnippetsModifiers: Int { d.integer(forKey: DefaultsKey.hotkeySnippetsModifiers) }
    var blockedSources: [String] { d.stringArray(forKey: DefaultsKey.securityBlockedSources) ?? [] }
    var dictationSuppressSeconds: Double { d.double(forKey: DefaultsKey.securityDictationSuppressSeconds) }
    var secretTTLMinutes: Int { d.integer(forKey: DefaultsKey.securitySecretTTLMinutes) }
    var awakeBatteryThreshold: Int { d.integer(forKey: DefaultsKey.awakeBatteryThreshold) }
    public var awakeDefaultDuration: Int { d.integer(forKey: DefaultsKey.awakeDefaultDuration) }
    public var mouseEnabled: Bool { d.bool(forKey: DefaultsKey.mouseEnabled) }
    public var snippetsSeeded: Bool { d.bool(forKey: DefaultsKey.snippetsSeeded) }
    public var didOnboard: Bool { d.bool(forKey: DefaultsKey.didOnboard) }

    public func markOnboarded() {
        d.set(true, forKey: DefaultsKey.didOnboard)
    }

    public func markSnippetsSeeded() {
        d.set(true, forKey: DefaultsKey.snippetsSeeded)
    }

    public func setPasteAutoAfterSelect(_ value: Bool) {
        d.set(value, forKey: DefaultsKey.pasteAutoAfterSelect)
    }

    // Ревизия 9: полное окно настроек (§9 Фаза 6)
    public func setHistoryLimit(_ v: Int) {
        d.set(min(max(v, 10), 500), forKey: DefaultsKey.historyLimit)
    }

    public func setHistoryExpireDays(_ v: Int) {
        d.set(min(max(v, 1), 365), forKey: DefaultsKey.historyExpireDays)
    }

    public func setMenuInlineCount(_ v: Int) {
        d.set(min(max(v, 5), 30), forKey: DefaultsKey.menuInlineCount)
    }

    public func setMouseEnabled(_ v: Bool) {
        d.set(v, forKey: DefaultsKey.mouseEnabled)
    }

    public func setAwakeDefaultDuration(_ v: Int) {
        d.set(v, forKey: DefaultsKey.awakeDefaultDuration)
    }

    public func setAwakeBatteryThreshold(_ v: Int) {
        d.set(min(max(v, 5), 100), forKey: DefaultsKey.awakeBatteryThreshold)
    }

    public func setBlockedSources(_ list: [String]) {
        d.set(list, forKey: DefaultsKey.securityBlockedSources)
    }

    public func setSecretTTLMinutes(_ v: Int) {
        d.set(min(max(v, 5), 1440), forKey: DefaultsKey.securitySecretTTLMinutes)
    }
}
