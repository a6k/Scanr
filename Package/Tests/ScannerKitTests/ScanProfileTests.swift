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
        XCTAssertEqual(ScanProfile.auto.jpegQuality, 0.4)
        XCTAssertEqual(ScanProfile.foto.dpi, 600)
        XCTAssertEqual(ScanProfile.foto.colorMode, .color)
        XCTAssertEqual(ScanProfile.foto.format, .jpg)
        XCTAssertEqual(ScanProfile.foto.jpegQuality, 0.9)
        XCTAssertTrue(ScanProfile.foto.duplex)
        XCTAssertTrue(ScanProfile.foto.removeBlankPages)
        XCTAssertEqual(ScanProfile.auto.scanSettings, ScanSettings(dpi: 300, duplex: true, overscan: true))
        let r = ScanProfile.rechnungen
        XCTAssertEqual(r.id, "rechnungen")
        XCTAssertEqual(r.name, "Rechnungen")
        XCTAssertEqual(r.dpi, 300)
        XCTAssertEqual(r.colorMode, .blackWhite)
        XCTAssertEqual(r.format, .pdf)
        XCTAssertTrue(r.duplex)
        XCTAssertTrue(r.removeBlankPages)
        XCTAssertEqual(r.jpegQuality, 0.4)
    }

    func testEmptyDefaultsGiveStartProfiles() {
        XCTAssertEqual(ProfileStore(defaults: defaults).load(), [.rechnungen, .auto, .foto])
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
        XCTAssertEqual(ProfileStore(defaults: defaults).load(), [.rechnungen, .auto, .foto])
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

    func testBadEntryDoesNotDropGoodOnes() throws {
        var custom = ScanProfile.auto
        custom.id = "eigenes"
        custom.name = "Eigenes"
        custom.dpi = 200
        let good = try JSONSerialization.jsonObject(with: JSONEncoder().encode(custom))
        var bad = try XCTUnwrap(good as? [String: Any])
        bad["colorMode"] = "unbekannt"
        bad["id"] = "kaputt"
        let data = try JSONSerialization.data(withJSONObject: [good, bad])
        defaults.set(data, forKey: ProfileStore.key)
        XCTAssertEqual(ProfileStore(defaults: defaults).load(), [custom])
    }

    func testNothingDecodableGivesStartProfiles() throws {
        defaults.set(try JSONSerialization.data(withJSONObject: [["x": 1]]), forKey: ProfileStore.key)
        XCTAssertEqual(ProfileStore(defaults: defaults).load(), [.rechnungen, .auto, .foto])
    }

    func testJpegQualityIsClampedOnDecode() throws {
        var p = ScanProfile.foto
        p.jpegQuality = 7
        let data = try JSONEncoder().encode([p])
        defaults.set(data, forKey: ProfileStore.key)
        XCTAssertEqual(ProfileStore(defaults: defaults).load().first?.jpegQuality, 1)
    }

    func testNaNQualityFallsBackToStartValue() throws {
        var p = ScanProfile.foto
        p.jpegQuality = .nan
        let enc = JSONEncoder()
        enc.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        // Der Store nutzt Standard-Dekodierung; NaN erreicht ihn nur über eigene Dekodierung.
        let dec = JSONDecoder()
        dec.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let back = try dec.decode(ScanProfile.self, from: enc.encode(p))
        XCTAssertEqual(back.jpegQuality, 0.9)
    }

    func testActiveProfileDefaultsToRechnungenAndPersists() {
        let defaults = UserDefaults(suiteName: "scanr-active-\(UUID().uuidString)")!
        let store = ProfileStore(defaults: defaults)
        XCTAssertEqual(store.activeProfileID, ScanProfile.rechnungen.id)
        store.activeProfileID = "foto"
        XCTAssertEqual(ProfileStore(defaults: defaults).activeProfileID, "foto")
    }
}
