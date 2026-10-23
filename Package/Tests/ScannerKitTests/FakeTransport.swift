import Foundation
@testable import ScannerKit

/// Spielt einen iX500 nach: zeichnet jeden Befehl auf und antwortet aus vorgegebenen Blättern.
/// Bilddaten liefert der Fake so, wie das Gerät sie schickt (invertiert); der letzte READ einer
/// Seite endet kurz mit ILI und EOM.
final class FakeTransport: USBTransport, @unchecked Sendable {
    struct Call: Equatable {
        let cdb: [UInt8]
        let dataOut: [UInt8]?
        let readLength: Int?
    }

    struct Sheet {
        var width: Int
        var front: [UInt8]
        var back: [UInt8]
        var frontLines: Int { front.count / (width * 3) }
        var backLines: Int { back.count / (width * 3) }
    }

    private let lock = NSLock()
    private var log: [Call] = []
    private var objectPositions = 0
    private var current: Sheet?
    private var remaining: [UInt8: [UInt8]] = [:]

    /// GHS meldet: kein Papier im Einzug.
    var hopperEmpty = false
    /// Blätter, die der Reihe nach eingezogen werden. Ist keins mehr da, endet OBJECT POSITION mit „kein Papier“.
    var sheets: [Sheet] = []
    /// Fehler für das n-te OBJECT POSITION (ab 1).
    var objectPositionError: [Int: ScannerError] = [:]
    /// Nur diese Farbreihenfolge nimmt SET WINDOW an; nil heißt alle.
    var acceptedInterlace: ColorInterlace?
    /// Zeilenzahl, die die Pixelgröße vor dem Scan meldet (das Fenster, nicht das Papier).
    var windowLines = 1000
    /// Fehler für den ersten Bild-READ des n-ten eingezogenen Blatts (ab 1).
    var readError: [Int: ScannerError] = [:]
    /// Wartezeit vor jedem READ, damit ein Abbruch mitten im Blatt landet.
    var readDelay: Duration?
    /// READs dieser Seite liefern immer 0 Byte mit ILI und ohne EOM.
    var stallSide: ScanSide?
    /// SET WINDOW endet immer mit diesem Fehler.
    var setWindowError: ScannerError?
    /// Pixelgröße meldet überall 0.
    var zeroPixelSize = false
    /// Kurze READs kommen ohne ILI und EOM (fehlerhaftes Gerät).
    var unflaggedShortReads = false
    /// Der Rest kommt ohne Kennzeichen, das Seitenende danach als leerer READ mit EOM, aber ohne ILI.
    var emptyEomWithoutIli = false
    /// Zählt leere EOM-READs; ab 50 bricht der Fake ab, damit ein Fehler im Lesen nicht hängt.
    private var emptyEomReads = 0
    /// SCANNER CONTROL 04 (Abbruch) braucht so lange, auch in einem abgebrochenen Task.
    var cancelDelay: Duration?
    private var fedSheets = 0

    var calls: [Call] { lock.withLock { log } }

    func command(_ cdb: [UInt8], dataOut: [UInt8]?, readLength: Int?, timeout: Duration) async throws -> [UInt8] {
        try await execute(cdb, dataOut: dataOut, readLength: readLength, timeout: timeout).data
    }

    func execute(_ cdb: [UInt8], dataOut: [UInt8]?, readLength: Int?, timeout: Duration) async throws -> CommandResult {
        if cdb[0] == 0x28, let d = lock.withLock({ readDelay }) { try await Task.sleep(for: d) }
        if cdb == Command.scannerControl(0x04), let d = lock.withLock({ cancelDelay }) {
            let seconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { c.resume() }
            }
        }
        return try lock.withLock { try respond(cdb, dataOut: dataOut, readLength: readLength) }
    }

    private func respond(_ cdb: [UInt8], dataOut: [UInt8]?, readLength: Int?) throws -> CommandResult {
        log.append(Call(cdb: cdb, dataOut: dataOut, readLength: readLength))
        switch cdb[0] {
        case 0xC2:
            var b = [UInt8](repeating: 0, count: 12)
            if hopperEmpty { b[3] = 0x80 }
            return CommandResult(data: b)
        case 0x24:
            if let setWindowError { throw setWindowError }
            if let acceptedInterlace, let d = dataOut, Self.interlace(of: d) != acceptedInterlace {
                throw ScannerError.rejected(asc: 0x26, ascq: 0)
            }
            return CommandResult(data: [])
        case 0x31:
            objectPositions += 1
            if let e = objectPositionError[objectPositions] { throw e }
            guard !sheets.isEmpty else { throw ScannerError.noDocuments }
            let s = sheets.removeFirst()
            fedSheets += 1
            current = s
            remaining = [ScanSide.front.rawValue: s.front, ScanSide.back.rawValue: s.back]
            return CommandResult(data: [])
        case 0x28 where cdb[2] == PixelSize.dataType:
            guard let s = current else { throw ScannerError.protocolViolation("Pixelgröße ohne Blatt") }
            let lines = cdb[5] == ScanSide.back.rawValue ? s.backLines : s.frontLines
            var b = [UInt8](repeating: 0, count: PixelSize.length)
            if zeroPixelSize { return CommandResult(data: b) }
            Self.put(&b, 0, s.width)
            Self.put(&b, 4, windowLines)
            Self.put(&b, 8, s.width)
            Self.put(&b, 12, lines)
            return CommandResult(data: b)
        case 0x28:
            let side = cdb[5]
            if let e = readError.removeValue(forKey: fedSheets) { throw e }
            if stallSide?.rawValue == side { return CommandResult(data: [], shortRead: true) }
            let want = Int(cdb[6]) << 16 | Int(cdb[7]) << 8 | Int(cdb[8])
            let left = remaining[side] ?? []
            if left.count >= want && left.count > 0 {
                remaining[side] = Array(left.dropFirst(want))
                return CommandResult(data: Array(left.prefix(want)))
            }
            remaining[side] = []
            if emptyEomWithoutIli {
                if !left.isEmpty { return CommandResult(data: left) }
                emptyEomReads += 1
                if emptyEomReads > 50 { throw ScannerError.protocolViolation("Fake: Seite endet nie") }
                return CommandResult(data: [], endOfMedium: true)
            }
            if unflaggedShortReads { return CommandResult(data: left) }
            return CommandResult(data: left, shortRead: true, endOfMedium: true)
        default:
            return CommandResult(data: [])
        }
    }

    private static func put(_ b: inout [UInt8], _ o: Int, _ v: Int) {
        for i in 0..<4 { b[o + i] = UInt8((v >> (8 * (3 - i))) & 0xFF) }
    }

    private static func interlace(of payload: [UInt8]) -> ColorInterlace {
        let d = Array(payload[8...])
        if d[0x2A] == 0 { return .rrggbb }
        return d[0x2B] == 5 ? .bgr : .rgb
    }

    /// Lesbare Bezeichnung eines Befehls für Reihenfolge-Tests.
    static func label(_ c: Call) -> String {
        let hex = { (v: UInt8) in String(format: "%02x", v) }
        let side = { (v: UInt8) in v == ScanSide.back.rawValue ? "back" : "front" }
        switch c.cdb[0] {
        case 0x1D: return "SEND DIAGNOSTIC"
        case 0x15: return "MODE SELECT \(hex(c.dataOut?[4] ?? 0))"
        case 0x24: return "SET WINDOW"
        case 0x2A: return "SEND \(hex(c.cdb[2]))"
        case 0xF1 where c.cdb[1] & 0x10 != 0: return "RIC \(side(c.cdb[2]))"
        case 0xF1: return "SCANNER CONTROL \(hex(c.cdb[1] & 0x0F | c.cdb[2] << 4))"
        case 0xC2: return "GHS"
        case 0x31: return "OBJECT POSITION \(hex(c.cdb[1]))"
        case 0x1B: return "SCAN"
        case 0x28 where c.cdb[2] == PixelSize.dataType: return "READ PIXELSIZE \(side(c.cdb[5]))"
        case 0x28: return "READ \(side(c.cdb[5]))"
        default: return "OPCODE \(hex(c.cdb[0]))"
        }
    }
}
