/// Einstellungen eines Scanvorgangs. Der iX500 liefert nur Farbe; Grau und Schwarzweiß
/// entstehen später in Software.
public struct ScanSettings: Equatable, Sendable {
    /// Auflösung in dpi, waagerecht und senkrecht gleich.
    public var dpi: Int
    /// Beide Seiten jedes Blatts.
    public var duplex: Bool

    public init(dpi: Int, duplex: Bool) {
        self.dpi = dpi
        self.duplex = duplex
    }
}
