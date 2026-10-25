import AppKit
import Foundation
import SermonCutterCore

/// App-wide state: settings, the engine, the channel's streams and the
/// Sunday being worked on.
@MainActor
final class AppModel: ObservableObject {
    @Published var folders: Folders { didSet { saveSettings() } }
    @Published var tools: ToolsInfo?
    /// The last update of the app's own yt-dlp.
    @Published var ytdlp: YtdlpUpdate?
    @Published var updatingTools = false
    @Published var streams: [StreamEntry] = []
    @Published var streamsError: String?
    @Published var loadingStreams = false
    /// The channel has been listed at least once this run.
    @Published var streamsLoaded = false
    @Published var current: SundayModel?
    @Published var engineMissing = false
    /// Sundays still exporting after going back Home, by YouTube id. Opening
    /// one again picks it up where it is.
    @Published var running: [String: SundayModel] = [:]

    private(set) var engine: Engine?

    init() {
        let d = UserDefaults.standard
        let std = Folders.standard
        var work = d.string(forKey: "workFolder").map { URL(fileURLWithPath: $0) } ?? std.work
        // Downloads used to go to Movies/SermonCutter. Unless someone chose
        // that folder on purpose, they now live in the app's own folder, and
        // the Sundays already there move across (nothing else in it does).
        if work.standardizedFileURL.path == Folders.legacyWork.standardizedFileURL.path {
            work = std.work
        }
        if work.standardizedFileURL.path == std.work.standardizedFileURL.path {
            Folders.moveSundays(from: Folders.legacyWork, to: std.work)
        }
        folders = Folders(
            work: work,
            service: d.string(forKey: "serviceFolder").map { URL(fileURLWithPath: $0) } ?? std.service
        )
        // The speech model is inside the app now; an old setting would only mislead.
        d.removeObject(forKey: "modelPath")
        saveSettings()
        rebuildEngine()
    }

    private func saveSettings() {
        let d = UserDefaults.standard
        d.set(folders.work.path, forKey: "workFolder")
        d.set(folders.service.path, forKey: "serviceFolder")
    }

    private func rebuildEngine() {
        guard let exe = Engine.locate() else {
            engine = nil
            engineMissing = true
            return
        }
        engineMissing = false
        var env = Engine.environment()
        if let b = YouTubeSignIn.current { env[YouTubeSignIn.envKey] = b }
        engine = Engine(executable: exe, environment: env)
    }

    /// For checking the screens without clicking through them: a file named
    /// ".show" in the app's own folder holding a YouTube id and a page
    /// ("cut", "quality", "export", "done", "preview") opens that saved
    /// Sunday there, "home" goes back Home, and "light", "dark" or "auto" set
    /// the appearance. The file is removed once it's read.
    func watchForShowRequests() async {
        let file = Folders.appSupport.appendingPathComponent(".show")
        while !Task.isCancelled {
            if let text = try? String(contentsOf: file, encoding: .utf8) {
                try? FileManager.default.removeItem(at: file)
                show(text.split(whereSeparator: \.isWhitespace).map(String.init))
            }
            try? await Task.sleep(for: .seconds(1.5))
        }
    }

    private func show(_ words: [String]) {
        guard let first = words.first else { return }
        switch first {
        case "light": NSApp.appearance = NSAppearance(named: .aqua); return
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua); return
        case "auto": NSApp.appearance = nil; return
        default: break
        }
        if first == "home" {
            closeSunday()
            return
        }
        if current?.sunday.id != first {
            closeSunday()
            guard let saved = folders.load(first) else { return }
            open(saved: saved)
        }
        guard let model = current, words.count > 1 else { return }
        model.endsPreview = nil
        switch words[1] {
        case "cut": model.page = .cut
        case "quality": model.page = .quality
        case "export": model.page = .export
        case "done": model.page = .done
        case "preview": model.page = .cut; model.endsPreview = words.count > 2 ? words[2] : "opening"
        default: break
        }
    }

    func checkTools() async {
        guard let engine else { return }
        tools = try? await engine.run(["tools"]).result("tools", as: ToolsInfo.self)
    }

    /// Keeps the app's own copy of yt-dlp: the first time, copies it out of
    /// the app; about once a day, lets it update itself, since YouTube keeps
    /// breaking old copies. `force` checks now.
    func updateTools(force: Bool = false) async {
        guard let engine, !updatingTools else { return }
        updatingTools = true
        defer { updatingTools = false }
        let d = UserDefaults.standard
        let last = d.object(forKey: "ytdlpCheckedAt") as? Date
        let due = force || last.map { Date().timeIntervalSince($0) > 20 * 3600 } ?? true
        let args = due ? ["update-tools"] : ["update-tools", "--no-update"]
        if let r = try? await engine.run(args).result("update_tools", as: YtdlpUpdate.self) {
            ytdlp = r
            if due && r.problem == nil { d.set(Date(), forKey: "ytdlpCheckedAt") }
        }
        await checkTools()
    }


    func loadStreams() async {
        guard let engine, !loadingStreams else { return }
        loadingStreams = true
        streamsError = nil
        defer { loadingStreams = false }
        for attempt in 0..<2 {
            do {
                streams = try await engine.run(["streams", "--count", "8"]).result("streams", as: StreamList.self).streams
                streamsLoaded = true
                return
            } catch {
                // YouTube wanted proof this isn't a robot: once, go again
                // with the browser's YouTube sign-in.
                if attempt == 0, YouTubeSignIn.handle(error, engine: engine) { continue }
                streamsError = YouTubeSignIn.isRobotCheck(error) ? YouTubeSignIn.advice : error.localizedDescription
                return
            }
        }
    }

    /// Opens a Sunday from a link: picks up a saved job for the same stream,
    /// otherwise starts a new one, and prepares it.
    func open(link: String) {
        guard let engine else { return }
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var sunday = Sunday(url: trimmed)
        if let id = sunday.id, let model = running[id] {
            current = model
            return
        }
        if let id = sunday.id, let saved = folders.load(id) {
            sunday = saved
        }
        let model = SundayModel(sunday: sunday, engine: engine, folders: folders)
        current = model
        model.prepare()
    }

    func open(saved: Sunday) {
        guard let engine else { return }
        if let id = saved.id, let model = running[id] {
            current = model
            return
        }
        let model = SundayModel(sunday: saved, engine: engine, folders: folders)
        current = model
        model.prepare()
    }

    func hasSaved(_ id: String) -> Bool {
        running[id] != nil || FileManager.default.fileExists(atPath: folders.saved(id).path)
    }

    /// Moves a saved Sunday's downloads and work files to the Trash.
    func trash(_ sunday: Sunday) {
        guard let id = sunday.id else { return }
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folders.work.path)) ?? []
        for name in names where name.hasPrefix("\(id).") {
            try? fm.trashItem(at: folders.work.appendingPathComponent(name), resultingItemURL: nil)
        }
        objectWillChange.send()
    }

    /// Back to Home. A Sunday that's exporting keeps going in the background.
    func closeSunday() {
        guard let model = current else { return }
        if model.exporting, let id = model.sunday.id {
            model.player.pause()
            running[id] = model
        } else {
            model.stop()
            if let id = model.sunday.id { running[id] = nil }
        }
        current = nil
    }
}
