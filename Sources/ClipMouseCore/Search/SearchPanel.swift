import AppKit

/// Панель поиска (§9 Фаза 3): подкласс NSPanel, canBecomeKey = true,
/// hidesOnDeactivate = false (у .nonactivatingPanel деактивации не наступает).
/// Esc → orderOut; закрытие по resignKey и глобальному клику мимо —
/// в SearchView.
@MainActor
final class SearchPanel: NSPanel {

    override var canBecomeKey: Bool { true }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
                   styleMask: [.titled, .closable, .resizable],
                   backing: .buffered, defer: false)
	        title = String(localized: "ClipMouse")
        isFloatingPanel = true
        hidesOnDeactivate = false
        level = .floating
        isReleasedWhenClosed = false
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}
