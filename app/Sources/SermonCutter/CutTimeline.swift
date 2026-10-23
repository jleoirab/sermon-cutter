import SwiftUI
import SermonCutterCore

/// The timeline on Quality and Export: only the sermon, as it will be
/// exported. Snapshots of the video run along it, the banner fades out at
/// the start and in at the end, and quality shows minute by minute below.
/// Drag the playhead, or click anywhere, to play from there.
struct CutTimelineCard: View {
    @ObservedObject var model: SundayModel

    private let bandTop: CGFloat = 8
    private let bandHeight: CGFloat = 54
    private let stripTop: CGFloat = 68
    private let stripHeight: CGFloat = 8
    private let tickTop: CGFloat = 82

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The sermon").font(Brand.lato(14, .black))
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    band(w)
                    strip(w)
                    ticks(w)
                    playhead(w)
                }
                .frame(width: w, height: 100, alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in seek(v.location.x, w) }
                )
            }
            .frame(height: 100)
            HStack(spacing: 14) {
                QualityLegend(model: model)
                Spacer()
                Text(hint).lineLimit(1)
            }
            .font(Brand.lato(12))
            .foregroundStyle(Brand.text2)
        }
        .card(radius: 20, padding: 16)
        .task(id: filmstripKey) { await model.loadFilmstrip() }
    }

    private var hint: String {
        switch model.page {
        case .quality: return "Click a problem on the right to jump the player there."
        case .export where model.exporting: return "You can still play and listen while it exports."
        default: return "This is exactly what will be exported."
        }
    }

    private var filmstripKey: String {
        "\(model.hasVideo)|\(Int((model.sunday.cutIn ?? 0) / 5))|\(Int((model.sunday.cutOut ?? 0) / 5))"
    }

    private var start: Double { model.sunday.cutIn ?? 0 }
    private var length: Double { max(model.cutLength ?? 1, 1) }

    private func x(_ t: Double, _ w: CGFloat) -> CGFloat { CGFloat((t - start) / length) * w }

    private func seek(_ px: CGFloat, _ w: CGFloat) {
        let f = Double(max(0, min(px, w)) / max(w, 1))
        model.seek(start + f * length)
    }

    // MARK: - Parts

    private func band(_ w: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return ZStack {
            if model.filmstrip.isEmpty {
                runs(w)
            } else {
                HStack(spacing: 2) {
                    ForEach(Array(model.filmstrip.enumerated()), id: \.offset) { _, image in
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: bandHeight)
                            .clipped()
                    }
                }
                .background(Color(hex: 0x111111))
            }
            if let banner = model.bannerImage {
                HStack(spacing: 0) {
                    bannerEnd(banner, fadingTo: .trailing)
                    Spacer(minLength: 0)
                    bannerEnd(banner, fadingTo: .leading)
                }
            }
        }
        .frame(width: w, height: bandHeight)
        .background(Brand.card2)
        .clipShape(shape)
        .offset(y: bandTop)
    }

    /// The banner at one end, fading into the sermon. Drawn wider than its
    /// few seconds so it can be seen.
    private func bannerEnd(_ image: NSImage, fadingTo edge: UnitPoint) -> some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 104, height: bandHeight)
            .clipped()
            .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: edge == .trailing ? .leading : .trailing, endPoint: edge))
    }

    /// Music and speech, until the snapshots are ready.
    private func runs(_ w: CGFloat) -> some View {
        Canvas { ctx, size in
            for run in model.sunday.find?.runs ?? [] {
                let x0 = max(0, x(Double(run.start), size.width)), x1 = min(size.width, x(Double(run.end), size.width))
                guard x1 > x0 else { continue }
                let c: Color = run.kind == "music" ? Brand.music : run.kind == "speech" ? Brand.speech : run.kind == "silent" ? Brand.silent : Brand.mixed
                ctx.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)), with: .color(c))
            }
        }
    }

    private func strip(_ w: CGFloat) -> some View {
        HStack(spacing: 1) {
            ForEach(Array((model.sunday.quality?.minutes ?? []).enumerated()), id: \.offset) { _, status in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Brand.minute(status).opacity(model.qualityIsStale ? 0.35 : 1))
            }
        }
        .frame(width: w, height: stripHeight)
        .offset(y: stripTop)
    }

    private func ticks(_ w: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Text("0:00").position(x: 12, y: tickTop + 7)
            ForEach(Array(stride(from: 600.0, to: length, by: 600)), id: \.self) { s in
                let px = CGFloat(s / length) * w
                if px < w - 70 {
                    Text(Timecode.format(s)).position(x: px, y: tickTop + 7)
                }
            }
            Text(Timecode.format(length)).position(x: w - 22, y: tickTop + 7)
        }
        .font(Brand.lato(11).monospacedDigit())
        .foregroundStyle(Brand.text2)
        .frame(width: w, height: 100, alignment: .topLeading)
    }

    private func playhead(_ w: CGFloat) -> some View {
        let px = min(max(0, x(model.playhead, w)), w)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Brand.text).frame(width: 2, height: stripTop + stripHeight - 2)
                .offset(x: px - 1, y: 4)
            Circle().fill(Brand.text)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(Brand.card, lineWidth: 2))
                .offset(x: px - 7, y: 0)
        }
        .frame(width: w, height: 100, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}
