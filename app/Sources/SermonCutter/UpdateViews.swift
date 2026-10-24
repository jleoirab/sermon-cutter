import SwiftUI
import SermonCutterCore

/// On Home: a new version, how the update is going, or why it can't happen.
struct UpdateBanner: View {
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var app: AppModel

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Brand.coral)
                .frame(width: 40, height: 40)
                .background(Brand.card2, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Brand.lato(15, .black))
                if let detail {
                    Text(detail)
                        .font(Brand.lato(13))
                        .foregroundStyle(Brand.text2)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            UpdateActions()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 20, padding: 16)
    }

    private var icon: String {
        switch updater.state {
        case .available, .downloading, .installing: return "arrow.down.circle"
        case .upToDate: return "checkmark.circle"
        default: return "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch updater.state {
        case .available(let m): return "Version \(m.version) is ready"
        case .needsNewerMacOS(let m): return "Version \(m.version) needs \(m.minimumMacOSName)"
        case .downloading(let m, _): return "Downloading version \(m.version)"
        case .installing(let m): return "Installing version \(m.version)"
        case .upToDate: return "You have the latest version (\(updater.currentVersion))"
        case .failed: return "Couldn't update"
        case .idle, .checking: return ""
        }
    }

    private var detail: String? {
        switch updater.state {
        case .available(let m): return m.notes ?? "You have \(updater.currentVersion)."
        case .needsNewerMacOS:
            let os = ProcessInfo.processInfo.operatingSystemVersion
            return "This Mac has macOS \(os.majorVersion).\(os.minorVersion). Update it in System Settings › General › Software Update, then this app can update too."
        case .downloading(let m, let f):
            return "\(Int(f * 100))% of \(m.size / 1_000_000) MB from the CCI Sermon Cutter folder on Google Drive"
        case .installing: return "Checking it's the real thing. CCI Sermon Cutter will close and open again."
        case .failed(let why): return why
        default: return nil
        }
    }
}

/// The buttons that go with the update's state, on Home and in Settings.
struct UpdateActions: View {
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var app: AppModel

    var body: some View {
        HStack(spacing: 14) {
            switch updater.state {
            case .available(let m):
                if exporting {
                    Text("Update once the export is done")
                        .font(Brand.lato(13))
                        .foregroundStyle(Brand.text2)
                } else {
                    Button("Later") { updater.later() }
                        .buttonStyle(LinkButtonStyle())
                    Button("Update") { Task { await updater.update(m) } }
                        .buttonStyle(PillButtonStyle(kind: .primary, size: .small))
                }
            case .needsNewerMacOS:
                Button("OK") { updater.later() }
                    .buttonStyle(PillButtonStyle(kind: .outline, size: .small))
            case .downloading(_, let f):
                ProgressBar(fraction: f, color: Brand.coral, height: 6)
                    .frame(width: 140)
            case .installing:
                ProgressView().controlSize(.small)
            case .failed:
                Button("Close") { updater.later() }
                    .buttonStyle(LinkButtonStyle())
                Button("Try again") { Task { await updater.check(userAsked: true) } }
                    .buttonStyle(PillButtonStyle(kind: .outline, size: .small))
            case .idle, .checking, .upToDate:
                EmptyView()
            }
        }
    }

    /// An export would stop if the app quit for the update.
    private var exporting: Bool {
        app.current?.exporting == true || app.running.values.contains { $0.exporting }
    }
}

/// In Settings: this version, and Check for updates.
struct UpdatesCard: View {
    @EnvironmentObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Updates")
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CCI Sermon Cutter \(updater.currentVersion)")
                        .font(Brand.lato(15, .black))
                    Text(status)
                        .font(Brand.lato(12))
                        .foregroundStyle(Brand.text2)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                switch updater.state {
                case .idle, .upToDate:
                    Button("Check for updates") { Task { await updater.check(userAsked: true) } }
                        .buttonStyle(PillButtonStyle(kind: .outline, size: .small))
                case .checking:
                    ProgressView().controlSize(.small)
                default:
                    UpdateActions()
                }
            }
            .well()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 20, padding: 18)
    }

    private var status: String {
        switch updater.state {
        case .idle: return "Checks for a new version each time it opens."
        case .checking: return "Checking…"
        case .upToDate: return "This is the latest version."
        case .available(let m): return "Version \(m.version) is ready."
        case .needsNewerMacOS(let m): return "Version \(m.version) needs \(m.minimumMacOSName)."
        case .downloading(let m, let f): return "Downloading version \(m.version): \(Int(f * 100))%"
        case .installing(let m): return "Installing version \(m.version)…"
        case .failed(let why): return why
        }
    }
}
