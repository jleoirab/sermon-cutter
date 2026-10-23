import SwiftUI
import SermonCutterCore

@main
struct SermonCutterApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup("CCI Sermon Cutter") {
            ContentView()
                .environmentObject(app)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Back to Home") { app.closeSunday() }
                    .keyboardShortcut("n")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(app)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        Group {
            if app.engineMissing {
                EngineMissingView()
            } else if let sunday = app.current {
                ReviewView(model: sunday)
                    .id(ObjectIdentifier(sunday))
            } else {
                HomeView()
            }
        }
        .font(Brand.lato(14))
        .foregroundStyle(Brand.text)
        .background(Brand.paper)
        .toolbarBackground(Brand.bar, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .task { await app.checkTools() }
        .task { await app.watchForShowRequests() }
    }
}

/// Shown only when the app was built without its engine.
struct EngineMissingView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Brand.coral)
            Text("SOMETHING'S MISSING")
                .font(Brand.anton(40))
            Text("This copy of CCI Sermon Cutter is missing a piece it needs to cut sermons. Install the app again, and if that doesn't fix it, let the person who set it up know.")
                .font(Brand.lato(15))
                .foregroundStyle(Brand.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
