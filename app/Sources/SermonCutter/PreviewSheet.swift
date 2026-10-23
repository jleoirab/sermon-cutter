import AVFoundation
import SwiftUI
import SermonCutterCore

/// Plays one end of the cut, 20 seconds, the way it will be exported: the
/// stream with the banner laid over it and the sound faded, worked out as it
/// plays so a change shows straight away.
@MainActor
final class EndsPlayer: ObservableObject {
    let player = AVPlayer()
    @Published var time: Double = 0
    @Published var playing = false
    private(set) var window: ClosedRange<Double> = 0...20
    private weak var model: SundayModel?
    private var observer: Any?

    static let span = 20.0

    func load(_ model: SundayModel, end: String) {
        self.model = model
        if player.currentItem == nil, let v = model.sunday.videoFile {
            player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: v)))
        }
        if observer == nil {
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] t in
                MainActor.assumeIsolated { self?.tick(t.seconds) }
            }
        }
        let a = model.sunday.cutIn ?? 0, b = model.sunday.cutOut ?? EndsPlayer.span
        window = end == "closing" ? max(a, b - EndsPlayer.span)...b : a...min(b, a + EndsPlayer.span)
        player.pause()
        playing = false
        seek(window.lowerBound)
    }

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        time = t
        player.volume = Float(model?.gain(at: t) ?? 1)
        if playing && t >= window.upperBound - 0.03 {
            player.pause()
            playing = false
        }
    }

    func seek(_ t: Double) {
        let c = min(max(t, window.lowerBound), window.upperBound)
        time = c
        player.seek(to: CMTime(seconds: c, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func toggle() {
        if playing {
            player.pause()
            playing = false
        } else {
            if time >= window.upperBound - 0.1 { seek(window.lowerBound) }
            player.play()
            playing = true
        }
    }

    func play(from t: Double) {
        seek(t)
        player.play()
        playing = true
    }

    func stop() {
        player.pause()
        playing = false
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
    }
}

/// Preview the ends: watch the opening or closing 20 seconds and drag the
/// banner's hold, the dissolve and the sound fade on the tracks below.
struct PreviewSheet: View {
    @ObservedObject var model: SundayModel
    @StateObject private var ends = EndsPlayer()
    @State private var original: Timings?

    private var end: String { model.endsPreview ?? "opening" }
    private var closing: Bool { end == "closing" }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Text("Preview the ends").font(Brand.lato(20, .black))
                SegmentedPills(
                    options: [.init(value: "opening", title: "Opening"), .init(value: "closing", title: "Closing")],
                    selection: Binding(get: { end }, set: { model.endsPreview = $0 }),
                    fill: false
                )
                Spacer()
                HStack(spacing: 6) {
                    Text("Press")
                    Text("Space")
                        .font(Brand.lato(12, .black))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Brand.outline))
                    Text("to play or pause")
                }
                .font(Brand.lato(12))
                .foregroundStyle(Brand.text2)
            }

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    ZStack {
                        Color.black
                        PlayerView(player: ends.player)
                        if let banner = model.bannerImage {
                            BannerFrame(image: banner)
                                .opacity(model.bannerOpacity(at: ends.time))
                        }
                    }
                    .frame(width: 600, height: 338)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        OverlayLabel(text: "As it will be exported", bold: false).padding(12)
                    }

                    HStack(spacing: 12) {
                        Button {
                            ends.toggle()
                        } label: {
                            Image(systemName: ends.playing ? "pause.fill" : "play.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(Brand.onSelected)
                                .frame(width: 44, height: 44)
                                .background(Brand.selected, in: Circle())
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.space, modifiers: [])
                        Text(Timecode.format(ends.time - ends.window.lowerBound))
                            .font(Brand.lato(16, .black).monospacedDigit())
                        Text("of \(Timecode.format(ends.window.upperBound - ends.window.lowerBound))")
                            .foregroundStyle(Brand.text2)
                        Spacer()
                        Text(closing ? "Playing the last 20 seconds of the cut" : "Playing the first 20 seconds of the cut")
                            .font(Brand.lato(13))
                            .foregroundStyle(Brand.text2)
                    }

                    EndsTracks(model: model, ends: ends, closing: closing)
                        .frame(height: 100)
                }
                .frame(width: 600)

                VStack(alignment: .leading, spacing: 14) {
                    Eyebrow("What plays")
                    VStack(alignment: .leading, spacing: 10) {
                        let t = model.sunday.timings
                        value(Brand.coral, "Banner on screen", closing ? t.closeHold : t.openHold)
                        value(Brand.tonalLine, closing ? "Banner dissolves in" : "Banner dissolves away", t.dissolve)
                        value(Brand.music, closing ? "Sound fades out" : "Sound fades in", closing ? t.fadeOut : t.fadeIn)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        numbered(1, "Press play to watch these 20 seconds exactly as they'll be exported.")
                        numbered(2, "Not right? Drag a dot on the tracks. It plays again from just before it.")
                        numbered(3, closing ? "Switch to Opening to check the first 20 seconds the same way." : "Switch to Closing to check the last 20 seconds the same way.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Back") {
                    if let original { model.setTimings(original) }
                    model.endsPreview = nil
                }
                .buttonStyle(PillButtonStyle(kind: .outline))
                .keyboardShortcut(.cancelAction)
                .help("Close without keeping changes to the times")
                Spacer()
                Button("Done") { model.endsPreview = nil }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 960)
        .background(Brand.card)
        .font(Brand.lato(14))
        .foregroundStyle(Brand.text)
        .onAppear {
            original = model.sunday.timings
            model.player.pause()
            ends.load(model, end: end)
        }
        .onChange(of: end) { _, e in ends.load(model, end: e) }
        .onDisappear { ends.stop() }
    }

    private func value(_ color: Color, _ label: String, _ seconds: Double) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
            Text(label)
            Spacer()
            Text("\(Engine.number((seconds * 10).rounded() / 10)) s").font(Brand.lato(14, .black).monospacedDigit())
        }
    }

    private func numbered(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(Brand.lato(12, .black))
                .foregroundStyle(Brand.onSelected)
                .frame(width: 22, height: 22)
                .background(Brand.selected, in: Circle())
            Text(text)
                .font(Brand.lato(13))
                .foregroundStyle(Brand.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The tracks under the preview: a scrubber, when the banner covers the
/// picture, and how the sound fades. Drag a dot to change a hold, the
/// dissolve or a fade; drag anywhere else to move through the 20 seconds.
struct EndsTracks: View {
    @ObservedObject var model: SundayModel
    @ObservedObject var ends: EndsPlayer
    let closing: Bool
    @State private var grabbed: Edge?
    @State private var scrubbing = false

    enum Edge { case openHold, openDissolve, fadeIn, closeHold, closeDissolve, fadeOut }

    private let span = EndsPlayer.span
    private let bannerTop: CGFloat = 20
    private let soundTop: CGFloat = 54
    private let laneH: CGFloat = 26

    private var t: Timings { model.sunday.timings }

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in draw(&ctx, size: size) }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in drag(v, width: geo.size.width) }
                        .onEnded { _ in release() }
                )
        }
    }

    private func x(_ s: Double, _ w: CGFloat) -> CGFloat { CGFloat(s / span) * w }
    private func s(_ x: CGFloat, _ w: CGFloat) -> Double { Double(max(0, min(x, w)) / max(w, 1)) * span }

    /// Dot positions, in seconds into the 20 shown, and the height of each.
    private func handles() -> [(Edge, Double, CGFloat)] {
        if closing {
            return [
                (.closeDissolve, span - t.closeHold - t.dissolve, bannerTop + laneH),
                (.closeHold, span - t.closeHold, bannerTop),
                (.fadeOut, span - t.fadeOut, soundTop),
            ]
        }
        return [
            (.openHold, t.openHold, bannerTop),
            (.openDissolve, t.openHold + t.dissolve, bannerTop + laneH),
            (.fadeIn, t.fadeIn, soundTop),
        ]
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        let w = size.width
        let into = ends.time - ends.window.lowerBound
        // Scrubber.
        ctx.fill(Path(roundedRect: CGRect(x: 0, y: 4, width: w, height: 6), cornerRadius: 3), with: .color(Brand.card2))
        ctx.fill(Path(roundedRect: CGRect(x: 0, y: 4, width: max(6, x(into, w)), height: 6), cornerRadius: 3), with: .color(Brand.selected))
        // Lanes.
        for top in [bannerTop, soundTop] {
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: top, width: w, height: laneH), cornerRadius: 8), with: .color(Brand.card2))
        }
        var banner = Path()
        let b0 = bannerTop + laneH
        if closing {
            banner.move(to: CGPoint(x: x(span - t.closeHold - t.dissolve, w), y: b0))
            banner.addLine(to: CGPoint(x: x(span - t.closeHold, w), y: bannerTop))
            banner.addLine(to: CGPoint(x: w, y: bannerTop))
            banner.addLine(to: CGPoint(x: w, y: b0))
        } else {
            banner.move(to: CGPoint(x: 0, y: b0))
            banner.addLine(to: CGPoint(x: 0, y: bannerTop))
            banner.addLine(to: CGPoint(x: x(t.openHold, w), y: bannerTop))
            banner.addLine(to: CGPoint(x: x(t.openHold + t.dissolve, w), y: b0))
        }
        banner.closeSubpath()
        ctx.fill(banner, with: .color(Brand.coral))
        var sound = Path()
        let s0 = soundTop + laneH
        if closing {
            sound.move(to: CGPoint(x: 0, y: s0))
            sound.addLine(to: CGPoint(x: 0, y: soundTop))
            sound.addLine(to: CGPoint(x: x(span - t.fadeOut, w), y: soundTop))
            sound.addLine(to: CGPoint(x: w, y: s0))
        } else {
            sound.move(to: CGPoint(x: 0, y: s0))
            sound.addLine(to: CGPoint(x: x(t.fadeIn, w), y: soundTop))
            sound.addLine(to: CGPoint(x: w, y: soundTop))
            sound.addLine(to: CGPoint(x: w, y: s0))
        }
        sound.closeSubpath()
        ctx.fill(sound, with: .color(Brand.music))
        let bannerLabel = ctx.resolve(Text("Banner").font(Brand.lato(12, .black)).foregroundColor(.white))
        ctx.draw(bannerLabel, at: CGPoint(x: closing ? w - 10 : 10, y: bannerTop + laneH / 2), anchor: closing ? .trailing : .leading)
        let soundLabel = ctx.resolve(Text("Sound").font(Brand.lato(12, .black)).foregroundColor(Brand.grape))
        ctx.draw(soundLabel, at: CGPoint(x: closing ? 10 : w - 10, y: soundTop + laneH / 2), anchor: closing ? .leading : .trailing)
        // Dots.
        for (edge, secs, y) in handles() {
            let hx = x(secs, w)
            let r: CGFloat = grabbed == edge ? 8 : 7
            let dot = Path(ellipseIn: CGRect(x: hx - r, y: y - r, width: 2 * r, height: 2 * r))
            ctx.fill(dot, with: .color(.white))
            ctx.stroke(dot, with: .color(edge == .fadeIn || edge == .fadeOut ? Color(hex: 0x8E6BB8) : Brand.coral), lineWidth: 2)
        }
        // Playhead.
        let px = x(into, w)
        ctx.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: soundTop + laneH)), with: .color(Brand.selected))
        let knob = Path(ellipseIn: CGRect(x: px - 7, y: 0, width: 14, height: 14))
        ctx.fill(knob, with: .color(Brand.selected))
        ctx.stroke(knob, with: .color(Brand.card), lineWidth: 2)
        // Seconds.
        for sec in stride(from: 0.0, through: span, by: 5) {
            let label = ctx.resolve(Text("\(Int(sec)) s").font(Brand.lato(11)).foregroundColor(Brand.text2))
            let anchor: UnitPoint = sec == 0 ? .leading : sec == span ? .trailing : .center
            ctx.draw(label, at: CGPoint(x: x(sec, w), y: soundTop + laneH + 12), anchor: anchor)
        }
    }

    private func drag(_ v: DragGesture.Value, width w: CGFloat) {
        if grabbed == nil && !scrubbing {
            let p = v.startLocation
            grabbed = handles()
                .map { ($0.0, hypot(x($0.1, w) - p.x, $0.2 - p.y)) }
                .filter { $0.1 < 14 }
                .min { $0.1 < $1.1 }?.0
            if grabbed == nil { scrubbing = true }
        }
        if scrubbing {
            ends.seek(ends.window.lowerBound + s(v.location.x, w))
            return
        }
        guard let edge = grabbed else { return }
        let secs = (s(v.location.x, w) * 10).rounded() / 10
        var n = t
        switch edge {
        case .openHold: n.openHold = max(0, min(secs, span - n.dissolve))
        case .openDissolve: n.dissolve = max(0, min(secs - n.openHold, 5))
        case .fadeIn: n.fadeIn = max(0, min(secs, span))
        case .closeHold: n.closeHold = max(0, min(span - secs, span - n.dissolve))
        case .closeDissolve: n.dissolve = max(0, min(span - n.closeHold - secs, 5))
        case .fadeOut: n.fadeOut = max(0, min(span - secs, span))
        }
        model.setTimings(n)
    }

    /// After a dot is let go, play again from just before it.
    private func release() {
        if let edge = grabbed {
            let secs = handles().first { $0.0 == edge }?.1 ?? 0
            ends.play(from: ends.window.lowerBound + max(0, secs - 2))
        }
        grabbed = nil
        scrubbing = false
    }
}
