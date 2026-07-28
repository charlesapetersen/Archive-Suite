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

**Rule of thumb:** reach for #1 (headless) first — it's permission-free and CI-safe. Use #2 for an
interactive check on *this* machine, and #3 (below) for full GUI tests **unattended / in the daemon**.

## 3. Headless Tart VM — full GUI tests off the physical screen (`vm-gui-runner.sh`)
#2 needs the host's one `WindowServer`, so it takes over your screen — unusable unattended. A **Tart**
macOS VM has its *own* virtual display, so XCUITest **and** the sighted pixel loop run entirely off your
monitor. This is the daemon-safe GUI lane.

**Run:** `ops/gui/vm-gui-runner.sh [xcuitest|sighted|both]`. Artifacts (`.xcresult`, PNGs) land in
`~/.tart-mirror/vm-artifacts/` — `Read` the PNGs to eyeball renders. Drive the VM with `tart exec <vm> …`
(no SSH — Cirrus images ship the guest agent).

**One-time setup** (`brew install cirruslabs/cli/tart crane`; `vncdotool` in a venv at `~/.tart-mirror/vncenv`):
build the VM from Cirrus's `macos-tahoe-xcode:26.3` (macOS 26 + Xcode 26.3 — matches host). The image is
~63 GB; pull it **resumably** by mirroring into a local registry then cloning (a network drop costs ≤512 MB,
not the whole pull — `tart pull` itself is NOT resumable):
```
crane registry serve --disk ~/.tart-mirror/registry-storage --address 127.0.0.1:5001 &   # local registry
skopeo copy --dest-tls-verify=false docker://ghcr.io/cirruslabs/macos-tahoe-xcode:26.3 \
  docker://127.0.0.1:5001/cirruslabs/macos-tahoe-xcode:26.3        # RESUMABLE: re-run to continue
tart clone 127.0.0.1:5001/cirruslabs/macos-tahoe-xcode:26.3 archive-gui-runner --insecure
rm -rf ~/.tart-mirror/registry-storage                            # reclaim the ~63 GB mirror after clone
tart set archive-gui-runner --display 1920x1200
```
`xcodegen` must be on the **host** — the runner generates the `.xcodeproj` into the mounted worktree; the
guest image has no xcodegen.

**Why VNC for the sighted lane** (not in-VM `screencapture`/`cliclick`): a headless VM has **no capturable
display** until a viewer attaches (in-VM `screencapture` → "could not create image from display"), and in-VM
`cliclick` needs Accessibility TCC that's awkward to grant. So the runner boots with `--vnc-experimental` (a
virtual display served over a local VNC port — still off your physical screen) and uses `vncdotool` from the
host to grab that framebuffer **and** inject clicks/keys — **VNC-injected input bypasses guest TCC entirely.**
It parses tart's one-shot `vnc://:PASS@127.0.0.1:PORT` from the launch log.

**GUI fixture:** fixtured Reader UITests need `ArchiveReader/scripts/make-gui-fixture.sh` (a tagged scratch
corpus at `~/Library/Application Support/ArchiveReader/AR-GUI-Fixture`). It honors `AR_FIXTURE_SRC` (point it
at a mounted corpus) and takes the first 10 real PDFs — robust to a slimmed/strided corpus.

**Status (both follow-ups done 2026-07-28):** (a) ✅ the 5 toolbar UITests (`sidebar`/`tagCloud`/`preview`)
that failed "multiple matching elements" (the app opens **two windows** → two toolbars) are fixed by a
`toolbarButton(_:)` helper in `FixtureUITestCase` (window-scope to "Archive Reader" + prefer the hittable
match) → **suite is 15/15 in the VM**. (b) ✅ daemon wiring landed as an **opt-in, fail-open** health-gate
step — `ops/autonomous/gui-vm-gate.sh` + a `AUTONOMOUS_GUI_VM=1` hook in `health-gate.sh`: **OFF by default**;
a missing VM / boot failure / timeout **skips** (never parks), and it REDs only on a reproducible
`** TEST FAILED **` (retry-once). The change is committed but **inert until armed** — build the VM, run
`gui-vm-gate.sh` once by hand, then set `AUTONOMOUS_GUI_VM=1`. VM TCC grants live on the VM's disk (re-apply
if the VM is rebuilt).
