import AppKit
import Foundation

/// Монитор буфера обмена (§9 Фаза 1).
/// DispatchSourceTimer, не Timer: Timer в .default замирает при открытом
/// NSMenu, в .common — перевыстреливает (замерено, §2).
/// Фильтры живут здесь с Фазы 1, не в поздней фазе.
public actor ClipboardMonitor {

    private let store: ClipStore
    private let tracker: SourceTracker
    private let prefs: Prefs
    private var timer: DispatchSourceTimer?
    private var lastChangeCount: Int
    private var ignoreNext = false
    /// Окно подавления диктовок (§9 Фаза 4): Spokenly вставляет через буфер,
    /// frontmost в этот момент — целевое приложение, чёрный список не поможет.
    private var suppressUntil: Date?

    /// Последняя чистка истёкших временных клипов (TTL секретов).
    /// nil — ещё не было: первый tick чистит сразу (истёкшие за время,
    /// пока приложение не работало, не должны показываться).
    private var lastPurge: Date?

    public init(store: ClipStore, tracker: SourceTracker, prefs: Prefs) {
        self.store = store
        self.tracker = tracker
        self.prefs = prefs
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    public func start() {
        let t = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "dev.zeklop.clipmouse.monitor", qos: .utility))
        t.schedule(deadline: .now(), repeating: max(prefs.historyPollInterval, 0.1))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.tick() }
        }
        t.resume()
        timer = t
        Log.monitor.info("монитор запущен, интервал \(self.prefs.historyPollInterval)")
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Перед собственной записью в буфер (выбор пункта меню):
    /// иначе монитор поймает свою же запись как новый клип.
    func ignoreNextChange() {
        ignoreNext = true
    }

    /// Не сохранять новые клипы до указанного момента (dictationSuppressSeconds).
    func suppressDictation(seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        if let current = suppressUntil, current > until { return }
        suppressUntil = until
    }

    private func tick() async {
        // Периодическая чистка истёкших временных клипов (раз в 60 с)
        if lastPurge.map({ Date().timeIntervalSince($0) >= 60 }) ?? true {
            lastPurge = Date()
            if let purged = try? await store.purgeExpired(), purged > 0 {
                Log.monitor.info("удалено истёкших временных клипов: \(purged)")
                NotificationCenter.default.post(name: .clipsDidChange, object: nil)
            }
        }

        let pb = NSPasteboard.general
        let cc = pb.changeCount
        guard cc != lastChangeCount else { return }
        lastChangeCount = cc

        if ignoreNext {
            ignoreNext = false
            return
        }

        // Окно подавления: changeCount двигается, клипы не сохраняются
        if let suppressUntil, Date() < suppressUntil {
            return
        }

        guard var clip = ClipboardIO.read(from: pb, prefs: prefs) else { return }

        // Источники: кто был фронтом на now - pollInterval и позже (§9 Фаза 1)
        let window = prefs.historyPollInterval + 0.1
        let sources = await tracker.activeSources(window: window)

        // Чёрный список: блокируем, если хоть один источник окна в списке
        if let blocked = sources.first(where: { prefs.blockedSources.contains($0) }) {
            Log.monitor.notice("пропущен источник из чёрного списка: \(blocked, privacy: .public)")
            return
        }
        clip.sourceBundle = sources.first

        // Эвристики секретов — только для текста (§12): сохраняем сразу,
        // но временным клипом с TTL из настроек; по истечении purge
        // уберёт его из БД и меню.
        if clip.kind == .string, let text = clip.text,
           let verdict = SecretHeuristics.check(text) {
            let ttl = TimeInterval(max(prefs.secretTTLMinutes, 1) * 60)
            clip.expiresAt = Date().addingTimeInterval(ttl)
            Log.monitor.info(
                "сохранено как временный секрет (\(verdict.rule, privacy: .public), длина \(text.count), TTL \(Int(ttl)) с)")
        }

        do {
            try await store.upsert(clip, limit: prefs.historyLimit,
                                   expireDays: prefs.historyExpireDays)
            NotificationCenter.default.post(name: .clipsDidChange, object: nil)
        } catch {
            Log.store.error("upsert: \(error.localizedDescription, privacy: .public)")
        }
    }
}
