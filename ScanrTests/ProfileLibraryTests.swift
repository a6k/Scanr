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
        // ergänzt und in die feste Reihenfolge der Startprofile gebracht
        #expect(c.profiles.map(\.id) == ["rechnungen", "auto", "foto"])
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

    @Test func addCopiesTheShownProfileUnderANewName() {
        let rig = Rig { _ in FakeOpener([.failure(.notFound)]) }
        let c = rig.controller()
        let id = c.addProfile(copying: "foto")
        let neu = c.profiles.first { $0.id == id }!
        #expect(neu.name == "Neues Profil")
        #expect(neu.dpi == ScanProfile.foto.dpi && neu.format == ScanProfile.foto.format)
        #expect(c.profiles.map(\.id).last == id)
        #expect(rig.controller().profiles.contains { $0.id == id })   // gespeichert
    }

    @Test func secondNewProfileGetsANumber() {
        let rig = Rig { _ in FakeOpener([.failure(.notFound)]) }
        let c = rig.controller()
        _ = c.addProfile(copying: "auto")
        let id = c.addProfile(copying: "auto")
        #expect(c.profiles.first { $0.id == id }?.name == "Neues Profil 2")
    }

    @Test func startProfilesCannotBeDeleted() {
        let rig = Rig { _ in FakeOpener([.failure(.notFound)]) }
        let c = rig.controller()
        c.deleteProfile("auto")
        #expect(c.profiles.contains { $0.id == "auto" })
        #expect(!c.canDelete("auto"))
    }

    @Test func deletingTheActiveProfileActivatesRechnungen() {
        let rig = Rig { _ in FakeOpener([.failure(.notFound)]) }
        let c = rig.controller()
        let id = c.addProfile(copying: "foto")
        c.selectProfile(id)
        #expect(c.canDelete(id))
        c.deleteProfile(id)
        #expect(!c.profiles.contains { $0.id == id })
        #expect(c.activeProfileID == "rechnungen")
        #expect(rig.controller().activeProfileID == "rechnungen")
    }

    @Test func renamedStartProfileKeepsItsNameOnRestore() {
        let rig = Rig { _ in FakeOpener([.failure(.notFound)]) }
        let c = rig.controller()
        var auto = ScanProfile.auto
        auto.name = "Briefe"
        auto.dpi = 600
        c.update(auto)
        c.restoreStartValues(of: "auto")
        let restored = c.profiles.first { $0.id == "auto" }!
        #expect(restored.name == "Briefe")
        #expect(restored.dpi == ScanProfile.auto.dpi)
    }

    @Test func startProfilesComeFirst() {
        var eigen = ScanProfile.auto
        eigen.id = "eigen"
        let ordered = ProfileLibrary.ordered([eigen, .foto, .auto, .rechnungen])
        #expect(ordered.map(\.id) == ["rechnungen", "auto", "foto", "eigen"])
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
