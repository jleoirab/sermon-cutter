import Foundation

/// One line the engine printed.
public struct EngineEvent: Decodable, Sendable {
    /// "progress", "log", "result" or "error".
    public var event: String
    public var step: String?
    public var fraction: Double?
    public var etaS: Double?
    public var detail: String?
    public var level: String?
    public var message: String?
}

public enum EngineError: LocalizedError, Equatable {
    case notFound
    case failed(step: String, message: String)
    case noResult(String)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "The Sermon Cutter engine wasn't found inside the app."
        case .failed(_, let message):
            return message
        case .noResult(let step):
            return "The engine finished without a \(step) result."
        }
    }
}

/// A `{"event":"result","data":...}` line.
private struct ResultLine<T: Decodable>: Decodable {
    var data: T
}

/// The results of one engine run, by step.
public struct EngineRun: Sendable {
    public var results: [String: Data]
    /// The engine's error message, when it failed and the caller asked to
    /// see the results anyway.
    public var error: String? = nil

    public init(results: [String: Data], error: String? = nil) {
        self.results = results
        self.error = error
    }

    public func result<T: Decodable>(_ step: String, as type: T.Type = T.self) throws -> T {
        guard let line = results[step] else { throw EngineError.noResult(step) }
        return try Engine.decoder.decode(ResultLine<T>.self, from: line).data
    }
}

/// Runs the `sermoncut` command-line engine and reads its JSON lines.
public final class Engine: @unchecked Sendable {
    public let executable: URL
    public var environment: [String: String]

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    public init(executable: URL, environment: [String: String]) {
        self.executable = executable
        self.environment = environment
    }

    /// The engine inside the app bundle, or one named by SERMONCUT_ENGINE.
    public static func locate(bundle: Bundle = .main) -> URL? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["SERMONCUT_ENGINE"], fm.isExecutableFile(atPath: env) {
            return URL(fileURLWithPath: env)
        }
        if let r = bundle.url(forResource: "sermoncut", withExtension: nil), fm.isExecutableFile(atPath: r.path) {
            return r
        }
        let dev = fm.homeDirectoryForCurrentUser.appendingPathComponent("Code/sermon-cutter/target/release/sermoncut")
        return fm.isExecutableFile(atPath: dev.path) ? dev : nil
    }

    /// The environment for the engine: the app's own, plus Homebrew on the
    /// PATH (apps opened from the Finder don't get the shell's PATH) and the
    /// speech model when one is set.
    public static func environment(model: URL?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let path = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        env["PATH"] = (extra + path.filter { !extra.contains($0) }).joined(separator: ":")
        if let model, FileManager.default.fileExists(atPath: model.path) {
            env["SERMONCUT_WHISPER_MODEL"] = model.path
        }
        return env
    }

    /// Seconds as the engine expects them: up to three decimals.
    public static func number(_ x: Double) -> String {
        var s = String(format: "%.3f", x)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    /// Runs `sermoncut <arguments>`, passing every event to `onEvent` as it
    /// arrives. Throws the engine's own error message if it fails (or, with
    /// `keepResults`, returns what it reported along with the error), and
    /// stops the engine if the task is cancelled.
    public func run(
        _ arguments: [String],
        keepResults: Bool = false,
        onEvent: @escaping @Sendable (EngineEvent) -> Void = { _ in }
    ) async throws -> EngineRun {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()

        // Drain standard error alongside, so a chatty tool can't block.
        let errTask = Task.detached { () -> Data in
            err.fileHandleForReading.readDataToEndOfFile()
        }

        var results: [String: Data] = [:]
        var failure: (String, String)?
        try await withTaskCancellationHandler {
            for try await line in out.fileHandleForReading.bytes.lines {
                guard let data = line.data(using: .utf8),
                      let event = try? Engine.decoder.decode(EngineEvent.self, from: data)
                else { continue }
                if event.event == "result", let step = event.step {
                    results[step] = data
                } else if event.event == "error" {
                    failure = (event.step ?? "", event.message ?? "unknown error")
                }
                onEvent(event)
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()
        let stderr = String(data: await errTask.value, encoding: .utf8) ?? ""
        try Task.checkCancellation()
        if process.terminationStatus != 0 {
            if keepResults, !results.isEmpty {
                return EngineRun(results: results, error: failure?.1 ?? "The engine reported a problem.")
            }
            if let (step, message) = failure {
                throw EngineError.failed(step: step, message: message)
            }
            let tail = stderr.split(separator: "\n").suffix(4).joined(separator: "\n")
            throw EngineError.failed(step: "", message: tail.isEmpty ? "The engine stopped unexpectedly." : tail)
        }
        return EngineRun(results: results)
    }
}
