import AppKit

/// Строка Awake в меню (ревизия 20): плашка с заголовком «Awake», меткой
/// остатка «ЧЧ:мм» и пилюлями 1–5 ч (при активном кофеине — с заливкой
/// активной и красной стоп-пилюлей). Дополнительные длительности — соседним
/// пунктом «Другие интервалы ▸» (фолбэк §6: popUp из активного tracking
/// меню по клику из кастомного view не рисуется — подтверждено живьём).
/// NSMenu не автосайзит кастомные view — вся геометрия вручную фреймами,
/// без auto-layout. Паттерн кликов — ClipItemView в MenuBuilder.swift.
final class AwakeRowView: NSView {

    // MARK: - Колбэки и состояние

    /// Метка остатка «ЧЧ:мм»; перерисовка только при смене значения —
    /// метка меняется раз в минуту, тик приходит чаще.
    var remainingLabel: String? {
        didSet { if remainingLabel != oldValue { needsDisplay = true } }
    }
    /// Клик по часовой пилюле, включая активную (перезапуск на ту же длительность)
    var onPick: (@MainActor (Int) -> Void)?
    /// Клик по стоп-пилюле
    var onStop: (@MainActor () -> Void)?
    /// Клик по свободной части строки — дефолтная длительность
    var onLabel: (@MainActor () -> Void)?

    private let hourSteps: [Int]
    private let activeSeconds: Int?
    private let isActive: Bool

    init(hourSteps: [Int], activeSeconds: Int?, isActive: Bool) {
        self.hourSteps = hourSteps
        self.activeSeconds = activeSeconds
        self.isActive = isActive
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("не используется") }

    // MARK: - Геометрия (константы по ТЗ §3.2)

    private static let inset: CGFloat = 10
    private static let rowHeight: CGFloat = 24
    private static let pillHeight: CGFloat = 16
    private static let pillGap: CGFloat = 4
    private static let pillPadding: CGFloat = 7
    private static let stopPadding: CGFloat = 6
    private static let labelGap: CGFloat = 8   // заголовок → метка остатка
    private static let pillsGap: CGFloat = 12  // заголовок/метка → пилюли
    private static let minWidth: CGFloat = 280 // menu.minimumWidth

    private static let titleFont = NSFont.systemFont(
        ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .medium)
    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private static let pillFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    /// Эталон ширины метки: фиксированная «00:00» с monospaced digits, чтобы
    /// фрейм не менялся на ходу (считать по текущему остатку нельзя)
    private static let labelReference = "00:00" as NSString

    override var intrinsicContentSize: NSSize {
        let titleWidth = ceil((Self.rowTitle as NSString).size(
            withAttributes: [.font: Self.titleFont]).width)
        var width = Self.inset + titleWidth
        if isActive {
            let labelWidth = ceil(Self.labelReference.size(
                withAttributes: [.font: Self.labelFont]).width)
            width += Self.labelGap + labelWidth
        }
        width += Self.pillsGap + pillsTotalWidth() + Self.inset
        return NSSize(width: max(width, Self.minWidth), height: Self.rowHeight)
    }

    private static let rowTitle = String(localized: "Awake")

    private func pillTitle(_ seconds: Int) -> String {
        String(format: String(localized: "awake.pill.hours"), seconds / 3600)
    }

    private func hourPillWidth(_ seconds: Int) -> CGFloat {
        ceil((pillTitle(seconds) as NSString).size(
            withAttributes: [.font: Self.pillFont]).width) + 2 * Self.pillPadding
    }

    private var stopIcon: NSImage? { MenuBuilder.tintedSymbol("stop.fill", color: .white) }

    private func pillsTotalWidth() -> CGFloat {
        var w: CGFloat = 0
        for step in hourSteps { w += hourPillWidth(step) + Self.pillGap }
        if isActive, let icon = stopIcon {
            w += ceil(icon.size.width) + 2 * Self.stopPadding + Self.pillGap
        }
        return max(w - Self.pillGap, 0)
    }

    /// Единственный источник прямоугольников пилюль — и для draw, и для
    /// hit-теста. Прижаты к правому краю, порядок слева направо: 1 ч … 5 ч, стоп.
    private func pillRects() -> (hours: [(seconds: Int, rect: NSRect)], stop: NSRect?) {
        let pillY = bounds.midY - Self.pillHeight / 2
        var x = max(bounds.width, intrinsicContentSize.width) - Self.inset
        var stopRect: NSRect? = nil
        if isActive, let icon = stopIcon {
            let w = ceil(icon.size.width) + 2 * Self.stopPadding
            x -= w
            stopRect = NSRect(x: x, y: pillY, width: w, height: Self.pillHeight)
            x -= Self.pillGap
        }
        var hours: [(seconds: Int, rect: NSRect)] = []
        for step in hourSteps.reversed() {
            let w = hourPillWidth(step)
            x -= w
            hours.append((step, NSRect(x: x, y: pillY, width: w, height: Self.pillHeight)))
            x -= Self.pillGap
        }
        return (hours.reversed(), stopRect)
    }

    // MARK: - Отрисовка

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = enclosingMenuItem?.isHighlighted ?? false

        // фон строки; при наведении поверх — системная подсветка выбора (как в ClipItemView)
        (isActive ? NSColor.systemOrange.withAlphaComponent(0.16)
                  : NSColor.controlAccentColor.withAlphaComponent(0.10)).setFill()
        bounds.fill()
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            bounds.fill()
        }

        // акцентная полоса 3 pt по левому краю
        (isActive ? NSColor.systemOrange : NSColor.controlAccentColor).setFill()
        NSRect(x: bounds.minX, y: bounds.minY, width: 3, height: bounds.height).fill()

        // заголовок
        let titleColor: NSColor = highlighted
            ? .selectedMenuItemTextColor
            : (isActive ? .systemOrange : .labelColor)
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.titleFont, .foregroundColor: titleColor,
        ]
        let titleX = Self.inset
        let titleSize = (Self.rowTitle as NSString).size(withAttributes: titleAttrs)
        (Self.rowTitle as NSString).draw(
            at: NSPoint(x: titleX, y: bounds.midY - titleSize.height / 2), withAttributes: titleAttrs)

        // метка остатка
        if isActive, let label = remainingLabel {
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: Self.labelFont,
                .foregroundColor: highlighted ? NSColor.selectedMenuItemTextColor : NSColor.secondaryLabelColor,
            ]
            let size = (label as NSString).size(withAttributes: labelAttrs)
            (label as NSString).draw(
                at: NSPoint(x: titleX + titleSize.width + Self.labelGap,
                            y: bounds.midY - size.height / 2),
                withAttributes: labelAttrs)
        }

        // пилюли
        let rects = pillRects()
        for (seconds, rect) in rects.hours {
            let active = isActive && seconds == activeSeconds
            let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            let textColor: NSColor
            if active {
                NSColor.systemOrange.setFill()
                path.fill()
                textColor = .white
            } else {
                NSColor.separatorColor.setStroke()
                path.lineWidth = 1
                path.stroke()
                textColor = highlighted ? .selectedMenuItemTextColor : .labelColor
            }
            let title = pillTitle(seconds) as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Self.pillFont, .foregroundColor: textColor,
            ]
            let size = title.size(withAttributes: attrs)
            title.draw(at: NSPoint(x: rect.midX - size.width / 2,
                                   y: rect.midY - size.height / 2), withAttributes: attrs)
        }
        if let stop = rects.stop {
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: stop, xRadius: 8, yRadius: 8).fill()
            if let icon = stopIcon {
                icon.draw(in: NSRect(x: stop.midX - icon.size.width / 2,
                                     y: stop.midY - icon.size.height / 2,
                                     width: icon.size.width, height: icon.size.height),
                          from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
    }

    // MARK: - Ввод

    override func mouseUp(with event: NSEvent) {
        // кнопка 0 = левая; правая (1) уходит в rightMouseUp — как в ClipItemView
        guard event.buttonNumber != 1 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let rects = pillRects()
        if let stop = rects.stop, stop.contains(p) {
            fireStop()
            return
        }
        for (seconds, rect) in rects.hours where rect.contains(p) {
            firePick(seconds)
            return
        }
        fireLabel()
    }

    override func rightMouseDown(with event: NSEvent) {
        // перехват: без обработчика меню закрыла бы пункт как обычный выбор
    }

    override func rightMouseUp(with event: NSEvent) {
        // правый клик по строке Awake ничего не делает (тумблер живёт на иконке)
    }

    private func firePick(_ seconds: Int) {
        enclosingMenuItem?.menu?.cancelTracking()
        let cb = onPick
        Task { @MainActor in cb?(seconds) }
    }

    private func fireStop() {
        enclosingMenuItem?.menu?.cancelTracking()
        let cb = onStop
        Task { @MainActor in cb?() }
    }

    private func fireLabel() {
        enclosingMenuItem?.menu?.cancelTracking()
        let cb = onLabel
        Task { @MainActor in cb?() }
    }

    // MARK: - Доступность (специфика AppKit: методы и оверрайды, не свойства)

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityLabel() -> String? {
        if isActive {
            if let label = remainingLabel {
                return String(format: String(localized: "awake.remaining"), label)
            }
            return String(localized: "Awake: indefinite")
        }
        return String(localized: "awake.row.off")
    }

    override func accessibilityPerformPress() -> Bool {
        // при активном кофеине press ничего не делает (как onLabel)
        guard !isActive else { return true }
        fireLabel()
        return true
    }

    @MainActor
    private final class AXAction: NSObject {
        private let handler: () -> Bool
        init(_ handler: @escaping () -> Bool) { self.handler = handler }
        // AX-действия по строкам меню AppKit диспатчит на главном потоке —
        // граница unchecked, как у @objc-методов ClipItemView
        @objc func axPerform() -> Bool { handler() }
    }
    /// Таргеты кастомных действий держим живыми, пока view доступна
    private var axTargets: [AXAction] = []

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        var actions: [NSAccessibilityCustomAction] = []
        var targets: [AXAction] = []
        for (seconds, _) in pillRects().hours {
            let target = AXAction { [weak self] in self?.firePick(seconds); return true }
            targets.append(target)
            actions.append(NSAccessibilityCustomAction(
                name: pillTitle(seconds), target: target, selector: #selector(AXAction.axPerform)))
        }
        if isActive {
            let stopTarget = AXAction { [weak self] in self?.fireStop(); return true }
            targets.append(stopTarget)
            actions.append(NSAccessibilityCustomAction(
                name: String(localized: "awake.ax.stop"),
                target: stopTarget, selector: #selector(AXAction.axPerform)))
        }
        // «Другие интервалы» отдельным пунктом меню — доступно VoiceOver
        // нативно, кастомное действие не нужно
        axTargets = targets
        return actions
    }
}
