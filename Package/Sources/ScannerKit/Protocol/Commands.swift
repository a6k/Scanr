/// Seite eines Dokuments, als Fenster-ID im READ-Befehl (`WD_wid_front`, `WD_wid_back`).
public enum ScanSide: UInt8, Sendable {
    case front = 0x00
    case back = 0x80
}

/// Aktion für OBJECT POSITION (`OP_Discharge`, `OP_Feed`, `OP_Halt`).
public enum ObjectPositionAction: UInt8, Sendable {
    case discharge = 0x00
    case feed = 0x01
    case halt = 0x04
}

/// CDB-Bauer für die SCSI-Befehle des Scanners. Opcodes und Felder stammen aus `fujitsu-scsi.h` (SANE).
/// Befehle mit Nutzdaten (SET WINDOW, SEND, MODE SELECT, SEND DIAGNOSTIC) bauen hier nur das CDB;
/// die Nutzdaten kommen von den Aufrufern.
public enum Command {
    /// Schreibt `value` big-endian in `count` Byte ab `offset` (`putnbyte`).
    /// Werte, die nicht in `count` Byte passen, sind ein Programmierfehler und brechen ab.
    private static func put(_ cdb: inout [UInt8], at offset: Int, _ value: Int, bytes count: Int) {
        precondition(value >= 0 && value < 1 << (8 * count), "Wert \(value) passt nicht in \(count) Byte")
        for i in 0..<count {
            cdb[offset + i] = UInt8((value >> (8 * (count - 1 - i))) & 0xFF)
        }
    }

    /// INQUIRY, Standardantwort mit 96 Byte (`INQUIRY_std_len`).
    public static func inquiry() -> [UInt8] {
        [0x12, 0, 0, 0, 96, 0]
    }

    /// INQUIRY mit EVPD-Bit (Byte 1 Bit 0), Seite 0xF0 und 204 Byte Antwort (`init_vpd`, `INQUIRY_vpd_len`).
    public static func inquiryVPD() -> [UInt8] {
        [0x12, 0x01, 0xF0, 0, 204, 0]
    }

    /// MODE SENSE(6) für eine Seite (Byte 2, untere 6 Bit) mit 0x14 Byte Antwort (`init_ms`, `MODE_SENSE_data_len`).
    public static func modeSense(page: UInt8) -> [UInt8] {
        [0x1A, 0, page & 0x3F, 0, 0x14, 0]
    }

    /// REQUEST SENSE, 18 Byte (`RS_return_size`).
    public static func requestSense() -> [UInt8] {
        [0x03, 0, 0, 0, 0x12, 0]
    }

    /// GET HARDWARE STATUS, Allocation Length 12 (`GHS_data_len`) in Byte 7 und 8.
    public static func getHardwareStatus() -> [UInt8] {
        var cdb = [UInt8](repeating: 0, count: 10)
        cdb[0] = 0xC2
        put(&cdb, at: 7, HardwareStatus.dataLength, bytes: 2)
        return cdb
    }

    /// SCANNER CONTROL. `function` ist z. B. 0x04 (Abbruch), 0x1F (continuous) oder 0x2F (rpath);
    /// das untere Nibble liegt in Byte 1, `function >> 4` in Byte 2.
    public static func scannerControl(_ function: UInt8) -> [UInt8] {
        var cdb = [UInt8](repeating: 0, count: 10)
        cdb[0] = 0xF1
        cdb[1] = function & 0x0F
        cdb[2] = function >> 4
        return cdb
    }

    /// SCANNER CONTROL mit RIC-Bit (Byte 1 Bit 4): fragt, ob `length` Byte Bilddaten der Seite
    /// bereitliegen (`scanner_control_ric`). Fenster-ID in Byte 2, Länge 3 Byte ab Offset 6.
    public static func scannerControlRIC(length: Int, side: ScanSide) -> [UInt8] {
        var cdb = [UInt8](repeating: 0, count: 10)
        cdb[0] = 0xF1
        cdb[1] = 0x10
        cdb[2] = side.rawValue
        put(&cdb, at: 6, length, bytes: 3)
        return cdb
    }

    /// OBJECT POSITION: Einzug, Auswurf oder Halt, Aktion in den unteren drei Bit von Byte 1.
    public static func objectPosition(_ action: ObjectPositionAction) -> [UInt8] {
        var cdb = [UInt8](repeating: 0, count: 10)
        cdb[0] = 0x31
        cdb[1] = action.rawValue & 0x07
        return cdb
    }

    /// SET WINDOW, Länge der Fensterdaten (3 Byte ab Offset 6).
    public static func setWindow(length: Int) -> [UInt8] {
        var cdb = [UInt8](repeating: 0, count: 10)
        cdb[0] = 0x24
        put(&cdb, at: 6, length, bytes: 3)
        return cdb
    }

    /// SEND mit Datentyp (Byte 2) und Länge (3 Byte ab Offset 6), z. B. 0x88 für die JPEG-Q-Tabelle.
    public static func send(dataType: UInt8, length: Int) -> [UInt8] {
        var cdb = [UInt8](repeating: 0, count: 10)
        cdb[0] = 0x2A
        cdb[2] = dataType
        put(&cdb, at: 6, length, bytes: 3)
        return cdb
    }

    /// MODE SELECT mit Page-Format-Bit (Byte 1, Bit 4) und Länge in Byte 4.
    public static func modeSelect(length: Int) -> [UInt8] {
        precondition(length >= 0 && length <= 0xFF, "MODE SELECT: Länge \(length) passt nicht in ein Byte")
        return [0x15, 0x10, 0, 0, UInt8(length), 0]
    }

    /// SCAN mit Anzahl der Fenster-IDs, die als Nutzdaten folgen (Byte 4).
    public static func scan(windows: Int) -> [UInt8] {
        precondition(windows >= 0 && windows <= 0xFF, "SCAN: \(windows) Fenster passen nicht in ein Byte")
        return [0x1B, 0, 0, 0, UInt8(windows), 0]
    }

    /// READ mit Datentyp (Byte 2, 0x00 Bilddaten), Fenster-ID für die Seite (Byte 5) und Länge (3 Byte ab Offset 6).
    public static func read(dataType: UInt8, length: Int, side: ScanSide) -> [UInt8] {
        var cdb = [UInt8](repeating: 0, count: 10)
        cdb[0] = 0x28
        cdb[2] = dataType
        cdb[5] = side.rawValue
        put(&cdb, at: 6, length, bytes: 3)
        return cdb
    }

    /// SEND DIAGNOSTIC ohne Selbsttest, Länge der Nutzdaten (2 Byte ab Offset 3).
    public static func sendDiagnostic(length: Int) -> [UInt8] {
        var cdb = [UInt8](repeating: 0, count: 6)
        cdb[0] = 0x1D
        put(&cdb, at: 3, length, bytes: 2)
        return cdb
    }
}
