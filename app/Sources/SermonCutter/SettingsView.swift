import AppKit
import SwiftUI
import SermonCutterCore

/// Settings, in the app's own look: where the finished sermons go, and the
/// folder the app works in. The helpers the app carries look after
/// themselves, so they aren't shown.
struct SettingsView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SETTINGS").font(Brand.anton(32))
            FolderCard(
                title: "Finished sermons",
                detail: "Each Sunday gets its own folder here, like “Oct 11th 2026”, with the sermon inside.",
                url: app.folders.service
            ) { app.folders.service = $0 }
            FolderCard(
                title: "Downloads and work files",
                detail: "Each stream's sound and video while you work on it. The app keeps them in its own folder; there's no need to change this.",
                url: app.folders.work
            ) { app.folders.work = $0 }
            Spacer(minLength: 0)
            Text(version)
                .font(Brand.lato(12))
                .foregroundStyle(Brand.text2)
        }
        .padding(28)
        .frame(width: 560, height: 470, alignment: .topLeading)
        .background(Brand.paper)
        .font(Brand.lato(14))
        .foregroundStyle(Brand.text)
    }

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "CCI Sermon Cutter" + (v.map { " \($0)" } ?? "")
    }
}

/// One folder: its name and where it is, Show in Finder and Change.
struct FolderCard: View {
    let title: String
    let detail: String
    let url: URL
    let set: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(title)
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Brand.coral)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(Brand.lato(15, .black))
                        .lineLimit(1)
                    Text(FolderCard.tilde(url.deletingLastPathComponent().path))
                        .font(Brand.lato(12))
                        .foregroundStyle(Brand.text2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(LinkButtonStyle())
                    .disabled(!FileManager.default.fileExists(atPath: url.path))
                Button("Change") { choose() }
                    .buttonStyle(PillButtonStyle(kind: .outline, size: .small))
            }
            .well()
            Text(detail)
                .font(Brand.lato(12))
                .foregroundStyle(Brand.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 20, padding: 18)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = url
        if panel.runModal() == .OK, let u = panel.url { set(u) }
    }

    static func tilde(_ path: String) -> String {
        path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }
}
