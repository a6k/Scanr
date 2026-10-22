/// Fenstermaße eines Scans wie `update_params` in `fujitsu.c`, nur Farbe, unkomprimiert.
/// Längen in 1/1200 Zoll, Pixelangaben bei der gewählten Auflösung.
struct ScanGeometry: Equatable, Sendable {
    /// Papierbreite: US-Letter wie `init_user` (`page_width = 8.5 * 1200`), höchstens die Gerätebreite.
    static let letterWidth = 10200

    let dpi: Int
    let pageWidth: Int
    /// Bei automatischer Längenerkennung die größte Länge des Geräts: das Blatt endet per EOM,
    /// lange Kassenbons werden nicht abgeschnitten.
    let pageHeight: Int
    let pixelsPerLine: Int
    let lines: Int

    /// Mit `overscan` kommt wie in `get_page_width` links und rechts der Overscan-Rand aus der
    /// VPD dazu, höchstens bis zur Gerätebreite. Die Länge ist ohnehin schon das Gerätemaximum.
    init(dpi: Int, capabilities: ScannerCapabilities, overscan: Bool = false) {
        self.dpi = dpi
        let margin = overscan ? 2 * capabilities.overscanX * 1200 / capabilities.basicXRes : 0
        pageWidth = min(Self.letterWidth + margin, capabilities.maxX)
        pageHeight = capabilities.maxY
        // ppl_mod_by_mode[COLOR] = 2 beim iX500; Zeilen gerade wie in update_params.
        let ppl = dpi * pageWidth / 1200
        pixelsPerLine = ppl - ppl % 2
        let l = dpi * pageHeight / 1200
        lines = l - l % 2
    }

    var bytesPerLine: Int { pixelsPerLine * 3 }
    var windowWidth: Int { pixelsPerLine * 1200 / dpi }
    var windowLength: Int { lines * 1200 / dpi }
}

/// Nutzdaten-Bauer, byte-genau nach `set_window`, `diag_preread` und `send_q_table`.
enum WindowPayload {
    static let headerLength = 8      // SW_header_len
    static let descriptorLength = 64 // SW_desc_len
    static let compositionColor: UInt8 = 5 // WD_comp_CG, MODE_COLOR

    private static func put(_ b: inout [UInt8], at offset: Int, _ value: Int, bytes count: Int) {
        precondition(value >= 0 && value < 1 << (8 * count), "Wert \(value) passt nicht in \(count) Byte")
        for i in 0..<count {
            b[offset + i] = UInt8((value >> (8 * (count - 1 - i))) & 0xFF)
        }
    }

    /// SET WINDOW: Kopf mit Deskriptorlänge, ein Deskriptor für vorn, beim Duplex ein zweiter für hinten.
    static func setWindow(_ g: ScanGeometry, duplex: Bool, interlace: ColorInterlace) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: headerLength + descriptorLength * (duplex ? 2 : 1))
        put(&out, at: 6, descriptorLength, bytes: 2)  // set_WPDB_wdblen

        var d = [UInt8](repeating: 0, count: descriptorLength)
        d[0x00] = ScanSide.front.rawValue
        put(&d, at: 0x02, g.dpi, bytes: 2)
        put(&d, at: 0x04, g.dpi, bytes: 2)
        // ULX und ULY bleiben 0 (CROP_RELATIVE, tl_x = tl_y = 0).
        put(&d, at: 0x0E, g.windowWidth, bytes: 4)
        put(&d, at: 0x12, g.windowLength, bytes: 4)
        // Helligkeit, Schwelle, Kontrast 0: der iX500 hat keine Stufen dafür (VPD 0x52, 0x54).
        d[0x19] = compositionColor
        d[0x1A] = 8  // Bit je Farbe
        // RIF, Kompression (COMP_NONE) und Argument bleiben 0.
        d[0x28] = 0xC1  // WD_VUID_COLOR
        d[0x29] = 0     // window_gamma: interne Tabelle
        switch interlace {
        case .rgb: d[0x2A] = 1; d[0x2B] = 0     // WD_SCAN_ORDER_DOT, WD_SCAN_ARG_RGB
        case .bgr: d[0x2A] = 1; d[0x2B] = 5     // WD_SCAN_ORDER_DOT, WD_SCAN_ARG_BGR
        case .rrggbb: d[0x2A] = 0; d[0x2B] = 0  // WD_SCAN_ORDER_LINE, WD_SCAN_ARG_RGB
        }
        // Betonung, Spiegelung, Weißpegel bleiben 0.
        d[0x35] = 3 << 6  // WD_paper_SEL_NON_STANDARD
        put(&d, at: 0x36, g.pageWidth, bytes: 4)
        put(&d, at: 0x3A, g.pageHeight, bytes: 4)
        out.replaceSubrange(headerLength..<(headerLength + descriptorLength), with: d)

        if duplex {
            var back = d
            back[0x00] = ScanSide.back.rawValue
            back[0x35] = 0  // WD_paper_SEL_UNDEFINED
            put(&back, at: 0x36, 0, bytes: 4)
            put(&back, at: 0x3A, 0, bytes: 4)
            out.replaceSubrange((headerLength + descriptorLength)..<out.count, with: back)
        }
        return out
    }

    /// SEND DIAGNOSTIC "SET PRE READMODE" (`diag_preread`, 32 Byte).
    static func preread(_ g: ScanGeometry) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        out.replaceSubrange(0..<16, with: Array("SET PRE READMODE".utf8))
        put(&out, at: 0x10, g.dpi, bytes: 2)
        put(&out, at: 0x12, g.dpi, bytes: 2)
        put(&out, at: 0x14, g.pageWidth, bytes: 4)
        put(&out, at: 0x18, g.pageHeight, bytes: 4)
        out[0x1C] = compositionColor
        return out
    }

    /// SEND-Datentyp der JPEG-Q-Tabelle (`S_datatype_jpg_q_table`).
    static let qTableDataType: UInt8 = 0x88

    /// Q-Tabelle (`send_q_table`): 10 Byte Kopf mit den Längen 0x40 und 0x40, dann Y und UV.
    /// Der iX500 will sie auch ohne JPEG (`need_q_table`).
    static func qTable() -> [UInt8] {
        let y: [UInt8] = [
            0x04, 0x03, 0x03, 0x04, 0x03, 0x03, 0x04, 0x04,
            0x03, 0x04, 0x05, 0x05, 0x04, 0x05, 0x07, 0x0c,
            0x07, 0x07, 0x06, 0x06, 0x07, 0x0e, 0x0a, 0x0b,
            0x08, 0x0c, 0x11, 0x0f, 0x12, 0x12, 0x11, 0x0f,
            0x10, 0x10, 0x13, 0x15, 0x1b, 0x17, 0x13, 0x14,
            0x1a, 0x14, 0x10, 0x10, 0x18, 0x20, 0x18, 0x1a,
            0x1c, 0x1d, 0x1e, 0x1f, 0x1e, 0x12, 0x17, 0x21,
            0x24, 0x21, 0x1e, 0x24, 0x1b, 0x1e, 0x1e, 0x1d,
        ]
        let uv: [UInt8] = [0x05, 0x05, 0x05, 0x07, 0x06, 0x07, 0x0e, 0x07,
                           0x07, 0x0e, 0x1d, 0x13, 0x10, 0x13, 0x1d, 0x1d]
            + [UInt8](repeating: 0x1d, count: 48)
        var out = [UInt8](repeating: 0, count: 10)
        put(&out, at: 4, y.count, bytes: 2)
        put(&out, at: 6, uv.count, bytes: 2)
        return out + y + uv
    }
}

/// Antwort auf READ mit Datentyp 0x80 (`get_pixelsize`, `R_PSIZE_len` = 0x20).
struct PixelSize: Equatable, Sendable {
    static let dataType: UInt8 = 0x80
    static let length = 0x20

    let pixelsPerLine: Int
    let lines: Int
    /// Nach dem Scan: tatsächliche Breite und Länge des Papiers, 0 wenn unbekannt.
    let paperWidth: Int
    let paperLength: Int

    init(bytes: [UInt8]) throws {
        guard bytes.count >= 16 else {
            throw ScannerError.protocolViolation("Pixelgröße hat \(bytes.count) Byte, erwartet mindestens 16")
        }
        func n(_ o: Int) -> Int { (0..<4).reduce(0) { $0 << 8 | Int(bytes[o + $1]) } }
        pixelsPerLine = n(0x00)
        lines = n(0x04)
        paperWidth = n(0x08)
        paperLength = n(0x0C)
    }
}
