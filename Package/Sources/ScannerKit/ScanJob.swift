import CoreGraphics
import Foundation

/// Warum ein Durchlauf nicht sauber zu Ende ging.
public enum ScanJobError: Error, Equatable, Sendable {
    /// Der Scanner hat den Stapel beendet (Doppeleinzug, Stau, kein Papier, ...).
    case scanner(ScannerError)
    /// Eine Datei ließ sich nicht schreiben.
    case output(OutputError)
}

/// Ergebnis eines Durchlaufs.
public struct ScanResult: Sendable {
    /// Geschriebene Dateien, bei JPG eine je Seite.
    public let files: [URL]
    /// Seiten, die in den Dateien stehen (ohne entfernte Leerseiten).
    public let pages: Int
    /// Der Fehler, den die Oberfläche nennen soll. Ein Schreibfehler hat Vorrang, wenn danach
    /// keine Datei vorliegt (PDF), sonst steht hier der Scannerfehler.
    public let error: ScanJobError?
    /// Der Scannerfehler, der den Stapel beendet hat, auch wenn `error` ein Schreibfehler ist.
    public let scannerError: ScannerError?
    /// Der Durchlauf wurde abgebrochen. Bereits geschriebene JPGs bleiben in `files`; eine PDF
    /// wird bei Abbruch nicht geschrieben.
    public let cancelled: Bool

    public init(files: [URL], pages: Int, error: ScanJobError?, scannerError: ScannerError? = nil,
                cancelled: Bool = false) {
        self.files = files
        self.pages = pages
        self.error = error
        self.scannerError = scannerError
        self.cancelled = cancelled
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

    /// Führt den Durchlauf aus. `progress` bekommt nach jeder behaltenen Seite die Zahl der
    /// Seiten, die im Ergebnis stehen werden (Leerseiten zählen nicht).
    ///
    /// Bei Abbruch stoppt der Scanner. Fertig geschriebene Dateien bleiben (JPG: alle bis dahin),
    /// eine PDF entsteht nicht. Das Ergebnis trägt dann `cancelled == true`.
    public func run(progress: @Sendable (Int) -> Void) async -> ScanResult {
        var kept: [ProcessedPage] = []   // nur PDF
        var files: [URL] = []            // nur JPG
        var pageCount = 0
        var scanFailure: ScannerError?
        var outputFailure: OutputError?

        do {
            for try await raw in session.run(profile.scanSettings) {
                try Task.checkCancellation()
                guard let page = Self.prepare(raw.image, profile: profile) else { continue }
                switch profile.format {
                case .pdf:
                    kept.append(Self.compact(page, quality: profile.jpegQuality))
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
            scanFailure = e
        } catch let e as OutputError {
            outputFailure = e
        } catch {
            scanFailure = .protocolViolation("\(error)")
        }
        if scanFailure == nil && outputFailure == nil && Task.isCancelled { return cancelled(files) }

        if profile.format == .pdf && !kept.isEmpty && outputFailure == nil {
            do {
                files = [try await writePDF(kept)]
            } catch is CancellationError {
                return cancelled([])
            } catch let e as OutputError {
                outputFailure = e
                pageCount = 0
            } catch {
                outputFailure = .cannotCreateFile
                pageCount = 0
            }
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
        return ScanResult(files: files, pages: pageCount, error: error, scannerError: scanFailure)
    }

    private func cancelled(_ written: [URL]) -> ScanResult {
        ScanResult(files: written, pages: written.count, error: nil, cancelled: true)
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
}
