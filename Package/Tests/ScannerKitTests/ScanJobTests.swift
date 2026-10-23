import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import ScannerKit

final class ScanJobTests: XCTestCase {
    var dir: URL!
    let dpi = 150

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanr-job-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Hilfen

    private var caps: ScannerCapabilities {
        var c = ScannerCapabilities.iX500
        c.colorInterlace = .rgb
        return c
    }

    /// Die Seite so, wie das Gerät sie schickt: RGB, invertiert.
    private func deviceBytes(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        rgba.withUnsafeMutableBytes { raw in
            let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var out = [UInt8]()
        out.reserveCapacity(w * h * 3)
        for i in 0..<(w * h) {
            out.append(rgba[i * 4] ^ 0xFF)
            out.append(rgba[i * 4 + 1] ^ 0xFF)
            out.append(rgba[i * 4 + 2] ^ 0xFF)
        }
        return out
    }

    private func sheet(front: CGImage, back: CGImage) -> FakeTransport.Sheet {
        FakeTransport.Sheet(width: front.width, front: deviceBytes(front), back: deviceBytes(back))
    }

    private func text(_ lines: [String]) -> CGImage {
        TestPages.textPage(lines, dpi: dpi, size: 50)
    }

    private lazy var blank = TestPages.textPage([], dpi: dpi)

    private func fake(_ sheets: [FakeTransport.Sheet]) -> FakeTransport {
        let f = FakeTransport()
        f.sheets = sheets
        f.windowLines = 4000
        return f
    }

    private func profile(_ base: ScanProfile, _ change: (inout ScanProfile) -> Void = { _ in }) -> ScanProfile {
        var p = base
        p.dpi = dpi
        change(&p)
        return p
    }

    private func job(_ f: FakeTransport, _ p: ScanProfile, pattern: String = "scan {nr}") -> ScanJob {
        ScanJob(session: ScanSession(transport: f, capabilities: caps, emptyReadPause: .zero),
                profile: p, namer: FileNamer(pattern: pattern), outputDir: dir)
    }

    private func names() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    // MARK: Durchläufe

    func testAutoProfileWritesOnePDFWithoutBlankBack() async throws {
        let f = fake([
            sheet(front: text(["Rechnung 4711"]), back: blank),
            sheet(front: text(["Lieferschein 99"]), back: text(["Rueckseite 12"])),
        ])
        let result = await job(f, profile(.auto)).run { _ in }
        XCTAssertNil(result.error)
        XCTAssertEqual(result.pages, 3)
        XCTAssertEqual(result.sheets, 2)
        XCTAssertEqual(result.files.map(\.lastPathComponent), ["scan 01.pdf"])
        XCTAssertEqual(names(), ["scan 01.pdf"], "keine Temp-Datei übrig")
        let doc = try XCTUnwrap(PDFDocument(url: result.files[0]))
        XCTAssertEqual(doc.pageCount, 3)
        let found = doc.findString("Rechnung", withOptions: [])
        XCTAssertFalse(found.isEmpty, "Textebene: \(doc.string ?? "")")
        XCTAssertFalse(doc.findString("Lieferschein", withOptions: []).isEmpty)
    }

    func testFotoProfileWritesOneJPGAndDropsBlankBack() async throws {
        let f = fake([sheet(front: TestPages.colorPage(dpi: dpi), back: blank)])
        let result = await job(f, profile(.foto)).run { _ in }
        XCTAssertNil(result.error)
        XCTAssertEqual(result.pages, 1)
        XCTAssertEqual(names(), ["scan 01.jpg"])
        XCTAssertEqual(result.files.map(\.lastPathComponent), ["scan 01.jpg"])
    }

    func testDoubleFeedAfterFirstSheetKeepsFirstSheet() async throws {
        let f = fake([sheet(front: text(["Blatt eins"]), back: blank), sheet(front: text(["Blatt zwei"]), back: blank)])
        f.objectPositionError = [2: .doubleFeed]
        let result = await job(f, profile(.auto)).run { _ in }
        XCTAssertEqual(result.error, .scanner(.doubleFeed))
        XCTAssertFalse(result.cancelled)
        XCTAssertEqual(result.pages, 1)
        XCTAssertEqual(result.sheets, 1)
        XCTAssertEqual(names(), ["scan 01.pdf"])
        XCTAssertEqual(PDFDocument(url: result.files[0])?.pageCount, 1)
    }

    func testPaperJamAfterFirstSheetKeepsFirstSheet() async throws {
        let f = fake([sheet(front: text(["Blatt eins"]), back: blank), sheet(front: text(["Blatt zwei"]), back: blank)])
        f.objectPositionError = [2: .paperJam]
        let result = await job(f, profile(.auto)).run { _ in }
        XCTAssertEqual(result.error, .scanner(.paperJam))
        XCTAssertEqual(result.pages, 1)
        XCTAssertEqual(names(), ["scan 01.pdf"])
        XCTAssertEqual(PDFDocument(url: result.files[0])?.pageCount, 1)
    }

    func testFailedTextRecognitionKeepsThePagesWithoutTextLayer() async throws {
        struct VisionFailed: Error {}
        let f = fake([sheet(front: text(["Rechnung 4711"]), back: text(["Rueckseite 12"]))])
        var j = job(f, profile(.auto))
        j.recognize = { _ in throw VisionFailed() }
        let result = await j.run { _ in }
        XCTAssertNil(result.error)
        XCTAssertEqual(result.pages, 2)
        XCTAssertEqual(names(), ["scan 01.pdf"])
        XCTAssertEqual(PDFDocument(url: result.files[0])?.pageCount, 2)
    }

    func testWriteFailureIsNotHiddenByEarlierScannerError() async {
        let f = fake([sheet(front: text(["Blatt eins"]), back: blank), sheet(front: text(["Blatt zwei"]), back: blank)])
        f.objectPositionError = [2: .doubleFeed]
        var j = job(f, profile(.auto))
        j.beforeWrite = { url in FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)) }
        let result = await j.run { _ in }
        XCTAssertEqual(result.error, .output(.destinationExists))
        XCTAssertEqual(result.scannerError, .doubleFeed)
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertEqual(result.pages, 0)
    }

    func testEmptyHopperReturnsNoDocumentsAndWritesNothing() async {
        let f = fake([])
        f.hopperEmpty = true
        let result = await job(f, profile(.auto)).run { _ in }
        XCTAssertEqual(result.error, .scanner(.noDocuments))
        XCTAssertEqual(result.pages, 0)
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertEqual(names(), [])
    }

    func testOnlyBlankPagesWriteNoFile() async {
        let f = fake([sheet(front: blank, back: blank)])
        let result = await job(f, profile(.auto)).run { _ in }
        XCTAssertNil(result.error)
        XCTAssertEqual(result.pages, 0)
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertEqual(names(), [])
    }

    func testKeepsBlankPagesWhenRemovalIsOff() async throws {
        let f = fake([sheet(front: text(["Seite"]), back: blank)])
        let result = await job(f, profile(.auto) { $0.removeBlankPages = false }).run { _ in }
        XCTAssertEqual(result.pages, 2)
        XCTAssertEqual(PDFDocument(url: result.files[0])?.pageCount, 2)
    }

    func testJPGWritesOneFilePerPageWithConsecutiveNumbers() async throws {
        let f = fake([sheet(front: text(["Eins"]), back: text(["Zwei"]))])
        let result = await job(f, profile(.auto) { $0.format = .jpg }).run { _ in }
        XCTAssertNil(result.error)
        XCTAssertEqual(result.pages, 2)
        XCTAssertEqual(names(), ["scan 01.jpg", "scan 02.jpg"])
        XCTAssertEqual(result.files.map(\.lastPathComponent), ["scan 01.jpg", "scan 02.jpg"])
    }

    func testProgressCountsKeptPagesThenReportsTextRecognition() async {
        let f = fake([sheet(front: text(["Eins"]), back: blank), sheet(front: text(["Zwei"]), back: blank)])
        let seen = Locked<[ScanProgress]>([])
        _ = await job(f, profile(.auto)).run { p in seen.withLock { $0.append(p) } }
        XCTAssertEqual(seen.value, [.scanned(pages: 1), .scanned(pages: 2),
                                    .recognizing(page: 1, of: 2), .recognizing(page: 2, of: 2)])
    }

    func testJPGHasNoTextRecognitionPhase() async {
        let f = fake([sheet(front: text(["Eins"]), back: blank)])
        let seen = Locked<[ScanProgress]>([])
        _ = await job(f, profile(.auto) { $0.format = .jpg }).run { p in seen.withLock { $0.append(p) } }
        XCTAssertEqual(seen.value, [.scanned(pages: 1)])
    }

    // MARK: Blätter

    func testDuplexSheetWithRemovedBlankBackCountsAsComplete() async throws {
        let f = fake([
            sheet(front: text(["Blatt eins"]), back: blank),
            sheet(front: text(["Blatt zwei"]), back: text(["Rueckseite zwei"])),
            sheet(front: text(["Blatt drei"]), back: blank),
        ])
        f.objectPositionError = [3: .doubleFeed]
        let result = await job(f, profile(.auto)).run { _ in }
        XCTAssertEqual(result.error, .scanner(.doubleFeed))
        XCTAssertEqual(result.sheets, 2)
        XCTAssertEqual(result.pages, 3)
        XCTAssertEqual(PDFDocument(url: try XCTUnwrap(result.files.first))?.pageCount, 3)
    }

    func testSheetWithOnlyBlankPagesCounts() async {
        let f = fake([sheet(front: blank, back: blank), sheet(front: blank, back: blank)])
        f.objectPositionError = [2: .paperJam]
        let result = await job(f, profile(.auto)).run { _ in }
        XCTAssertEqual(result.error, .scanner(.paperJam))
        XCTAssertEqual(result.sheets, 1)
        XCTAssertEqual(result.pages, 0)
        XCTAssertTrue(result.files.isEmpty)
    }

    func testDoubleFeedOnFirstSheetHasNoCompleteSheet() async {
        let f = fake([sheet(front: text(["Eins"]), back: blank)])
        f.objectPositionError = [1: .doubleFeed]
        let result = await job(f, profile(.auto)).run { _ in }
        XCTAssertEqual(result.error, .scanner(.doubleFeed))
        XCTAssertEqual(result.sheets, 0)
        XCTAssertTrue(result.files.isEmpty)
    }

    // MARK: Farbmodus

    func testColorModes() throws {
        let textPage = text(["Schwarz auf Weiss"])
        let colorPage = TestPages.colorPage(dpi: dpi)

        func prepared(_ mode: ColorMode, _ image: CGImage) throws -> ProcessedPage {
            try XCTUnwrap(ScanJob.prepare(image, profile: profile(.auto) { $0.colorMode = mode }))
        }
        // Auto: Text wird 1 Bit, Farbe bleibt Farbe.
        var p = try prepared(.autoDetect, textPage)
        XCTAssertEqual(p.image.bitsPerComponent, 1)
        XCTAssertFalse(p.isColor)
        p = try prepared(.autoDetect, colorPage)
        XCTAssertTrue(p.isColor)
        XCTAssertEqual(p.image.colorSpace?.model, .rgb)
        // Schwarzweiß: auch die Farbseite wird 1 Bit.
        p = try prepared(.blackWhite, colorPage)
        XCTAssertEqual(p.image.bitsPerComponent, 1)
        XCTAssertFalse(p.isColor)
        // Grau: 8 Bit, ein Kanal, für beide.
        for image in [textPage, colorPage] {
            p = try prepared(.gray, image)
            XCTAssertEqual(p.image.bitsPerComponent, 8)
            XCTAssertEqual(p.image.bitsPerPixel, 8)
            XCTAssertEqual(p.image.colorSpace?.model, .monochrome)
            XCTAssertFalse(p.isColor)
        }
        // Farbe: bleibt Farbe, auch der Text.
        p = try prepared(.color, textPage)
        XCTAssertEqual(p.image.colorSpace?.model, .rgb)
        XCTAssertTrue(p.isColor)
        p = try prepared(.color, colorPage)
        XCTAssertTrue(p.isColor)
    }

    func testPrepareDropsBlankOnlyWhenAsked() {
        XCTAssertNil(ScanJob.prepare(blank, profile: profile(.auto)))
        XCTAssertNotNil(ScanJob.prepare(blank, profile: profile(.auto) { $0.removeBlankPages = false }))
    }

    // MARK: Dateinamen

    func testNameCollisionBetweenAskingAndWritingRetriesWithNewName() async throws {
        let f = fake([sheet(front: text(["Eins"]), back: blank)])
        let taken = Locked(0)
        var j = job(f, profile(.auto))
        // Zwischen Namensfrage und Schreiben legt jemand genau diese Datei an (erste zwei Versuche).
        j.beforeWrite = { url in
            let n = taken.withLock { v -> Int in v += 1; return v }
            if n <= 2 { FileManager.default.createFile(atPath: url.path, contents: Data("fremd".utf8)) }
        }
        let result = await j.run { _ in }
        XCTAssertNil(result.error)
        XCTAssertEqual(result.files.map(\.lastPathComponent), ["scan 03.pdf"])
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("scan 01.pdf"), encoding: .utf8), "fremd")
        XCTAssertEqual(names(), ["scan 01.pdf", "scan 02.pdf", "scan 03.pdf"])
    }

    func testNameCollisionGivesUpAfterFiveTries() async {
        let f = fake([sheet(front: text(["Eins"]), back: blank)])
        var j = job(f, profile(.auto))
        j.beforeWrite = { url in FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)) }
        let result = await j.run { _ in }
        XCTAssertEqual(result.error, .output(.destinationExists))
        XCTAssertNil(result.scannerError)
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertEqual(names().count, 5, "fünf fremde Dateien, nichts von uns")
    }

    // MARK: Abbruch

    private func positions(_ f: FakeTransport) -> Int {
        f.calls.map(FakeTransport.label).filter { $0.hasPrefix("OBJECT POSITION") }.count
    }

    /// Startet den Durchlauf in einem Task, den `cancelWhen` aus dem Fortschritt heraus abbricht.
    private func runCancelling(_ j: ScanJob, when cancelWhen: @escaping @Sendable (ScanProgress) -> Bool) async -> ScanResult {
        let box = Locked<Task<ScanResult, Never>?>(nil)
        let task = Task { await j.run { p in if cancelWhen(p) { box.withLock { $0 }?.cancel() } } }
        box.withLock { $0 = task }
        return await task.value
    }

    func testCancelAfterFirstPageStopsScannerAndSavesThePDF() async throws {
        let sheetCount = 6
        let f = fake((0..<sheetCount).map { _ in sheet(front: text(["Seite"]), back: blank) })
        f.readDelay = .milliseconds(10)
        let result = await runCancelling(job(f, profile(.auto))) { _ in true }
        XCTAssertTrue(result.cancelled)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.files.map(\.lastPathComponent), ["scan 01.pdf"])
        XCTAssertEqual(result.pages, 1)
        XCTAssertEqual(names(), ["scan 01.pdf"])
        let doc = try XCTUnwrap(PDFDocument(url: result.files[0]))
        XCTAssertEqual(doc.pageCount, 1)
        XCTAssertTrue((doc.string ?? "").isEmpty, "ohne Texterkennung: \(doc.string ?? "")")
        // Nur Abbruch erklärt das: nicht alle Blätter wurden eingezogen (sonst sheetCount + 1).
        XCTAssertLessThan(positions(f), sheetCount)
        XCTAssertEqual(f.calls.map(FakeTransport.label).last, "SCANNER CONTROL 04")
    }

    func testRunReturnsOnlyAfterTheScannerWasStopped() async {
        let f = fake((0..<6).map { _ in sheet(front: text(["Seite"]), back: blank) })
        f.readDelay = .milliseconds(10)
        f.cancelDelay = .milliseconds(200)
        let result = await runCancelling(job(f, profile(.auto) { $0.format = .jpg })) { _ in true }
        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(f.calls.map(FakeTransport.label).last, "SCANNER CONTROL 04")
    }

    func testCancelBeforeAnyPageWritesNothing() async {
        let f = fake([sheet(front: blank, back: blank), sheet(front: text(["Seite"]), back: blank)])
        f.readDelay = .milliseconds(10)
        let j = job(f, profile(.auto))
        let task = Task { await j.run { _ in } }
        task.cancel()
        let result = await task.value
        XCTAssertTrue(result.cancelled)
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertEqual(result.pages, 0)
        XCTAssertEqual(names(), [])
    }

    func testCancelDuringTextRecognitionKeepsTextOfFinishedPages() async throws {
        let f = fake([sheet(front: text(["Rechnung 4711"]), back: blank),
                      sheet(front: text(["Lieferschein 99"]), back: blank)])
        let result = await runCancelling(job(f, profile(.auto))) { $0 == .recognizing(page: 2, of: 2) }
        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.pages, 2)
        XCTAssertEqual(result.sheets, 2)
        let doc = try XCTUnwrap(PDFDocument(url: try XCTUnwrap(result.files.first)))
        XCTAssertEqual(doc.pageCount, 2)
        XCTAssertFalse(doc.findString("Rechnung", withOptions: []).isEmpty, "Seite 1 behält ihren Text")
        XCTAssertTrue((doc.page(at: 1)?.string ?? "").isEmpty, "Seite 2 ohne Texterkennung")
    }

    func testCancelKeepsJPGsAlreadyWritten() async throws {
        let sheetCount = 6
        let f = fake((0..<sheetCount).map { _ in sheet(front: text(["Seite"]), back: blank) })
        f.readDelay = .milliseconds(10)
        let result = await runCancelling(job(f, profile(.auto) { $0.format = .jpg })) { _ in true }
        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.files.map(\.lastPathComponent), ["scan 01.jpg"])
        XCTAssertEqual(result.pages, 1)
        XCTAssertEqual(names(), ["scan 01.jpg"], "fertige Datei bleibt")
        XCTAssertLessThan(positions(f), sheetCount)
    }

    // MARK: Speicher

    func testCompactKeepsColorAndGrayAsJPEGBytesAndLeavesOneBitAlone() throws {
        let color = ScanJob.prepare(TestPages.colorPage(dpi: dpi), profile: profile(.auto))!
        let c = ScanJob.compact(color, quality: 0.4)
        XCTAssertNotNil(c.jpegData)
        XCTAssertTrue(c.isColor)
        let gray = ScanJob.prepare(TestPages.colorPage(dpi: dpi), profile: profile(.auto) { $0.colorMode = .gray })!
        XCTAssertNotNil(ScanJob.compact(gray, quality: 0.4).jpegData)
        let bw = ScanJob.prepare(text(["Text"]), profile: profile(.auto))!
        XCTAssertNil(ScanJob.compact(bw, quality: 0.4).jpegData)
        // Das PDF übernimmt die Bytes unverändert.
        let url = dir.appendingPathComponent("c.pdf")
        try PDFComposer.write([(c, [])], to: url, jpegQuality: 0.4)
        let data = try Data(contentsOf: url)
        XCTAssertNotNil(data.range(of: try XCTUnwrap(c.jpegData)), "JPEG-Bytes liegen im PDF")
    }

    func testColorPDFHasOneEmbeddedPagePerScannedPage() async throws {
        let f = fake([sheet(front: TestPages.colorPage(dpi: dpi), back: blank)])
        let result = await job(f, profile(.auto)).run { _ in }
        XCTAssertNil(result.error)
        XCTAssertEqual(PDFDocument(url: result.files[0])?.pageCount, 1)
    }
}

/// Kleiner Behälter für Werte, die aus @Sendable-Rückrufen geändert werden.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func withLock<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&stored) } }
}
