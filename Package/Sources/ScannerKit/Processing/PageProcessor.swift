import CoreGraphics
import Foundation

/// Eine aufbereitete Seite (zugeschnitten, gerade gerückt, ggf. in 1 Bit).
public struct ProcessedPage: @unchecked Sendable {
    public let image: CGImage
    public let dpi: Int
    public let isColor: Bool

    public init(image: CGImage, dpi: Int, isColor: Bool) {
        self.image = image
        self.dpi = dpi
        self.isColor = isColor
    }
}

/// Reine Bildverarbeitung für gescannte Seiten: Leerseite, Zuschnitt mit Geraderücken,
/// Farberkennung und Umwandlung in 1 Bit. Analyse läuft auf einer verkleinerten Kopie
/// (`PageAnalysis`), nur der Zuschnitt und die 1-Bit-Wandlung arbeiten in voller Auflösung.
public enum PageProcessor {
    // MARK: Schwellen und ihre Herkunft

    /// Tinte ist ein Pixel, das um mehr als diesen Wert dunkler ist als das Papier (90. Perzentil).
    /// Gemessen an den Echtscans: Durchscheinen der Rückseite und der Thermo-Geisterdruck
    /// auf Bons liegen höchstens 30 Stufen unter Weiß; Text und Linien über 90 Stufen darunter.
    static let inkContrast = 40
    /// Anteil Tinte an der Blattfläche, unter dem die Seite leer ist. Gemessen an den Echtscans:
    /// leere Sechzehntel eines Blatts (Bon, Lieferschein) haben 0 bis 0,07 Prozent Tinte, die am
    /// wenigsten bedruckte ganze Seite (Lieferschein) 3,9 Prozent. In den erzeugten Tests liegen
    /// Rauschen und Kantenschatten bei 0 Prozent, drei Anschriftszeilen bei etwa 0,7 Prozent.
    static let blankInkFraction = 0.0015
    /// Eine leere Seite muss hell sein; ein komplett schwarzes Blatt ist nicht leer.
    static let blankMinPaperLuma = 150

    /// Farbig ist ein Pixel, dessen Kanäle um mindestens so viel auseinanderliegen. Das Papier hat
    /// 4 bis 12 (Blaustich), Farbsäume an schwarzem Text bleiben nach dem Verkleinern unter 30,
    /// das rote Logo des Lieferscheins liegt bei über 100.
    static let colorChroma = 45
    /// Anteil farbiger Pixel an der Blattfläche, ab dem die Seite als farbig gilt.
    static let colorFraction = 0.0008

    /// Zuschnitt: Rand ringsum, der bei Leerseite und Farbe unberücksichtigt bleibt (Anteil der
    /// kürzeren Blattseite, mindestens 3 Analysepixel). Hier liegen Kantenschatten und Farbsäume.
    static let marginFraction = 0.015

    /// 1 Bit: schwarz ist ein Pixel, das dunkler als dieser Anteil des lokalen Mittels ist.
    /// Das Mittel eines weißen Blatts mit Text liegt bei 235 bis 245; 0,75 davon sind etwa 180 und
    /// lassen den Geisterdruck (205 bis 225) weiß.
    static let binarizeRatio = 0.75
    /// Unter dieser Helligkeit ist ein Pixel in jedem Fall schwarz.
    static let binarizeHardBlack = 70
    /// Kantenlänge der Zellen, aus denen das lokale Mittel entsteht (Pixel).
    static let binarizeCell = 32
    /// Das Mittel einer Zelle wird über so viele Zellen in jede Richtung geglättet.
    static let binarizeSmoothCells = 2

    // MARK: Leerseite

    /// Wahr, wenn auf dem Blatt (ohne Rand und Hintergrund) praktisch nichts gedruckt ist.
    public static func isBlank(_ image: CGImage) -> Bool {
        guard let region = PageRegion(image) else { return false }
        var hist = [Int](repeating: 0, count: 256)
        var n = 0
        region.forEachPixel { y, x in
            hist[Int(region.analysis.luma[y * region.analysis.width + x])] += 1
            n += 1
        }
        guard n > 0 else { return false }
        // 90. Perzentil als Papierhelligkeit.
        var cum = 0, paper = 255
        for v in 0..<256 {
            cum += hist[v]
            if cum * 10 >= n * 9 { paper = v; break }
        }
        guard paper >= blankMinPaperLuma else { return false }
        let limit = paper - inkContrast
        var ink = 0
        for v in 0..<max(0, limit) { ink += hist[v] }
        return Double(ink) / Double(n) < blankInkFraction
    }

    // MARK: Farbe

    /// Wahr, wenn ein nennenswerter Teil des Blatts farbig ist.
    public static func hasColor(_ image: CGImage) -> Bool {
        guard let region = PageRegion(image) else { return false }
        var colored = 0, n = 0
        let px = region.analysis.rgba
        region.forEachPixel { y, x in
            let i = (y * region.analysis.width + x) * 4
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            if max(r, g, b) - min(r, g, b) >= colorChroma { colored += 1 }
            n += 1
        }
        guard n > 0 else { return false }
        return Double(colored) / Double(n) >= colorFraction
    }

    // MARK: Zuschnitt

    /// Schneidet das Blatt vom Hintergrund und richtet es gerade. Wird keine Papierkante
    /// gefunden (etwa bei einem randlosen Bild), kommt das Original unverändert zurück.
    public static func cropAndDeskew(_ image: CGImage) -> CGImage {
        guard let analysis = PageAnalysis(image), let rect = PaperDetector.detect(analysis) else { return image }
        let f = analysis.scale
        let outW = Int((rect.width * f).rounded())
        let outH = Int((rect.height * f).rounded())
        guard outW >= 8, outH >= 8 else { return image }
        let cx = rect.cx * f, cy = rect.cy * f

        // Fast gerade: verlustfrei ausschneiden statt neu abtasten.
        if abs(rect.angle) < 0.1 * .pi / 180 {
            let box = CGRect(x: (cx - Double(outW) / 2).rounded(), y: (cy - Double(outH) / 2).rounded(),
                             width: Double(outW), height: Double(outH))
                .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return image.cropping(to: box) ?? image
        }

        guard let space = image.colorSpace.flatMap({ $0.model == .rgb ? $0 : nil }) ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
        ctx.interpolationQuality = .high

        // Ausgabepixel (u, v), oben links, liest das Quellbild bei c + (u - W/2) ex + (v - H/2) ey.
        // CGContext zählt von unten: Quell- und Zielkoordinaten werden in y gespiegelt.
        let c = cos(rect.angle), s = sin(rect.angle)
        let srcH = Double(image.height)
        func map(_ x: Double, _ yUp: Double) -> (Double, Double) {
            let dx = x - cx, dy = (srcH - yUp) - cy
            let u = Double(outW) / 2 + dx * c + dy * s
            let v = Double(outH) / 2 - dx * s + dy * c
            return (u, Double(outH) - v)
        }
        let o = map(0, 0), px = map(1, 0), py = map(0, 1)
        ctx.concatenate(CGAffineTransform(
            a: px.0 - o.0, b: px.1 - o.1, c: py.0 - o.0, d: py.1 - o.1, tx: o.0, ty: o.1))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    // MARK: 1 Bit

    /// Wandelt in ein Graustufenbild mit 1 Bit je Pixel (schwarz = 0). Die Schwelle folgt dem
    /// lokalen Mittel, damit Schatten, Verläufe und getöntes Papier nicht kippen.
    public static func binarize(_ image: CGImage) -> CGImage {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return image }
        var gray = [UInt8](repeating: 255, count: w * h)
        let drawn = gray.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return image }

        // Zellmittel, danach über Nachbarzellen geglättet.
        let cell = binarizeCell
        let gw = (w + cell - 1) / cell, gh = (h + cell - 1) / cell
        var sum = [Double](repeating: 0, count: gw * gh)
        var cnt = [Double](repeating: 0, count: gw * gh)
        gray.withUnsafeBufferPointer { g in
            for y in 0..<h {
                let gy = y / cell
                for x in 0..<w {
                    let i = gy * gw + x / cell
                    sum[i] += Double(g[y * w + x])
                    cnt[i] += 1
                }
            }
        }
        var smooth = [Double](repeating: 0, count: gw * gh)
        let r = binarizeSmoothCells
        for gy in 0..<gh {
            for gx in 0..<gw {
                var s = 0.0, n = 0.0
                for yy in max(0, gy - r)...min(gh - 1, gy + r) {
                    for xx in max(0, gx - r)...min(gw - 1, gx + r) {
                        s += sum[yy * gw + xx]; n += cnt[yy * gw + xx]
                    }
                }
                smooth[gy * gw + gx] = s / n
            }
        }

        let bytesPerRow = (w + 7) / 8
        var bits = [UInt8](repeating: 0xFF, count: bytesPerRow * h)
        let hard = UInt8(binarizeHardBlack)
        gray.withUnsafeBufferPointer { g in
            for y in 0..<h {
                // Bilinear zwischen den Zellmittelpunkten, sonst sieht man das Raster.
                let fy = max(0, min(Double(gh - 1), (Double(y) + 0.5) / Double(cell) - 0.5))
                let y0 = Int(fy), y1 = min(gh - 1, y0 + 1), wy = fy - Double(y0)
                for x in 0..<w {
                    let v = g[y * w + x]
                    var black = v < hard
                    if !black {
                        let fx = max(0, min(Double(gw - 1), (Double(x) + 0.5) / Double(cell) - 0.5))
                        let x0 = Int(fx), x1 = min(gw - 1, x0 + 1), wx = fx - Double(x0)
                        let top = smooth[y0 * gw + x0] * (1 - wx) + smooth[y0 * gw + x1] * wx
                        let bot = smooth[y1 * gw + x0] * (1 - wx) + smooth[y1 * gw + x1] * wx
                        let mean = top * (1 - wy) + bot * wy
                        black = Double(v) < mean * binarizeRatio
                    }
                    if black { bits[y * bytesPerRow + x / 8] &= ~(0x80 >> UInt8(x % 8)) }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(bits) as CFData),
              let out = CGImage(
                width: w, height: h, bitsPerComponent: 1, bitsPerPixel: 1, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return image }
        return out
    }
}

/// Der Teil einer Seite, der für Leerseite und Farbe zählt: das Blatt ohne Rand.
struct PageRegion {
    let analysis: PageAnalysis
    let rect: PaperRect?
    let inset: Double

    init?(_ image: CGImage) {
        guard let a = PageAnalysis(image) else { return nil }
        analysis = a
        rect = PaperDetector.detect(a)
        let shorter = rect.map { min($0.width, $0.height) } ?? Double(min(a.width, a.height))
        inset = max(3, shorter * PageProcessor.marginFraction)
    }

    func forEachPixel(_ body: (_ y: Int, _ x: Int) -> Void) {
        let w = analysis.width, h = analysis.height
        if let rect {
            // Nur den umschließenden Kasten des gedrehten Rechtecks absuchen.
            let half = (abs(rect.width * cos(rect.angle)) + abs(rect.height * sin(rect.angle))) / 2
            let halfY = (abs(rect.width * sin(rect.angle)) + abs(rect.height * cos(rect.angle))) / 2
            let x0 = max(0, Int(rect.cx - half)), x1 = min(w - 1, Int(rect.cx + half) + 1)
            let y0 = max(0, Int(rect.cy - halfY)), y1 = min(h - 1, Int(rect.cy + halfY) + 1)
            for y in y0...y1 {
                for x in x0...x1 where rect.contains(x: Double(x) + 0.5, y: Double(y) + 0.5, inset: inset) {
                    body(y, x)
                }
            }
        } else {
            let m = Int(inset)
            guard w > 2 * m, h > 2 * m else { return }
            for y in m..<(h - m) { for x in m..<(w - m) { body(y, x) } }
        }
    }
}
