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

## macOS tag/label coupling (verified 2026-07-05)
- A **`Red`/`Purple` tag token is inseparable from its Finder color label**: setting the token makes
  macOS auto-assign label 6/3, and there is no "Red subject with no label" state. So `TagWriter`'s
  color-clear removes the token matching the *actual* label (correct), and a document whose subject
  is literally "Red"/"Purple" will always appear color-labeled. Non-color subjects are unaffected.
- **Do not run overlapping `xcodebuild test` invocations** on the same scheme/DerivedData — the
  concurrent test processes contend on `NSFileCoordinator` and tag writes, ballooning runtimes
  (seen: a 0.07s suite took 448s under contention). Run one build/test at a time.

## Deferred hardening (from the 2026-07-05 code review)
- **Write-target identity re-verification (Safety §6, low severity):** `TagWriter.mutate` writes to
  whatever file currently occupies the URL. If a file is moved/replaced in Finder between Spotlight
  discovery and the write, the delta could apply to the wrong file's tags. v1 assumes stable local
  files (owner-confirmed). Full fix = capture a stable identity (security-scoped bookmark /
  `fileResourceIdentifierKey`) at discovery and re-verify inside the coordination block before
  writing. Tracked for a future hardening pass; do NOT request `.documentIdentifierKey` (it mutates).

## @Published willSet timing (fixed 2026-07-05 — GUI-caught)
- A Combine subscription on a nested `@Published` (`library.$files`) fires in **willSet**, *before* the
  property commits. A synchronous sink that reads the stored property (`self.library.files`) inside
  `recompute()` therefore sees the **old** value — which made the nav list show **0 of N** after a
  load. Fix: `.receive(on: DispatchQueue.main)` before the sink so it runs after the value commits
  (or use the value the publisher delivers, not the stored property). **Do not** read a just-changed
  `@Published` back from `self` inside its own synchronous sink. Unit tests missed this; only running
  the GUI surfaced it (verified via `screencapture`).

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
