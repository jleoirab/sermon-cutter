import Foundation

/// Times as the volunteer reads and types them: "1:11:36", "1:11:36.5",
/// "71:36" or plain seconds.
public enum Timecode {
    /// "1:11:36" (whole seconds), or "1:11:36.5" with `tenths`.
    public static func format(_ seconds: Double, tenths: Bool = false) -> String {
        let s = max(0, seconds)
        let whole = Int(s.rounded(.down))
        let h = whole / 3600, m = whole % 3600 / 60, sec = whole % 60
        var out = h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
        if tenths {
            let t = Int(((s - Double(whole)) * 10).rounded(.down))
            out += ".\(t)"
        }
        return out
    }

    /// Parses "1:11:36", "1:11:36.5", "71:36", "4296" or "4296.5".
    public static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (i, p) in parts.enumerated() {
            guard let v = Double(p), v >= 0 else { return nil }
            // Minutes and seconds after the first part must be under 60.
            if i > 0 && v >= 60 { return nil }
            total = total * 60 + v
        }
        return total
    }

    /// "2 h 47 min", "54 min": a stream's length at a glance.
    public static func long(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        switch (m / 60, m % 60) {
        case (0, let r): return "\(r) min"
        case (let h, 0): return "\(h) h"
        case (let h, let r): return "\(h) h \(r) min"
        }
    }

    /// "31 s", "8 min 17 s", "2 min".
    public static func span(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        switch (s / 60, s % 60) {
        case (0, let r): return "\(r) s"
        case (let m, 0): return "\(m) min"
        case (let m, let r): return "\(m) min \(r) s"
        }
    }
}
