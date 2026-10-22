import SwiftUI
import SermonCutterCore

/// One Sunday: progress while it prepares, then the Review screen with the
/// player and timeline on the left and the decisions on the right.
struct SundayView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var model: SundayModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    PlayerView(player: model.player)
                        .frame(minHeight: 280)
                    Divider()
                    TimelineView(model: model)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                    EndsTrack(model: model)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .frame(minWidth: 620)
                InspectorView(model: model)
                    .frame(minWidth: 340, idealWidth: 380, maxWidth: 460)
            }
        }
        .sheet(isPresented: Binding(
            get: { model.previewEnd != nil },
            set: { if !$0 { model.closePreview() } }
        )) {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.previewEnd == "opening" ? "The opening, as it will export" : "The closing, as it will export")
                    .font(.headline)
                PlayerView(player: model.previewPlayer)
                    .frame(width: 800, height: 450)
                HStack {
                    Text("Change the holds and fades on the right, then preview again.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") { model.closePreview() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.problem != nil },
            set: { if !$0 { model.problem = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.problem ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Button {
                app.closeSunday()
            } label: {
                Label("Streams", systemImage: "chevron.left")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.title3.weight(.semibold)).lineLimit(1)
                if let d = model.dateText {
                    Text(d).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !model.allDone || model.anyFailed {
                StepsBar(steps: model.steps)
            }
            if let q = model.sunday.quality {
                VerdictBadge(report: q, stale: model.qualityIsStale)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// The preparation steps, each with a tick, a spinner or a cross.
struct StepsBar: View {
    let steps: [Step]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(steps) { step in
                HStack(spacing: 4) {
                    icon(step.state)
                    Text(step.title).font(.caption)
                        .foregroundStyle(step.state == .waiting ? .secondary : .primary)
                }
                .help(help(step))
            }
        }
    }

    @ViewBuilder private func icon(_ s: StepState) -> some View {
        switch s {
        case .waiting:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running(let f):
            if let f {
                ProgressView(value: f).progressViewStyle(.circular).controlSize(.mini)
            } else {
                ProgressView().controlSize(.mini)
            }
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private func help(_ step: Step) -> String {
        if case .failed(let why) = step.state { return why }
        if case .running(let f) = step.state, let f {
            return "\(step.detail ?? step.title): \(Int(f * 100))%"
        }
        return step.detail ?? step.title
    }
}

struct VerdictBadge: View {
    let report: QualityReport
    let stale: Bool

    var body: some View {
        Text(report.headline)
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(stale ? 0.06 : 0.18), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(stale ? 0.35 : 0.7), style: StrokeStyle(lineWidth: 1, dash: stale ? [3, 2] : [])))
            .help(stale ? "Checked before In or Out last moved; check again to update." : report.reasons.joined(separator: " "))
    }

    var color: Color { VerdictBadge.color(report.verdict) }

    static func color(_ verdict: String) -> Color {
        switch verdict {
        case "good": return .green
        case "tell_leads": return .orange
        default: return .red
        }
    }
}
