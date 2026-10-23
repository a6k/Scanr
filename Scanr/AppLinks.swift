import Foundation

/// Adressen für Hilfe und Support. Die Oberfläche ist nur Deutsch, deshalb immer die deutschen Seiten.
enum AppLinks {
    static let help = URL(string: "https://comodin.com/projekte/scanr/hilfe/")!
    static let privacy = URL(string: "https://comodin.com/projekte/scanr/privacy")!
    static let sourceCode = URL(string: "https://github.com/a6k/Scanr")!
    /// Neueste Version auf GitHub. Scanr fragt nicht selbst nach (kein Netzwerkcode), der
    /// Knopf öffnet die Seite im Browser, die eigene Version steht im Reiter daneben.
    static let latestRelease = URL(string: "https://github.com/a6k/Scanr/releases/latest")!
    static let supportAddress = "support@comodin.com"
    static let support = URL(string: "mailto:\(supportAddress)")!

    /// „Version 0.4 (4)“ aus der Info.plist, damit die Versionsnummer nur dort steht.
    static var versionLine: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Version \(version) (\(build))"
    }

    /// Copyright und Lizenz aus der Info.plist (`NSHumanReadableCopyright`).
    static var copyright: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""
    }
}
