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
            // Until the video is in, AVKit draws its own audio artwork; ours
            // says the same thing, so keep just ours.
            PlayerView(player: model.player)
                .opacity(model.hasVideo ? 1 : 0)
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
        // No play button: the timeline below plays from wherever it's
        // clicked. Clicking the picture or pressing Space plays and pauses.
        // (A clear layer on top takes the click; AVKit's view would eat it.)
        .overlay {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { if model.sunday.audioFile != nil { model.togglePlay() } }
        }
        .help("Click the timeline to play from there. Click here or press Space to pause.")
        .background {
            Button("Play or pause") { model.togglePlay() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model.sunday.audioFile == nil)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .bottomLeading) {
            OverlayLabel(text: label)
                .padding(16)
                .allowsHitTesting(false)
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
