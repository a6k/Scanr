import CoreGraphics
import Foundation

/// Verkleinerte Kopie einer Seite für die Analyse. Leerseite, Farbe und Papierkanten
/// brauchen keine 600 dpi; nur der endgültige Zuschnitt arbeitet in voller Auflösung.
struct PageAnalysis {
    /// Seitenlänge der Kopie in Pixeln, darüber wird heruntergerechnet.
    static let maxSide = 1000

    /// Vollauflösungs-Pixel je Analysepixel (ganzzahlig, mindestens 1).
    let scale: Double
    let width: Int
    let height: Int
    /// RGB, 4 Byte je Pixel (das vierte ungenutzt), Zeilen ohne Auffüllung.
    let rgba: [UInt8]
    /// Helligkeit 0 bis 255 (Rec. 601).
    let luma: [UInt8]

    init?(_ image: CGImage) {
        let longest = max(image.width, image.height)
        let scale = max(1.0, (Double(longest) / Double(Self.maxSide)).rounded(.up))
        let w = max(1, Int(Double(image.width) / scale))
        let h = max(1, Int(Double(image.height) / scale))
        var buffer = [UInt8](repeating: 255, count: w * h * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(
                    data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .high
            // Obere linke Ecken decken sich; der Rest unter 1 Analysepixel fällt weg.
            ctx.draw(image, in: CGRect(
                x: 0, y: Double(h) - Double(image.height) / scale,
                width: Double(image.width) / scale, height: Double(image.height) / scale))
            return true
        }
        guard drawn else { return nil }
        var luma = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = Int(buffer[i * 4]), g = Int(buffer[i * 4 + 1]), b = Int(buffer[i * 4 + 2])
            luma[i] = UInt8((77 * r + 150 * g + 29 * b) >> 8)
        }
        self.scale = scale
        self.width = w
        self.height = h
        self.rgba = buffer
        self.luma = luma
    }
}

/// Gedrehtes Rechteck in Analysepixeln. `angle` ist die Richtung der Rechteck-x-Achse
/// in Bildkoordinaten (y nach unten), positiv im Uhrzeigersinn.
struct PaperRect {
    var cx: Double
    var cy: Double
    var width: Double
    var height: Double
    var angle: Double

    /// Liegt der Punkt im Rechteck, das ringsum um `inset` verkleinert wird?
    func contains(x: Double, y: Double, inset: Double) -> Bool {
        let dx = x - cx, dy = y - cy
        let c = cos(angle), s = sin(angle)
        let u = dx * c + dy * s
        let v = -dx * s + dy * c
        return abs(u) <= width / 2 - inset && abs(v) <= height / 2 - inset
    }
}
