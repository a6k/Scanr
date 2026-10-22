import Foundation

/// Scanablauf für einen Stapel im Einzug, portiert aus `sane_start`, `sane_read`,
/// `read_from_scanner` und `copy_buffer` in `fujitsu.c` (SANE), mit den iX500-Werten aus
/// `init_model`: Q-Tabelle und Pre-Read nötig, Einzug erst nach Prüfung des Papiers,
/// kein Warten nach OBJECT POSITION, Zeilenbreite durch 2 teilbar. Nur Farbe, unkomprimiert,
/// mit automatischer Längenerkennung.
public final class ScanSession: Sendable {
    /// Größe eines READ-Blocks (`global_buffer_size`).
    static let bufferSize = 64 * 1024
    /// Zeitlimit je Befehl wie `USB_COMMAND_TIME`.
    static let timeout: Duration = .seconds(30)
    /// So oft wird die Lampe angefragt, mit 0,5 s Abstand (`scanner_control`, `do_cmd`-Schleife).
    static let lampTries = 120
    /// So viele leere READs in Folge (Gerät beschäftigt) werden hingenommen, danach ist Schluss.
    static let maxEmptyReads = 600

    let transport: USBTransport
    let capabilities: ScannerCapabilities
    /// Pause nach einem leeren READ. Tests setzen sie auf 0.
    let emptyReadPause: Duration

    public convenience init(transport: USBTransport) {
        self.init(transport: transport, capabilities: .iX500)
    }

    public convenience init(transport: USBTransport, capabilities: ScannerCapabilities) {
        self.init(transport: transport, capabilities: capabilities, emptyReadPause: .milliseconds(100))
    }

    init(transport: USBTransport, capabilities: ScannerCapabilities, emptyReadPause: Duration) {
        self.transport = transport
        self.capabilities = capabilities
        self.emptyReadPause = emptyReadPause
    }

    /// Ein laufender Stapel: die Seiten und der Task, der den Scanner bedient.
    public struct Run: Sendable {
        public let pages: AsyncThrowingStream<RawPage, Error>
        /// Endet erst, wenn der Scanner gestoppt ist (SCANNER CONTROL 04 nach Abbruch oder Fehler).
        /// Abbrechen stoppt den Stapel.
        public let producer: Task<Void, Never>
    }

    /// Scannt alle Blätter im Einzug. Ein leerer Einzug zu Beginn endet mit `.noDocuments`;
    /// läuft der Einzug nach dem ersten Blatt leer, endet der Stream normal.
    public func run(_ settings: ScanSettings) -> AsyncThrowingStream<RawPage, Error> {
        start(settings).pages
    }

    /// Wie `run`, gibt aber den Task mit zurück. Wer auf ihn wartet, weiß, dass der Scanner steht.
    public func start(_ settings: ScanSettings) -> Run {
        let (pages, continuation) = AsyncThrowingStream<RawPage, Error>.makeStream()
        let task = Task {
            do {
                try await self.scanBatch(settings) { continuation.yield($0) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return Run(pages: pages, producer: task)
    }

    // MARK: Stapel

    private func scanBatch(_ settings: ScanSettings, deliver: (RawPage) -> Void) async throws {
        let caps = capabilities
        guard (caps.minRes...caps.maxRes).contains(settings.dpi) else {
            throw ScannerError.protocolViolation(
                "Auflösung \(settings.dpi) dpi liegt außerhalb von \(caps.minRes) bis \(caps.maxRes) dpi")
        }
        guard !caps.needsDownloadedGamma else {
            throw ScannerError.protocolViolation("Gerät verlangt eine Gammatabelle, das ist nicht umgesetzt")
        }
        let geometry = ScanGeometry(dpi: settings.dpi, capabilities: caps, overscan: settings.overscan)
        let interlace: ColorInterlace
        if let known = caps.colorInterlace {
            interlace = known
        } else {
            interlace = try await probeInterlace(geometry, duplex: settings.duplex)
        }
        try await configure(geometry, duplex: settings.duplex, overscan: settings.overscan, interlace: interlace)

        // iX500 bricht OBJECT POSITION ohne Papier mit Fehler ab, also vorher nachsehen (hopper_before_op).
        guard try await transport.hardwareStatus().paperInHopper else {
            throw ScannerError.noDocuments
        }

        var started = false
        var sheet = 0
        do {
            while true {
                try Task.checkCancellation()
                do {
                    try await send(Command.objectPosition(.feed))
                } catch ScannerError.noDocuments where started {
                    // Stapel zu Ende. sane_start räumt auch hier per Abbruch auf.
                    await cancelScan()
                    return
                }
                try await send(Command.scan(windows: settings.duplex ? 2 : 1),
                               dataOut: settings.duplex ? [ScanSide.front.rawValue, ScanSide.back.rawValue]
                                                        : [ScanSide.front.rawValue])
                let size = try? await pixelSize(.front)
                started = true
                sheet += 1
                try await readSheet(sheet: sheet, settings: settings, geometry: geometry,
                                    initial: size, interlace: interlace, deliver: deliver)
            }
        } catch {
            if started { await cancelScan() }
            throw error
        }
    }

    /// Einstellungen zu Beginn des Stapels, Reihenfolge wie in `sane_start`.
    private func configure(_ g: ScanGeometry, duplex: Bool, overscan: Bool, interlace: ColorInterlace) async throws {
        let caps = capabilities
        // Ohne Flachbett und Rückweg schickt scanner_control für den Einzug keinen Befehl.
        if caps.hasScannerControl && (caps.hasFlatbed || caps.hasReturnPath) {
            try await bestEffort { try await self.send(Command.scannerControl(0x00)) }
        }
        if caps.hasSendDiagnostic && caps.hasReadDiagnostic {
            let preread = WindowPayload.preread(g)
            try await bestEffort {
                try await self.send(Command.sendDiagnostic(length: preread.count), dataOut: preread)
            }
        }
        let pages: [(ModePage, [UInt8])] = [
            (.auto, ModeSelectPayload.auto(lengthDetection: true, overscan: overscan)),
            (.doubleFeed, ModeSelectPayload.doubleFeed()),
            (.background, ModeSelectPayload.background()),
            (.dropout, ModeSelectPayload.dropout()),
            (.buffer, ModeSelectPayload.buffer()),
            (.prepick, ModeSelectPayload.prepick()),
        ]
        for (page, payload) in pages where caps.modePages.contains(page) {
            try await bestEffort { try await self.send(Command.modeSelect(length: payload.count), dataOut: payload) }
        }
        // Endorser gibt es am iX500 nicht (VPD 0x20 Bit 3 und 0).
        let window = WindowPayload.setWindow(g, duplex: duplex, interlace: interlace)
        try await send(Command.setWindow(length: window.count), dataOut: window)

        let qTable = WindowPayload.qTable()
        try await bestEffort {
            try await self.send(Command.send(dataType: WindowPayload.qTableDataType, length: qTable.count), dataOut: qTable)
        }
        if caps.hasScannerControl {
            try await bestEffort {
                for attempt in 1...Self.lampTries {
                    do {
                        try await self.send(Command.scannerControl(0x05))
                        return
                    } catch let e as ScannerError where attempt < Self.lampTries && !Self.isFatal(e) {
                        try await Task.sleep(for: .milliseconds(500))
                    }
                }
            }
        }
    }

    /// Farbreihenfolge per SET WINDOW ermitteln, erste angenommene gewinnt (`init_interlace`).
    private func probeInterlace(_ g: ScanGeometry, duplex: Bool) async throws -> ColorInterlace {
        for candidate in ColorInterlace.allCases {
            let window = WindowPayload.setWindow(g, duplex: duplex, interlace: candidate)
            do {
                try await send(Command.setWindow(length: window.count), dataOut: window)
                return candidate
            } catch ScannerError.rejected {
                // Nur eine echte Ablehnung (Illegal Request) heißt „diese Reihenfolge nicht“.
                // Beschäftigt, Klappe offen usw. werden weitergereicht, sonst stünde eine falsche
                // Reihenfolge fest.
                continue
            }
        }
        throw ScannerError.protocolViolation("SET WINDOW nimmt keine Farbreihenfolge an")
    }

    // MARK: Blatt lesen

    /// Liest ein Blatt. Beim Duplex kommen beide Seiten abwechselnd, die Rückseite höchstens
    /// einen Block vor der Vorderseite (`sane_read`, `DUPLEX_INTERLACE_ALT`).
    private func readSheet(sheet: Int, settings: ScanSettings, geometry g: ScanGeometry,
                           initial: PixelSize?, interlace: ColorInterlace,
                           deliver: (RawPage) -> Void) async throws {
        // Meldet die Pixelgröße 0 oder fehlt sie, gilt das Fenster (wie SANE ohne has_pixelsize).
        let width = initial.map(\.pixelsPerLine).flatMap { $0 > 0 ? $0 : nil } ?? g.pixelsPerLine
        let lines = initial.map(\.lines).flatMap { $0 > 0 ? $0 : nil } ?? g.lines
        var reader = SheetReader(bytesPerLine: width * 3, totalBytes: width * 3 * lines)

        while !reader.front.eof {
            try Task.checkCancellation()
            try await readBlock(.front, &reader)
            if settings.duplex && reader.back.bytes < reader.front.bytes + Self.bufferSize {
                try await readBlock(.back, &reader)
            }
        }
        deliver(try await page(sheet: sheet, side: .front, data: reader.front.data, width: width,
                               interlace: interlace, dpi: settings.dpi))

        guard settings.duplex else { return }
        // Vorderseite ist fertig; die Bedingung „nicht zu weit voraus“ entfällt, sonst könnte
        // die Schleife bei sehr ungleichen Seiten stehen bleiben.
        while !reader.back.eof {
            try Task.checkCancellation()
            try await readBlock(.back, &reader)
        }
        deliver(try await page(sheet: sheet, side: .back, data: reader.back.data, width: width,
                               interlace: interlace, dpi: settings.dpi))
    }

    /// Ein READ für eine Seite, wie `read_from_scanner`.
    private func readBlock(_ side: ScanSide, _ reader: inout SheetReader) async throws {
        guard !reader[side].eof else { return }
        let remain = reader.totalBytes - reader[side].bytes
        var bytes = min(Self.bufferSize, remain)
        bytes -= bytes % reader.bytesPerLine
        // Manche Geräte wollen gerade Blockgrößen, außer beim letzten Block.
        if bytes % 2 == 1 && bytes < remain { bytes -= reader.bytesPerLine }
        // SANE würde hier ohne READ zurückkehren und endlos kreisen. Weniger als eine Zeile Rest
        // ohne Seitenende kann nicht mehr fertig werden.
        guard bytes > 0 else {
            throw ScannerError.protocolViolation(
                "Seite endet nicht: \(remain) Byte Rest, weniger als eine Zeile (\(reader.bytesPerLine) Byte)")
        }

        // Am Seitenanfang über USB erst fragen, ob Daten bereitliegen (scanner_control_ric).
        if reader[side].bytes == 0 && capabilities.hasScannerControl {
            try await readyInquiry(bytes: bytes, side: side)
        }

        let result: CommandResult
        do {
            result = try await transport.execute(
                Command.read(dataType: 0x00, length: bytes, side: side),
                dataOut: nil, readLength: bytes, timeout: Self.timeout)
        } catch ScannerError.busy {
            result = CommandResult(data: [])
        }

        // Leer ohne EOM zählt als „nichts bekommen“, auch mit ILI, sonst liefe die Schleife ewig.
        if result.data.isEmpty && !result.endOfMedium {
            reader.emptyReads += 1
            guard reader.emptyReads < Self.maxEmptyReads else {
                throw ScannerError.protocolViolation("\(Self.maxEmptyReads) READs in Folge ohne Bilddaten und ohne Seitenende")
            }
            try await Task.sleep(for: emptyReadPause)
        } else {
            reader.emptyReads = 0
        }
        reader.append(result, to: side)
    }

    /// RIC mit langer Wiederholung bei „beschäftigt“. Nur Papier- und Klappenfehler zählen,
    /// alles andere wird übergangen, weil nicht jedes Gerät RIC kennt.
    private func readyInquiry(bytes: Int, side: ScanSide) async throws {
        for attempt in 1...Self.lampTries {
            do {
                try await send(Command.scannerControlRIC(length: bytes, side: side))
                return
            } catch ScannerError.busy where attempt < Self.lampTries {
                try await Task.sleep(for: .milliseconds(500))
            } catch let e as ScannerError {
                switch e {
                case .noDocuments, .paperJam, .doubleFeed, .coverOpen, .disconnected,
                     .notFound, .deviceHeldByOtherProcess:
                    throw e
                default:
                    return
                }
            }
        }
    }

    /// Baut die Seite. Die Länge kommt bei ALD aus der Pixelgröße nach dem Lesen
    /// (`get_pixelsize(s,1)`), höchstens aber aus den tatsächlich gelesenen Zeilen.
    private func page(sheet: Int, side: ScanSide, data: [UInt8], width: Int,
                      interlace: ColorInterlace, dpi: Int) async throws -> RawPage {
        let received = data.count / (width * 3)
        var height = received
        if let actual = try? await pixelSize(side), actual.paperLength > 0 {
            height = min(received, actual.paperLength)
        }
        let rgb = Self.reorder(data, width: width, lines: height, interlace: interlace)
        return RawPage(sheet: sheet, side: side,
                       image: try RawPage.makeImage(rgb: rgb, width: width, height: height), dpi: dpi)
    }

    /// Farbreihenfolge auf RGB bringen (`copy_buffer`). Das Invertieren geschieht schon beim Lesen.
    static func reorder(_ data: [UInt8], width: Int, lines: Int, interlace: ColorInterlace) -> [UInt8] {
        let bpl = width * 3
        var out = Array(data.prefix(bpl * lines))
        switch interlace {
        case .rgb:
            break
        case .bgr:
            for i in stride(from: 0, to: out.count, by: 3) { out.swapAt(i, i + 2) }
        case .rrggbb:
            for line in 0..<lines {
                let base = line * bpl
                let src = Array(data[base..<(base + bpl)])
                for x in 0..<width {
                    out[base + x * 3] = src[x]
                    out[base + x * 3 + 1] = src[width + x]
                    out[base + x * 3 + 2] = src[2 * width + x]
                }
            }
        }
        return out
    }

    // MARK: Einzelbefehle

    private func pixelSize(_ side: ScanSide) async throws -> PixelSize {
        let bytes = try await transport.command(
            Command.read(dataType: PixelSize.dataType, length: PixelSize.length, side: side),
            dataOut: nil, readLength: PixelSize.length, timeout: Self.timeout)
        return try PixelSize(bytes: bytes)
    }

    private func send(_ cdb: [UInt8], dataOut: [UInt8]? = nil) async throws {
        _ = try await transport.command(cdb, dataOut: dataOut, readLength: nil, timeout: Self.timeout)
    }

    /// Abbruch nach Fehler oder am Stapelende (`check_for_cancel`). Fehler dabei zählen nicht mehr.
    private func cancelScan() async {
        guard capabilities.hasScannerControl else { return }
        _ = try? await transport.command(Command.scannerControl(0x04), dataOut: nil, readLength: nil, timeout: Self.timeout)
    }

    /// Befehle, deren Fehler SANE nur protokolliert. Ist das Gerät weg, geht es trotzdem nicht weiter.
    private func bestEffort(_ body: @Sendable () async throws -> Void) async throws {
        do {
            try await body()
        } catch let e as ScannerError where !Self.isFatal(e) {
            return
        }
    }

    private static func isFatal(_ e: ScannerError) -> Bool {
        switch e {
        case .disconnected, .notFound, .deviceHeldByOtherProcess: return true
        default: return false
        }
    }
}

/// Lesezustand eines Blatts je Seite (`bytes_rx`, `eof_rx`, `ili_rx`, `eom_rx`).
struct SheetReader {
    struct SideState {
        var data: [UInt8] = []
        var bytes: Int { data.count }
        var eof = false
        var shortRead = false
    }

    let bytesPerLine: Int
    let totalBytes: Int
    var front = SideState()
    var back = SideState()
    var endOfMedium = false
    var emptyReads = 0

    init(bytesPerLine: Int, totalBytes: Int) {
        self.bytesPerLine = bytesPerLine
        self.totalBytes = totalBytes
    }

    subscript(side: ScanSide) -> SideState {
        get { side == .back ? back : front }
        set { if side == .back { back = newValue } else { front = newValue } }
    }

    /// Nimmt einen READ auf. Farbe kommt beim iX500 invertiert (`reverse_by_mode[COLOR] = 1`).
    /// Bei EOM endet jede Seite, deren letzter READ kurz war.
    mutating func append(_ r: CommandResult, to side: ScanSide) {
        self[side].data.append(contentsOf: r.data.map { $0 ^ 0xFF })
        if self[side].bytes >= totalBytes { self[side].eof = true }
        self[side].shortRead = r.shortRead
        if r.endOfMedium { endOfMedium = true }
        if endOfMedium {
            if front.shortRead { front.eof = true }
            if back.shortRead { back.eof = true }
        }
    }
}
