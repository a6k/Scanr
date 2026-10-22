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

    @Test func disconnectDuringPollDropsTheTransportAndWaits() async {
        let rig = Rig { clock in
            FakeOpener([.success(FakeTransport([.error(.disconnected)], clock: clock)), .failure(.notFound)])
        }
        let c = rig.controller()

        #expect(await c.step() == .waitForDevice)
        #expect(c.state == .disconnected)
        #expect(await c.step() == .waitForDevice)
        #expect(rig.opener.calls == 2)
    }

    @Test func deviceArrivalTriggersAReconnect() async {
        let rig = Rig { clock in FakeOpener([.failure(.notFound), .success(FakeTransport([], clock: clock))]) }
        let c = rig.controller()
        let (arrivals, arrive) = AsyncStream.makeStream(of: Void.self)
        rig.clock.sleepLimit = 3
        let loop = Task { await c.run(arrivals: arrivals) }

        #expect(await eventually { rig.opener.calls == 1 && c.state == .disconnected })
        arrive.yield()
        #expect(await eventually { c.state == .ready })
        #expect(rig.opener.calls == 2)
        loop.cancel()
        await loop.value
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
}
