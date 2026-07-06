# Potential Features

> Forward-looking backlog only. Items that have since shipped (custom OCR prompts, custom tag vocabularies, multi-page merging, Compare Models, completion notifications, redo-tagging, live-capture resume, the OpenAI-compatible gateway) have been removed from this list — see README.md for what ships today.

## High Priority

### Quality & Accuracy
- **OCR confidence scoring** — request confidence levels from the LLM and flag low-confidence pages for human review
- **Side-by-side original/OCR verification view** — show the original image alongside its OCR text in the main review flow (the Tools "Compare Models" tool already shows multiple model outputs side by side)

### Workflow
- **Processing profiles/presets** — save combinations of provider, model, tagging, and segmentation settings as named profiles
- **Queue system** — add files to a processing queue and process in the background
- **Undo/redo for review changes** — general undo across review dialogs (a redo-tagging loop already exists)
- **Resume interrupted processing (standard runs)** — persist non-batch Files-processing state across restart (Live Capture already resumes via its staging manifest)

## Medium Priority

### Tagging Enhancements
- **Tag suggestions from nearby documents** — use surrounding document context to improve tag accuracy
- **Hierarchical tags** — support nested tag structures (e.g., Politics > Elections > Presidential)
- **Tag editing UI** — edit applied tags directly in the file pane without reprocessing
- **Bulk tag operations** — apply/remove tags across multiple files at once
- **Import a tag vocabulary from CSV / drag-and-drop** — load a controlled subject-tag vocabulary from a CSV or text file. A parser (`loadTagVocabularyFromURL`) existed but was never wired to any UI, so the README wrongly advertised it; the dead code was removed in the 2026-07-04 maintainability pass. Re-add with a file picker + a drop target on the vocabulary editor.

### Document Processing
- **Handwriting recognition mode** — specialized prompts and processing for handwritten documents
- **Table extraction** — detect and extract tabular data from documents into structured formats
- **Language detection** — identify document language and adjust OCR accordingly
- **Newspaper/periodical layout analysis** — handle multi-column layouts, headlines, captions

### Collection Management
- **Nested collection hierarchy** — support sub-collections (Box > Folder > Document)
- **Collection-level metadata** — assign metadata to entire collections, not just individual documents

## Lower Priority

### Performance & Scale
- **Incremental processing** — process only new/changed files in a directory
- **Distributed batch processing** — split large jobs across multiple API keys for faster throughput
- **Memory-efficient streaming** — stream batch results instead of loading all into memory

### UI Enhancements
- **Dark mode optimization** — ensure all custom views render correctly in dark mode
- **Global keyboard shortcuts** — main-window shortcuts for start-processing / switch-provider (review and tag-card dialogs already have full keyboard navigation)

### API & Extensibility
- **First-class OpenAI/GPT-4o provider** — a native OpenAI provider (an OpenAI-compatible gateway already ships for custom/proxied endpoints)
- **Local model support** — integrate with Ollama or llama.cpp for offline processing
- **Plugin system** — allow custom classification and tagging plugins
- **REST API server mode** — run Archive Processor as a headless service for automation
- **Apple Shortcuts integration** — expose processing actions via Shortcuts app

### Data & Analytics
- **Processing history** — track all processing runs with timestamps, settings, and results
- **Cost tracking** — cumulative cost reporting across all processing runs
- **Accuracy metrics** — compare OCR results against ground truth files for benchmarking
- **Tag frequency analysis** — show most common tags, date distributions, subject clusters

---

## Live Capture — Wired Transport Without USB Debugging (feasibility)

The v3.2.0 Live Capture wired mode uses `adb reverse`, which requires **USB debugging** (Developer Options) + a per-computer adb authorization + `adb` on the Mac. That is fine for personal/small-scale use but **cannot ship in a wide-release app** — you can't ask general users to enable Developer Options and trust an RSA key. A normal Android app also cannot open a USB data channel to a host except through the sanctioned USB APIs, so "no debugging" means dropping adb entirely. Options, in order of practicality:

1. **Wi‑Fi instead of USB (easiest, wide-release-ready).** Already supported via QR/manual LAN pairing. For a broad release this is the pragmatic primary transport; wired becomes a power-user extra. Downside: needs a shared network (the reading-room problem).

2. **USB tethering (no Developer Options, but fragile on Macs).** The user toggles Settings → Hotspot & tethering → USB tethering, creating a real network link over the cable; the app does HTTP over it — no debugging/authorization. **But** Android tethering uses RNDIS, which modern Apple‑Silicon macOS does not support without a kernel driver (kexts are largely dead on current macOS). Some newer devices offer NCM (better macOS support) but it's inconsistent. Consumer-friendly on the phone, unreliable on the Mac today — not safe to ship.

3. **Android Open Accessory (AOA) — the proper wide-release wired path.** Android's sanctioned way for an app to talk to a USB *host* with no debugging/root. The Mac acts as USB host via **libusb** (pure user-space, no kext), sends AOA control requests to switch the phone into accessory mode, then bulk-transfers; the Android app implements the `UsbAccessory` side and gets a standard one-time "Allow this app to access the USB device?" prompt (not Developer Options). Distributable and robust, but real engineering: a custom framed protocol on both sides plus a libusb host embedded in the Mac app. Moderate-to-high effort.

**Bottom line:** feasible for wide release, but only by adding **AOA** (option 3) — a real project, not a flag. USB tethering (option 2) is too flaky on current Macs to rely on. Recommended posture for a broad release: make **Wi‑Fi the primary transport**, keep `adb reverse` as a documented power-user/dev option, and invest in **AOA** only if wired-for-everyone becomes a hard requirement.

---

## App-Store Distribution — Phase 4 (deferred)

The distribution initiative is complete through **Phase 3**: guided
BYO-key onboarding (Gemini + Mistral, both confirmed free with no card), and an **iPhone capture
companion** (`ArchiveCaptureiOS/`) alongside the Android one — the shipped story is documented in
README.md and CLAUDE.md. **Phase 4 — publishing the companion
apps to the App Store and Google Play — is intentionally deferred** and captured here for the future.

Phase 4 is mostly **owner (not Claude) work**, because it needs paid accounts, real hardware, and
signing identities Claude cannot access:

- **[USER] Apple:** enroll in the Apple Developer Program ($99/yr); create the App ID, signing
  certificate, and provisioning profile; run the iOS companion on a physical iPhone to smoke-test the
  camera + LAN pairing (the simulator can't exercise the camera); archive and upload via Xcode /
  App Store Connect; complete the App Privacy questionnaire; submit for review.
- **[USER] Google:** create a Google Play Console account (one-time $25); generate an upload key and
  sign the Android app bundle (`.aab`); complete the Data Safety form; submit.
- **[USER] Assets:** capture screenshots / a short screen-recording of each companion for the store
  listings (Claude can't produce device screenshots of a live camera session).

What **Claude can draft on request** (no accounts needed): the privacy policy, the Play **Data
Safety** form answers, the Apple **App Privacy** "nutrition-label" answers, the store descriptions /
keywords, and the in-app BYO-key onboarding copy. Because neither companion holds API keys or sends
data anywhere except the user's own paired Mac over the LAN, the privacy story is simple (no data
collection / no third-party sharing) — which keeps the questionnaires short.

**Feasibility note:** every code artifact Phase 4 needs already exists and builds; the blockers are
purely account/identity/asset steps that require the owner. Nothing here needs new engineering unless
review feedback demands a change.

### Open decisions & logistics (migrated from the retired distribution plan)

- **Android `targetSdk` 36** becomes mandatory for Play updates ~**2026-08-31**; `ArchiveCapture/app/build.gradle.kts` is still on `targetSdk 34` and must be bumped before that submission.
- **Play closed-testing gate:** new personal Play Console accounts must run a **closed test with ≥12 testers for ≥14 days** before production access — plan for that lead time.
- **[D1] macOS distribution channel (UNDECIDED):** Mac App Store (free) vs. a notarized Developer-ID DMG. Today the Mac app ships as an owner-only, ad-hoc-signed DMG (see CLAUDE.md → Releasing).
- **iOS "minimal functionality" risk (App Store guidelines 2.1 / 4.2):** the companion is useless without the paired Mac, so the listing and first-run must clearly state the Mac-app dependency.
- **[D3] first-run wizard behavior:** forced vs. dismissible banner — verify against the shipped `ContentView` first-run flow before treating as open.
- **Provider caveats to keep in the in-app copy:** Gemini's free tier may train on inputs and requires the **paid** tier in the EEA/UK/CH (already handled by a locale pre-warn); free-tier rate limits are dynamic — keep copy provider-agnostic / user-refreshable rather than hardcoded.

## Maintainability / refactor backlog (deferred from the 2026-07-04 audit)

Behavior-preserving de-duplication/refactors surfaced by the maintainability audit but deferred because they
either consolidate copies that have already DRIFTED (so unifying is a behavior decision, not a safe merge),
touch the Tier-2 file-move/finalize path, or are large mechanical sweeps better done as one focused pass. Each
is safe to pick up individually; prove equivalence + build before/after. Item-by-item detail (file:line,
safety, verdict) is in audit run `wf_4373722d-e70`.

- ~~**Central `DefaultsKey` constants for the ~35 @AppStorage keys (flagship).**~~ **DONE** (2026-07-04):
  `Models/DefaultsKeys.swift` now defines all 37 durable-settings keys once and every `@AppStorage` / `forKey:`
  call site references it; values verified byte-identical to the originals so saved settings are preserved.
- **Shared provider text-completion client.** `TagGenerator` and `CollectionSegmenter` duplicate ~85 lines of
  callLLM/callGateway/callAnthropic/callGemini/callMistralChat (differ only by max_tokens; already drifted on
  the Mistral signature). Extract one shared text client taking a maxTokens param.
- **Shared finalize/organize helpers.** startProcessing / resumeRun / resumeBatch each duplicate the
  "organize into collection folders" + run-completion blocks verbatim. Extract `organizeCollectionFolders` +
  `finalizeRun`. Touches the Tier-2 file-move path → adversarial-review before shipping.
- **Unify the box/folder color-retag logic** across applyReviewEdits / updateClassification /
  applyDocumentReviewEdits (three copies that have slightly drifted — confirm the intended behavior first).
- **Smaller de-dups:** shared `highestLeadingNumber(in:)` (CollectionSegmenter + LiveCaptureProcessor);
  `ThinkingLevel.budgetTokens` + the Anthropic max_tokens bump (4 clients — budgets differ by call type);
  a shared transient-status friendly-message helper (4 OCR clients); one `acceptedImageExtensions` constant
  (3 files); shared `englishMonthNames` / `monthTag` (LiveCaptureProcessor + OCRProcessor); a segment-JSON
  schema builder (2 sites); OCRResult `.with(...)` copy helpers; `GatewayConfig.fromDefaults()` (3 views); a
  `liveProcessingMode` enum instead of "stage"/"live" magic strings; LLMRotationDetector.rotate →
  ImageEncoding.rotate; Gemini cancelBatch via the shared URL builder.
- **Value decision:** the recent-years cap differs between the companions (iOS 5, Android 6) — pick one.

### Live Capture transport — bypass networks that block device-to-device
Motivated 2026-07-06: on airport/guest/hotel/CGNAT Wi-Fi with **client isolation**, phone↔Mac LAN
connections are blocked, so QR/Wi-Fi pairing can't work at all (see KNOWN_ISSUES for the silent-failure UX
gap). USB already bypasses this. Options, cheapest first:

- **Personal-hotspot guidance (zero code).** Tell the user to put the Mac + phone on a personal hotspot
  (phone's own, or the Mac's) — a private AP with no client isolation, so the existing LAN path just works.
  Document it in-app as the first fallback; near-free to add.
- **Peer-to-peer, no infrastructure Wi-Fi.** Connect the two devices directly, independent of the AP:
  iOS `MultipeerConnectivity` (AWDL/Bluetooth/peer-Wi-Fi) for the iPhone companion; **Wi-Fi Direct /
  Nearby Connections** on Android. Bypasses AP isolation entirely, no cloud, no cable. Medium effort; a
  new transport behind the same segment-transfer protocol (`CaptureServer` becomes one of several transports).
- **Cloud relay (works anywhere, incl. remote).** Phone uploads each captured segment to a cloud store
  (user's Google Drive / Dropbox / iCloud, or a small object store), Mac watches/pulls and feeds the same
  ingest path. Pros: works across *any* network and even off-site. Cons: needs cloud auth (fits the
  existing "managed access / BYO keys" initiative), and archival photos transit third-party storage —
  **privacy call the owner must make**; make it explicit + opt-in. Largest effort; keep the durable
  disk-queue + idempotent re-upload semantics so "never lose a photo" still holds across a relay.
- **Reachability preflight + honest diagnostics** regardless of transport (the KNOWN_ISSUES fix): never
  let the phone sit on a dead scanner — detect unreachability and name the cause + the fallbacks.

### Live Capture output-folder control (in the Live Capture pane)
Motivated 2026-07-06 during the Android walkthrough: a Process-live **Finish session** wrote the finalized
collections to **`~/Downloads/`** with **no visible way to choose where** — the operator had to hunt for
the output. Add an explicit **output-folder picker in the Live Capture pane** (the tagging-mode dropdown +
output folder already live in the Process Files view — mirror that here) so live-captured collections go
where the user wants. Show the current destination on the pane; default sensibly (last-used, or a
dedicated "Archive Processor" folder rather than Downloads). Per the settings-UX convention, give it a `?`
help popover and gray it out when irrelevant. Confirm whether live finalize currently reuses the Process
Files `outputDirectory` or has its own — and unify if it makes sense.

### Decide the phone "Finish" button's purpose — currently near-useless
Found 2026-07-06: the phone capture screen has **"End segment"** (finishes the current document — essential)
and **"Finish"** (`CaptureViewModel.finishSession()` → `MacClient.sessionComplete()` → `POST
/session/complete`). But the Mac handler (`CaptureServer.swift:242-244`) does **only** one thing on
receipt: sets `statusMessage = "Session complete — ready to process."` and returns OK. It does **not**
start the finalize flow (rotation review → collection naming → output) — the operator must still go to the
Mac and click **Finish session**. So the phone "Finish" is a weak "I'm done capturing" nudge, easily
mistaken for actually finishing. **Decision:** either (a) make phone "Finish" actually initiate/enable the
Mac's finalize flow (let the operator wrap up from the phone without walking to the Mac — most useful), or
(b) relabel it (e.g. "Tell Mac I'm done") so it's not mistaken for finalizing, or (c) remove it. Keep both
companions in sync.
