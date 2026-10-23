import ScannerKit
import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UserNotifications

struct SettingsView: View {
    let controller: ScannerController
    let loginItem: LoginItem
    @State private var notifications = NotificationPermission()

    var body: some View {
        TabView {
            Tab("Allgemein", systemImage: "gearshape") {
                GeneralSettings(controller: controller, loginItem: loginItem, notifications: notifications)
            }
            Tab("Profile", systemImage: "slider.horizontal.3") {
                ProfileSettings(controller: controller)
            }
            Tab("Info", systemImage: "info.circle") {
                InfoSettings()
            }
        }
        .frame(width: 480, height: 560)
    }
}

// MARK: Info

/// Über Scanr und Hilfe in einem Reiter. Scanr hat als Menüleisten-App kein Programmmenü,
/// in dem „Über Scanr“ sonst stünde.
private struct InfoSettings: View {
    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Scanr").font(.title2.bold())
                        Text(AppLinks.versionLine).foregroundStyle(.secondary)
                        Link("Nach Update suchen", destination: AppLinks.latestRelease)
                            .help("Öffnet die neueste Version auf GitHub im Browser")
                    }
                }
                Text("Menüleisten-App für den Fujitsu ScanSnap iX500 per USB, ohne ScanSnap Home.")
                Text(AppLinks.copyright)
                Text("Das USB-Protokoll ist aus dem fujitsu-Backend von SANE portiert.")
                Text("Scanr gehört nicht zu Fujitsu, PFU oder Ricoh. ScanSnap ist deren Marke.")
            }
            .font(.callout)
            Section("Hilfe") {
                Link("Hilfe", destination: AppLinks.help)
                Link("Datenschutz", destination: AppLinks.privacy)
                Link("Quelltext auf GitHub", destination: AppLinks.sourceCode)
                Link(AppLinks.supportAddress, destination: AppLinks.support)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Allgemein

private struct GeneralSettings: View {
    @Bindable var controller: ScannerController
    let loginItem: LoginItem
    let notifications: NotificationPermission
    @State private var outputError: String?

    private static let placeholders: [(String, String)] = [
        ("{datum}", "Datum, etwa 2026-10-22"),
        ("{zeit}", "Uhrzeit, etwa 14-05"),
        ("{profil}", "Name des Profils"),
        ("{nr}", "Laufende Nummer, je Tag neu bei Muster mit {datum}"),
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
                LabeledContent("Ablage") {
                    Menu {
                        // Name wie im Finder, der auf diesem Mac „Desktop“ oder „Schreibtisch“ zeigen kann.
                        Button(FileManager.default.displayName(atPath: controller.defaultOutputDirectory.path)) {
                            choose(controller.defaultOutputDirectory)
                        }
                        Divider()
                        Button("Anderer Ordner …") { pickFolder() }
                    } label: {
                        Label {
                            Text(FileManager.default.displayName(atPath: controller.outputDirectory.path))
                        } icon: {
                            Image(nsImage: Self.folderIcon(controller.outputDirectory))
                        }
                    }
                    .fixedSize()
                    .help(controller.outputDirectory.path)
                }
                if let outputError {
                    Text(outputError).foregroundStyle(.red)
                }
                TextField("Muster", text: $controller.fileNamePattern)
                LabeledContent("Nächster Name", value: controller.previewName())
                ForEach(Self.placeholders, id: \.0) { token, meaning in
                    LabeledContent(token, value: meaning)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("Fehlt {nr}, wird die Nummer angehängt.")
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
            Section {
                LabeledContent("Mitteilungen", value: notifications.statusText)
                if notifications.isDenied {
                    Button("Systemeinstellungen öffnen") { notifications.openSystemSettings() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loginItem.refresh(); outputError = nil }
        .task { await notifications.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await notifications.refresh() }
        }
    }
}

extension GeneralSettings {
    /// Prüft den Ordner gleich beim Wechsel; macOS fragt dabei nach, wenn er geschützt ist.
    private func choose(_ url: URL) {
        outputError = controller.chooseOutputDirectory(url)
    }

    /// Ordnersymbol in Zeilengröße; `icon(forFile:)` liefert es sonst in voller Größe.
    private static func folderIcon(_ url: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = controller.outputDirectory
        panel.prompt = "Wählen"
        panel.message = "Ordner für die Scans"
        if panel.runModal() == .OK, let url = panel.url {
            choose(url)
        }
    }
}

/// Anmeldeobjekt über `SMAppService.mainApp`.
@Observable
final class LoginItem {
    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    private(set) var errorText: String?

    /// Auch beim Warten auf die Freigabe an: registriert ist die App dann schon, und Ausschalten
    /// muss ohne vorheriges Einschalten gehen.
    var isEnabled: Bool { status == .enabled || status == .requiresApproval }

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

/// Ob Scanr Mitteilungen zeigen darf.
@Observable
final class NotificationPermission {
    private(set) var status: UNAuthorizationStatus?

    var isDenied: Bool { status == .denied }

    var statusText: String {
        switch status {
        case .authorized, .provisional, .ephemeral: "erlaubt"
        case .denied: "abgelehnt"
        case .notDetermined: "noch nicht gefragt"
        case nil: "wird geprüft"
        @unknown default: "unbekannt"
        }
    }

    func refresh() async {
        status = await Self.currentStatus()
    }

    private nonisolated static func currentStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
            ?? URL(fileURLWithPath: "/System/Applications/System Settings.app")
        NSWorkspace.shared.open(url)
    }
}

// MARK: Profile

/// Oben ein Klappmenü mit den Profilen und Knöpfen zum Anlegen und Löschen,
/// darunter nur die Einstellungen des gewählten. Die Auswahl hier ändert nicht
/// das aktive Profil, das bleibt im Menü.
private struct ProfileSettings: View {
    let controller: ScannerController
    @State private var shownID: String?
    @State private var confirmDelete = false

    var body: some View {
        let selectedID = controller.profiles.contains { $0.id == shownID }
            ? shownID! : controller.activeProfileID
        Form {
            Section {
                HStack {
                    Picker("Profil", selection: Binding(
                        get: { selectedID },
                        set: { shownID = $0 }
                    )) {
                        ForEach(controller.profiles) { profile in
                            let active = profile.id == controller.activeProfileID
                            Text(active ? "\(profile.name) •" : profile.name)
                                .accessibilityLabel(active ? "\(profile.name), aktiv" : profile.name)
                                .tag(profile.id)
                        }
                    }
                    Button {
                        shownID = controller.addProfile(copying: selectedID)
                    } label: {
                        // Feste Höhe: das Minus-Symbol ist flacher, der Knopf wäre sonst niedriger.
                        Image(systemName: "plus").frame(width: 16, height: 16)
                    }
                    .help("Kopie dieses Profils anlegen")
                    .accessibilityLabel("Profil kopieren")
                    Button {
                        confirmDelete = true
                    } label: {
                        Image(systemName: "minus").frame(width: 16, height: 16)
                    }
                    .help("Dieses Profil löschen")
                    .accessibilityLabel("Profil löschen")
                    .disabled(!controller.canDelete(selectedID))
                }
            } footer: {
                Text("• = aktiv für die Scan-Taste, wechseln im Menü")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let profile = controller.profiles.first(where: { $0.id == selectedID }) {
                ProfileSection(profile: Binding(
                    get: { controller.profiles.first { $0.id == profile.id } ?? profile },
                    set: { controller.update($0) }
                )) {
                    controller.restoreStartValues(of: profile.id)
                }
                // Je Profil eine eigene Sektion: beim Wechsel übernimmt die alte ihren Namen
                // noch ins alte Profil, bevor die neue erscheint.
                .id(profile.id)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Profil „\(controller.profiles.first { $0.id == selectedID }?.name ?? "")“ löschen?",
            isPresented: $confirmDelete
        ) {
            Button("Löschen", role: .destructive) {
                controller.deleteProfile(selectedID)
                shownID = nil
            }
        } message: {
            Text("Die Einstellungen dieses Profils gehen verloren.")
        }
    }
}

private struct ProfileSection: View {
    @Binding var profile: ScanProfile
    let restore: () -> Void
    /// Der Name wird hier bearbeitet und erst beim Verlassen des Felds übernommen (Eingabetaste,
    /// anderes Feld, anderes Profil, Fenster zu). Leer bleibt der bisherige Name.
    @State private var nameDraft = ""
    @FocusState private var nameFocused: Bool

    private func commitName() {
        let name = ProfileLibrary.committedName(nameDraft, previous: profile.name)
        if name != profile.name { profile.name = name }
        nameDraft = name
    }

    var body: some View {
        Section {
            TextField("Name", text: $nameDraft)
                .focused($nameFocused)
                .onSubmit(commitName)
                .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
                .onAppear { nameDraft = profile.name }
                .onDisappear(perform: commitName)
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
            if let atStart = ProfileLibrary.hasStartValues(profile) {
                Button("Startwerte wiederherstellen", action: restore)
                    .disabled(atStart)
            }
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
