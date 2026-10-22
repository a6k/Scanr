# Scanr

Persönliche macOS-Menüleisten-App, die einen Fujitsu ScanSnap iX500 direkt über USB ansteuert (Ersatz für die Hersteller-Software). Nicht sandboxed, IOUSBHost. Lizenz: GPL-3.0-or-later (siehe `LICENSE`).

- Plan: `~/Documents/Doku/02 Projekte/Apps/Scanr/Implementierungsplan.md`
- Protokollreferenz: `Referenz/sane-fujitsu/` (SANE-Backend, nur lesen)
- Paket: `Package/` (`ScannerKit`, `scanr-cli`)

## Bauen und testen

`swift test --package-path Package`

Liegt das Repo in iCloud (`~/Documents`), scheitert das Signieren des Test-Bundles an Finder-Attributen. Dann einen Build-Ordner außerhalb nutzen: `--scratch-path /tmp/scanr-build`.

## Regeln

- Kommentare und Texte für Nutzer auf Deutsch, kein Gedankenstrich als Satzzeichen.
- Commit-Messages auf Deutsch, am Ende `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Direkt auf `main` arbeiten, nach jeder Änderung committen.
- Wissen gehört in den Vault, nicht in diese Datei.
