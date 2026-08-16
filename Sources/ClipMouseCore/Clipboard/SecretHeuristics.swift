import Foundation

/// Эвристики секретов (§12). Возвращают правило, по которому текст съеден,
/// или nil, если текст не похож на секрет.
/// К сниппетам не применяются никогда (§9 Фаза 2).
enum SecretHeuristics {

    struct Verdict: Sendable, Equatable {
        let rule: String
    }

    static func check(_ raw: String) -> Verdict? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = text.count
        guard n >= 8, n <= 256 else { return nil }

        // Точные префиксы — до всего остального
        let prefixes = [("sk-", "sk-"), ("gsk_", "gsk_"), ("ghp_", "ghp_"), ("AKIA", "akia")]
        for (p, rule) in prefixes where text.hasPrefix(p) {
            return Verdict(rule: "prefix:\(rule)")
        }
        if text.hasPrefix("-----BEGIN ") { return Verdict(rule: "pem") }

        // Луна: 15–19 цифр
        if n >= 15, n <= 19, text.allSatisfy(\.isNumber), luhnValid(text) {
            return Verdict(rule: "luhn")
        }

        // Явные не-секреты: пути и «чистый» hex длиной 7/8/40/64 (SHA)
        if text.hasPrefix("/") { return nil }
        if [7, 8, 40, 64].contains(n), text.allSatisfy(isHex) { return nil }

        // Энтропия ≥ 3.6 бит/символ и три класса символов
        if entropyPerChar(text) >= 3.6 && characterClasses(text) >= 3 {
            return Verdict(rule: "entropy")
        }
        return nil
    }

    private static func isHex(_ c: Character) -> Bool {
        c.isHexDigit
    }

    private static func luhnValid(_ digits: String) -> Bool {
        var sum = 0
        var alt = false
        for ch in digits.reversed() {
            guard var d = ch.wholeNumberValue else { return false }
            if alt {
                d *= 2
                if d > 9 { d -= 9 }
            }
            sum += d
            alt.toggle()
        }
        return sum % 10 == 0
    }

    private static func entropyPerChar(_ s: String) -> Double {
        var freq: [Character: Int] = [:]
        for ch in s { freq[ch, default: 0] += 1 }
        let total = Double(s.count)
        var h = 0.0
        for c in freq.values {
            let p = Double(c) / total
            h -= p * log2(p)
        }
        return h
    }

    private static func characterClasses(_ s: String) -> Int {
        var classes = 0
        if s.contains(where: { $0.isLowercase }) { classes += 1 }
        if s.contains(where: { $0.isUppercase }) { classes += 1 }
        if s.contains(where: { $0.isNumber }) { classes += 1 }
        if s.contains(where: { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }) { classes += 1 }
        return classes
    }
}
