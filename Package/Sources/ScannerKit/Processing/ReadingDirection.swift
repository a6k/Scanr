import CoreGraphics
import Foundation
import os
import Vision

/// Erkennt eine auf dem Kopf liegende Seite, etwa einen verkehrt herum eingelegten Bon.
///
/// Vision hat keine eigene Erkennung der Leserichtung (Stand macOS 27 SDK). Die genaue
/// Texterkennung liest umgekehrten Text aber richtig und liefert die Zeilen dann mit vertauschten
/// Ecken: die obere linke liegt rechts von der oberen rechten. Ein Durchgang auf einer verkleinerten
/// Kopie reicht, gemessen rund 0,1 s je Seite. Die schnelle Stufe taugt nicht: Sie liest
/// umgekehrten Text als Zeichensalat und meldet trotzdem hohe Sicherheit (2026-10-23 am echten
/// Bon gemessen). Quer liegende Seiten (90 Grad) prüft das nicht.
public enum ReadingDirection {
    /// Längste Seite der Probe in Pixeln. Bon-Text bei 300 dpi bleibt dabei lesbar.
    static let probeSide = 1600
    /// So viele Zeichen müssen in umgekehrten Zeilen stehen. Darunter gilt die Seite als
    /// textlos (Foto, Leerseite, Stempel) und bleibt, wie sie ist.
    static let minimumCharacters = 20
    static let log = Logger(subsystem: "app.comodin.Scanr", category: "orientation")

    /// Die Seite, um 180 Grad gedreht, wenn sie auf dem Kopf liegt; sonst unverändert.
    public static func upright(_ image: CGImage) -> CGImage {
        guard isUpsideDown(image), let turned = rotated180(image) else { return image }
        return turned
    }

    /// Wahr, wenn die Mehrheit der erkannten Zeichen in umgekehrt liegenden Zeilen steht.
    static func isUpsideDown(_ image: CGImage) -> Bool {
        guard let probe = scaled(image, maxSide: probeSide) else { return false }
        let (normal, reversed) = characters(probe)
        log.debug("Leserichtung: Zeichen normal \(normal, privacy: .public), umgekehrt \(reversed, privacy: .public)")
        return reversed >= minimumCharacters && reversed > normal
    }

    /// Erkannte Zeichen in normal und in umgekehrt liegenden Zeilen.
    static func characters(_ image: CGImage) -> (normal: Int, reversed: Int) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["de-DE", "en-US"]
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            log.error("Leserichtung nicht prüfbar: \(String(describing: error), privacy: .public)")
            return (0, 0)
        }
        var normal = 0, reversed = 0
        for obs in request.results ?? [] {
            let count = obs.topCandidates(1).first?.string.count ?? 0
            if obs.topRight.x >= obs.topLeft.x { normal += count } else { reversed += count }
        }
        return (normal, reversed)
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

    /// Dieselbe Seite um 180 Grad gedreht, in Größe, Farbraum und Pixelformat des Originals.
    static func rotated180(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        let space = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: image.bitsPerComponent, bytesPerRow: 0,
            space: space, bitmapInfo: image.bitmapInfo.rawValue)
            ?? CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.translateBy(x: CGFloat(w), y: CGFloat(h))
        ctx.rotate(by: .pi)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
