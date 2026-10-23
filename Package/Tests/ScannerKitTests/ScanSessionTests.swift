import XCTest
@testable import ScannerKit

final class ScanSessionTests: XCTestCase {
    /// iX500-Fähigkeiten mit bekannter Farbreihenfolge, damit kein Probe-SET-WINDOW vorneweg läuft.
    private var caps: ScannerCapabilities {
        var c = ScannerCapabilities.iX500
        c.colorInterlace = .rgb
        return c
    }

    /// Ein Blatt mit einheitlicher Farbe. Das Gerät schickt invertierte Bytes.
    private func sheet(width: Int = 4, frontLines: Int = 6, backLines: Int = 4,
                       front: UInt8 = 0x00, back: UInt8 = 0x0F) -> FakeTransport.Sheet {
        FakeTransport.Sheet(
            width: width,
            front: [UInt8](repeating: front, count: width * frontLines * 3),
            back: [UInt8](repeating: back, count: width * backLines * 3))
    }

    private func collect(_ session: ScanSession, _ settings: ScanSettings) async -> ([RawPage], Error?) {
        var pages: [RawPage] = []
        do {
            for try await p in session.run(settings) { pages.append(p) }
            return (pages, nil)
        } catch {
            return (pages, error)
        }
    }

    func testEmptyHopperThrowsNoDocumentsBeforeFeeding() async {
        let fake = FakeTransport()
        fake.hopperEmpty = true
        fake.sheets = [sheet()]
        let (pages, error) = await collect(ScanSession(transport: fake, capabilities: caps),
                                           ScanSettings(dpi: 300, duplex: true))
        XCTAssertTrue(pages.isEmpty)
        XCTAssertEqual(error as? ScannerError, .noDocuments)
        let labels = fake.calls.map(FakeTransport.label)
        XCTAssertEqual(labels.last, "GHS")
        XCTAssertFalse(labels.contains { $0.hasPrefix("OBJECT POSITION") })
        // Noch nichts gestartet: kein Abbruchbefehl (check_for_cancel nur bei started).
        XCTAssertFalse(labels.contains("SCANNER CONTROL 04"))
    }

    func testCommandOrderForDuplexBatch() async throws {
        let fake = FakeTransport()
        fake.sheets = [sheet()]
        let (pages, error) = await collect(ScanSession(transport: fake, capabilities: caps),
                                           ScanSettings(dpi: 300, duplex: true))
        XCTAssertNil(error)
        XCTAssertEqual(pages.count, 2)

        let labels = fake.calls.map(FakeTransport.label)
        // sane_start mit iX500-Werten. SCANNER CONTROL (ADF) fällt weg: kein Flachbett, kein
        // Rückweg (VPD 0x20 Bit 6, 0x7C Bit 7), scanner_control kehrt dann ohne Befehl zurück.
        // Vor dem ersten READ je Seite fragt read_from_scanner per RIC, ob Daten bereitliegen (USB).
        XCTAssertEqual(Array(labels.prefix(18)), [
            "SEND DIAGNOSTIC",
            "MODE SELECT 3c", "MODE SELECT 38", "MODE SELECT 37",
            "MODE SELECT 39", "MODE SELECT 3a", "MODE SELECT 33",
            "SET WINDOW",
            "SEND 88",
            "SCANNER CONTROL 05",
            "GHS",
            "OBJECT POSITION 01",
            "SCAN",
            "READ PIXELSIZE front",
            "RIC front", "READ front",
            "RIC back", "READ back",
        ])
        // Nach dem Lesen: tatsächliche Größe je Seite, dann Ende des Stapels mit Abbruch.
        XCTAssertEqual(Array(labels.suffix(4)), [
            "READ PIXELSIZE front", "READ PIXELSIZE back", "OBJECT POSITION 01", "SCANNER CONTROL 04",
        ])

        let calls = fake.calls
        let scan = try XCTUnwrap(calls.first { $0.cdb[0] == 0x1B })
        XCTAssertEqual(scan.cdb, Command.scan(windows: 2))
        XCTAssertEqual(scan.dataOut, [0x00, 0x80])
        let window = try XCTUnwrap(calls.first { $0.cdb[0] == 0x24 })
        XCTAssertEqual(window.dataOut?.count, 8 + 64 + 64)
        XCTAssertEqual(window.cdb, Command.setWindow(length: 136))
        let auto = try XCTUnwrap(calls.first { $0.cdb[0] == 0x15 })
        XCTAssertEqual(auto.dataOut?[7], 0x80, "ALD an")
    }

    func testDoubleFeedAfterFirstSheetYieldsFirstSheetThenThrows() async {
        let fake = FakeTransport()
        fake.sheets = [sheet(), sheet()]
        fake.objectPositionError = [2: .doubleFeed]
        let (pages, error) = await collect(ScanSession(transport: fake, capabilities: caps),
                                           ScanSettings(dpi: 300, duplex: true))
        XCTAssertEqual(pages.map { "\($0.sheet) \($0.side)" }, ["1 front", "1 back"])
        XCTAssertEqual(error as? ScannerError, .doubleFeed)
        XCTAssertEqual(fake.calls.map(FakeTransport.label).last, "SCANNER CONTROL 04")
    }

    func testPagesCarryInvertedRGBAndActualLength() async throws {
        let fake = FakeTransport()
        // Gerät schickt 0x00 vorn und 0x0F hinten, nach dem Invertieren 0xFF und 0xF0.
        fake.sheets = [sheet(width: 4, frontLines: 6, backLines: 4)]
        let (pages, error) = await collect(ScanSession(transport: fake, capabilities: caps),
                                           ScanSettings(dpi: 300, duplex: true))
        XCTAssertNil(error)
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].image.width, 4)
        XCTAssertEqual(pages[0].image.height, 6, "Länge aus dem Papier, nicht aus dem Fenster")
        XCTAssertEqual(pages[1].image.height, 4)
        XCTAssertEqual(pages[0].dpi, 300)
        XCTAssertEqual(firstPixel(pages[0].image), [0xFF, 0xFF, 0xFF])
        XCTAssertEqual(firstPixel(pages[1].image), [0xF0, 0xF0, 0xF0])
    }

    func testSimplexReadsFrontOnlyWithOneWindow() async throws {
        let fake = FakeTransport()
        fake.sheets = [sheet(), sheet()]
        let (pages, error) = await collect(ScanSession(transport: fake, capabilities: caps),
                                           ScanSettings(dpi: 300, duplex: false))
        XCTAssertNil(error)
        XCTAssertEqual(pages.map { "\($0.sheet) \($0.side)" }, ["1 front", "2 front"])
        let labels = fake.calls.map(FakeTransport.label)
        XCTAssertFalse(labels.contains { $0.hasSuffix("back") })
        let scan = try XCTUnwrap(fake.calls.first { $0.cdb[0] == 0x1B })
        XCTAssertEqual(scan.dataOut, [0x00])
        XCTAssertEqual(fake.calls.first { $0.cdb[0] == 0x24 }?.dataOut?.count, 8 + 64)
    }

    func testUnknownInterlaceIsProbedLikeInitInterlace() async throws {
        let fake = FakeTransport()
        fake.acceptedInterlace = .bgr
        // Das Gerät schickt BGR und invertiert: B=0xFF, G=0xFF, R=0x00 ergibt Rot.
        var s = sheet(width: 2, frontLines: 2, backLines: 2)
        for i in stride(from: 0, to: s.front.count, by: 3) {
            s.front[i] = 0xFF; s.front[i + 1] = 0xFF; s.front[i + 2] = 0x00
        }
        fake.sheets = [s]
        var c = caps
        c.colorInterlace = nil
        let (pages, error) = await collect(ScanSession(transport: fake, capabilities: c),
                                           ScanSettings(dpi: 300, duplex: true))
        XCTAssertNil(error)
        let labels = fake.calls.map(FakeTransport.label)
        XCTAssertEqual(Array(labels.prefix(2)), ["SET WINDOW", "SET WINDOW"], "RGB abgelehnt, BGR angenommen")
        XCTAssertEqual(firstPixel(pages[0].image), [0xFF, 0x00, 0x00])
    }

    func testRejectsResolutionOutsideDeviceRange() async {
        let fake = FakeTransport()
        let (_, error) = await collect(ScanSession(transport: fake, capabilities: caps),
                                       ScanSettings(dpi: 1200, duplex: false))
        guard case .protocolViolation = error as? ScannerError else {
            return XCTFail("Fehler erwartet, bekam \(String(describing: error))")
        }
        XCTAssertTrue(fake.calls.isEmpty)
    }

    private func firstPixel(_ image: CGImage) -> [UInt8] {
        guard let data = image.dataProvider?.data as Data? else { return [] }
        return Array(data.prefix(3))
    }

    // MARK: Abbruch und Fehler mitten im Stapel

    func testBreakingOutMidSheetSendsCancelAndStopsFeeding() async throws {
        let fake = FakeTransport()
        fake.sheets = [sheet(), sheet(), sheet()]
        fake.readDelay = .milliseconds(20)
        let session = ScanSession(transport: fake, capabilities: caps)
        for try await page in session.run(ScanSettings(dpi: 300, duplex: true)) {
            XCTAssertEqual(page.side, .front)
            break  // mitten im ersten Blatt: die Rückseite ist noch nicht abgeholt
        }
        try await waitFor { fake.calls.map(FakeTransport.label).contains("SCANNER CONTROL 04") }
        try await Task.sleep(for: .milliseconds(100))
        let labels = fake.calls.map(FakeTransport.label)
        XCTAssertEqual(labels.last, "SCANNER CONTROL 04", "nach dem Abbruch kein weiterer Befehl")
        XCTAssertEqual(labels.filter { $0.hasPrefix("OBJECT POSITION") }.count, 1)
    }

    func testCancellingConsumerTaskSendsCancel() async throws {
        let fake = FakeTransport()
        fake.sheets = [sheet(), sheet()]
        fake.readDelay = .milliseconds(50)
        let session = ScanSession(transport: fake, capabilities: caps)
        let consumer = Task {
            var n = 0
            for try await _ in session.run(ScanSettings(dpi: 300, duplex: true)) { n += 1 }
            return n
        }
        try await waitFor { fake.calls.contains { FakeTransport.label($0) == "READ front" } }
        consumer.cancel()
        _ = try? await consumer.value
        try await waitFor { fake.calls.map(FakeTransport.label).last == "SCANNER CONTROL 04" }
        XCTAssertEqual(fake.calls.map(FakeTransport.label).filter { $0.hasPrefix("OBJECT POSITION") }.count, 1)
    }

    func testReadErrorOnSecondSheetDeliversFirstSheetThenThrows() async {
        for failure in [ScannerError.paperJam, .doubleFeed] {
            let fake = FakeTransport()
            fake.sheets = [sheet(), sheet()]
            fake.readError = [2: failure]
            let (pages, error) = await collect(ScanSession(transport: fake, capabilities: caps),
                                               ScanSettings(dpi: 300, duplex: true))
            XCTAssertEqual(pages.map { "\($0.sheet) \($0.side)" }, ["1 front", "1 back"], "\(failure)")
            XCTAssertEqual(error as? ScannerError, failure)
            let labels = fake.calls.map(FakeTransport.label)
            XCTAssertEqual(Array(labels.suffix(2)), ["READ front", "SCANNER CONTROL 04"], "\(failure)")
        }
    }

    // MARK: Schutz vor Endlosschleifen und falschen Annahmen

    func testShortReadsWithoutDataAndWithoutEomEndWithError() async {
        let fake = FakeTransport()
        fake.sheets = [sheet()]
        fake.stallSide = .back
        let session = ScanSession(transport: fake, capabilities: caps, emptyReadPause: .zero)
        let (pages, error) = await collect(session, ScanSettings(dpi: 300, duplex: true))
        XCTAssertEqual(pages.count, 1, "Vorderseite kam noch")
        guard case .protocolViolation = error as? ScannerError else {
            return XCTFail("Fehler erwartet, bekam \(String(describing: error))")
        }
        XCTAssertEqual(fake.calls.map(FakeTransport.label).last, "SCANNER CONTROL 04")
    }

    func testEmptyReadWithEomButWithoutIliEndsThePage() async {
        let fake = FakeTransport()
        fake.sheets = [sheet(width: 4, frontLines: 6, backLines: 4)]
        fake.emptyEomWithoutIli = true
        let (pages, error) = await collect(ScanSession(transport: fake, capabilities: caps, emptyReadPause: .zero),
                                           ScanSettings(dpi: 300, duplex: false))
        XCTAssertNil(error)
        XCTAssertEqual(pages.map { $0.image.height }, [6])
    }

    func testRemainderBelowOneLineEndsWithError() async {
        let fake = FakeTransport()
        // 5 Zeilen Fenster, das Gerät schickt 4,5 Zeilen ohne ILI und EOM: Rest unter einer Zeile.
        var s = sheet(width: 4, frontLines: 5, backLines: 5)
        s.front.removeLast(6)
        fake.sheets = [s]
        fake.windowLines = 5
        fake.unflaggedShortReads = true
        let (_, error) = await collect(ScanSession(transport: fake, capabilities: caps, emptyReadPause: .zero),
                                       ScanSettings(dpi: 300, duplex: false))
        guard case .protocolViolation(let text) = error as? ScannerError else {
            return XCTFail("Fehler erwartet, bekam \(String(describing: error))")
        }
        XCTAssertTrue(text.contains("weniger als eine Zeile"), text)
    }

    func testZeroPixelSizeFallsBackToWindowGeometry() async throws {
        let fake = FakeTransport()
        fake.zeroPixelSize = true
        // 50 dpi: Fensterbreite 10200 * 50 / 1200 = 425, gerade 424.
        fake.sheets = [sheet(width: 424, frontLines: 2, backLines: 2)]
        let (pages, error) = await collect(ScanSession(transport: fake, capabilities: caps),
                                           ScanSettings(dpi: 50, duplex: false))
        XCTAssertNil(error)
        XCTAssertEqual(pages.first?.image.width, 424)
        XCTAssertEqual(pages.first?.image.height, 2)
    }

    func testInterlaceProbePassesOnTransientErrors() async {
        for transient in [ScannerError.busy, .coverOpen] {
            let fake = FakeTransport()
            fake.setWindowError = transient
            var c = caps
            c.colorInterlace = nil
            let (_, error) = await collect(ScanSession(transport: fake, capabilities: c),
                                           ScanSettings(dpi: 300, duplex: true))
            XCTAssertEqual(error as? ScannerError, transient)
            XCTAssertEqual(fake.calls.map(FakeTransport.label), ["SET WINDOW"], "keine weitere Reihenfolge probiert")
        }
    }

    private func waitFor(_ condition: () -> Bool, timeout: Duration = .seconds(5)) async throws {
        let end = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < end else { return XCTFail("Bedingung nicht erreicht") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
