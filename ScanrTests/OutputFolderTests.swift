import Foundation
import ScannerKit
import Testing
@testable import Scanr

@MainActor
struct OutputFolderTests {
    static func makeFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanr-ablage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func chosenFolderIsUsedSavedAndLeftClean() throws {
        let dir = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("2026-10-23 scan 04.pdf").path, contents: Data())
        let rig = Rig { _ in FakeOpener([.failure(.notFound)]) }
        let c = rig.controller()

        #expect(c.chooseOutputDirectory(dir) == nil)

        #expect(c.outputDirectory.path == dir.path)
        #expect(c.previewName(date: Self.date) == "2026-10-23 scan 05.pdf")
        // Die Probedatei für die Rechteabfrage ist wieder weg.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["2026-10-23 scan 04.pdf"])
        // Ein neuer Controller mit denselben Einstellungen nimmt den Ordner wieder.
        #expect(rig.controller().outputDirectory.path == dir.path)
    }

    @Test func unwritableFolderIsRejectedAndTheOldOneStays() throws {
        let dir = try Self.makeFolder()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        let rig = Rig { _ in FakeOpener([.failure(.notFound)]) }
        let c = rig.controller()
        let before = c.outputDirectory

        let error = c.chooseOutputDirectory(dir)

        #expect(error == "In „\(dir.lastPathComponent)“ kann Scanr nicht schreiben.")
        #expect(c.outputDirectory == before)
    }

    @Test func missingFolderStopsTheScanWithAMessage() async throws {
        let dir = try Self.makeFolder()
        let rig = Rig { clock in FakeOpener([.success(FakeTransport([.status(button: false)], clock: clock))]) }
        let c = rig.controller()
        #expect(c.chooseOutputDirectory(dir) == nil)
        try FileManager.default.removeItem(at: dir)
        _ = await c.step()
        #expect(c.canScan)

        c.scanNow()
        await c.scanTask?.value

        #expect(rig.jobs.profiles.isEmpty)
        #expect(rig.notifier.posted == [ResultMessage(
            title: "Scan nicht gestartet", body: "Ablage nicht gefunden: \(dir.path)", files: [])])
    }

    @Test func unwritableFolderStopsTheScanBeforeFeeding() async throws {
        let dir = try Self.makeFolder()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let rig = Rig { clock in FakeOpener([.success(FakeTransport([.status(button: false)], clock: clock))]) }
        let c = rig.controller()
        #expect(c.chooseOutputDirectory(dir) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        _ = await c.step()

        c.scanNow()
        await c.scanTask?.value

        #expect(rig.jobs.profiles.isEmpty)
        let expected = ResultMessage(title: "Scan nicht gestartet",
                                     body: "In „\(dir.lastPathComponent)“ kann Scanr nicht schreiben.", files: [])
        #expect(rig.notifier.posted == [expected])
        // Ohne erlaubte Mitteilungen steht das Ergebnis im Menü.
        #expect(c.lastMessage == expected)
    }

    @Test func scanGoesToTheChosenFolder() async throws {
        let dir = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rig = Rig { clock in FakeOpener([.success(FakeTransport([.status(button: true)], clock: clock))]) }
        let c = rig.controller()
        #expect(c.chooseOutputDirectory(dir) == nil)

        _ = await c.step()
        await c.scanTask?.value

        #expect(rig.jobs.dirs.map(\.path) == [dir.path])
    }

    static let date: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 23; c.hour = 12
        return Calendar(identifier: .gregorian).date(from: c)!
    }()
}
