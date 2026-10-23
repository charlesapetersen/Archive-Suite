# Phone↔Mac round-trip E2E (`scripts/e2e-phone-mac.sh`)

The **only** test that exercises the *whole* Live Capture round-trip between both real apps —
Android companion **and** Mac Processor — end to end, deterministically and unattended:

```
emulator (identical Android app)  ──LAN──▶  headless Mac (real Gemini OCR)
   inject known documents  ──▶  stream pages  ──▶  OCR → tag → PDF → finalize
                                          ──▶  assert tokens + years survived
```

It is distinct from the two things that already existed and each covers only *half*:
- `android-ui-drive.sh` — drives the phone UI + wire protocol against a **fake** Mac stub (no OCR).
- `LiveCaptureTestDriver` / `test-smoke.sh` — drive the **Mac** pipeline with no phone.

## What it proves
A known document photographed "on the phone" travels the real durable-queue + `(group,seq)` + ack
path to the Mac, is OCR'd by the real provider, tagged, rendered to a PDF, and finalized — by asserting
that each fixture's **unique OCR token** (e.g. `MEMO-ALPHA-4471`) and its **year** appear in the Mac's
finalized output. Both sides are checked (Mac output + per-doc phone screencaps).

The year may land in an output **filename** or a **Finder tag**, and `assert_mac.py` accepts either. ⚠️ Until
`W26.oracle` (2026-08-06) the tag half never actually fired: it read tags via `mdls`, and TESTOUT lives under
`/tmp` (below), which Spotlight does not index — so `mdls` returned `(null)` with exit 0 for correctly tagged
output, in every run. Tags now come from the xattr via `scripts/finder_tags.py`; the oracle **prints the tags
it read**, and if a year is missing while any tag read failed it says the check may be blind rather than
blaming tagging. Guarded by `./scripts/test-finder-tags.sh`, which needs no emulator, key or network.

## Why emulator + inject (not a physical phone)
A physical phone's camera is non-deterministic (framing/lighting/focus) and can't be driven unattended.
The emulator runs the **identical** app build; a **debug-only** capture-inject seam (stripped from
release) feeds bundled known documents through the exact real capture path — the only change is the
pixel source. This is the sole fully-deterministic, unattended route.

## The three seams it depends on
- **B1 (Android, debug-only):** at the shutter, if `filesDir/test_inject.jpg` exists, its bytes are used
  instead of the camera and routed through the same `addDocumentPhoto`/`captureMarker`; consumed per tap.
  Push the next image with `adb shell run-as com.archiveprocessor.capture cp /data/local/tmp/inject.jpg files/test_inject.jpg`.
- **B2 (Mac, env-gated — prod-unchanged when unset), all requiring `LIVECAPTURE_AUTOSTART=1`:**
  - `ARCHIVEPROC_HEADLESS` + `LIVECAPTURE_OCRKEY=<key>` → OCR key for the headless live pipeline (used only if the Keychain is empty).
  - `LIVECAPTURE_AUTOSKIPTAGS=1` → auto-resolve each Mac tag card via the existing `skipMacTags` (LLM tags, no GUI).
  - `LIVECAPTURE_AUTOFINALIZE=1` → on `POST /session/complete` → drain-gated `requestFinish`→`finalize`, then write `DONE.txt`.
  - `LIVECAPTURE_TESTOUT=<dir>` → isolated output dir + where `DONE.txt` lands (never the real corpus).
- **B3:** this orchestrator + `assert_mac.py` + `pdftext.swift` + `e2e-fixtures/` (known docs + `ground_truth.json`).
  The LAN `LIVECAPTURE_READY` line publishes both the listener port and the high-entropy bearer the receiver
  authenticates, so the orchestrator never reads the running app's persisted defaults. It redacts that bearer
  from READY and Mac-log artifacts immediately after pairing; the app's stderr readiness line is redacted too.
  The distinct file-relay READY line intentionally keeps the six-character Drive-relay `token`. The filled
  pairing form is deliberately not screenshot: it contains the persistent LAN bearer.

The companion has **no session-finish UI** (it finishes per-segment; whole-session finalize is a Mac
action), so the harness itself sends `POST /session/complete` over the documented Bearer route.

## When to run
The **Tier-2 functional gate** for `Capture/`/`Net/` and the phone↔Mac protocol — run it after changes
there, and before a release that touches Live Capture. **Not** a per-commit or CI check: it needs a live,
awake Mac + the emulator and spends a little on OCR. For a cheap every-commit gate use `test-smoke.sh`.

## Run
```bash
export OCR_KEY="<gemini-key>"       # optional; falls back to the Keychain Gemini key
caffeinate -di ArchiveProcessor/scripts/e2e-phone-mac.sh
```
Prereqs: `ap_test36` AVD + the android-36 system image installed; the Mac free/awake (it's a live GUI app);
xcodegen on PATH. Artifacts (raw backup, screencaps, `mac.log`, `REPORT.txt`, finalized `out/`) all land in a
new, owner-private `/tmp/ap-e2e-*` dir (`E2E_RUNDIR` must name a nonexistent path with that prefix). Exit 0
= PASS. `KEEP_EMU=always|onfail|never` controls emulator teardown (default `onfail`).

## The iPhone companion (`--ios`, W40.i3)
`e2e-phone-mac.sh --ios` runs the same Mac side, fixtures and assertions against the iPhone companion in a
headless iOS simulator (`ios-sim-drive.sh`: `simctl boot`, never Simulator.app). Needs an iOS simulator runtime
(`xcodebuild -downloadPlatform iOS`, about 8 GB). The simulator has no camera and no `adb input`, so the app's
DEBUG-only harness (`ArchiveCaptureiOS/.../Debug/E2EHarness.swift`, absent from Release) supplies B1's twin —
`Documents/test_inject.jpg` at the shutter — plus pairing from a launch payload and a driver that runs shutter,
End segment and Skip per fixture; the script stages the fixtures and follows `Documents/e2e-status.txt`. It does
not tap buttons, so the UI wiring is not covered. The connected shot and each page's shot must all differ, or
the phone side fails (`STALE screencaps`: the app drew no new frame, `W40.i3-fu-shots`). The camera-less
simulator shows "No camera on this device." where the preview would be. Evidence:
`verification/evidence/capture/W40.i3-ios-e2e.md`.

## The iPhone app's own buttons (`e2e-ios-ui.sh`, W40.i-sim-ui)
`caffeinate -di scripts/e2e-ios-ui.sh` covers what `--ios` does not: it runs `ArchiveCaptureiOSUITests` (XCUITest,
real taps, in the same headless simulator) against the same real headless Mac. Six tests run in order on one install:
manual entry and each connect diagnostic; Box, Folder, two pages, End segment and the tag sheet's Q2 + 1962; Retry and
auto-retry with the Mac stopped and restarted; the app backgrounded and terminated with pages unsent; the Clear and
delete dialogs and Re-pair. The tests ask the script for Mac stops, restarts and finalizes through files in
`$RUN/ctl`. The camera seam is a feed directory (`ARCHIVECAP_UITEST_FEED`, DEBUG only). The script checks the Q2/1962
Finder tags, the heartbeat counts the Mac heard (`LIVECAPTURE_PHONE_PENDING`, headless only), and that every photo
taken was filed but the one deleted. It also ends the Xcode helpers xcodebuild leaves in its session, so the Mac heavy
lock is released (`W40.fix-heavy-run-xcode-helpers` is the real fix). Evidence:
`verification/evidence/capture/W40.i-sim-ui.md`.

## Cost
Tiny — 3 fixtures × `gemini-2.5-flash-lite` (a few cents). Isolated output; never touches the real corpus.
