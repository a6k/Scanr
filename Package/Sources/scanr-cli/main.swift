import Foundation
import ScannerKit

/// Prüfwerkzeug für den Scanner am USB. Nur für Entwicklung.
func usage() -> Never {
    FileHandle.standardError.write(Data("Aufruf: scanr-cli inquiry\n".utf8))
    exit(2)
}

func ascii(_ bytes: ArraySlice<UInt8>) -> String {
    String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
}

guard CommandLine.arguments.count == 2 else { usage() }

switch CommandLine.arguments[1] {
case "inquiry":
    do {
        let transport = try IOUSBHostTransport.open()
        let data = try await transport.command([0x12, 0, 0, 0, 96, 0], dataOut: nil, readLength: 96, timeout: .seconds(5))
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
default:
    usage()
}
