import Foundation

/// A YouTube title such as "YOUR MOUNTAIN | 1ST SERVICE | 11TH OCTOBER 2026 |
/// CELEBRATION CHURCH INT'L", read as the sermon's name ("Your Mountain") and
/// the service ("1st service").
public struct ServiceTitle: Equatable, Sendable {
    public var sermon: String
    public var service: String?
    /// The date written in the title ("18TH OCTOBER 2026"), if any.
    public var date: Date?

    public init(sermon: String, service: String?, date: Date? = nil) {
        self.sermon = sermon
        self.service = service
        self.date = date
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
        let date = parts.lazy.compactMap(ServiceTitle.date(in:)).first
        self.init(sermon: ServiceTitle.titleCase(first), service: service.map(ServiceTitle.serviceName), date: date)
    }

    static let monthNames = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]

    /// "18TH OCTOBER 2026" or "7TH OCTOBER, 2026" as a date.
    static func date(in text: String) -> Date? {
        let words = text.uppercased()
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ")
            .map(String.init)
        guard words.count >= 3 else { return nil }
        for i in 0..<(words.count - 2) {
            let dayWord = words[i].trimmingCharacters(in: .letters)
            guard let day = Int(dayWord), (1...31).contains(day),
                  let month = monthNames.firstIndex(where: { words[i + 1].hasPrefix($0) }),
                  let year = Int(words[i + 2]), (2000...2100).contains(year)
            else { continue }
            return Naming.date(fromYYYYMMDD: String(format: "%04d%02d%02d", year, month + 1, day))
        }
        return nil
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
            // Keep roman numerals and the church's own initials.
            if ["II", "III", "IV", "CCI"].contains(w) { return w }
            if w == "MDWK" { return "Midweek" }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }.joined(separator: " ")
    }
}

/// Which stream Home leads with: the newest Sunday service, the 1st service
/// if that Sunday has more than one, otherwise simply the newest stream.
public enum StreamPicker {
    public static func thisSunday(_ streams: [StreamEntry]) -> StreamEntry? {
        let sundays = streams.filter { s in
            guard let d = s.serviceDate else { return false }
            return Naming.isSunday(d)
        }
        guard let newest = sundays.first else { return streams.first }
        let sameDay = sundays.filter { $0.serviceDate == newest.serviceDate }
        return sameDay.first { $0.title.uppercased().contains("1ST SERVICE") } ?? newest
    }
}

extension StreamEntry {
    /// The service date: YouTube's upload date, or the one in the title when
    /// the channel listing leaves it out.
    public var serviceDate: Date? {
        uploadDate.flatMap(Naming.date(fromYYYYMMDD:)) ?? ServiceTitle(title).date
    }
}
