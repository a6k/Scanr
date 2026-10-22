import AppKit
import ScannerKit
import SwiftUI

@main
struct ScanrApp: App {
    @State private var controller: ScannerController
    @State private var loginItem = LoginItem()
    private let notifier: SystemNotifier
    private let watcher: DeviceWatcher?

    init() {
        let notifier = SystemNotifier()
        let environment = ScannerEnvironment.live(notifier: notifier)
        let controller = ScannerController(environment: environment)
        _controller = State(initialValue: controller)
        self.notifier = notifier
        // Als Testumgebung geladen: kein Gerät öffnen, keine Mitteilungen anfordern.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            watcher = nil
            return
        }
        notifier.activate()
        // Nicht auf dem Hauptthread: Fragt macOS erst nach dem Zugriff auf den Schreibtisch, hält
        // das Lesen bis zur Antwort an, und so lange erschiene kein Symbol in der Menüleiste.
        let outputDirectory = environment.outputDirectory
        Task.detached(priority: .utility) { OutputFile.removeStaleTemps(in: outputDirectory) }
        let watcher = DeviceWatcher()
        self.watcher = watcher
        Task { await controller.run(arrivals: watcher.arrivals) }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(controller: controller)
        } label: {
            Group {
                if controller.isScanning {
                    Image(systemName: "doc.viewfinder")
                } else {
                    // Eigene Zeichnung des iX500, als Vorlage für helle und dunkle Leiste
                    Image("MenuBarIcon")
                }
            }
            .accessibilityLabel("Scanr")
        }
        Settings {
            SettingsView(controller: controller, loginItem: loginItem)
        }
    }
}
