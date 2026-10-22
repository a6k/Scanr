import CoreGraphics
import XCTest
@testable import ScannerKit

/// Prüft die Bildaufbereitung an erzeugten Seiten. Echte Scans liegen nicht im Repo
/// (personenbezogene Daten); die Farben sind an Messwerten des iX500 ausgerichtet:
/// Hintergrund hellgrau mit Blaustich (RGB 227/230/229 bis 239/240/240, quer zur
/// Einzugsrichtung ein flacher Verlauf), Papier weiß (RGB 245 bis 253).
final class PageProcessorTests: XCTestCase {
    // MARK: Hilfen zum Erzeugen von Testseiten

    /// Deterministisches Rauschen, damit die Tests reproduzierbar bleiben.
    struct Noise {
        var state: UInt64 = 0x9E3779B97F4A7C15
        mutating func next() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % 5) - 2   // -2 ... 2
        }
    }

    enum Ink {
        case black
        case red
        case grey
        case faint   // verblasster Thermodruck, Helligkeit etwa 178
        var rgb: (CGFloat, CGFloat, CGFloat) {
            switch self {
            case .black: (0.05, 0.05, 0.05)
            case .red: (0.85, 0.1, 0.1)
            case .grey: (0.45, 0.45, 0.45)
            case .faint: (0.70, 0.70, 0.70)
            }
        }
    }

    struct Block {
        /// In Papier-Millimetern, Ursprung oben links.
        var x: Double, y: Double, w: Double, h: Double
        var ink: Ink = .black
    }

    /// Papier auf hellgrauem Grund. Maße in Pixeln bei `dpi`, Drehung in Grad.
    /// `canvas` ist der Scan (volle Einzugsbreite 8,5 Zoll), das Papier liegt mittig.
    static func makeScan(
        dpi: Int = 100, canvasHeightMM: Double? = nil, paperMM: (w: Double, h: Double),
        angle: Double = 0, blocks: [Block] = [], shadow: Bool = false, noise: Bool = true,
        paper: (CGFloat, CGFloat, CGFloat) = (250.0 / 255, 250.0 / 255, 251.0 / 255)
    ) -> CGImage {
        let ppm = Double(dpi) / 25.4
        let cw = Int((8.5 * Double(dpi)).rounded())
        let paperH = paperMM.h * ppm
        let ch = Int(((canvasHeightMM.map { $0 * ppm }) ?? (paperH + 20)).rounded())
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        // Hintergrund mit flachem Verlauf von links (229) nach rechts (237).
        for x in 0..<cw {
            let g = 229.0 + 8.0 * Double(x) / Double(cw)
            ctx.setFillColor(red: g / 255, green: (g + 3) / 255, blue: (g + 2) / 255, alpha: 1)
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: ch))
        }
        // Papier: Drehung um die Mitte des Scans, Koordinaten oben links.
        ctx.saveGState()
        ctx.translateBy(x: Double(cw) / 2, y: Double(ch) / 2)
        ctx.rotate(by: -angle * .pi / 180)   // positiver Winkel dreht im Uhrzeigersinn
        let pw = paperMM.w * ppm
        let paperRect = CGRect(x: -pw / 2, y: -paperH / 2, width: pw, height: paperH)
        if shadow {
            ctx.setFillColor(red: 0.80, green: 0.80, blue: 0.80, alpha: 1)
            ctx.fill(paperRect.insetBy(dx: -2, dy: -2))
        }
        ctx.setFillColor(red: paper.0, green: paper.1, blue: paper.2, alpha: 1)
        ctx.fill(paperRect)
        for b in blocks {
            let (r, g, bl) = b.ink.rgb
            ctx.setFillColor(red: r, green: g, blue: bl, alpha: 1)
            ctx.fill(CGRect(
                x: paperRect.minX + b.x * ppm, y: paperRect.maxY - (b.y + b.h) * ppm,
                width: b.w * ppm, height: b.h * ppm))
        }
        ctx.restoreGState()
        if noise, let data = ctx.data {
            var n = Noise()
            let p = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * ch)
            for y in 0..<ch {
                for x in 0..<cw {
                    let i = y * ctx.bytesPerRow + x * 4
                    let d = n.next()
                    for c in 0..<3 { p[i + c] = UInt8(max(0, min(255, Int(p[i + c]) + d))) }
                }
            }
        }
        return ctx.makeImage()!
    }

    /// Absatzartiger Text: Zeilen aus Blöcken von 2 mm Höhe.
    static func textLines(count: Int, width: Double, left: Double = 12, top: Double = 12, ink: Ink = .black) -> [Block] {
        (0..<count).map { i in Block(x: left, y: top + Double(i) * 5, w: width * (i % 3 == 2 ? 0.6 : 1.0), h: 2, ink: ink) }
    }

    /// Mittlere Helligkeit (0 bis 255) im Rechteck, Koordinaten oben links.
    static func meanLuma(_ image: CGImage, x: Int, y: Int, w: Int, h: Int) -> Double {
        let space = CGColorSpaceCreateDeviceGray()
        var buf = [UInt8](repeating: 0, count: image.width * image.height)
        let ctx = CGContext(
            data: &buf, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width, space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var sum = 0
        for yy in y..<(y + h) { for xx in x..<(x + w) { sum += Int(buf[yy * image.width + xx]) } }
        return Double(sum) / Double(w * h)
    }

    // MARK: Leerseite

    func testBlankPageWithNoiseAndEdgeShadowIsBlank() {
        let scan = Self.makeScan(paperMM: (210, 297), angle: 1.2, shadow: true)
        XCTAssertTrue(PageProcessor.isBlank(scan))
    }

    func testBlankReceiptIsBlank() {
        let scan = Self.makeScan(paperMM: (80, 176), angle: -2)
        XCTAssertTrue(PageProcessor.isBlank(scan))
    }

    func testPageWithTextIsNotBlank() {
        let scan = Self.makeScan(paperMM: (210, 297), angle: 1.2, blocks: Self.textLines(count: 40, width: 180))
        XCTAssertFalse(PageProcessor.isBlank(scan))
    }

    func testPageWithFewLinesIsNotBlank() {
        // Eine Anschrift aus drei Zeilen, sonst leer.
        let scan = Self.makeScan(paperMM: (210, 297), blocks: Self.textLines(count: 3, width: 70, left: 20, top: 40))
        XCTAssertFalse(PageProcessor.isBlank(scan))
    }

    func testCroppedBlankPageWithoutBackgroundIsBlank() {
        let scan = Self.makeScan(paperMM: (210, 297), shadow: true)
        XCTAssertTrue(PageProcessor.isBlank(PageProcessor.cropAndDeskew(scan)))
    }

    func testSignatureOnOtherwiseEmptyPageIsNotBlank() {
        // Ein paar kurze, gebogene Striche in der unteren rechten Ecke.
        let ppm = 100 / 25.4
        let paperW = 210.0, paperH = 297.0
        let cw = 850, ch = Int(paperH * ppm) + 20
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
        let left = (Double(cw) - paperW * ppm) / 2
        ctx.setFillColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1)
        ctx.fill(CGRect(x: left, y: 10, width: paperW * ppm, height: paperH * ppm))
        ctx.setStrokeColor(red: 0.1, green: 0.1, blue: 0.3, alpha: 1)
        ctx.setLineWidth(2.5)
        ctx.setLineCap(.round)
        let bx = left + 130 * ppm, by = 40.0 + 20 * ppm
        for i in 0..<3 {
            let o = Double(i) * 9
            ctx.move(to: CGPoint(x: bx + o, y: by))
            ctx.addCurve(to: CGPoint(x: bx + o + 30, y: by + 12),
                         control1: CGPoint(x: bx + o + 8, y: by + 25), control2: CGPoint(x: bx + o + 20, y: by - 10))
            ctx.strokePath()
        }
        XCTAssertFalse(PageProcessor.isBlank(ctx.makeImage()!))
    }

    func testDarkPageIsNotBlankAndCropIsSane() {
        let dark: (CGFloat, CGFloat, CGFloat) = (0.1, 0.1, 0.11)
        let scan = Self.makeScan(paperMM: (210, 297), angle: 0.8, blocks: Self.textLines(count: 4, width: 100), paper: dark)
        XCTAssertFalse(PageProcessor.isBlank(scan))
        let out = PageProcessor.cropAndDeskew(scan)
        XCTAssertEqual(Double(out.width), 210 / 25.4 * 100, accuracy: 12)
        XCTAssertEqual(Double(out.height), 297 / 25.4 * 100, accuracy: 12)
        XCTAssertFalse(PageProcessor.hasColor(scan))
        var blocks = Self.textLines(count: 4, width: 100)
        blocks.append(Block(x: 120, y: 100, w: 60, h: 40, ink: .red))
        XCTAssertTrue(PageProcessor.hasColor(Self.makeScan(paperMM: (210, 297), angle: 0.8, blocks: blocks, paper: dark)))
    }

    func testFullWidthPageWithoutGreyKeepsItsSize() {
        // Kein Hintergrund sichtbar: Textblöcke dürfen nicht für das Blatt gehalten werden.
        let ppm = 100 / 25.4
        let w = 850, h = Int(297 * ppm)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)
        for i in 0..<45 {
            ctx.fill(CGRect(x: 80 + (i % 4 == 0 ? 30 : 0), y: 60 + i * 22, width: 600, height: 8))
        }
        let out = PageProcessor.cropAndDeskew(ctx.makeImage()!)
        XCTAssertGreaterThan(out.width, w - 40)
        XCTAssertGreaterThan(out.height, h - 40)
    }

    // MARK: Zuschnitt und Entzerrung

    func testReceiptAspectRatioAfterCropAndDeskew() {
        for angle in [2.0, -2.5, 3.0] {
            let scan = Self.makeScan(
                paperMM: (80, 176), angle: angle, blocks: Self.textLines(count: 30, width: 56))
            let out = PageProcessor.cropAndDeskew(scan)
            let aspect = Double(out.width) / Double(out.height)
            XCTAssertEqual(aspect, 80.0 / 176.0, accuracy: 80.0 / 176.0 * 0.03, "Winkel \(angle)")
            // Papier ist 80 mm breit: bei 100 dpi 315 Pixel.
            XCTAssertEqual(Double(out.width), 80 / 25.4 * 100, accuracy: 8, "Winkel \(angle)")
        }
    }

    func testReceiptAspectRatioWhenScanIsCutAtPaperLength() {
        // Längenerkennung: der Scan ist so lang wie das Papier, die Ecken ragen aus dem Bild.
        let scan = Self.makeScan(
            canvasHeightMM: 176, paperMM: (80, 176), angle: 2.5, blocks: Self.textLines(count: 30, width: 56))
        let out = PageProcessor.cropAndDeskew(scan)
        let aspect = Double(out.width) / Double(out.height)
        XCTAssertEqual(aspect, 80.0 / 176.0, accuracy: 80.0 / 176.0 * 0.03)
    }

    func testCropLeavesOnlyThinGreyMargin() {
        let scan = Self.makeScan(
            paperMM: (80, 176), angle: 2.5, blocks: Self.textLines(count: 30, width: 56))
        let out = PageProcessor.cropAndDeskew(scan)
        // Randstreifen von 3 Pixeln: Papier (250) statt Hintergrund (230 bis 237).
        let m = 3
        XCTAssertGreaterThan(Self.meanLuma(out, x: 0, y: 40, w: m, h: out.height - 80), 244)
        XCTAssertGreaterThan(Self.meanLuma(out, x: out.width - m, y: 40, w: m, h: out.height - 80), 244)
        XCTAssertGreaterThan(Self.meanLuma(out, x: 40, y: 0, w: out.width - 80, h: m), 244)
        XCTAssertGreaterThan(Self.meanLuma(out, x: 40, y: out.height - m, w: out.width - 80, h: m), 244)
    }

    func testCropA4PageKeepsSize() {
        let scan = Self.makeScan(paperMM: (210, 297), angle: 1.0, blocks: Self.textLines(count: 40, width: 180))
        let out = PageProcessor.cropAndDeskew(scan)
        XCTAssertEqual(Double(out.width), 210 / 25.4 * 100, accuracy: 10)
        XCTAssertEqual(Double(out.height), 297 / 25.4 * 100, accuracy: 10)
    }

    func testBusinessCardWithSkew() {
        let scan = Self.makeScan(
            paperMM: (85, 55), angle: -1.5, blocks: Self.textLines(count: 8, width: 60, left: 8, top: 8))
        let out = PageProcessor.cropAndDeskew(scan)
        XCTAssertEqual(Double(out.width) / Double(out.height), 85.0 / 55.0, accuracy: 85.0 / 55.0 * 0.03)
    }

    func testCropReturnsInputWhenNoPaperEdgeIsFound() {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let out = PageProcessor.cropAndDeskew(ctx.makeImage()!)
        XCTAssertEqual(out.width, 400)
        XCTAssertEqual(out.height, 300)
    }

    // MARK: Farbe

    func testRedLogoCountsAsColor() {
        var blocks = Self.textLines(count: 30, width: 150)
        blocks.append(Block(x: 150, y: 10, w: 40, h: 12, ink: .red))
        let scan = Self.makeScan(paperMM: (210, 297), angle: 0.8, blocks: blocks)
        XCTAssertTrue(PageProcessor.hasColor(scan))
    }

    func testBlackAndGreyContentIsNotColor() {
        var blocks = Self.textLines(count: 30, width: 150)
        blocks.append(Block(x: 150, y: 10, w: 40, h: 12, ink: .grey))
        let scan = Self.makeScan(paperMM: (210, 297), angle: 0.8, blocks: blocks)
        XCTAssertFalse(PageProcessor.hasColor(scan))
    }

    func testTextOnPaleYellowPaperIsNotColor() {
        let yellow: (CGFloat, CGFloat, CGFloat) = (250.0 / 255, 240.0 / 255, 190.0 / 255)
        let text = Self.textLines(count: 30, width: 150)
        XCTAssertFalse(PageProcessor.hasColor(Self.makeScan(paperMM: (210, 297), angle: 0.8, blocks: text, paper: yellow)))
        var withLogo = text
        withLogo.append(Block(x: 150, y: 10, w: 40, h: 12, ink: .red))
        XCTAssertTrue(PageProcessor.hasColor(Self.makeScan(paperMM: (210, 297), angle: 0.8, blocks: withLogo, paper: yellow)))
    }

    func testBlankPageIsNotColor() {
        XCTAssertFalse(PageProcessor.hasColor(Self.makeScan(paperMM: (210, 297), angle: 1.0)))
    }

    // MARK: Speicher

    /// Der gerade Zuschnitt darf das Rohbild nicht am Leben halten: `cropping(to:)` teilt
    /// dessen Puffer, das Ergebnis muss einen eigenen, nur so großen haben.
    func testStraightCropOwnsItsBuffer() throws {
        let scan = Self.makeScan(paperMM: (180, 260), angle: 0, blocks: Self.textLines(count: 20, width: 120))
        let out = PageProcessor.cropAndDeskew(scan)
        XCTAssertLessThan(out.width, scan.width, "Zuschnitt hat stattgefunden")
        let held = try CFDataGetLength(XCTUnwrap(out.dataProvider?.data))
        let needed = out.width * out.height * out.bitsPerPixel / 8
        XCTAssertLessThanOrEqual(held, needed + 64 * out.height, "Puffer gehört dem Zuschnitt allein")
    }

    // MARK: Bereits zugeschnitten

    /// Zugeschnittenes Blatt ohne Hintergrund: weiß, mit einer hellgrauen Bahn über die ganze
    /// Höhe (wie ein großes Foto oder ein Farbfeld) und einer roten Marke im linken Rand.
    /// Die Papiersuche kann die Bahn für das Blatt halten und die Marke außerhalb liegen lassen.
    static func croppedPageWithBand() -> CGImage {
        let w = 800, h = 1100
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(red: 0.90, green: 0.90, blue: 0.90, alpha: 1)
        ctx.fill(CGRect(x: 250, y: 0, width: 300, height: h))
        ctx.setFillColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1)
        ctx.fill(CGRect(x: 30, y: 500, width: 100, height: 100))
        return ctx.makeImage()!
    }

    func testAlreadyCroppedSkipsSecondPaperSearch() {
        let page = Self.croppedPageWithBand()
        XCTAssertTrue(PageProcessor.hasColor(page, alreadyCropped: true), "Marke im Rand zählt")
        XCTAssertFalse(PageProcessor.isBlank(page, alreadyCropped: true))
        // Ohne den Hinweis hielt die Papiersuche die Bahn für das Blatt: die Seite galt als
        // leer und farblos, die rote Marke lag außerhalb (beim Schreiben dieses Tests gemessen).
        let region = PageRegion(page, detectPaper: false)
        XCTAssertNil(region?.rect)
    }

    // MARK: 1 Bit

    func testBinarizeProducesOneBitImage() {
        let scan = Self.makeScan(paperMM: (80, 100), blocks: [Block(x: 10, y: 10, w: 40, h: 10)])
        let bw = PageProcessor.binarize(scan)
        XCTAssertEqual(bw.bitsPerComponent, 1)
        XCTAssertEqual(bw.bitsPerPixel, 1)
        XCTAssertEqual(bw.width, scan.width)
        XCTAssertEqual(bw.height, scan.height)
    }

    func testFadedThermalTextStaysBlack() {
        // Grauer Text (Helligkeit etwa 178) auf weißem Bon: die Striche müssen schwarz bleiben.
        let blocks = Self.textLines(count: 20, width: 56, ink: .faint)
        let scan = Self.makeScan(paperMM: (80, 120), blocks: blocks)
        let bw = PageProcessor.binarize(scan)
        var buf = [UInt8](repeating: 0, count: bw.width * bw.height)
        let ctx = CGContext(
            data: &buf, width: bw.width, height: bw.height, bitsPerComponent: 8, bytesPerRow: bw.width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.draw(bw, in: CGRect(x: 0, y: 0, width: bw.width, height: bw.height))
        let ppm = 100 / 25.4
        let left = (Double(scan.width) - 80 * ppm) / 2, top = (Double(scan.height) - 120 * ppm) / 2
        var black = 0, total = 0
        for i in 0..<20 {
            // Mitte jedes Blocks, 1 mm Rand ausgenommen.
            let y0 = Int(top + (12 + Double(i) * 5 + 0.5) * ppm), y1 = Int(top + (12 + Double(i) * 5 + 1.5) * ppm)
            let x0 = Int(left + 14 * ppm), x1 = Int(left + 12 * ppm + 50 * ppm * (i % 3 == 2 ? 0.6 : 1.0) * 0.8)
            for y in y0..<y1 { for x in x0..<max(x0 + 1, x1) { total += 1; if buf[y * bw.width + x] == 0 { black += 1 } } }
        }
        XCTAssertGreaterThan(Double(black) / Double(total), 0.95)
    }

    func testBinarizeKeepsInkBlackAndPaperWhite() {
        let scan = Self.makeScan(paperMM: (80, 100), blocks: [Block(x: 10, y: 10, w: 40, h: 10)])
        let bw = PageProcessor.binarize(scan)
        // Zurück in 8 Bit Grau zeichnen und Stichproben lesen.
        var buf = [UInt8](repeating: 0, count: bw.width * bw.height)
        let ctx = CGContext(
            data: &buf, width: bw.width, height: bw.height, bitsPerComponent: 8, bytesPerRow: bw.width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.draw(bw, in: CGRect(x: 0, y: 0, width: bw.width, height: bw.height))
        let ppm = 100 / 25.4
        let paperLeft = (Double(scan.width) - 80 * ppm) / 2
        let paperTop = (Double(scan.height) - 100 * ppm) / 2
        let inkX = Int(paperLeft + 30 * ppm), inkY = Int(paperTop + 15 * ppm)
        let paperX = Int(paperLeft + 60 * ppm), paperY = Int(paperTop + 60 * ppm)
        XCTAssertEqual(buf[inkY * bw.width + inkX], 0)
        XCTAssertEqual(buf[paperY * bw.width + paperX], 255)
    }
}
