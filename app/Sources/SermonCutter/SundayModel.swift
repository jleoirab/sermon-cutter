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

/// The Review screen's three steps, and the page that follows the export.
enum ReviewPage: Equatable {
    case cut, quality, export, done
}

/// One Sunday's job: preparing the stream, the cut being reviewed, and the
/// export.
@MainActor
final class SundayModel: ObservableObject {
    @Published var sunday: Sunday
    @Published var steps: [Step] = [
        Step(id: "info", title: "Reading the stream"),
        Step(id: "audio", title: "Downloading the sound"),
        Step(id: "find", title: "Locating sermon segment"),
        Step(id: "sound", title: "Checking the sound"),
        Step(id: "video", title: "Downloading video"),
        Step(id: "picture", title: "Checking picture quality"),
    ]
    @Published var page: ReviewPage = .cut
    @Published var playhead: Double = 0
    @Published var isPlaying = false
    @Published var loudness: Loudness?
    @Published var transcript: Transcript?
    @Published var checking = false
    @Published var exporting = false
    @Published var exportProgress: Double?
    @Published var exportETA: Double?
    @Published var exportError: String?
    @Published var problem: String?
    /// The banner, read once for the thumbnail, the player and the preview.
    @Published var bannerImage: NSImage?
    @Published var bannerUnreadable = false
    /// Snapshots across the cut, for the timeline on Quality and Export.
    @Published var filmstrip: [NSImage] = []
    /// "opening" or "closing" while Preview the ends is open.
    @Published var endsPreview: String?

    let engine: Engine
    var folders: Folders
    let player = AVPlayer()
    private var tasks: [Task<Void, Never>] = []
    private var exportTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var loadedMedia: String?
    private var filmstripKey = ""

    init(sunday: Sunday, engine: Engine, folders: Folders) {
        self.sunday = sunday
        self.engine = engine
        self.folders = folders
        if sunday.verify?.passed == true, let p = sunday.exportPath, FileManager.default.fileExists(atPath: p) {
            page = .done
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, t.seconds.isFinite else { return }
                self.tick(t.seconds)
            }
        }
        if let id = sunday.id {
            loudness = Loudness.load(folders.soundCache(id))
            transcript = Transcript.load(folders.wordsCache(id))
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

    var title: ServiceTitle { ServiceTitle(sunday.info?.title ?? sunday.url) }

    /// "1st service · Oct 11, 2026 · from a 2 h 47 min stream"
    var subtitle: String {
        var parts: [String] = []
        if let s = title.service { parts.append(s) }
        if let d = sunday.date { parts.append(Naming.display(d)) }
        if let len = sunday.find?.streamSeconds ?? sunday.info?.duration { parts.append("from a \(Timecode.long(len)) stream") }
        return parts.joined(separator: " · ")
    }

    var duration: Double {
        if let d = sunday.find?.streamSeconds ?? sunday.info?.duration { return d }
        let d = player.currentItem?.duration.seconds ?? 0
        return d.isFinite && d > 1 ? d : 1
    }
    var cutLength: Double? {
        guard let a = sunday.cutIn, let b = sunday.cutOut else { return nil }
        return b - a
    }
    var found: Bool { sunday.find != nil && sunday.cutIn != nil && sunday.cutOut != nil }
    var hasVideo: Bool { sunday.videoFile.map { FileManager.default.fileExists(atPath: $0) } ?? false }
    var exportURL: URL? { sunday.date.map { folders.sermonFile($0) } }
    var preparing: Bool { steps.contains { if case .running = $0.state { return true } else { return false } } }
    var failedStep: Step? { steps.first { if case .failed = $0.state { return true } else { return false } } }

    /// How far the video download has got, while it downloads.
    var videoProgress: Double? {
        guard let s = steps.first(where: { $0.id == "video" }), case .running(let f) = s.state else { return nil }
        return f ?? 0
    }

    /// Whether the last check covered a different cut than the current one.
    var qualityIsStale: Bool {
        guard let q = sunday.quality, let a = sunday.cutIn, let b = sunday.cutOut else { return false }
        return abs(q.cutIn - a) > 0.5 || abs(q.cutOut - b) > 0.5
    }

    var canExport: Bool {
        hasVideo && sunday.bannerPath != nil && found && !exporting
    }

    /// Why Export can't start yet, in plain words.
    var exportBlocker: String? {
        if !found { return "Waiting for the sermon to be found." }
        if !hasVideo {
            if let f = videoProgress { return "Waiting for the video to download (\(Int(f * 100))%)." }
            return "Waiting for the video to download."
        }
        if sunday.bannerPath == nil { return "Add this Sunday's banner in step 1 first." }
        return nil
    }

    /// Quality and Export play the cut as it will be exported: from Start to
    /// End, with the banner and the fades at both ends.
    var playsCut: Bool { page == .quality || page == .export }

    // MARK: - Preparing

    func prepare() {
        for i in steps.indices where steps[i].state != .done { steps[i].state = .waiting }
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
            set("info", .done, detail: sunday.date.map(Naming.display) ?? sunday.info?.title)
            guard let id = sunday.id else { throw EngineError.failed(step: "info", message: "That doesn't look like a YouTube link.") }
            try FileManager.default.createDirectory(at: folders.work, withIntermediateDirectories: true)
            if sunday.bannerPath == nil, let d = sunday.date {
                let folders = self.folders
                if let b = await Task.detached(operation: { folders.suggestedBanner(d) }).value {
                    sunday.bannerPath = b.path
                    save()
                }
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
            let v = try await fetch(id, part: "video")
            // Show the picture as soon as it's here, even mid-analysis.
            sunday.videoFile = v.path
            save()
            loadMedia()
            return v
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
            if let a = sunday.cutIn, !hasVideo || playhead < 1 { seek(a) }
        }
        loudness = Loudness.load(folders.soundCache(id))
        transcript = Transcript.load(folders.wordsCache(id))
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

    /// Checks again after Start or End moved.
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

    private func tick(_ t: Double) {
        playhead = t
        let playing = player.timeControlStatus == .playing
        if isPlaying != playing { isPlaying = playing }
        if playsCut, let b = sunday.cutOut {
            player.volume = Float(gain(at: t))
            if playing && t >= b - 0.05 {
                player.pause()
                isPlaying = false
            }
        } else if player.volume != 1 {
            player.volume = 1
        }
    }

    func seek(_ t: Double) {
        let clamped = max(0, min(t, duration))
        playhead = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlay() {
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
            return
        }
        if playsCut, let a = sunday.cutIn, let b = sunday.cutOut, playhead < a || playhead >= b - 0.2 {
            seek(a)
        }
        player.play()
        isPlaying = true
    }

    func play(from t: Double) {
        seek(t)
        player.play()
        isPlaying = true
    }

    /// How much of the banner covers the picture at stream time `t`: 1 while
    /// it holds, fading over the dissolve, 0 in between.
    func bannerOpacity(at t: Double) -> Double {
        guard let a = sunday.cutIn, let b = sunday.cutOut else { return 0 }
        let tm = sunday.timings
        func edge(_ x: Double, hold: Double) -> Double {
            if x < hold { return 1 }
            if tm.dissolve <= 0 { return 0 }
            return max(0, 1 - (x - hold) / tm.dissolve)
        }
        return max(edge(t - a, hold: tm.openHold), edge(b - t, hold: tm.closeHold))
    }

    /// The sound level at stream time `t`: fading in after Start and out
    /// before End.
    func gain(at t: Double) -> Double {
        guard let a = sunday.cutIn, let b = sunday.cutOut else { return 1 }
        let tm = sunday.timings
        var g = 1.0
        if tm.fadeIn > 0 { g = min(g, max(0, (t - a) / tm.fadeIn)) }
        if tm.fadeOut > 0 { g = min(g, max(0, (b - t) / tm.fadeOut)) }
        return g
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

    /// Puts Start the lead-in's length before the preacher starts.
    func applyLeadIn(_ seconds: Double) {
        sunday.leadIn = max(0, seconds)
        if let f = sunday.find {
            setIn(Double(f.preacherStarts) - sunday.leadIn)
        }
        save()
    }

    func resetCut() {
        guard let f = sunday.find else { return }
        sunday.cutIn = f.cutIn
        sunday.cutOut = f.cutOut
        save()
    }

    var cutChanged: Bool {
        guard let f = sunday.find else { return false }
        return sunday.cutIn != f.cutIn || sunday.cutOut != f.cutOut
    }

    // MARK: - The banner

    /// Downloads a banner shared on Google Drive with "anyone with the link".
    func fetchBanner(from link: String) async throws {
        guard let fileID = DriveLink.fileID(link) else {
            throw EngineError.failed(step: "banner", message: "That isn't a Google Drive file link.")
        }
        let (data, response) = try await URLSession.shared.data(from: DriveLink.downloadURL(fileID))
        let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard type.hasPrefix("image/") else {
            throw EngineError.failed(
                step: "banner",
                message: "Drive didn't hand over an image. Share the banner with “Anyone with the link”, or download it and drop the file here."
            )
        }
        let ext = type.contains("png") ? "png" : type.contains("webp") ? "webp" : "jpg"
        let base = sunday.id ?? "banner"
        let file = folders.work.appendingPathComponent("\(base).banner.\(ext)")
        try FileManager.default.createDirectory(at: folders.work, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        setBanner(file)
    }

    func setBanner(_ url: URL) {
        sunday.bannerPath = url.path
        save()
    }

    /// Reads the banner off the main thread: the first read of a file in
    /// Documents waits for macOS to ask for permission.
    func loadBanner() async {
        bannerImage = nil
        bannerUnreadable = false
        guard let path = sunday.bannerPath else { return }
        let data = await Task.detached(priority: .userInitiated) { FileManager.default.contents(atPath: path) }.value
        guard !Task.isCancelled, path == sunday.bannerPath else { return }
        if let data, let image = NSImage(data: data) {
            bannerImage = image
        } else {
            bannerUnreadable = true
        }
    }

    func setTimings(_ t: Timings) {
        sunday.timings = t
        save()
    }

    // MARK: - Snapshots for the timeline

    /// Pictures from across the cut, made again when Start or End move.
    func loadFilmstrip(count: Int = 10) async {
        guard hasVideo, let v = sunday.videoFile, let a = sunday.cutIn, let b = sunday.cutOut else {
            filmstrip = []
            return
        }
        let key = "\(v)|\(Int(a / 5))|\(Int(b / 5))|\(count)"
        guard key != filmstripKey else { return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: v)))
        generator.maximumSize = CGSize(width: 320, height: 180)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 4, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 4, preferredTimescale: 600)
        var images: [NSImage] = []
        for i in 0..<count {
            let t = a + (b - a) * (Double(i) + 0.5) / Double(count)
            guard !Task.isCancelled else { return }
            if let frame = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)) {
                let cg = frame.image
                images.append(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
            }
        }
        guard !Task.isCancelled else { return }
        filmstrip = images
        filmstripKey = key
    }

    // MARK: - Exporting

    func export(overwrite: Bool) {
        guard canExport, let video = sunday.videoFile, let banner = sunday.bannerPath,
              let a = sunday.cutIn, let b = sunday.cutOut, let out = exportURL
        else { return }
        player.pause()
        exporting = true
        exportProgress = 0
        exportETA = nil
        exportError = nil
        exportTask = Task {
            defer {
                exporting = false
                exportTask = nil
            }
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
                    let eta = event.etaS
                    Task { @MainActor in
                        model.exportProgress = f
                        if let eta { model.exportETA = eta }
                    }
                }
                if let outcome = try? run.result("render", as: RenderOutcome.self) {
                    sunday.exported = outcome
                    sunday.exportPath = outcome.output
                }
                sunday.verify = try? run.result("verify", as: VerifyReport.self)
                save()
                if let e = run.error {
                    exportError = e
                } else if sunday.verify?.passed == true {
                    page = .done
                }
            } catch is CancellationError {
                // Stopped: the half-written file is hidden beside the sermon.
                let partial = out.deletingLastPathComponent().appendingPathComponent(".\(out.lastPathComponent).partial")
                try? FileManager.default.removeItem(at: partial)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    func stopExport() {
        exportTask?.cancel()
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
