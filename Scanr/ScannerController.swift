import Foundation
import Observation
import os
import ScannerKit

/// Zeitquelle der Abfrageschleife. Tests setzen eine Uhr ein, die nur auf Anweisung läuft.
nonisolated protocol PollClock: Sendable {
    /// Vergangene Zeit seit einem festen Ursprung.
    func now() -> Duration
    func sleep(for duration: Duration) async throws
}

nonisolated struct SystemClock: PollClock {
    private let origin = ContinuousClock.now
    func now() -> Duration { ContinuousClock.now - origin }
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

/// Zeigt das Ergebnis eines Durchlaufs an.
protocol ResultNotifier {
    func post(_ message: ResultMessage)
}

/// Alles, was der Controller von außen braucht. Die App setzt Gerät, Uhr und Mitteilungen
/// ein, Tests ihre Attrappen.
struct ScannerEnvironment {
    typealias JobRunner = @Sendable (
        _ transport: any USBTransport, _ profile: ScanProfile, _ namer: FileNamer, _ outputDirectory: URL,
        _ progress: @escaping @Sendable (Int) -> Void
    ) async -> ScanResult

    var defaults: UserDefaults
    var outputDirectory: URL
    var clock: any PollClock
    var notifier: any ResultNotifier
    var open: @Sendable () throws -> any USBTransport
    var runJob: JobRunner

    /// Echter Scanner über USB, Ausgabe auf den Schreibtisch.
    static func live(notifier: any ResultNotifier) -> ScannerEnvironment {
        ScannerEnvironment(
            defaults: .standard,
            outputDirectory: FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0],
            clock: SystemClock(),
            notifier: notifier,
            open: { try IOUSBHostTransport.open() },
            runJob: { transport, profile, namer, dir, progress in
                await ScanJob(transport: transport, profile: profile, namer: namer, outputDir: dir)
                    .run(progress: progress)
            })
    }
}

/// Hält die Verbindung zum Scanner, fragt im Leerlauf die Scan-Taste ab und startet Durchläufe.
@Observable
final class ScannerController {
    enum State: Equatable {
        case disconnected
        case heldByScanSnapHome
        case ready
        case busy
        case scanning(page: Int)
        case failed(String)
    }

    /// Was die Abfrageschleife als Nächstes tut.
    enum Next: Equatable {
        case poll(after: Duration)
        case waitForDevice
    }

    /// Takt der Abfrage, gemessen vom Beginn einer Abfrage zum Beginn der nächsten.
    static let pollInterval: Duration = .milliseconds(500)
    /// Pause, wenn der Scanner beschäftigt ist (etwa ein Scan per WLAN).
    static let busyDelay: Duration = .seconds(2)
    /// Pause nach einem Fehler, bevor die Verbindung neu aufgebaut wird.
    static let failureDelay: Duration = .seconds(2)
    /// Abstand der Versuche, solange ein anderes Programm den Scanner hält.
    static let heldDelay: Duration = .seconds(5)
    /// Ohne Gerät: so lange auf die Ankunftsmeldung warten, dann trotzdem öffnen. Öffnen ohne
    /// Gerät ist nur eine Suche in der IORegistry, es geht nichts über USB.
    static let reconnectFallback: Duration = .seconds(15)
    nonisolated static let log = Logger(subsystem: "app.comodin.Scanr", category: "scanner")
    static let patternKey = "fileNamePattern"
    static let defaultPattern = FileNamer().pattern

    private(set) var state: State = .disconnected
    private(set) var profiles: [ScanProfile]
    private(set) var activeProfileID: String
    var fileNamePattern: String {
        didSet { environment.defaults.set(fileNamePattern, forKey: Self.patternKey) }
    }

    @ObservationIgnored private let environment: ScannerEnvironment
    @ObservationIgnored private let store: ProfileStore
    @ObservationIgnored private var transport: (any USBTransport)?
    /// Taste bei der letzten erfolgreichen Abfrage gedrückt. Nur der Wechsel von nicht
    /// gedrückt auf gedrückt startet einen Durchlauf.
    @ObservationIgnored private var buttonWasDown = false
    private(set) var scanTask: Task<Void, Never>?

    init(environment: ScannerEnvironment) {
        self.environment = environment
        store = ProfileStore(defaults: environment.defaults)
        let profiles = ProfileLibrary.completed(store.load())
        self.profiles = profiles
        activeProfileID = ProfileLibrary.active(id: store.activeProfileID, in: profiles).id
        fileNamePattern = environment.defaults.string(forKey: Self.patternKey) ?? Self.defaultPattern
    }

    // MARK: Profile

    /// Das Profil, mit dem der nächste Scan startet.
    var profile: ScanProfile {
        get { ProfileLibrary.active(id: activeProfileID, in: profiles) }
        set { update(newValue) }
    }

    func selectProfile(_ id: String) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeProfileID = id
        store.activeProfileID = id
    }

    /// Ersetzt das Profil mit derselben id und speichert.
    func update(_ profile: ScanProfile) {
        guard let i = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[i] = profile
        store.save(profiles)
    }

    func restoreStartValues(of id: String) {
        guard let start = ProfileLibrary.startValue(of: id) else { return }
        update(start)
    }

    /// Ein leeres Muster ergäbe nur die Nummer, dann gilt das Standardmuster.
    var namer: FileNamer {
        let pattern = fileNamePattern.trimmingCharacters(in: .whitespaces)
        return FileNamer(pattern: pattern.isEmpty ? Self.defaultPattern : fileNamePattern)
    }

    /// Name, den der nächste Scan mit dem aktiven Profil bekäme.
    func previewName(date: Date = Date()) -> String {
        let ext = profile.format == .pdf ? "pdf" : "jpg"
        return namer.nextURL(in: environment.outputDirectory, date: date, profile: profile, ext: ext).lastPathComponent
    }

    // MARK: Aufräumen

    /// Löscht Temp-Dateien eines abgestürzten Laufs im Ausgabeordner (älter als eine Stunde).
    @discardableResult
    func removeStaleTemps(now: Date = Date()) -> Int {
        OutputFile.removeStaleTemps(in: environment.outputDirectory, now: now)
    }

    // MARK: Scannen

    var isScanning: Bool { scanTask != nil }

    var canScan: Bool { state == .ready && scanTask == nil && transport != nil }

    func scanNow() {
        guard canScan, let transport else { return }
        let profile = self.profile, namer = self.namer, dir = environment.outputDirectory
        let runJob = environment.runJob
        state = .scanning(page: 0)
        scanTask = Task {
            let result = await runJob(transport, profile, namer, dir) { page in
                Task { @MainActor in self.showProgress(page) }
            }
            finish(result)
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    private func showProgress(_ page: Int) {
        guard case .scanning(let shown) = state, page > shown else { return }
        state = .scanning(page: page)
    }

    private func finish(_ result: ScanResult) {
        if let error = result.error {
            Self.log.notice("Durchlauf beendet mit \(String(describing: error), privacy: .public)")
        }
        if result.scannerError == .disconnected {
            transport = nil
            buttonWasDown = false
            state = .disconnected
        } else {
            state = .ready
        }
        scanTask = nil
        environment.notifier.post(ResultMessage(result))
    }

    // MARK: Abfrage

    /// Eine Runde: bei Bedarf verbinden, dann den Gerätestatus abfragen.
    func step() async -> Next {
        let start = environment.clock.now()
        let transport: any USBTransport
        switch self.transport.map(Opening.opened) ?? connect() {
        case .opened(let t): transport = t
        case .failed(let next): return next
        }
        do {
            let status = try await transport.hardwareStatus()
            // Während der Abfrage wurde per Menü ein Scan gestartet: Ergebnis verwerfen.
            guard scanTask == nil else { return .poll(after: Self.pollInterval) }
            state = .ready
            let pressed = status.scanButton && !buttonWasDown
            buttonWasDown = status.scanButton
            if pressed { scanNow() }
        } catch {
            guard scanTask == nil else { return .poll(after: Self.pollInterval) }
            return commandFailed(error as? ScannerError ?? .protocolViolation("\(error)"))
        }
        let elapsed = environment.clock.now() - start
        return .poll(after: max(.zero, Self.pollInterval - elapsed))
    }

    private enum Opening {
        case opened(any USBTransport)
        case failed(Next)
    }

    private func connect() -> Opening {
        do {
            let opened = try environment.open()
            transport = opened
            buttonWasDown = false
            return .opened(opened)
        } catch {
            return .failed(openFailed(error as? ScannerError ?? .protocolViolation("\(error)")))
        }
    }

    /// Öffnen gescheitert. Nur ohne Gerät in der IORegistry wird auf das Anstecken gewartet.
    private func openFailed(_ error: ScannerError) -> Next {
        switch error {
        case .notFound, .disconnected:
            drop(.disconnected)
            return .waitForDevice
        default:
            return commandFailed(error)
        }
    }

    /// Ein Befehl ist gescheitert. Der Transport wird verworfen und auf dem normalen Weg neu
    /// geöffnet: ein Interface, das in der IORegistry bleibt, meldet keine neue Ankunft.
    private func commandFailed(_ error: ScannerError) -> Next {
        switch error {
        case .busy:
            state = .busy
            return .poll(after: Self.busyDelay)
        case .notFound, .disconnected:
            drop(.disconnected)
            return .poll(after: Self.failureDelay)
        case .deviceHeldByOtherProcess:
            drop(.heldByScanSnapHome)
            return .poll(after: Self.heldDelay)
        default:
            Self.log.error("Scannerfehler: \(String(describing: error), privacy: .public)")
            drop(.failed(ResultMessage.describe(error)))
            return .poll(after: Self.failureDelay)
        }
    }

    private func drop(_ newState: State) {
        transport = nil
        buttonWasDown = false
        state = newState
    }

    /// Abfrageschleife bis zum Abbruch. Während eines Scans ruht sie. Ohne Gerät wartet sie auf
    /// die nächste Meldung in `arrivals` (Gerät angesteckt), höchstens `reconnectFallback` lang.
    func run(arrivals: AsyncStream<Void>) async {
        let signal = ArrivalSignal()
        let feeder = Task {
            for await _ in arrivals { signal.fire() }
        }
        defer { feeder.cancel() }
        while !Task.isCancelled {
            if let scanTask {
                await scanTask.value
                continue
            }
            switch await step() {
            case .poll(let delay):
                do { try await environment.clock.sleep(for: delay) } catch { return }
            case .waitForDevice:
                guard await waitForDevice(signal) else { return }
            }
        }
    }

    /// Wartet auf das Anstecken oder auf den Ablauf von `reconnectFallback`. Falsch heißt:
    /// die Schleife wurde abgebrochen.
    private func waitForDevice(_ signal: ArrivalSignal) async -> Bool {
        let clock = environment.clock
        let fallback = Self.reconnectFallback
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await signal.wait()
                return !Task.isCancelled
            }
            group.addTask {
                do {
                    try await clock.sleep(for: fallback)
                    return true
                } catch {
                    return false
                }
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}

/// Meldung „Gerät angesteckt“, die genau einen Wartenden weckt. Kommt sie, während niemand
/// wartet, bleibt sie für den nächsten liegen. Abbruch weckt den Wartenden ohne Meldung.
nonisolated final class ArrivalSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    private var waiter: (id: UUID, continuation: CheckedContinuation<Void, Never>)?
    private var cancelledIDs: Set<UUID> = []

    func fire() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            guard let waiter else {
                pending = true
                return nil
            }
            self.waiter = nil
            return waiter.continuation
        }
        continuation?.resume()
    }

    func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    if pending {
                        pending = false
                        return true
                    }
                    if cancelledIDs.remove(id) != nil { return true }
                    waiter = (id, continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
                if let waiter, waiter.id == id {
                    self.waiter = nil
                    return waiter.continuation
                }
                cancelledIDs.insert(id)
                return nil
            }
            continuation?.resume()
        }
    }
}
