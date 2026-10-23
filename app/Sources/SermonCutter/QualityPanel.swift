import SwiftUI
import SermonCutterCore

/// Step 2: how the stream held up, minute by minute, with each problem and a
/// note for the leads.
struct QualityPanel: View {
    @ObservedObject var model: SundayModel
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How the stream held up").font(Brand.lato(18, .black))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let q = model.sunday.quality {
                        VerdictCard(report: q)
                        if model.qualityIsStale {
                            HStack(spacing: 10) {
                                Text("Start or End moved since this check.")
                                    .font(Brand.lato(13))
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 6)
                                if model.checking {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Button("Check again") { model.recheck() }
                                        .buttonStyle(PillButtonStyle(kind: .dark, size: .small))
                                }
                            }
                            .well(padding: 12)
                        }
                        minutes(q)
                        if !q.videoChecked {
                            Text(model.hasVideo ? "Checking the picture now." : "The picture is checked once the video has downloaded.")
                                .font(Brand.lato(12))
                                .foregroundStyle(Brand.text2)
                        }
                        if !q.issues.isEmpty {
                            issues(q)
                        }
                        if !q.note.isEmpty {
                            Button(copied ? "Copied" : "Copy a note for the leads") {
                                model.copyNote()
                                copied = true
                            }
                            .buttonStyle(PillButtonStyle(kind: .tonal, size: .small))
                            .help("A short message listing the problems, ready to paste")
                        }
                        if q.verdict == "not_usable" {
                            Text("If there's another stream of this service, go back Home and prepare that one instead. You can still export this one.")
                                .font(Brand.lato(13))
                                .foregroundStyle(Brand.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Checking the stream for gaps in the sound and the picture…")
                                .font(Brand.lato(13))
                                .foregroundStyle(Brand.text2)
                        }
                        .well()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            HStack {
                Spacer()
                Button("Next: export ›") { model.page = .export }
                    .buttonStyle(PillButtonStyle(kind: .tonal))
            }
        }
    }

    private func minutes(_ q: QualityReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow("Minute by minute")
            HStack(spacing: 1) {
                ForEach(Array(q.minutes.enumerated()), id: \.offset) { _, status in
                    RoundedRectangle(cornerRadius: 2).fill(Brand.minute(status))
                }
            }
            .frame(height: 22)
            .opacity(model.qualityIsStale ? 0.4 : 1)
            HStack {
                Text("Start")
                Spacer()
                if q.minutes.count > 40 { Text("30 min"); Spacer() }
                if q.minutes.count > 70 { Text("60 min"); Spacer() }
                Text("End")
            }
            .font(Brand.lato(11))
            .foregroundStyle(Brand.text2)
        }
    }

    private func issues(_ q: QualityReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("Times into the sermon")
            ForEach(q.issues.prefix(30)) { issue in
                HStack(spacing: 10) {
                    Text(issue.intoCutTc)
                        .font(Brand.lato(13, .black).monospacedDigit())
                        .frame(width: 54, alignment: .leading)
                    Image(systemName: issue.isSound ? "speaker.slash" : "tv.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(Brand.text2)
                    Text("\(issue.what.prefix(1).uppercased() + issue.what.dropFirst()) for \(Timecode.span(issue.len))")
                        .font(Brand.lato(13))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Button(issue.isSound ? "Listen" : "Watch") {
                        model.play(from: max(0, issue.start - 3))
                    }
                    .buttonStyle(LinkButtonStyle(size: 12))
                    .help("Stream time \(issue.streamTc)")
                }
            }
        }
        .well(padding: 12)
    }
}

/// The verdict, once, in its colour.
struct VerdictCard: View {
    let report: QualityReport

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(Brand.card)
                .frame(width: 36, height: 36)
                .background(fg, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Brand.lato(16, .black))
                ForEach(report.reasons, id: \.self) { r in
                    Text(r).font(Brand.lato(13)).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(fg)
        .padding(14)
        .background(bg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var title: String {
        switch report.verdict {
        case "good": return "Good"
        case "tell_leads": return "Usable, tell the leads"
        default: return "Not usable"
        }
    }

    private var icon: String {
        switch report.verdict {
        case "good": return "checkmark"
        case "tell_leads": return "exclamationmark"
        default: return "xmark"
        }
    }

    private var fg: Color {
        switch report.verdict {
        case "good": return Brand.goodFg
        case "tell_leads": return Brand.warnFg
        default: return Brand.badFg
        }
    }

    private var bg: Color {
        switch report.verdict {
        case "good": return Brand.goodBg
        case "tell_leads": return Brand.warnBg
        default: return Brand.badBg
        }
    }
}
