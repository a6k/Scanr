import Foundation
import ScannerKit
@testable import Scanr

/// Uhr, die nur weiterläuft, wenn ein Test oder der falsche Transport sie stellt.
final class FakeClock: PollClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Duration = .zero
    private var recorded: [Duration] = []
    /// Nach so vielen Schlafphasen endet die Schleife (CancellationError).
    var sleepLimit = Int.max

    func now() -> Duration { lock.withLock { current } }
    func advance(_ d: Duration) { lock.withLock { current += d } }
    var sleeps: [Duration] { lock.withLock { recorded } }

    func sleep(for duration: Duration) async throws {
        let stop = lock.withLock {
            recorded.append(duration)
            current += duration
            return recorded.count > sleepLimit
        }
        if stop { throw CancellationError() }
        await Task.yield()
    }
}

/// Transport, der auf jeden Befehl die nächste vorbereitete Antwort gibt.
/// Jeder Befehl kostet `cost` auf der falschen Uhr.
final class FakeTransport: USBTransport, @unchecked Sendable {
    enum Reply { case status(button: Bool), error(ScannerError) }

    private let lock = NSLock()
    private var replies: [Reply]
    private var fallback: Reply
    private var sent: [[UInt8]] = []
    let clock: FakeClock
    let cost: Duration

    init(_ replies: [Reply], then fallback: Reply = .status(button: false), clock: FakeClock,
         cost: Duration = .milliseconds(200)) {
        self.replies = replies
        self.fallback = fallback
        self.clock = clock
        self.cost = cost
    }

    var commands: [[UInt8]] { lock.withLock { sent } }

    func command(_ cdb: [UInt8], dataOut: [UInt8]?, readLength: Int?, timeout: Duration) async throws -> [UInt8] {
        let reply: Reply = lock.withLock {
            sent.append(cdb)
            return replies.isEmpty ? fallback : replies.removeFirst()
        }
        clock.advance(cost)
        switch reply {
        case .status(let button):
            var bytes = [UInt8](repeating: 0, count: 12)
            if button { bytes[4] = 0x01 }
            return bytes
        case .error(let e):
            throw e
        }
    }
}

/// Öffnet nacheinander die vorbereiteten Ergebnisse, danach immer das letzte.
final class FakeOpener: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<FakeTransport, ScannerError>]
    private var count = 0

    init(_ results: [Result<FakeTransport, ScannerError>]) { self.results = results }

    var calls: Int { lock.withLock { count } }

    func open() throws -> any USBTransport {
        let r = lock.withLock {
            count += 1
            return results.count > 1 ? results.removeFirst() : results[0]
        }
        return try r.get()
    }
}

/// Merkt sich die gestarteten Durchläufe. Mit `hold` wartet jeder Durchlauf, bis der Test
/// `release()` ruft oder der Durchlauf abgebrochen wird.
final class FakeJobs: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [ScanProfile] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false
    var hold = false
    var result = ScanResult(files: [], pages: 0, error: nil)
    var pagesToReport = 0

    var profiles: [ScanProfile] { lock.withLock { started } }

    func release() {
        let conts = lock.withLock {
            released = true
            defer { waiting = [] }
            return waiting
        }
        conts.forEach { $0.resume() }
    }

    func run(_ transport: any USBTransport, _ profile: ScanProfile, _ namer: FileNamer, _ dir: URL,
             _ progress: @escaping @Sendable (Int) -> Void) async -> ScanResult {
        lock.withLock { started.append(profile) }
        for n in stride(from: 1, through: pagesToReport, by: 1) { progress(n) }
        if hold {
            await withTaskCancellationHandler {
                await withCheckedContinuation { cont in
                    let resumeNow = lock.withLock {
                        if released || Task.isCancelled { return true }
                        waiting.append(cont)
                        return false
                    }
                    if resumeNow { cont.resume() }
                }
            } onCancel: {
                self.release()
            }
            if Task.isCancelled { return ScanResult(files: [], pages: 0, error: nil, cancelled: true) }
        }
        return result
    }
}

@MainActor
final class FakeNotifier: ResultNotifier {
    var posted: [ResultMessage] = []
    func post(_ message: ResultMessage) { posted.append(message) }
}

@MainActor
struct Rig {
    let clock = FakeClock()
    let jobs = FakeJobs()
    let notifier = FakeNotifier()
    let defaults: UserDefaults
    let opener: FakeOpener

    init(opener: (FakeClock) -> FakeOpener) {
        let suite = "ScanrTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        self.opener = opener(clock)
    }

    func controller() -> ScannerController {
        let opener = self.opener, jobs = self.jobs
        return ScannerController(environment: ScannerEnvironment(
            defaults: defaults,
            outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            clock: clock,
            notifier: notifier,
            open: { try opener.open() },
            runJob: { try? await Task.sleep(for: .zero); return await jobs.run($0, $1, $2, $3, $4) }))
    }
}

/// Wartet (mit Task.yield), bis die Bedingung erfüllt ist; nach `tries` Runden falsch.
@MainActor
func eventually(tries: Int = 2000, _ condition: () -> Bool) async -> Bool {
    for _ in 0..<tries {
        if condition() { return true }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}
