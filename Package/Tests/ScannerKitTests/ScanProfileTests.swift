import XCTest
@testable import ScannerKit

final class ScanProfileTests: XCTestCase {
    var suite: String!
    var defaults: UserDefaults!

    override func setUp() {
        suite = "scanr-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testStartValues() {
        XCTAssertEqual(ScanProfile.auto.dpi, 300)
        XCTAssertTrue(ScanProfile.auto.duplex)
        XCTAssertTrue(ScanProfile.auto.removeBlankPages)
        XCTAssertEqual(ScanProfile.auto.colorMode, .autoDetect)
        XCTAssertEqual(ScanProfile.auto.format, .pdf)
        XCTAssertEqual(ScanProfile.auto.jpegQuality, 0.6)
        XCTAssertEqual(ScanProfile.foto.dpi, 600)
        XCTAssertEqual(ScanProfile.foto.colorMode, .color)
        XCTAssertEqual(ScanProfile.foto.format, .jpg)
        XCTAssertEqual(ScanProfile.foto.jpegQuality, 0.9)
        XCTAssertTrue(ScanProfile.foto.duplex)
        XCTAssertTrue(ScanProfile.foto.removeBlankPages)
        XCTAssertEqual(ScanProfile.auto.scanSettings, ScanSettings(dpi: 300, duplex: true))
    }

    func testEmptyDefaultsGiveStartProfiles() {
        XCTAssertEqual(ProfileStore(defaults: defaults).load(), [.auto, .foto])
    }

    func testSaveAndReload() {
        var foto = ScanProfile.foto
        foto.dpi = 200
        foto.colorMode = .gray
        let store = ProfileStore(defaults: defaults)
        store.save([.auto, foto])
        let loaded = ProfileStore(defaults: defaults).load()
        XCTAssertEqual(loaded, [.auto, foto])
        XCTAssertEqual(loaded[1].dpi, 200)
        XCTAssertEqual(loaded[1].colorMode, .gray)
    }

    func testBrokenJSONGivesStartProfiles() {
        defaults.set(Data("{kaputt".utf8), forKey: ProfileStore.key)
        XCTAssertEqual(ProfileStore(defaults: defaults).load(), [.auto, .foto])
    }

    func testOutOfRangeDpiFallsBackToStartValue() throws {
        var foto = ScanProfile.foto
        foto.dpi = 1234
        var auto = ScanProfile.auto
        auto.dpi = 75
        let data = try JSONEncoder().encode([auto, foto])
        defaults.set(data, forKey: ProfileStore.key)
        let loaded = ProfileStore(defaults: defaults).load()
        XCTAssertEqual(loaded[0].dpi, 300)
        XCTAssertEqual(loaded[1].dpi, 600)
    }

    func testUnknownProfileWithBadDpiFallsBackTo300() throws {
        var p = ScanProfile.auto
        p.id = "eigenes"
        p.dpi = 999
        let data = try JSONEncoder().encode([p])
        defaults.set(data, forKey: ProfileStore.key)
        XCTAssertEqual(ProfileStore(defaults: defaults).load().first?.dpi, 300)
    }
}
