import AppKit
import SwiftUI

@main
struct ScanrApp: App {
    @State private var controller: ScannerController
    @State private var loginItem = LoginItem()
    private let notifier: SystemNotifier
    private let watcher: DeviceWatcher?

    init() {
        let notifier = SystemNotifier()
        let controller = ScannerController(environment: .live(notifier: notifier))
        _controller = State(initialValue: controller)
        self.notifier = notifier
        // Als Testumgebung geladen: kein Gerät öffnen, keine Mitteilungen anfordern.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            watcher = nil
            return
        }
        notifier.activate()
        controller.removeStaleTemps()
        let watcher = DeviceWatcher()
        self.watcher = watcher
        Task { await controller.run(arrivals: watcher.arrivals) }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(controller: controller)
        } label: {
            Image(systemName: controller.isScanning ? "doc.viewfinder" : "scanner")
                .accessibilityLabel("Scanr")
        }
        Settings {
            SettingsView(controller: controller, loginItem: loginItem)
        }
    }
}
