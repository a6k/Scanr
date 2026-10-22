import CoreGraphics
import Foundation

/// Ergebnis eines Durchlaufs.
public struct ScanResult: Sendable {
    /// Geschriebene Dateien, bei JPG eine je Seite.
    public let files: [URL]
    /// Seiten, die in den Dateien stehen (ohne entfernte Leerseiten).
    public let pages: Int
    /// Fehler, der den Stapel beendet hat. Was bis dahin gescannt war, steht in `files`.
    public let error: ScannerError?

    public init(files: [URL], pages: Int, error: ScannerError?) {
        self.files = files
        self.pages = pages
        self.error = error
    }
}

/// Ein ganzer Durchlauf: scannen, jede Seite aufbereiten, Ergebnis schreiben.
///
/// Jede Seite wird aufbereitet, sobald sie aus dem Scanner kommt, das Rohbild ist danach frei.
/// Bei PDF bleiben nur die aufbereiteten Seiten im Speicher (1 Bit ist klein). Die Texterkennung
/// läuft erst nach dem Scannen, Seite für Seite hintereinander: sie braucht Sekunden je Seite
/// und würde sonst die Rohseiten im Puffer des Streams stauen.
public struct ScanJob: Sendable {
    /// So oft wird nach einem Namenskonflikt ein neuer Name erfragt.
    static let nameTries = 5

    let session: ScanSession
    let profile: ScanProfile
    let namer: FileNamer
    let outputDir: URL
    /// Tests: läuft zwischen Namensfrage und Schreiben, dort kann jemand die Datei anlegen.
    var beforeWrite: (@Sendable (URL) -> Void)?

    public init(transport: USBTransport, profile: ScanProfile, namer: FileNamer, outputDir: URL) {
        self.init(session: ScanSession(transport: transport), profile: profile, namer: namer, outputDir: outputDir)
    }

    init(session: ScanSession, profile: ScanProfile, namer: FileNamer, outputDir: URL) {
        self.session = session
        self.profile = profile
        self.namer = namer
        self.outputDir = outputDir
    }

    /// Führt den Durchlauf aus. `progress` bekommt nach jeder gescannten Seite die Zahl der
    /// Seiten, die im Ergebnis stehen werden.
    ///
    /// Wird die Aufgabe abgebrochen, stoppt der Scanner, es bleibt keine Datei übrig (bereits
    /// geschriebene JPGs dieses Durchlaufs werden wieder entfernt) und das Ergebnis ist leer.
    public func run(progress: @Sendable (Int) -> Void) async -> ScanResult {
        var kept: [ProcessedPage] = []   // nur PDF
        var files: [URL] = []            // nur JPG, bis zum Ende
        var pageCount = 0
        var failure: ScannerError?

        do {
            for try await raw in session.run(profile.scanSettings) {
                try Task.checkCancellation()
                guard let page = Self.prepare(raw.image, profile: profile) else { continue }
                switch profile.format {
                case .pdf:
                    kept.append(page)
                case .jpg:
                    files.append(try writeJPEG(page))
                }
                pageCount += 1
                progress(pageCount)
            }
            try Task.checkCancellation()   // Abbruch beendet den Stream ohne Fehler
        } catch is CancellationError {
            return cancelled(files)
        } catch let e as ScannerError {
            failure = e
        } catch let e as OutputError {
            failure = Self.scannerError(e)
        } catch {
            failure = .protocolViolation("\(error)")
        }
        if failure == nil && Task.isCancelled { return cancelled(files) }

        if profile.format == .pdf && !kept.isEmpty {
            do {
                files = [try await writePDF(kept)]
            } catch is CancellationError {
                return cancelled([])
            } catch let e as OutputError {
                failure = failure ?? Self.scannerError(e)
                pageCount = 0
            } catch {
                failure = failure ?? .protocolViolation("\(error)")
                pageCount = 0
            }
        }
        return ScanResult(files: files, pages: pageCount, error: failure)
    }

    private func cancelled(_ written: [URL]) -> ScanResult {
        for url in written { try? FileManager.default.removeItem(at: url) }
        return ScanResult(files: [], pages: 0, error: nil)
    }

    // MARK: Seite aufbereiten

    /// Zuschnitt, Leerseitenprüfung und Farbmodus. Die Analyse läuft einmal, auf dem
    /// zugeschnittenen Blatt (`alreadyCropped`). Nil heißt Leerseite, die wegfällt.
    static func prepare(_ image: CGImage, profile: ScanProfile) -> ProcessedPage? {
        let cropped = PageProcessor.cropAndDeskew(image)
        if profile.removeBlankPages && PageProcessor.isBlank(cropped, alreadyCropped: true) { return nil }
        let dpi = profile.dpi
        switch profile.colorMode {
        case .color:
            return ProcessedPage(image: cropped, dpi: dpi, isColor: true)
        case .gray:
            return ProcessedPage(image: PageProcessor.grayscale(cropped), dpi: dpi, isColor: false)
        case .blackWhite:
            return ProcessedPage(image: PageProcessor.binarize(cropped), dpi: dpi, isColor: false)
        case .autoDetect:
            if PageProcessor.hasColor(cropped, alreadyCropped: true) {
                return ProcessedPage(image: cropped, dpi: dpi, isColor: true)
            }
            return ProcessedPage(image: PageProcessor.binarize(cropped), dpi: dpi, isColor: false)
        }
    }

    // MARK: Schreiben

    private func writeJPEG(_ page: ProcessedPage) throws -> URL {
        try write(ext: "jpg") { url in
            try JPEGWriter.write(page, quality: profile.jpegQuality, to: url)
        }
    }

    private func writePDF(_ pages: [ProcessedPage]) async throws -> URL {
        // Texterkennung nacheinander, vor der Namensfrage: so liegt zwischen Frage und Schreiben
        // keine Wartezeit.
        var withText: [(ProcessedPage, [TextLine])] = []
        for page in pages {
            try Task.checkCancellation()
            let lines = try await OCR.lines(in: page.image)
            withText.append((page, lines))
        }
        try Task.checkCancellation()
        return try write(ext: "pdf") { url in
            try PDFComposer.write(withText, to: url, jpegQuality: profile.jpegQuality)
        }
    }

    /// Fragt den Namen unmittelbar vor dem Schreiben. Hat sich die Datei inzwischen angefunden,
    /// kommt ein neuer Name, höchstens `nameTries` Mal.
    private func write(ext: String, _ body: (URL) throws -> Void) throws -> URL {
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        for _ in 0..<Self.nameTries {
            let url = namer.nextURL(in: outputDir, date: Date(), profile: profile, ext: ext)
            beforeWrite?(url)
            do {
                try body(url)
                return url
            } catch OutputError.destinationExists {
                continue
            }
        }
        throw OutputError.destinationExists
    }

    private static func scannerError(_ e: OutputError) -> ScannerError {
        switch e {
        case .noPages: .protocolViolation("Keine Seiten zum Schreiben")
        case .cannotCreateFile: .protocolViolation("Datei lässt sich nicht anlegen")
        case .encodingFailed: .protocolViolation("Bild lässt sich nicht kodieren")
        case .destinationExists: .protocolViolation("Kein freier Dateiname gefunden")
        }
    }
}
