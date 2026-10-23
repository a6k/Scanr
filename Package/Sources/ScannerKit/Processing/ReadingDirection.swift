import CoreGraphics
import Foundation
import os
import Vision

/// Erkennt die Lage einer Seite und richtet sie auf: auf dem Kopf (180 Grad) oder quer
/// eingelegt (90 Grad nach links oder rechts).
///
/// Vision hat keine eigene Erkennung der Leserichtung (Stand macOS 27 SDK). Die genaue
/// Texterkennung liest gedrehten Text aber richtig und liefert jede Zeile mit ihren Ecken, wie
/// sie im Bild liegen. Die Richtung von der oberen linken zur oberen rechten Ecke ist die
/// Leserichtung. Ein Durchgang auf einer verkleinerten Kopie reicht, rund 0,1 s je Seite; am
/// echten Bon lagen in jeder der vier Lagen alle erkannten Zeichen in genau einer Richtung.
/// Die schnelle Stufe taugt nicht: Sie liest gedrehten Text als Zeichensalat und meldet trotzdem
/// hohe Sicherheit (2026-10-23 gemessen).
public enum ReadingDirection {
    /// Längste Seite der Probe in Pixeln. Bon-Text bei 300 dpi bleibt dabei lesbar.
    static let probeSide = 1600
    /// So viele Zeichen müssen in der gewinnenden Richtung stehen. Darunter gilt die Seite als
    /// textlos (Foto, Leerseite, Stempel) und bleibt, wie sie ist.
    static let minimumCharacters = 20
    static let log = Logger(subsystem: "app.comodin.Scanr", category: "orientation")

    /// Die Seite in Leserichtung; unverändert, wenn sie schon so liegt oder zu wenig Text hat.
    public static func upright(_ image: CGImage) -> CGImage {
        let turns = quarterTurnsNeeded(image)
        guard turns != 0, let turned = rotated(image, quarterTurns: turns) else { return image }
        return turned
    }

    /// Vierteldrehungen gegen den Uhrzeigersinn (0 bis 3), die die Seite aufrichten.
    static func quarterTurnsNeeded(_ image: CGImage) -> Int {
        guard let probe = scaled(image, maxSide: probeSide) else { return 0 }
        let chars = characters(probe)
        let total = chars.reduce(0, +)
        guard let best = chars.indices.max(by: { chars[$0] < chars[$1] }) else { return 0 }
        log.debug("Leserichtung: Zeichen je Richtung \(chars, privacy: .public)")
        // Die gewinnende Richtung braucht genug Text und mehr als die Hälfte aller Zeichen.
        guard chars[best] >= minimumCharacters, chars[best] * 2 > total else { return 0 }
        // Läuft der Text in Richtung best × 90 Grad (gegen den Uhrzeigersinn gemessen), dreht
        // die Gegenrichtung ihn waagerecht.
        return (4 - best) % 4
    }

    /// Erkannte Zeichen je Leserichtung: Index 0 waagerecht nach rechts, 1 nach oben, 2 nach links
    /// (auf dem Kopf), 3 nach unten. Gemessen gegen den Uhrzeigersinn, y nach oben wie bei Vision.
    static func characters(_ image: CGImage) -> [Int] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["de-DE", "en-US"]
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            log.error("Leserichtung nicht prüfbar: \(String(describing: error), privacy: .public)")
            return [0, 0, 0, 0]
        }
        var chars = [0, 0, 0, 0]
        for obs in request.results ?? [] {
            let count = obs.topCandidates(1).first?.string.count ?? 0
            // In Pixeln, damit ein schmales Bild die Winkel nicht verzerrt.
            let dx = Double(obs.topRight.x - obs.topLeft.x) * Double(image.width)
            let dy = Double(obs.topRight.y - obs.topLeft.y) * Double(image.height)
            var degrees = atan2(dy, dx) * 180 / .pi
            if degrees < 0 { degrees += 360 }
            chars[Int((degrees + 45) / 90) % 4] += count
        }
        return chars
    }

    static func scaled(_ image: CGImage, maxSide: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        let factor = longest > maxSide ? Double(maxSide) / Double(longest) : 1
        let w = max(1, Int((Double(image.width) * factor).rounded()))
        let h = max(1, Int((Double(image.height) * factor).rounded()))
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Dieselbe Seite um `quarterTurns` × 90 Grad gegen den Uhrzeigersinn gedreht, in Farbraum
    /// und Pixelformat des Originals. Bei einer Vierteldrehung tauschen Breite und Höhe.
    static func rotated(_ image: CGImage, quarterTurns: Int) -> CGImage? {
        let turns = ((quarterTurns % 4) + 4) % 4
        let w = image.width, h = image.height
        let (outW, outH) = turns % 2 == 0 ? (w, h) : (h, w)
        let space = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: outW, height: outH, bitsPerComponent: image.bitsPerComponent, bytesPerRow: 0,
            space: space, bitmapInfo: image.bitmapInfo.rawValue)
            ?? CGContext(
                data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        // CoreGraphics zählt y nach oben, ein positiver Winkel dreht gegen den Uhrzeigersinn.
        switch turns {
        case 1: ctx.translateBy(x: CGFloat(h), y: 0); ctx.rotate(by: .pi / 2)
        case 2: ctx.translateBy(x: CGFloat(w), y: CGFloat(h)); ctx.rotate(by: .pi)
        case 3: ctx.translateBy(x: 0, y: CGFloat(w)); ctx.rotate(by: -.pi / 2)
        default: break
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
