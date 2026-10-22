import Foundation

public enum ColorMode: String, Codable, CaseIterable, Sendable {
    /// Je Seite: ohne nennenswerte Farbe 1 Bit Schwarzweiß, sonst Farbe.
    case autoDetect
    case color
    case gray
    case blackWhite
}

public enum OutputFormat: String, Codable, CaseIterable, Sendable {
    case pdf
    case jpg
}

/// Ein Scanprofil: was gescannt wird und wie die Ausgabe entsteht.
public struct ScanProfile: Codable, Equatable, Sendable, Identifiable {
    public static let allowedDPI = [150, 200, 300, 600]

    public var id: String
    public var name: String
    public var dpi: Int
    public var colorMode: ColorMode
    public var format: OutputFormat
    public var jpegQuality: Double
    public var duplex: Bool
    public var removeBlankPages: Bool

    public init(
        id: String, name: String, dpi: Int, colorMode: ColorMode, format: OutputFormat,
        jpegQuality: Double, duplex: Bool, removeBlankPages: Bool
    ) {
        self.id = id
        self.name = name
        self.dpi = dpi
        self.colorMode = colorMode
        self.format = format
        self.jpegQuality = jpegQuality
        self.duplex = duplex
        self.removeBlankPages = removeBlankPages
    }

    public var scanSettings: ScanSettings { ScanSettings(dpi: dpi, duplex: duplex) }

    public static let auto = ScanProfile(
        id: "auto", name: "Auto", dpi: 300, colorMode: .autoDetect, format: .pdf,
        jpegQuality: 0.6, duplex: true, removeBlankPages: true)

    public static let foto = ScanProfile(
        id: "foto", name: "Foto", dpi: 600, colorMode: .color, format: .jpg,
        jpegQuality: 0.9, duplex: true, removeBlankPages: true)

    /// Startwert eines Profils mit dieser id, sonst nil.
    static func startValue(forID id: String) -> ScanProfile? {
        [auto, foto].first { $0.id == id }
    }

    // Beim Lesen fällt eine unzulässige Auflösung auf den Startwert des Profils zurück
    // (300 dpi bei eigenen Profilen), damit der Scanner nie einen ungültigen Wert bekommt.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        let rawDPI = try c.decode(Int.self, forKey: .dpi)
        dpi = Self.allowedDPI.contains(rawDPI) ? rawDPI : (Self.startValue(forID: id)?.dpi ?? 300)
        colorMode = try c.decode(ColorMode.self, forKey: .colorMode)
        format = try c.decode(OutputFormat.self, forKey: .format)
        let q = try c.decode(Double.self, forKey: .jpegQuality)
        jpegQuality = q.isNaN ? (Self.startValue(forID: id)?.jpegQuality ?? 0.6) : max(0, min(1, q))
        duplex = try c.decode(Bool.self, forKey: .duplex)
        removeBlankPages = try c.decode(Bool.self, forKey: .removeBlankPages)
    }
}

/// Speichert die Profile als JSON in den UserDefaults. Fehlt der Eintrag oder ist er
/// unlesbar, kommen die Startwerte.
public struct ProfileStore: @unchecked Sendable {
    static let key = "scanProfiles"
    let defaults: UserDefaults

    private struct Lossy: Decodable {
        let profile: ScanProfile?
        init(from decoder: Decoder) throws { profile = try? ScanProfile(from: decoder) }
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func load() -> [ScanProfile] {
        // Elementweise lesen: ein beschädigter Eintrag kostet nicht alle anderen.
        guard let data = defaults.data(forKey: Self.key),
              let boxes = try? JSONDecoder().decode([Lossy].self, from: data)
        else { return [.auto, .foto] }
        let profiles = boxes.compactMap(\.profile)
        return profiles.isEmpty ? [.auto, .foto] : profiles
    }

    public func save(_ profiles: [ScanProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
