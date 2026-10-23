import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SermonCutterCore

/// Step 1, on the right: Start, End and the banner. Until every
/// getting-ready step is done it shows those steps instead.
struct CutPanel: View {
    @ObservedObject var model: SundayModel

    var body: some View {
        if model.isReady {
            VStack(alignment: .leading, spacing: 14) {
                Text("Check the cut and the banner").font(Brand.lato(18, .black))
                ScrollView {
                    VStack(spacing: 12) {
                        StartCard(model: model)
                        EndCard(model: model)
                        BannerCard(model: model)
                    }
                }
                .scrollIndicators(.never)
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 0) {
                        Eyebrow("Length")
                        Text(model.cutLength.map { Timecode.format($0) } ?? "–")
                            .font(Brand.lato(18, .black).monospacedDigit())
                    }
                    Spacer(minLength: 8)
                    Button("Undo my changes") { model.resetCut() }
                        .buttonStyle(LinkButtonStyle())
                        .disabled(!model.cutChanged)
                    Button("Looks right ›") { model.page = .quality }
                        .buttonStyle(PillButtonStyle(kind: .tonal))
                }
            }
        } else {
            PreparingPanel(model: model)
        }
    }
}

// MARK: - Getting ready

struct PreparingPanel: View {
    @ObservedObject var model: SundayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Getting the Sunday ready").font(Brand.lato(18, .black))
            Text("This takes a few minutes. You can listen in the meantime. The cut opens once every step below is done.")
                .font(Brand.lato(13))
                .foregroundStyle(Brand.text2)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.steps) { step in
                    StepRow(step: step)
                }
            }
            .well()
            if let failed = model.failedStep, case .failed(let why) = failed.state {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(failed.title) didn't work").font(Brand.lato(14, .black))
                    Text(why).font(Brand.lato(13)).fixedSize(horizontal: false, vertical: true)
                    Button("Try again") { model.prepare() }
                        .buttonStyle(PillButtonStyle(kind: .primary, size: .small))
                }
                .foregroundStyle(Brand.badFg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Brand.badBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            Spacer(minLength: 0)
        }
    }
}

struct StepRow: View {
    let step: Step

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 22, height: 22)
            Text(step.title)
                .font(Brand.lato(14, .bold))
                .foregroundStyle(step.state == .waiting ? Brand.text2 : Brand.text)
            Spacer(minLength: 6)
            Text(trailing)
                .font(Brand.lato(12).monospacedDigit())
                .foregroundStyle(Brand.text2)
                .lineLimit(1)
        }
    }

    @ViewBuilder private var icon: some View {
        switch step.state {
        case .waiting:
            Circle().stroke(Brand.outline, lineWidth: 2).padding(2)
        case .running(let f):
            if let f {
                ProgressRing(fraction: f, lineWidth: 3).padding(2)
            } else {
                ProgressView().controlSize(.small)
            }
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Brand.goodFg)
                .frame(width: 22, height: 22)
                .background(Brand.goodBg, in: Circle())
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Brand.badFg)
                .frame(width: 22, height: 22)
                .background(Brand.badBg, in: Circle())
        }
    }

    private var trailing: String {
        switch step.state {
        case .running(let f?): return "\(Int(f * 100))%"
        case .running: return step.detail ?? ""
        case .done: return step.detail ?? "Done"
        default: return ""
        }
    }
}

// MARK: - Start and End

/// A time as h:mm:ss.t that can be typed over; Return applies it.
struct TimeField: View {
    let value: Double?
    let set: (Double) -> Void
    let label: String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("h:mm:ss", text: $text)
            .textFieldStyle(.plain)
            .font(Brand.lato(20, .black).monospacedDigit())
            .focused($focused)
            .accessibilityLabel(label)
            .onSubmit {
                if let t = Timecode.parse(text) { set(t) } else { reset() }
                focused = false
            }
            .onAppear(perform: reset)
            .onChange(of: value) { _, _ in if !focused { reset() } }
            .onChange(of: focused) { _, f in if !f { reset() } }
    }

    private func reset() {
        text = value.map { Timecode.format($0, tenths: true) } ?? ""
    }
}

struct ListenButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill").font(.system(size: 11, weight: .bold))
        }
        .buttonStyle(CircleButtonStyle(diameter: 32, background: Brand.card))
        .help(help)
    }
}

/// How sure the engine is about a point, in plain words.
struct ConfidenceChip: View {
    let confidence: String

    var body: some View {
        switch confidence {
        case "high":
            Chip(text: "Sure", foreground: Brand.goodFg, background: Brand.goodBg)
                .help("A glance is enough.")
        case "medium":
            Chip(text: "Give it a listen", foreground: Brand.warnFg, background: Brand.warnBg)
                .help("Listen to the few seconds around it.")
        default:
            Chip(text: "Check it", foreground: Brand.badFg, background: Brand.badBg)
                .help("Listen and set it yourself.")
        }
    }
}

struct Nudges: View {
    let value: Double?
    let set: (Double) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach([-5.0, -1.0, 1.0, 5.0], id: \.self) { d in
                Button(d > 0 ? "+\(Int(d)) s" : "−\(Int(-d)) s") {
                    if let value { set(value + d) }
                }
                .buttonStyle(PillButtonStyle(kind: .outline, size: .small))
                .help(d > 0 ? "Later by \(Int(d)) s" : "Earlier by \(Int(-d)) s")
            }
        }
    }
}

struct StartCard: View {
    @ObservedObject var model: SundayModel
    @State private var editingLeadIn = false
    @State private var leadIn = ""

    var body: some View {
        let f = model.sunday.find
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Eyebrow("Start").frame(width: 44, alignment: .leading)
                TimeField(value: model.sunday.cutIn, set: set, label: "Start time")
                ListenButton(help: "Listen from the start") {
                    if let a = model.sunday.cutIn { model.play(from: a) }
                }
            }
            if let f {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ConfidenceChip(confidence: f.startConfidence)
                    Text(evidence(f))
                        .font(Brand.lato(13))
                        .foregroundStyle(Brand.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 6) {
                Nudges(value: model.sunday.cutIn, set: set)
                Spacer(minLength: 4)
                Button("Change") {
                    leadIn = Timecode.format(model.sunday.leadIn)
                    editingLeadIn = true
                }
                .buttonStyle(LinkButtonStyle(size: 12))
                .help("How much worship to keep before the preacher starts")
                .popover(isPresented: $editingLeadIn, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Worship kept before the preacher").font(Brand.lato(13, .black))
                        HStack {
                            TextField("2:00", text: $leadIn)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .onSubmit(applyLeadIn)
                            Button("Apply", action: applyLeadIn)
                                .buttonStyle(PillButtonStyle(kind: .primary, size: .small))
                                .disabled(Timecode.parse(leadIn) == nil)
                        }
                        Text("Usually 2:00. Start moves to that long before the preacher.")
                            .font(Brand.lato(12))
                            .foregroundStyle(Brand.text2)
                    }
                    .padding(16)
                    .frame(width: 280)
                }
            }
        }
        .well()
    }

    private func set(_ t: Double) {
        model.setIn(t)
        if let a = model.sunday.cutIn { model.seek(a) }
    }

    private func evidence(_ f: FindResult) -> String {
        let kept = Double(f.preacherStarts) - (model.sunday.cutIn ?? f.cutIn)
        let keptText = kept >= 1 ? "\(Timecode.span(kept)) of worship \(kept < 120 ? "is" : "are") kept before that." : "Nothing before that is kept."
        return "The preacher starts at \(Timecode.format(Double(f.preacherStarts))). \(keptText)"
    }

    private func applyLeadIn() {
        guard let s = Timecode.parse(leadIn) else { return }
        model.applyLeadIn(s)
        if let a = model.sunday.cutIn { model.seek(a) }
        editingLeadIn = false
    }
}

struct EndCard: View {
    @ObservedObject var model: SundayModel

    var body: some View {
        let f = model.sunday.find
        let words = model.transcript.map { $0.around(model.sunday.cutOut ?? 0) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Eyebrow("End").frame(width: 44, alignment: .leading)
                TimeField(value: model.sunday.cutOut, set: set, label: "End time")
                ListenButton(help: "Listen to the last 10 seconds") {
                    if let b = model.sunday.cutOut { model.play(from: max(0, b - 10)) }
                }
            }
            if let f {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ConfidenceChip(confidence: f.outConfidence)
                    Text(words.map { !$0.before.isEmpty } == true ? "What we heard at the end. Click a word to end the cut there." : evidence(f))
                        .font(Brand.lato(13))
                        .foregroundStyle(Brand.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let words, !words.before.isEmpty {
                WordsBox(before: words.before, after: words.after, cue: f?.outCue) { w in
                    set(w.end)
                    model.play(from: max(0, w.end - 4))
                }
            }
            Nudges(value: model.sunday.cutOut, set: set)
        }
        .well()
    }

    private func set(_ t: Double) {
        model.setOut(t)
        if let b = model.sunday.cutOut { model.seek(max(0, b - 3)) }
    }

    private func evidence(_ f: FindResult) -> String {
        switch f.outMethod {
        case "seat_cue":
            return "Heard: “\(f.outCue?.context ?? "")”"
        case "prayer_before_handover":
            return "The end of the closing prayer, before someone else took over: “\(f.outCue?.context ?? "")”"
        case "prayer_close":
            return "No “please be seated” was heard; this is the end of the closing prayer before the offering."
        default:
            return "Nothing was heard to place it; this is where the preaching stops. Listen and set it."
        }
    }
}

/// The words heard around End. The cue ("please be seated") is highlighted;
/// a thin coral bar marks where the cut ends. Click a word to end there.
struct WordsBox: View {
    let before: [Transcript.Word]
    let after: [Transcript.Word]
    let cue: SeatCue?
    let pick: (Transcript.Word) -> Void

    var body: some View {
        let cueWords = WordsBox.cueWords(before + after, near: cue?.at)
        FlowLayout(spacing: 4, lineSpacing: 6) {
            Text("…").foregroundStyle(Brand.text2)
            ForEach(WordsBox.chunks(before, highlighted: { cueWords.contains($0) })) { c in
                chunk(c, dimmed: false)
            }
            RoundedRectangle(cornerRadius: 1).fill(Brand.coral).frame(width: 2, height: 18)
                .accessibilityLabel("The cut ends here")
            ForEach(WordsBox.chunks(after, highlighted: { cueWords.contains(before.count + $0) })) { c in
                chunk(c, dimmed: true)
            }
            Text("…").foregroundStyle(Brand.text2)
        }
        .font(Brand.lato(14))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Which words say "please be seated" (or "you may be seated", "sit
    /// down", "take your seats"): the one heard nearest the cue.
    static func cueWords(_ words: [Transcript.Word], near t: Double?) -> Set<Int> {
        guard let t else { return [] }
        let tokens = words.map { $0.text.lowercased().filter(\.isLetter) }
        var best: (ClosedRange<Int>, Double)?
        for (i, tok) in tokens.enumerated() {
            var j = i
            switch tok {
            case "seated":
                if j > 0, tokens[j - 1] == "be" {
                    j -= 1
                    if j > 0, ["please", "may"].contains(tokens[j - 1]) {
                        j -= 1
                        if tokens[j] == "may", j > 0, tokens[j - 1] == "you" { j -= 1 }
                    }
                }
            case "down":
                guard i > 0, tokens[i - 1] == "sit" else { continue }
                j = i - 1
                if j > 0, tokens[j - 1] == "please" { j -= 1 }
            case "seat", "seats":
                while j > 0, i - j < 3, ["your", "a", "have", "take", "please"].contains(tokens[j - 1]) { j -= 1 }
            default:
                continue
            }
            let d = abs(words[i].start - t)
            if best == nil || d < best!.1 { best = (j...i, d) }
        }
        guard let best, best.1 < 30 else { return [] }
        return Set(best.0)
    }

    /// A word, or the cue's words run together as one highlighted phrase.
    struct Chunk: Identifiable {
        let id: Int
        let words: [Transcript.Word]
        let highlighted: Bool
        var text: String { words.map(\.text).joined(separator: " ") }
    }

    static func chunks(_ words: [Transcript.Word], highlighted: (Int) -> Bool) -> [Chunk] {
        var out: [Chunk] = []
        for (i, w) in words.enumerated() {
            let h = highlighted(i)
            if h, let last = out.last, last.highlighted {
                out[out.count - 1] = Chunk(id: last.id, words: last.words + [w], highlighted: true)
            } else {
                out.append(Chunk(id: i, words: [w], highlighted: h))
            }
        }
        return out
    }

    private func chunk(_ c: Chunk, dimmed: Bool) -> some View {
        Button {
            if let last = c.words.last { pick(last) }
        } label: {
            Text(c.text)
                .font(Brand.lato(14, c.highlighted ? .black : .regular))
                .foregroundStyle(c.highlighted ? Brand.highlightFg : dimmed ? Brand.text2 : Brand.text)
                .padding(.horizontal, c.highlighted ? 5 : 0)
                .padding(.vertical, c.highlighted ? 1 : 0)
                .background(c.highlighted ? Brand.highlightBg : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("End the cut after “\(c.words.last?.text ?? "")”")
    }
}

/// Lays its children out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width {
                y += line + lineSpacing
                x = 0
                line = 0
            }
            x += s.width + spacing
            line = max(line, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX {
                y += line + lineSpacing
                x = bounds.minX
                line = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}

// MARK: - Banner

struct BannerCard: View {
    @ObservedObject var model: SundayModel
    @State private var choosing = false
    @State private var targeted = false
    @State private var pastingLink = false
    @State private var link = ""
    @State private var fetching = false
    @State private var linkError: String?

    var body: some View {
        Group {
            if model.sunday.bannerPath == nil {
                empty
            } else {
                chosen
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(targeted ? Brand.coral : .clear, lineWidth: 2)
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { BannerCard.isImage($0) }) else { return false }
            model.setBanner(url)
            return true
        } isTargeted: { targeted = $0 }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.png, .jpeg, .webP, .image]) { result in
            if case .success(let url) = result { model.setBanner(url) }
        }
        .popover(isPresented: $pastingLink, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Paste the banner's Google Drive link").font(Brand.lato(13, .black))
                HStack {
                    TextField("https://drive.google.com/…", text: $link)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                        .onSubmit(fetch)
                        .onChange(of: link) { linkError = nil }
                    if fetching {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Get", action: fetch)
                            .buttonStyle(PillButtonStyle(kind: .primary, size: .small))
                            .disabled(DriveLink.fileID(link) == nil)
                    }
                }
                if let linkError {
                    Text(linkError).font(Brand.lato(12)).foregroundStyle(Brand.badFg)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 320, alignment: .leading)
                }
            }
            .padding(16)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("Banner")
            Text("Add this Sunday's banner").font(Brand.lato(14, .black))
            Text("Drop the image here, choose the file, or paste its Google Drive link.")
                .font(Brand.lato(13))
                .foregroundStyle(Brand.text2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Choose a file…") { choosing = true }
                    .buttonStyle(PillButtonStyle(kind: .primary, size: .small))
                Button("Paste a Drive link…") { pastingLink = true }
                    .buttonStyle(PillButtonStyle(kind: .outline, size: .small))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Brand.outline, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        )
    }

    private var chosen: some View {
        HStack(spacing: 12) {
            thumbnail
                .frame(width: 112, height: 63)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Eyebrow("Banner")
                Text((model.sunday.bannerPath.map { ($0 as NSString).lastPathComponent }) ?? "")
                    .font(Brand.lato(13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if model.bannerUnreadable {
                    Text("Couldn't open it. Choose it again, or allow Documents in System Settings › Privacy & Security › Files and Folders.")
                        .font(Brand.lato(12))
                        .foregroundStyle(Brand.warnFg)
                        .fixedSize(horizontal: false, vertical: true)
                } else if model.bannerImage == nil {
                    SlowNote(text: "Waiting for macOS. If it asks to let CCI Sermon Cutter open Documents, choose Allow.")
                }
                HStack(spacing: 14) {
                    Menu {
                        Button("Choose a file…") { choosing = true }
                        Button("Paste a Google Drive link…") { pastingLink = true }
                    } label: {
                        Text("Replace")
                    }
                    .menuStyle(.button)
                    .buttonStyle(LinkButtonStyle())
                    .menuIndicator(.hidden)
                    .fixedSize()
                    Button("Preview the ends ›") { model.endsPreview = "opening" }
                        .buttonStyle(LinkButtonStyle())
                        .disabled(!model.hasVideo || model.bannerImage == nil)
                        .help(model.hasVideo ? "Watch the first and last 20 seconds as they'll be exported" : "Once the video has downloaded")
                }
            }
            Spacer(minLength: 0)
        }
        .well()
    }

    @ViewBuilder private var thumbnail: some View {
        if let image = model.bannerImage {
            BannerFrame(image: image)
        } else if model.bannerUnreadable {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Brand.warnFg)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Brand.warnBg)
                .help("Couldn't open the banner. If you said no when macOS asked about Documents, turn it on in System Settings › Privacy & Security › Files and Folders, or choose the banner again.")
        } else {
            BannerWaiting()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Brand.card)
        }
    }

    private func fetch() {
        guard DriveLink.fileID(link) != nil, !fetching else { return }
        fetching = true
        linkError = nil
        Task {
            do {
                try await model.fetchBanner(from: link)
                link = ""
                pastingLink = false
            } catch {
                linkError = error.localizedDescription
            }
            fetching = false
        }
    }

    static func isImage(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "webp"].contains(url.pathExtension.lowercased())
    }
}

/// A spinner for the banner while it opens.
struct BannerWaiting: View {
    var body: some View {
        ProgressView().controlSize(.small)
    }
}

/// A note that only appears if something takes more than a moment. For the
/// banner that most likely means macOS is waiting for an answer about
/// Documents.
struct SlowNote: View {
    let text: String
    @State private var slow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Always something here, so the timer starts even before the note shows.
            Color.clear.frame(width: 0, height: 0)
            if slow {
                Text(text)
                    .font(Brand.lato(12))
                    .foregroundStyle(Brand.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { slow = true }
        }
    }
}
