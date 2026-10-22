import XCTest
@testable import ScannerKit

final class HardwareStatusTests: XCTestCase {
    /// 12 Byte, Papier im Einzug (Byte 3 Bit 7 gelöscht), sonst alles aus.
    private func base() -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 12)
        b[3] = 0
        return b
    }

    private func quiet() -> HardwareStatus {
        HardwareStatus(paperInHopper: true, scanButton: false, coverOpen: false,
                       doubleFeed: false, errorCode: 0, sleeping: false)
    }

    func testAllZeroMeansPaperInHopperBecauseBitIsInverted() throws {
        // get_GHS_hopper ist !bit7: gelöschtes Bit heißt Papier da.
        XCTAssertEqual(try HardwareStatus(bytes: base()), quiet())
    }

    func testHopperBitSetMeansNoPaper() throws {
        var b = base(); b[3] = 0x80
        var expected = quiet(); expected.paperInHopper = false
        XCTAssertEqual(try HardwareStatus(bytes: b), expected)
    }

    func testScanButton() throws {
        var b = base(); b[4] = 0x01
        var expected = quiet(); expected.scanButton = true
        XCTAssertEqual(try HardwareStatus(bytes: b), expected)
    }

    func testCoverOpen() throws {
        var b = base(); b[3] = 0x20
        var expected = quiet(); expected.coverOpen = true
        XCTAssertEqual(try HardwareStatus(bytes: b), expected)
    }

    func testDoubleFeed() throws {
        var b = base(); b[6] = 0x01
        var expected = quiet(); expected.doubleFeed = true
        XCTAssertEqual(try HardwareStatus(bytes: b), expected)
    }

    func testErrorCode() throws {
        var b = base(); b[7] = 0x5A
        var expected = quiet(); expected.errorCode = 0x5A
        XCTAssertEqual(try HardwareStatus(bytes: b), expected)
    }

    func testSleeping() throws {
        var b = base(); b[4] = 0x80
        var expected = quiet(); expected.sleeping = true
        XCTAssertEqual(try HardwareStatus(bytes: b), expected)
    }

    func testOtherBitsDoNotLeakIntoFields() throws {
        // Bits, die nicht zu den sechs Feldern gehören (scan_sw_long, send_sw, manual_feed in Byte 4,
        // paper_end und exit in Byte 3, ink_empty in Byte 6).
        var b = base(); b[3] = 0x05; b[4] = 0x26; b[6] = 0xFE
        XCTAssertEqual(try HardwareStatus(bytes: b), quiet())
    }

    func testRejectsTooShortReply() {
        XCTAssertThrowsError(try HardwareStatus(bytes: [UInt8](repeating: 0, count: 7)))
    }

    func testIdleFixtureParses() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ghs-idle", withExtension: "bin", subdirectory: "Fixtures"))
        let bytes = [UInt8](try Data(contentsOf: url))
        _ = try HardwareStatus(bytes: bytes)
    }

    func testHardwareStatusPropagatesBusy() async {
        struct Busy: USBTransport {
            func command(_ cdb: [UInt8], dataOut: [UInt8]?, readLength: Int?, timeout: Duration) async throws -> [UInt8] {
                throw ScannerError.busy
            }
        }
        do {
            _ = try await Busy().hardwareStatus()
            XCTFail("busy erwartet")
        } catch {
            XCTAssertEqual(error as? ScannerError, .busy)
        }
    }

    func testHardwareStatusSendsGetHardwareStatusAndParses() async throws {
        final class Spy: USBTransport, @unchecked Sendable {
            var seen: [UInt8] = []
            var seenRead: Int?
            func command(_ cdb: [UInt8], dataOut: [UInt8]?, readLength: Int?, timeout: Duration) async throws -> [UInt8] {
                seen = cdb; seenRead = readLength
                var b = [UInt8](repeating: 0, count: 12); b[4] = 0x01
                return b
            }
        }
        let spy = Spy()
        let s = try await spy.hardwareStatus()
        XCTAssertEqual(spy.seen, Command.getHardwareStatus())
        XCTAssertEqual(spy.seenRead, 12)
        XCTAssertTrue(s.scanButton)
    }
}
