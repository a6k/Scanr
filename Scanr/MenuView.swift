import AppKit
import ScannerKit
import SwiftUI

struct MenuView: View {
    let controller: ScannerController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(controller.state.text)
        if let last = controller.lastMessage {
            Text("\(last.title): \(last.body)")
        }
        Divider()
        Picker("Profil", selection: Binding(
            get: { controller.activeProfileID },
            set: { controller.selectProfile($0) }
        )) {
            ForEach(controller.profiles) { profile in
                Text(profile.name).tag(profile.id)
            }
        }
        .pickerStyle(.inline)
        Divider()
        if controller.isScanning {
            Button("Scan abbrechen") { controller.cancelScan() }
        } else {
            Button("Jetzt scannen") { controller.scanNow() }
                .disabled(!controller.canScan)
        }
        Divider()
        Button("Hilfe") { NSWorkspace.shared.open(AppLinks.help) }
        Button("Einstellungen …") {
            NSApplication.shared.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Button("Beenden") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

extension ScannerController.State {
    var text: String {
        switch self {
        case .disconnected: "Kein Scanner verbunden"
        case .heldByScanSnapHome: "Von ScanSnap Home belegt"
        case .ready: "Bereit"
        case .coverOpen: ScannerController.coverOpenText
        case .busy: "Scanner beschäftigt"
        case .scanning(let page): page == 0 ? "Scannt" : "Scannt, Seite \(page)"
        case .recognizing: "Texterkennung …"
        case .failed(let message): "Fehler: \(message)"
        }
    }
}
