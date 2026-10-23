import CoreGraphics
import Foundation

/// Warum ein Durchlauf nicht sauber zu Ende ging.
public enum ScanJobError: Error, Equatable, Sendable {
    /// Der Scanner hat den Stapel beendet (Doppeleinzug, Stau, kein Papier, ...).
    case scanner(ScannerError)
    /// Eine Datei ließ sich nicht schreiben.
    case output(OutputError)
}

/// Fortschritt eines Durchlaufs.
public enum ScanProgress: Equatable, Sendable {
    /// Nach jeder behaltenen Seite: so viele Seiten stehen im Ergebnis (Leerseiten zählen nicht).
    case scanned(pages: Int)
    /// Der Scanner ist fertig, die Texterkennung beginnt mit Seite `page` von `of`. Nur bei PDF.
    case recognizing(page: Int, of: Int)
}

/// Ergebnis eines Durchlaufs.
public struct ScanResult: Sendable {
    /// Geschriebene Dateien, bei JPG eine je Seite.
    public let files: [URL]
    /// Seiten, die in den Dateien stehen (ohne entfernte Leerseiten).
    public let pages: Int
    /// Vollständig gelesene Blätter, deren Seiten alle im Ergebnis stehen oder als Leerseite
    /// entfallen sind. Ein Fehler betrifft das Blatt danach.
    public let sheets: Int
    /// Der Fehler, den die Oberfläche nennen soll. Ein Schreibfehler hat Vorrang, wenn danach
    /// keine Datei vorliegt (PDF), sonst steht hier der Scannerfehler.
    public let error: ScanJobError?
    /// Der Scannerfehler, der den Stapel beendet hat, auch wenn `error` ein Schreibfehler ist.
    public let scannerError: ScannerError?
    /// Der Durchlauf wurde abgebrochen. Was bis dahin gescannt war, steht in `files`: bei JPG die
    /// fertigen Dateien, bei PDF eine Datei mit allen behaltenen Seiten.
    public let cancelled: Bool
    /// Seiten im PDF, deren Texterkennung gescheitert ist. Sie stehen ohne Textebene darin.
    public let pagesWithoutText: Int

    public init(files: [URL], pages: Int, sheets: Int = 0, error: ScanJobError?,
                scannerError: ScannerError? = nil, cancelled: Bool = false, pagesWithoutText: Int = 0) {
        self.files = files
        self.pages = pages
        self.sheets = sheets
        self.error = error
        self.scannerError = scannerError
        self.cancelled = cancelled
        self.pagesWithoutText = pagesWithoutText
    }
}

/// Ein ganzer Durchlauf: scannen, jede Seite aufbereiten, Ergebnis schreiben.
///
/// Jede Seite wird aufbereitet, sobald sie aus dem Scanner kommt, das Rohbild ist danach frei.
/// Bei PDF bleiben nur die aufbereiteten Seiten im Speicher (1 Bit ist klein). Die Texterkennung
/// läuft erst nach dem Scannen, Seite für Seite hintereinander: sie braucht Sekunden je Seite
/// und würde sonst die Rohseiten im Puffer des Streams stauen. Den Beginn meldet
/// `ScanProgress.recognizing`.
public struct ScanJob: Sendable {
    /// So oft wird nach einem Namenskonflikt ein neuer Name erfragt.
    static let nameTries = 5

    let session: ScanSession
    let profile: ScanProfile
    let namer: FileNamer
    let outputDir: URL
    /// Tests: läuft zwischen Namensfrage und Schreiben, dort kann jemand die Datei anlegen.
    var beforeWrite: (@Sendable (URL) -> Void)?
    /// Texterkennung einer Seite; Tests setzen hier einen Fehler ein.
    var recognize: @Sendable (CGImage) async throws -> [TextLine] = { try await OCR.lines(in: $0) }

    public init(transport: USBTransport, profile: ScanProfile, namer: FileNamer, outputDir: URL) {
        self.init(session: ScanSession(transport: transport), profile: profile, namer: namer, outputDir: outputDir)
    }

    init(session: ScanSession, profile: ScanProfile, namer: FileNamer, outputDir: URL) {
        self.session = session
        self.profile = profile
        self.namer = namer
        self.outputDir = outputDir
    }

    /// Führt den Durchlauf aus und meldet den Fortschritt über `progress`.
    ///
    /// Kehrt erst zurück, wenn der Scanner steht. Bei Abbruch stoppt der Scanner, die Seiten bis
    /// dahin bleiben: JPGs sind schon geschrieben, eine PDF entsteht aus den behaltenen Seiten.
    /// Läuft gerade die Texterkennung, bekommen nur die schon erkannten Seiten eine Textebene.
    /// Das Ergebnis trägt dann `cancelled == true`.
    public func run(progress: @Sendable (ScanProgress) -> Void) async -> ScanResult {
        var kept: [ProcessedPage] = []   // nur PDF
        var files: [URL] = []            // nur JPG
        var pageCount = 0
        var sheets = 0
        var pagesWithoutText = 0
        var scanFailure: ScannerError?
        var outputFailure: OutputError?
        let duplex = profile.scanSettings.duplex
        let scan = session.start(profile.scanSettings)

        do {
            for try await raw in scan.pages {
                if Task.isCancelled { break }
                if let page = Self.prepare(raw.image, profile: profile) {
                    switch profile.format {
                    case .pdf:
                        kept.append(Self.compact(page, quality: profile.jpegQuality))
                    case .jpg:
                        files.append(try writeJPEG(page))
                    }
                    pageCount += 1
                    progress(.scanned(pages: pageCount))
                }
                // Das Blatt ist fertig, wenn seine letzte Seite durch ist, auch als Leerseite.
                if !duplex || raw.side == .back { sheets = raw.sheet }
            }
        } catch is CancellationError {
            // Abbruch, siehe unten.
        } catch let e as ScannerError {
            scanFailure = e
        } catch let e as OutputError {
            outputFailure = e
        } catch {
            scanFailure = .protocolViolation("\(error)")
        }
        // Endet die Schleife vorzeitig (Abbruch, Schreibfehler), läuft der Scanner noch. Erst
        // zurückkehren, wenn er gestoppt ist.
        scan.producer.cancel()
        await scan.producer.value
        // Ein Fehler, den erst der Abbruch ausgelöst hat, zählt nicht.
        if Task.isCancelled { scanFailure = nil }

        if profile.format == .pdf && !kept.isEmpty && outputFailure == nil {
            do {
                let pdf = try await writePDF(kept, progress: progress)
                files = [pdf.url]
                pagesWithoutText = pdf.withoutText
            } catch {
                if let e = error as? OutputError {
                    outputFailure = e
                } else {
                    OutputFile.log.error("PDF nicht geschrieben: \(String(describing: error), privacy: .public)")
                    outputFailure = .cannotCreateFile
                }
                pageCount = 0
                sheets = 0
            }
        }
        if Task.isCancelled {
            return ScanResult(files: files, pages: pageCount, sheets: sheets,
                              error: outputFailure.map { .output($0) }, cancelled: true,
                              pagesWithoutText: pagesWithoutText)
        }
        // Ein Schreibfehler gewinnt, wenn nichts geschrieben wurde; der Scannerfehler bleibt in
        // `scannerError`. Mit geschriebener Datei zählt der Fehler, der den Stapel beendet hat.
        let error: ScanJobError? = if let outputFailure, files.isEmpty || scanFailure == nil {
            .output(outputFailure)
        } else if let scanFailure {
            .scanner(scanFailure)
        } else {
            nil
        }
        return ScanResult(files: files, pages: pageCount, sheets: sheets, error: error, scannerError: scanFailure,
                          pagesWithoutText: pagesWithoutText)
    }

    /// Farb- und Graubilder sofort als JPEG kodieren (Qualität des Profils), damit sie bis zum
    /// Schreiben der PDF nur noch die komprimierten Bytes belegen. 1 Bit ist schon klein.
    static func compact(_ page: ProcessedPage, quality: Double) -> ProcessedPage {
        guard page.image.bitsPerComponent > 1,
              let data = JPEGWriter.encode(page.image, dpi: page.dpi, quality: quality),
              let provider = CGDataProvider(data: data as CFData),
              let lazy = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return page }
        return ProcessedPage(image: lazy, dpi: page.dpi, isColor: page.isColor, jpegData: data)
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

    /// Texterkennung nacheinander, vor der Namensfrage: so liegt zwischen Frage und Schreiben
    /// keine Wartezeit. Nach einem Abbruch beginnt keine weitere Erkennung, die übrigen Seiten
    /// kommen ohne Textebene ins PDF.
    private func writePDF(_ pages: [ProcessedPage], progress: @Sendable (ScanProgress) -> Void) async throws
        -> (url: URL, withoutText: Int)
    {
        var withText: [(ProcessedPage, [TextLine])] = []
        var withoutText = 0
        for (i, page) in pages.enumerated() {
            var lines: [TextLine] = []
            if !Task.isCancelled { progress(.recognizing(page: i + 1, of: pages.count)) }
            if !Task.isCancelled {
                // Scheitert die Erkennung einer Seite, kommt sie ohne Textebene ins PDF. Sonst
                // wäre der ganze gescannte Stapel verloren, und die Meldung nennte einen Schreibfehler.
                do {
                    lines = try await recognize(page.image)
                } catch {
                    withoutText += 1
                    OutputFile.log.error("Texterkennung Seite \(i + 1): \(String(describing: error), privacy: .public)")
                }
            }
            withText.append((page, lines))
        }
        let url = try write(ext: "pdf") { url in
            try PDFComposer.write(withText, to: url, jpegQuality: profile.jpegQuality)
        }
        return (url, withoutText)
    }

    /// Fragt den Namen unmittelbar vor dem Schreiben. Hat sich die Datei inzwischen angefunden,
    /// kommt ein neuer Name, höchstens `nameTries` Mal.
    private func write(ext: String, _ body: (URL) throws -> Void) throws -> URL {
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            OutputFile.log.error("Ausgabeordner nicht anlegbar: \(String(describing: error), privacy: .public)")
        }
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
}
