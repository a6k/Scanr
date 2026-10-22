/// Antwort auf GET HARDWARE STATUS, Bitpositionen nach den `get_GHS_*`-Makros in `fujitsu-scsi.h`.
public struct HardwareStatus: Equatable, Sendable {
    /// Länge der vollständigen Antwort (`GHS_data_len`).
    static let dataLength = 12
    /// Kürzeste Antwort, die noch den Fehlercode (Byte 7) enthält.
    static let minimumLength = 8

    /// Papier im Einzug. Das Bit ist invertiert: gelöscht heißt Papier da (`get_GHS_hopper`).
    public var paperInHopper: Bool
    /// Scan-Taste gedrückt (`scan_sw`, Byte 4 Bit 0).
    public var scanButton: Bool
    /// Einzugsklappe offen (`adf_open`, Byte 3 Bit 5).
    public var coverOpen: Bool
    /// Doppeleinzug erkannt (`double_feed`, Byte 6 Bit 0).
    public var doubleFeed: Bool
    /// Fehlercode des Geräts (Byte 7).
    public var errorCode: UInt8
    /// Gerät im Ruhezustand (`sleep`, Byte 4 Bit 7).
    public var sleeping: Bool

    public init(paperInHopper: Bool, scanButton: Bool, coverOpen: Bool,
                doubleFeed: Bool, errorCode: UInt8, sleeping: Bool) {
        self.paperInHopper = paperInHopper
        self.scanButton = scanButton
        self.coverOpen = coverOpen
        self.doubleFeed = doubleFeed
        self.errorCode = errorCode
        self.sleeping = sleeping
    }

    public init(bytes: [UInt8]) throws {
        guard bytes.count >= Self.minimumLength else {
            throw ScannerError.protocolViolation(
                "Hardwarestatus hat \(bytes.count) Byte, erwartet mindestens \(Self.minimumLength)")
        }
        paperInHopper = bytes[3] & 0x80 == 0
        coverOpen = bytes[3] & 0x20 != 0
        sleeping = bytes[4] & 0x80 != 0
        scanButton = bytes[4] & 0x01 != 0
        doubleFeed = bytes[6] & 0x01 != 0
        errorCode = bytes[7]
    }
}

extension USBTransport {
    /// Fragt den Gerätestatus ab. Ist das Gerät beschäftigt, wirft das `ScannerError.busy`.
    public func hardwareStatus() async throws -> HardwareStatus {
        let bytes = try await command(
            Command.getHardwareStatus(), dataOut: nil,
            readLength: HardwareStatus.dataLength, timeout: .seconds(2))
        return try HardwareStatus(bytes: bytes)
    }
}
