import Foundation
import ImageIO
import ScannerKit
import UniformTypeIdentifiers

/// Prüfwerkzeug für den Scanner am USB. Nur für Entwicklung.
func usage() -> Never {
    FileHandle.standardError.write(Data("Aufruf: scanr-cli inquiry | caps | ghs [--raw] | status --watch | scan --dpi <n> [--duplex] --out <ordner> | job --profile auto|foto [--out <ordner>]\n".utf8))
    exit(2)
}

func ascii(_ bytes: ArraySlice<UInt8>) -> String {
    String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
}

func describe(_ s: HardwareStatus) -> String {
    "Papier: \(s.paperInHopper ? "ja" : "nein"), Taste: \(s.scanButton ? "gedrückt" : "aus"), "
        + "Klappe: \(s.coverOpen ? "offen" : "zu"), Doppeleinzug: \(s.doubleFeed ? "ja" : "nein"), "
        + "Fehlercode: 0x\(String(s.errorCode, radix: 16)), Ruhezustand: \(s.sleeping ? "ja" : "nein")"
}

/// Fehlermeldung für Menschen.
func message(_ error: Error) -> String {
    switch error as? ScannerError {
    case .noDocuments: return "Kein Papier im Einzug. Bitte Blätter einlegen und erneut starten."
    case .doubleFeed: return "Doppeleinzug erkannt. Blätter prüfen und erneut einlegen."
    case .paperJam: return "Papierstau. Klappe öffnen und Papier entfernen."
    case .coverOpen: return "Die Klappe ist offen."
    case .busy: return "Der Scanner ist beschäftigt."
    case .notFound: return "Kein Scanner gefunden."
    case .deviceHeldByOtherProcess: return "Ein anderes Programm benutzt den Scanner."
    case .disconnected: return "Die Verbindung zum Scanner ist abgerissen."
    case .rejected(let asc, let ascq):
        return String(format: "Der Scanner lehnt den Befehl ab (ASC 0x%02x, ASCQ 0x%02x).", asc, ascq)
    case .protocolViolation(let detail): return "Protokollfehler: \(detail)"
    case nil: return "Fehler: \(error)"
    }
}

func writePNG(_ image: CGImage, dpi: Int, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let verb = args.first else { usage() }

switch verb {
case "inquiry":
    guard args.count == 1 else { usage() }
    do {
        let transport = try IOUSBHostTransport.open()
        let data = try await transport.command(Command.inquiry(), dataOut: nil, readLength: 96, timeout: .seconds(5))
        guard data.count >= 36 else {
            print("Fehler: INQUIRY lieferte nur \(data.count) Byte, erwartet mindestens 36")
            exit(1)
        }
        print("Bytes:    \(data.count)")
        print("Hersteller: \(ascii(data[8..<16]))")
        print("Produkt:    \(ascii(data[16..<32]))")
        print("Version:    \(ascii(data[32..<36]))")
    } catch {
        print("Fehler: \(error)")
        exit(1)
    }
case "ghs":
    guard args.count == 1 || (args.count == 2 && args[1] == "--raw") else { usage() }
    do {
        let transport = try IOUSBHostTransport.open()
        let raw = try await transport.command(
            Command.getHardwareStatus(), dataOut: nil, readLength: 12, timeout: .seconds(2))
        if args.count == 2 {
            // Rohbytes unverändert auf stdout, für Fixtures.
            FileHandle.standardOutput.write(Data(raw))
        } else {
            print("Bytes: \(raw.map { String(format: "%02x", $0) }.joined(separator: " "))")
            print(describe(try HardwareStatus(bytes: raw)))
        }
    } catch {
        FileHandle.standardError.write(Data("Fehler: \(error)\n".utf8))
        exit(1)
    }
case "status":
    guard args == ["status", "--watch"] else { usage() }
    do {
        let transport = try IOUSBHostTransport.open()
        setvbuf(stdout, nil, _IOLBF, 0)
        var last: HardwareStatus?
        var polls = 0
        var busyReplies = 0
        while true {
            if polls > 0 && polls % 20 == 0 {
                print("... \(polls) Abfragen, \(busyReplies) mal beschäftigt")
            }
            polls += 1
            do {
                let s = try await transport.hardwareStatus()
                if s != last {
                    print("\(Date().formatted(date: .omitted, time: .standard)) \(describe(s))")
                    last = s
                }
            } catch ScannerError.busy {
                busyReplies += 1  // Gerät beschäftigt, nächste Runde.
            }
            try await Task.sleep(for: .milliseconds(500))
        }
    } catch {
        print("Fehler: \(error)")
        exit(1)
    }
case "caps":
    // Fähigkeiten wie `init_vpd` und `init_ms`: VPD-Seite 0xF0 und die MODE-SENSE-Seiten.
    guard args.count == 1 else { usage() }
    do {
        let transport = try IOUSBHostTransport.open()
        let vpd = try await transport.command(Command.inquiryVPD(), dataOut: nil, readLength: 204, timeout: .seconds(5))
        print("VPD (\(vpd.count) Byte):")
        for row in stride(from: 0, to: vpd.count, by: 16) {
            let line = vpd[row..<min(row + 16, vpd.count)].map { String(format: "%02x", $0) }.joined(separator: " ")
            print(String(format: "  %03x: ", row) + line)
        }
        let pages: [(UInt8, String)] = [
            (0x32, "autocolor"), (0x33, "prepick"), (0x34, "sleep"), (0x35, "duplex"), (0x36, "rand"),
            (0x37, "bg"), (0x38, "df"), (0x39, "dropout"), (0x3A, "buff"), (0x3C, "auto"),
        ]
        // Seite 0x3D (Lampe) fehlt absichtlich: MODE SENSE darauf legt den iX500 lahm, bis er
        // vom Strom getrennt wird (`init_model`, "locks up scanner"; am 2026-10-22 so erlebt).
        // 0x3E (Jobtrennung) wird beim Scannen nicht gebraucht und bleibt ungeprüft.
        for (page, name) in pages {
            do {
                let r = try await transport.command(Command.modeSense(page: page), dataOut: nil, readLength: 0x14, timeout: .seconds(5))
                print(String(format: "MODE SENSE 0x%02x %@: ja, ", page, name) + r.map { String(format: "%02x", $0) }.joined(separator: " "))
            } catch {
                print(String(format: "MODE SENSE 0x%02x %@: nein (", page, name) + "\(error))")
            }
        }
    } catch {
        print("Fehler: \(error)")
        exit(1)
    }
case "scan":
    var dpi: Int?
    var duplex = false
    var out: String?
    var rest = args.dropFirst()
    while let a = rest.popFirst() {
        switch a {
        case "--dpi": dpi = rest.popFirst().flatMap(Int.init)
        case "--duplex": duplex = true
        case "--out": out = rest.popFirst()
        default: usage()
        }
    }
    guard let dpi, let out else { usage() }
    let dir = URL(fileURLWithPath: out, isDirectory: true)
    do {
        let session = ScanSession(transport: try IOUSBHostTransport.open())
        var count = 0
        for try await page in session.run(ScanSettings(dpi: dpi, duplex: duplex)) {
            // Ordner erst anlegen, wenn wirklich eine Seite kommt (also Papier da war).
            if count == 0 {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let name = String(format: "blatt-%03d-%@.png", page.sheet, page.side == .front ? "vorn" : "hinten")
            try writePNG(page.image, dpi: page.dpi, to: dir.appendingPathComponent(name))
            count += 1
            print("\(name): \(page.image.width) x \(page.image.height) Pixel")
        }
        print("\(count) Seiten gespeichert in \(dir.path)")
    } catch {
        FileHandle.standardError.write(Data((message(error) + "\n").utf8))
        exit(1)
    }
case "job":
    var profileID: String?
    var out: String?
    var rest = args.dropFirst()
    while let a = rest.popFirst() {
        switch a {
        case "--profile": profileID = rest.popFirst()
        case "--out": out = rest.popFirst()
        default: usage()
        }
    }
    let profile: ScanProfile
    switch profileID {
    case "auto": profile = .auto
    case "foto": profile = .foto
    default: usage()
    }
    let dir = out.map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    do {
        let job = ScanJob(transport: try IOUSBHostTransport.open(), profile: profile, namer: FileNamer(), outputDir: dir)
        setvbuf(stdout, nil, _IOLBF, 0)
        let result = await job.run { print("\($0) Seiten") }
        for file in result.files { print("geschrieben: \(file.path)") }
        print("\(result.pages) Seiten in \(result.files.count) Datei(en)")
        if let error = result.error {
            FileHandle.standardError.write(Data((message(error) + "\n").utf8))
            exit(1)
        }
    } catch {
        FileHandle.standardError.write(Data((message(error) + "\n").utf8))
        exit(1)
    }
default:
    usage()
}
