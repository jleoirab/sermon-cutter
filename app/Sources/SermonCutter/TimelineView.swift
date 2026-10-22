import SwiftUI
import SermonCutterCore

/// The timeline track: the whole service as music and speech bands, the cut
/// between its In and Out handles, the quality strip, and the playhead.
/// Drag a handle to move it (the player follows); click anywhere else to
/// play from there. Zoom in to see the loudness and cut to the second.
struct TimelineView: View {
    @ObservedObject var model: SundayModel
    @State private var zoom: Zoom = .whole
    @State private var focus: Double?
    @State private var dragging: Grab?

    enum Zoom: String, CaseIterable, Identifiable {
        case whole = "Whole service"
        case tenMinutes = "10 min"
        case minute = "1 min"
        var id: String { rawValue }
        var span: Double? {
            switch self {
            case .whole: return nil
            case .tenMinutes: return 600
            case .minute: return 60
            }
        }
    }

    enum Grab { case cutIn, cutOut, seek }

    private let bandTop: CGFloat = 0
    private let bandHeight: CGFloat = 54
    private let stripTop: CGFloat = 60
    private let stripHeight: CGFloat = 10
    private let tickTop: CGFloat = 76

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("Zoom", selection: $zoom) {
                    ForEach(Zoom.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 270)
                .onChange(of: zoom) { _, _ in
                    if focus == nil { focus = model.playhead }
                }
                Button("In") { show(model.sunday.cutIn) }
                    .help("Zoom to the In point")
                Button("Out") { show(model.sunday.cutOut) }
                    .help("Zoom to the Out point")
                Button {
                    model.togglePlay()
                } label: {
                    Image(systemName: "playpause.fill")
                }
                .keyboardShortcut(.space, modifiers: [])
                .help("Play or pause (space)")
                Spacer()
                Text(Timecode.format(model.playhead, tenths: true))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let range = visibleRange
                Canvas { ctx, size in
                    draw(&ctx, size: size, range: range)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in drag(v, width: geo.size.width, range: range) }
                        .onEnded { _ in
                            if let g = dragging, g != .seek {
                                focus = g == .cutIn ? model.sunday.cutIn : model.sunday.cutOut
                            }
                            dragging = nil
                        }
                )
            }
            .frame(height: 96)
            legend
        }
    }

    // MARK: - Geometry

    private var visibleRange: ClosedRange<Double> {
        let total = max(model.duration, 1)
        guard let span = zoom.span, span < total else { return 0...total }
        let center = focus ?? model.playhead
        var lo = center - span / 2
        lo = max(0, min(lo, total - span))
        return lo...(lo + span)
    }

    private func x(_ t: Double, _ width: CGFloat, _ r: ClosedRange<Double>) -> CGFloat {
        CGFloat((t - r.lowerBound) / (r.upperBound - r.lowerBound)) * width
    }

    private func time(_ x: CGFloat, _ width: CGFloat, _ r: ClosedRange<Double>) -> Double {
        r.lowerBound + Double(max(0, min(x, width)) / max(width, 1)) * (r.upperBound - r.lowerBound)
    }

    private func show(_ t: Double?) {
        guard let t else { return }
        if zoom == .whole { zoom = .minute }
        focus = t
        model.seek(t)
    }

    private func drag(_ v: DragGesture.Value, width: CGFloat, range: ClosedRange<Double>) {
        if dragging == nil {
            let sx = v.startLocation.x
            if let a = model.sunday.cutIn, abs(sx - x(a, width, range)) < 10 {
                dragging = .cutIn
            } else if let b = model.sunday.cutOut, abs(sx - x(b, width, range)) < 10 {
                dragging = .cutOut
            } else {
                dragging = .seek
            }
        }
        let t = time(v.location.x, width, range)
        switch dragging {
        case .cutIn:
            model.setIn(t)
            model.seek(model.sunday.cutIn ?? t)
        case .cutOut:
            model.setOut(t)
            model.seek(model.sunday.cutOut ?? t)
        default:
            model.seek(t)
        }
    }

    // MARK: - Drawing

    private func color(_ kind: String) -> Color {
        switch kind {
        case "music": return .purple.opacity(0.45)
        case "speech": return .orange.opacity(0.5)
        case "silent": return .black.opacity(0.4)
        default: return .gray.opacity(0.25)
        }
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, range r: ClosedRange<Double>) {
        let w = size.width
        let band = CGRect(x: 0, y: bandTop, width: w, height: bandHeight)
        ctx.fill(Path(roundedRect: band, cornerRadius: 4), with: .color(.gray.opacity(0.12)))

        // Music and speech.
        for run in model.sunday.find?.runs ?? [] where Double(run.end) > r.lowerBound && Double(run.start) < r.upperBound {
            let x0 = max(0, x(Double(run.start), w, r))
            let x1 = min(w, x(Double(run.end), w, r))
            ctx.fill(Path(CGRect(x: x0, y: bandTop, width: max(1, x1 - x0), height: bandHeight)), with: .color(color(run.kind)))
        }

        // Loudness, when zoomed in far enough to read it.
        if let loud = model.loudness, r.upperBound - r.lowerBound <= 900 {
            var wave = Path()
            let step: CGFloat = 2
            var px: CGFloat = 0
            while px < w {
                let t0 = time(px, w, r), t1 = time(px + step, w, r)
                if let db = loud.peak(from: t0, to: t1) {
                    let h = CGFloat(max(0, min(1, (Double(db) + 60) / 60))) * (bandHeight - 6)
                    let mid = bandTop + bandHeight / 2
                    wave.addRect(CGRect(x: px, y: mid - h / 2, width: step - 0.5, height: max(1, h)))
                }
                px += step
            }
            ctx.fill(wave, with: .color(.primary.opacity(0.55)))
        }

        // Dim what's outside the cut.
        if let a = model.sunday.cutIn, let b = model.sunday.cutOut {
            let xa = x(a, w, r), xb = x(b, w, r)
            if xa > 0 { ctx.fill(Path(CGRect(x: 0, y: bandTop, width: min(xa, w), height: bandHeight)), with: .color(.black.opacity(0.35))) }
            if xb < w { ctx.fill(Path(CGRect(x: max(0, xb), y: bandTop, width: w - max(0, xb), height: bandHeight)), with: .color(.black.opacity(0.35))) }
        }

        // Quality: each minute of the cut.
        if let q = model.sunday.quality {
            for (m, status) in q.minutes.enumerated() {
                let t0 = q.cutIn + 60 * Double(m)
                let t1 = min(t0 + 60, q.cutOut)
                guard t1 > r.lowerBound, t0 < r.upperBound else { continue }
                let x0 = max(0, x(t0, w, r)), x1 = min(w, x(t1, w, r))
                let c: Color = status == "bad" ? .red : status == "warn" ? .orange : .green
                ctx.fill(Path(CGRect(x: x0, y: stripTop, width: max(1, x1 - x0 - 0.5), height: stripHeight)),
                         with: .color(c.opacity(model.qualityIsStale ? 0.25 : 0.65)))
            }
        }

        // Ticks.
        let span = r.upperBound - r.lowerBound
        let tick: Double = span > 5400 ? 900 : span > 1800 ? 300 : span > 400 ? 60 : span > 100 ? 15 : 5
        var t = (r.lowerBound / tick).rounded(.up) * tick
        while t <= r.upperBound {
            let tx = x(t, w, r)
            if tx > 18 && tx < w - 18 {
                ctx.fill(Path(CGRect(x: tx, y: tickTop, width: 1, height: 4)), with: .color(.secondary))
                ctx.draw(Text(Timecode.format(t)).font(.system(size: 9).monospacedDigit()).foregroundColor(.secondary),
                         at: CGPoint(x: tx, y: tickTop + 12), anchor: .center)
            }
            t += tick
        }

        // Where the preacher starts and where the seat cue was heard.
        if let f = model.sunday.find {
            mark(&ctx, at: x(Double(f.preacherStarts), w, r), label: "preacher", w: w)
            if let cue = f.outCue { mark(&ctx, at: x(cue.at, w, r), label: "seat cue", w: w) }
        }

        // In and Out handles.
        if let a = model.sunday.cutIn { handle(&ctx, at: x(a, w, r), label: "In", w: w) }
        if let b = model.sunday.cutOut { handle(&ctx, at: x(b, w, r), label: "Out", w: w) }

        // Playhead.
        let px = x(model.playhead, w, r)
        if px >= 0 && px <= w {
            ctx.fill(Path(CGRect(x: px - 0.75, y: bandTop, width: 1.5, height: stripTop + stripHeight)), with: .color(.red))
        }
    }

    private func mark(_ ctx: inout GraphicsContext, at x: CGFloat, label: String, w: CGFloat) {
        guard x >= 0 && x <= w else { return }
        var p = Path()
        p.move(to: CGPoint(x: x, y: bandTop))
        p.addLine(to: CGPoint(x: x, y: bandTop + bandHeight))
        ctx.stroke(p, with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }

    private func handle(_ ctx: inout GraphicsContext, at x: CGFloat, label: String, w: CGFloat) {
        guard x >= -6 && x <= w + 6 else { return }
        ctx.fill(Path(CGRect(x: x - 1, y: bandTop - 2, width: 2, height: stripTop + stripHeight + 2)), with: .color(.accentColor))
        let knob = CGRect(x: x - 5, y: bandTop + bandHeight / 2 - 11, width: 10, height: 22)
        ctx.fill(Path(roundedRect: knob, cornerRadius: 3), with: .color(.accentColor))
        let right = label == "In"
        ctx.draw(Text(label).font(.caption2.bold()).foregroundColor(.white),
                 at: CGPoint(x: x + (right ? 8 : -8), y: bandTop + 8), anchor: right ? .leading : .trailing)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            swatch(.purple.opacity(0.6), "Music")
            swatch(.orange.opacity(0.6), "Speech")
            swatch(.green.opacity(0.7), "Quality, minute by minute")
            Spacer()
            Text("Drag In or Out to move them; click to play from there.")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func swatch(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 10)
            Text(label)
        }
    }
}
