/// Einstellungen eines Scanvorgangs. Der iX500 liefert nur Farbe; Grau und Schwarzweiß
/// entstehen später in Software.
public struct ScanSettings: Equatable, Sendable {
    /// Auflösung in dpi, waagerecht und senkrecht gleich.
    public var dpi: Int
    /// Beide Seiten jedes Blatts.
    public var duplex: Bool
    /// Rand um das Blatt (`overscan` in SANE). Die App scannt immer damit (`ScanProfile.scanSettings`),
    /// `scanr-cli scan` nur mit `--overscan`.
    public var overscan: Bool

    public init(dpi: Int, duplex: Bool, overscan: Bool = false) {
        self.dpi = dpi
        self.duplex = duplex
        self.overscan = overscan
    }
}
