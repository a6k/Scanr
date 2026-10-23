import CoreGraphics
import XCTest
@testable import ScannerKit

final class ReadingDirectionTests: XCTestCase {
    static let lines = ["Kompost Erden Nord GmbH", "Rechnung 4711 vom 23. Oktober", "Summe 1,00 EUR"]

    func testUprightPageStaysAsItIs() {
        let page = TestPages.textPage(Self.lines)
        XCTAssertFalse(ReadingDirection.isUpsideDown(page))
    }

    func testUpsideDownPageIsDetectedAndTurned() throws {
        let turned = try XCTUnwrap(ReadingDirection.rotated180(TestPages.textPage(Self.lines)))
        XCTAssertTrue(ReadingDirection.isUpsideDown(turned))
        let fixed = ReadingDirection.upright(turned)
        XCTAssertEqual(fixed.width, turned.width)
        XCTAssertEqual(fixed.height, turned.height)
        XCTAssertFalse(ReadingDirection.isUpsideDown(fixed))
    }

    func testPageWithoutTextIsNotTurned() throws {
        let blank = TestPages.textPage([])
        XCTAssertFalse(ReadingDirection.isUpsideDown(blank))
        XCTAssertFalse(ReadingDirection.isUpsideDown(try XCTUnwrap(ReadingDirection.rotated180(blank))))
    }

    func testFewCharactersAreNotEnough() throws {
        // Ein einzelner kurzer Stempel reicht nicht für eine Drehung.
        let stamp = try XCTUnwrap(ReadingDirection.rotated180(TestPages.textPage(["OK"])))
        XCTAssertFalse(ReadingDirection.isUpsideDown(stamp))
    }

    func testScanJobTurnsAnUpsideDownSheetBeforeColourAndOneBit() throws {
        let turned = try XCTUnwrap(ReadingDirection.rotated180(TestPages.textPage(Self.lines)))
        for profile in [ScanProfile.rechnungen, .auto] {
            let page = try XCTUnwrap(ScanJob.prepare(turned, profile: profile))
            // Unabhängig von isUpsideDown geprüft: alle erkannten Zeilen liegen aufrecht.
            let probe = try XCTUnwrap(ReadingDirection.scaled(page.image, maxSide: ReadingDirection.probeSide))
            let (normal, reversed) = ReadingDirection.characters(probe)
            XCTAssertGreaterThan(normal, 20, profile.id)
            XCTAssertEqual(reversed, 0, profile.id)
        }
    }
}
