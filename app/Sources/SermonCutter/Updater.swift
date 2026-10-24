import AppKit
import Foundation
import SermonCutterCore

/// Keeps CCI Sermon Cutter on its one current version. On launch (and twice
/// a day while open) it reads latest.json from Google Drive. When there's a
/// newer version it offers it; Update downloads the installer from the same
/// Drive folder, checks it's the real one (size, SHA-256 and the release
/// key's signature), copies the new app out of it, and swaps it in for this
/// one when this one quits, then opens it.
///
/// The new copy is downloaded by the app, not a browser, so macOS doesn't
/// hold it back the way it holds back the first download of an app that
/// isn't from a paid Apple developer account.
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        /// Shown briefly after Check for Updates found nothing new.
        case upToDate
        case available(UpdateManifest)
        /// The newest version needs a newer macOS than this Mac has.
        case needsNewerMacOS(UpdateManifest)
        case downloading(UpdateManifest, Double)
        case installing(UpdateManifest)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Later was clicked for this version.
    @Published private(set) var laterFor: Int?

    let currentVersion: String
    let currentBuild: Int
    private let manifestURL: URL?
    private let publicKey: String?

    init(bundle: Bundle = .main) {
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        currentBuild = Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
        manifestURL = (bundle.object(forInfoDictionaryKey: "SCUpdateManifestURL") as? String).flatMap(URL.init(string:))
        publicKey = bundle.object(forInfoDictionaryKey: "SCUpdatePublicKey") as? String
    }

    /// Whether the Home banner has something to say.
    var showsBanner: Bool {
        switch state {
        case .idle, .checking: return false
        case .available(let m), .needsNewerMacOS(let m): return laterFor != m.build
        default: return true
        }
    }

    /// Checks on launch, then every 12 hours.
    func watch() async {
        while !Task.isCancelled {
            await check()
            try? await Task.sleep(for: .seconds(12 * 3600))
        }
    }

    /// Reads latest.json. `userAsked` (Check for Updates) also reports
    /// "you're up to date" and problems reaching Drive.
    func check(userAsked: Bool = false) async {
        switch state {
        case .downloading, .installing, .checking: return
        default: break
        }
        guard let manifestURL else {
            if userAsked { state = .failed("This copy of the app doesn't know where updates come from.") }
            return
        }
        if userAsked { laterFor = nil }
        state = .checking
        var request = URLRequest(url: manifestURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
        request.setValue("CCI Sermon Cutter/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            // A sign-in page or an error instead of the file: Drive isn't
            // sharing it (yet), or is busy.
            guard (response as? HTTPURLResponse)?.statusCode == 200, response.mimeType != "text/html" else {
                throw URLError(.resourceUnavailable)
            }
            // Before the first release, latest.json holds only a placeholder.
            guard let m = try? JSONDecoder().decode(UpdateManifest.self, from: data), m.build > currentBuild else {
                state = userAsked ? .upToDate : .idle
                if userAsked { clearUpToDate() }
                return
            }
            state = m.runs(on: ProcessInfo.processInfo.operatingSystemVersion) ? .available(m) : .needsNewerMacOS(m)
        } catch {
            state = userAsked ? .failed("Couldn't check for a new version. Is this Mac online?") : .idle
        }
    }

    func later() {
        switch state {
        case .available(let m), .needsNewerMacOS(let m): laterFor = m.build
        default: state = .idle
        }
    }

    private func clearUpToDate() {
        Task {
            try? await Task.sleep(for: .seconds(4))
            if state == .upToDate { state = .idle }
        }
    }

    // MARK: - Updating

    /// Downloads, checks and installs `m`, then quits so the new copy can
    /// take this one's place and open.
    func update(_ m: UpdateManifest) async {
        let app = Bundle.main.bundleURL
        if app.path.contains("/AppTranslocation/") || app.path.hasPrefix("/Volumes/") {
            state = .failed("Move CCI Sermon Cutter into your Applications folder and open it from there, then update.")
            return
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("CCI Sermon Cutter update \(m.build)")
        try? fm.removeItem(at: work)
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let installer = work.appendingPathComponent("CCI Sermon Cutter.dmg")
            state = .downloading(m, 0)
            try await download(m, to: installer)
            state = .installing(m)
            let publicKey = self.publicKey
            try await Task.detached { try ReleaseKey.verify(installer, against: m, publicKey: publicKey) }.value
            let fresh = try await Task.detached { try Updater.copyApp(outOf: installer, into: work, expecting: m) }.value
            let folder = app.deletingLastPathComponent()
            guard fm.isWritableFile(atPath: folder.path), fm.isWritableFile(atPath: app.path) else {
                // Not allowed to replace it here: hand over the checked
                // installer to drag across by hand.
                NSWorkspace.shared.open(installer)
                state = .failed("This Mac doesn't let CCI Sermon Cutter replace itself. The new version is open in Finder: drag it into Applications and choose Replace.")
                return
            }
            try Updater.swapOnQuit(app: app, with: fresh, work: work)
            NSApp.terminate(nil)
        } catch {
            try? fm.removeItem(at: work)
            state = .failed("The update didn't work: \(error.localizedDescription) Try again later.")
        }
    }

    /// Downloads the installer, reporting progress, and makes sure Drive
    /// handed over the file and not a page.
    private func download(_ m: UpdateManifest, to file: URL) async throws {
        var request = URLRequest(url: m.download, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
        request.setValue("CCI Sermon Cutter/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let done = Completion()
        let task = URLSession.shared.downloadTask(with: request) { tmp, response, error in
            if let error { return done.finish(.failure(error)) }
            let http = response as? HTTPURLResponse
            guard let tmp, http?.statusCode == 200, response?.mimeType != "text/html" else {
                return done.finish(.failure(DownloadProblem.notTheFile))
            }
            do {
                try? FileManager.default.removeItem(at: file)
                try FileManager.default.moveItem(at: tmp, to: file)
                done.finish(.success(()))
            } catch {
                done.finish(.failure(error))
            }
        }
        let progress = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let f = m.size > 0 ? Double(task.countOfBytesReceived) / Double(m.size) : 0
                self?.state = .downloading(m, min(1, f))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { progress.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            done.set(c)
            task.resume()
        }
    }

    enum DownloadProblem: LocalizedError {
        case notTheFile
        case noApp
        var errorDescription: String? {
            switch self {
            case .notTheFile: return "Google Drive didn't hand over the file (it may be busy)."
            case .noApp: return "The download doesn't hold the app."
            }
        }
    }

    /// Copies the app out of the installer into `work`, and checks it's this
    /// app at the version promised.
    nonisolated static func copyApp(outOf installer: URL, into work: URL, expecting m: UpdateManifest) throws -> URL {
        let mount = work.appendingPathComponent("mount")
        let fresh = work.appendingPathComponent("new/CCI Sermon Cutter.app")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", installer.path, "-nobrowse", "-readonly", "-noautoopen", "-noverify", "-mountpoint", mount.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let inside = mount.appendingPathComponent("CCI Sermon Cutter.app")
        guard FileManager.default.fileExists(atPath: inside.path) else { throw DownloadProblem.noApp }
        try FileManager.default.createDirectory(at: fresh.deletingLastPathComponent(), withIntermediateDirectories: true)
        try run("/usr/bin/ditto", [inside.path, fresh.path])
        let info = NSDictionary(contentsOf: fresh.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              Int(info?["CFBundleVersion"] as? String ?? "") == m.build
        else { throw UpdateProblem.notTheInstaller }
        return fresh
    }

    /// Starts a small script that waits for this app to quit, puts the new
    /// copy where this one is, and opens it. If the swap fails, the old copy
    /// goes back.
    static func swapOnQuit(app: URL, with fresh: URL, work: URL) throws {
        let script = work.appendingPathComponent("swap.sh")
        try """
        #!/bin/bash
        PID="$1"; APP="$2"; NEW="$3"; WORK="$4"
        for i in $(seq 1 600); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
        OLD="$WORK/previous.app"
        if mv "$APP" "$OLD"; then
          if mv "$NEW" "$APP"; then rm -rf "$OLD"; else mv "$OLD" "$APP"; fi
        fi
        xattr -dr com.apple.quarantine "$APP" 2>/dev/null
        open "$APP"
        cd /; rm -rf "$WORK"
        """.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), app.path, fresh.path, work.path]
        try p.run()
    }

    @discardableResult
    nonisolated static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "CCI Sermon Cutter", code: Int(p.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: tool).lastPathComponent) failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))",
            ])
        }
        return text
    }
}

/// Hands a download's outcome to the code waiting for it, once.
private final class Completion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func set(_ c: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let result { lock.unlock(); c.resume(with: result); return }
        continuation = c
        lock.unlock()
    }

    func finish(_ r: Result<Void, Error>) {
        lock.lock()
        if let c = continuation { continuation = nil; lock.unlock(); c.resume(with: r); return }
        result = r
        lock.unlock()
    }
}
