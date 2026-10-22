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
        let saved = Self.count(result.files.count, "Datei", "Dateien")
        if result.cancelled {
            title = "Scan abgebrochen"
            body = result.files.isEmpty ? "Abgebrochen, nichts gespeichert" : "Abgebrochen, \(saved) gespeichert"
        } else if let error = result.error {
            let problem = Self.describe(error)
            if result.files.isEmpty {
                title = "Scan fehlgeschlagen"
                body = switch error {
                case .scanner(.noDocuments): problem
                case .scanner(.protocolViolation): "Übertragungsfehler, nichts gespeichert. Bitte erneut versuchen"
                default: "\(problem), nichts gespeichert"
                }
            } else {
                let place = result.files.count == 1 ? result.files[0].lastPathComponent : saved
                title = "Scan unvollständig"
                body = "\(problem) nach Seite \(result.pages). "
                    + "\(Self.count(result.pages, "Seite", "Seiten")) gespeichert in \(place)"
            }
        } else if result.files.isEmpty {
            title = "Nichts gespeichert"
            body = "Nur leere Seiten"
        } else {
            title = "Scan gespeichert"
            let first = result.files[0].lastPathComponent
            body = result.files.count == 1 ? first : "\(saved), erste: \(first)"
        }
    }

    private static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n) \(n == 1 ? one : many)"
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
