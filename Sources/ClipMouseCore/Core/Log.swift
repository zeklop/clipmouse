import os

/// Единая точка логирования. Всё производное от буфера обмена —
/// только с privacy: .private (план §3).
public enum Log {
    private static let subsystem = "dev.zeklop.clipmouse"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let store = Logger(subsystem: subsystem, category: "store")
    public static let monitor = Logger(subsystem: subsystem, category: "monitor")
    public static let hotkeys = Logger(subsystem: subsystem, category: "hotkeys")
    public static let menu = Logger(subsystem: subsystem, category: "menu")
    public static let mouse = Logger(subsystem: subsystem, category: "mouse")
    public static let awake = Logger(subsystem: subsystem, category: "awake")
}
