import SwiftUI
import SermonCutterCore

@main
struct SermonCutterApp: App {
    var body: some Scene {
        WindowGroup("Sermon Cutter") {
            Text("Sermon Cutter \(Timecode.format(4296))")
                .frame(minWidth: 400, minHeight: 200)
        }
    }
}
