import SwiftUI
import SermonCutterCore

/// Step 1's timeline: the whole service as music and speech, the cut between
/// its Start and End handles, quality minute by minute under the cut, and
/// the playhead. Drag a handle to move it (the player follows); click
/// anywhere else to listen from there.
struct ServiceTimelineCard: View {
    @ObservedObject var model: SundayModel
    @State private var dragging: Grab?

    enum Grab { case cutIn, cutOut, seek }

    private let bandTop: CGFloat = 18
    private let bandHeight: CGFloat = 48
    private let stripTop: CGFloat = 71
    private let stripHeight: CGFloat = 8
    private let tickTop: CGFloat = 84

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button("Go to start") { if let a = model.sunday.cutIn { model.play(from: a) } }
                    .buttonStyle(LinkButtonStyle(size: 12))
                Button("Go to end") { if let b = model.sunday.cutOut { model.play(from: max(0, b - 10)) } }
                    .buttonStyle(LinkButtonStyle(size: 12))
                Spacer()
                Legend(color: Brand.music, text: "Music")
                Legend(color: Brand.speech, text: "Speech")
            }
            .disabled(!model.found)
            GeometryReader { geo in
                Canvas { ctx, size in draw(&ctx, size: size) }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in drag(v, width: geo.size.width) }
                            .onEnded { _ in dragging = nil }
                    )
            }
            .frame(height: 100)
            HStack(spacing: 14) {
                QualityLegend(model: model)
                HStack(spacing: 5) {
                    Rectangle().fill(.clear).frame(width: 1, height: 12)
                        .overlay(Rectangle().stroke(Brand.mark, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])))
                    Text("Preacher starts")
                }
                Spacer()
                Text("Drag Start or End. Click anywhere to listen.")
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .font(Brand.lato(12))
            .foregroundStyle(Brand.text2)
        }
        .card(radius: 20, padding: 16)
    }

    // MARK: - Geometry

    private var total: Double { max(model.duration, 1) }
    private func x(_ t: Double, _ w: CGFloat) -> CGFloat { CGFloat(t / total) * w }
    private func time(_ x: CGFloat, _ w: CGFloat) -> Double { Double(max(0, min(x, w)) / max(w, 1)) * total }

    private func drag(_ v: DragGesture.Value, width w: CGFloat) {
        if dragging == nil {
            let sx = v.startLocation.x
            if let a = model.sunday.cutIn, abs(sx - x(a, w)) < 10 {
                dragging = .cutIn
            } else if let b = model.sunday.cutOut, abs(sx - x(b, w)) < 10 {
                dragging = .cutOut
            } else {
                dragging = .seek
            }
        }
        let t = time(v.location.x, w)
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
        case "music": return Brand.music
        case "speech": return Brand.speech
        case "silent": return Brand.silent
        default: return Brand.mixed
        }
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        let w = size.width
        let band = CGRect(x: 0, y: bandTop, width: w, height: bandHeight)
        let bandPath = Path(roundedRect: band, cornerRadius: 10, style: .continuous)
        ctx.fill(bandPath, with: .color(Brand.card2))

        // Music and speech, clipped to the band's round corners.
        var inBand = ctx
        inBand.clip(to: bandPath)
        for run in model.sunday.find?.runs ?? [] {
            let x0 = x(Double(run.start), w), x1 = x(Double(run.end), w)
            inBand.fill(Path(CGRect(x: x0, y: bandTop, width: max(1, x1 - x0), height: bandHeight)), with: .color(color(run.kind)))
        }
        // Dim what's outside the cut.
        if let a = model.sunday.cutIn, let b = model.sunday.cutOut {
            inBand.fill(Path(CGRect(x: 0, y: bandTop, width: x(a, w), height: bandHeight)), with: .color(Brand.dim))
            inBand.fill(Path(CGRect(x: x(b, w), y: bandTop, width: w - x(b, w), height: bandHeight)), with: .color(Brand.dim))
        }
        // Where the preacher starts.
        if let f = model.sunday.find {
            let px = x(Double(f.preacherStarts), w)
            var p = Path()
            p.move(to: CGPoint(x: px, y: bandTop))
            p.addLine(to: CGPoint(x: px, y: bandTop + bandHeight))
            ctx.stroke(p, with: .color(Brand.mark), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
        }

        // Quality: each minute of the cut.
        if let q = model.sunday.quality {
            for (m, status) in q.minutes.enumerated() {
                let t0 = q.cutIn + 60 * Double(m)
                let t1 = min(t0 + 60, q.cutOut)
                let x0 = x(t0, w), x1 = x(t1, w)
                ctx.fill(Path(roundedRect: CGRect(x: x0, y: stripTop, width: max(1, x1 - x0 - 1), height: stripHeight), cornerRadius: 1),
                         with: .color(Brand.minute(status).opacity(model.qualityIsStale ? 0.35 : 1)))
            }
        }

        // Ticks every quarter of an hour.
        var t = 900.0
        while t < total {
            let tx = x(t, w)
            if tx > 24 && tx < w - 24 {
                ctx.draw(Text(Timecode.format(t)).font(Brand.lato(11).monospacedDigit()).foregroundColor(Brand.text2),
                         at: CGPoint(x: tx, y: tickTop + 7), anchor: .center)
            }
            t += 900
        }

        // Start and End.
        if let a = model.sunday.cutIn { handle(&ctx, at: x(a, w), label: "Start", w: w) }
        if let b = model.sunday.cutOut { handle(&ctx, at: x(b, w), label: "End", w: w) }

        // Playhead.
        let px = x(model.playhead, w)
        ctx.fill(Path(CGRect(x: px - 1, y: bandTop, width: 2, height: stripTop + stripHeight - bandTop)), with: .color(Brand.text))
    }

    private func handle(_ ctx: inout GraphicsContext, at x: CGFloat, label: String, w: CGFloat) {
        ctx.fill(Path(CGRect(x: x - 1, y: 14, width: 2, height: 56)), with: .color(Brand.coral))
        let knob = CGRect(x: x - 6, y: bandTop + bandHeight / 2 - 14, width: 12, height: 28)
        ctx.fill(Path(roundedRect: knob.insetBy(dx: -2, dy: -2), cornerRadius: 8), with: .color(Brand.card))
        ctx.fill(Path(roundedRect: knob, cornerRadius: 6), with: .color(Brand.coral))
        let text = ctx.resolve(Text(label).font(Brand.lato(11, .black)).foregroundColor(.white))
        let size = text.measure(in: CGSize(width: 100, height: 20))
        let pill = CGRect(x: min(max(0, x - size.width / 2 - 8), w - size.width - 16), y: 0, width: size.width + 16, height: 16)
        ctx.fill(Path(roundedRect: pill, cornerRadius: 8), with: .color(Brand.coral))
        ctx.draw(text, at: CGPoint(x: pill.midX, y: pill.midY), anchor: .center)
    }
}

struct Legend: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
            Text(text)
        }
        .font(Brand.lato(12))
        .foregroundStyle(Brand.text2)
    }
}

/// "Quality, minute by minute: all clear", with three little chunks.
struct QualityLegend: View {
    @ObservedObject var model: SundayModel

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 1) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1).fill(Brand.minuteGood).frame(width: 4, height: 6)
                }
            }
            Text(text).lineLimit(1)
        }
        .font(Brand.lato(12))
        .foregroundStyle(Brand.text2)
    }

    private var text: String {
        guard let q = model.sunday.quality else { return "Quality, minute by minute, once it's checked" }
        if model.qualityIsStale { return "Quality, minute by minute: check again" }
        let bad = q.minutes.filter { $0 != "good" }.count
        return bad == 0 ? "Quality, minute by minute: all clear" : "Quality, minute by minute: \(bad) to look at"
    }
}
