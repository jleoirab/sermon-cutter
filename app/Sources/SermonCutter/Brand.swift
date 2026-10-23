import AppKit
import SwiftUI

/// CCI's look: coral as the one accent, neutral white or black grounds,
/// Anton for big titles and Lato for everything else. Every colour has a
/// light and a dark value and follows the Mac's appearance.
enum Brand {
    // MARK: Colours

    static let coral = Color(hex: 0xDF4E4E)
    /// Coral deep enough for white text on it.
    static let deepCoral = Color(hex: 0xC93B3B)
    static let grape = Color(hex: 0x371E4C)

    static let paper = Color(light: 0xF5F5F5, dark: 0x0E0E0F)
    static let bar = Color(light: 0xFFFFFF, dark: 0x161617)
    static let card = Color(light: 0xFFFFFF, dark: 0x1F1F1F)
    static let card2 = Color(light: 0xF0F0F2, dark: 0x2A2A2D)
    static let border = Color(light: 0xE4E4E7, dark: 0x2A2A2D)
    static let outline = Color(light: 0xD4D4D8, dark: 0x45454A)
    static let text = Color(light: 0x111111, dark: 0xF5F5F5)
    static let text2 = Color(light: 0x5F6066, dark: 0xA4A5AB)
    static let text3 = Color(light: 0x3A3B40, dark: 0xD4D4D8)
    static let link = Color(light: 0xB83232, dark: 0xF27A7A)
    static let selected = Color(light: 0x111111, dark: 0xF5F5F5)
    static let onSelected = Color(light: 0xFFFFFF, dark: 0x111111)

    static let tonalBg = Color(light: 0xFCE9E9, dark: 0x3A1F1F)
    static let tonalFg = Color(light: 0x8E2424, dark: 0xF7B5B5)
    static let tonalLine = Color(light: 0xF3B9B9, dark: 0x5A2B2B)
    static let goodBg = Color(light: 0xE4F4EA, dark: 0x173323)
    static let goodFg = Color(light: 0x1B6B3A, dark: 0x8FD9A8)
    static let warnBg = Color(light: 0xFFF0D6, dark: 0x3A2C12)
    static let warnFg = Color(light: 0x8A5300, dark: 0xF5C46B)
    static let badBg = Color(light: 0xFDE3E3, dark: 0x3D1A1A)
    static let badFg = Color(light: 0xA42323, dark: 0xFF9C9C)
    static let highlightBg = Color(light: 0xFCE1E1, dark: 0x4A2323)
    static let highlightFg = Color(light: 0x8E2424, dark: 0xFFD0D0)

    static let music = Color(light: 0xB49AD6, dark: 0x6A4C8C)
    static let speech = Color(light: 0xF5CC8A, dark: 0x9A7738)
    static let silent = Color(light: 0xD4D4D8, dark: 0x151517)
    static let mixed = Color(light: 0xE4E0EA, dark: 0x3A3A3E)
    static let dim = Color(light: 0xFFFFFF, dark: 0x000000, lightAlpha: 0.62, darkAlpha: 0.58)
    static let mark = Color(light: 0x111111, dark: 0xF5F5F5, lightAlpha: 0.55, darkAlpha: 0.7)

    static let minuteGood = Color(light: 0x2E9E5B, dark: 0x3FBF74)
    static let minuteWarn = Color(hex: 0xE0A43A)
    static let minuteBad = Color(hex: 0xD64545)

    static func minute(_ status: String) -> Color {
        switch status {
        case "bad": return minuteBad
        case "warn": return minuteWarn
        default: return minuteGood
        }
    }

    // MARK: Type

    enum Weight { case regular, bold, black }

    static func lato(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        switch weight {
        case .regular: return .custom("Lato-Regular", size: size)
        case .bold: return .custom("Lato-Bold", size: size)
        case .black: return .custom("Lato-Black", size: size)
        }
    }

    static func anton(_ size: CGFloat) -> Font {
        .custom("Anton-Regular", size: size)
    }

    static let shadowColor = Color(light: 0x000000, dark: 0x000000, lightAlpha: 0.06, darkAlpha: 0)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(nsColor: NSColor(hex: hex, alpha: alpha))
    }

    /// A colour that follows the Mac's light or dark appearance.
    init(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark, alpha: darkAlpha)
                : NSColor(hex: light, alpha: lightAlpha)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - Buttons

/// The app's rounded buttons. None of them ever wraps its label.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, tonal, outline, dark, quiet }
    enum Size { case small, regular, large }

    var kind: Kind = .primary
    var size: Size = .regular

    func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration, kind: kind, size: size)
    }

    private struct Pill: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        let size: Size
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(font)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, hPad)
                .padding(.vertical, vPad)
                .foregroundStyle(foreground)
                .background(background, in: Capsule())
                .overlay(Capsule().strokeBorder(kind == .outline ? Brand.outline : .clear, lineWidth: 1))
                .contentShape(Capsule())
                .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
        }

        private var font: Font {
            switch size {
            case .small: return Brand.lato(12.5, kind == .outline || kind == .quiet ? .bold : .black)
            case .regular: return Brand.lato(14, kind == .outline || kind == .quiet ? .bold : .black)
            case .large: return Brand.lato(15, .black)
            }
        }

        private var hPad: CGFloat { size == .small ? 13 : size == .regular ? 18 : 24 }
        private var vPad: CGFloat { size == .small ? 6 : size == .regular ? 9 : 12 }

        private var foreground: Color {
            switch kind {
            case .primary: return .white
            case .tonal: return Brand.tonalFg
            case .outline: return Brand.text
            case .dark: return Brand.onSelected
            case .quiet: return Brand.link
            }
        }

        private var background: Color {
            switch kind {
            case .primary: return Brand.deepCoral
            case .tonal: return Brand.tonalBg
            case .outline: return Brand.card
            case .dark: return Brand.selected
            case .quiet: return .clear
            }
        }
    }
}

/// A text-only button in the link colour.
struct LinkButtonStyle: ButtonStyle {
    var size: CGFloat = 13

    func makeBody(configuration: Configuration) -> some View {
        LinkLabel(configuration: configuration, size: size)
    }

    private struct LinkLabel: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(Brand.lato(size, .bold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(Brand.link)
                .contentShape(Rectangle())
                .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
        }
    }
}

/// A round icon button, like the back arrow and Settings.
struct CircleButtonStyle: ButtonStyle {
    var diameter: CGFloat = 32
    var background: Color = Brand.card2

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Brand.text)
            .frame(width: diameter, height: diameter)
            .background(background, in: Circle())
            .contentShape(Circle())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

// MARK: - Small pieces

/// A small rounded label: a verdict, a status, a confidence.
struct Chip: View {
    let text: String
    var foreground: Color = Brand.text3
    var background: Color = Brand.card2
    var systemImage: String?
    var size: CGFloat = 12
    var dashed = false

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: size - 1, weight: .bold))
            }
            Text(text).font(Brand.lato(size, .bold)).lineLimit(1)
        }
        .fixedSize()
        .padding(.horizontal, size * 0.8)
        .padding(.vertical, size * 0.25)
        .foregroundStyle(foreground)
        .background(dashed ? Color.clear : background, in: Capsule())
        .overlay {
            if dashed {
                Capsule().strokeBorder(foreground.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
    }
}

/// The small spaced capitals used for labels, like the website's tags.
struct Eyebrow: View {
    let text: String
    var color: Color = Brand.text2

    init(_ text: String, color: Color = Brand.text2) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(Brand.lato(11, .black))
            .tracking(1.3)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// A row of tabs or choices in a grey capsule; the chosen one is filled.
struct SegmentedPills<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String
        var enabled = true
        var id: String { title }
    }

    let options: [Option]
    @Binding var selection: Value
    var fill = true
    var size: CGFloat = 13

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { o in
                let chosen = o.value == selection
                Button {
                    selection = o.value
                } label: {
                    Text(o.title)
                        .font(Brand.lato(size, chosen ? .black : .bold))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(chosen ? Brand.onSelected : Brand.text2)
                        .padding(.horizontal, fill ? 6 : 13)
                        .padding(.vertical, 6)
                        .frame(maxWidth: fill ? .infinity : nil)
                        .background(chosen ? Brand.selected : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!o.enabled)
                .opacity(o.enabled ? 1 : 0.45)
            }
        }
        .padding(3)
        .background(Brand.card2, in: Capsule())
    }
}

extension View {
    /// A white (or night) card with soft corners.
    func card(radius: CGFloat = 20, padding: CGFloat? = 16) -> some View {
        self
            .padding(padding ?? 0)
            .background(Brand.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: Brand.shadowColor, radius: 6, y: 2)
    }

    /// A grey inner panel, for groups inside a card.
    func well(radius: CGFloat = 16, padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .background(Brand.card2, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// A circle that fills as a fraction completes.
struct ProgressRing: View {
    let fraction: Double
    var lineWidth: CGFloat = 12

    var body: some View {
        ZStack {
            Circle().stroke(Brand.card2, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(Brand.coral, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// A thin bar that fills as a fraction completes.
struct ProgressBar: View {
    let fraction: Double?
    var color: Color = Brand.coral
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Brand.border)
                if let fraction {
                    Capsule().fill(color).frame(width: max(height, geo.size.width * min(1, max(0, fraction))))
                }
            }
        }
        .frame(height: height)
    }
}
