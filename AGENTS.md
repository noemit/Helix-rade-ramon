# Faulix

Native macOS reader for legacy Helix ("HeliX Heap") collections. Sample file: `Libros`.

## Layout
- `Sources/HelixKit` – reverse-engineered file-format reader (SwiftPM library)
- `Sources/hxdump` – CLI: `swift run hxdump Libros schema|objects|records [rel] [n]|csv [rel]|json|templates|views`
- `Sources/HelixKit/Templates.swift` – template/view/font-table decoding (layout documented in doc comments)
- `Sources/HelixKit/Abaci.swift` – abacus tile trees, opcode table (guesses marked `(?)`), evaluator, query selection
- `swift run hxdump Libros abaci [recordID]` prints every formula as text with its value
- `Sources/HelixKit/RecordStore.swift` – SQLite store; data is imported once to
  `~/Library/Application Support/Faulix/<name>-<sha256>.sqlite` and edited there (Helix file is never written).
  Every change goes through `put()` which logs before/after JSON in the `history` table (used for undo/restore).
- `Sources/HelixKit/Design.swift` – editable native design (`DesignModel`, imported once from Helix, stored as JSON in
  the store's `meta` table) and `Design` (all app lookups + ordering). `Formula.swift` – text formula language
  (print/parse round-trips every abacus). App design edits go through `CollectionModel.editDesign` (undo + history).
- `App/NotHelix/Help.swift` – quickstart text for every page (`HelpButton(topic:)` in each toolbar, Help menu window).
- `Exporter.helixText` writes Helix's tab-delimited import format; `Template.fieldOrder` gives a view's tab order.
- App: `ViewForms.swift` (forms/lists, editing, status bar), `HistoryView.swift` (log + Edit menu undo),
  `ExportSheet.swift`, `DesignDesktop.swift` (RADE icon windows, tile editor)
- Verified against real Helix screenshots (Lista Xeral, Ficha): row order/values, "previous" opcode, rectangle
  flags (+4 0x80 framed, +5 0x80 vertical scroll), number formats (+0x26 kind, +0x27 flags 0x40 fixed/0x80 currency,
  +0x28 decimals; Spanish region → "19,95", "3.319Pts"). Extra `0x4698` blocks in the heap are deleted/old record copies.
- App testing overrides: `PrintPDFTo /tmp/x.pdf` writes the open view's print PDF; `OpenRecordText "taberna de Galiana"` opens a record; `SearchText "Chao Rego, Xosé"` fills Find;
  `ClickText "Chao Rego"` simulates clicking a list cell (drill-down / open record). Search: `TextSearch` (HelixKit).
- Writing the Helix heap format itself is intentionally NOT supported (indexes use Helix's private collation keys;
  no way to verify output without real Helix).
- App testing overrides: `defaults write com.nothelix.NotHelix OpenView "Ficha"` (User mode view),
  `defaults write com.nothelix.NotHelix DesignOpen "Libros/Título lista"` (Design mode path); `defaults delete` to reset
- `App/NotHelix` – SwiftUI document-based viewer app
- `project.yml` – XcodeGen spec; regenerate with `xcodegen generate` after adding app files

## Localization (English + Galician)
- UI strings: SwiftUI literals are localized automatically; strings built in code use `L("…")` (or `Lk(key)` for
  runtime keys such as undo action names). Translations live in `scripts/translations_gl.py`.
- After UI changes: `xcodebuild -exportLocalizations -project NotHelix.xcodeproj -localizationPath /tmp/loc -exportLanguage gl`,
  then `python3 scripts/build_strings.py --check "/tmp/loc/gl.xcloc/Localized Contents/gl.xliff"` lists untranslated
  strings; add them to `translations_gl.py` and run `python3 scripts/build_strings.py` to regenerate `Localizable.xcstrings`.
- Language: Settings ▸ Language (Automatic = Galician on es/gl/pt/ca Macs). Test with `defaults write com.nothelix.NotHelix FaulixLanguage gl`.

## Release
- `scripts/release.sh` → universal Release build signed with "Developer ID Application" (team CT5KSA99W8, hardened
  runtime, timestamp), notarized with keychain profile `faulix-notary`, stapled, zipped to `dist/`.
  `NOTARIZE=0 scripts/release.sh` signs only. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`.
- `Libros` (private sample data) is gitignored; its tests skip when it is absent.

## Verify
- Library tests: `swift test`
- App build: `xcodebuild -project NotHelix.xcodeproj -scheme NotHelix -configuration Debug -derivedDataPath build/DerivedData build`
- Run: `open -a "build/DerivedData/Build/Products/Debug/Faulix.app" Libros`
