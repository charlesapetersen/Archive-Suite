# Live Capture — Android companion app + macOS receiver

**Status:** **v3.2.0 pushed (commit + tag) to GitHub.** Live Capture verified end-to-end: on-device capture→ingest, crash durability (phone + Mac), dual output built, capture-UI refinements. Remaining = one cheap paid Process/OCR run to confirm tags land on PDFs. · **Last updated:** 2026-07-02
**Permanent working plan.** If work is interrupted, resume from the phase checklists below.
(Supersedes the temporary plan at `~/.claude/plans/moonlit-strolling-crane.md`.)

## Goal
Photograph documents rapidly on a **Pixel 9+**, **group and lightly tag them on the phone as you shoot**, and stream them to the Mac, which runs the **existing** Archive Processor OCR + tagging pipeline. On-phone speed + grouping + minimal tagging is the whole point; the phone is where your hands are.

---

## Decisions locked (reviewed with user 2026-07-01)

1. **On-phone tagging = Priority + Date** (not subjects; subjects stay on the Mac's LLM).
   - **Priority tags:** `P10`, `P9`, `P8`, `P7` — `P10` is highest. Applied **per document segment** via a quick picker shown when the user *finishes photographing a segment*.
   - **Per-page override:** within a segment, specific pages can be marked **`P10`** individually.
   - **Year:** phone offers **suggested years derived from recently tagged documents** (quick chips) for fast selection; user may also enter a **specific year**.
   - **Month:** phone presents a month selector. **Do NOT bias/suggest months by recency** — always neutral Jan–Dec.
2. **How phone tags feed the Mac tagging flow** (governed by the main-UI `TaggingMode`): the phone **pre-fills** the existing per-mode flow; the Mac still owns subjects.
   - **Priority** → always applied per page (any mode except `.none`); no LLM equivalent.
   - **Date (year/month)** → pre-fills the segment's date everywhere; overrides the LLM/auto date when the phone supplied one.
   - **Subjects** → whatever the selected mode already does. `.automatic` = LLM generates subjects (merged with phone date/priority). Manual modes (`.autoDate`, `.autoDateManualSeg`, `.human`) = the Mac's **manual subject-tagging UI still runs**, pre-filled with the phone's date + pre-grouped segments. **The phone never sends subjects — only minimal tagging (priority + date) on the phone.**
   - Net: Live Capture supplies grouping + date + priority; it does **not** bypass the Mac's subject tagging in manual modes.
3. **Sequencing:** **Mac receiver first** (harden + build + curl-test here), **then** Android.
4. **Pairing (v1):** **QR scan only** (Mac already renders host/port/token QR). mDNS auto-discovery deferred to polish.
5. **Stack (from prior locked plan):** native Android, **Kotlin + Jetpack Compose + CameraX**.
6. **No shared-network assumption (added 2026-07-01):** do NOT assume the phone and Mac share Wi-Fi — reading rooms often can't. **USB (`adb reverse tcp:PORT tcp:PORT`) is a first-class transport**, co-equal with Wi-Fi: pairing must support connecting to `127.0.0.1` over the USB tunnel. The app must allow cleartext HTTP (LAN/loopback, no TLS) — `android:usesCleartextTraffic="true"`.

---

## Current state (snapshot)

### macOS receiver — built, UNTESTED, not yet network-ready
Untracked/uncommitted on `main`:
- `Net/CaptureServer.swift` — `NWListener` HTTP/1.1 server; Bearer auth; `GET /ping`, `POST /photo`, `POST /session/complete`; advertises Bonjour `_archivecap._tcp`.
- `Capture/CaptureSession.swift` + `Capture/CaptureModels.swift` — per-session incoming folder under Application Support, atomic ingest, grouping (document/box/folder), ordered handoff.
- `Views/LiveCaptureView.swift` — QR pairing, live grouped-thumbnail stream, "Process →" handoff.
- Wiring: `ContentView.swift` Files/Live-Capture toggle; `OCRProcessor` gained `stagedCaptureFiles` + `preGroupedBoundaries/Types` + `applyPreGroupedClassifications` (phone groups skip LLM segmentation, map onto `documentStart`/`boxLabel`/`folderLabel`); `OCRView` consumes the staged handoff.

### Android app — NOT started
`ArchiveCapture/` contains only the Gradle wrapper + a one-line `settings.gradle.kts`. No app module, manifest, or Kotlin source.

### Gaps that block "done" (addressed by this plan)
- **Protocol carries no tags** — needs priority + year/month (see Protocol v2).
- **Protocol drifted from old plan** — implemented as **raw JPEG body + `X-*` headers** (not multipart); dropped `X-Session`/`X-Timestamp`. Android must match the *implemented* protocol.
- **Info.plist missing** `NSBonjourServices` (`_archivecap._tcp`) and `NSLocalNetworkUsageDescription` → Bonjour advertise + local-network prompt fail on current macOS.
- **Build:** project uses **XcodeGen** (`project.yml` = source of truth, source-globbing). Prefer `xcodegen generate` over hand-editing `project.pbxproj`.
- **Toolchain:** `adb` ✓ and `sdkmanager` ✓ installed, but `ANDROID_HOME` unset and no SDK root/platform → not buildable yet. Java 21 ✓.
- **Sandbox:** app is **not sandboxed** (listening works). If sandbox is ever enabled for distribution, add `com.apple.security.network.server`.

---

## Architecture

### Protocol v2 (raw body + headers; Bearer token on all)
- `GET /ping` → `{ok, app}` (health/pairing check).
- `POST /photo` — body = raw JPEG. Headers:
  - `Authorization: Bearer <session token>`
  - `X-Group: <groupId>` — stable per segment
  - `X-Seq: <int>` — global capture order
  - `X-Type: document|box|folder`
  - `X-Device: <name>` *(optional)*
  - `X-Priority: P7|P8|P9|P10` *(optional; per-photo effective priority = page override, else segment default)*
  - `X-Year: <YYYY>` *(optional; the segment's year, repeated on each photo of the group)*
  - `X-Month: <1-12>` *(optional; the segment's month)*
- `POST /session/complete` → finalize/status.

### macOS side
- **Models** (`CaptureModels.swift`): add to `CapturedPhoto` → `priority: String?`, `year: Int?`, `month: Int?`. `CaptureGroup` derives `year`/`month` from its photos (priority stays per-photo).
- **Server** (`CaptureServer.swift`): parse `X-Priority`/`X-Year`/`X-Month`, pass into `ingest(...)`.
- **Session** (`CaptureSession.swift`): store the new fields; extend `orderedFilesAndGroups()` to also return per-file priority + per-file year/month (parallel arrays).
- **Pipeline** (`OCRProcessor.swift`): new staged/pre-grouped arrays (`priorities`, `years`, `months`). Application rules:
  - **Priority** → append the `Pxx` string as a macOS tag on each output PDF (per page), always (mode ≠ `.none`).
  - **Date** → feed phone year/month into the segment's `GeneratedTags`/`SegmentTagData` (`year` = "YYYY", `month` = "MM Month").
  - **Subjects** follow the selected `TaggingMode` unchanged: `.automatic` runs the LLM; manual modes still open the Mac manual subject UI (now pre-filled with phone date + pre-grouped segments). Phone date/priority layer on regardless of mode. Box/folder → existing Red/Purple via `applyBoxFolderLabelTags`.
- **Info.plist:** add `NSLocalNetworkUsageDescription` + `NSBonjourServices = [_archivecap._tcp]`.
- **UI polish:** show per-group priority/date badges in `LiveCaptureView` (nice-to-have).

### Android side (`ArchiveCapture/`, Kotlin + Compose + CameraX)
- **Connect screen:** scan the Mac's QR → parse `{host, port, token, name}`; persist endpoint; `GET /ping` to confirm. Also supports **USB** (`adb reverse` → connect to `127.0.0.1:PORT`) and manual host/port/token entry, so no shared Wi-Fi is required.
- **Capture screen:** CameraX full-res preview; **white circular shutter (no label)** shoots document pages; **Box (red) / Folder (purple)** each capture a **single-image marker** (never a multi-page segment) and upload immediately; **End segment** finalizes the current document segment → tag sheet; recent-thumbnail strip (auto-scrolls) + per-photo upload status. **Thumbnail tap = select → X → delete**; **long-press = flag `P10`**; with a photo selected, **Box/Folder reclassifies it** into a single-image marker. App icon = the Archive Processor Mac icon (adaptive, generated from `AppIcon` via `sips`).
- **Segment-completion tagging sheet** (on "New Document" / finish segment): **Priority** chips P7–P10; **Year** = recency-suggested chips + custom entry; **Month** = neutral Jan–Dec (no recency).
- **Recency model:** phone-local store of recent year selections; suggest a small range around them. (Months excluded by design.)
- **Upload:** durable queue (WorkManager + Room, or a simple disk queue) decoupled from shutter; retries on blips; posts Protocol v2 to the Mac's LAN IP.

---

## Reliability & durability — archival photos cannot be re-taken
**Invariant:** a photo's bits AND its grouping/tag metadata are durable on disk at every step; after a crash only re-OCR (cheap, repeatable) may be needed — never re-photographing.
- **Phone = source of truth:** each shot is written to a file immediately; a `session.json` manifest records every item `{id,path,group,seq,type,priority,year,month,state}`, rewritten (temp→rename) on every change. On launch the session is restored and any non-uploaded item is re-sent. Re-upload is **idempotent** on the Mac (same group+seq → replace, never duplicate). Photos are retained until an explicit new-session/clear. **[DONE + crash-tested 2026-07-02: `data/SessionStore.kt` + VM restore/persist/resume + Mac `ingest` dedup. force-stop → relaunch restored all 11 items with states/metadata; buffered pages survived; Mac showed no duplicates.]**
  - Follow-up: clean up orphaned capture files from prior sessions (session.json is source of truth; old JPEGs currently linger).
- **Mac receiver:** photos written atomically (temp→rename) **[done]**; a `manifest.json` sidecar of header metadata written on ingest, and the newest unprocessed session reloaded on launch so a crash never orphans received data. **[DONE + crash-tested 2026-07-02: SIGKILL → relaunch adopted the same session folder with photos + manifest intact.]**
- **Processing:** sources are durable → a mid-Process crash loses no photos; re-run regenerates PDFs. Full OCR-resume is a later enhancement.

## Dual output (Live Capture)
The final/collection folder must contain BOTH the renamed **original image** and the **PDF** for each captured page — same base name, identical tags (date/subjects/priority/Red-Purple), moved together during collection organization. **[DONE — `OCRProcessor.exportOriginalImages()` (gated by `exportOriginals`, set for Live Capture runs) copies each source image next to its PDF pre-merge and mirrors the PDF's tags; `CollectionSegmenter.organizeOutput` moves the sibling image alongside the PDF. End-to-end check needs a Process run (paid OCR).]**

## Phased work breakdown

### Phase 1 — macOS receiver (buildable/testable here NOW)
- [x] Protocol v2 headers in `CaptureServer.process` (priority/year/month).
- [x] `CaptureModels` + `CaptureSession.ingest` + `orderedFilesAndGroups()` carry priority/date.
- [x] `OCRProcessor`: staged/pre-grouped priority/year/month; apply priority per file (always, merge-safe read→append→re-apply in `applyCapturePriorityTags`); pre-fill segment date from phone (automatic override in `performTaggingPhase`; manual-mode seeding; `prefetchManualDates` skips phone-dated segments); subjects via the existing per-mode flow.
- [x] `Info.plist`: `NSBonjourServices` (`_archivecap._tcp`) + `NSLocalNetworkUsageDescription`.
- [x] `xcodegen generate` → `xcodebuild` (Debug) → **BUILD SUCCEEDED**.
- [x] Receiver smoke test (`scratchpad/receiver_test.sh`): launched via `LIVECAPTURE_AUTOSTART`/`READYFILE`, curl over loopback → token gating (401/200), 4 protocol-v2 posts (priority/year/month) all 200, 4 files landed grouped (`0000N-gX.jpg`).
- [ ] **Paid-OCR verification (next):** click Process on a captured set → confirm priority + date land on output PDFs (`mdls -name kMDItemUserTags`). Per CLAUDE.md: test plan + cost estimate + request API key first; cheap model (`gemini-2.5-flash-lite`).

### Phase 2 — Android toolchain + scaffold ✅
- [x] SDK present at `/opt/homebrew/share/android-commandlinetools` (`sdk.dir` in `local.properties`): platform-tools 37, `platforms;android-34`, `build-tools;34.0.0`, cmdline-tools 20.0, licenses accepted. `adb` + `java` 21 on PATH.
- [x] Versions: **Gradle 8.9** (wrapper), **AGP 8.6.1** (defaults to build-tools 34.0.0), **Kotlin 2.0.20** + Compose compiler plugin, **Compose BOM 2024.09.02**. `compileSdk/targetSdk 34`, `minSdk 26`, appId `com.archiveprocessor.capture`.
- [x] Scaffolded `app/` (settings/build gradle, `gradle.properties`, framework theme, `MainActivity` hello-world Compose). `./gradlew assembleDebug` → **BUILD SUCCESSFUL**, `app/build/outputs/apk/debug/app-debug.apk` (9 MB).
- Note: CameraX deps deferred to Phase 3 (kept the first build minimal to validate the toolchain).

### Phase 3 — Android app
Phase 3a (builds; on-device behavior unverified) — package `com.archiveprocessor.capture`, appId matches:
- [x] CameraX capture (`LifecycleCameraController`) + current-group indicator + thumbnail strip (downsampled) + per-photo upload-status dot.
- [x] Grouping controls (New doc / Box / Folder) + per-page `P10` (long-press thumbnail).
- [x] Segment-completion tag sheet (`SegmentTagSheet`): priority P10–P7, year = recency chips + custom entry, month = neutral Jan–Dec.
- [x] QR pairing (`QrAnalyzer` = ML Kit, bundled) + manual host/port/token fallback; `MacClient` HTTP Protocol v2; per-item upload with 3× retry + `session/complete`; `Prefs` persists endpoint + recent years.
- [x] `./gradlew assembleDebug` → **BUILD SUCCESSFUL**, `app-debug.apk` (~34 MB).
- Key files: `net/{MacEndpoint,MacClient,QrAnalyzer}.kt`, `data/Prefs.kt`, `capture/{CaptureModels,CaptureViewModel}.kt`, `ui/{ConnectScreen,CaptureScreen,SegmentTagSheet}.kt`, `MainActivity.kt`.
- Phase 3b polish (later): queue durable across process death (re-enqueue disk files on relaunch), reconnection, retake/delete/reorder, session save/reset.

### Phase 4 — on-device integration (in progress, 2026-07-01)
- [x] APK sideloaded to **Pixel 9 (Android 16)** via `adb install -r -g`.
- [x] Environment findings: phone was on **cellular only** (`v4-rmnet1`, no Wi-Fi); macOS **application firewall on** — so direct LAN pairing to the Mac's IP cannot work here. Confirmed the Mac receiver is alive (loopback `/ping` 200).
- [x] **USB path established:** `adb reverse tcp:PORT tcp:PORT` → phone `localhost:PORT` reaches the Mac over the cable (loopback is firewall/Local-Network-privacy exempt). This is the reliable transport here and the general answer to "no shared Wi-Fi."
- [x] **Bug fixed:** app now sets `android:usesCleartextTraffic="true"`; without it, `targetSdk 34` blocked plain HTTP so `ping()`/uploads silently failed (the "nothing happens on Connect" symptom). Rebuilt + reinstalled.
- [x] **Token shortened** to a 6-char code (`CaptureSession.makeToken()`, alphabet without `0/O/1/I/L`) so USB/manual pairing is typeable; the QR still carries it. Port is still system-assigned per session (Phase 5: consider pinning for constant USB entry).
- [x] Paired over USB (`127.0.0.1:50723` + 6-char token) → captured **5 photos in 2 groups**; all arrived in the Mac session folder, correctly grouped and in seq order (`0000N-<groupId>.jpg`). **Capture → group → upload → ingest verified end-to-end on-device.**
- [x] Bug found + fixed: clicking "Process" in Live Capture didn't load photos into the Files tab. `OCRView` mounts *after* `stagedCaptureFiles` is set (the tab switch), so its `.onChange` never fired for the already-set value. Added an `.onAppear` that picks up pending staged files.
- [x] **Wired connection automated:** Mac auto-runs `adb reverse tcp:PORT tcp:PORT` on server start (`Net/USBBridge.swift`, best-effort, off-main); the app asks **Wired vs Wi-Fi** on open and, in Wired mode, scans the *same* QR but connects to `127.0.0.1:<port>` (QR's port + token). Verified: the app set `adb reverse` for the new port with no manual step. Added an **Unpair** button (re-pair without `pm clear`). UI polish: white shutter (no label), Box red / Folder purple, box/folder = single image.
- [x] Files pane shows the phone's finished segmentation as soon as Live Capture files are staged — Box / Folder / Document Start / Continuation badges + tinted rows, via `FileRowView.presetClassification` (falls back to it before a job exists). The pre-grouped run already skips LLM re-segmentation, so the decisions aren't redone.
- [ ] Then Process (paid OCR) → confirm priority + date (+ Red/Purple + rotation) on the output PDFs. Metadata (type/priority/year/month) rides in the upload headers; provable only by a Process run. Needs an API key.

### Phase 5 — polish
- [x] **Re-pair without churn — DONE:** the Mac token is now **stable** (persisted in UserDefaults) and the listen port is **pinned to 48627** (falls back to a system-assigned port only if busy). Verified: two relaunches kept the same port + token. A phone paired over USB (`127.0.0.1:48627` + token) keeps working across Mac restarts with **no re-pair**. To re-pair when genuinely needed (new Mac/network), clear the app's saved endpoint (`run-as … rm shared_prefs/archivecapture.xml`, which keeps photos).

### Capture UI refinements (2026-07-02, in v3.2.0)
- Middle button renamed **New doc → End segment**, moved **above** the thumbnail strip (shutter stays at the very bottom) to avoid accidental taps.
- Thumbnail strip **auto-scrolls** to the newest capture.
- Removed the top bar (title, upload count, Unpair) and the P10 hint text.
- Camera preview is now a **letterboxed top region** (`FIT_CENTER`) with controls in a panel below, rather than full-screen behind the controls.
- Added a **Clear** action (confirm dialog) that deletes all captured photos + resets the session (files + `session.json`).

### Post-v3.2.0 — committed locally as v3.2.1 (commit 3d7a5e2 + tag v3.2.1; push deferred, venue WiFi blocks SSL)
- Clear-all-photos action (Android).
- Stable Mac token (UserDefaults) + pinned port 48627 (fallback if busy) → phone reconnects across Mac launches with no re-pair.
- Per-photo delete (tap → X → delete) + select-then-Box/Folder to reclassify a photo as a single-image marker; P10 moved to long-press.
- `POTENTIAL_FEATURES.md`: wired-transport-without-USB-debugging feasibility analysis.
- **Performance (fixes the process-start beachball on full-res phone photos):** `GeminiClient.loadImageAsJPEG` (used by all providers) no longer full-decodes — it reads dimensions from the header and decodes straight to a capped **~2048 px** long edge, honoring EXIF orientation (no more ~50 MB/image buffers × concurrent workers). Vision LLMs downsample internally, so OCR quality is unaffected; the **PDF page-1 image and the archived original stay full-resolution** (produced separately). `exportOriginalImages()` (dual-output copy) moved **off the main actor**. `maxOCRDimension` is a tunable constant.
- **Resume Run beachball fixed:** the resume path was regenerating a full-resolution PDF for *every* already-completed file, synchronously on the main actor — even though the original run had already written those PDFs. Now it **reuses existing output PDFs** (usually all of them → resume is near-instant) and rebuilds only genuinely-missing ones **off the main actor**.
- **Thumbnail beachballs fixed (uncommitted, after v3.2.1):** review thumbnails were decoded synchronously in-body (a burst of main-thread decodes whenever a pane filled). Now **all three** load **off the main actor** (placeholder → async decode via a detached task → NSImage on main): `DocumentReviewRow` (segmentation review), `CollectionReviewRow` (collection review), and the shared `ArchiveThumbnail` (box/folder-confirm + manual-tag sheets + the Mac Live Capture strip). Closes the whole thumbnail-beachball class.
- **Capture size confirmed (2026-07-02):** phone captures are standard **JPEG, 4080×3060 (~12.5 MP), ~3.2–3.8 MB** — same as the Pixel camera app, **not RAW**, already ≤4 MB. The beachballs were Mac-side full-res *decoding*, not oversized files; no capture-size change needed (could pin JPEG quality/resolution for a hard ≤4 MB guarantee if ever wanted).
- **Unplug resilience** (phone can be unplugged easily): Mac re-asserts `adb reverse` every 5s (a dropped tunnel self-heals in ~3s — verified by removing the mapping and watching it return); phone **auto-retries** failed uploads every 8s. Capture keeps working offline (photos buffer, durable); on replug everything flushes automatically (idempotent ingest → no dupes), no manual Retry.
- Caveat: delete/reclassify only affect the phone; a photo already uploaded to the Mac isn't removed remotely (no delete endpoint) — best done before End segment while still PENDING.
- [ ] Smoother USB pairing UX: QR carries port+token; app offers **Connect over USB** (localhost) vs **Wi-Fi**; Mac auto-runs `adb reverse` when USB is chosen (bundle `adb`). Consider a fixed/known listen port for predictable USB pairing.
- [ ] Durable queue across process death (re-enqueue disk files on relaunch); reconnection/resume; retake/delete/reorder; mDNS auto-discovery; session save/reset.

---

## Key files
- **macOS new:** `Capture/CaptureModels.swift`, `Capture/CaptureSession.swift`, `Net/CaptureServer.swift`, `Views/LiveCaptureView.swift`.
- **macOS modified:** `ContentView.swift`, `OCR/OCRProcessor.swift`, `Views/OCRView.swift`, `Sources/ArchiveProcessor/Info.plist`, `project.yml` (Info.plist keys; later bundle `adb` for USB).
- **Android new:** `ArchiveCapture/app/` — `CaptureActivity`, Compose connect/capture screens, `SegmentTagSheet`, `UploadQueue`, `MacClient`, `SessionModel`, `RecentYears` store.

## Reuse (macOS)
`OCRProcessor.startProcessing`; `GeneratedTags`/`SegmentTagData`; `MacOSTagger.applyTags`; `ArchiveThumbnail`, `TagInputField`, `SystemTagsProvider`; `RotationDetector`/`LLMRotationDetector`; `NetworkSession`.

## Testing & cost policy (per CLAUDE.md)
- Do NOT modify `Test Files/`; write outputs only.
- No API keys in code. Before any paid run: test plan → cost estimate → request key. Prefer `gemini-2.5-flash-lite` / `claude-sonnet-4-6`.
- Phase 1 verifiable with curl + `dns-sd -B _archivecap._tcp` (no phone, minimal/zero API cost until the OCR step).

## Risks / notes
- Local-network permission prompt appears on first receive on current macOS — the Info.plist keys are required.
- Keep `project.yml` authoritative; regenerate the Xcode project rather than hand-editing `pbxproj`.
- Android app truly testable only on the Pixel (Phase 4); Phases 1–3 build/verify here.
