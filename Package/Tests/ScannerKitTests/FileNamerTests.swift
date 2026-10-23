import XCTest
@testable import ScannerKit

final class FileNamerTests: XCTestCase {
    var dir: URL!
    var calendar: Calendar!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanr-namer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar = cal
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9, _ min: Int = 5) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func touch(_ name: String) throws {
        try Data().write(to: dir.appendingPathComponent(name))
    }

    func namer(_ pattern: String = "{datum} scan {nr}") -> FileNamer {
        FileNamer(pattern: pattern, timeZone: calendar.timeZone)
    }

    func testEmptyFolderStartsAtOne() {
        let url = namer().nextURL(in: dir, date: date(2026, 10, 22), profile: .auto, ext: "pdf")
        XCTAssertEqual(url.lastPathComponent, "2026-10-22 scan 01.pdf")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, dir.standardizedFileURL)
    }

    func testTakesHighestPlusOneAndDoesNotFillGaps() throws {
        try touch("2026-10-22 scan 01.pdf")
        try touch("2026-10-22 scan 03.pdf")
        let url = namer().nextURL(in: dir, date: date(2026, 10, 22), profile: .auto, ext: "pdf")
        XCTAssertEqual(url.lastPathComponent, "2026-10-22 scan 04.pdf")
    }

    func testPreviousDayDoesNotCount() throws {
        try touch("2026-10-21 scan 07.pdf")
        let url = namer().nextURL(in: dir, date: date(2026, 10, 22), profile: .auto, ext: "pdf")
        XCTAssertEqual(url.lastPathComponent, "2026-10-22 scan 01.pdf")
    }

    func testPdfAndJpgShareOneCounter() throws {
        try touch("2026-10-22 scan 02.jpg")
        let url = namer().nextURL(in: dir, date: date(2026, 10, 22), profile: .foto, ext: "pdf")
        XCTAssertEqual(url.lastPathComponent, "2026-10-22 scan 03.pdf")
    }

    func testUnrelatedFilesAreIgnored() throws {
        try touch("2026-10-22 scan 09 Kopie.pdf")
        try touch("2026-10-22 scan.pdf")
        try touch("x2026-10-22 scan 08.pdf")
        try touch("2026-10-22 scan 05.pdf")
        let url = namer().nextURL(in: dir, date: date(2026, 10, 22), profile: .auto, ext: "pdf")
        XCTAssertEqual(url.lastPathComponent, "2026-10-22 scan 06.pdf")
    }

    func testThreeDigitsAboveNinetyNine() throws {
        try touch("2026-10-22 scan 99.pdf")
        let url = namer().nextURL(in: dir, date: date(2026, 10, 22), profile: .auto, ext: "pdf")
        XCTAssertEqual(url.lastPathComponent, "2026-10-22 scan 100.pdf")
        try touch("2026-10-22 scan 100.pdf")
        let next = namer().nextURL(in: dir, date: date(2026, 10, 22), profile: .auto, ext: "jpg")
        XCTAssertEqual(next.lastPathComponent, "2026-10-22 scan 101.jpg")
    }

    func testTimePlaceholder() {
        let url = namer("{datum} {zeit} {nr}").nextURL(
            in: dir, date: date(2026, 10, 22, 14, 7), profile: .auto, ext: "pdf")
        XCTAssertEqual(url.lastPathComponent, "2026-10-22 14-07 01.pdf")
    }

    func testCounterIgnoresTimeOfExistingFiles() throws {
        try touch("2026-10-22 14-07 01.pdf")
        let url = namer("{datum} {zeit} {nr}").nextURL(
            in: dir, date: date(2026, 10, 22, 15, 30), profile: .auto, ext: "pdf")
        XCTAssertEqual(url.lastPathComponent, "2026-10-22 15-30 02.pdf")
    }

    func testProfilePlaceholder() {
        let n = namer("{profil} {datum} {nr}")
        XCTAssertEqual(n.nextURL(in: dir, date: date(2026, 10, 22), profile: .auto, ext: "pdf").lastPathComponent,
                       "Auto 2026-10-22 01.pdf")
        XCTAssertEqual(n.nextURL(in: dir, date: date(2026, 10, 22), profile: .foto, ext: "jpg").lastPathComponent,
                       "Foto 2026-10-22 01.jpg")
    }

    func testUnknownPlaceholderStaysLiteral() {
        let url = namer("{ort} {nr}").nextURL(in: dir, date: date(2026, 10, 22), profile: .auto, ext: "pdf")
        XCTAssertEqual(url.lastPathComponent, "{ort} 01.pdf")
    }

    func testIllegalCharactersAreReplaced() {
        var p = ScanProfile.auto
        p.name = "A/B:C"
        let url = namer("{profil} {nr}").nextURL(in: dir, date: date(2026, 10, 22), profile: p, ext: "pdf")
        XCTAssertEqual(url.lastPathComponent, "A-B-C 01.pdf")
        let url2 = namer("a/b: {nr}").nextURL(in: dir, date: date(2026, 10, 22), profile: .auto, ext: "pdf")
        XCTAssertEqual(url2.lastPathComponent, "a-b- 01.pdf")
    }

    func testProfileNameWithRegexCharactersCountsExistingFiles() throws {
        var p = ScanProfile.auto
        p.name = "A.(1)"
        try touch("A.(1) 04.pdf")
        let url = namer("{profil} {nr}").nextURL(in: dir, date: date(2026, 10, 22), profile: p, ext: "pdf")
        XCTAssertEqual(url.lastPathComponent, "A.(1) 05.pdf")
    }

    func testDecomposedUmlautsInFolderStillCount() throws {
        // Ein Netzlaufwerk liefert „ü“ als u plus Trema (NFD), der Profilname ist zusammengesetzt.
        var p = ScanProfile.auto
        p.name = "B\u{00FC}ro"
        try touch("Bu\u{0308}ro 03.pdf")
        let url = namer("{profil} {nr}").nextURL(in: dir, date: date(2026, 10, 22), profile: p, ext: "pdf")
        XCTAssertEqual(url.lastPathComponent, "B\u{00FC}ro 04.pdf")
    }

    func testPatternWithoutNumberGetsOneAppended() throws {
        let url = namer("{datum} Scan").nextURL(in: dir, date: date(2026, 10, 22), profile: .auto, ext: "pdf")
        XCTAssertEqual(url.lastPathComponent, "2026-10-22 Scan 01.pdf")
    }

    func testExistingNamesMatchCaseInsensitively() throws {
        try touch("2026-10-22 SCAN 05.PDF")
        let url = namer().nextURL(in: dir, date: date(2026, 10, 22), profile: .auto, ext: "pdf")
        XCTAssertEqual(url.lastPathComponent, "2026-10-22 scan 06.pdf")
    }

    func testDateInForeignTimeZoneHasGregorianYear() {
        // Prüft die Zeitzone. Ob der Namer auch bei buddhistischem Systemkalender gregorianisch
        // bleibt (sonst Jahr 2569), lässt sich hier nicht nachstellen: der Systemkalender ist
        // nicht umschaltbar. Die Zusage steht in `FileNamer.calendar`.
        let url = FileNamer(timeZone: TimeZone(identifier: "Asia/Bangkok")!)
            .nextURL(in: dir, date: Date(timeIntervalSince1970: 1_792_000_000), profile: .auto, ext: "pdf")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("2026-"), url.lastPathComponent)
    }

    // MARK: iCloud

    func testEvictedICloudPlaceholderCounts() throws {
        // Ausgelagerte Datei auf einem iCloud-Schreibtisch: nur ein versteckter Platzhalter liegt da.
        try touch(".2026-10-22 scan 04.pdf.icloud")
        try touch("2026-10-22 scan 02.pdf")
        let url = namer().nextURL(in: dir, date: date(2026, 10, 22), profile: .auto, ext: "pdf")
        XCTAssertEqual(url.lastPathComponent, "2026-10-22 scan 05.pdf")
    }

    func testOnlyRealPlaceholdersCount() throws {
        try touch(".2026-10-22 scan 07.pdf")
        try touch("2026-10-22 scan 08.pdf.icloud")
        let url = namer().nextURL(in: dir, date: date(2026, 10, 22), profile: .auto, ext: "pdf")
        XCTAssertEqual(url.lastPathComponent, "2026-10-22 scan 01.pdf")
    }
}

final class OutputFileTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanr-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func names() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    func testICloudPlaceholderCountsAsExisting() throws {
        try Data().write(to: dir.appendingPathComponent(".scan 01.pdf.icloud"))
        XCTAssertThrowsError(try OutputFile.writeAtomically(to: dir.appendingPathComponent("scan 01.pdf")) { url in
            try Data("neu".utf8).write(to: url)
        }) { XCTAssertEqual($0 as? OutputError, .destinationExists) }
        XCTAssertEqual(names(), [".scan 01.pdf.icloud"])
    }

    func testTempNameCarriesCreationTime() {
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        let name = OutputFile.tempURL(in: dir, now: now).lastPathComponent
        XCTAssertTrue(name.hasPrefix(".scanr-1792000000-"), name)
        XCTAssertTrue(name.hasSuffix(".tmp"), name)
        XCTAssertEqual(OutputFile.tempCreation(name), now)
    }

    func testRemovesOnlyTempFilesOlderThanOneHour() throws {
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        let old = OutputFile.tempURL(in: dir, now: now.addingTimeInterval(-3601))
        let fresh = OutputFile.tempURL(in: dir, now: now.addingTimeInterval(-60))
        for url in [old, fresh] { try Data("x".utf8).write(to: url) }
        let foreign = [".scanr-abc.tmp", "scan 01.pdf", ".scanr-123-x.pdf"]
        for name in foreign { try Data().write(to: dir.appendingPathComponent(name)) }

        let removed = OutputFile.removeStaleTemps(in: dir, now: now)

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(names(), ([fresh.lastPathComponent] + foreign).sorted())
    }

    func testRemovingStaleTempsInMissingFolderDoesNothing() {
        XCTAssertEqual(OutputFile.removeStaleTemps(in: dir.appendingPathComponent("fehlt")), 0)
    }
}
