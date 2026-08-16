import AppKit
import ApplicationServices

public enum Permissions {

    /// System Settings → Privacy & Security → Clipboard (macOS 15.4+).
    public static func openClipboardPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Clipboard")!
        NSWorkspace.shared.open(url)
    }

    /// System Settings → Privacy & Security → Accessibility.
    public static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// System Settings → Privacy & Security → Input Monitoring (не нужен,
    /// гейт снимается Accessibility — оставлено для диагностики, §2).
    public static func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }
}

/// Наблюдатель прав (§9 Фаза 3): опрос раз в 2 с и на didBecomeActive;
/// переход false→true пересоздаёт тап и хоткеи без перезапуска.
/// axWasGrantedOnce — файл-маркер в Application Support/ClipMouse:
/// ключей Defaults сверх §7 не заводим.
@MainActor
public final class PermissionsWatcher {

    private var timer: DispatchSourceTimer?
    private var becameActiveObserver: NSObjectProtocol?
    private var stickyAlertShown = false

    public private(set) var axGranted = AXIsProcessTrusted()
    public private(set) var postEventGranted = CGPreflightPostEventAccess()

    /// false → true по Accessibility: пересоздать тап и хоткеи.
    public var onAXGranted: (() -> Void)?

    public init() {
        becameActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    deinit {
        // Наблюдатель и таймер живут дольше процесса; таймер cancel безопасен?
        // deinit не может трогать не-Sendable — cleanup не делаем (объект один на процесс)
    }

    public func start() {
        Log.app.info("AX при старте: \(self.axGranted ? "выдан" : "нет", privacy: .public)")
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.poll() }
        }
        t.resume()
        timer = t
    }

    public func poll() {
        let ax = AXIsProcessTrusted()
        postEventGranted = CGPreflightPostEventAccess()

        if ax && !axGranted {
            markGrantedOnce()
            axGranted = true
            Log.app.info("Accessibility выдан — пересоздаём тап и хоткеи")
            onAXGranted?()
        } else if ax {
            axGranted = true
        }

        // Залипшая TCC-запись при смене подписи (§9 Фаза 3):
        // раньше было право, теперь его нет — лечится пересозданием строки
        if !ax && grantedOnceMarkerExists() && !stickyAlertShown {
            stickyAlertShown = true
            let alert = NSAlert()
	            alert.messageText = String(localized: "Accessibility permission is stale")
	            alert.informativeText = String(localized: "permissions.stale.info")
	            alert.addButton(withTitle: String(localized: "Request"))
	            alert.addButton(withTitle: String(localized: "Open Settings"))
	            alert.addButton(withTitle: String(localized: "Later"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                // системный запрос: TCC-запись создаётся по csreq приложения
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            case .alertSecondButtonReturn:
                Permissions.openAccessibilitySettings()
            default:
                break
            }
        }
        axGranted = ax
    }

    // MARK: - Маркер «право когда-то было»

    private static var markerURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("ClipMouse/.ax-granted")
    }

    private func markGrantedOnce() {
        FileManager.default.createFile(atPath: Self.markerURL.path, contents: nil)
    }

    private func grantedOnceMarkerExists() -> Bool {
        FileManager.default.fileExists(atPath: Self.markerURL.path)
    }
}
