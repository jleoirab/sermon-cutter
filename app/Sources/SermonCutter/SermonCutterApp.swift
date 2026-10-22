import SwiftUI
import SermonCutterCore

@main
struct SermonCutterApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup("Sermon Cutter") {
            ContentView()
                .environmentObject(app)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Sunday") { app.closeSunday() }
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
                ContentUnavailableView(
                    "The engine is missing",
                    systemImage: "exclamationmark.triangle",
                    description: Text("This copy of Sermon Cutter was built without its engine. Rebuild it with app/build.sh.")
                )
            } else if let sunday = app.current {
                SundayView(model: sunday)
                    .id(ObjectIdentifier(sunday))
            } else {
                StreamsView()
            }
        }
        .task { await app.checkTools() }
    }
}
