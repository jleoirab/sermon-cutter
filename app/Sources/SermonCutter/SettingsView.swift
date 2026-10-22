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
        LabeledContent(label) {
            HStack {
                Text(url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
    }
}
