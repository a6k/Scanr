import Foundation
import ScannerKit

/// Mitteilung nach einem Durchlauf. `files` sind die Dateien, die ein Klick im Finder zeigt.
nonisolated struct ResultMessage: Equatable, Sendable {
    var title: String
    var body: String
    var files: [URL]

    init(title: String, body: String, files: [URL]) {
        self.title = title
        self.body = body
        self.files = files
    }

    init(_ result: ScanResult) {
        files = result.files
        if result.cancelled {
            title = "Scan abgebrochen"
            body = Self.cancelledBody(result)
        } else if let error = result.error {
            let problem = Self.stop(error, result)
            if result.files.isEmpty {
                title = "Scan fehlgeschlagen"
                body = error == .scanner(.noDocuments) && result.sheets == 0 ? problem : "\(problem), nichts gespeichert"
            } else {
                title = "Scan unvollständig"
                body = "\(problem). \(Self.saved(result))"
            }
        } else if result.files.isEmpty {
            title = "Nichts gespeichert"
            body = "Nur leere Seiten"
        } else {
            title = "Scan gespeichert"
            let first = result.files[0].lastPathComponent
            body = result.files.count == 1 ? first : "\(Self.count(result.files.count, "Datei", "Dateien")), erste: \(first)"
            if result.pagesWithoutText > 0 {
                body += ". Ohne Texterkennung: \(Self.count(result.pagesWithoutText, "Seite", "Seiten"))"
            }
        }
    }

    private static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n) \(n == 1 ? one : many)"
    }

    private static func cancelledBody(_ result: ScanResult) -> String {
        if result.files.isEmpty {
            if case .output(let e) = result.error { return "Abgebrochen. \(describe(e)), nichts gespeichert" }
            return "Abgebrochen, nichts gespeichert"
        }
        if result.files.count == 1 {
            return "Abgebrochen, \(count(result.pages, "Seite", "Seiten")) gespeichert in \(result.files[0].lastPathComponent)"
        }
        return "Abgebrochen, \(count(result.files.count, "Datei", "Dateien")) gespeichert"
    }

    /// Was den Stapel beendet hat. Fehler am Papier nennen das Blatt, an dem es hing; andere
    /// Fehler nur, wenn schon etwas gelesen war.
    private static func stop(_ error: ScanJobError, _ result: ScanResult) -> String {
        guard case .scanner(let e) = error else { return describe(error) }
        let name = if case .protocolViolation = e { "Übertragungsfehler" } else { describe(e) }
        let atSheet: Bool = switch e {
        case .doubleFeed, .paperJam, .coverOpen, .protocolViolation: true
        default: result.sheets > 0 || !result.files.isEmpty
        }
        return atSheet ? "\(name) bei Blatt \(result.sheets + 1)" : name
    }

    /// „Blatt 1 bis 2 gespeichert (3 Seiten) in …“
    private static func saved(_ result: ScanResult) -> String {
        let place = result.files.count == 1
            ? result.files[0].lastPathComponent : count(result.files.count, "Datei", "Dateien")
        let pages = count(result.pages, "Seite", "Seiten")
        return switch result.sheets {
        case 0: "\(pages) gespeichert in \(place)"
        case 1: "Blatt 1 gespeichert (\(pages)) in \(place)"
        default: "Blatt 1 bis \(result.sheets) gespeichert (\(pages)) in \(place)"
        }
    }

    static func describe(_ error: ScanJobError) -> String {
        switch error {
        case .scanner(let e): describe(e)
        case .output(let e): describe(e)
        }
    }

    static func describe(_ error: ScannerError) -> String {
        switch error {
        case .doubleFeed: "Doppeleinzug"
        case .paperJam: "Papierstau"
        case .coverOpen: "Klappe offen"
        case .noDocuments: "Kein Papier eingelegt"
        case .busy, .deviceHeldByOtherProcess: "Scanner belegt"
        case .disconnected, .notFound: "Scanner getrennt"
        case .rejected(let asc, let ascq):
            String(format: "Scanner lehnt Befehl ab (ASC %02X, ASCQ %02X)", asc, ascq)
        // Einzelheiten stehen im Protokoll (Logger), nicht in Menü oder Mitteilung.
        case .protocolViolation: "Übertragungsfehler, bitte erneut versuchen"
        }
    }

    static func describe(_ error: OutputError) -> String {
        switch error {
        case .cannotCreateFile: "Datei nicht schreibbar (Schreibrechte oder freien Platz prüfen)"
        case .encodingFailed: "Bild ließ sich nicht kodieren"
        case .destinationExists: "Kein freier Dateiname"
        case .noPages: "Keine Seiten zum Schreiben"
        }
    }
}
