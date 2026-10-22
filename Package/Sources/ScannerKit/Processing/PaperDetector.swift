import Foundation

/// Findet das Blatt auf dem hellgrauen Scanner-Hintergrund.
///
/// Kein Vision: Der Hintergrund ist nur 8 bis 20 Helligkeitsstufen dunkler als das Papier und
/// hat quer zur Einzugsrichtung einen Verlauf (siehe Messwerte in `PageProcessor`). Statt einer
/// festen Schwelle sucht das Verfahren Stufen zwischen zwei ebenen Flächen und legt über sie
/// eine Hough-Abstimmung für die beiden langen Blattkanten. Eine echte Papierkante
/// ist auf voller Länge vorhanden, Textränder nur zu einem Teil.
enum PaperDetector {
    // Messwerte des iX500: Papier 244 bis 254, Hintergrund 223 bis 243, am Blattrand wirft das
    // Papier einen Schatten (Hintergrund bis 197 auf 5 Pixeln, danach Sprung auf 247). Die
    // schwächste Kante ist die einer Bon-Rückseite mit 231 gegen 244, also 13 Stufen.
    /// Kleinste Stufe zwischen Hintergrund und Papier, die als Kante zählt.
    static let minStep = 5
    /// Die Hintergrundseite der Stufe muss mindestens so hell sein.
    static let minBackgroundLuma = 170
    /// Auf der Papierseite einer Kante müssen die nächsten 4 Pixel eben sein (Schwankung höchstens
    /// so groß). Das sortiert dünne dunkle Linien aus, etwa den Strich im Scanner-Hintergrund
    /// bei x = 12 mm, der in einer Zeile wie eine Kante mit Schatten aussieht.
    static let innerFlatTolerance = 8
    static let innerFlatLength = 4
    /// Kleinster Abstand zwischen linker und rechter Kante (Analysepixel).
    static let minSpan = 20
    /// Suchbereich für den Drehwinkel in Grad. Ein von Hand schief eingelegter Bon kam am
    /// 2026-10-23 auf rund 20 Grad; 15 Grad reichten dafür nicht.
    static let maxAngleDegrees = 30.0
    /// Schrittweite der groben Suche in Grad; die feine Suche deckt einen Schritt nach jeder Seite ab.
    static let coarseStepDegrees = 1.0
    /// Schrittweite der feinen Suche in Grad.
    static let fineStepDegrees = 0.05
    /// Anteil der Blatthöhe, den eine Linie an Kantenpunkten haben muss, um als Blattkante zu gelten.
    static let minSideFraction = 0.4
    /// Von mehreren starken Linien gilt die äußerste, wenn sie mindestens so viel Stimmen hat.
    static let outermostRatio = 0.75
    /// Rechteck nach innen verschieben (Analysepixel), damit der Kantenübergang nicht mitkommt.
    static let edgeInset = 1.5
    /// Abstand zur gefundenen Linie, bis zu dem ein Kantenpunkt zu ihr zählt (Analysepixel).
    static let inlierDistance = 1.5

    private struct Points {
        var x: [Float] = []
        var y: [Float] = []
        var count: Int { x.count }
    }

    private struct Votes {
        var best = 0
        var acc: [Int32] = []
    }

    /// Das Blatt, oder nil wenn keine verlässliche Kante gefunden wurde.
    ///
    /// Gesucht werden die linke und die rechte Blattkante (lange Kanten, die der Scanner nie
    /// abschneidet). Oben und unten liefert die Ausdehnung dieser beiden Kanten: Die Längen-
    /// erkennung des Scanners endet am Blatt, ein schief eingezogenes Blatt berührt Ober- und
    /// Unterkante des Scans mit seinen Ecken. Textzeilen und Tabellenlinien im Blatt würden eine
    /// eigene Suche nach oberer und unterer Kante täuschen.
    static func detect(_ a: PageAnalysis) -> PaperRect? {
        let w = a.width, h = a.height
        guard w >= 16, h >= 16 else { return nil }

        // Kantenpunkte aus den Zeilen. `left`: Hintergrund davor, `right`: Hintergrund dahinter.
        var left = Points(), right = Points()
        a.luma.withUnsafeBufferPointer { l in
            for y in 0..<h {
                scan(l, start: y * w, stride: 1, count: w,
                     first: { p in left.x.append(Float(p)); left.y.append(Float(y) + 0.5) },
                     second: { p in right.x.append(Float(p)); right.y.append(Float(y) + 0.5) })
            }
        }

        let span = w + h
        let size = 2 * span + 16
        let offset = 0.3 * Double(span) + 2

        func votes(_ pts: Points, theta: Double) -> Votes {
            var acc = [Int32](repeating: 0, count: size)
            let c = Float(cos(theta)), s = Float(sin(theta))
            let off = Float(offset)
            pts.x.withUnsafeBufferPointer { xs in
                pts.y.withUnsafeBufferPointer { ys in
                    for i in 0..<pts.count {
                        let idx = Int((xs[i] * c + ys[i] * s + off).rounded())
                        if idx >= 0 && idx < size { acc[idx] += 1 }
                    }
                }
            }
            // Drei benachbarte Klassen zusammenfassen, die Kante ist 1 bis 2 Pixel verschmiert.
            var sm = [Int32](repeating: 0, count: size)
            var best: Int32 = 0
            for i in 1..<(size - 1) {
                sm[i] = acc[i - 1] + acc[i] + acc[i + 1]
                best = max(best, sm[i])
            }
            return Votes(best: Int(best), acc: sm)
        }

        /// Beste Paarung aus linker und rechter Linie, die mindestens `minSpan` auseinanderliegen.
        func bestPair(_ l: Votes, _ r: Votes) -> (score: Int, left: Int, right: Int) {
            var bestScore = -1, bestL = 0, bestR = 0
            var prefix = 0, prefixAt = 0
            for j in 1..<(size - 1) {
                let i = j - minSpan
                if i >= 1, Int(l.acc[i]) > prefix { prefix = Int(l.acc[i]); prefixAt = i }
                if i >= 1 {
                    let sc = min(prefix, 2 * h) + min(Int(r.acc[j]), 2 * h)
                    if sc > bestScore { bestScore = sc; bestL = prefixAt; bestR = j }
                }
            }
            return (bestScore, bestL, bestR)
        }

        func score(_ theta: Double) -> Int {
            bestPair(votes(left, theta: theta), votes(right, theta: theta)).score
        }

        // Grob im Raster, dann fein um das Maximum.
        var bestTheta = 0.0
        var bestScore = -1
        var deg = -maxAngleDegrees
        while deg <= maxAngleDegrees + 1e-9 {
            let t = deg * .pi / 180
            let sc = score(t)
            if sc > bestScore { bestScore = sc; bestTheta = t }
            deg += coarseStepDegrees
        }
        var fine = bestTheta - coarseStepDegrees * .pi / 180
        let fineEnd = bestTheta + coarseStepDegrees * .pi / 180
        while fine <= fineEnd + 1e-12 {
            let sc = score(fine)
            if sc > bestScore { bestScore = sc; bestTheta = fine }
            fine += fineStepDegrees * .pi / 180
        }

        // Die äußerste unter den starken Linien ist die Blattkante.
        let vl = votes(left, theta: bestTheta), vr = votes(right, theta: bestTheta)
        let pair = bestPair(vl, vr)
        func pick(_ v: Votes, around peak: Int, lowest: Bool, bound: Int) -> Double? {
            guard Double(v.acc[peak]) >= minSideFraction * Double(h) else { return nil }
            let limit = Double(v.acc[peak]) * outermostRatio
            let candidates = lowest ? Array(1..<bound) : Array(((bound + 1)..<(size - 1)).reversed())
            for i in candidates where Double(v.acc[i]) >= limit {
                var m = i   // Gipfel statt Flanke
                for j in max(1, i - 2)...min(size - 2, i + 2) where v.acc[j] > v.acc[m] { m = j }
                return Double(m) - offset
            }
            return Double(peak) - offset
        }
        var lRho = pick(vl, around: pair.left, lowest: true, bound: max(2, pair.right - minSpan + 1))
        var rRho = pick(vr, around: pair.right, lowest: false, bound: min(size - 3, pair.left + minSpan - 1))
        if let l = lRho, let r = rRho, r - l < Double(minSpan) { lRho = nil; rRho = nil }
        guard lRho != nil || rRho != nil else { return nil }

        let c = cos(bestTheta), s = sin(bestTheta)
        let corners = [(0.0, 0.0), (Double(w), 0.0), (0.0, Double(h)), (Double(w), Double(h))]
        let ns = corners.map { $0.0 * c + $0.1 * s }
        let ts = corners.map { -$0.0 * s + $0.1 * c }

        // Oben und unten: Vereinigung der Ausdehnungen beider Kanten entlang der Kante. Ein schief
        // eingezogenes Blatt erreicht links und rechts je eine andere Ecke zuerst; Lücken in einer
        // Kante (helle Bilder am Rand) verkürzen nur diese, die andere trägt dann das Maß.
        func extent(_ pts: Points, rho: Double?) -> (Double, Double)? {
            guard let rho else { return nil }
            var lo = Double.infinity, hi = -Double.infinity
            for i in 0..<pts.count {
                let x = Double(pts.x[i]), y = Double(pts.y[i])
                guard abs(x * c + y * s - rho) <= inlierDistance else { continue }
                let t = -x * s + y * c
                lo = min(lo, t); hi = max(hi, t)
            }
            return lo <= hi ? (lo, hi) : nil
        }
        let eL = extent(left, rho: lRho), eR = extent(right, rho: rRho)
        var top = ts.min()!, bottom = ts.max()!
        var haveEnds = false
        if let eL, let eR {
            top = min(eL.0, eR.0); bottom = max(eL.1, eR.1); haveEnds = true
        } else if let e = eL ?? eR {
            top = e.0; bottom = e.1; haveEnds = true
        }
        guard bottom - top >= 8 else { return nil }

        var l = lRho.map { $0 + edgeInset } ?? ns.min()!
        var r = rRho.map { $0 - edgeInset } ?? ns.max()!
        let t = haveEnds ? top + edgeInset : top
        let b = haveEnds ? bottom - edgeInset : bottom

        // Fehlt eine Seite, liegt sie am Bildrand: so weit nach innen ziehen, bis die Ecken im Bild liegen.
        if lRho == nil || rRho == nil {
            func fits(_ l: Double, _ r: Double) -> Bool {
                for (n, u) in [(l, t), (r, t), (l, b), (r, b)] {
                    let x = n * c - u * s, y = n * s + u * c
                    if x < -1 || x > Double(w) + 1 || y < -1 || y > Double(h) + 1 { return false }
                }
                return true
            }
            let (l0, r0) = (l, r)
            func moved(_ k: Double) -> (Double, Double) { (lRho == nil ? l0 + k : l0, rRho == nil ? r0 - k : r0) }
            if !fits(moved(0).0, moved(0).1) {
                var lo = 0.0, hi = Double(max(w, h))
                for _ in 0..<40 {
                    let mid = (lo + hi) / 2
                    let m = moved(mid)
                    if fits(m.0, m.1) { hi = mid } else { lo = mid }
                }
                (l, r) = moved(hi)
            }
        }
        guard r - l >= 8, b - t >= 8 else { return nil }
        let mn = (l + r) / 2, mt = (t + b) / 2
        let rect = PaperRect(
            cx: mn * c - mt * s, cy: mn * s + mt * c, width: r - l, height: b - t, angle: bestTheta)
        // Ein winziges Rechteck ist ein Textblock, kein Blatt.
        guard rect.width * rect.height >= 0.1 * Double(w * h) else { return nil }
        return rect
    }

    /// Verdichtet aufeinanderfolgende Treffer einer Zeile oder Spalte zu einer Kante an der
    /// Stelle mit der größten Stufe.
    private struct Run {
        var active = false
        var last = 0
        var pos = 0
        var mag = 0

        mutating func feed(hit: Bool, at p: Int, mag m: Int, report: (Int) -> Void) {
            if hit {
                if active && last == p - 1 {
                    if m > mag { pos = p; mag = m }
                } else {
                    if active { report(pos) }
                    active = true; pos = p; mag = m
                }
                last = p
            } else if active && last < p - 1 {
                report(pos)
                active = false
            }
        }

        mutating func finish(report: (Int) -> Void) {
            if active { report(pos) }
            active = false
        }
    }

    /// Sucht Stufen zwischen den Pixelpaaren (p-1, p) und (p+1, p+2). Das Papier wirft einen
    /// Schatten auf den Hintergrund, der zur Kante hin bis zu 40 Stufen dunkler wird; die Kante
    /// selbst ist die größte Stufe in dieser Flanke. `first` meldet Stufen mit Hintergrund davor,
    /// `second` mit Hintergrund dahinter, jeweils als Kantenkoordinate (Pixelgrenze).
    private static func scan(
        _ l: UnsafeBufferPointer<UInt8>, start: Int, stride: Int, count: Int,
        first: (Int) -> Void, second: (Int) -> Void
    ) {
        guard count >= 6 else { return }
        var firstRun = Run(), secondRun = Run()
        /// Sind die `innerFlatLength` Pixel ab `from` (mit `step` als Richtung) eben?
        func flat(from: Int, step: Int) -> Bool {
            var lo = 255, hi = 0
            for k in 0..<innerFlatLength {
                let q = from + k * step
                guard q >= 0 && q < count else { return false }
                let v = Int(l[start + q * stride])
                lo = min(lo, v); hi = max(hi, v)
            }
            return hi - lo <= innerFlatTolerance
        }
        // Kante E liegt zwischen den Pixeln E-1 und E. Papier danach: E+1 ... E+4;
        // Papier davor: E-5 ... E-2 (E-1 und E bleiben als Übergang außen vor).
        func reportFirst(_ e: Int) { if flat(from: e + 1, step: 1) { first(e) } }
        func reportSecond(_ e: Int) { if flat(from: e - 2, step: -1) { second(e) } }
        for p in 1...(count - 3) {
            let a = Int(l[start + (p - 1) * stride]) + Int(l[start + p * stride])
            let b = Int(l[start + (p + 1) * stride]) + Int(l[start + (p + 2) * stride])
            let mag = abs(b - a) / 2
            let hit = mag >= minStep
            firstRun.feed(hit: hit && a / 2 >= minBackgroundLuma, at: p, mag: mag, report: { reportFirst($0 + 1) })
            secondRun.feed(hit: hit && b / 2 >= minBackgroundLuma, at: p, mag: mag, report: { reportSecond($0 + 1) })
        }
        firstRun.finish(report: { reportFirst($0 + 1) })
        secondRun.finish(report: { reportSecond($0 + 1) })
    }
}
