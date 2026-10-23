# Scanr

A menu bar app that drives a Fujitsu ScanSnap iX500 over USB. Press the scan button,
get a searchable PDF on your Desktop. Nothing else runs in the background.

Scanr replaces ScanSnap Home for one job: scanning documents into files. It talks to the
scanner directly, without the vendor driver, and it has no network code. Your scans go
from the USB cable to your Desktop, or a folder you choose, and nowhere else. There is no cloud, no account and
no update service.

## What it does

- **Scan button on the device** starts a scan with the active profile. The menu bar
  icon offers the same, plus „Scan abbrechen“ while a scan runs.
- **Duplex**, blank pages removed, pages straightened and cropped to the paper. Receipts
  and business cards keep their real size instead of being padded to A4.
- **Text recognition** with Apple's Vision framework. PDFs get an invisible text layer,
  so you can search and copy text.
- **Three profiles** to start with, plus your own:
  - *Rechnungen*: 300 dpi, always black and white (1 bit), PDF. About 25 to 50 KB per
    A4 page.
  - *Auto*: 300 dpi, colour only on pages that have colour, PDF.
  - *Foto*: 600 dpi colour, one JPG per page.
- **File names** from a pattern, by default `2026-10-22 scan 01.pdf`.
- **Output folder** is the Desktop unless you pick another one in the settings. macOS asks
  for access when you change it, not at the first scan.
- If a sheet double-feeds or jams, the pages read so far are saved and the message
  tells you which sheet to put back.

The user interface is in German.

## Requirements

- macOS 26 or later
- Fujitsu ScanSnap iX500, connected by USB
- ScanSnap Home must not be running, it would hold the scanner. Scanr shows
  „Von ScanSnap Home belegt“ in that case.

Other ScanSnap models are not supported. The iX500 has quirks (it only delivers colour,
grey and black and white are computed in software; some status queries lock it up) that
Scanr handles specifically.

## Download

Signed and notarized builds are on the
[Releases](https://github.com/a6k/Scanr/releases) page. Open the DMG and drag Scanr
into Programme/Applications.

## Building

```bash
git clone https://github.com/a6k/Scanr.git
cd Scanr
swift test --package-path Package --scratch-path /tmp/scanr-build
```

The driver, image processing, OCR and PDF output live in the Swift package
`Package/` (ScannerKit) and are tested without the scanner. The app target in
`Scanr.xcodeproj` is the menu bar UI on top of it.

To sign with your own team, create `Local.xcconfig` next to `Signing.xcconfig`:

```
DEVELOPMENT_TEAM = <your ten-character team ID>
```

The file is ignored by git. A pre-commit hook in `scripts/githooks` blocks team IDs from
being committed; enable it with `git config core.hooksPath scripts/githooks`.

`scanr-cli` in the package is a command line tool for working on the protocol:
`inquiry`, `caps`, `ghs`, `status --watch`, `scan`, `job`. Do not send MODE SENSE page 0x3D to
an iX500: it locks the device until it is power-cycled.

## Credits and licence

The USB protocol is ported from the `fujitsu` backend of
[SANE](https://gitlab.com/sane-project/backends) (`backend/fujitsu.c`, by Randolph Bentson,
Frederik Ramm, Oliver Schirrmeister, m. allan noah and others), which is licensed under GPL-2.0-or-later. A copy of the backend is kept in
`Referenz/sane-fujitsu/` for reference.

Scanr is licensed under the GNU General Public License, version 3 or later. See
[LICENSE](LICENSE).

Scanr is not affiliated with Fujitsu, PFU or Ricoh. ScanSnap is their trademark.
