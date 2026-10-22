import XCTest
@testable import ScannerKit

/// Nutzdaten byte-genau gegen die Makros in `fujitsu-scsi.h` und die Werte in `fujitsu.c`.
final class PayloadTests: XCTestCase {
    private let g = ScanGeometry(dpi: 300, capabilities: .iX500)

    func testVPDFixtureGivesIX500Values() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "vpd-ix500", withExtension: "bin", subdirectory: "Fixtures"))
        var parsed = try ScannerCapabilities(vpd: [UInt8](try Data(contentsOf: url)))
        // Seiten und Farbreihenfolge stehen nicht in der VPD.
        parsed.modePages = ScannerCapabilities.iX500.modePages
        XCTAssertEqual(parsed, ScannerCapabilities.iX500)
        XCTAssertFalse(parsed.needsDownloadedGamma)
    }

    func testGeometryAt300Dpi() {
        // Letter-Breite 10200, Gerätelänge 41424 (VPD 0x18: 20712 bei 600 dpi).
        XCTAssertEqual(g.pageWidth, 10200)
        XCTAssertEqual(g.pageHeight, 41424)
        XCTAssertEqual(g.pixelsPerLine, 2550)
        XCTAssertEqual(g.lines, 10356)
        XCTAssertEqual(g.windowWidth, 10200)
        XCTAssertEqual(g.windowLength, 41424)
    }

    func testPixelsPerLineIsEven() {
        // 75 dpi: 10200 * 75 / 1200 = 637,5 -> 637 -> 636 (ppl_mod 2).
        XCTAssertEqual(ScanGeometry(dpi: 75, capabilities: .iX500).pixelsPerLine, 636)
    }

    func testSetWindowDuplexRGB() {
        let p = WindowPayload.setWindow(g, duplex: true, interlace: .rgb)
        XCTAssertEqual(p.count, 136)
        XCTAssertEqual(Array(p[0..<8]), [0, 0, 0, 0, 0, 0, 0x00, 0x40])
        var d = [UInt8](repeating: 0, count: 64)
        d[0x02] = 0x01; d[0x03] = 0x2C          // 300 dpi
        d[0x04] = 0x01; d[0x05] = 0x2C
        d[0x0E...0x11] = [0x00, 0x00, 0x27, 0xD8]  // Breite 10200
        d[0x12...0x15] = [0x00, 0x00, 0xA1, 0xD0]  // Länge 41424
        d[0x19] = 5; d[0x1A] = 8
        d[0x28] = 0xC1; d[0x2A] = 1; d[0x2B] = 0
        d[0x35] = 0xC0
        d[0x36...0x39] = [0x00, 0x00, 0x27, 0xD8]
        d[0x3A...0x3D] = [0x00, 0x00, 0xA1, 0xD0]
        XCTAssertEqual(Array(p[8..<72]), d)

        var back = d
        back[0] = 0x80
        back[0x35] = 0
        back[0x36...0x3D] = [0, 0, 0, 0, 0, 0, 0, 0]
        XCTAssertEqual(Array(p[72..<136]), back)
    }

    func testSetWindowInterlaceAndSimplex() {
        let bgr = WindowPayload.setWindow(g, duplex: false, interlace: .bgr)
        XCTAssertEqual(bgr.count, 72)
        XCTAssertEqual(bgr[8 + 0x2A], 1)
        XCTAssertEqual(bgr[8 + 0x2B], 5)
        let planar = WindowPayload.setWindow(g, duplex: false, interlace: .rrggbb)
        XCTAssertEqual(planar[8 + 0x2A], 0)
        XCTAssertEqual(planar[8 + 0x2B], 0)
    }

    func testPreread() {
        let p = WindowPayload.preread(g)
        XCTAssertEqual(p.count, 32)
        XCTAssertEqual(Array(p[0..<16]), Array("SET PRE READMODE".utf8))
        XCTAssertEqual(Array(p[16..<32]), [0x01, 0x2C, 0x01, 0x2C,
                                           0x00, 0x00, 0x27, 0xD8,
                                           0x00, 0x00, 0xA1, 0xD0,
                                           0x05, 0x00, 0x00, 0x00])
    }

    func testQTable() {
        let q = WindowPayload.qTable()
        XCTAssertEqual(q.count, 0x8A)
        XCTAssertEqual(Array(q[0..<10]), [0, 0, 0, 0, 0x00, 0x40, 0x00, 0x40, 0, 0])
        XCTAssertEqual(Array(q[10..<14]), [0x04, 0x03, 0x03, 0x04])
        XCTAssertEqual(q[10 + 63], 0x1D)
        XCTAssertEqual(Array(q[74..<82]), [0x05, 0x05, 0x05, 0x07, 0x06, 0x07, 0x0E, 0x07])
        XCTAssertTrue(q[90..<138].allSatisfy { $0 == 0x1D })
    }

    func testModeSelectPages() {
        let h: [UInt8] = [0, 0, 0, 0]
        XCTAssertEqual(ModeSelectPayload.auto(lengthDetection: true), h + [0x3C, 6, 0, 0x80, 0, 0, 0, 0])
        XCTAssertEqual(ModeSelectPayload.doubleFeed(), h + [0x38, 6, 0x90, 0, 0, 0, 0, 0])
        XCTAssertEqual(ModeSelectPayload.background(), h + [0x37, 6, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(ModeSelectPayload.dropout(), h + [0x39, 8, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(ModeSelectPayload.buffer(), h + [0x3A, 6, 0x80, 0xC0, 0, 0, 0, 0])
        XCTAssertEqual(ModeSelectPayload.prepick(), h + [0x33, 6, 0, 0, 0, 0, 0, 0])
    }

    func testModeSelectAutoWithOverscan() {
        // set_MSEL_overscan(page, MSEL_ON): Byte 5, Bits 6 und 7.
        let h: [UInt8] = [0, 0, 0, 0]
        XCTAssertEqual(ModeSelectPayload.auto(lengthDetection: true, overscan: true), h + [0x3C, 6, 0, 0x80, 0, 0xC0, 0, 0])
    }

    func testOverscanWidensWindowUpToDeviceWidth() {
        // 10200 + 2 * 153 * 1200 / 600 = 10812, begrenzt auf max_x 10448 (get_page_width).
        let o = ScanGeometry(dpi: 300, capabilities: .iX500, overscan: true)
        XCTAssertEqual(o.pageWidth, 10448)
        XCTAssertEqual(o.pixelsPerLine, 2612)
        XCTAssertEqual(o.pageHeight, 41424)
    }

    func testPixelSize() throws {
        var b = [UInt8](repeating: 0, count: 32)
        b[2] = 0x09; b[3] = 0xF6        // 2550
        b[6] = 0x28; b[7] = 0x74        // 10356
        b[10] = 0x09; b[11] = 0xF6
        b[14] = 0x04; b[15] = 0xB0      // 1200
        let p = try PixelSize(bytes: b)
        XCTAssertEqual(p.pixelsPerLine, 2550)
        XCTAssertEqual(p.lines, 10356)
        XCTAssertEqual(p.paperWidth, 2550)
        XCTAssertEqual(p.paperLength, 1200)
        XCTAssertThrowsError(try PixelSize(bytes: [0, 0]))
    }

    func testReorderPlanarLine() {
        // Eine Zeile mit zwei Pixeln: RR GG BB.
        let out = ScanSession.reorder([1, 2, 3, 4, 5, 6], width: 2, lines: 1, interlace: .rrggbb)
        XCTAssertEqual(out, [1, 3, 5, 2, 4, 6])
        XCTAssertEqual(ScanSession.reorder([1, 2, 3], width: 1, lines: 1, interlace: .bgr), [3, 2, 1])
    }

    func testEomEndsOnlySidesWithShortRead() {
        var r = SheetReader(bytesPerLine: 3, totalBytes: 30)
        r.append(CommandResult(data: [0, 0, 0]), to: .back)
        r.append(CommandResult(data: [0, 0, 0], shortRead: true, endOfMedium: true), to: .front)
        XCTAssertTrue(r.front.eof)
        XCTAssertFalse(r.back.eof, "Rückseite war nicht kurz, liest weiter")
        r.append(CommandResult(data: [], shortRead: true), to: .back)
        XCTAssertTrue(r.back.eof)
        XCTAssertEqual(r.front.data, [0xFF, 0xFF, 0xFF], "invertiert")
    }
}
