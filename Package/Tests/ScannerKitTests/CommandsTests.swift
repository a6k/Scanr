import XCTest
@testable import ScannerKit

/// Erwartete Bytes aus den Makros in `fujitsu-scsi.h` (SANE).
final class CommandsTests: XCTestCase {
    func testInquiry() {
        XCTAssertEqual(Command.inquiry(), [0x12, 0, 0, 0, 96, 0])
    }

    func testRequestSense() {
        XCTAssertEqual(Command.requestSense(), [0x03, 0, 0, 0, 0x12, 0])
    }

    func testGetHardwareStatus() {
        // Opcode 0xC2, Allocation Length 12 (GHS_data_len) in Byte 7 und 8.
        XCTAssertEqual(Command.getHardwareStatus(), [0xC2, 0, 0, 0, 0, 0, 0, 0, 12, 0])
    }

    func testScannerControl() {
        // function_1 im unteren Nibble von Byte 1, function_2 (val >> 4) in Byte 2.
        XCTAssertEqual(Command.scannerControl(0x00), [0xF1, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(Command.scannerControl(0x04), [0xF1, 0x04, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(Command.scannerControl(0x1F), [0xF1, 0x0F, 0x01, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(Command.scannerControl(0x2F), [0xF1, 0x0F, 0x02, 0, 0, 0, 0, 0, 0, 0])
    }

    func testObjectPosition() {
        XCTAssertEqual(Command.objectPosition(.discharge), [0x31, 0x00, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(Command.objectPosition(.feed), [0x31, 0x01, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(Command.objectPosition(.halt), [0x31, 0x04, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    func testSetWindowLengthIsThreeBytesAtOffset6() {
        XCTAssertEqual(Command.setWindow(length: 0x000148), [0x24, 0, 0, 0, 0, 0, 0x00, 0x01, 0x48, 0])
    }

    func testSend() {
        // Datentyp in Byte 2, Länge 3 Byte ab Offset 6.
        XCTAssertEqual(Command.send(dataType: 0x88, length: 0x8A), [0x2A, 0, 0x88, 0, 0, 0, 0x00, 0x00, 0x8A, 0])
    }

    func testModeSelectSetsPageFormatAndLength() {
        XCTAssertEqual(Command.modeSelect(length: 12), [0x15, 0x10, 0, 0, 12, 0])
    }

    func testScanCarriesWindowCount() {
        XCTAssertEqual(Command.scan(windows: 2), [0x1B, 0, 0, 0, 2, 0])
        XCTAssertEqual(Command.scan(windows: 1), [0x1B, 0, 0, 0, 1, 0])
    }

    func testReadFrontAndBack() {
        // Datentyp in Byte 2, Fenster-ID in Byte 5 (0x00 vorn, 0x80 hinten), Länge ab Offset 6.
        XCTAssertEqual(Command.read(dataType: 0x00, length: 0x010000, side: .front),
                       [0x28, 0, 0x00, 0, 0, 0x00, 0x01, 0x00, 0x00, 0])
        XCTAssertEqual(Command.read(dataType: 0x81, length: 8, side: .back),
                       [0x28, 0, 0x81, 0, 0, 0x80, 0x00, 0x00, 0x08, 0])
    }

    func testSendDiagnostic() {
        // Selbsttest-Bit 0, Länge 2 Byte ab Offset 3.
        XCTAssertEqual(Command.sendDiagnostic(length: 16), [0x1D, 0, 0, 0, 16, 0])
        XCTAssertEqual(Command.sendDiagnostic(length: 0x0120), [0x1D, 0, 0, 0x01, 0x20, 0])
    }

    func testInquiryVPD() {
        // EVPD-Bit, Seite 0xF0, 204 Byte (INQUIRY_vpd_len).
        XCTAssertEqual(Command.inquiryVPD(), [0x12, 0x01, 0xF0, 0, 204, 0])
    }

    func testModeSense() {
        XCTAssertEqual(Command.modeSense(page: 0x3C), [0x1A, 0, 0x3C, 0, 0x14, 0])
    }

    func testScannerControlRIC() {
        // RIC-Bit in Byte 1, Fenster-ID in Byte 2, Länge 3 Byte ab Offset 6.
        XCTAssertEqual(Command.scannerControlRIC(length: 0x00FFF0, side: .back),
                       [0xF1, 0x10, 0x80, 0, 0, 0, 0x00, 0xFF, 0xF0, 0])
        XCTAssertEqual(Command.scannerControlRIC(length: 4, side: .front),
                       [0xF1, 0x10, 0x00, 0, 0, 0, 0, 0, 4, 0])
    }
}
