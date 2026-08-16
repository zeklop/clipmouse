import AppKit

/// Иконка ножниц (§5, вариант A — дословно).
/// Цвета резолвятся внутри drawingHandler: он вызывается по разу на каждую
/// appearance и кешируется, смена темы отрабатывает сама, KVO вреден.
enum StatusIcon {

    static func make(awake: Bool) -> NSImage {
        NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            // Лезвия
            NSColor.labelColor.setStroke()
            let blades = NSBezierPath()
            blades.lineWidth = 1.5
            blades.lineCapStyle = .round
            blades.move(to: NSPoint(x: 6.1, y: 6.0))
            blades.line(to: NSPoint(x: 15.6, y: 12.3))
            blades.move(to: NSPoint(x: 6.1, y: 12.0))
            blades.line(to: NSPoint(x: 15.6, y: 5.7))
            blades.stroke()

            // Кольца: заливка systemOrange при активном Awake, иначе пусто
            for cy in [5.1, 12.9] {
                let ring = NSBezierPath(ovalIn: NSRect(x: 4.3 - 2.1, y: cy - 2.1, width: 4.2, height: 4.2))
                if awake {
                    NSColor.systemOrange.setFill()
                    ring.fill()
                }
                NSColor.labelColor.setStroke()
                ring.lineWidth = 1.5
                ring.stroke()
            }

            // Ось
            NSColor.labelColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: 10.6 - 0.85, y: 9.0 - 0.85, width: 1.7, height: 1.7)).fill()
            return true
        }
    }
}
