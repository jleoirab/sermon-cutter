import SwiftUI
import SermonCutterCore

/// The first screen: this Sunday's stream, the channel's other recent
/// streams, a box for any other link, and Sundays already started.
struct StreamsView: View {
    @EnvironmentObject var app: AppModel
    @State private var link = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let tools = app.tools, !tools.missing.isEmpty {
                    ToolsWarning(missing: tools.missing)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Streams").font(.largeTitle.bold())
                    Text("Pick the stream to cut. Preparing downloads the audio first, finds the sermon and checks the stream while the video downloads.")
                        .foregroundStyle(.secondary)
                }

                streamList

                VStack(alignment: .leading, spacing: 8) {
                    Text("Another stream").font(.headline)
                    HStack {
                        TextField("Paste a YouTube link", text: $link)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { app.open(link: link) }
                        Button("Prepare") { app.open(link: link) }
                            .disabled(Sunday.videoID(from: link) == nil)
                    }
                }

                let saved = app.folders.savedSundays()
                if !saved.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Started before").font(.headline)
                        ForEach(saved, id: \.url) { s in
                            SavedRow(sunday: s, open: { app.open(saved: s) }, trash: { app.trash(s) })
                        }
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task { if app.streams.isEmpty { await app.loadStreams() } }
    }

    @ViewBuilder private var streamList: some View {
        if app.loadingStreams && app.streams.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for the newest streams on CelebrationGlobalTV…").foregroundStyle(.secondary)
            }
        } else if let e = app.streamsError, app.streams.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Couldn't list the channel's streams", systemImage: "wifi.exclamationmark")
                Text(e).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Button("Try again") { Task { await app.loadStreams() } }
            }
        } else {
            VStack(spacing: 0) {
                ForEach(Array(app.streams.enumerated()), id: \.element.id) { i, s in
                    StreamRow(entry: s, newest: i == 0) { app.open(link: s.url) }
                    if i < app.streams.count - 1 { Divider() }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Spacer()
                Button {
                    Task { await app.loadStreams() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(app.loadingStreams)
            }
        }
    }
}

struct StreamRow: View {
    let entry: StreamEntry
    let newest: Bool
    let prepare: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if newest {
                        Text("NEWEST").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                    }
                    if entry.liveStatus == "is_live" {
                        Text("LIVE NOW").font(.caption2.bold()).foregroundStyle(.red)
                    }
                    Text(entry.title).font(.body.weight(.medium)).lineLimit(1)
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(newest ? "Prepare" : "Prepare", action: prepare)
                .buttonStyle(.borderedProminent)
                .tint(newest ? .accentColor : .gray)
                .disabled(entry.liveStatus == "is_live" || entry.liveStatus == "is_upcoming")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let d = entry.uploadDate, let date = Naming.date(fromYYYYMMDD: d) { parts.append(Naming.folderName(date)) }
        if let len = entry.duration { parts.append(Timecode.format(len)) }
        if entry.liveStatus == "is_upcoming" { parts.append("not started yet") }
        return parts.isEmpty ? entry.url : parts.joined(separator: " · ")
    }
}

struct SavedRow: View {
    let sunday: Sunday
    let open: () -> Void
    let trash: () -> Void
    @State private var confirming = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(sunday.info?.title ?? sunday.url).lineLimit(1)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open", action: open)
            Menu {
                Button("Move its downloads to the Trash…") { confirming = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 4)
        .confirmationDialog("Move this Sunday's downloads and work files to the Trash?", isPresented: $confirming) {
            Button("Move to Trash", role: .destructive, action: trash)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The finished sermon in the Service folder stays where it is.")
        }
    }

    private var status: String {
        var parts: [String] = []
        if let d = sunday.date { parts.append(Naming.folderName(d)) }
        if sunday.exportPath != nil { parts.append("exported") } else if let q = sunday.quality { parts.append(q.headline) }
        return parts.joined(separator: " · ")
    }
}

struct ToolsWarning: View {
    let missing: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Sermon Cutter needs: \(missing.joined(separator: ", "))", systemImage: "wrench.and.screwdriver")
                .font(.headline)
            Text("For now these come from Homebrew. In Terminal: brew install ffmpeg yt-dlp deno whisper-cpp. The speech model goes in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
