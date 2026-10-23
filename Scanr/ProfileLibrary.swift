import ScannerKit

/// Profile in der App: fehlende Startprofile ergänzen, aktives Profil bestimmen.
nonisolated enum ProfileLibrary {
    static let startProfiles: [ScanProfile] = [.rechnungen, .auto, .foto]

    static func startValue(of id: String) -> ScanProfile? {
        startProfiles.first { $0.id == id }
    }

    /// Hängt Startprofile an, deren id in der gespeicherten Liste fehlt, etwa „Rechnungen“
    /// bei einer Liste, die vor diesem Profil gespeichert wurde.
    static func completed(_ stored: [ScanProfile]) -> [ScanProfile] {
        let ids = Set(stored.map(\.id))
        return stored + startProfiles.filter { !ids.contains($0.id) }
    }

    /// Ob ein Startprofil noch seine Startwerte hat, der Name zählt nicht.
    /// `nil` bei eigenen Profilen, die keine Startwerte haben.
    static func hasStartValues(_ profile: ScanProfile) -> Bool? {
        guard var start = startValue(of: profile.id) else { return nil }
        start.name = profile.name
        return start == profile
    }

    /// Längster Profilname. Der Name kann über {profil} in den Dateinamen gehen, und macOS
    /// erlaubt dort höchstens 255 Byte.
    static let maxNameLength = 40

    /// Der Name, der beim Verlassen des Namensfelds gilt: leer bleibt der bisherige, sonst auf
    /// `maxNameLength` gekürzt. Nicht bei jedem Tastendruck, sonst ließe sich ein Name nicht
    /// ganz löschen und neu schreiben.
    static func committedName(_ draft: String, previous: String) -> String {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return previous }
        return String(draft.prefix(maxNameLength))
    }

    static func isStartProfile(_ id: String) -> Bool {
        startProfiles.contains { $0.id == id }
    }

    /// Startprofile in fester Reihenfolge vorn, eigene Profile dahinter in ihrer Reihenfolge.
    static func ordered(_ profiles: [ScanProfile]) -> [ScanProfile] {
        let start = startProfiles.compactMap { s in profiles.first { $0.id == s.id } }
        return start + profiles.filter { !isStartProfile($0.id) }
    }

    /// „Neues Profil“, bei Namensgleichheit mit angehängter Zahl.
    static func newName(among profiles: [ScanProfile]) -> String {
        let base = "Neues Profil"
        let names = Set(profiles.map(\.name))
        guard names.contains(base) else { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Das Profil zu `id`. Gibt es keins, „Rechnungen“, sonst das erste.
    static func active(id: String, in profiles: [ScanProfile]) -> ScanProfile {
        profiles.first { $0.id == id }
            ?? profiles.first { $0.id == ScanProfile.rechnungen.id }
            ?? profiles.first
            ?? .rechnungen
    }
}

extension ScanProfile {
    /// Die JPEG-Qualität wirkt bei JPG und bei PDF-Seiten in Farbe oder Grau.
    /// Reine Schwarzweiß-PDFs speichern 1 Bit ohne JPEG.
    nonisolated var showsJPEGQuality: Bool {
        format == .jpg || colorMode != .blackWhite
    }
}
