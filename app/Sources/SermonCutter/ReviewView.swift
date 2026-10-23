import SwiftUI
import SermonCutterCore

/// One Sunday. Three steps (Cut, Quality, Export), each the same window:
/// the player and timeline on the left, the step on the right. After the
/// export comes the last page.
struct ReviewView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var model: SundayModel

    var body: some View {
        Group {
            if model.page == .done {
                DonePage(model: model)
            } else {
                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 16) {
                        PlayerPane(model: model)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if model.page == .cut || !model.found {
                            ServiceTimelineCard(model: model)
                        } else {
                            CutTimelineCard(model: model)
                        }
                    }
                    .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
                    VStack(alignment: .leading, spacing: 14) {
                        StepTabs(model: model)
                        switch model.page {
                        case .cut, .done: CutPanel(model: model)
                        case .quality: QualityPanel(model: model)
                        case .export: ExportPanel(model: model)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .card(radius: 20, padding: 16)
                    .frame(width: 390)
                }
                .padding(20)
            }
        }
        .toolbar { header }
        .task(id: model.sunday.bannerPath) { await model.loadBanner() }
        .onChange(of: model.page) { _, page in
            // Quality and Export play the cut itself, from Start.
            if page == .quality || page == .export, let a = model.sunday.cutIn,
               let b = model.sunday.cutOut, model.playhead < a || model.playhead > b {
                model.seek(a)
            }
        }
        .sheet(isPresented: Binding(
            get: { model.endsPreview != nil },
            set: { if !$0 { model.endsPreview = nil } }
        )) {
            PreviewSheet(model: model)
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

    @ToolbarContentBuilder private var header: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 12) {
                Button {
                    app.closeSunday()
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold))
                }
                .buttonStyle(CircleButtonStyle())
                .help("Back to Home")
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.title.sermon)
                        .font(Brand.lato(15, .black))
                        .lineLimit(1)
                    Text(model.subtitle)
                        .font(Brand.lato(11.5))
                        .foregroundStyle(Brand.text2)
                        .lineLimit(1)
                }
            }
        }
        ToolbarItemGroup(placement: .automatic) {
            // A spacer in the toolbar pushes what follows to the right.
            Spacer()
            StatusChip(model: model)
            ExportPill(model: model)
        }
    }
}

/// 1 · Cut, 2 · Quality, 3 · Export.
struct StepTabs: View {
    @ObservedObject var model: SundayModel

    var body: some View {
        SegmentedPills(
            options: [
                .init(value: ReviewPage.cut, title: "1 · Cut"),
                .init(value: ReviewPage.quality, title: "2 · Quality", enabled: model.isReady),
                .init(value: ReviewPage.export, title: "3 · Export", enabled: model.isReady),
            ],
            selection: Binding(
                get: { model.page == .done ? .export : model.page },
                set: { model.page = $0 }
            )
        )
    }
}

/// The stream's verdict, or what's happening before there is one.
struct StatusChip: View {
    @ObservedObject var model: SundayModel

    var body: some View {
        if model.failedStep != nil && !model.isReady {
            Chip(text: "Couldn't get the Sunday ready", foreground: Brand.badFg, background: Brand.badBg, size: 13)
        } else if !model.isReady {
            working("Getting the Sunday ready")
        } else if model.checking {
            working("Checking the stream")
        } else if let q = model.sunday.quality {
            Chip(
                text: text(q.verdict),
                foreground: fg(q.verdict),
                background: bg(q.verdict),
                size: 13,
                dashed: model.qualityIsStale
            )
            .help(model.qualityIsStale ? "Checked before Start or End last moved. Check again on step 2." : q.reasons.joined(separator: " "))
            .onTapGesture { if model.page != .done { model.page = .quality } }
        } else {
            working("Checking the stream")
        }
    }

    private func working(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(text).font(Brand.lato(13, .bold))
        }
        .foregroundStyle(Brand.text2)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Brand.card2, in: Capsule())
        .fixedSize()
    }

    private func text(_ v: String) -> String {
        switch v {
        case "good": return "Stream quality good"
        case "tell_leads": return "Usable, tell the leads"
        default: return "Stream not usable"
        }
    }

    private func fg(_ v: String) -> Color {
        v == "good" ? Brand.goodFg : v == "tell_leads" ? Brand.warnFg : Brand.badFg
    }

    private func bg(_ v: String) -> Color {
        v == "good" ? Brand.goodBg : v == "tell_leads" ? Brand.warnBg : Brand.badBg
    }
}

/// Export, always at the top right; its progress while it runs.
struct ExportPill: View {
    @ObservedObject var model: SundayModel

    var body: some View {
        if model.exporting {
            Button {
                model.page = .export
            } label: {
                HStack(spacing: 10) {
                    ProgressBar(fraction: model.exportProgress, color: Brand.deepCoral, height: 6)
                        .frame(width: 56)
                    Text("Exporting · \(Int((model.exportProgress ?? 0) * 100))%")
                        .monospacedDigit()
                }
            }
            .buttonStyle(PillButtonStyle(kind: .tonal, size: .small))
        } else if model.page == .done {
            Chip(text: "Exported", foreground: Brand.goodFg, background: Brand.goodBg, size: 13)
        } else {
            Button {
                model.page = .export
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(PillButtonStyle(kind: .primary, size: .small))
            .disabled(!model.isReady)
        }
    }
}
