# Known Issues & Gotchas

Running log of quirks, risks, and things verified/unverified. Keep current.

## Verified facts to rely on (2026-07-04)
- Writing `.tagNamesKey` while keeping the color-name token (`Red`/`Purple`) and **not** touching
  `.labelNumberKey` **preserved** `labelNumber` (tested on a Red-labeled scratch copy, local APFS).
  Still verify `labelNumber` after every write and restore on drift.
- `FileManager.setAttributes([.creationDate:])` accepts historical dates (1938, 1850) but **clamps
  below ~1677-09-21** (int64-ns-since-1970). → Do NOT use creation date as the chronological sort
  key; sort by a date derived from the tags (no range limit, medieval-safe).
- Spotlight tag queries are fast (compound 3-facet over 6,941 files ≈ 0.38s) and scale.

## Open risks / to verify
- **Spotlight content indexing is unreliable here:** `kMDItemTextContent` was `null` on the freshly
  copied test corpus. → Full-text search must use the app's own content index (extract page-2 text
  per file), not `kMDItemTextContent`. Re-check whether normal on-disk archives get content-indexed.
- **`.documentIdentifierKey` may mutate the file** (assigns/persists an identifier on read) — do NOT
  request it. Use security-scoped bookmarks + path-identity re-verification instead. *To confirm.*
- **Tag-write coordination:** must use `NSFileCoordinator(.contentIndependentMetadataOnly)`, never
  `.forReplacing`. TOCTOU: read the array *inside* the coordinated write. *Property-test this.*
- **Unicode normalization on tag write:** confirm macOS does not NFC/NFD-normalize or trim tag
  strings on write (would make the multiset verify false-fail). *Property-test on the real corpus copy.*
- **Classification is not always present** (`Document Start`/`Continuation` absent on some outputs) —
  segment features must degrade gracefully; never assume presence.
- **SwiftUI `Table` at ~150k live rows** with multi-sort may jank — abstract the data layer so an
  AppKit `NSTableView` swap is possible; perf-test early.
- **Not every file is a clean 2-page PDF** — guard 1-page/>2-page/0-page/corrupt/encrypted and
  tagged non-PDF images; the two-up viewer must degrade, not crash.
- **Subject/facet collisions** (a subject literally `1984`, `P7`, `Read`) — facet classification is
  display/sort/filter only and must never drive a write.

## Environment notes
- Xcode 26.3 / Swift 6.2 toolchain; XcodeGen 2.45.2 at `/opt/homebrew/bin/xcodegen`.
- GitHub CLI: use `/opt/homebrew/bin/gh` (bare `gh` is shadowed on this machine).
- The corpus lives in `Test files/Brown Gemini/` (~6,941 PDFs) and is gitignored — never modify it.
