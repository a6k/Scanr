import ScannerKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let controller: ScannerController
    let loginItem: LoginItem

    var body: some View {
        TabView {
            Tab("Allgemein", systemImage: "gearshape") {
                GeneralSettings(controller: controller, loginItem: loginItem)
            }
            Tab("Profile", systemImage: "slider.horizontal.3") {
                ProfileSettings(controller: controller)
            }
        }
        .frame(width: 480, height: 560)
    }
}

// MARK: Allgemein

private struct GeneralSettings: View {
    @Bindable var controller: ScannerController
    let loginItem: LoginItem

    private static let placeholders: [(String, String)] = [
        ("{datum}", "Datum, etwa 2026-10-22"),
        ("{zeit}", "Uhrzeit, etwa 14-05"),
        ("{profil}", "Name des Profils"),
        ("{nr}", "Laufende Nummer des Tages, 01, 02, …"),
    ]

    var body: some View {
        Form {
            Section {
                Picker("Aktives Profil", selection: Binding(
                    get: { controller.activeProfileID },
                    set: { controller.selectProfile($0) }
                )) {
                    ForEach(controller.profiles) { Text($0.name).tag($0.id) }
                }
            }
            Section("Dateiname") {
                TextField("Muster", text: $controller.fileNamePattern)
                LabeledContent("Nächster Name", value: controller.previewName())
                ForEach(Self.placeholders, id: \.0) { token, meaning in
                    LabeledContent(token, value: meaning)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("Fehlt {nr}, wird die Nummer angehängt. Ablage: Schreibtisch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Beim Anmelden starten", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.set($0) }
                ))
                LabeledContent("Status", value: loginItem.statusText)
                if let error = loginItem.errorText {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loginItem.refresh() }
    }
}

/// Anmeldeobjekt über `SMAppService.mainApp`.
@Observable
final class LoginItem {
    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    private(set) var errorText: String?

    var isEnabled: Bool { status == .enabled }

    var statusText: String {
        switch status {
        case .enabled: "Eingeschaltet"
        case .notRegistered: "Ausgeschaltet"
        case .requiresApproval: "Wartet auf Freigabe in Systemeinstellungen > Allgemein > Anmeldeobjekte"
        case .notFound: "App nicht gefunden"
        @unknown default: "Unbekannt"
        }
    }

    func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
        refresh()
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }
}

// MARK: Profile

private struct ProfileSettings: View {
    let controller: ScannerController

    var body: some View {
        Form {
            ForEach(controller.profiles) { profile in
                ProfileSection(profile: Binding(
                    get: { controller.profiles.first { $0.id == profile.id } ?? profile },
                    set: { controller.update($0) }
                )) {
                    controller.restoreStartValues(of: profile.id)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProfileSection: View {
    @Binding var profile: ScanProfile
    let restore: () -> Void

    var body: some View {
        Section(profile.name) {
            Picker("Auflösung", selection: $profile.dpi) {
                ForEach(ScanProfile.allowedDPI, id: \.self) { Text("\($0) dpi").tag($0) }
            }
            Picker("Farbmodus", selection: $profile.colorMode) {
                ForEach(ColorMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Format", selection: $profile.format) {
                Text("PDF").tag(OutputFormat.pdf)
                Text("JPG").tag(OutputFormat.jpg)
            }
            if profile.showsJPEGQuality {
                LabeledContent("JPEG-Qualität") {
                    HStack {
                        Slider(value: $profile.jpegQuality, in: 0.1...1, step: 0.05)
                        Text(profile.jpegQuality, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
            Toggle("Duplex", isOn: $profile.duplex)
            Toggle("Leerseiten entfernen", isOn: $profile.removeBlankPages)
            Button("Startwerte wiederherstellen", action: restore)
                .disabled(ProfileLibrary.startValue(of: profile.id) == profile)
        }
    }
}

extension ColorMode {
    var label: String {
        switch self {
        case .autoDetect: "Auto-Erkennung"
        case .color: "Farbe"
        case .gray: "Grau"
        case .blackWhite: "Schwarzweiß"
        }
    }
}
