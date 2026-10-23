import SwiftUI
import SermonCutterCore

/// Home: this Sunday's stream up front, Sundays already started beside it,
/// and the channel's other recent streams below. A link to any other stream
/// can be pasted in the toolbar.
struct HomeView: View {
    @EnvironmentObject var app: AppModel
    @State private var showAll = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let tools = app.tools, !tools.missing.isEmpty {
                    ToolsWarning(missing: tools.missing)
                }
                HStack(alignment: .top, spacing: 24) {
                    ThisSundayCard()
                        .frame(maxWidth: .infinity)
                    StartedBeforeCard()
                        .frame(width: 360)
                }
                .fixedSize(horizontal: false, vertical: true)
                otherStreams
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
            .frame(maxWidth: 1500)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                PasteLinkField()
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .medium))
                }
                .buttonStyle(CircleButtonStyle())
                .help("Settings")
            }
        }
        .task { if app.streams.isEmpty { await app.loadStreams() } }
    }

    private var others: [StreamEntry] {
        let hero = StreamPicker.thisSunday(app.streams)
        return app.streams.filter { $0.id != hero?.id }
    }

    @ViewBuilder private var otherStreams: some View {
        let list = others
        if !list.isEmpty || !app.streamsLoaded {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Other recent streams").font(Brand.lato(16, .black))
                    Text("from CelebrationGlobalTV on YouTube")
                        .font(Brand.lato(13))
                        .foregroundStyle(Brand.text2)
                    Spacer()
                    if list.count > 4 {
                        Button(showAll ? "Show fewer" : "Show more") { showAll.toggle() }
                            .buttonStyle(LinkButtonStyle())
                    }
                    if app.loadingStreams && app.streamsLoaded {
                        ProgressView().controlSize(.small)
                    } else if app.streamsLoaded {
                        Button {
                            Task { await app.loadStreams() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(LinkButtonStyle())
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20, alignment: .top), count: 4), spacing: 20) {
                    if app.streamsLoaded {
                        ForEach(showAll ? list : Array(list.prefix(4))) { s in
                            StreamCard(entry: s) { app.open(link: s.url) }
                        }
                    } else {
                        ForEach(0..<4, id: \.self) { _ in
                            StreamCard(entry: HomeView.placeholder, prepare: {})
                                .redacted(reason: .placeholder)
                                .disabled(true)
                        }
                    }
                }
            }
        }
    }

    static let placeholder = StreamEntry(
        id: "placeholder",
        title: "SUNDAY SERVICE | 1ST SERVICE | 11TH OCTOBER 2026",
        url: "",
        duration: 9000,
        uploadDate: "20261011"
    )
}

// MARK: - Toolbar

/// "Paste a YouTube link" in the toolbar. Return prepares that stream.
struct PasteLinkField: View {
    @EnvironmentObject var app: AppModel
    @State private var link = ""
    @FocusState private var focused: Bool

    private var valid: Bool { Sunday.videoID(from: link) != nil }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Brand.text2)
            TextField("Paste a YouTube link", text: $link)
                .textFieldStyle(.plain)
                .font(Brand.lato(13))
                .focused($focused)
                .onSubmit(open)
            if valid {
                Button("Prepare", action: open)
                    .buttonStyle(PillButtonStyle(kind: .primary, size: .small))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, valid ? 3 : 12)
        .frame(width: 340, height: 32)
        .background(Brand.card2, in: Capsule())
        .overlay(Capsule().strokeBorder(!link.isEmpty && !valid ? Brand.tonalLine : .clear, lineWidth: 1))
        .help(!link.isEmpty && !valid ? "That doesn't look like a YouTube link." : "Paste the link of any stream to cut it.")
    }

    private func open() {
        guard valid else { return }
        app.open(link: link)
        link = ""
    }
}

// MARK: - This Sunday

struct ThisSundayCard: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        Group {
            if let entry = StreamPicker.thisSunday(app.streams) {
                content(entry)
            } else if let error = app.streamsError {
                problem(error)
            } else if app.streamsLoaded {
                VStack(alignment: .leading, spacing: 10) {
                    Text("NO STREAMS YET").font(Brand.anton(40))
                    Text("There's nothing on CelebrationGlobalTV right now. Paste a link at the top to cut any other stream.")
                        .foregroundStyle(Brand.text2)
                }
                .frame(maxWidth: .infinity, minHeight: 225, alignment: .leading)
            } else {
                content(HomeView.placeholder)
                    .redacted(reason: .placeholder)
                    .disabled(true)
            }
        }
        .card(radius: 24, padding: 20)
    }

    private func content(_ entry: StreamEntry) -> some View {
        let title = ServiceTitle(entry.title)
        let date = entry.uploadDate.flatMap(Naming.date(fromYYYYMMDD:))
        let blocked = entry.liveStatus == "is_live" || entry.liveStatus == "is_upcoming"
        return HStack(alignment: .top, spacing: 24) {
            Thumbnail(id: entry.id, duration: entry.duration)
                .frame(maxWidth: 400)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(eyebrow(date))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Brand.card2, in: Capsule())
                (Text(title.sermon.uppercased() + (title.service == nil ? "" : " "))
                    + Text((title.service ?? "").uppercased()).foregroundStyle(Brand.coral))
                    .font(Brand.anton(44))
                    .lineSpacing(-4)
                    .minimumScaleFactor(0.6)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let date {
                    Text("Streamed \(Naming.weekday(date)), \(Naming.display(date))" + (entry.duration.map { " · \(Timecode.long($0))" } ?? ""))
                        .foregroundStyle(Brand.text2)
                }
                Spacer(minLength: 12)
                if blocked {
                    Chip(text: entry.liveStatus == "is_live" ? "Live now: come back once the service has ended" : "Not started yet",
                         foreground: Brand.warnFg, background: Brand.warnBg, size: 13)
                } else {
                    Button(app.hasSaved(entry.id) ? "Open this Sunday" : "Prepare this Sunday") { app.open(link: entry.url) }
                        .buttonStyle(PillButtonStyle(kind: .primary, size: .large))
                }
            }
            .frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 225)
    }

    private func eyebrow(_ date: Date?) -> String {
        guard let date else { return "Newest stream" }
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 99
        if Naming.isSunday(date) {
            return (days <= 6 ? "This Sunday · " : "Sunday · ") + Naming.monthDay(date)
        }
        return "\(Naming.weekday(date)) · \(Naming.monthDay(date))"
    }

    private func problem(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Brand.coral)
            Text("COULDN'T REACH YOUTUBE").font(Brand.anton(40))
            Text("Check the internet connection and try again. You can also paste a stream's link at the top.")
                .foregroundStyle(Brand.text2)
            Text(error).font(Brand.lato(12)).foregroundStyle(Brand.text2).lineLimit(2)
            Spacer(minLength: 8)
            Button("Try again") { Task { await app.loadStreams() } }
                .buttonStyle(PillButtonStyle(kind: .primary, size: .regular))
        }
        .frame(maxWidth: .infinity, minHeight: 225, alignment: .leading)
    }
}

/// A stream's YouTube thumbnail, 16:9, with its length in the corner.
struct Thumbnail: View {
    let id: String
    let duration: Double?
    var showsPlay = false

    var body: some View {
        Color.black
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if id != "placeholder", let url = URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg") {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            // hqdefault is 4:3 with bars; filling 16:9 crops them off.
                            image.resizable().scaledToFill()
                        } else {
                            Brand.card2
                        }
                    }
                } else {
                    Brand.card2
                }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if let duration {
                    Text(Timecode.format(duration))
                        .font(Brand.lato(12, .black).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.72), in: Capsule())
                        .padding(10)
                }
            }
    }
}

// MARK: - Started before

struct StartedBeforeCard: View {
    @EnvironmentObject var app: AppModel
    @State private var trashing: Sunday?

    var body: some View {
        let saved = Array(app.folders.savedSundays().prefix(4))
        VStack(alignment: .leading, spacing: 0) {
            Text("Started before").font(Brand.lato(16, .black)).padding(.bottom, 8)
            if saved.isEmpty {
                Text("Sundays you start show up here, so you can come back to them.")
                    .foregroundStyle(Brand.text2)
                    .padding(.vertical, 8)
            }
            ForEach(Array(saved.enumerated()), id: \.element.url) { i, s in
                if i > 0 { Divider().overlay(Brand.border) }
                SavedRow(sunday: s, running: s.id.flatMap { app.running[$0] }) { app.open(saved: s) }
                    .contextMenu {
                        Button("Move its downloads to the Trash…") { trashing = s }
                    }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card(radius: 24, padding: 20)
        .confirmationDialog(
            "Move this Sunday's downloads and work files to the Trash?",
            isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } })
        ) {
            Button("Move to Trash", role: .destructive) {
                if let s = trashing { app.trash(s) }
                trashing = nil
            }
            Button("Cancel", role: .cancel) { trashing = nil }
        } message: {
            Text("The finished sermon in the Service folder stays where it is.")
        }
    }
}

struct SavedRow: View {
    let sunday: Sunday
    var running: SundayModel?
    let open: () -> Void

    var body: some View {
        let title = ServiceTitle(sunday.info?.title ?? sunday.url)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text([title.sermon, title.service].compactMap { $0 }.joined(separator: " · "))
                    .font(Brand.lato(14, .bold))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let d = sunday.date {
                        Text(Naming.monthDay(d)).font(Brand.lato(12)).foregroundStyle(Brand.text2)
                    }
                    status
                }
            }
            Spacer(minLength: 8)
            Button("Open", action: open)
                .buttonStyle(PillButtonStyle(kind: .outline, size: .small))
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder private var status: some View {
        let fm = FileManager.default
        if let running {
            RunningChip(model: running)
        } else if let p = sunday.exportPath, fm.fileExists(atPath: p) {
            Chip(text: "Exported", foreground: Brand.goodFg, background: Brand.goodBg)
        } else if sunday.cutIn != nil, sunday.bannerPath != nil,
                  let v = sunday.videoFile, fm.fileExists(atPath: v) {
            Chip(text: "Ready to export", foreground: Brand.tonalFg, background: Brand.tonalBg)
        } else {
            Chip(text: "Not finished")
        }
    }
}

// MARK: - Other streams

struct StreamCard: View {
    let entry: StreamEntry
    let prepare: () -> Void

    var body: some View {
        let title = ServiceTitle(entry.title)
        let date = entry.uploadDate.flatMap(Naming.date(fromYYYYMMDD:))
        VStack(alignment: .leading, spacing: 0) {
            Thumbnail(id: entry.id, duration: entry.duration)
            VStack(alignment: .leading, spacing: 4) {
                Text(title.sermon).font(Brand.lato(14, .black)).lineLimit(1)
                Text([title.service, date.map(Naming.monthDay)].compactMap { $0 }.joined(separator: " · "))
                    .font(Brand.lato(13))
                    .foregroundStyle(Brand.text2)
                    .lineLimit(1)
                Group {
                    switch entry.liveStatus {
                    case "is_live":
                        Chip(text: "Live now", foreground: Brand.badFg, background: Brand.badBg)
                    case "is_upcoming":
                        Chip(text: "Not started yet")
                    default:
                        Button("Prepare", action: prepare)
                            .buttonStyle(PillButtonStyle(kind: .tonal, size: .small))
                    }
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 16)
        }
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Brand.shadowColor, radius: 6, y: 2)
    }
}

/// Until the app installs its own helpers: what's missing, plainly.
struct ToolsWarning: View {
    let missing: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Brand.warnFg)
            VStack(alignment: .leading, spacing: 4) {
                Text("A few helpers are missing: \(missing.joined(separator: ", "))")
                    .font(Brand.lato(14, .black))
                Text("Until CCI Sermon Cutter installs them itself, they come from Homebrew. In Terminal: brew install ffmpeg yt-dlp deno whisper-cpp. The speech model goes in Settings.")
                    .font(Brand.lato(13))
            }
            .foregroundStyle(Brand.warnFg)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Brand.warnBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// The status of a Sunday that's still working after going back Home.
struct RunningChip: View {
    @ObservedObject var model: SundayModel

    var body: some View {
        if model.exporting {
            Chip(text: "Exporting \(Int((model.exportProgress ?? 0) * 100))%", foreground: Brand.tonalFg, background: Brand.tonalBg)
        } else if model.page == .done {
            Chip(text: "Exported", foreground: Brand.goodFg, background: Brand.goodBg)
        } else if model.exportError != nil {
            Chip(text: "Export stopped", foreground: Brand.badFg, background: Brand.badBg)
        } else {
            Chip(text: "Ready to export", foreground: Brand.tonalFg, background: Brand.tonalBg)
        }
    }
}
