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

**Run:** `ops/gui/vm-gui-runner.sh [reader|notes] [xcuitest|sighted|both]` (default `reader both`; the app
argument is optional, so the old `vm-gui-runner.sh xcuitest` form still means "reader"). Artifacts (`.xcresult`, PNGs) land in
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
`cliclick` needs Accessibility TCC that's awkward to grant. So the sighted lane boots with
`--vnc-experimental` (a virtual display served over a local VNC port) and uses `vncdotool` from the host to
grab that framebuffer **and** inject clicks/keys — **VNC-injected input bypasses guest TCC entirely.** It
parses tart's one-shot `vnc://:PASS@127.0.0.1:PORT` from the launch log.

⚠️ **`--vnc-experimental` is not silent, and the boot mode is therefore PER LANE.** `tart run --help`: it uses
"Virtualization.Framework's VNC server **instead of** the built-in UI" — and tart then opens macOS
**Screen Sharing.app** at that endpoint, so a VM window appears on your display. It steals no input, but it is
unasked-for. The owner hit this on 2026-07-30 when a session ran the *xcuitest* lane, which needs no pixels at
all. So:
- **xcuitest → `--no-graphics`** ("Don't open a UI window") — completely silent. The guest still has its own
  virtual display, which is why XCUITest works there; this only suppresses a *host* window. The health gate
  has always booted this way, which is why the gate never showed anything.
- **sighted → `--no-graphics --vnc-experimental`.** The two flags **compose**, which is the clean answer:
  tart still prints `VNC server is running at vnc://…` so `vncdotool` has a framebuffer to grab, and **no
  viewer is ever opened** — better than opening a window and closing it, which flashes. (A scoped
  `close_vm_viewer` remains as a guard in case a future tart reverts that behaviour; it only quits Screen
  Sharing if it was not already running before the boot, so a session of your own is never torn down.)

Both verified end to end on 2026-07-30 with no window on the host at any point: `xcuitest` →
ArchiveReaderUITests **15/15** in the VM; `sighted` → `sighted-reader.png`, a real 2048×1536 capture of the
Reader on `AR-GUI-Fixture` (11 documents, tags, parsed dates, OCR-fail badges).

**GUI fixture:** fixtured Reader UITests need `ArchiveReader/scripts/make-gui-fixture.sh` (a tagged scratch
corpus at `~/Library/Application Support/ArchiveReader/AR-GUI-Fixture`). It honors `AR_FIXTURE_SRC` (point it
at a mounted corpus) and `AR_FIXTURE_DST` (build somewhere throwaway), and takes the first 10 real PDFs —
robust to a slimmed/strided corpus. Since `W26.scripts` (2026-08-07) it neither `mdimport`s nor waits on
`mdfind`: it reads the tags back off disk and **exits non-zero** if the fixture is wrong. That matters most
here — the guest boots with a cold Spotlight index, so the old poll could only ever time out and warn.
Its own gate is `ArchiveReader/scripts/test-fixture-scripts.sh` (26 checks, run it by hand — `W26.lint-fu`).

**THE GUEST'S SCREEN SIZE IS NOT THE VM'S CONFIGURED ONE (W21.vmgui-c, measured 2026-08-01).** `tart run
--no-graphics` attaches no display, so the guest's WindowServer boots at its headless default **1024×768** —
even though `tart get archive-gui-runner` reports `Display: 1920x1200`. That is small enough to break real
tests: the Notes browser needs ~1084 pt of width, so its window overflowed and ~92 pt was clipped off each
side, and four `ArchiveNotesUITests` failed as "not hittable" for two days while being tracked as product
bugs. **`tart_ensure_display` now raises the guest to `$TART_VM_DISPLAY` (default 1920×1200) right after the
guest-agent wait**, in `tart-lib.sh` so both entry points get it, via the guest-side helper
`ops/gui/vm-set-display.swift` (`CGConfigureDisplayWithDisplayMode`, `.permanently`, so later runs no-op).
It reports what actually took effect and WARNs — loudly, with the consequence named — rather than dying, since
Reader is green at either size. If you ever debug "element is not hittable" in this lane, print
`NSScreen.screens` and the window frame from the test **first**; `tart get` is not evidence about the guest.

**Status (2026-08-01):** the gate covers **every app with a UITest bundle** — Reader *and* Notes (Processor has
no test target). Pick a subset with `AUTONOMOUS_GUI_VM_APPS="reader"`. **Reader is 15/15 and Notes is 12/12 in
the VM**, so the **warn tier** (`AUTONOMOUS_GUI_VM_WARN_APPS`) is **empty by default** and a UITest failure in
either app REDs the gate. Don't re-add an app to it without a tracked item — a permanent warn tier is a
disabled test with extra steps. The gate is **ON by default**
(`AUTONOMOUS_GUI_VM=0` disables); a missing VM / boot failure / guest-agent timeout **skips** (never parks), and
it REDs only on a reproducible `** TEST FAILED **` (retry-once). `GATE_MAXRUN` is 50 min to absorb the VM step.
Sessions also verify view/interaction changes here off-screen — the old `gui-mode` flag was retired, GUI is
unattended now (CLAUDE.md loop step 2 + resume-prompt STEP 3.5), and `.claude/hooks/no-host-gui.sh` now *enforces*
that for unattended runs. VM TCC grants live on the VM's disk (re-apply if the VM is rebuilt).

**One table, one wait — `ops/gui/tart-lib.sh`.** The per-app config (project/scheme/UITest bundle/guest
DerivedData/app bundle/fixture + its builder/launch arg/pre-run), the guest-agent wait, and the corpus
resolution are **shared** by `vm-gui-runner.sh` and `ops/autonomous/gui-vm-gate.sh`. That is load-bearing,
not tidiness: the guest-agent fix below originally landed in the gate *only*, leaving the interactive
runner — the script this README, the resume prompt, CLAUDE.md and AGENTS.md all point people at — broken in
exactly the way the gate had just been fixed. Adding an app is one block in that table.

Bugs found on 2026-07-30 that are worth not re-introducing:

- **The guest-agent race (why the gate silently ran nothing).** `tart ip --wait` returns when the guest has
  *networking*, but `tart exec` talks over a separate vsock control socket served by the Tart Guest Agent, which
  comes up **later**. The gate exec'd immediately and got *"Failed to connect to the VM using its control socket
  … is the Tart Guest Agent running?"*. Every exec in that run failed — including the fixture probe, which is why
  the log also claimed the fixture was missing. The gate now **polls `tart exec true` until the agent answers**
  (`AUTONOMOUS_GUI_VM_AGENTWAIT`, default 240s).
- **Skip ≠ pass.** The gate used to `exit 0` for "skipped" as well as "passed", so `health-gate.sh` printed a
  bare `✓ gui-vm` for a lane that had executed **zero tests**, and the reason went to a temp log shown only on
  RED. It now exits **3 = SKIPPED**, and `health-gate.sh` prints `⊘ … SKIPPED — <reason>` and appends
  `— but NOT VERIFIED: gui-vm` to the summary. Don't collapse that back into a two-state exit.

- **The sighted lane needs `vncdotool`, and its venv is not tracked.** `~/.tart-mirror/vncenv` had gone
  missing by 2026-07-30, so `vm-gui-runner.sh sighted` could not run at all. It is a plain venv — recreate
  with `python3 -m venv ~/.tart-mirror/vncenv && ~/.tart-mirror/vncenv/bin/pip install vncdotool`. The
  runner now fails with that exact command in the message instead of a bare "not found".
- **A failed in-VM fixture build is now LOUD.** It used to be `>/dev/null 2>&1 || true`, which is how the
  unmounted-path bug above stayed invisible: the fixtured UITests just XCTSkipped and the suite still
  reported success. Same class as the silent green.

**Fixtures** are built inside the VM on demand (idempotent, scratch-only, persisting on the VM disk):
`ArchiveReader/scripts/make-gui-fixture.sh` → `AR-GUI-Fixture`, `ArchiveNotes/scripts/make-notes-fixture.sh` →
`AN-GUI-Fixture`. Their source PDFs are **gitignored** (primary checkout only), so the gate mounts that corpus as
its own `corpus:` share rather than reaching under the repo mount — which is what lets it run from a worktree.
