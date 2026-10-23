import Foundation
import ScannerKit
@testable import Scanr

/// Uhr, die nur weiterläuft, wenn ein Test oder der falsche Transport sie stellt.
final class FakeClock: PollClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Duration = .zero
    private var recorded: [Duration] = []
    /// Schlafphasen ab 10 s (Rückfall ohne Gerät) warten bis `fireLongSleep()` oder Abbruch.
    var holdLongSleeps = false
    private let longSleepGate = ArrivalSignal()

    func fireLongSleep() { longSleepGate.fire() }

    func now() -> Duration { lock.withLock { current } }
    func advance(_ d: Duration) { lock.withLock { current += d } }
    var sleeps: [Duration] { lock.withLock { recorded } }

    func sleep(for duration: Duration) async throws {
        if holdLongSleeps && duration >= .seconds(10) {
            lock.withLock { recorded.append(duration) }
            await longSleepGate.wait()
            try Task.checkCancellation()
            advance(duration)
            return
        }
        lock.withLock {
            recorded.append(duration)
            current += duration
        }
        try Task.checkCancellation()
        await Task.yield()
    }
}

/// Transport, der auf jeden Befehl die nächste vorbereitete Antwort gibt.
/// Jeder Befehl kostet `cost` auf der falschen Uhr.
final class FakeTransport: USBTransport, @unchecked Sendable {
    enum Reply { case status(button: Bool, coverOpen: Bool = false), error(ScannerError) }

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

    /// Befehl mit diesem Index (ab 0) hält an, bis `unblock()` kommt.
    var blockIndex: Int?
    private let gate = ArrivalSignal()
    func unblock() { gate.fire() }

    func command(_ cdb: [UInt8], dataOut: [UInt8]?, readLength: Int?, timeout: Duration) async throws -> [UInt8] {
        let (reply, index): (Reply, Int) = lock.withLock {
            sent.append(cdb)
            return (replies.isEmpty ? fallback : replies.removeFirst(), sent.count - 1)
        }
        if index == blockIndex { await gate.wait() }
        clock.advance(cost)
        switch reply {
        case .status(let button, let coverOpen):
            var bytes = [UInt8](repeating: 0, count: 12)
            if button { bytes[4] = 0x01 }
            if coverOpen { bytes[3] = 0x20 }
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
    private var startedDirs: [URL] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false
    var hold = false
    var result = ScanResult(files: [], pages: 0, error: nil)
    var cancelledResult = ScanResult(files: [], pages: 0, error: nil, cancelled: true)
    var pagesToReport = 0
    /// Nach den Seiten die Texterkennung melden.
    var reportRecognizing = false

    var profiles: [ScanProfile] { lock.withLock { started } }
    var dirs: [URL] { lock.withLock { startedDirs } }

    func release() {
        let conts = lock.withLock {
            released = true
            defer { waiting = [] }
            return waiting
        }
        conts.forEach { $0.resume() }
    }

    func run(_ transport: any USBTransport, _ profile: ScanProfile, _ namer: FileNamer, _ dir: URL,
             _ progress: @escaping @Sendable (ScanProgress) -> Void) async -> ScanResult {
        lock.withLock { started.append(profile); startedDirs.append(dir) }
        for n in stride(from: 1, through: pagesToReport, by: 1) { progress(.scanned(pages: n)) }
        if reportRecognizing { progress(.recognizing(page: 1, of: max(1, pagesToReport))) }
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
            if Task.isCancelled { return cancelledResult }
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
    let failureLog = Locked<[String]>([])
    var outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory())

    let cleanup: PreferencesCleanup

    init(opener: (FakeClock) -> FakeOpener) {
        let suite = PreferencesCleanup.temporarySuite()
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        cleanup = PreferencesCleanup(suite: suite)
        self.opener = opener(clock)
    }

    func controller() -> ScannerController {
        let opener = self.opener, jobs = self.jobs, failureLog = self.failureLog
        var environment = ScannerEnvironment(
            defaults: defaults,
            outputDirectory: outputDirectory,
            clock: clock,
            notifier: notifier,
            open: { try opener.open() },
            runJob: { try? await Task.sleep(for: .zero); return await jobs.run($0, $1, $2, $3, $4) })
        environment.logFailure = { detail in failureLog.withLock { $0.append(detail) } }
        return ScannerController(environment: environment)
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

/// Kleiner Behälter für Werte, die aus Rückrufen geändert werden.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func withLock<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&stored) } }
}

/// Einstellungen eines Tests liegen als absoluter Pfad im Temp-Ordner, nicht unter
/// `~/Library/Preferences`. Mit einem Suite-Namen blieb dort je Test eine Datei liegen, auch nach
/// `removePersistentDomain` (cfprefsd schreibt eine leere nach; 2026-10-23: über 300 Stück).
final class PreferencesCleanup: Sendable {
    let suite: String
    init(suite: String) { self.suite = suite }
    deinit { try? FileManager.default.removeItem(atPath: suite + ".plist") }

    static func temporarySuite() -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanr-tests-prefs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(UUID().uuidString).path
    }
}
