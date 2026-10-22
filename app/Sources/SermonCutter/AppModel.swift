import AppKit
import Foundation
import SermonCutterCore

/// App-wide state: settings, the engine, the channel's streams and the
/// Sunday being worked on.
@MainActor
final class AppModel: ObservableObject {
    @Published var folders: Folders { didSet { saveSettings() } }
    @Published var modelPath: String { didSet { saveSettings(); rebuildEngine() } }
    @Published var tools: ToolsInfo?
    @Published var streams: [StreamEntry] = []
    @Published var streamsError: String?
    @Published var loadingStreams = false
    @Published var current: SundayModel?
    @Published var engineMissing = false

    private(set) var engine: Engine?

    init() {
        let d = UserDefaults.standard
        let std = Folders.standard
        folders = Folders(
            work: d.string(forKey: "workFolder").map { URL(fileURLWithPath: $0) } ?? std.work,
            service: d.string(forKey: "serviceFolder").map { URL(fileURLWithPath: $0) } ?? std.service
        )
        modelPath = d.string(forKey: "modelPath") ?? AppModel.defaultModel(work: std.work)
        rebuildEngine()
    }

    /// The speech model: the one in the work folder if it's there.
    static func defaultModel(work: URL) -> String {
        let candidates = [
            work.appendingPathComponent("models/ggml-small.en-q8_0.bin"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Sermon Cutter/bin/models/ggml-small.en-q8_0.bin"),
        ]
        return (candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]).path
    }

    private func saveSettings() {
        let d = UserDefaults.standard
        d.set(folders.work.path, forKey: "workFolder")
        d.set(folders.service.path, forKey: "serviceFolder")
        d.set(modelPath, forKey: "modelPath")
    }

    private func rebuildEngine() {
        guard let exe = Engine.locate() else {
            engine = nil
            engineMissing = true
            return
        }
        engineMissing = false
        engine = Engine(executable: exe, environment: Engine.environment(model: URL(fileURLWithPath: modelPath)))
    }

    func checkTools() async {
        guard let engine else { return }
        tools = try? await engine.run(["tools"]).result("tools", as: ToolsInfo.self)
    }

    func loadStreams() async {
        guard let engine, !loadingStreams else { return }
        loadingStreams = true
        streamsError = nil
        defer { loadingStreams = false }
        do {
            streams = try await engine.run(["streams", "--count", "8"]).result("streams", as: StreamList.self).streams
        } catch {
            streamsError = error.localizedDescription
        }
    }

    /// Opens a Sunday from a link: picks up a saved job for the same stream,
    /// otherwise starts a new one, and prepares it.
    func open(link: String) {
        guard let engine else { return }
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var sunday = Sunday(url: trimmed)
        if let id = sunday.id, let saved = folders.load(id) {
            sunday = saved
        }
        let model = SundayModel(sunday: sunday, engine: engine, folders: folders)
        current = model
        model.prepare()
    }

    func open(saved: Sunday) {
        guard let engine else { return }
        let model = SundayModel(sunday: saved, engine: engine, folders: folders)
        current = model
        model.prepare()
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

    func closeSunday() {
        current?.stop()
        current = nil
    }
}
