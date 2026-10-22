import SwiftUI
import SermonCutterCore

/// The two ends of the cut, 20 seconds each: when the banner covers the
/// picture and how the sound fades. Drag a dot to change a hold, the
/// dissolve or a fade.
struct EndsTrack: View {
    @ObservedObject var model: SundayModel
    @State private var grabbed: Edge?

    /// Seconds shown at each end.
    static let span = 20.0

    enum Edge { case openHold, openDissolve, fadeIn, closeHold, closeDissolve, fadeOut }

    var body: some View {
        HStack(spacing: 16) {
            panel(closing: false)
            panel(closing: true)
        }
        .frame(height: 92)
    }

    private func panel(closing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(closing ? "Closing" : "Opening").font(.caption.weight(.semibold))
                Spacer()
                Text(summary(closing)).font(.caption2).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                Canvas { ctx, size in draw(&ctx, size: size, closing: closing) }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in drag(v, width: geo.size.width, closing: closing) }
                            .onEnded { _ in grabbed = nil }
                    )
            }
        }
    }

    private var t: Timings { model.sunday.timings }

    private func summary(_ closing: Bool) -> String {
        closing
            ? "banner \(fmt(t.closeHold)) s · sound out \(fmt(t.fadeOut)) s"
            : "banner \(fmt(t.openHold)) s · sound in \(fmt(t.fadeIn)) s"
    }

    private func fmt(_ x: Double) -> String { Engine.number((x * 10).rounded() / 10) }

    // Seconds from the start of the panel: the opening runs 0...20 after In,
    // the closing 0...20 ending on Out.
    private func x(_ s: Double, _ w: CGFloat) -> CGFloat { CGFloat(s / EndsTrack.span) * w }
    private func s(_ x: CGFloat, _ w: CGFloat) -> Double { Double(max(0, min(x, w)) / max(w, 1)) * EndsTrack.span }

    private let laneH: CGFloat = 26
    private var bannerTop: CGFloat { 0 }
    private var soundTop: CGFloat { laneH + 8 }

    /// Handle positions (seconds into the panel) for each end.
    private func handles(_ closing: Bool) -> [(Edge, Double, CGFloat)] {
        let e = EndsTrack.span
        if closing {
            return [
                (.closeDissolve, e - t.closeHold - t.dissolve, bannerTop + laneH),
                (.closeHold, e - t.closeHold, bannerTop),
                (.fadeOut, e - t.fadeOut, soundTop),
            ]
        }
        return [
            (.openHold, t.openHold, bannerTop),
            (.openDissolve, t.openHold + t.dissolve, bannerTop + laneH),
            (.fadeIn, t.fadeIn, soundTop),
        ]
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, closing: Bool) {
        let w = size.width
        let e = EndsTrack.span
        for top in [bannerTop, soundTop] {
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: top, width: w, height: laneH), cornerRadius: 3), with: .color(.gray.opacity(0.12)))
        }
        // Banner opacity.
        var banner = Path()
        let b0 = bannerTop + laneH
        if closing {
            let start = e - t.closeHold - t.dissolve
            banner.move(to: CGPoint(x: x(start, w), y: b0))
            banner.addLine(to: CGPoint(x: x(e - t.closeHold, w), y: bannerTop))
            banner.addLine(to: CGPoint(x: w, y: bannerTop))
            banner.addLine(to: CGPoint(x: w, y: b0))
        } else {
            banner.move(to: CGPoint(x: 0, y: b0))
            banner.addLine(to: CGPoint(x: 0, y: bannerTop))
            banner.addLine(to: CGPoint(x: x(t.openHold, w), y: bannerTop))
            banner.addLine(to: CGPoint(x: x(t.openHold + t.dissolve, w), y: b0))
        }
        banner.closeSubpath()
        ctx.fill(banner, with: .color(.accentColor.opacity(0.45)))
        // Sound level.
        var sound = Path()
        let s0 = soundTop + laneH
        if closing {
            sound.move(to: CGPoint(x: 0, y: s0))
            sound.addLine(to: CGPoint(x: 0, y: soundTop))
            sound.addLine(to: CGPoint(x: x(e - t.fadeOut, w), y: soundTop))
            sound.addLine(to: CGPoint(x: w, y: s0))
        } else {
            sound.move(to: CGPoint(x: 0, y: s0))
            sound.addLine(to: CGPoint(x: x(t.fadeIn, w), y: soundTop))
            sound.addLine(to: CGPoint(x: w, y: soundTop))
            sound.addLine(to: CGPoint(x: w, y: s0))
        }
        sound.closeSubpath()
        ctx.fill(sound, with: .color(.orange.opacity(0.45)))
        // Lane names.
        ctx.draw(Text("Banner").font(.caption2).foregroundColor(.secondary), at: CGPoint(x: closing ? 4 : w - 4, y: bannerTop + laneH / 2), anchor: closing ? .leading : .trailing)
        ctx.draw(Text("Sound").font(.caption2).foregroundColor(.secondary), at: CGPoint(x: closing ? w - 4 : 4, y: soundTop + laneH / 2), anchor: closing ? .trailing : .leading)
        // Handles.
        for (edge, secs, y) in handles(closing) {
            let hx = x(secs, w)
            let r: CGFloat = grabbed == edge ? 6 : 4.5
            ctx.fill(Path(ellipseIn: CGRect(x: hx - r, y: y - r, width: 2 * r, height: 2 * r)), with: .color(.white))
            ctx.stroke(Path(ellipseIn: CGRect(x: hx - r, y: y - r, width: 2 * r, height: 2 * r)), with: .color(.accentColor), lineWidth: 1.5)
        }
    }

    private func drag(_ v: DragGesture.Value, width w: CGFloat, closing: Bool) {
        if grabbed == nil {
            let p = v.startLocation
            grabbed = handles(closing)
                .map { ($0.0, hypot(x($0.1, w) - p.x, $0.2 - p.y)) }
                .filter { $0.1 < 14 }
                .min { $0.1 < $1.1 }?.0
        }
        guard let edge = grabbed else { return }
        let secs = (s(v.location.x, w) * 10).rounded() / 10
        let e = EndsTrack.span
        var n = t
        switch edge {
        case .openHold: n.openHold = max(0, min(secs, e - n.dissolve))
        case .openDissolve: n.dissolve = max(0, min(secs - n.openHold, 5))
        case .fadeIn: n.fadeIn = max(0, min(secs, e))
        case .closeHold: n.closeHold = max(0, min(e - secs, e - n.dissolve))
        case .closeDissolve: n.dissolve = max(0, min(e - n.closeHold - secs, 5))
        case .fadeOut: n.fadeOut = max(0, min(e - secs, e))
        }
        model.setTimings(n)
    }
}
