import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum OutputError: Error, Equatable {
    case noPages
    case cannotCreateFile
    case encodingFailed
    /// Am Ziel liegt schon eine Datei; nichts wird überschrieben.
    case destinationExists
}

public enum JPEGWriter {
    /// Schreibt die Seite als JPEG und vermerkt die Auflösung in den Metadaten.
    public static func write(_ page: ProcessedPage, quality: Double, to url: URL) throws {
        guard let data = encode(page.image, dpi: page.dpi, quality: quality) else { throw OutputError.encodingFailed }
        try OutputFile.writeAtomically(to: url) { temp in
            do { try data.write(to: temp) } catch { throw OutputError.cannotCreateFile }
        }
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

/// Gemeinsamer Schreibweg: erst in eine versteckte Temp-Datei im selben Ordner, dann ohne
/// Überschreiben an den Zielnamen verschieben. Ein fehlgeschlagener Schreibvorgang hinterlässt
/// weder eine halbe Datei am Ziel noch eine Temp-Datei, die der FileNamer mitzählen könnte.
enum OutputFile {
    static func writeAtomically(to url: URL, _ body: (URL) throws -> Void) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { throw OutputError.destinationExists }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".scanr-\(UUID().uuidString).tmp")
        do {
            try body(temp)
            // moveItem ersetzt nie; existiert das Ziel inzwischen, wirft es.
            do { try fm.moveItem(at: temp, to: url) } catch {
                throw fm.fileExists(atPath: url.path) ? OutputError.destinationExists : OutputError.cannotCreateFile
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }
}
