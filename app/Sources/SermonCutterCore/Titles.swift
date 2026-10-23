import Foundation

/// A YouTube title such as "YOUR MOUNTAIN | 1ST SERVICE | 11TH OCTOBER 2026 |
/// CELEBRATION CHURCH INT'L", read as the sermon's name ("Your Mountain") and
/// the service ("1st service").
public struct ServiceTitle: Equatable, Sendable {
    public var sermon: String
    public var service: String?

    public init(sermon: String, service: String?) {
        self.sermon = sermon
        self.service = service
    }

    public init(_ raw: String) {
        let parts = raw.split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = parts.first else {
            self.init(sermon: ServiceTitle.titleCase(raw), service: nil)
            return
        }
        let service = parts.dropFirst().first { $0.uppercased().contains("SERVICE") }
        self.init(sermon: ServiceTitle.titleCase(first), service: service.map(ServiceTitle.serviceName))
    }

    /// "1ST SERVICE" → "1st service", "MDWK SERVICE" → "Midweek".
    static func serviceName(_ s: String) -> String {
        let up = s.uppercased()
        if up.contains("MDWK") || up.contains("MIDWEEK") { return "Midweek" }
        let words = s.split(separator: " ").map { $0.lowercased() }
        return words.joined(separator: " ")
    }

    static let small: Set<String> = ["a", "an", "and", "as", "at", "but", "by", "for", "in", "of", "on", "or", "the", "to", "vs", "with"]

    /// "WHAT IS THE ECCLESIA?" → "What Is the Ecclesia?". Words that are
    /// already mixed case are left as they are.
    public static func titleCase(_ s: String) -> String {
        let words = s.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        return words.enumerated().map { i, w in
            if w != w.uppercased() { return w }
            let lower = w.lowercased()
            if i > 0, small.contains(lower) { return lower }
            // Keep roman numerals and acronyms with dots ("II", "U.S.").
            if ["II", "III", "IV", "CCI"].contains(w) { return w }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }.joined(separator: " ")
    }
}

/// Which stream Home leads with: the newest Sunday service, the 1st service
/// if that Sunday has more than one, otherwise simply the newest stream.
public enum StreamPicker {
    public static func thisSunday(_ streams: [StreamEntry]) -> StreamEntry? {
        let sundays = streams.filter { s in
            guard let d = s.uploadDate.flatMap(Naming.date(fromYYYYMMDD:)) else { return false }
            return Naming.isSunday(d)
        }
        guard let newest = sundays.first else { return streams.first }
        let sameDay = sundays.filter { $0.uploadDate == newest.uploadDate }
        return sameDay.first { $0.title.uppercased().contains("1ST SERVICE") } ?? newest
    }
}
