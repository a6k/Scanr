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

/// Ein SCSI-Befehl über USB: Befehl, optionale Daten hinaus, optional Daten zurück.
public protocol USBTransport: Sendable {
    /// Setzt einen Befehl ab und liefert die tatsächlich gelesenen Daten (leer, wenn `readLength` nil ist).
    /// Die Antwort kann kürzer als `readLength` sein (Bild-READs enden absichtlich kurz, per ILI
    /// oder EOM). Das ist kein Fehler; Aufrufer müssen die Länge prüfen.
    /// Fehlerzustände des Geräts kommen als `ScannerError`.
    func command(_ cdb: [UInt8], dataOut: [UInt8]?, readLength: Int?, timeout: Duration) async throws -> [UInt8]
}
