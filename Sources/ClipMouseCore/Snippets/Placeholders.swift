import Foundation

/// Плейсхолдеры сниппетов (§9 Фаза 2): `{date:формат}`, `{clipboard}`, `{uuid}`.
/// `{cursor}` — в бэклоге (§13).
enum Placeholders {

    /// Разворачивает шаблон. clipboardText — текущее текстовое содержимое
    /// буфера для {clipboard}.
    static func expand(_ template: String, clipboardText: String?, now: Date = Date()) -> String {
        var out = template.replacingOccurrences(of: "{clipboard}", with: clipboardText ?? "")
        out = out.replacingOccurrences(of: "{uuid}", with: UUID().uuidString)
        while let open = out.range(of: "{date:"),
              let close = out[open.upperBound...].firstIndex(of: "}") {
            let format = String(out[open.upperBound..<close])
            out.replaceSubrange(open.lowerBound...close,
                                with: formatDate(format: format, date: now))
        }
        return out
    }

    private static func formatDate(format: String, date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = format
        return f.string(from: date)
    }
}
