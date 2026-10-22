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
