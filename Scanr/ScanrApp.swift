import SwiftUI

@main
struct ScanrApp: App {
    var body: some Scene {
        MenuBarExtra("Scanr", systemImage: "scanner") {
            Button("Beenden") { NSApplication.shared.terminate(nil) }
        }
    }
}
