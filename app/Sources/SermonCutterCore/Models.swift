import Foundation

// What the engine reports, as Swift types. Field names follow the engine's
// JSON after snake_case is converted to camelCase (see `Engine.decoder`).

public struct StreamInfo: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var channel: String?
    public var duration: Double?
    public var liveStatus: String?
    /// YYYYMMDD.
    public var uploadDate: String?
    public var description: String?
    public var bestH264Height: Int?
}

public struct StreamEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var url: String
    public var duration: Double?
    public var liveStatus: String?
    public var uploadDate: String?
}

public struct StreamList: Codable, Sendable {
    public var streams: [StreamEntry]
}

public struct FileResult: Codable, Sendable {
    public var file: String
}

/// A stretch of the service the engine heard as one kind of sound.
public struct SoundRun: Codable, Equatable, Sendable {
    public var start: Int
    public var end: Int
    /// "music", "speech", "mixed" or "silent".
    public var kind: String
}

/// Where someone told the congregation to sit.
public struct SeatCue: Codable, Equatable, Sendable {
    public var at: Double
    public var out: Double
    public var context: String
    public var afterPrayer: Bool
    public var beforeOffering: Bool?
    public var beforeNextPart: Bool
}

public struct FindResult: Codable, Equatable, Sendable {
    public var cutIn: Double
    public var cutOut: Double
    public var leadIn: Double
    public var preacherStarts: Int
    public var startConfidence: String
    public var outConfidence: String
    /// "seat_cue", "prayer_before_handover", "prayer_close" or "speech_run_end".
    public var outMethod: String
    public var outCue: SeatCue?
    public var cues: [SeatCue]
    public var speechRunEnds: Int
    public var streamSeconds: Double
    public var runs: [SoundRun]

    enum CodingKeys: String, CodingKey {
        case cutIn = "in"
        case cutOut = "out"
        case leadIn, preacherStarts, startConfidence, outConfidence, outMethod, outCue, cues,
            speechRunEnds, streamSeconds, runs
    }
}

public struct QualityIssue: Codable, Equatable, Identifiable, Sendable {
    public var kind: String
    public var what: String
    public var start: Double
    public var end: Double
    public var len: Double
    public var intoCut: Double
    public var intoCutTc: String
    public var streamTc: String
    public var id: String { "\(kind)@\(start)" }

    public var isSound: Bool { ["dead_air", "lost_mic", "audio_gap"].contains(kind) }
}

public struct QualityReport: Codable, Equatable, Sendable {
    /// "good", "tell_leads" or "not_usable".
    public var verdict: String
    public var headline: String
    public var reasons: [String]
    public var cutIn: Double
    public var cutOut: Double
    public var soundLost: Double
    public var pictureLost: Double
    public var videoChecked: Bool
    public var issues: [QualityIssue]
    /// One per minute of the cut: "good", "warn" or "bad".
    public var minutes: [String]
    public var note: String
}

public struct RenderOutcome: Codable, Equatable, Sendable {
    public var output: String
    public var encoder: String
    public var cutLen: Double
    public var elapsedS: Double
    public var speed: Double
}

public struct VerifyCheck: Codable, Equatable, Sendable {
    public var name: String
    public var passed: Bool
    public var detail: String
}

public struct VerifyReport: Codable, Equatable, Sendable {
    public var passed: Bool
    public var checks: [VerifyCheck]
}

public struct ToolsInfo: Codable, Equatable, Sendable {
    public var toolsDir: String?
    public var ffmpeg: String?
    public var ffprobe: String?
    public var ytdlp: String?
    public var deno: String?
    public var whisper: String?
    public var whisperModel: String?

    /// What's missing, by the name a person would install.
    public var missing: [String] {
        var m: [String] = []
        if ffmpeg == nil || ffprobe == nil { m.append("ffmpeg") }
        if ytdlp == nil { m.append("yt-dlp") }
        if deno == nil { m.append("deno") }
        if whisper == nil { m.append("whisper-cpp") }
        if whisperModel == nil { m.append("the speech model") }
        return m
    }
}

/// Banner and fade lengths, in seconds. Defaults come from the reference cuts.
public struct Timings: Codable, Equatable, Sendable {
    public var openHold: Double = 8
    public var dissolve: Double = 0.5
    public var closeHold: Double = 6
    public var fadeIn: Double = 4
    public var fadeOut: Double = 3

    public init() {}

    public var arguments: [String] {
        [
            "--open-hold", Engine.number(openHold),
            "--dissolve", Engine.number(dissolve),
            "--close-hold", Engine.number(closeHold),
            "--fade-in", Engine.number(fadeIn),
            "--fade-out", Engine.number(fadeOut),
        ]
    }
}
