import AVKit
import SwiftUI
import SermonCutterCore

/// The video itself. The app draws its own play button, so the standard
/// controls are off unless asked for.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    var controls: AVPlayerViewControlsStyle = .none

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = controls
        v.showsFullScreenToggleButton = controls != .none
        v.videoGravity = .resizeAspect
        return v
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
        if nsView.controlsStyle != controls { nsView.controlsStyle = controls }
    }
}

/// The banner as the export shows it: fitted into a 16:9 frame on black.
struct BannerFrame: View {
    let image: NSImage

    var body: some View {
        ZStack {
            Color.black
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        }
        .aspectRatio(16 / 9, contentMode: .fit)
    }
}

/// The Review screen's player: the stream on step 1; on Quality and Export
/// the cut as it will be exported, with the banner over both ends and the
/// sound fading in and out.
struct PlayerPane: View {
    @ObservedObject var model: SundayModel

    var body: some View {
        ZStack {
            Color.black
            PlayerView(player: model.player)
            if model.playsCut, let banner = model.bannerImage {
                BannerFrame(image: banner)
                    .opacity(model.bannerOpacity(at: model.playhead))
                    .allowsHitTesting(false)
            }
            if !model.hasVideo {
                VStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 28, weight: .semibold))
                    Text(model.sunday.audioFile == nil ? "The sound and picture are on their way." : "You can listen already. The picture shows once the video has downloaded.")
                        .font(Brand.lato(14))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                .foregroundStyle(.white.opacity(0.75))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .topLeading) {
            HStack(spacing: 8) {
                if model.playsCut {
                    OverlayLabel(text: "Preview: the sermon as it will be exported", bold: false)
                }
                if let f = model.videoProgress {
                    OverlayLabel(text: "Video downloading · \(Int(f * 100))%", bold: false)
                }
            }
            .padding(16)
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 10) {
                Button {
                    model.togglePlay()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color(hex: 0x111111))
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.92), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .help("Play or pause (Space)")
                .disabled(model.sunday.audioFile == nil)
                OverlayLabel(text: label)
            }
            .padding(16)
        }
    }

    private var label: String {
        if model.playsCut, let len = model.cutLength { return Timecode.format(len) }
        return Timecode.format(model.playhead)
    }
}

/// White text on a dark capsule, over the picture.
struct OverlayLabel: View {
    let text: String
    var bold = true

    var body: some View {
        Text(text)
            .font(Brand.lato(bold ? 13 : 12, bold ? .black : .bold).monospacedDigit())
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .padding(.vertical, bold ? 6 : 4)
            .background(.black.opacity(0.6), in: Capsule())
    }
}
