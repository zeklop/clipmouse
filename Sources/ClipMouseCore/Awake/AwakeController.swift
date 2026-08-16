import Foundation
import IOKit.pwr_mgt

/// Awake (§9 Фаза 5): IOPMAssertion с таймаутом через CreateWithDescription
/// (TimeoutAction=Release) — переживает засыпание и смену времени, в отличие
/// от Timer. Порог батареи проверяется опросом каждые 30 с.
@MainActor
public final class AwakeController {

    public private(set) var assertionID: IOPMAssertionID = 0
    public private(set) var expiresAt: Date?
    private var pollTimer: DispatchSourceTimer?
    private let prefs: Prefs

    /// Изменение состояния (включение/выключение, любым путём).
    public var onStateChange: (() -> Void)?

    public var isActive: Bool { assertionID != 0 }

    public init(prefs: Prefs) {
        self.prefs = prefs
    }

    /// seconds == nil → Indefinitely (без таймаута).
    @discardableResult
    public func enable(seconds: Int?) -> Bool {
        disable()
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithDescription(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            "ClipMouse" as CFString,
            nil, nil, nil,
            CFTimeInterval(seconds ?? 0),
            kIOPMAssertionTimeoutActionRelease as CFString,
            &id)
        guard status == kIOReturnSuccess else {
            Log.awake.error("IOPMAssertionCreateWithDescription: \(status)")
            return false
        }
        assertionID = id
        expiresAt = seconds.map { Date().addingTimeInterval(TimeInterval($0)) }
        startPolling()
        Log.awake.info("awake включён на \(seconds.map(String.init) ?? "∞", privacy: .public) с")
        onStateChange?()
        return true
    }

    public func disable() {
        guard assertionID != 0 else { return }
        // если таймаут уже сработал, Release вернёт ошибку — это нормально
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        expiresAt = nil
        pollTimer?.cancel()
        pollTimer = nil
        Log.awake.info("awake выключен")
        onStateChange?()
    }

    /// Остаток для UI; nil — бессрочно.
    public func remaining() -> (label: String, seconds: Int)? {
        guard let expiresAt else { return nil }
        let left = max(Int(expiresAt.timeIntervalSinceNow.rounded()), 0)
        return (Self.durationLabel(left), left)
    }

    public static func durationLabel(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private func startPolling() {
        pollTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 30, repeating: 30)
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.periodicCheck() }
        }
        t.resume()
        pollTimer = t
    }

    private func periodicCheck() {
        // истечение отслеживает PM-менеджер (TimeoutAction=Release),
        // здесь синхронизируем состояние и проверяем порог батареи
        if isActive, let expiresAt, Date() >= expiresAt {
            assertionID = 0
            self.expiresAt = nil
            pollTimer?.cancel()
            pollTimer = nil
            Log.awake.info("awake истёк по таймауту")
            onStateChange?()
            return
        }
        if isActive,
           let (onBattery, percent) = PowerSource.batteryStatus(),
           onBattery, percent <= prefs.awakeBatteryThreshold {
            Log.awake.notice("батарея \(percent)% ≤ порога — awake выключается")
            disable()
        }
    }
}
