import SwiftUI
import SermonCutterCore

/// Folders, and the helpers the app carries.
struct SettingsView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        Form {
            Section("Folders") {
                folderRow("Finished sermons (Service folder)", url: app.folders.service) { app.folders.service = $0 }
                folderRow("Downloads and work files", url: app.folders.work) { app.folders.work = $0 }
            }
            Section {
                if let t = app.tools {
                    tool("ffmpeg", t.ffmpeg)
                    tool("ffprobe", t.ffprobe)
                    tool("Deno", t.deno)
                    tool("whisper.cpp", t.whisper)
                    tool("Speech model", t.whisperModel)
                    LabeledContent("yt-dlp") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(ytdlpLine(t.ytdlp)).foregroundStyle(t.ytdlp == nil ? Color.red : Color.secondary)
                            if let problem = app.ytdlp?.problem {
                                Text("Couldn't check for a newer one: \(problem)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
                HStack {
                    Spacer()
                    if app.updatingTools { ProgressView().controlSize(.small) }
                    Button("Check for a newer yt-dlp") { Task { await app.updateTools(force: true) } }
                        .disabled(app.updatingTools)
                }
            } header: {
                Text("Helpers")
            } footer: {
                Text("Everything comes with the app. yt-dlp, which downloads from YouTube, keeps itself up to date about once a day, since YouTube changes often.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 560)
        .task { await app.checkTools() }
    }

    /// "Inside the app", "Kept up to date by the app", or the path for a
    /// helper from anywhere else.
    private func place(_ path: String) -> String {
        if let b = app.tools?.bundleDir, path.hasPrefix(b + "/") || path.hasPrefix(Bundle.main.bundlePath + "/") {
            return "Inside the app"
        }
        if let t = app.tools?.toolsDir, path.hasPrefix(t + "/") { return "Kept up to date by the app" }
        return FolderRow.tilde(path)
    }

    private func ytdlpLine(_ path: String?) -> String {
        guard let path else { return "missing" }
        var parts = [place(path)]
        if let v = app.ytdlp?.version { parts.append("version \(v)") }
        if let d = app.ytdlpCheckedAt {
            parts.append("checked \(d.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }

    private func tool(_ name: String, _ path: String?) -> some View {
        LabeledContent(name) {
            if let path {
                Text(place(path)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            } else {
                Text("missing").foregroundStyle(.red)
            }
        }
    }

    private func folderRow(_ label: String, url: URL, set: @escaping (URL) -> Void) -> some View {
        FolderRow(label: label, url: url, set: set)
    }
}

/// A folder as an editable path, with a Change… button for the usual picker.
struct FolderRow: View {
    let label: String
    let url: URL
    let set: (URL) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
            HStack {
                TextField("Folder", text: $text)
                    .onSubmit(commit)
                    .font(.callout)
                Button("Change…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.directoryURL = url
                    if panel.runModal() == .OK, let u = panel.url { set(u) }
                }
            }
        }
        .onAppear { text = FolderRow.tilde(url.path) }
        .onChange(of: url) { _, u in
            let t = FolderRow.tilde(u.path)
            if t != text { text = t }
        }
        .onChange(of: text) { _, t in
            // Take a pasted or typed path as soon as its parent folder exists.
            let path = (t as NSString).expandingTildeInPath
            let parent = (path as NSString).deletingLastPathComponent
            var isDir: ObjCBool = false
            if path != url.path, path.hasPrefix("/"),
               FileManager.default.fileExists(atPath: parent, isDirectory: &isDir), isDir.boolValue {
                set(URL(fileURLWithPath: path, isDirectory: true))
            }
        }
    }

    private func commit() {
        let path = (text as NSString).expandingTildeInPath
        guard !path.isEmpty else { return }
        set(URL(fileURLWithPath: path, isDirectory: true))
    }

    static func tilde(_ path: String) -> String {
        path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }
}
