import Foundation
import ScannerKit

/// Prüfwerkzeug für den Scanner am USB. Nur für Entwicklung.
func usage() -> Never {
    FileHandle.standardError.write(Data("Aufruf: scanr-cli inquiry | ghs [--raw] | status --watch\n".utf8))
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
default:
    usage()
}
