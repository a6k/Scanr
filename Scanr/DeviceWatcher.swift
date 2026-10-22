import Foundation
import IOKit
import IOKit.usb

/// Meldet, wenn das Interface des iX500 erscheint (Kabel gesteckt, Gerät eingeschaltet).
/// Gleiche Suche wie `IOUSBHostTransport.open()`: Hersteller, Produkt, Interface 0.
nonisolated final class DeviceWatcher: @unchecked Sendable {
    let arrivals: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var port: IONotificationPortRef?
    private var iterator: io_iterator_t = 0

    init() {
        (arrivals, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        guard let port = IONotificationPortCreate(kIOMainPortDefault),
              let matching = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary?
        else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        matching["IOPropertyMatch"] = ["idVendor": 0x04C5, "idProduct": 0x132B, "bInterfaceNumber": 0] as NSDictionary
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, matching, { refcon, iterator in
            guard let refcon else { return }
            Unmanaged<DeviceWatcher>.fromOpaque(refcon).takeUnretainedValue().drain(iterator, notify: true)
        }, refcon, &iterator)
        // Vorhandene Geräte abholen, sonst meldet IOKit keine weiteren. Beim Start verbindet
        // sich der Controller ohnehin selbst.
        if result == KERN_SUCCESS { drain(iterator, notify: false) }
    }

    deinit {
        continuation.finish()
        if iterator != 0 { IOObjectRelease(iterator) }
        if let port { IONotificationPortDestroy(port) }
    }

    private func drain(_ iterator: io_iterator_t, notify: Bool) {
        var found = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
            found = true
        }
        if found && notify { continuation.yield() }
    }
}
