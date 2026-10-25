import AppKit
import SermonCutterCore

/// When YouTube asks this Mac to prove it isn't a robot (it does after a lot
/// of downloads from one network), yt-dlp can borrow the YouTube sign-in
/// from a browser on this Mac. The app turns that on by itself the first
/// time YouTube asks, and keeps it on; Settings can turn it off.
enum YouTubeSignIn {
    /// UserDefaults: yt-dlp's name for the browser in use, if any.
    static let key = "youtubeBrowser"
    /// How the engine's error starts (the engine's BOT_CHECK).
    static let marker = "YouTube wants a sign-in to show this isn't a robot"
    /// The environment variable the engine reads (the engine's COOKIES_ENV).
    static let envKey = "SERMONCUT_COOKIES_FROM_BROWSER"

    /// Browsers yt-dlp can read the sign-in from, by bundle id. Safari is
    /// left out: reading its cookies needs Full Disk Access.
    static let browsers: [(bundle: String, ytdlp: String, name: String)] = [
        ("com.google.Chrome", "chrome", "Chrome"),
        ("com.brave.Browser", "brave", "Brave"),
        ("com.microsoft.edgemac", "edge", "Edge"),
        ("org.mozilla.firefox", "firefox", "Firefox"),
        ("com.vivaldi.Vivaldi", "vivaldi", "Vivaldi"),
        ("com.operasoftware.Opera", "opera", "Opera"),
    ]

    /// The browser in use, if any.
    static var current: String? {
        UserDefaults.standard.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func name(_ ytdlp: String) -> String {
        browsers.first { $0.ytdlp == ytdlp }?.name ?? ytdlp.capitalized
    }

    /// The browsers on this Mac yt-dlp can read the sign-in from.
    static var installed: [(bundle: String, ytdlp: String, name: String)] {
        browsers.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundle) != nil }
    }

    /// The default browser when yt-dlp can read it, otherwise the first one
    /// installed that it can.
    static func pick() -> String? {
        let ws = NSWorkspace.shared
        if let url = ws.urlForApplication(toOpen: URL(string: "https://www.youtube.com")!),
           let id = Bundle(url: url)?.bundleIdentifier,
           let b = browsers.first(where: { id.hasPrefix($0.bundle) }) {
            return b.ytdlp
        }
        return browsers.first { ws.urlForApplication(withBundleIdentifier: $0.bundle) != nil }?.ytdlp
    }

    static func isRobotCheck(_ error: Error) -> Bool {
        error.localizedDescription.contains(marker) || "\(error)".contains(marker)
    }

    /// Starts using `browser`'s sign-in for every yt-dlp call from now on.
    static func turnOn(_ browser: String, engine: Engine) {
        UserDefaults.standard.set(browser, forKey: key)
        engine.environment[envKey] = browser
    }

    static func turnOff(engine: Engine?) {
        UserDefaults.standard.removeObject(forKey: key)
        engine?.environment[envKey] = nil
    }

    /// If `error` is YouTube's robot check and no browser is in use yet,
    /// turns one on and says so; the caller then tries again.
    static func handle(_ error: Error, engine: Engine) -> Bool {
        guard isRobotCheck(error), current == nil, let b = pick() else { return false }
        turnOn(b, engine: engine)
        return true
    }

    /// What to tell someone when YouTube still says no.
    static var advice: String {
        if let b = current {
            return "YouTube wants to make sure this Mac isn't a robot. Make sure you're signed in to YouTube in \(name(b)) on this Mac, then try again. If macOS asks for your password to use “\(name(b)) Safe Storage”, type it and choose Always Allow."
        }
        return "YouTube wants to make sure this Mac isn't a robot. Sign in to YouTube in Chrome or Firefox on this Mac, then try again."
    }
}
