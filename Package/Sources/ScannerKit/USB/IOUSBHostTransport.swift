import Foundation
import IOKit
import IOUSBHost

/// USB-Transport für den ScanSnap iX500 über IOUSBHost.
/// Ablauf je Befehl wie `do_usb_cmd` in `fujitsu.c`: Befehlspaket schreiben, optional Daten
/// schreiben, optional lesen, 13 Byte Status lesen. Bei Check Condition folgt REQUEST SENSE.
public final class IOUSBHostTransport: USBTransport, @unchecked Sendable {
    static let vendorID = 0x04C5
    static let productID = 0x132B
    static let senseLength = 0x12

    private let interface: IOUSBHostInterface
    private let bulkOut: IOUSBHostPipe
    private let bulkIn: IOUSBHostPipe
    /// Ein Befehl nach dem anderen: Befehl, Daten und Status gehören zusammen.
    private let lock = NSLock()

    private init(interface: IOUSBHostInterface, bulkOut: IOUSBHostPipe, bulkIn: IOUSBHostPipe) {
        self.interface = interface
        self.bulkOut = bulkOut
        self.bulkIn = bulkIn
    }

    deinit { interface.destroy() }

    // MARK: Öffnen

    public static func open() throws -> IOUSBHostTransport {
        guard let service = findInterfaceService() else { throw ScannerError.notFound }
        defer { IOObjectRelease(service) }

        let interface: IOUSBHostInterface
        do {
            interface = try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
        } catch {
            throw map(error)
        }

        var outPipe: IOUSBHostPipe?
        var inPipe: IOUSBHostPipe?
        // Endpunktadressen aus dem Interface-Descriptor lesen: Bit 7 = IN, Typ Bulk.
        var current: UnsafePointer<IOUSBDescriptorHeader>? = nil
        let ifaceDesc = interface.interfaceDescriptor
        while let next = IOUSBGetNextEndpointDescriptor(
            interface.configurationDescriptor, ifaceDesc, current) {
            current = UnsafeRawPointer(next).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
            let ep = next.pointee
            guard ep.bmAttributes & 0x03 == 0x02 else { continue }  // nur Bulk
            let pipe: IOUSBHostPipe
            do { pipe = try interface.copyPipe(withAddress: Int(ep.bEndpointAddress)) } catch { throw map(error) }
            if ep.bEndpointAddress & 0x80 != 0 { inPipe = pipe } else { outPipe = pipe }
        }
        guard let outPipe, let inPipe else {
            throw ScannerError.protocolViolation("Bulk-Endpunkte fehlen")
        }
        return IOUSBHostTransport(interface: interface, bulkOut: outPipe, bulkIn: inPipe)
    }

    /// Sucht das Interface 0 des Scanners in der IORegistry.
    private static func findInterfaceService() -> io_service_t? {
        guard let matching = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary? else { return nil }
        let properties: NSMutableDictionary = [
            "idVendor": vendorID, "idProduct": productID, "bInterfaceNumber": 0,
        ]
        matching["IOPropertyMatch"] = properties
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        let service = IOIteratorNext(iterator)
        return service == 0 ? nil : service
    }

    // MARK: Befehl

    public func command(_ cdb: [UInt8], dataOut: [UInt8]?, readLength: Int?, timeout: Duration) async throws -> [UInt8] {
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        // Blockierende IORequests laufen auf einem Hintergrund-Thread, nicht im Cooperative Pool.
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    cont.resume(returning: try self.commandSync(cdb, dataOut: dataOut, readLength: readLength, timeout: seconds))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func commandSync(_ cdb: [UInt8], dataOut: [UInt8]?, readLength: Int?, timeout: TimeInterval) throws -> [UInt8] {
        lock.lock(); defer { lock.unlock() }

        try write(USBFraming.wrap(cdb), timeout: timeout)
        if let dataOut, !dataOut.isEmpty { try write(dataOut, timeout: timeout) }

        var data: [UInt8] = []
        if let readLength, readLength > 0 {
            data = try read(readLength, timeout: timeout)
        }

        let status = try USBFraming.status(try readExactStatus(timeout: timeout))
        switch status {
        case .good:
            return data
        case .busy:
            throw ScannerError.busy
        case .checkCondition:
            // REQUEST SENSE selbst läuft ohne weiteren Sense-Abruf.
            try write(USBFraming.wrap([0x03, 0, 0, 0, UInt8(Self.senseLength), 0]), timeout: timeout)
            let sense = try read(Self.senseLength, timeout: timeout)
            _ = try USBFraming.status(try readExactStatus(timeout: timeout))
            guard let error = ScannerError(sense: sense) else {
                // Sense-Key 0 mit EOM oder ILI: Befehl war erfolgreich, ILI meldet die Restlänge.
                let ili = sense[2] & 0x20 != 0
                if ili, readLength != nil {
                    let remainder = Int(UInt32(sense[3]) << 24 | UInt32(sense[4]) << 16 | UInt32(sense[5]) << 8 | UInt32(sense[6]))
                    return USBFraming.truncate(data, requested: readLength ?? data.count, remainder: remainder)
                }
                return data
            }
            throw error
        }
    }

    private func readExactStatus(timeout: TimeInterval) throws -> [UInt8] {
        try read(USBFraming.statusLength, timeout: timeout)
    }

    // MARK: Bulk-Übertragung

    private func write(_ bytes: [UInt8], timeout: TimeInterval) throws {
        let buffer = NSMutableData(bytes: bytes, length: bytes.count)
        var transferred = 0
        do {
            try bulkOut.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: timeout)
        } catch {
            recover()
            throw Self.map(error)
        }
        guard transferred == bytes.count else {
            throw ScannerError.protocolViolation("Schreiben: \(transferred) von \(bytes.count) Byte")
        }
    }

    private func read(_ length: Int, timeout: TimeInterval) throws -> [UInt8] {
        let buffer = NSMutableData(length: length)!
        var transferred = 0
        do {
            try bulkIn.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: timeout)
        } catch {
            recover()
            throw Self.map(error)
        }
        return Array(UnsafeBufferPointer(start: buffer.bytes.assumingMemoryBound(to: UInt8.self), count: transferred))
    }

    /// Nach einem fehlgeschlagenen Transfer (Timeout, Stall): Stall löschen und offene
    /// Anfragen abbrechen, damit der nächste Befehl nicht auf einem halben Zustand aufsetzt.
    /// Fehler dabei sind unerheblich, das Gerät kann auch schon weg sein.
    private func recover() {
        for pipe in [bulkOut, bulkIn] {
            try? pipe.clearStall()
            try? pipe.__abort(with: .synchronous)
        }
    }

    // MARK: Fehlerabbildung

    static func map(_ error: Error) -> ScannerError {
        let code = (error as NSError).code
        switch Int32(truncatingIfNeeded: code) {
        case kIOReturnExclusiveAccess:
            return .deviceHeldByOtherProcess
        case kIOReturnNoDevice, kIOReturnNotAttached, kIOReturnNotResponding, kIOReturnOffline:
            return .disconnected
        case kIOReturnBusy:
            return .busy
        default:
            return .protocolViolation("USB-Fehler \(error)")
        }
    }
}
