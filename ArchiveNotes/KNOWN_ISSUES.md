# Archive Notes — Known Issues & Gotchas

Running log of quirks, risks, and things verified/unverified for the Notes app. Keep current.
(Sibling logs: `../ArchiveReader/KNOWN_ISSUES.md`, `../ArchiveProcessor/KNOWN_ISSUES.md`.)

## Test harness — headless full-scheme run crashes (found 2026-07-13, open)

Running the **whole** `ArchiveNotes` unit scheme headless (`xcodebuild test …`, and therefore
`test-smoke.sh notes`) aborts the shared Swift-Testing process with:

```
NSInvalidArgumentException: -[ArchiveNotes.BlockHeaderChipView performClick:]: unrecognized selector
```

- **Source:** `SourceBlockViewTests` → "reveal callback receives the anchor" (a W4-S7 **display** test
  that drives the chip's Reveal button). It reproduces identically on `main` **before** any later files
  are compiled, so it is pre-existing — not tied to whatever change a session is making.
- **Impact:** one fatal `NSException` in a display test aborts *all* Swift-Testing tests in that process,
  so the whole-scheme smoke gate is red headless even when the logic suites are green. This is why W4-S7
  reported "**92 non-display** tests green".
- **Workaround (until fixed):** verify per-suite, not whole-scheme. `-only-testing:`/`-skip-testing:` do
  **not** match Swift-Testing suites in this Xcode/SDK (see below), so you can't skip the crashing suite
  by name; instead run the specific logic suite(s) you touched (e.g.
  `-only-testing:ArchiveNotesTests/<YourSwiftTestingSuite>` — which DOES run once the files are compiled).
- **Fix candidates (GUI-paused, deferred):** make `BlockHeaderChipView` respond to / forward
  `performClick:` (or have the test click the hosted `NSButton`, not the container `NSView`); and/or gate
  the display suites behind a trait so headless runs skip them. Then confirm the whole scheme is green.

## Build/test gotchas (XcodeGen + Swift Testing, 2026-07-13)

- **`xcodegen generate` must run AFTER adding files.** XcodeGen expands the globbed source dirs into an
  explicit file list at *generation* time (not synchronized groups). If you add a `.swift` file to
  `Sources/`/`Tests/` **after** generating, the `.xcodeproj` won't reference it — it silently isn't
  compiled, and `-only-testing:…/NewSuite` matches 0 tests. In a fresh worktree: write your files first,
  *then* `xcodegen generate`, then build/test. (Confirmed: 0 → N pbxproj refs only after re-generating.)
- **`-only-testing:` / `-skip-testing:` don't select Swift-Testing suites here** (Xcode w/ MacOSX26.2 SDK).
  A `Target/SuiteType` (or `Target/SuiteType/func`) filter selects 0 for `@Suite`/`@Test` types; the XCTest
  "Executed N tests" summary also excludes Swift-Testing results (those print as `✔ Test "…"` lines). Read
  the `✔ Test`/`✔ Suite`/`Test run with N tests` lines to confirm a Swift-Testing suite ran, not the XCTest
  summary. A bare `-only-testing:<Target>` runs everything (and hits the crash above).
