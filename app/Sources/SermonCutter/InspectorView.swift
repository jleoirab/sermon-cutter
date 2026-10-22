import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SermonCutterCore

/// The Review screen's right-hand side: the cut, the stream's quality, the
/// banner, the ends, and Export.
struct InspectorView: View {
    @ObservedObject var model: SundayModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CutSection(model: model)
                Divider()
                QualitySection(model: model)
                Divider()
                BannerSection(model: model)
                Divider()
                EndsSection(model: model)
                Divider()
                ExportSection(model: model)
            }
            .padding(16)
        }
        .background(.background)
    }
}

// MARK: - Cut

struct CutSection: View {
    @ObservedObject var model: SundayModel
    @State private var leadIn = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The cut").font(.headline)
            if let f = model.sunday.find {
                PointRow(
                    label: "In",
                    value: model.sunday.cutIn,
                    confidence: f.startConfidence,
                    evidence: "Preacher starts at \(Timecode.format(Double(f.preacherStarts))); \(Timecode.span(Double(f.preacherStarts) - (model.sunday.cutIn ?? 0))) of worship kept before that.",
                    playhead: model.playhead,
                    set: model.setIn,
                    seek: model.seek
                )
                PointRow(
                    label: "Out",
                    value: model.sunday.cutOut,
                    confidence: f.outConfidence,
                    evidence: outEvidence(f),
                    playhead: model.playhead,
                    set: model.setOut,
                    seek: model.seek
                )
                HStack {
                    Text("Worship before the preacher")
                    TextField("2:00", text: $leadIn)
                        .frame(width: 64)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(applyLeadIn)
                    Button("Apply", action: applyLeadIn)
                        .disabled(Timecode.parse(leadIn) == nil)
                }
                .font(.callout)
                HStack {
                    if let a = model.sunday.cutIn, let b = model.sunday.cutOut {
                        Text("Sermon length \(Timecode.format(b - a))").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Back to the found points") { model.resetCut() }
                        .controlSize(.small)
                        .disabled(model.sunday.cutIn == f.cutIn && model.sunday.cutOut == f.cutOut)
                }
            } else {
                Text("Finding the sermon…").foregroundStyle(.secondary)
            }
        }
        .onAppear { leadIn = Timecode.format(model.sunday.leadIn) }
    }

    private func applyLeadIn() {
        guard let s = Timecode.parse(leadIn) else { return }
        model.applyLeadIn(s)
        if let a = model.sunday.cutIn { model.seek(a) }
    }

    private func outEvidence(_ f: FindResult) -> String {
        switch f.outMethod {
        case "seat_cue":
            return "Heard: “\(f.outCue?.context ?? "")”"
        case "prayer_before_handover":
            return "End of the closing prayer, before someone else took over: “\(f.outCue?.context ?? "")”"
        case "prayer_close":
            return "No “please be seated” was heard; this is the end of the closing prayer before the offering."
        default:
            return "Nothing was heard to place it; this is where the preaching stops. Listen and set it."
        }
    }
}

/// In or Out: its time (typed or nudged), confidence and evidence.
struct PointRow: View {
    let label: String
    let value: Double?
    let confidence: String
    let evidence: String
    let playhead: Double
    let set: @MainActor (Double) -> Void
    let seek: @MainActor (Double) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(label).font(.body.weight(.semibold)).frame(width: 30, alignment: .leading)
                TextField("h:mm:ss", text: $text)
                    .font(.body.monospacedDigit())
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 96)
                    .onSubmit {
                        if let t = Timecode.parse(text) { set(t); seek(t) }
                    }
                ConfidenceBadge(confidence: confidence)
                Spacer()
                Button {
                    if let value { seek(value) }
                } label: {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.borderless)
                .help("Go to \(label)")
            }
            HStack(spacing: 4) {
                ForEach([-5.0, -1.0, 1.0, 5.0], id: \.self) { d in
                    Button(d > 0 ? "+\(Int(d)) s" : "\(Int(d)) s") {
                        guard let value else { return }
                        set(value + d)
                        seek(value + d)
                    }
                    .controlSize(.small)
                }
                Spacer()
                Button("Set to playhead") { set(playhead) }
                    .controlSize(.small)
            }
            Text(evidence)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { text = value.map { Timecode.format($0, tenths: true) } ?? "" }
        .onChange(of: value) { _, v in text = v.map { Timecode.format($0, tenths: true) } ?? "" }
    }
}

struct ConfidenceBadge: View {
    let confidence: String

    var body: some View {
        Text(confidence.capitalized)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
            .help(help)
    }

    private var color: Color {
        switch confidence {
        case "high": return .green
        case "medium": return .orange
        default: return .red
        }
    }

    private var help: String {
        switch confidence {
        case "high": return "A glance is enough."
        case "medium": return "Listen to the 10 seconds around it."
        default: return "Listen and set it yourself."
        }
    }
}

// MARK: - Quality

struct QualitySection: View {
    @ObservedObject var model: SundayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Stream quality").font(.headline)
                Spacer()
                if model.checking {
                    ProgressView().controlSize(.small)
                } else if model.qualityIsStale {
                    Button("Check again") { model.recheck() }.controlSize(.small)
                }
            }
            if let q = model.sunday.quality {
                VerdictBadge(report: q, stale: model.qualityIsStale)
                ForEach(q.reasons, id: \.self) { r in
                    Text(r).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                if !q.videoChecked {
                    Text("The picture is checked once the video has downloaded.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !q.issues.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(q.issues.prefix(30)) { issue in
                            Button {
                                model.seek(max(0, issue.start - 3))
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: issue.isSound ? "speaker.slash" : "tv.slash")
                                        .foregroundStyle(.secondary)
                                    Text(issue.intoCutTc).monospacedDigit().frame(width: 48, alignment: .leading)
                                    Text("\(issue.what), \(Timecode.span(issue.len))")
                                    Spacer()
                                }
                                .font(.caption)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Times are into the sermon; click to listen (stream \(issue.streamTc))")
                        }
                    }
                }
                if !q.note.isEmpty {
                    Button {
                        model.copyNote()
                    } label: {
                        Label("Copy the note for the leads", systemImage: "doc.on.doc")
                    }
                }
                if q.verdict == "not_usable" {
                    Text("Use a different stream if there is one: go back to Streams and prepare it. You can still export this one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Checked once the sermon is found.").foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Banner

struct BannerSection: View {
    @ObservedObject var model: SundayModel
    @State private var choosing = false
    @State private var targeted = false
    @State private var link = ""
    @State private var fetching = false
    @State private var linkError: String?
    @State private var thumbnail: NSImage?
    @State private var unreadable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sunday banner").font(.headline)
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(targeted ? Color.accentColor : .secondary)
                if let image = thumbnail {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .padding(6)
                } else if model.sunday.bannerPath != nil {
                    if unreadable {
                        VStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle").font(.title2)
                            Text("Couldn't open the banner. Choose it again or drop another.").font(.callout)
                            Text("If you said no when macOS asked about Documents, turn it on in System Settings → Privacy & Security → Files and Folders.")
                                .font(.caption)
                        }
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(10)
                    } else {
                        BannerWaiting()
                    }
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "photo").font(.title2)
                        Text("Drop the banner here").font(.callout)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(height: 150)
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: { BannerSection.isImage($0) }) else { return false }
                model.setBanner(url)
                return true
            } isTargeted: { targeted = $0 }
            HStack {
                if let path = model.sunday.bannerPath {
                    Text((path as NSString).lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Choose…") { choosing = true }
            }
            HStack {
                TextField("or paste a Google Drive link", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(fetch)
                    .onChange(of: link) { linkError = nil }
                if fetching {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Get", action: fetch).disabled(DriveLink.fileID(link) == nil)
                }
            }
            if let linkError {
                Text(linkError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: model.sunday.bannerPath) {
            // Read the image off the main thread: the first read of a file in
            // Documents waits for macOS to ask for permission.
            thumbnail = nil
            unreadable = false
            guard let path = model.sunday.bannerPath else { return }
            let data = await Task.detached(priority: .userInitiated) { FileManager.default.contents(atPath: path) }.value
            guard !Task.isCancelled else { return }
            if let data, let image = NSImage(data: data) {
                thumbnail = image
            } else {
                unreadable = true
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.png, .jpeg, .webP, .image]) { result in
            if case .success(let url) = result { model.setBanner(url) }
        }
    }

    private func fetch() {
        guard DriveLink.fileID(link) != nil, !fetching else { return }
        fetching = true
        linkError = nil
        Task {
            do {
                try await model.fetchBanner(from: link)
                link = ""
            } catch {
                linkError = error.localizedDescription
            }
            fetching = false
        }
    }

    static func isImage(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "webp"].contains(url.pathExtension.lowercased())
    }
}

/// A spinner for the banner. If it takes more than a moment, macOS is most
/// likely waiting for an answer about Documents, so say so.
struct BannerWaiting: View {
    @State private var slow = false

    var body: some View {
        VStack(spacing: 6) {
            ProgressView().controlSize(.small)
            if slow {
                Text("Waiting for macOS. If it asks to let Sermon Cutter open Documents, choose Allow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { slow = true }
        }
    }
}

// MARK: - Ends

struct EndsSection: View {
    @ObservedObject var model: SundayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Banner and fades").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    Text("Opening").font(.caption).foregroundStyle(.secondary)
                    Text("Closing").font(.caption).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Banner holds")
                    SecondsField(value: binding(\.openHold))
                    SecondsField(value: binding(\.closeHold))
                }
                GridRow {
                    Text("Sound fades")
                    SecondsField(value: binding(\.fadeIn))
                    SecondsField(value: binding(\.fadeOut))
                }
                GridRow {
                    Text("Dissolve")
                    SecondsField(value: binding(\.dissolve))
                    Text("both ends").font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            HStack {
                Button("Reset to the usual") { model.setTimings(Timings()) }
                    .controlSize(.small)
                    .disabled(model.sunday.timings == Timings())
                Spacer()
            }
            HStack(spacing: 8) {
                Text("Preview").font(.callout)
                ForEach(["opening", "closing"], id: \.self) { end in
                    Button {
                        model.preview(end)
                    } label: {
                        if model.previewing == end {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.mini)
                                Text("\(Int((model.previewProgress ?? 0) * 100))%")
                            }
                        } else {
                            Text(end.capitalized)
                        }
                    }
                    .disabled(model.previewing != nil || !model.hasVideo || model.sunday.bannerPath == nil)
                }
            }
            Text("Plays 20 seconds with the banner and fade, as they will export.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func binding(_ key: WritableKeyPath<Timings, Double>) -> Binding<Double> {
        Binding(
            get: { model.sunday.timings[keyPath: key] },
            set: { v in
                var t = model.sunday.timings
                t[keyPath: key] = max(0, v)
                model.setTimings(t)
            }
        )
    }
}

struct SecondsField: View {
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 3) {
            TextField("", value: $value, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 54)
                .multilineTextAlignment(.trailing)
            Text("s").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Export

struct ExportSection: View {
    @ObservedObject var model: SundayModel
    @State private var confirmReplace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export").font(.headline)
            if let url = model.exportURL {
                Text(url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            if model.exporting {
                ProgressView(value: model.exportProgress ?? 0) {
                    Text("Exporting…")
                } currentValueLabel: {
                    Text("\(Int((model.exportProgress ?? 0) * 100))%")
                }
            } else {
                Button {
                    if let url = model.exportURL, FileManager.default.fileExists(atPath: url.path) {
                        confirmReplace = true
                    } else {
                        model.export(overwrite: false)
                    }
                } label: {
                    Label("Export the sermon", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canExport)
                if !model.canExport {
                    Text(waitingFor).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let e = model.exportError {
                Text(e).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let out = model.sunday.exported, !model.exporting {
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        "Exported \(Timecode.format(out.cutLen)) in \(Timecode.format(out.elapsedS))",
                        systemImage: model.sunday.verify?.passed == false ? "exclamationmark.triangle" : "checkmark.seal"
                    )
                    if let v = model.sunday.verify {
                        Text(v.passed ? "Self-check passed: length, banner at both ends, quiet start and end." :
                                "Self-check failed: \(v.checks.filter { !$0.passed }.map(\.detail).joined(separator: "; "))")
                            .font(.caption)
                            .foregroundStyle(v.passed ? Color.secondary : Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button("Show in Finder") { model.showExportInFinder() }
                        if !(model.sunday.quality?.note ?? "").isEmpty {
                            Button("Copy note for the leads") { model.copyNote() }
                        }
                    }
                }
            }
        }
        .confirmationDialog("Replace the sermon already exported?", isPresented: $confirmReplace) {
            Button("Replace", role: .destructive) { model.export(overwrite: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A file with this name is already in the Sunday's folder.")
        }
    }

    private var waitingFor: String {
        if !model.hasVideo { return "Waiting for the video to download." }
        if model.sunday.bannerPath == nil { return "Add the Sunday banner first." }
        if model.sunday.cutIn == nil { return "Waiting for the sermon to be found." }
        return ""
    }
}
