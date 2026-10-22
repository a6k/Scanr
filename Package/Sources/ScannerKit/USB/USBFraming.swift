/// SCSI-Status aus dem 13-Byte-Statuspaket.
public enum ScsiStatus: Equatable, Sendable {
    case good, busy, checkCondition
}

/// Verpackung der SCSI-Befehle für USB, Werte aus `fujitsu-scsi.h` (SANE).
public enum USBFraming {
    static let commandCode: UInt8 = 0x43
    static let commandLength = 0x1F
    static let commandOffset = 0x13
    static let statusCode: UInt8 = 0x53
    static let statusLength = 0x0D
    static let statusOffset = 0x09

    /// 31 Byte: Code 0x43 vorn, CDB ab Offset 0x13, Rest Nullen.
    public static func wrap(_ cdb: [UInt8]) -> [UInt8] {
        precondition(cdb.count <= commandLength - commandOffset, "CDB zu lang")
        var packet = [UInt8](repeating: 0, count: commandLength)
        packet[0] = commandCode
        packet.replaceSubrange(commandOffset..<(commandOffset + cdb.count), with: cdb)
        return packet
    }

    /// Kürzt gelesene Daten nach ILI: Ergebnislänge ist die angeforderte Länge minus Restlänge
    /// (wie `*inLen = askLen - rs_info` in `do_usb_cmd`), höchstens aber das tatsächlich Gelesene.
    public static func truncate(_ data: [UInt8], requested: Int, remainder: Int) -> [UInt8] {
        Array(data.prefix(max(0, min(data.count, requested - remainder))))
    }

    /// Bits aus den Sense-Daten, die auch bei Erfolg gesetzt sein können
    /// (`get_RS_EOM`, `get_RS_ILI`, `get_RS_information` in `fujitsu-scsi.h`).
    public struct SenseFlags: Equatable, Sendable {
        public var eom: Bool
        public var ili: Bool
        /// Restlänge bei ILI (Byte 3 bis 6).
        public var information: Int

        public init(sense: [UInt8]) {
            guard sense.count >= 7 else {
                eom = false; ili = false; information = 0
                return
            }
            eom = sense[2] & 0x40 != 0
            ili = sense[2] & 0x20 != 0
            information = Int(UInt32(sense[3]) << 24 | UInt32(sense[4]) << 16 | UInt32(sense[5]) << 8 | UInt32(sense[6]))
        }
    }

    /// Liest das Statusbyte (Offset 9) aus dem 13-Byte-Paket.
    public static func status(_ packet: [UInt8]) throws -> ScsiStatus {
        guard packet.count == statusLength else {
            throw ScannerError.protocolViolation("Statuspaket hat \(packet.count) statt \(statusLength) Byte")
        }
        switch packet[statusOffset] {
        case 0: return .good
        case 8: return .busy
        default: return .checkCondition
        }
    }
}

extension ScannerError {
    /// Übersetzt Sense-Daten (18 Byte) nach `sense_handler` in `fujitsu.c`.
    /// nil heißt: kein Fehler (Sense-Key 0, z. B. EOM oder ILI bei erfolgreichem Befehl).
    init?(sense: [UInt8]) {
        guard sense.count >= 14 else {
            self = .protocolViolation("Sense-Daten zu kurz: \(sense.count) Byte")
            return
        }
        let key = sense[2] & 0x0F
        let asc = sense[12]
        let ascq = sense[13]
        let hex = { (v: UInt8) in "0x" + String(v, radix: 16) }
        let unknown = ScannerError.protocolViolation(
            "Sense-Key \(hex(key)), ASC \(hex(asc)), ASCQ \(hex(ascq))")

        switch key {
        case 0x0:
            if asc == 0x00 && ascq == 0x00 { return nil }
            if asc == 0x80 { return nil }  // Hardware-Statusbits
            self = unknown
        case 0x5:
            self = .rejected(asc: asc, ascq: ascq)
        case 0x2:
            self = (asc == 0 && ascq == 0) ? .busy : unknown
        case 0x3:
            guard asc == 0x80 else { self = unknown; return }
            switch ascq {
            case 0x01, 0x04, 0x07, 0x08, 0x09, 0x0C:
                self = ascq == 0x07 ? .doubleFeed : .paperJam
            case 0x02: self = .coverOpen
            case 0x03, 0x20, 0x30: self = .noDocuments
            case 0x13, 0x32: self = .busy
            default: self = unknown
            }
        default:
            self = unknown
        }
    }
}
