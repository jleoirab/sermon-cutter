import AppKit
import SwiftUI
import SermonCutterCore

/// Step 3: what will be made and where it goes, then the export itself.
struct ExportPanel: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var model: SundayModel
    @State private var confirmReplace = false

    var body: some View {
        if model.exporting {
            ExportingView(model: model)
        } else {
            ready
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export the sermon").font(Brand.lato(18, .black))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.exportURL?.lastPathComponent ?? "The sermon")
                            .font(Brand.lato(16, .black))
                        if let len = model.cutLength {
                            Text("\(Timecode.format(len)) · 1080p · \(size(len))")
                                .font(Brand.lato(13).monospacedDigit())
                                .foregroundStyle(Brand.text2)
                            Text("With the banner and fades at both ends. Takes about \(takes(len)).")
                                .font(Brand.lato(13))
                                .foregroundStyle(Brand.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .well()

                    Eyebrow("Where it goes")
                    HStack(spacing: 12) {
                        Image(systemName: "laptopcomputer")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 36, height: 36)
                            .background(Brand.card2, in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text("This Mac").font(Brand.lato(14, .black))
                            Text(whereText)
                                .font(Brand.lato(13))
                                .foregroundStyle(Brand.text2)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer(minLength: 6)
                        Button("Change", action: changeFolder)
                            .buttonStyle(LinkButtonStyle())
                            .help(model.folders.service.path)
                    }
                    .padding(12)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.border, lineWidth: 1))

                    if let e = model.exportError {
                        problem("The export didn't finish", e)
                    } else if let v = model.sunday.verify, !v.passed {
                        problem(
                            "The self-check found a problem",
                            v.lines(length: model.sunday.exported?.cutLen).filter { !$0.passed }
                                .map { "\($0.text): \($0.detail ?? "")" }.joined(separator: "\n")
                        )
                    } else if fileExists {
                        Text("This Sunday was exported before. Exporting again replaces that file.")
                            .font(Brand.lato(12))
                            .foregroundStyle(Brand.text2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            HStack(spacing: 10) {
                if let why = model.exportBlocker {
                    Text(why)
                        .font(Brand.lato(12))
                        .foregroundStyle(Brand.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Button {
                    if fileExists { confirmReplace = true } else { model.export(overwrite: false) }
                } label: {
                    Label("Export the sermon", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PillButtonStyle(kind: .primary, size: .large))
                .disabled(!model.canExport)
            }
        }
        .confirmationDialog("Replace the sermon already exported?", isPresented: $confirmReplace) {
            Button("Replace", role: .destructive) { model.export(overwrite: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A file with this name is already in the Sunday's folder.")
        }
    }

    private var fileExists: Bool {
        model.exportURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// "Service › Oct 11th 2026"
    private var whereText: String {
        guard let folder = model.exportURL?.deletingLastPathComponent() else { return model.folders.service.lastPathComponent }
        return "\(folder.deletingLastPathComponent().lastPathComponent) › \(folder.lastPathComponent)"
    }

    /// About 6 Mbps of picture and 192 kbps of sound.
    private func size(_ len: Double) -> String {
        let gb = len * 6.2e6 / 8 / 1e9
        return gb < 1 ? String(format: "about %.0f MB", gb * 1000) : String(format: "about %.1f GB", gb)
    }

    /// From this Mac's last export, or about 6.5 times faster than real time.
    private func takes(_ len: Double) -> String {
        let speed = model.sunday.exported?.speed ?? 6.5
        let minutes = max(1, Int((len / max(speed, 0.5) / 60).rounded()))
        return minutes == 1 ? "a minute" : "\(minutes) minutes"
    }

    private func problem(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Brand.lato(14, .black))
            Text(detail).font(Brand.lato(12)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Brand.badFg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Brand.badBg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func changeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose where finished sermons go. Each Sunday gets its own folder inside it."
        panel.directoryURL = model.folders.service
        if panel.runModal() == .OK, let url = panel.url {
            app.folders.service = url
            model.folders.service = url
        }
    }
}

/// While the export runs: how far it's got, and a way to stop.
struct ExportingView: View {
    @ObservedObject var model: SundayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Exporting the sermon").font(Brand.lato(18, .black))
            HStack {
                Spacer()
                ZStack {
                    ProgressRing(fraction: model.exportProgress ?? 0, lineWidth: 12)
                    VStack(spacing: 2) {
                        Text("\(Int((model.exportProgress ?? 0) * 100))%")
                            .font(Brand.anton(36))
                        Text(left)
                            .font(Brand.lato(12))
                            .foregroundStyle(Brand.text2)
                    }
                }
                .frame(width: 132, height: 132)
                Spacer()
            }
            .padding(.vertical, 6)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "laptopcomputer").font(.system(size: 13))
                    Text("Save to this Mac").font(Brand.lato(14, .black))
                    Spacer()
                    Text("\(Int((model.exportProgress ?? 0) * 100))%").font(Brand.lato(14, .black).monospacedDigit())
                }
                ProgressBar(fraction: model.exportProgress)
                Text(model.exportURL.map { "\($0.deletingLastPathComponent().lastPathComponent) › \($0.lastPathComponent)" } ?? "")
                    .font(Brand.lato(12))
                    .foregroundStyle(Brand.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .well()
            Text("You can keep using your Mac, or go back Home. The export keeps going, and the file is checked once it's done.")
                .font(Brand.lato(13))
                .foregroundStyle(Brand.text2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Stop exporting") { model.stopExport() }
                    .buttonStyle(PillButtonStyle(kind: .outline))
            }
        }
    }

    private var left: String {
        guard let eta = model.exportETA else { return "starting…" }
        if eta < 60 { return "under a minute left" }
        return "about \(Int((eta / 60).rounded())) min left"
    }
}
