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

    public static var standard: Folders {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Folders(
            work: home.appendingPathComponent("Movies/SermonCutter"),
            service: home.appendingPathComponent("Documents/CCIKW/Service")
        )
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
}
