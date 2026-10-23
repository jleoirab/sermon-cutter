import AVFoundation
import SwiftUI
import SermonCutterCore

/// The last page: the finished sermon, how it was checked, where it went,
/// and the way back Home.
struct DonePage: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var model: SundayModel
    @State private var player = AVPlayer()
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 16) {
                ZStack {
                    Color.black
                    PlayerView(player: player, controls: .inline)
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                if let v = model.sunday.verify {
                    VStack(alignment: .leading, spacing: 10) {
                        Eyebrow("Checked before it was saved")
                        ForEach(v.lines(length: model.sunday.exported?.cutLen), id: \.text) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: line.passed ? "checkmark" : "xmark")
                                    .font(.system(size: 9, weight: .black))
                                    .foregroundStyle(line.passed ? Brand.goodFg : Brand.badFg)
                                    .frame(width: 18, height: 18)
                                    .background(line.passed ? Brand.goodBg : Brand.badBg, in: Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.text)
                                    if let d = line.detail {
                                        Text(d).font(Brand.lato(12)).foregroundStyle(Brand.badFg)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(radius: 20, padding: 18)
                }
            }
            .frame(width: 600)

            VStack(alignment: .leading, spacing: 16) {
                StepTabs(model: model)
                VStack(alignment: .leading, spacing: 4) {
                    headline
                        .font(Brand.anton(46))
                    if let out = model.sunday.exported {
                        Text("Exported \(Timecode.format(out.cutLen)) in \(Timecode.span(out.elapsedS)).")
                            .foregroundStyle(Brand.text2)
                    }
                }
                destination(
                    icon: "laptopcomputer",
                    label: "On this Mac",
                    title: placeText
                ) {
                    Button("Show in Finder") { model.showExportInFinder() }
                        .buttonStyle(PillButtonStyle(kind: .outline, size: .small))
                }
                if let note = model.sunday.quality?.note, !note.isEmpty {
                    destination(
                        icon: "text.bubble",
                        label: "For the leads",
                        title: "A short note on how the stream held up, ready to paste"
                    ) {
                        Button(copied ? "Copied" : "Copy the note") {
                            model.copyNote()
                            copied = true
                        }
                        .buttonStyle(PillButtonStyle(kind: .outline, size: .small))
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    Button("Export again") { model.page = .export }
                        .buttonStyle(LinkButtonStyle())
                    Spacer()
                    Button("Back to home") { app.closeSunday() }
                        .buttonStyle(PillButtonStyle(kind: .primary, size: .large))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 32)
        .frame(maxWidth: 1400, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity)
        .onAppear {
            if let p = model.sunday.exportPath, FileManager.default.fileExists(atPath: p) {
                player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: p)))
            }
        }
        .onDisappear { player.pause() }
    }

    private var passed: Bool { model.sunday.verify?.passed != false }

    private var headline: Text {
        passed
            ? Text("THE SERMON IS ") + Text("READY").foregroundStyle(Brand.coral)
            : Text("EXPORTED, BUT ") + Text("CHECK IT").foregroundStyle(Brand.coral)
    }

    /// "Service › Oct 11th 2026 › Oct 11th Sermon.mp4"
    private var placeText: String {
        guard let p = model.sunday.exportPath else { return "" }
        let url = URL(fileURLWithPath: p)
        let folder = url.deletingLastPathComponent()
        return [folder.deletingLastPathComponent().lastPathComponent, folder.lastPathComponent, url.lastPathComponent].joined(separator: " › ")
    }

    private func destination<Actions: View>(icon: String, label: String, title: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 40, height: 40)
                .background(Brand.card2, in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(label)
                Text(title)
                    .font(Brand.lato(14, .bold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: 10) { actions() }
            }
            Spacer(minLength: 0)
        }
        .card(radius: 16, padding: 16)
    }
}
