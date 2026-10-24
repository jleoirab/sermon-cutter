import CryptoKit
import Foundation

/// `latest.json`, published next to the installer on Google Drive: the one
/// version there is, what it needs, and how to check the installer is the
/// real one.
public struct UpdateManifest: Codable, Equatable, Sendable {
    /// "0.7", as people see it.
    public var version: String
    /// Counts up with every release; what's compared.
    public var build: Int
    /// The oldest macOS it runs on, like "14.0".
    public var minimumMacOS: String
    /// A line or two on what's new.
    public var notes: String?
    /// Where the installer (.dmg) downloads from.
    public var download: URL
    public var size: Int64
    /// The installer's SHA-256, in hex.
    public var sha256: String
    /// The release key's Ed25519 signature of `signedMessage`, in base64.
    public var signature: String

    public init(version: String, build: Int, minimumMacOS: String, notes: String?, download: URL, size: Int64, sha256: String, signature: String) {
        self.version = version
        self.build = build
        self.minimumMacOS = minimumMacOS
        self.notes = notes
        self.download = download
        self.size = size
        self.sha256 = sha256
        self.signature = signature
    }

    /// What the release key signs: this app, the build, and the installer's
    /// SHA-256. A copy of latest.json changed by anyone else fails the check.
    public static func signedMessage(build: Int, sha256: String) -> Data {
        Data("CCI Sermon Cutter\n\(build)\n\(sha256.lowercased())".utf8)
    }

    /// Whether this Mac's macOS is new enough.
    public func runs(on os: OperatingSystemVersion) -> Bool {
        let parts = minimumMacOS.split(separator: ".").map { Int($0) ?? 0 }
        let need = OperatingSystemVersion(
            majorVersion: parts.count > 0 ? parts[0] : 0,
            minorVersion: parts.count > 1 ? parts[1] : 0,
            patchVersion: parts.count > 2 ? parts[2] : 0
        )
        return (os.majorVersion, os.minorVersion, os.patchVersion) >= (need.majorVersion, need.minorVersion, need.patchVersion)
    }

    /// "macOS 15" or "macOS 14.4".
    public var minimumMacOSName: String {
        let s = minimumMacOS.hasSuffix(".0") ? String(minimumMacOS.dropLast(2)) : minimumMacOS
        return "macOS \(s)"
    }
}

public enum UpdateProblem: LocalizedError, Equatable {
    case wrongSize
    case notTheInstaller
    case notSigned
    case noReleaseKey

    public var errorDescription: String? {
        switch self {
        case .wrongSize: return "The download isn't the size it should be."
        case .notTheInstaller: return "The download doesn't match the new version."
        case .notSigned: return "The new version isn't signed by CCI Sermon Cutter's release key."
        case .noReleaseKey: return "This copy of the app can't check new versions."
        }
    }
}

public enum ReleaseKey {
    /// A new Ed25519 private key, in base64.
    public static func newPrivateKey() -> String {
        Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString()
    }

    /// The public key for a base64 private key, in base64.
    public static func publicKey(forPrivate base64: String) throws -> String {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)) ?? Data())
        return key.publicKey.rawRepresentation.base64EncodedString()
    }

    /// Signs a release: the base64 signature of `signedMessage(build, sha256)`.
    public static func sign(build: Int, sha256: String, privateKey base64: String) throws -> String {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)) ?? Data())
        return try key.signature(for: UpdateManifest.signedMessage(build: build, sha256: sha256)).base64EncodedString()
    }

    /// The SHA-256 of a file, in hex, reading it a few megabytes at a time.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Checks a downloaded installer against the manifest and the app's public key.
    public static func verify(_ file: URL, against manifest: UpdateManifest, publicKey base64: String?) throws {
        guard let base64, let raw = Data(base64Encoded: base64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        else { throw UpdateProblem.noReleaseKey }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
        guard size == manifest.size else { throw UpdateProblem.wrongSize }
        guard try sha256(of: file) == manifest.sha256.lowercased() else { throw UpdateProblem.notTheInstaller }
        guard let signature = Data(base64Encoded: manifest.signature),
              key.isValidSignature(signature, for: UpdateManifest.signedMessage(build: manifest.build, sha256: manifest.sha256))
        else { throw UpdateProblem.notSigned }
    }
}
