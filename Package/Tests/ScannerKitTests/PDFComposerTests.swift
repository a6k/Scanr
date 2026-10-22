import CoreGraphics
import PDFKit
import XCTest
@testable import ScannerKit

/// Die Seiten werden im Test erzeugt: Text "Rechnung 4711" in Helvetica, schwarz auf weiß.
final class PDFComposerTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanr-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func invoice() -> CGImage {
        TestPages.textPage(["Rechnung 4711", "Musterstrasse 12"], size: 100)
    }

    func testOCRFindsKnownText() async throws {
        let lines = try await OCR.lines(in: invoice())
        let text = lines.map(\.text).joined(separator: "\n")
        XCTAssertTrue(text.contains("Rechnung"), text)
        XCTAssertTrue(text.contains("4711"), text)
        for line in lines {
            XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(line.box), "\(line.box)")
        }
    }

    func testPDFHasSearchableTextLayer() async throws {
        let image = invoice()
        let bw = PageProcessor.binarize(image)
        let lines = try await OCR.lines(in: image)
        let url = dir.appendingPathComponent("a.pdf")
        try PDFComposer.write([(TestPages.page(bw, isColor: false), lines)], to: url)
        let doc = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(doc.pageCount, 1)
        let text = doc.string ?? ""
        XCTAssertTrue(text.contains("Rechnung"), text)
        XCTAssertTrue(text.contains("4711"), text)
        // Der Text liegt an der Stelle der Zeile: Suche liefert ein Rechteck auf der Seite.
        let hit = try XCTUnwrap(doc.findString("4711", withOptions: []).first)
        let box = hit.bounds(for: doc.page(at: 0)!)
        XCTAssertGreaterThan(box.width, 10)
        XCTAssertGreaterThan(box.minY, doc.page(at: 0)!.bounds(for: .mediaBox).height / 2)
    }

    func testReceiptPageSizeFollowsPixelsAndDpi() throws {
        let image = TestPages.textPage([], widthMM: 80, heightMM: 176, dpi: 300)
        let url = dir.appendingPathComponent("bon.pdf")
        try PDFComposer.write([(TestPages.page(image, dpi: 300), [])], to: url)
        let box = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(box.width, Double(image.width) / 300 * 72, accuracy: 1)
        XCTAssertEqual(box.height, Double(image.height) / 300 * 72, accuracy: 1)
    }

    func testReceiptAndA4HaveDifferentPageSizes() throws {
        let bon = TestPages.textPage([], widthMM: 80, heightMM: 176, dpi: 300)
        let a4 = TestPages.textPage([], dpi: 300)
        let url = dir.appendingPathComponent("beide.pdf")
        try PDFComposer.write([(TestPages.page(bon), []), (TestPages.page(a4), [])], to: url)
        let doc = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(doc.pageCount, 2)
        let b0 = doc.page(at: 0)!.bounds(for: .mediaBox), b1 = doc.page(at: 1)!.bounds(for: .mediaBox)
        XCTAssertNotEqual(b0.size, b1.size)
        XCTAssertEqual(b1.width, 595, accuracy: 1.5)
    }

    func testPageDpiScalesPageSize() throws {
        let image = TestPages.textPage([], widthMM: 80, heightMM: 80, dpi: 150)
        let url = dir.appendingPathComponent("d.pdf")
        try PDFComposer.write([(TestPages.page(image, dpi: 150), [])], to: url)
        let box = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(box.width, 80 / 25.4 * 72, accuracy: 1)
    }

    func testEmptyPageListThrows() {
        XCTAssertThrowsError(try PDFComposer.write([], to: dir.appendingPathComponent("leer.pdf")))
    }

    func testJPEGWriterWritesReadableFileWithDpi() throws {
        let image = TestPages.colorPage(dpi: 150)
        let url = dir.appendingPathComponent("f.jpg")
        try JPEGWriter.write(TestPages.page(image, dpi: 150, isColor: true), quality: 0.9, to: url)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(src), 1)
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyPixelWidth] as? Int, image.width)
        XCTAssertEqual((props?[kCGImagePropertyDPIWidth] as? Double) ?? 0, 150, accuracy: 0.5)
    }

    func testJPEGQualityChangesSize() throws {
        let page = TestPages.page(TestPages.colorPage(dpi: 150), dpi: 150, isColor: true)
        let lo = dir.appendingPathComponent("lo.jpg"), hi = dir.appendingPathComponent("hi.jpg")
        try JPEGWriter.write(page, quality: 0.3, to: lo)
        try JPEGWriter.write(page, quality: 0.95, to: hi)
        let sLo = try FileManager.default.attributesOfItem(atPath: lo.path)[.size] as! Int
        let sHi = try FileManager.default.attributesOfItem(atPath: hi.path)[.size] as! Int
        XCTAssertLessThan(sLo, sHi)
    }

    /// Größenmessung für den Bericht; die Schwellen sind grobe Schranken, keine Zielwerte.
    func testMeasuredSizes() async throws {
        let text = (1...30).map { "Zeile \($0): Rechnungsposition Nummer \($0 * 17) Betrag \($0 * 3),50 EUR" }
        let bwImage = TestPages.textPage(text, size: 40)
        let bw = PageProcessor.binarize(bwImage)
        let lines = try await OCR.lines(in: bwImage)
        let bwURL = dir.appendingPathComponent("sw.pdf")
        try PDFComposer.write([(TestPages.page(bw, isColor: false), lines)], to: bwURL)
        let colURL = dir.appendingPathComponent("farbe.pdf")
        try PDFComposer.write([(TestPages.page(TestPages.colorPage(), isColor: true), [])], to: colURL, jpegQuality: 0.6)
        let sBW = try FileManager.default.attributesOfItem(atPath: bwURL.path)[.size] as! Int
        let sCol = try FileManager.default.attributesOfItem(atPath: colURL.path)[.size] as! Int
        print("GROESSE sw=\(sBW / 1024) KB (\(lines.count) Zeilen erkannt) farbe=\(sCol / 1024) KB")
        XCTAssertLessThan(sBW, 400 * 1024)
        XCTAssertLessThan(sCol, 4 * 1024 * 1024)
    }
}
