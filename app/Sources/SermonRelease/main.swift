import Foundation
import SermonCutterCore

// SermonRelease: the release key, and latest.json for a new installer.
// app/build.sh runs it; the private key comes on standard input, from the
// Mac's keychain, and is never written to a file.
//
//   SermonRelease new-key
//       prints a new private key (base64)
//   SermonRelease public-key < key
//       prints the public key the app checks updates with
//   SermonRelease manifest INSTALLER APP DOWNLOAD_URL NOTES OUT < key
//       writes latest.json for INSTALLER (.dmg), holding APP (.app)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func readKey() -> String {
    String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

let args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first ?? "" {
    case "new-key":
        print(ReleaseKey.newPrivateKey())
    case "public-key":
        print(try ReleaseKey.publicKey(forPrivate: readKey()))
    case "manifest" where args.count == 6:
        let installer = URL(fileURLWithPath: args[1])
        let app = URL(fileURLWithPath: args[2])
        guard let download = URL(string: args[3]) else { fail("not a link: \(args[3])") }
        let notes = (try? String(contentsOfFile: args[4], encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let version = info["CFBundleShortVersionString"] as? String,
              let build = Int(info["CFBundleVersion"] as? String ?? ""),
              let minimum = info["LSMinimumSystemVersion"] as? String
        else { fail("\(app.path) has no version, numeric build or minimum macOS") }
        let size = (try FileManager.default.attributesOfItem(atPath: installer.path)[.size] as? NSNumber)?.int64Value ?? 0
        let sha = try ReleaseKey.sha256(of: installer)
        let manifest = UpdateManifest(
            version: version,
            build: build,
            minimumMacOS: minimum,
            notes: notes?.isEmpty == false ? notes : nil,
            download: download,
            size: size,
            sha256: sha,
            signature: try ReleaseKey.sign(build: build, sha256: sha, privateKey: readKey())
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(manifest).write(to: URL(fileURLWithPath: args[5]), options: .atomic)
        print("\(version) (build \(build)), \(size / 1_000_000) MB, SHA-256 \(sha.prefix(12))…")
    default:
        fail("usage: SermonRelease new-key | public-key | manifest INSTALLER APP DOWNLOAD_URL NOTES OUT")
    }
} catch {
    fail("\(error)")
}
