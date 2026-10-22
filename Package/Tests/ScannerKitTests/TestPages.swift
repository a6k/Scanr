import CoreGraphics
import CoreText
import Foundation
@testable import ScannerKit

/// Erzeugt Testseiten für Ausgabe und OCR. Echte Scans liegen nicht im Repo.
enum TestPages {
    static let a4 = (widthMM: 210.0, heightMM: 297.0)

    static func pixels(_ mm: Double, dpi: Int) -> Int { Int((mm / 25.4 * Double(dpi)).rounded()) }

    /// Weißes RGB-Blatt mit Textzeilen in schwarzer Serifenlosschrift.
    /// `lines` stehen von oben nach unten, `size` in Pixeln, Zeilenabstand 1,5.
    static func textPage(
        _ lines: [String], widthMM: Double = a4.widthMM, heightMM: Double = a4.heightMM,
        dpi: Int = 300, size: CGFloat = 90
    ) -> CGImage {
        let w = pixels(widthMM, dpi: dpi), h = pixels(heightMM, dpi: dpi)
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        drawLines(lines, in: ctx, height: h, size: size)
        return ctx.makeImage()!
    }

    static func drawLines(_ lines: [String], in ctx: CGContext, height: Int, size: CGFloat) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ]
        for (i, text) in lines.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
            ctx.textPosition = CGPoint(x: size, y: CGFloat(height) - size * 1.5 * CGFloat(i + 1))
            CTLineDraw(line, ctx)
        }
    }

    static func page(_ image: CGImage, dpi: Int = 300, isColor: Bool = false) -> ProcessedPage {
        ProcessedPage(image: image, dpi: dpi, isColor: isColor)
    }

    /// Farbseite: Rauschen wie bei einem Foto im unteren Teil, rotes Logo oben, eine Textzeile.
    static func colorPage(dpi: Int = 300) -> CGImage {
        let w = pixels(a4.widthMM, dpi: dpi), h = pixels(a4.heightMM, dpi: dpi)
        var px = [UInt8](repeating: 255, count: w * h * 4)
        var state: UInt64 = 0x9E3779B97F4A7C15
        func rnd() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % 41) - 20
        }
        // Foto: Verlauf mit Rauschen, untere Hälfte.
        for y in (h / 2)..<(h - h / 20) {
            for x in (w / 20)..<(w - w / 20) {
                let base = 90 + (x * 100 / w) + (y * 40 / h)
                let i = (y * w + x) * 4
                px[i] = UInt8(max(0, min(255, base + rnd())))
                px[i + 1] = UInt8(max(0, min(255, base - 20 + rnd())))
                px[i + 2] = UInt8(max(0, min(255, base + 30 + rnd())))
            }
        }
        // Logo: rotes Rechteck mit Rundung nur grob als Kasten.
        for y in (h / 20)..<(h / 20 + h / 12) {
            for x in (w / 20)..<(w / 20 + w / 5) {
                let i = (y * w + x) * 4
                px[i] = 215; px[i + 1] = 30; px[i + 2] = 35
            }
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = px.withUnsafeMutableBytes { raw in
            CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        }
        drawLines(["Lieferschein 4711"], in: ctx, height: h - h / 6, size: 90)
        return ctx.makeImage()!
    }
}
