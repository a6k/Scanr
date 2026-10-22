import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum OutputError: Error, Equatable {
    case noPages
    case cannotCreateFile
    case encodingFailed
}

public enum JPEGWriter {
    /// Schreibt die Seite als JPEG und vermerkt die Auflösung in den Metadaten.
    public static func write(_ page: ProcessedPage, quality: Double, to url: URL) throws {
        guard let data = encode(page.image, dpi: page.dpi, quality: quality) else { throw OutputError.encodingFailed }
        do { try data.write(to: url, options: .atomic) } catch { throw OutputError.cannotCreateFile }
    }

    static func encode(_ image: CGImage, dpi: Int, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: max(0, min(1, quality)),
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
