import CoreGraphics
import XCTest
@testable import ScannerKit

final class ReadingDirectionTests: XCTestCase {
    static let lines = ["Kompost Erden Nord GmbH", "Rechnung 4711 vom 23. Oktober", "Summe 1,00 EUR"]

    /// Unabhängig von `quarterTurnsNeeded` geprüft: Liegt jede erkannte Zeile waagerecht nach rechts?
    func assertReadsLeftToRight(_ image: CGImage, _ label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let probe = try XCTUnwrap(ReadingDirection.scaled(image, maxSide: ReadingDirection.probeSide))
        let chars = ReadingDirection.characters(probe)
        XCTAssertGreaterThan(chars[0], 20, "\(label): \(chars)", file: file, line: line)
        XCTAssertEqual(chars[1] + chars[2] + chars[3], 0, "\(label): \(chars)", file: file, line: line)
    }

    func testUprightPageStaysAsItIs() {
        XCTAssertEqual(ReadingDirection.quarterTurnsNeeded(TestPages.textPage(Self.lines)), 0)
    }

    func testEveryTurnedPositionIsDetectedAndUndone() throws {
        let page = TestPages.textPage(Self.lines)
        for turns in 1...3 {
            let turned = try XCTUnwrap(ReadingDirection.rotated(page, quarterTurns: turns))
            XCTAssertEqual(ReadingDirection.quarterTurnsNeeded(turned), (4 - turns) % 4, "gedreht um \(turns) × 90 Grad")
            let fixed = ReadingDirection.upright(turned)
            XCTAssertEqual(fixed.width, page.width, "gedreht um \(turns) × 90 Grad")
            XCTAssertEqual(fixed.height, page.height, "gedreht um \(turns) × 90 Grad")
            try assertReadsLeftToRight(fixed, "gedreht um \(turns) × 90 Grad")
        }
    }

    func testRotationSwapsSidesOnlyForQuarterTurns() throws {
        let page = TestPages.textPage([], widthMM: 80, heightMM: 150, dpi: 100)
        let quarter = try XCTUnwrap(ReadingDirection.rotated(page, quarterTurns: 1))
        XCTAssertEqual([quarter.width, quarter.height], [page.height, page.width])
        let half = try XCTUnwrap(ReadingDirection.rotated(page, quarterTurns: 2))
        XCTAssertEqual([half.width, half.height], [page.width, page.height])
    }

    func testPageWithoutTextIsNotTurned() throws {
        let blank = TestPages.textPage([])
        for turns in 0...3 {
            let turned = try XCTUnwrap(ReadingDirection.rotated(blank, quarterTurns: turns))
            XCTAssertEqual(ReadingDirection.quarterTurnsNeeded(turned), 0)
        }
    }

    func testFewCharactersAreNotEnough() throws {
        // Ein einzelner kurzer Stempel reicht nicht für eine Drehung.
        let stamp = try XCTUnwrap(ReadingDirection.rotated(TestPages.textPage(["OK"]), quarterTurns: 2))
        XCTAssertEqual(ReadingDirection.quarterTurnsNeeded(stamp), 0)
    }

    func testScanJobTurnsEveryPositionBeforeColourAndOneBit() throws {
        // 150 dpi genügen der Erkennung; mit 300 dpi brauchte der Test 20 s.
        let page = TestPages.textPage(Self.lines, dpi: 150, size: 45)
        for turns in [1, 2, 3] {
            let turned = try XCTUnwrap(ReadingDirection.rotated(page, quarterTurns: turns))
            for profile in [ScanProfile.rechnungen, .auto] {
                let prepared = try XCTUnwrap(ScanJob.prepare(turned, profile: profile))
                try assertReadsLeftToRight(prepared.image, "\(profile.id), gedreht um \(turns) × 90 Grad")
            }
        }
    }
}
