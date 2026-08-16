import AppKit

// Иконка приложения, концепт «Utility».
// Геометрия — source of truth StatusIcon.swift (viewbox 18×18, y вниз,
// stroke 1.5, round caps); масштаб ×56, поворот −8°, тайл 1024, rx 232.
// Палитра: фон #fafafc→#e5e5ee (вертикальный градиент),
// моно #1d1d24, кольца #ff9f0a. Координаты не трогать.

let size: CGFloat = 1024
let scale: CGFloat = 56
let offset = (size - 18 * scale) / 2

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocusFlipped(true) // y вниз, как в StatusIcon

// Фон: градиент в сквиркле
let tile = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
                        xRadius: 232, yRadius: 232)
tile.addClip()
let gradient = NSGradient(
    starting: NSColor(srgbRed: 0xfa / 255, green: 0xfa / 255, blue: 0xfc / 255, alpha: 1),
    ending: NSColor(srgbRed: 0xe5 / 255, green: 0xe5 / 255, blue: 0xee / 255, alpha: 1))!
// flipped-контекст: −90 даёт вертикальный градиент сверху вниз
gradient.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -90)

// Поворот −8° вокруг центра
let t = NSAffineTransform()
t.translateX(by: 512, yBy: 512)
t.rotate(byDegrees: -8)
t.translateX(by: -512, yBy: -512)
t.concat()

let mono = NSColor(srgbRed: 0x1d / 255, green: 0x1d / 255, blue: 0x24 / 255, alpha: 1)
let orange = NSColor(srgbRed: 0xff / 255, green: 0x9f / 255, blue: 0x0a / 255, alpha: 1)

func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
    NSPoint(x: offset + x * scale, y: offset + y * scale)
}

// Лезвия
mono.setStroke()
let blades = NSBezierPath()
blades.lineWidth = 1.5 * scale
blades.lineCapStyle = .round
blades.move(to: pt(6.1, 6.0)); blades.line(to: pt(15.6, 12.3))
blades.move(to: pt(6.1, 12.0)); blades.line(to: pt(15.6, 5.7))
blades.stroke()

// Кольца: заливка оранжевая, обводка моно
for cy in [5.1, 12.9] {
    let c = pt(4.3, cy)
    let r = 2.1 * scale
    let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    orange.setFill()
    ring.fill()
    mono.setStroke()
    ring.lineWidth = 1.5 * scale
    ring.stroke()
}

// Ось
mono.setFill()
let a = pt(10.6, 9.0)
let ar = 0.85 * scale
NSBezierPath(ovalIn: NSRect(x: a.x - ar, y: a.y - ar, width: ar * 2, height: ar * 2)).fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("PNG не собрался")
}
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print("иконка: \(out)")
