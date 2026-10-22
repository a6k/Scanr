import XCTest
@testable import ScannerKit

final class USBFramingTests: XCTestCase {
    func testWrapPadsTo31BytesWithCommandCodeAndOffset() {
        let p = USBFraming.wrap([0x12, 0, 0, 0, 96, 0])
        XCTAssertEqual(p.count, 0x1F)
        XCTAssertEqual(p[0], 0x43)
        XCTAssertEqual(Array(p[0x13..<0x19]), [0x12, 0, 0, 0, 96, 0])
        XCTAssertTrue(p[1..<0x13].allSatisfy { $0 == 0 })
    }

    func testStatusByteAtOffset9() throws {
        var s = [UInt8](repeating: 0, count: 0x0D); s[0] = 0x53
        XCTAssertEqual(try USBFraming.status(s), .good)
        s[9] = 8; XCTAssertEqual(try USBFraming.status(s), .busy)
        s[9] = 2; XCTAssertEqual(try USBFraming.status(s), .checkCondition)
    }

    func testStatusRejectsWrongLength() {
        XCTAssertThrowsError(try USBFraming.status([0x53, 0, 0]))
    }

    func testSenseTranslation() {
        func sense(_ key: UInt8, _ asc: UInt8, _ ascq: UInt8) -> [UInt8] {
            var b = [UInt8](repeating: 0, count: 18)
            b[2] = key; b[12] = asc; b[13] = ascq
            return b
        }
        XCTAssertNil(ScannerError(sense: sense(0, 0, 0)))
        XCTAssertEqual(ScannerError(sense: sense(2, 0, 0)), .busy)
        XCTAssertEqual(ScannerError(sense: sense(3, 0x80, 0x03)), .noDocuments)
        XCTAssertEqual(ScannerError(sense: sense(3, 0x80, 0x07)), .doubleFeed)
        XCTAssertEqual(ScannerError(sense: sense(3, 0x80, 0x01)), .paperJam)
        XCTAssertEqual(ScannerError(sense: sense(3, 0x80, 0x02)), .coverOpen)
        if case .protocolViolation = ScannerError(sense: sense(4, 0x80, 0x05)) {} else {
            XCTFail("Hardwarefehler muss protocolViolation sein")
        }
    }

    func testTruncateUsesRequestedLengthMinusRemainder() {
        let full = [UInt8](repeating: 7, count: 100)
        XCTAssertEqual(USBFraming.truncate(full, requested: 100, remainder: 30).count, 70)
        // Transfer lieferte schon nur 70 Byte: nicht ein zweites Mal abziehen.
        XCTAssertEqual(USBFraming.truncate(Array(full.prefix(70)), requested: 100, remainder: 30).count, 70)
        XCTAssertEqual(USBFraming.truncate(full, requested: 100, remainder: 500).count, 0)
    }

    func testSenseFlagsReadEomIliAndRemainder() {
        var b = [UInt8](repeating: 0, count: 18)
        b[2] = 0x60  // EOM und ILI, Sense-Key 0
        b[3] = 0x00; b[4] = 0x01; b[5] = 0x00; b[6] = 0x10
        let f = USBFraming.SenseFlags(sense: b)
        XCTAssertTrue(f.eom)
        XCTAssertTrue(f.ili)
        XCTAssertEqual(f.information, 0x010010)
        // Erfolg trotz EOM: keine Fehlerabbildung.
        XCTAssertNil(ScannerError(sense: b))

        b[2] = 0x20
        XCTAssertEqual(USBFraming.SenseFlags(sense: b).eom, false)
        XCTAssertEqual(USBFraming.SenseFlags(sense: b).ili, true)
    }
}
