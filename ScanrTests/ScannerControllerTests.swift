import Foundation
import ScannerKit
import Testing
@testable import Scanr

@MainActor
struct ScannerControllerTests {
    /// GET HARDWARE STATUS.
    static let ghs: UInt8 = 0xC2

    @Test func buttonHeldOverThreePollsStartsExactlyOneJobWithActiveProfile() async {
        let rig = Rig { clock in
            FakeOpener([.success(FakeTransport(
                [.status(button: true), .status(button: true), .status(button: true)], clock: clock))])
        }
        rig.defaults.set("auto", forKey: "activeProfileID")
        let c = rig.controller()

        for _ in 0..<3 {
            _ = await c.step()
            await c.scanTask?.value
        }

        #expect(rig.jobs.profiles.map(\.id) == ["auto"])
    }

    @Test func releasingAndPressingAgainStartsASecondJob() async {
        let rig = Rig { clock in
            FakeOpener([.success(FakeTransport(
                [.status(button: true), .status(button: false), .status(button: true)], clock: clock))])
        }
        let c = rig.controller()

        for _ in 0..<3 {
            _ = await c.step()
            await c.scanTask?.value
        }

        #expect(rig.jobs.profiles.map(\.id) == ["rechnungen", "rechnungen"])
    }

    @Test func idlePollSleepsTheRestOfTheCycle() async {
        let rig = Rig { clock in FakeOpener([.success(FakeTransport([], clock: clock, cost: .milliseconds(200)))]) }
        let c = rig.controller()

        let next = await c.step()

        #expect(next == .poll(after: .milliseconds(300)))
        #expect(c.state == .ready)
    }

    @Test func slowPollStartsTheNextOneImmediately() async {
        let rig = Rig { clock in FakeOpener([.success(FakeTransport([], clock: clock, cost: .milliseconds(700)))]) }
        let c = rig.controller()

        #expect(await c.step() == .poll(after: .zero))
    }

    @Test func busyScannerShowsBusyAndWaitsTwoSeconds() async {
        let rig = Rig { clock in FakeOpener([.success(FakeTransport([.error(.busy)], clock: clock))]) }
        let c = rig.controller()

        #expect(await c.step() == .poll(after: .seconds(2)))
        #expect(c.state == .busy)

        #expect(await c.step() == .poll(after: .milliseconds(300)))
        #expect(c.state == .ready)
    }

    @Test func missingScannerWaitsForDeviceArrival() async {
        let rig = Rig { _ in FakeOpener([.failure(.notFound)]) }
        let c = rig.controller()

        #expect(await c.step() == .waitForDevice)
        #expect(c.state == .disconnected)
    }

    @Test func disconnectFromACommandReopensOnTheNextPoll() async {
        let rig = Rig { clock in
            FakeOpener([.success(FakeTransport([.error(.disconnected)], clock: clock)),
                        .success(FakeTransport([], clock: clock))])
        }
        let c = rig.controller()

        #expect(await c.step() == .poll(after: .seconds(2)))
        #expect(c.state == .disconnected)
        #expect(await c.step() == .poll(after: .milliseconds(300)))
        #expect(c.state == .ready)
        #expect(rig.opener.calls == 2)
    }

    @Test func disconnectFromACommandWithoutDeviceWaitsForArrival() async {
        let rig = Rig { clock in
            FakeOpener([.success(FakeTransport([.error(.disconnected)], clock: clock)), .failure(.notFound)])
        }
        let c = rig.controller()

        #expect(await c.step() == .poll(after: .seconds(2)))
        #expect(await c.step() == .waitForDevice)
        #expect(c.state == .disconnected)
        #expect(rig.opener.calls == 2)
    }

    @Test func deviceArrivalTriggersAReconnect() async {
        let rig = Rig { clock in FakeOpener([.failure(.notFound), .success(FakeTransport([], clock: clock))]) }
        rig.clock.holdLongSleeps = true
        let c = rig.controller()
        let (arrivals, arrive) = AsyncStream.makeStream(of: Void.self)
        let loop = Task { await c.run(arrivals: arrivals) }

        #expect(await eventually { rig.opener.calls == 1 && c.state == .disconnected })
        arrive.yield()
        #expect(await eventually { c.state == .ready })
        #expect(rig.opener.calls == 2)
        loop.cancel()
        await loop.value
    }

    @Test func withoutArrivalOpenIsTriedAfterFifteenSeconds() async {
        let rig = Rig { clock in FakeOpener([.failure(.notFound), .success(FakeTransport([], clock: clock))]) }
        rig.clock.holdLongSleeps = true
        let c = rig.controller()
        let (arrivals, _) = AsyncStream.makeStream(of: Void.self)
        let loop = Task { await c.run(arrivals: arrivals) }

        #expect(await eventually { rig.clock.sleeps.contains(.seconds(15)) })
        #expect(rig.opener.calls == 1)
        #expect(c.state == .disconnected)
        rig.clock.fireLongSleep()
        #expect(await eventually { c.state == .ready })
        #expect(rig.opener.calls == 2)
        loop.cancel()
        await loop.value
    }

    @Test func menuScanDuringAPollKeepsTheConnection() async {
        let clock = FakeClock()
        let transport = FakeTransport([.status(button: false), .error(.disconnected)], clock: clock)
        transport.blockIndex = 1
        let rig = Rig { _ in FakeOpener([.success(transport)]) }
        rig.jobs.hold = true
        let c = rig.controller()
        _ = await c.step()

        let poll = Task { await c.step() }
        #expect(await eventually { transport.commands.count == 2 })
        c.scanNow()
        #expect(c.isScanning)
        transport.unblock()
        _ = await poll.value

        #expect(c.state == .scanning(page: 0))
        #expect(rig.opener.calls == 1)
        rig.jobs.release()
        await c.scanTask?.value
        #expect(c.state == .ready)
        _ = await c.step()
        #expect(c.state == .ready)
        #expect(rig.opener.calls == 1)
    }

    @Test func protocolErrorShowsAShortText() async {
        let rig = Rig { clock in
            FakeOpener([.success(FakeTransport([.error(.protocolViolation("Error Domain=NSOSStatus Code=-536870212"))],
                                               clock: clock))])
        }
        let c = rig.controller()

        #expect(await c.step() == .poll(after: .seconds(2)))
        #expect(c.state == .failed("Übertragungsfehler, bitte erneut versuchen"))
    }

    @Test func scanSnapHomeHoldingTheDeviceIsReported() async {
        let rig = Rig { _ in FakeOpener([.failure(.deviceHeldByOtherProcess)]) }
        let c = rig.controller()

        #expect(await c.step() == .poll(after: .seconds(5)))
        #expect(c.state == .heldByScanSnapHome)
    }

    @Test func idleControllerSendsOnlyHardwareStatus() async {
        let transport = FakeTransport([], clock: FakeClock())
        let rig = Rig { _ in FakeOpener([.success(transport)]) }
        let c = rig.controller()

        for _ in 0..<5 { _ = await c.step() }

        #expect(transport.commands.count == 5)
        #expect(transport.commands.allSatisfy { $0.first == Self.ghs })
    }

    @Test func noPollingWhileAScanRuns() async {
        let transport = FakeTransport([.status(button: true)], clock: FakeClock())
        let rig = Rig { _ in FakeOpener([.success(transport)]) }
        rig.jobs.hold = true
        let c = rig.controller()
        let (arrivals, _) = AsyncStream.makeStream(of: Void.self)
        let loop = Task { await c.run(arrivals: arrivals) }

        #expect(await eventually { c.isScanning })
        let pollsAtStart = transport.commands.count
        for _ in 0..<50 { await Task.yield() }
        #expect(transport.commands.count == pollsAtStart)

        rig.jobs.release()
        #expect(await eventually { transport.commands.count > pollsAtStart })
        loop.cancel()
        await loop.value
    }

    @Test func progressShowsThePageNumber() async {
        let rig = Rig { clock in FakeOpener([.success(FakeTransport([.status(button: true)], clock: clock))]) }
        rig.jobs.hold = true
        rig.jobs.pagesToReport = 3
        let c = rig.controller()

        _ = await c.step()

        #expect(await eventually { c.state == .scanning(page: 3) })
        rig.jobs.release()
        await c.scanTask?.value
        #expect(c.state == .ready)
    }

    @Test func textRecognitionIsShownAndCanBeCancelled() async {
        let rig = Rig { clock in FakeOpener([.success(FakeTransport([.status(button: true)], clock: clock))]) }
        rig.jobs.hold = true
        rig.jobs.pagesToReport = 2
        rig.jobs.reportRecognizing = true
        let pdf = URL(fileURLWithPath: "/tmp/2026-10-22 scan 01.pdf")
        rig.jobs.cancelledResult = ScanResult(files: [pdf], pages: 2, sheets: 2, error: nil, cancelled: true)
        let c = rig.controller()

        _ = await c.step()

        #expect(await eventually { c.state == .recognizing })
        #expect(c.state.text == "Texterkennung …")
        #expect(c.isScanning, "Menü zeigt weiter „Scan abbrechen“")
        c.cancelScan()
        await c.scanTask?.value
        #expect(c.state == .ready)
        #expect(rig.notifier.posted.map(\.body) == ["Abgebrochen, 2 Seiten gespeichert in 2026-10-22 scan 01.pdf"])
    }

    @Test func finishedScanPostsTheFileName() async {
        let rig = Rig { clock in FakeOpener([.success(FakeTransport([.status(button: true)], clock: clock))]) }
        let file = URL(fileURLWithPath: "/tmp/2026-10-22 scan 01.pdf")
        rig.jobs.result = ScanResult(files: [file], pages: 2, error: nil)
        let c = rig.controller()

        _ = await c.step()
        await c.scanTask?.value

        #expect(rig.notifier.posted == [ResultMessage(title: "Scan gespeichert", body: "2026-10-22 scan 01.pdf", files: [file])])
    }

    @Test func cancelStopsTheJobAndReportsIt() async {
        let rig = Rig { clock in FakeOpener([.success(FakeTransport([], clock: clock))]) }
        rig.jobs.hold = true
        let c = rig.controller()
        _ = await c.step()

        c.scanNow()
        #expect(c.isScanning)
        c.cancelScan()
        await c.scanTask?.value

        #expect(!c.isScanning)
        #expect(rig.notifier.posted.map(\.body) == ["Abgebrochen, nichts gespeichert"])
    }

    @Test func scanNowNeedsAReadyScanner() async {
        let rig = Rig { _ in FakeOpener([.failure(.notFound)]) }
        let c = rig.controller()
        _ = await c.step()

        c.scanNow()

        #expect(!c.isScanning)
        #expect(rig.jobs.profiles.isEmpty)
    }

    @Test func disconnectDuringScanLeadsToReconnect() async {
        let rig = Rig { clock in
            FakeOpener([.success(FakeTransport([.status(button: true)], clock: clock)), .failure(.notFound)])
        }
        rig.jobs.result = ScanResult(files: [], pages: 0, error: .scanner(.disconnected), scannerError: .disconnected)
        let c = rig.controller()

        _ = await c.step()
        await c.scanTask?.value
        #expect(await c.step() == .waitForDevice)
        #expect(c.state == .disconnected)
        #expect(rig.opener.calls == 2)
    }

    @Test func startRemovesStaleTempFilesFromTheOutputFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanr-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        let old = ".scanr-\(Int(now.timeIntervalSince1970) - 7200)-\(UUID().uuidString).tmp"
        let fresh = ".scanr-\(Int(now.timeIntervalSince1970) - 60)-\(UUID().uuidString).tmp"
        for name in [old, fresh, "scan 01.pdf"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
        }
        var rig = Rig { _ in FakeOpener([.failure(.notFound)]) }
        rig.outputDirectory = dir
        let c = rig.controller()

        #expect(c.removeStaleTemps(now: now) == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == [fresh, "scan 01.pdf"].sorted())
    }

    @Test func openCoverIsShownBeforeScanning() async {
        let rig = Rig { clock in
            FakeOpener([.success(FakeTransport([.status(button: false, coverOpen: true), .status(button: false)],
                                               clock: clock))])
        }
        let c = rig.controller()

        _ = await c.step()
        #expect(c.state == .coverOpen)
        #expect(c.state.text == "Klappe offen, bitte schließen")
        #expect(!c.canScan)

        _ = await c.step()
        #expect(c.state == .ready)
    }

    @Test func buttonWithOpenCoverStartsNoJob() async {
        let rig = Rig { clock in
            FakeOpener([.success(FakeTransport([.status(button: true, coverOpen: true)], clock: clock))])
        }
        let c = rig.controller()

        _ = await c.step()

        #expect(!c.isScanning)
        #expect(rig.jobs.profiles.isEmpty)
        #expect(rig.notifier.posted == [ResultMessage(title: "Scan nicht gestartet",
                                                      body: "Klappe offen, bitte schließen", files: [])])
    }

    @Test func persistentOpenFailureIsLoggedOnce() async {
        let missing = ScannerError.protocolViolation("Interface ohne Bulk-Endpunkte")
        let rig = Rig { _ in FakeOpener([.failure(missing)]) }
        let c = rig.controller()

        for _ in 0..<5 { #expect(await c.step() == .poll(after: .seconds(2))) }

        #expect(rig.failureLog.value.count == 1)
    }

    @Test func failureIsLoggedAgainAfterItChangesOrClears() async {
        let rig = Rig { clock in
            FakeOpener([.failure(.protocolViolation("A")), .failure(.protocolViolation("A")),
                        .failure(.protocolViolation("B")),
                        .success(FakeTransport([.status(button: false), .error(.protocolViolation("B"))], clock: clock))])
        }
        let c = rig.controller()

        _ = await c.step()   // A
        _ = await c.step()   // A, schon protokolliert
        _ = await c.step()   // B
        _ = await c.step()   // geöffnet, Status in Ordnung
        #expect(c.state == .ready)
        _ = await c.step()   // B nach einer guten Abfrage: wieder protokolliert

        #expect(rig.failureLog.value == [
            String(describing: ScannerError.protocolViolation("A")),
            String(describing: ScannerError.protocolViolation("B")),
            String(describing: ScannerError.protocolViolation("B")),
        ])
    }
}
