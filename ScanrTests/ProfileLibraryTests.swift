import Foundation
import ScannerKit
import Testing
@testable import Scanr

@MainActor
struct ProfileLibraryTests {
    @Test func activeProfileByID() {
        #expect(ProfileLibrary.active(id: "foto", in: [.rechnungen, .auto, .foto]).id == "foto")
    }

    @Test func unknownActiveIDFallsBackToRechnungen() {
        #expect(ProfileLibrary.active(id: "weg", in: [.auto, .rechnungen, .foto]).id == "rechnungen")
    }

    @Test func withoutRechnungenTheFirstProfileWins() {
        #expect(ProfileLibrary.active(id: "weg", in: [.foto, .auto]).id == "foto")
    }

    @Test func missingStartProfilesAreAppended() {
        var auto = ScanProfile.auto
        auto.dpi = 600
        let result = ProfileLibrary.completed([auto, .foto])
        #expect(result.map(\.id) == ["auto", "foto", "rechnungen"])
        #expect(result[0].dpi == 600)
    }

    @Test func completeListStaysAsIs() {
        #expect(ProfileLibrary.completed([.foto, .rechnungen, .auto]).map(\.id) == ["foto", "rechnungen", "auto"])
    }

    @Test func controllerUsesRechnungenForAnUnknownStoredID() {
        let rig = Rig { _ in FakeOpener([.failure(.notFound)]) }
        rig.defaults.set("gibtsnicht", forKey: "activeProfileID")
        let c = rig.controller()
        #expect(c.profile.id == "rechnungen")
        #expect(c.activeProfileID == "rechnungen")
    }

    @Test func controllerAddsRechnungenToAnOldStoredList() throws {
        let rig = Rig { _ in FakeOpener([.failure(.notFound)]) }
        ProfileStore(defaults: rig.defaults).save([.auto, .foto])
        let c = rig.controller()
        #expect(c.profiles.map(\.id) == ["auto", "foto", "rechnungen"])
        #expect(c.profile.id == "rechnungen")
    }

    @Test func changingTheProfileIsSaved() {
        let rig = Rig { _ in FakeOpener([.failure(.notFound)]) }
        let c = rig.controller()
        var foto = c.profiles.first { $0.id == "foto" }!
        foto.dpi = 300
        c.update(foto)
        c.selectProfile("foto")

        let again = rig.controller()
        #expect(again.profile.id == "foto")
        #expect(again.profile.dpi == 300)
    }

    @Test func restoreStartValues() {
        let rig = Rig { _ in FakeOpener([.failure(.notFound)]) }
        let c = rig.controller()
        var auto = ScanProfile.auto
        auto.duplex = false
        c.update(auto)
        c.restoreStartValues(of: "auto")
        #expect(c.profiles.first { $0.id == "auto" } == .auto)
    }

    @Test func jpegQualityOnlyWhereItMatters() {
        #expect(ScanProfile.foto.showsJPEGQuality)            // JPG
        #expect(ScanProfile.auto.showsJPEGQuality)            // PDF, Farbe möglich
        #expect(!ScanProfile.rechnungen.showsJPEGQuality)     // PDF, nur Schwarzweiß
        var gray = ScanProfile.rechnungen
        gray.colorMode = .gray
        #expect(gray.showsJPEGQuality)
    }
}
