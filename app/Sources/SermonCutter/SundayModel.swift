import AVFoundation
import AppKit
import Foundation
import SermonCutterCore

enum StepState: Equatable {
    case waiting
    case running(Double?)
    case done
    case failed(String)
}

struct Step: Identifiable, Equatable {
    let id: String
    let title: String
    var state: StepState = .waiting
    /// A few words on what's happening or what came out.
    var detail: String?
}

/// One Sunday's job: preparing the stream, the cut being reviewed, and the
/// export.
@MainActor
final class SundayModel: ObservableObject {
    @Published var sunday: Sunday
    @Published var steps: [Step] = [
        Step(id: "info", title: "Stream"),
        Step(id: "audio", title: "Audio"),
        Step(id: "find", title: "Sermon found"),
        Step(id: "sound", title: "Sound checked"),
        Step(id: "video", title: "Video"),
        Step(id: "picture", title: "Picture checked"),
    ]
    @Published var playhead: Double = 0
    @Published var loudness: Loudness?
    @Published var checking = false
    @Published var exporting = false
    @Published var exportProgress: Double?
    @Published var exportError: String?
    @Published var problem: String?

    let engine: Engine
    let folders: Folders
    let player = AVPlayer()
    private var tasks: [Task<Void, Never>] = []
    private var timeObserver: Any?
    private var loadedMedia: String?

    init(sunday: Sunday, engine: Engine, folders: Folders) {
        self.sunday = sunday
        self.engine = engine
        self.folders = folders
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
        ) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, t.seconds.isFinite else { return }
                self.playhead = t.seconds
            }
        }
        if let id = sunday.id {
            loudness = Loudness.load(folders.soundCache(id))
        }
        loadMedia()
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    // MARK: - Facts the views use

    var title: String { sunday.info?.title ?? sunday.url }
    var dateText: String? { sunday.date.map { Naming.folderName($0) } }
    var duration: Double {
        if let d = sunday.find?.streamSeconds ?? sunday.info?.duration { return d }
        let d = player.currentItem?.duration.seconds ?? 0
        return d.isFinite && d > 1 ? d : 1
    }
    var preparing: Bool { steps.contains { if case .running = $0.state { return true } else { return false } } }
    var hasVideo: Bool { sunday.videoFile.map { FileManager.default.fileExists(atPath: $0) } ?? false }
    var exportURL: URL? { sunday.date.map { folders.sermonFile($0) } }

    /// Whether the last check covered a different cut than the current one.
    var qualityIsStale: Bool {
        guard let q = sunday.quality, let a = sunday.cutIn, let b = sunday.cutOut else { return false }
        return abs(q.cutIn - a) > 0.5 || abs(q.cutOut - b) > 0.5
    }

    var canExport: Bool {
        hasVideo && sunday.bannerPath != nil && sunday.cutIn != nil && sunday.cutOut != nil && !exporting
    }

    // MARK: - Preparing

    func prepare() {
        let t = Task { await self.runPrepare() }
        tasks.append(t)
    }

    private func set(_ id: String, _ state: StepState, detail: String? = nil) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[i].state = state
        if let detail { steps[i].detail = detail }
    }

    /// Passes the engine's progress on to the step it belongs to.
    private func progress(_ map: [String: (String, String)]) -> @Sendable (EngineEvent) -> Void {
        { [weak self] event in
            guard event.event == "progress", let s = event.step, let target = map[s], let model = self else { return }
            let f = event.fraction
            Task { @MainActor in model.set(target.0, .running(f), detail: target.1) }
        }
    }

    private func save() {
        try? folders.save(sunday)
    }

    private func runPrepare() async {
        var current = "info"
        do {
            if sunday.info == nil {
                set("info", .running(nil), detail: "reading the stream")
                sunday.info = try await engine.run(["info", sunday.url]).result("info", as: StreamInfo.self)
                save()
            }
            set("info", .done, detail: dateText ?? sunday.info?.title)
            guard let id = sunday.id else { throw EngineError.failed(step: "info", message: "That doesn't look like a YouTube link.") }
            try FileManager.default.createDirectory(at: folders.work, withIntermediateDirectories: true)
            if sunday.bannerPath == nil, let d = sunday.date, let b = folders.suggestedBanner(d) {
                sunday.bannerPath = b.path
                save()
            }

            current = "audio"
            let audio = try await fetch(id, part: "audio")
            sunday.audioFile = audio.path
            save()
            if !hasVideo { loadMedia() }

            // The video downloads while the audio is analysed.
            async let video: URL? = fetchVideoQuietly(id)

            current = "find"
            try await findSermon(id, audio: audio)
            current = "sound"
            try await check(includePicture: false)

            current = "video"
            guard let v = await video else { return }
            sunday.videoFile = v.path
            save()
            loadMedia()
            current = "picture"
            try await check(includePicture: true)
        } catch is CancellationError {
        } catch {
            set(current, .failed(error.localizedDescription))
            problem = error.localizedDescription
        }
    }

    /// The audio or video file, downloading it only if it isn't here yet.
    private func fetch(_ id: String, part: String) async throws -> URL {
        let local = part == "audio" ? folders.audio(id) : folders.video(id)
        if FileManager.default.fileExists(atPath: local.path) {
            set(part, .done, detail: "already downloaded")
            return local
        }
        set(part, .running(0), detail: "downloading")
        let run = try await engine.run(
            ["fetch", sunday.url, "--dir", folders.work.path, "--part", part],
            onEvent: progress(["fetch_\(part)": (part, "downloading")])
        )
        let file = try run.result("fetch_\(part)", as: FileResult.self).file
        set(part, .done, detail: "downloaded")
        return URL(fileURLWithPath: file)
    }

    private func fetchVideoQuietly(_ id: String) async -> URL? {
        do {
            return try await fetch(id, part: "video")
        } catch {
            set("video", .failed(error.localizedDescription))
            return nil
        }
    }

    private func findSermon(_ id: String, audio: URL) async throws {
        if sunday.find == nil {
            set("find", .running(nil), detail: "measuring the sound")
            let run = try await engine.run(
                [
                    "find", audio.path,
                    "--lead-in", Engine.number(sunday.leadIn),
                    "--cache", folders.soundCache(id).path,
                    "--transcript-cache", folders.wordsCache(id).path,
                ],
                onEvent: progress([
                    "find_listen": ("find", "measuring the sound"),
                    "find_words": ("find", "listening for “please be seated”"),
                ])
            )
            let found = try run.result("find", as: FindResult.self)
            sunday.find = found
            sunday.cutIn = found.cutIn
            sunday.cutOut = found.cutOut
            save()
        }
        loudness = Loudness.load(folders.soundCache(id))
        if let a = sunday.cutIn, let b = sunday.cutOut {
            set("find", .done, detail: "\(Timecode.format(a)) to \(Timecode.format(b))")
        }
    }

    /// Checks the current cut: the sound, and the picture too when asked
    /// and the video is here.
    func check(includePicture: Bool) async throws {
        guard let id = sunday.id, let audio = sunday.audioFile, let a = sunday.cutIn, let b = sunday.cutOut else { return }
        let step = includePicture ? "picture" : "sound"
        let withPicture = includePicture && hasVideo
        if let q = sunday.quality, !qualityIsStale, q.videoChecked || !withPicture {
            set(step, .done, detail: q.headline)
            if !withPicture || q.videoChecked { set("sound", .done, detail: q.headline) }
            return
        }
        set(step, .running(nil), detail: includePicture ? "scanning the picture" : "listening for dropouts")
        checking = true
        defer { checking = false }
        var args = [
            "check", audio,
            "--in", Engine.number(a), "--out", Engine.number(b),
            "--cache", folders.soundCache(id).path,
        ]
        if withPicture, let v = sunday.videoFile {
            args += ["--video", v, "--picture-cache", folders.pictureCache(id).path]
        } else {
            args.append("--no-video")
        }
        let report = try await engine.run(args, onEvent: progress([
            "check_listen": (step, "measuring the sound"),
            "check_picture": (step, "scanning the picture"),
        ])).result("check", as: QualityReport.self)
        sunday.quality = report
        save()
        set(step, .done, detail: report.headline)
    }

    /// Checks again after In or Out moved.
    func recheck() {
        let t = Task {
            do {
                try await check(includePicture: hasVideo)
            } catch {
                problem = error.localizedDescription
            }
        }
        tasks.append(t)
    }

    // MARK: - Playing

    private func loadMedia() {
        let path = hasVideo ? sunday.videoFile : sunday.audioFile
        guard let path, path != loadedMedia, FileManager.default.fileExists(atPath: path) else { return }
        let keep = player.currentTime()
        let hadMedia = loadedMedia != nil
        player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: path)))
        loadedMedia = path
        if hadMedia, keep.seconds > 0 {
            player.seek(to: keep, toleranceBefore: .zero, toleranceAfter: .zero)
        } else if let a = sunday.cutIn {
            seek(a)
        }
    }

    func seek(_ t: Double) {
        let clamped = max(0, min(t, duration))
        playhead = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlay() {
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
    }

    // MARK: - Editing the cut

    func setIn(_ t: Double) {
        let limit = (sunday.cutOut ?? duration) - 60
        sunday.cutIn = max(0, min(t, limit))
        save()
    }

    func setOut(_ t: Double) {
        let floor = (sunday.cutIn ?? 0) + 60
        sunday.cutOut = min(duration, max(t, floor))
        save()
    }

    /// Puts In the lead-in's length before the preacher starts.
    func applyLeadIn(_ seconds: Double) {
        sunday.leadIn = max(0, seconds)
        if let f = sunday.find {
            setIn(Double(f.preacherStarts) - sunday.leadIn)
        }
        save()
    }

    func setBanner(_ url: URL) {
        sunday.bannerPath = url.path
        save()
    }

    func setTimings(_ t: Timings) {
        sunday.timings = t
        save()
    }

    func resetCut() {
        guard let f = sunday.find else { return }
        sunday.cutIn = f.cutIn
        sunday.cutOut = f.cutOut
        save()
    }

    // MARK: - Exporting

    func export(overwrite: Bool) {
        guard canExport, let video = sunday.videoFile, let banner = sunday.bannerPath,
              let a = sunday.cutIn, let b = sunday.cutOut, let out = exportURL
        else { return }
        exporting = true
        exportProgress = 0
        exportError = nil
        let t = Task {
            defer { exporting = false }
            do {
                try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                var args = [
                    "render", "--source", video, "--banner", banner,
                    "--in", Engine.number(a), "--out", Engine.number(b),
                    "-o", out.path,
                ] + sunday.timings.arguments
                if overwrite { args.append("--overwrite") }
                let run = try await engine.run(args, keepResults: true) { [weak self] event in
                    guard event.event == "progress", event.step == "render", let f = event.fraction, let model = self else { return }
                    Task { @MainActor in model.exportProgress = f }
                }
                if let outcome = try? run.result("render", as: RenderOutcome.self) {
                    sunday.exported = outcome
                    sunday.exportPath = outcome.output
                }
                sunday.verify = try? run.result("verify", as: VerifyReport.self)
                save()
                if let e = run.error { exportError = e }
            } catch is CancellationError {
            } catch {
                exportError = error.localizedDescription
            }
        }
        tasks.append(t)
    }

    func showExportInFinder() {
        guard let p = sunday.exportPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }

    func copyNote() {
        guard let note = sunday.quality?.note, !note.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note, forType: .string)
    }
}
