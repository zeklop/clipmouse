import ApplicationServices
import CoreGraphics
import Foundation

// Ч3 (§9 Фаза 3/4): спайк правого Command для Spokenly.
// Постит зеркальную пару keyDown/keyUp виртуального кода 0x36 (правая Command)
// с флагами 0x100010 (maskCommand | NX_DEVICERCMDKEYMASK) на down и 0 на up,
// пауза 60 мс, 5 повторов с интервалом 1 с.
//
// Запускает ЧЕЛОВЕК при ВЫКЛЮЧЕННОМ правиле Karabiner. Spokenly должен
// включить и выключить запись диктовки на каждый повтор → SPIKE=green.

let NX_DEVICERCMDKEYMASK: UInt64 = 0x10

guard AXIsProcessTrusted() else {
    print("НЕТ ПРАВ: Accessibility не выдан процессу, запускающему спайк.")
    print("Правый Command не дойдёт до системы. Запустите из терминала,")
    print("которому выдана Accessibility, или выдайте права спайку.")
    exit(2)
}

print("Спайк правого Command: 5 повторов, down=0x100010, up=0, пауза 60 мс")
print("Правило Karabiner должно быть выключено. Смотрите на реакцию Spokenly.\n")

for i in 1...5 {
    let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x36, keyDown: true)
    down?.flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | NX_DEVICERCMDKEYMASK)
    down?.post(tap: .cghidEventTap)

    usleep(60_000)

    let up = CGEvent(keyboardEventSource: nil, virtualKey: 0x36, keyDown: false)
    up?.flags = []
    up?.post(tap: .cghidEventTap)

    print("повтор \(i)/5: right Command down/up отправлены")
    fflush(stdout)
    if i < 5 { usleep(1_000_000) }
}

print("\nГотово. Spokenly реагировал на каждый повтор — спайк зелёный.")
print("Не реагировал или двойные срабатывания — спайк красный.")
