/// MODE-SELECT-Nutzdaten: 4 Byte Kopf (Nullen), dann die Seite mit Code und Länge
/// (`MSEL_header_len`, `MSEL_data_min_len`, `MSEL_data_max_len` in `fujitsu-scsi.h`).
enum ModeSelectPayload {
    static let headerLength = 4
    /// Werte für Puffer, Prepick, Overscan und Doppeleinzug-Zusätze.
    static let msOff: UInt8 = 2  // MSEL_OFF

    private static func page(_ code: ModePage, length: Int = 8, _ fill: (inout [UInt8]) -> Void = { _ in }) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: length)
        p[0] = code.rawValue
        p[1] = UInt8(length - 2)
        fill(&p)
        return [UInt8](repeating: 0, count: headerLength) + p
    }

    static let msOn: UInt8 = 3   // MSEL_ON

    /// Automatik (`mode_select_auto`): ALD an (Byte 3 Bit 7). Breitenerkennung und Schräglagen-
    /// korrektur bleiben auf Vorgabe, denn sie zwängen SANE zum Puffern der ganzen Seite.
    /// Overscan (Byte 5 Bit 6 und 7, `set_MSEL_overscan`) liest Hintergrund vor und hinter dem
    /// Blatt mit; ohne bleibt das Feld auf Vorgabe (0).
    static func auto(lengthDetection: Bool, overscan: Bool = false) -> [UInt8] {
        page(.auto) {
            $0[3] = lengthDetection ? 0x80 : 0
            if overscan { $0[5] = msOn << 6 }
        }
    }

    /// Doppeleinzug (`mode_select_df`): Erkennung an mit Anhalten (`DF_STOP`, kein Continue-Bit)
    /// über die Papierdicke, also den Ultraschallsensor (Byte 2 Bit 7 und Bit 4). Schräglage und
    /// Länge bleiben aus. Papierschutz, Heftklammer und Wiederaufnahme hat der iX500 laut VPD nicht.
    static func doubleFeed() -> [UInt8] {
        page(.doubleFeed) { $0[2] = 0x80 | 0x10 }
    }

    /// Hintergrund (`mode_select_bg`): Vorgabe des Geräts, Seite leer.
    static func background() -> [UInt8] {
        page(.background)
    }

    /// Blindfarbe (`mode_select_dropout`): Vorgabe, 10-Byte-Seite.
    static func dropout() -> [UInt8] {
        page(.dropout, length: 10)
    }

    /// Puffer (`mode_select_buff`): Puffermodus aus (`init_user`: `buff_mode = MSEL_OFF`, sonst zieht
    /// das Gerät mehrere Blätter ein) und `buff_clear` 3.
    static func buffer() -> [UInt8] {
        page(.buffer) {
            $0[2] = msOff << 6
            $0[3] = 3 << 6
        }
    }

    /// Prepick (`mode_select_prepick`): Vorgabe des Geräts.
    static func prepick() -> [UInt8] {
        page(.prepick)
    }
}
