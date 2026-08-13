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
  The orchestrator reads the listener port from `LIVECAPTURE_READY`, then reads the running app's persisted
  high-entropy `LiveCaptureLANToken` for pairing. The READY line still publishes the old Drive-relay code
  after W16.lan2's credential split; the harness redacts it from both READY and Mac-log artifacts. Correcting
  that `Capture/` seam is owner-gated as W21.e2e-fu2. The filled pairing form is deliberately not screenshot:
  it contains the persistent LAN bearer.

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

## Cost
Tiny — 3 fixtures × `gemini-2.5-flash-lite` (a few cents). Isolated output; never touches the real corpus.
