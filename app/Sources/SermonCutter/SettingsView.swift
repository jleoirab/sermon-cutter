import SwiftUI
import SermonCutterCore

/// Folders, the speech model, and which tools the engine found.
struct SettingsView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        Form {
            Section("Folders") {
                folderRow("Downloads and work files", url: app.folders.work) { app.folders.work = $0 }
                folderRow("Service folder (finished sermons)", url: app.folders.service) { app.folders.service = $0 }
            }
            Section("Speech model") {
                TextField("Path", text: $app.modelPath)
                Text(FileManager.default.fileExists(atPath: app.modelPath) ? "Found." : "Not found: put ggml-small.en-q8_0.bin here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Tools") {
                if let t = app.tools {
                    tool("ffmpeg", t.ffmpeg)
                    tool("ffprobe", t.ffprobe)
                    tool("yt-dlp", t.ytdlp)
                    tool("Deno", t.deno)
                    tool("whisper.cpp", t.whisper)
                    tool("Speech model", t.whisperModel)
                } else {
                    ProgressView().controlSize(.small)
                }
                Button("Look again") { Task { await app.checkTools() } }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 520)
        .task { await app.checkTools() }
    }

    private func tool(_ name: String, _ path: String?) -> some View {
        LabeledContent(name) {
            if let path {
                Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
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
