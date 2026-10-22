import Foundation

/// The stream's loudness ten times a second, from the engine's sound
/// measurements, for drawing the waveform on the timeline.
public struct Loudness: Sendable {
    /// dBFS, floored at -100.
    public var env: [Float]
    public static let rate = 10.0

    public init(env: [Float]) {
        self.env = env
    }

    public static func load(_ url: URL) -> Loudness? {
        struct Features: Decodable { var env: [Float] }
        guard let data = try? Data(contentsOf: url),
              let f = try? JSONDecoder().decode(Features.self, from: data)
        else { return nil }
        return Loudness(env: f.env)
    }

    /// Loudest reading (dB) from `a` to `b` seconds, or nil past the end.
    public func peak(from a: Double, to b: Double) -> Float? {
        let i0 = max(0, Int(a * Loudness.rate))
        let i1 = min(env.count, max(i0 + 1, Int((b * Loudness.rate).rounded(.up))))
        guard i0 < i1 else { return nil }
        return env[i0..<i1].max()
    }
}
