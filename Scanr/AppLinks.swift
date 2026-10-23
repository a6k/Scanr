import Foundation

/// Adressen für Hilfe und Support. Die Oberfläche ist nur Deutsch, deshalb immer die deutschen Seiten.
enum AppLinks {
    static let help = URL(string: "https://comodin.com/projekte/scanr/hilfe/")!
    static let privacy = URL(string: "https://comodin.com/projekte/scanr/privacy")!
    static let sourceCode = URL(string: "https://github.com/a6k/Scanr")!
    static let supportAddress = "support@comodin.com"
    static let support = URL(string: "mailto:\(supportAddress)")!

    /// „Scanr 0.2 (2)“ aus der Info.plist, damit die Versionsnummer nur dort steht.
    static var versionLine: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Scanr \(version) (\(build))"
    }
}
