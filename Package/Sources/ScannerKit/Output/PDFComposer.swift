import CoreGraphics
import CoreText
import Foundation

/// Baut ein PDF aus Seiten mit unsichtbarer Textebene. Jede Seite hat die Größe, die ihre
/// Pixel bei ihrer Auflösung ergeben (Pixel / dpi × 72 Punkt), ein Bon bleibt also ein Bon.
public enum PDFComposer {
    /// - Parameter jpegQuality: Qualität, mit der Farbseiten als JPEG eingebettet werden.
    ///   Schwarzweiße 1-Bit-Seiten werden unverändert als 1-Bit-Bild eingebettet.
    public static func write(
        _ pages: [(ProcessedPage, [TextLine])], to url: URL, jpegQuality: Double = 0.6
    ) throws {
        guard !pages.isEmpty else { throw OutputError.noPages }
        try OutputFile.writeAtomically(to: url) { temp in
            try render(pages, to: temp, jpegQuality: jpegQuality)
        }
    }

    private static func render(_ pages: [(ProcessedPage, [TextLine])], to url: URL, jpegQuality: Double) throws {
        // CoreGraphics nennt keinen Grund. Ob der Ordner beschreibbar ist, sagt das Protokoll.
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil)
        else {
            let dir = url.deletingLastPathComponent().path
            let writable = FileManager.default.isWritableFile(atPath: dir)
            OutputFile.log.error("PDF nicht anlegbar, Ordner beschreibbar: \(writable, privacy: .public)")
            throw OutputError.cannotCreateFile
        }

        for (page, lines) in pages {
            let dpi = Double(max(1, page.dpi))
            let width = Double(page.image.width) / dpi * 72
            let height = Double(page.image.height) / dpi * 72
            var box = CGRect(x: 0, y: 0, width: width, height: height)
            let pageInfo = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)]
            ctx.beginPDFPage(pageInfo as CFDictionary)
            ctx.draw(embeddable(page, quality: jpegQuality), in: box)
            drawInvisibleText(lines, in: ctx, size: box.size)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    /// Farbseiten gehen als fertig kodierte JPEG-Daten in das PDF (CoreGraphics übernimmt sie
    /// ohne erneute Kompression). Alles andere, vor allem 1 Bit, bleibt wie es ist.
    private static func embeddable(_ page: ProcessedPage, quality: Double) -> CGImage {
        if let data = page.jpegData, let provider = CGDataProvider(data: data as CFData),
           let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        {
            return jpeg
        }
        guard page.isColor, page.image.bitsPerComponent > 1,
              let data = JPEGWriter.encode(page.image, dpi: page.dpi, quality: quality),
              let provider = CGDataProvider(data: data as CFData),
              let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return page.image }
        return jpeg
    }

    /// Schreibt jede Zeile unsichtbar in ihre Umrahmung: Schriftgröße nach der Zeilenhöhe,
    /// waagerecht auf die Breite der Umrahmung gestreckt.
    private static func drawInvisibleText(_ lines: [TextLine], in ctx: CGContext, size: CGSize) {
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for line in lines {
            let rect = CGRect(
                x: line.box.minX * size.width, y: line.box.minY * size.height,
                width: line.box.width * size.width, height: line.box.height * size.height)
            guard rect.width > 0, rect.height > 0 else { continue }
            let fontSize = max(1, rect.height * 0.8)
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let attributed = NSAttributedString(string: line.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let natural = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            guard natural > 0 else { continue }
            // Unterkante der Schrift etwas über der Unterkante der Umrahmung (Unterlängen).
            ctx.textMatrix = CGAffineTransform(a: rect.width / natural, b: 0, c: 0, d: 1,
                                               tx: rect.minX, ty: rect.minY + rect.height * 0.2)
            CTLineDraw(ctLine, ctx)
        }
        ctx.restoreGState()
    }
}
