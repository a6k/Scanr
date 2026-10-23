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

    @Test func successNamesPagesWithoutText() {
        let pdf = URL(fileURLWithPath: "/tmp/2026-10-22 scan 01.pdf")
        let m = ResultMessage(ScanResult(files: [pdf], pages: 3, error: nil, pagesWithoutText: 2))
        #expect(m.title == "Scan gespeichert")
        #expect(m.body == "2026-10-22 scan 01.pdf. Ohne Texterkennung: 2 Seiten")
    }

    @Test func incompleteScanAlsoNamesPagesWithoutText() {
        let pdf = URL(fileURLWithPath: "/tmp/2026-10-22 scan 01.pdf")
        let m = ResultMessage(ScanResult(files: [pdf], pages: 2, sheets: 2, error: .scanner(.paperJam),
                                         scannerError: .paperJam, pagesWithoutText: 1))
        #expect(m.title == "Scan unvollständig")
        #expect(m.body.hasSuffix(". Ohne Texterkennung: 1 Seite"))
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

    @Test func cancelledWithJPGs() {
        #expect(ResultMessage(ScanResult(files: [a, b], pages: 2, error: nil, cancelled: true)).body
            == "Abgebrochen, 2 Dateien gespeichert")
        #expect(ResultMessage(ScanResult(files: [a], pages: 1, error: nil, cancelled: true)).body
            == "Abgebrochen, 1 Seite gespeichert in 2026-10-22 scan 01.jpg")
    }

    @Test func cancelledPDFNamesPagesAndFile() {
        let pdf = URL(fileURLWithPath: "/tmp/2026-10-22 scan 03.pdf")
        let m = ResultMessage(ScanResult(files: [pdf], pages: 4, sheets: 2, error: nil, cancelled: true))
        #expect(m == ResultMessage(title: "Scan abgebrochen",
                                   body: "Abgebrochen, 4 Seiten gespeichert in 2026-10-22 scan 03.pdf",
                                   files: [pdf]))
    }

    @Test func cancelledButPDFNotWritable() {
        let m = ResultMessage(ScanResult(files: [], pages: 0, error: .output(.cannotCreateFile), cancelled: true))
        #expect(m.body == "Abgebrochen. Datei nicht schreibbar (Schreibrechte oder freien Platz prüfen), nichts gespeichert")
    }

    @Test func doubleFeedNamesTheSheetAndTheSavedSheets() {
        // Duplex: Blatt 1 mit leerer Rückseite, Blatt 2 beidseitig, Doppeleinzug bei Blatt 3.
        let pdf = URL(fileURLWithPath: "/tmp/2026-10-22 scan 03.pdf")
        let m = ResultMessage(ScanResult(files: [pdf], pages: 3, sheets: 2, error: .scanner(.doubleFeed),
                                         scannerError: .doubleFeed))
        #expect(m == ResultMessage(title: "Scan unvollständig",
                                   body: "Doppeleinzug bei Blatt 3. Blatt 1 bis 2 gespeichert (3 Seiten) in 2026-10-22 scan 03.pdf",
                                   files: [pdf]))
    }

    @Test func errorAfterOneSheet() {
        let pdf = URL(fileURLWithPath: "/tmp/2026-10-22 scan 03.pdf")
        let m = ResultMessage(ScanResult(files: [pdf], pages: 1, sheets: 1, error: .scanner(.paperJam),
                                         scannerError: .paperJam))
        #expect(m.body == "Papierstau bei Blatt 2. Blatt 1 gespeichert (1 Seite) in 2026-10-22 scan 03.pdf")
    }

    @Test func errorAfterSeveralJPGs() {
        let m = ResultMessage(ScanResult(files: [a, b], pages: 2, sheets: 2, error: .scanner(.coverOpen),
                                         scannerError: .coverOpen))
        #expect(m.body == "Klappe offen bei Blatt 3. Blatt 1 bis 2 gespeichert (2 Seiten) in 2 Dateien")
    }

    @Test func midBatchErrorsNameTheSheet() {
        let cases: [(ScannerError, String)] = [
            (.noDocuments, "Kein Papier eingelegt bei Blatt 4"),
            (.protocolViolation("x"), "Übertragungsfehler bei Blatt 4"),
            (.disconnected, "Scanner getrennt bei Blatt 4"),
        ]
        for (error, start) in cases {
            let m = ResultMessage(ScanResult(files: [a], pages: 5, sheets: 3, error: .scanner(error), scannerError: error))
            #expect(m.body == "\(start). Blatt 1 bis 3 gespeichert (5 Seiten) in 2026-10-22 scan 01.jpg")
        }
    }

    @Test func errorOnTheBackOfTheFirstSheetAfterItsFront() {
        let m = ResultMessage(ScanResult(files: [a], pages: 1, sheets: 0, error: .scanner(.paperJam),
                                         scannerError: .paperJam))
        #expect(m.body == "Papierstau bei Blatt 1. 1 Seite gespeichert in 2026-10-22 scan 01.jpg")
    }

    @Test func nothingSavedAfterBlankSheets() {
        let m = ResultMessage(ScanResult(files: [], pages: 0, sheets: 2, error: .scanner(.doubleFeed),
                                         scannerError: .doubleFeed))
        #expect(m.body == "Doppeleinzug bei Blatt 3, nichts gespeichert")
    }

    @Test func scannerErrorsByName() {
        let cases: [(ScannerError, String)] = [
            (.doubleFeed, "Doppeleinzug bei Blatt 1, nichts gespeichert"),
            (.paperJam, "Papierstau bei Blatt 1, nichts gespeichert"),
            (.coverOpen, "Klappe offen bei Blatt 1, nichts gespeichert"),
            (.noDocuments, "Kein Papier eingelegt"),
            (.protocolViolation("Error Domain=X Code=1"), "Übertragungsfehler bei Blatt 1, nichts gespeichert"),
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
