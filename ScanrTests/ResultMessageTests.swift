import Foundation
import ScannerKit
import Testing
@testable import Scanr

struct ResultMessageTests {
    let a = URL(fileURLWithPath: "/tmp/2026-10-22 scan 01.jpg")
    let b = URL(fileURLWithPath: "/tmp/2026-10-22 scan 02.jpg")

    @Test func success() {
        let m = ResultMessage(ScanResult(files: [a], pages: 1, error: nil))
        #expect(m == ResultMessage(title: "Scan gespeichert", body: "2026-10-22 scan 01.jpg", files: [a]))
    }

    @Test func successWithSeveralFiles() {
        let m = ResultMessage(ScanResult(files: [a, b], pages: 2, error: nil))
        #expect(m.body == "2 Dateien, erste: 2026-10-22 scan 01.jpg")
        #expect(m.files == [a, b])
    }

    @Test func onlyBlankPages() {
        let m = ResultMessage(ScanResult(files: [], pages: 0, error: nil))
        #expect(m.title == "Nichts gespeichert")
        #expect(m.body == "Nur leere Seiten")
    }

    @Test func cancelledWithoutFiles() {
        let m = ResultMessage(ScanResult(files: [], pages: 0, error: nil, cancelled: true))
        #expect(m == ResultMessage(title: "Scan abgebrochen", body: "Abgebrochen, nichts gespeichert", files: []))
    }

    @Test func cancelledWithFiles() {
        #expect(ResultMessage(ScanResult(files: [a, b], pages: 2, error: nil, cancelled: true)).body
            == "Abgebrochen, 2 Dateien gespeichert")
        #expect(ResultMessage(ScanResult(files: [a], pages: 1, error: nil, cancelled: true)).body
            == "Abgebrochen, 1 Datei gespeichert")
    }

    @Test func doubleFeedAfterSavedPages() {
        let pdf = URL(fileURLWithPath: "/tmp/2026-10-22 scan 03.pdf")
        let m = ResultMessage(ScanResult(files: [pdf], pages: 3, error: .scanner(.doubleFeed), scannerError: .doubleFeed))
        #expect(m == ResultMessage(title: "Scan unvollständig",
                                   body: "Doppeleinzug nach Seite 3. 3 Seiten gespeichert in 2026-10-22 scan 03.pdf",
                                   files: [pdf]))
    }

    @Test func errorAfterSeveralJPGs() {
        let m = ResultMessage(ScanResult(files: [a, b], pages: 2, error: .scanner(.paperJam), scannerError: .paperJam))
        #expect(m.body == "Papierstau nach Seite 2. 2 Seiten gespeichert in 2 Dateien")
    }

    @Test func scannerErrorsByName() {
        let cases: [(ScannerError, String)] = [
            (.doubleFeed, "Doppeleinzug, nichts gespeichert"),
            (.paperJam, "Papierstau, nichts gespeichert"),
            (.coverOpen, "Klappe offen, nichts gespeichert"),
            (.noDocuments, "Kein Papier, nichts gespeichert"),
            (.busy, "Scanner belegt, nichts gespeichert"),
            (.deviceHeldByOtherProcess, "Scanner belegt, nichts gespeichert"),
            (.disconnected, "Scanner getrennt, nichts gespeichert"),
            (.notFound, "Scanner getrennt, nichts gespeichert"),
        ]
        for (error, body) in cases {
            let m = ResultMessage(ScanResult(files: [], pages: 0, error: .scanner(error), scannerError: error))
            #expect(m.title == "Scan fehlgeschlagen")
            #expect(m.body == body)
        }
    }

    @Test func outputErrorNamesTheDiskProblem() {
        let m = ResultMessage(ScanResult(files: [], pages: 0, error: .output(.cannotCreateFile), scannerError: nil))
        #expect(m.body == "Datei nicht schreibbar (Schreibrechte oder freien Platz prüfen), nichts gespeichert")
        let n = ResultMessage(ScanResult(files: [], pages: 0, error: .output(.destinationExists)))
        #expect(n.body == "Kein freier Dateiname, nichts gespeichert")
    }
}
