# Execution plan — Android UI test harness (unattended, headless emulator)

**Goal:** let Claude exercise the Android capture companion's **UI end-to-end without a physical phone or
owner intervention** — pair, capture, group, tag, Save-to-phone, Finish — and verify results on a **headless**
Mac. Enables the phone-gated Processor items in `SUITE_TODO.md` (tag-card-live, re-pair coordination,
streaming residuals) to be checked in a self-contained loop.

**Status:** in progress (2026-07-07). Delete this file when the harness is committed + proven (git keeps history).

**Scope:** Android only. iOS is out — the simulator has no camera and a physical iPhone is deferred (see
[[iphone-testing-deferred]] / `SUITE_TODO`). No app code change is required (a bonus): pairing uses the
existing **manual host/port/token entry** on `ConnectScreen` (the `showManual` path), driven by `adb input`,
so there is **no Tier-2 pairing edit**.

## Design (how each need is met)
- **Device:** a **headless Android emulator** (`emulator -no-window`), created once via `avdmanager`. No
  display, no physical phone, survives unplugging. Apple-Silicon system image (`arm64-v8a`, `google_apis`).
- **Drive the UI:** `adb shell input tap/text/keyevent`; locate controls by dumping the tree
  (`uiautomator dump` → parse `text=`/`content-desc=`/`bounds=`) or by fixed coordinates per screen.
- **Observe / assert:** `adb exec-out screencap -p` (PNG, saved to scratchpad — Claude can view it) +
  `uiautomator dump` text assertions.
- **Camera:** the emulator's **virtualscene** camera. Flow tests don't need real content (the shutter just
  needs to produce a JPEG); for OCR-content tests, feed a document image into the virtual scene. Pairing does
  NOT use the camera (manual entry), so no QR-image feed is needed for connect.
- **Mac side (headless):** launch the Mac app with `LIVECAPTURE_AUTOSTART=1` +
  `LIVECAPTURE_READYFILE=<path>`; it writes `LIVECAPTURE_READY port=<p> token=<t> folder=<f>`. The harness
  reads `port`+`token` from that file — no GUI, no QR.
- **Connect:** emulator reaches the Mac host at **`10.0.2.2`** (the emulator's host-loopback alias), so pair
  in **Wi-Fi mode** with `host=10.0.2.2 port=<p> token=<t>` typed into the manual form. (No `adb reverse`.)
- **Verify:** assert on **files the Mac wrote** — the backup folder
  `~/Pictures/Archive Processor Live Capture/<session>/` and the staging manifest — for the expected pages /
  segment-complete, rather than scraping the Mac GUI. Keeps the whole loop headless.

## Build steps
1. **Toolchain (one-time):** `sdkmanager --install "emulator" "platform-tools" "system-images;android-34;google_apis;arm64-v8a"`; accept `--licenses`. SDK root = `/opt/homebrew/share/android-commandlinetools` (the Homebrew `android-commandlinetools` cask — there is NO `~/Library/Android/sdk`; `adb` is the separate `android-platform-tools` cask). NOTE: this corrects the "no Android SDK/toolchain" aside in `SUITE_TODO`'s targetSdk item — command-line-tools + platform-34 + build-tools 34 are present; only the emulator package was missing.
2. **AVD:** `avdmanager create avd -n ap_test -k "system-images;android-34;google_apis;arm64-v8a" -d pixel_6`.
3. **Boot script:** `emulator -avd ap_test -no-window -no-audio -no-boot-anim -no-snapshot -camera-back virtualscene &`; wait for `adb wait-for-device` + `sys.boot_completed`.
4. **Install app:** `./gradlew :app:installDebug` (needs `local.properties` → `sdk.dir=/opt/homebrew/share/android-commandlinetools`; gitignored, recreate after any clone).
5. **Mac headless:** launch Release/Debug build with `LIVECAPTURE_AUTOSTART=1 LIVECAPTURE_READYFILE=/tmp/ap_ready`; parse `port`/`token`.
6. **Driver (`scripts/android-ui-drive.sh` + a per-flow helper):** launch app → grant camera perm (`adb shell pm grant … CAMERA`) → open Wi-Fi manual entry → type host/port/token → Connect → run flows (shutter ×N, Box, Folder, End segment → tag sheet Apply/Skip/Cancel, Save to phone) → screencap each step.
7. **Assertions:** poll the Mac backup folder + manifest for the expected `NNNNN-<group>.jpg` pages and the completed segment; fail loudly with the screenshot + `uiautomator` dump on mismatch.

## Acceptance
Unattended, from a cold emulator: pairs to a headless Mac, captures a multi-page document, ends the segment,
and the Mac's backup folder + manifest show all pages + the segment marked complete; Box/Folder markers and
"Save to phone" (gallery MediaStore) verified; step screenshots saved. Re-runnable with a single command.

## Limits / non-goals
- **iOS:** blocked (no simulator camera; device deferred).
- **Camera content** is only controllable via the virtual scene; real-lens content isn't reproducible.
- **Not a replacement for** on-device final verification of camera/photo quality, nor for a Tier-3 review.
- Optional future: instrumented Compose UI tests (`androidTest`, fake `SegmentTransport`) for CI-grade
  regression — complementary, tracked separately if pursued.

## Coordination
- The Mac autostart path is headless (no GUI contention). If a variant ever drives the Mac GUI, follow the
  GUI-exclusive protocol (ask the owner first).
- Tier: harness code is **test tooling** (Tier-1). It touches NO app source (pairing via existing manual
  entry). If a debug-only endpoint-seed is ever added to skip manual entry, THAT is a phone `Net`/pairing
  change → **Tier-2** + must be build-flag-gated to debug builds only.
