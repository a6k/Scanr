import CoreGraphics
import Foundation

/// Seite eines Blatts. Dieselben Werte wie die Fenster-ID im READ-Befehl.
public typealias Side = ScanSide

/// Eine gescannte Seite, so wie der Scanner sie liefert (Farbe, 8 Bit je Kanal).
public struct RawPage: @unchecked Sendable {
    /// Blattnummer im Stapel, ab 1.
    public let sheet: Int
    public let side: Side
    public let image: CGImage
    public let dpi: Int

    public init(sheet: Int, side: Side, image: CGImage, dpi: Int) {
        self.sheet = sheet
        self.side = side
        self.image = image
        self.dpi = dpi
    }
}

extension RawPage {
    /// Baut ein CGImage aus RGB-Zeilen (3 Byte je Pixel, keine Auffüllung).
    static func makeImage(rgb: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard width > 0, height > 0, rgb.count >= width * height * 3 else {
            throw ScannerError.protocolViolation("Bilddaten passen nicht: \(rgb.count) Byte für \(width) x \(height)")
        }
        let bytes = Array(rgb.prefix(width * height * 3))
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
                bytesPerRow: width * 3, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else {
            throw ScannerError.protocolViolation("CGImage ließ sich nicht anlegen (\(width) x \(height))")
        }
        return image
    }
}
