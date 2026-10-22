import Foundation

/// Bildet Dateinamen aus einem Muster. Platzhalter: `{datum}` (yyyy-MM-dd), `{zeit}` (HH-mm),
/// `{profil}` (Profilname), `{nr}` (zweistellig, ab 100 dreistellig). Unbekannte Platzhalter
/// bleiben wörtlich stehen. Fehlt `{nr}`, wird ` {nr}` angehängt, sonst überschrieben
/// der zweite Scan des Tages den ersten.
public struct FileNamer: Sendable {
    public var pattern: String
    /// Zeitzone für `{datum}` und `{zeit}`; der Kalender ist immer gregorianisch,
    /// damit die Namen nicht von den Systemeinstellungen (etwa buddhistischer Kalender) abhängen.
    public var timeZone: TimeZone

    public init(pattern: String = "{datum} scan {nr}", timeZone: TimeZone = .current) {
        self.pattern = pattern
        self.timeZone = timeZone
    }

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }

    private enum Token {
        case literal(String)
        case datum, zeit, profil, nr
    }

    private func tokens() -> [Token] {
        var result: [Token] = []
        var literal = ""
        var rest = Substring(pattern)
        while let open = rest.firstIndex(of: "{") {
            literal += rest[..<open]
            let tail = rest[open...]
            if let close = tail.firstIndex(of: "}") {
                let name = tail[tail.index(after: open)..<close]
                let token: Token? = switch name {
                case "datum": .datum
                case "zeit": .zeit
                case "profil": .profil
                case "nr": .nr
                default: nil
                }
                if let token {
                    if !literal.isEmpty { result.append(.literal(literal)); literal = "" }
                    result.append(token)
                    rest = tail[tail.index(after: close)...]
                    continue
                }
            }
            literal += "{"
            rest = tail.dropFirst()
        }
        literal += rest
        if !literal.isEmpty { result.append(.literal(literal)) }
        if !result.contains(where: { if case .nr = $0 { true } else { false } }) {
            result.append(.literal(" "))
            result.append(.nr)
        }
        return result
    }

    private func format(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = format
        return f.string(from: date)
    }

    /// `/` trennt Pfade, `:` ist im Finder ein Pfadtrenner.
    private func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    /// Nächster freier Name: die Nummer über der höchsten, die im Ordner zu diesem Muster passt
    /// (Groß- und Kleinschreibung egal). Rechnet nur einen Namen aus und legt nichts an. Wer
    /// schreibt, legt die Datei an, bevor er den nächsten Namen erfragt, und holt bei
    /// `OutputError.destinationExists` einen neuen Namen.
    public func nextURL(in dir: URL, date: Date, profile: ScanProfile, ext: String) -> URL {
        let tokens = tokens()
        // Regulärer Ausdruck, der Dateien dieses Tages erkennt (beliebige Endung).
        var regex = "^"
        for token in tokens {
            switch token {
            case .literal(let s): regex += NSRegularExpression.escapedPattern(for: clean(s))
            case .datum: regex += NSRegularExpression.escapedPattern(for: format(date, "yyyy-MM-dd"))
            case .zeit: regex += "[0-9]{2}-[0-9]{2}"
            case .profil: regex += NSRegularExpression.escapedPattern(for: clean(profile.name))
            case .nr: regex += "([0-9]{2,})"
            }
        }
        regex += "\\.[^./]+$"

        var highest = 0
        if let re = try? NSRegularExpression(pattern: regex, options: .caseInsensitive),
           let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        {
            for name in names {
                let range = NSRange(name.startIndex..., in: name)
                guard let m = re.firstMatch(in: name, range: range), m.numberOfRanges > 1,
                      let r = Range(m.range(at: 1), in: name), let n = Int(name[r])
                else { continue }
                highest = max(highest, n)
            }
        }

        let number = String(format: "%02d", highest + 1)
        var name = ""
        for token in tokens {
            switch token {
            case .literal(let s): name += clean(s)
            case .datum: name += format(date, "yyyy-MM-dd")
            case .zeit: name += format(date, "HH-mm")
            case .profil: name += clean(profile.name)
            case .nr: name += number
            }
        }
        return dir.appendingPathComponent(name + "." + ext)
    }
}
