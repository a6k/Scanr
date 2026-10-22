/// Farbreihenfolge der Bilddaten, wie `init_interlace` sie per SET WINDOW ermittelt.
public enum ColorInterlace: CaseIterable, Sendable {
    /// RGBRGB... (`COLOR_INTERLACE_RGB`)
    case rgb
    /// BGRBGR... (`COLOR_INTERLACE_BGR`)
    case bgr
    /// Je Zeile erst alle R, dann alle G, dann alle B (`COLOR_INTERLACE_RRGGBB`)
    case rrggbb
}

/// MODE-SELECT-Seiten (`MS_pc_*` in `fujitsu-scsi.h`).
public enum ModePage: UInt8, Sendable {
    case prepick = 0x33
    case background = 0x37
    case doubleFeed = 0x38
    case dropout = 0x39
    case buffer = 0x3A
    case auto = 0x3C
}

/// Was der Scanner kann, soweit der Scanablauf es braucht. Felder und Auswertung wie
/// `init_vpd`, `init_ms` und `init_model` in `fujitsu.c`.
public struct ScannerCapabilities: Equatable, Sendable {
    /// Grundauflösung, auf die sich die VPD-Fenstermaße beziehen.
    public var basicXRes: Int
    public var basicYRes: Int
    /// Größtes Fenster in 1/1200 Zoll (`max_x`, `max_y`).
    public var maxX: Int
    public var maxY: Int
    public var minRes: Int
    public var maxRes: Int
    public var hasFlatbed: Bool
    public var hasReturnPath: Bool
    public var hasEndorser: Bool
    public var hasScannerControl: Bool
    public var hasSendDiagnostic: Bool
    public var hasReadDiagnostic: Bool
    public var brightnessSteps: Int
    public var contrastSteps: Int
    public var internalGammaCount: Int
    public var downloadGammaCount: Int
    public var hasPaperProtect: Bool
    public var hasStapleDetect: Bool
    public var hasDoubleFeedRecovery: Bool
    public var hasAdvancedPaperProtect: Bool
    /// Seiten, die MODE SENSE angenommen hat (`init_ms`). Kommt nicht aus der VPD.
    public var modePages: Set<ModePage>
    /// nil heißt: vor dem ersten Scan per SET WINDOW ermitteln (`init_interlace`).
    public var colorInterlace: ColorInterlace?

    /// Wertet die Antwort auf INQUIRY VPD 0xF0 aus. `modePages` und `colorInterlace` bleiben leer.
    public init(vpd: [UInt8]) throws {
        guard vpd.count >= 0x63, Int(vpd[4]) >= 0x5F else {
            throw ScannerError.protocolViolation("VPD zu kurz: \(vpd.count) Byte, Seitenlänge \(vpd.count > 4 ? Int(vpd[4]) : 0)")
        }
        func n(_ offset: Int, _ count: Int) -> Int {
            (0..<count).reduce(0) { $0 << 8 | Int(vpd[offset + $1]) }
        }
        func bit(_ offset: Int, _ shift: Int) -> Bool {
            offset < vpd.count && (vpd[offset] >> shift) & 1 == 1
        }
        var length = Int(vpd[4])
        // Viele Geräte melden 0x5F, obwohl 4 Byte mehr gültig sind (`init_vpd`).
        if length == 0x5F { length += 4 }
        let payloadEnd = length + 4

        basicXRes = n(0x05, 2)
        basicYRes = n(0x07, 2)
        maxRes = n(0x0A, 2)
        minRes = n(0x0E, 2)
        guard basicXRes > 0, basicYRes > 0 else {
            throw ScannerError.protocolViolation("VPD ohne Grundauflösung")
        }
        maxX = n(0x14, 4) * 1200 / basicXRes
        maxY = n(0x18, 4) * 1200 / basicYRes
        hasFlatbed = bit(0x20, 6)
        hasEndorser = bit(0x20, 3) || bit(0x20, 0)
        hasPaperProtect = bit(0x21, 4)
        hasSendDiagnostic = bit(0x28, 2)
        hasReadDiagnostic = bit(0x28, 1)
        hasScannerControl = bit(0x31, 1)
        brightnessSteps = Int(vpd[0x52])
        contrastSteps = Int(vpd[0x54])
        internalGammaCount = Int(vpd[0x57] >> 4)
        downloadGammaCount = Int(vpd[0x57] & 0x0F)
        hasAdvancedPaperProtect = payloadEnd >= 0x6D && bit(0x6D, 1)
        hasStapleDetect = payloadEnd >= 0x70 && bit(0x70, 4)
        hasDoubleFeedRecovery = payloadEnd >= 0x72 && vpd.count > 0x72 && vpd[0x72] & 0x0F != 0
        hasReturnPath = payloadEnd >= 0x7C && bit(0x7C, 7)
        modePages = []
        colorInterlace = nil
    }

    /// Ob SET WINDOW eine eigene Gammatabelle anfordern müsste (`window_gamma` in `set_window`).
    /// Helligkeit und Kontrast bleiben bei 0, also zählt nur die fehlende interne Tabelle.
    public var needsDownloadedGamma: Bool {
        downloadGammaCount > 0 && internalGammaCount == 0
    }

    /// iX500, wie am Gerät gelesen (2026-10-22, Firmware 0R00). VPD-Rohbytes liegen als
    /// `Tests/ScannerKitTests/Fixtures/vpd-ix500.bin`; ein Test prüft, dass die Auswertung genau
    /// diese Werte ergibt. Die Seiten stammen aus MODE SENSE: 0x32 bis 0x35 und 0x37 bis 0x3C
    /// angenommen, 0x36 mit Sense 5/24/00 abgelehnt. 0x3D (Lampe) nicht abfragen, das legt das
    /// Gerät lahm (`init_model`: `has_MS_lamp = 0`). Die Farbreihenfolge ist am Gerät noch nicht
    /// bestimmt und wird deshalb vor dem Scan ermittelt.
    public static let iX500 = ScannerCapabilities(
        basicXRes: 600, basicYRes: 600, maxX: 10448, maxY: 41424, minRes: 50, maxRes: 600,
        hasFlatbed: false, hasReturnPath: false, hasEndorser: false, hasScannerControl: true,
        hasSendDiagnostic: true, hasReadDiagnostic: true, brightnessSteps: 0, contrastSteps: 0,
        internalGammaCount: 1, downloadGammaCount: 1, hasPaperProtect: false, hasStapleDetect: false,
        hasDoubleFeedRecovery: false, hasAdvancedPaperProtect: false,
        modePages: [.prepick, .background, .doubleFeed, .dropout, .buffer, .auto],
        colorInterlace: nil)

    public init(basicXRes: Int, basicYRes: Int, maxX: Int, maxY: Int, minRes: Int, maxRes: Int,
                hasFlatbed: Bool, hasReturnPath: Bool, hasEndorser: Bool, hasScannerControl: Bool,
                hasSendDiagnostic: Bool, hasReadDiagnostic: Bool, brightnessSteps: Int, contrastSteps: Int,
                internalGammaCount: Int, downloadGammaCount: Int, hasPaperProtect: Bool, hasStapleDetect: Bool,
                hasDoubleFeedRecovery: Bool, hasAdvancedPaperProtect: Bool,
                modePages: Set<ModePage>, colorInterlace: ColorInterlace?) {
        self.basicXRes = basicXRes; self.basicYRes = basicYRes
        self.maxX = maxX; self.maxY = maxY; self.minRes = minRes; self.maxRes = maxRes
        self.hasFlatbed = hasFlatbed; self.hasReturnPath = hasReturnPath; self.hasEndorser = hasEndorser
        self.hasScannerControl = hasScannerControl
        self.hasSendDiagnostic = hasSendDiagnostic; self.hasReadDiagnostic = hasReadDiagnostic
        self.brightnessSteps = brightnessSteps; self.contrastSteps = contrastSteps
        self.internalGammaCount = internalGammaCount; self.downloadGammaCount = downloadGammaCount
        self.hasPaperProtect = hasPaperProtect; self.hasStapleDetect = hasStapleDetect
        self.hasDoubleFeedRecovery = hasDoubleFeedRecovery; self.hasAdvancedPaperProtect = hasAdvancedPaperProtect
        self.modePages = modePages; self.colorInterlace = colorInterlace
    }
}
