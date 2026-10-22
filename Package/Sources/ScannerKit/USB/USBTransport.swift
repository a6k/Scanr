/// Fehler der Scanner-Schicht. Sense-Daten und USB-Fehler werden hierauf abgebildet.
public enum ScannerError: Error, Equatable, Sendable {
    case notFound
    case deviceHeldByOtherProcess
    case busy
    case disconnected
    case noDocuments
    case doubleFeed
    case paperJam
    case coverOpen
    case protocolViolation(String)
}

/// Ergebnis eines erfolgreichen Befehls samt der Sense-Bits, die bei Erfolg mitkommen können.
/// Der Bild-READ braucht beides: ILI heißt kurz gelesen, EOM heißt Papierende
/// (`rs_ili` und `rs_eom` in `sense_handler`).
public struct CommandResult: Equatable, Sendable {
    public var data: [UInt8]
    /// ILI: Das Gerät hat weniger geliefert als angefordert.
    public var shortRead: Bool
    /// EOM: Ende des Mediums, das Blatt ist zu Ende.
    public var endOfMedium: Bool

    public init(data: [UInt8], shortRead: Bool = false, endOfMedium: Bool = false) {
        self.data = data
        self.shortRead = shortRead
        self.endOfMedium = endOfMedium
    }
}

/// Ein SCSI-Befehl über USB: Befehl, optionale Daten hinaus, optional Daten zurück.
public protocol USBTransport: Sendable {
    /// Setzt einen Befehl ab und liefert die tatsächlich gelesenen Daten (leer, wenn `readLength` nil ist).
    /// Die Antwort kann kürzer als `readLength` sein (Bild-READs enden absichtlich kurz, per ILI
    /// oder EOM). Das ist kein Fehler; Aufrufer müssen die Länge prüfen.
    /// Fehlerzustände des Geräts kommen als `ScannerError`.
    func command(_ cdb: [UInt8], dataOut: [UInt8]?, readLength: Int?, timeout: Duration) async throws -> [UInt8]

    /// Wie `command`, liefert zusätzlich ILI und EOM aus den Sense-Daten.
    /// Die Vorgabe meldet beide Bits als gelöscht; der echte Transport überschreibt das.
    func execute(_ cdb: [UInt8], dataOut: [UInt8]?, readLength: Int?, timeout: Duration) async throws -> CommandResult
}

extension USBTransport {
    public func execute(_ cdb: [UInt8], dataOut: [UInt8]?, readLength: Int?, timeout: Duration) async throws -> CommandResult {
        CommandResult(data: try await command(cdb, dataOut: dataOut, readLength: readLength, timeout: timeout))
    }
}
