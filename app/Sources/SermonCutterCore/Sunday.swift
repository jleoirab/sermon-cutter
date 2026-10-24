import Foundation

/// Everything about one Sunday's job, saved next to its downloads so the app
/// can pick up where it left off.
public struct Sunday: Codable, Equatable, Sendable {
    public var url: String
    public var info: StreamInfo?
    public var audioFile: String?
    public var videoFile: String?
    public var find: FindResult?
    /// The latest check; `videoChecked` says whether it covered the picture.
    public var quality: QualityReport?
    public var cutIn: Double?
    public var cutOut: Double?
    public var leadIn: Double = 120
    public var timings = Timings()
    public var bannerPath: String?
    public var exportPath: String?
    public var exported: RenderOutcome?
    public var verify: VerifyReport?

    public init(url: String) {
        self.url = url
    }

    /// The YouTube id, from the info or the link.
    public var id: String? {
        if let id = info?.id { return id }
        return Sunday.videoID(from: url)
    }

    /// The service date, from YouTube's upload date.
    public var date: Date? {
        guard let d = info?.uploadDate else { return nil }
        return Naming.date(fromYYYYMMDD: d)
    }

    public static func videoID(from link: String) -> String? {
        guard let comps = URLComponents(string: link.trimmingCharacters(in: .whitespaces)) else { return nil }
        if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value { return v }
        let host = comps.host ?? ""
        let parts = comps.path.split(separator: "/").map(String.init)
        if host.hasSuffix("youtu.be"), let first = parts.first { return first }
        if let i = parts.firstIndex(where: { $0 == "live" || $0 == "shorts" }), i + 1 < parts.count { return parts[i + 1] }
        return nil
    }
}

/// Where things go on disk.
public struct Folders: Equatable, Sendable {
    /// Downloads, caches and saved jobs.
    public var work: URL
    /// Documents/CCIKW/Service: one folder per Sunday with the finished sermon.
    public var service: URL

    public init(work: URL, service: URL) {
        self.work = work
        self.service = service
    }

    /// The app's own folder: ~/Library/Application Support/CCI Sermon Cutter.
    public static var appSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CCI Sermon Cutter")
    }

    /// Downloads and work files live in the app's own folder; only the
    /// finished sermon goes somewhere you'd browse.
    public static var standard: Folders {
        Folders(
            work: appSupport.appendingPathComponent("Work"),
            service: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/CCIKW/Service")
        )
    }

    /// Where downloads went before they moved into the app's own folder.
    public static var legacyWork: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/SermonCutter")
    }

    /// Moves every saved Sunday in `old` into `new`: its saved file and its
    /// downloads and work files (`<id>.*`), pointing the saved paths at the
    /// new place. Anything else in `old` stays where it is, and nothing in
    /// `new` is overwritten. Returns how many Sundays moved.
    @discardableResult
    public static func moveSundays(from old: URL, to new: URL) -> Int {
        let fm = FileManager.default
        let oldPath = old.standardizedFileURL.path, newPath = new.standardizedFileURL.path
        guard oldPath != newPath, let names = try? fm.contentsOfDirectory(atPath: oldPath) else { return 0 }
        let ids = names.filter { $0.hasSuffix(".sunday.json") }.map { String($0.dropLast(".sunday.json".count)) }
        guard !ids.isEmpty, (try? fm.createDirectory(at: new, withIntermediateDirectories: true)) != nil else { return 0 }
        let dest = Folders(work: new, service: new)
        var moved = 0
        for id in ids where !fm.fileExists(atPath: dest.saved(id).path) {
            for name in names where name.hasPrefix(id + ".") {
                let to = new.appendingPathComponent(name)
                if !fm.fileExists(atPath: to.path) {
                    try? fm.moveItem(at: old.appendingPathComponent(name), to: to)
                }
            }
            guard var sunday = dest.load(id) else { continue }
            let repoint = { (path: String?) -> String? in
                guard let path, path.hasPrefix(oldPath + "/") else { return path }
                return newPath + path.dropFirst(oldPath.count)
            }
            sunday.audioFile = repoint(sunday.audioFile)
            sunday.videoFile = repoint(sunday.videoFile)
            try? dest.save(sunday)
            moved += 1
        }
        return moved
    }

    public func file(_ id: String, _ suffix: String) -> URL {
        work.appendingPathComponent("\(id).\(suffix)")
    }

    public func audio(_ id: String) -> URL { file(id, "audio.m4a") }
    public func video(_ id: String) -> URL { file(id, "video.mp4") }
    public func soundCache(_ id: String) -> URL { file(id, "sound.json") }
    public func wordsCache(_ id: String) -> URL { file(id, "words.json") }
    public func pictureCache(_ id: String) -> URL { file(id, "picture.json") }
    public func saved(_ id: String) -> URL { file(id, "sunday.json") }

    /// Service/Oct 11th 2026
    public func sundayFolder(_ date: Date) -> URL {
        service.appendingPathComponent(Naming.folderName(date))
    }

    /// Service/Oct 11th 2026/Oct 11th Sermon.mp4
    public func sermonFile(_ date: Date) -> URL {
        sundayFolder(date).appendingPathComponent(Naming.fileName(date))
    }

    /// An image already in the Sunday's folder, if there's exactly one.
    public func suggestedBanner(_ date: Date) -> URL? {
        let dir = sundayFolder(date)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let images = names.filter { ["png", "jpg", "jpeg", "webp"].contains(($0 as NSString).pathExtension.lowercased()) }
        return images.count == 1 ? dir.appendingPathComponent(images[0]) : nil
    }

    public func save(_ sunday: Sunday) throws {
        guard let id = sunday.id else { return }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(sunday).write(to: saved(id), options: .atomic)
    }

    public func load(_ id: String) -> Sunday? {
        guard let data = try? Data(contentsOf: saved(id)) else { return nil }
        return try? JSONDecoder().decode(Sunday.self, from: data)
    }

    /// Saved jobs, newest first.
    public func savedSundays() -> [Sunday] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
        return names.filter { $0.hasSuffix(".sunday.json") }
            .compactMap { load(String($0.dropLast(".sunday.json".count))) }
            .sorted { ($0.info?.uploadDate ?? "") > ($1.info?.uploadDate ?? "") }
    }
}

/// Google Drive links to a single file.
public enum DriveLink {
    /// The file id in links like drive.google.com/file/d/<id>/view,
    /// drive.google.com/open?id=<id> or docs.google.com/uc?id=<id>.
    public static func fileID(_ link: String) -> String? {
        guard let comps = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = comps.host, host.hasSuffix("google.com")
        else { return nil }
        let parts = comps.path.split(separator: "/").map(String.init)
        if let i = parts.firstIndex(of: "d"), i + 1 < parts.count { return parts[i + 1] }
        return comps.queryItems?.first(where: { $0.name == "id" })?.value
    }

    /// Where a file shared with "anyone with the link" downloads from.
    public static func downloadURL(_ id: String) -> URL {
        URL(string: "https://drive.google.com/uc?export=download&id=\(id)")!
    }
}

/// Names the way the Service folder already uses them: "Sept 13th 2026",
/// "Oct 11th Sermon.mp4".
public enum Naming {
    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "June", "July", "Aug", "Sept", "Oct", "Nov", "Dec"]

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    public static func date(fromYYYYMMDD s: String) -> Date? {
        guard s.count == 8, let y = Int(s.prefix(4)), let m = Int(s.dropFirst(4).prefix(2)), let d = Int(s.suffix(2)) else { return nil }
        return calendar.date(from: DateComponents(year: y, month: m, day: d))
    }

    public static func ordinal(_ n: Int) -> String {
        let tens = n % 100
        if (11...13).contains(tens) { return "\(n)th" }
        switch n % 10 {
        case 1: return "\(n)st"
        case 2: return "\(n)nd"
        case 3: return "\(n)rd"
        default: return "\(n)th"
        }
    }

    /// "Oct 11th"
    public static func day(_ date: Date) -> String {
        let c = calendar.dateComponents([.month, .day], from: date)
        return "\(months[(c.month ?? 1) - 1]) \(ordinal(c.day ?? 1))"
    }

    /// "Oct 11th 2026"
    public static func folderName(_ date: Date) -> String {
        "\(day(date)) \(calendar.component(.year, from: date))"
    }

    /// "Oct 11th Sermon.mp4"
    public static func fileName(_ date: Date) -> String {
        "\(day(date)) Sermon.mp4"
    }

    /// "Oct 11"
    public static func monthDay(_ date: Date) -> String {
        let c = calendar.dateComponents([.month, .day], from: date)
        return "\(months[(c.month ?? 1) - 1]) \(c.day ?? 1)"
    }

    /// "Oct 11, 2026"
    public static func display(_ date: Date) -> String {
        "\(monthDay(date)), \(calendar.component(.year, from: date))"
    }

    public static func isSunday(_ date: Date) -> Bool {
        calendar.component(.weekday, from: date) == 1
    }

    /// "Sunday", "Wednesday"
    public static func weekday(_ date: Date) -> String {
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return names[calendar.component(.weekday, from: date) - 1]
    }
}

/// The words heard near the end of the sermon, as the engine cached them
/// while looking for "please be seated".
public struct Transcript: Codable, Sendable {
    public struct Word: Codable, Equatable, Sendable {
        /// Seconds into the stream.
        public var start: Double
        public var end: Double
        public var text: String

        public init(start: Double, end: Double, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public var words: [Word]

    public init(words: [Word]) {
        self.words = words
    }

    public static func load(_ url: URL) -> Transcript? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: data)
    }

    /// Up to `before` words ending at or before `t` and `after` words after it.
    public func around(_ t: Double, before: Int = 14, after: Int = 5) -> (before: [Word], after: [Word]) {
        let head = words.filter { $0.end <= t + 0.05 }.suffix(before)
        let tail = words.filter { $0.end > t + 0.05 }.prefix(after)
        return (Array(head), Array(tail))
    }
}

/// The export's self-check, in the few plain lines the last page shows.
public struct CheckLine: Equatable, Sendable {
    public var text: String
    public var passed: Bool
    /// The engine's own measurement, for when it failed.
    public var detail: String?
}

extension VerifyReport {
    public func lines(length: Double?) -> [CheckLine] {
        func group(_ names: [String], _ text: String) -> CheckLine? {
            let found = checks.filter { names.contains($0.name) }
            guard !found.isEmpty else { return nil }
            let failed = found.filter { !$0.passed }
            return CheckLine(text: text, passed: failed.isEmpty, detail: failed.isEmpty ? nil : failed.map(\.detail).joined(separator: "; "))
        }
        let known = ["length", "banner at start", "banner at end", "quiet start", "quiet end", "footage in the middle"]
        var out = [
            group(["length"], length.map { "The right length: \(Timecode.format($0))" } ?? "The right length"),
            group(["banner at start", "banner at end"], "The banner is on at both ends"),
            group(["quiet start", "quiet end"], "Quiet at the very start and end"),
            group(["footage in the middle"], "The sermon plays in between"),
        ].compactMap { $0 }
        for c in checks where !known.contains(c.name) && !c.passed {
            out.append(CheckLine(text: "The file's format", passed: false, detail: c.detail))
        }
        return out
    }
}
