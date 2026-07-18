# `ops/gui/` — the sighted GUI-verification loop

Two complementary ways to verify what the apps actually **render**, not just what the
accessibility tree reports. XCUITest (and every XCUI-family driver, incl. Appium mac2) only sees
the a11y tree: an element *exists / is hittable*. It is blind to whether a PDF drew, a thumbnail
is blank, text is clipped, or a colour/layout is wrong — which for these document apps is most of
"is it right?". These tools close that gap.

## 1. Headless pixel guards (no permissions) — the default
`ArchiveReader/macOS/Tests/ArchiveReaderTests/RenderProbe.swift` + `DocumentRenderGuardTests.swift`.
Renders a SwiftUI view (`ImageRenderer`) or a PDF page (ArchiveCore `PDFThumbnailer`) to real
pixels **inside the unit bundle** and asserts on them (`assertRendersNonBlank`, `nonWhiteFraction`,
`meanLuminance`). No app launch, no TCC/Accessibility/automation prompt → runs in the autonomous
health-gate. This guards the shared **2-page PDF SPEC** (page 0 scan / page 1 OCR) — the one
contract an `element.exists` check can never protect. Reference-image diffs: `SnapshotTests.swift`
(pointfreeco/swift-snapshot-testing). Rendered PNGs are written to `$ARCHIVE_TEST_ARTIFACT_DIR`
(else a temp dir) and logged as `ARTIFACT <name>: <path>` — `Read` them to eyeball the result.

## 2. `capture-window.sh` — the live sighted loop (needs GUI-on)
For checks that need the running app (real interaction, a bug repro, whole-window layout). Grabs
the actual on-screen pixels of a window to a PNG you can `Read`. Requires the seeded Accessibility +
Screen-Recording grants (AGENTS.md → *GUI verification*).

```bash
# 1. launch pointed at a SCRATCH copy (never the real corpus — Reader Core Directive)
./launch.sh reader

# 2. drive by coordinate with cliclick (/opt/homebrew/bin/cliclick), keys/menus via osascript
cliclick c:640,400            # click
cliclick t:"hello"            # type

# 3. capture → read the shot → decide the next action → repeat
shot="$(ops/gui/capture-window.sh ArchiveReader)"   # prints the PNG path
#    (then Read "$shot")

# 4. quit when done
osascript -e 'quit app "ArchiveReader"'
```

Optional image ops (ImageMagick `magick` / `compare`, and `sips`) for cropping a region or diffing
two shots when a property check isn't enough.

**Rule of thumb:** reach for #1 (headless) first — it's permission-free and CI-safe. Use #2 only
when the check genuinely needs the live app.
