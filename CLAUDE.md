# Scanr

Persönliche macOS-Menüleisten-App, die einen Fujitsu ScanSnap iX500 direkt über USB ansteuert (Ersatz für die Hersteller-Software). Nicht sandboxed, IOUSBHost. Lizenz: GPL-3.0-or-later (siehe `LICENSE`).

- Plan: `~/Documents/Doku/02 Projekte/Apps/Scanr/Implementierungsplan.md`
- Protokollreferenz: `Referenz/sane-fujitsu/` (SANE-Backend, nur lesen)
- Paket: `Package/` (`ScannerKit`, `scanr-cli`)

## Bauen und testen

`swift test --package-path Package`

Liegt das Repo in iCloud (`~/Documents`), scheitert das Signieren des Test-Bundles an Finder-Attributen. Dann einen Build-Ordner außerhalb nutzen: `--scratch-path /tmp/scanr-build`.

Zwei Testsuiten, zwei Befehle. Das Scheme `Scanr` (⌘U, Xcode-MCP `RunAllTests`) fährt nur die
App-Tests `ScanrTests`. Treiber, Bildverarbeitung, OCR und PDF (`ScannerKitTests`, rund 160
Tests) laufen nur mit `swift test`. Ein grünes ⌘U allein sagt über das Paket nichts. Das
Paket-Testziel ins Scheme einzutragen hat `xcodebuild` am 2026-10-23 nicht angenommen.

```
swift test --package-path Package --scratch-path /tmp/scanr-build
xcodebuild test -project Scanr.xcodeproj -scheme Scanr -destination 'platform=macOS'
```

## Regeln

- Kommentare und Texte für Nutzer auf Deutsch, kein Gedankenstrich als Satzzeichen.
- Commit-Messages auf Deutsch, am Ende `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Direkt auf `main` arbeiten, nach jeder Änderung committen.
- Wissen gehört in den Vault, nicht in diese Datei.
