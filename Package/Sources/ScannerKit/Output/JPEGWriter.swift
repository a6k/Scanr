import CoreGraphics
import Foundation
import ImageIO
import os
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
            do { try data.write(to: temp) } catch {
                OutputFile.log.error("JPEG nicht schreibbar: \(String(describing: error), privacy: .public)")
                throw OutputError.cannotCreateFile
            }
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
///
/// Die Temp-Datei trägt ihre Entstehungszeit im Namen (`.scanr-<Unix-Sekunden>-<UUID>.tmp`).
/// So findet `removeStaleTemps` Reste eines Absturzes, ohne Dateidaten zu lesen.
public enum OutputFile {
    static let log = Logger(subsystem: "app.comodin.Scanr", category: "output")
    /// Ab diesem Alter gilt eine Temp-Datei als Rest eines abgebrochenen Laufs.
    public static let staleAge: TimeInterval = 3600

    static func writeAtomically(to url: URL, _ body: (URL) throws -> Void) throws {
        let fm = FileManager.default
        if exists(url) { throw OutputError.destinationExists }
        let temp = tempURL(in: url.deletingLastPathComponent())
        do {
            try body(temp)
            // moveItem ersetzt nie; existiert das Ziel inzwischen, wirft es.
            do { try fm.moveItem(at: temp, to: url) } catch {
                if exists(url) { throw OutputError.destinationExists }
                log.error("Verschieben nach \(url.lastPathComponent, privacy: .public) gescheitert: \(String(describing: error), privacy: .public)")
                throw OutputError.cannotCreateFile
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// Die Datei liegt da, als echte Datei oder als ausgelagerter iCloud-Platzhalter.
    static func exists(_ url: URL) -> Bool {
        let fm = FileManager.default
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(FileNamer.placeholderName(of: url.lastPathComponent))
        return fm.fileExists(atPath: url.path) || fm.fileExists(atPath: placeholder.path)
    }

    static func tempURL(in dir: URL, now: Date = Date()) -> URL {
        dir.appendingPathComponent(".scanr-\(Int(now.timeIntervalSince1970))-\(UUID().uuidString).tmp")
    }

    /// Entstehungszeit aus dem Namen einer Temp-Datei; nil bei fremden Namen.
    static func tempCreation(_ name: String) -> Date? {
        let prefix = ".scanr-", suffix = ".tmp"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let core = name.dropFirst(prefix.count).dropLast(suffix.count)
        guard let dash = core.firstIndex(of: "-"), UUID(uuidString: String(core[core.index(after: dash)...])) != nil,
              let seconds = Int(core[..<dash])
        else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Löscht Temp-Dateien, die älter als `maxAge` sind (Reste eines Absturzes). Gibt die Zahl
    /// der gelöschten Dateien zurück.
    @discardableResult
    public static func removeStaleTemps(in dir: URL, now: Date = Date(), maxAge: TimeInterval = staleAge) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var removed = 0
        for name in names {
            guard let created = tempCreation(name), now.timeIntervalSince(created) > maxAge else { continue }
            do {
                try fm.removeItem(at: dir.appendingPathComponent(name))
                removed += 1
            } catch {
                log.error("Alte Temp-Datei \(name, privacy: .public) nicht gelöscht: \(String(describing: error), privacy: .public)")
            }
        }
        return removed
    }
}
