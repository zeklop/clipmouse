import AppKit

/// Непрерывный трек активаций приложений (§9 Фаза 1).
/// Источником клипа считается приложение, бывшее фронтом на момент
/// now - pollInterval; если внутри окна была смена — оба.
/// Спрашивать frontmostApplication в момент опроса нельзя:
/// скопировал пароль, нажал ⌘Tab — источник уже другой.
@MainActor
public final class SourceTracker {

    private struct Activation {
        let bundle: String
        let at: Date
    }

    private var activations: [Activation] = []
    private var observer: NSObjectProtocol?

    public init() {
        // Фронтмор на момент старта — тоже активация: без записи до первой
        // смены приложений трекер слеп, и копия из заблокированного
        // приложения (Bitwarden сразу после логина) уходит без источника
        if let front = NSWorkspace.shared.frontmostApplication,
           let bundle = front.bundleIdentifier {
            activations.append(Activation(bundle: bundle, at: Date()))
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundle = app.bundleIdentifier else { return }
            // очередь .main: уведомление приходит на главном потоке
            MainActor.assumeIsolated { self?.record(bundle) }
        }
    }

    // deinit не убирает наблюдателя: OpaquePointer/NSObjectProtocol не Sendable,
    // из deinit нельзя (Swift 6). Объект живёт всё время процесса,
    // блок держит weak self — после освобождения тихо глохнет.

    private func record(_ bundle: String) {
        activations.append(Activation(bundle: bundle, at: Date()))
        if activations.count > 64 {
            activations.removeFirst(activations.count - 64)
        }
    }

    /// Кандидаты в источники текущего содержимого буфера:
    /// всё, что активно на [now - window, now], плюс то, что было
    /// активно на левой границе окна. Первый элемент — основной источник.
    func activeSources(window: TimeInterval) -> [String] {
        let cutoff = Date().addingTimeInterval(-window)
        var inWindow: [String] = []
        var lastBefore: String?
        for a in activations where a.at >= cutoff {
            if !inWindow.contains(a.bundle) { inWindow.append(a.bundle) }
        }
        for a in activations.reversed() where a.at < cutoff {
            lastBefore = a.bundle
            break
        }
        if let lastBefore {
            if !inWindow.contains(lastBefore) {
                inWindow.insert(lastBefore, at: 0)
            } else if let idx = inWindow.firstIndex(of: lastBefore) {
                inWindow.swapAt(0, idx)
            }
        }
        return inWindow
    }
}
