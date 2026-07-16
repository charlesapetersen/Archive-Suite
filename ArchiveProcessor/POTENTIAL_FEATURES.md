# Potential Features

> Forward-looking backlog only. Items that have since shipped (custom OCR prompts, custom tag vocabularies, CSV vocabulary import, multi-page merging, Compare Models, completion notifications, redo-tagging, live-capture resume, the OpenAI-compatible gateway, the Google Drive cloud-relay transport) have been removed from this list — see README.md for what ships today.

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
- **Tag editing UI** — edit applied tags directly in the file pane without reprocessing
- **Bulk tag operations** — apply/remove tags across multiple files at once
  _(Hierarchical/nested tags removed 2026-07-15 — owner: out of scope; the flat Finder-tag vocabulary in
  `SPEC/tag-format.md` stays the contract.)_

### Document Processing
- **Handwriting recognition mode** — specialized prompts and processing for handwritten documents
- **Table extraction** — detect and extract tabular data from documents into structured formats
- **Language detection** — identify document language and adjust OCR accordingly
- **Newspaper/periodical layout analysis** — handle multi-column layouts, headlines, captions

### Collection Management
- **Collection-level metadata** — assign metadata to entire collections, not just individual documents
  _(Nested collection hierarchy (Box > Folder > Document) removed 2026-07-15 — owner: out of scope.)_

## Lower Priority

### Performance & Scale
- → **Incremental processing** — process only new/changed files in a directory. **Promoted to the near-term
  queue** (owner, 2026-07-15) — now in [`SUITE_TODO.md`](../SUITE_TODO.md).
- **Distributed batch processing** — split large jobs across multiple API keys for faster throughput
- **Memory-efficient streaming** — stream batch results instead of loading all into memory

### UI Enhancements
- → **Dark mode optimization + global keyboard shortcuts** — **promoted to the near-term queue** (owner,
  2026-07-15) as one item in [`SUITE_TODO.md`](../SUITE_TODO.md): main-window shortcuts for start-processing /
  switch-provider (review + tag-card dialogs already have full keyboard nav) + a dark-mode render audit.

### API & Extensibility
- **First-class OpenAI/GPT-4o provider** — a native OpenAI provider (an OpenAI-compatible gateway already ships for custom/proxied endpoints)
- **Local model support** — integrate with Ollama or llama.cpp for offline processing
- **Plugin system** — allow custom classification and tagging plugins
- **REST API server mode** — run Archive Processor as a headless service for automation
- **Apple Shortcuts integration** — expose processing actions via Shortcuts app

### Data & Analytics
- → **Processing history + cost tracking** — **promoted to the near-term queue** (owner, 2026-07-15) as one item
  in [`SUITE_TODO.md`](../SUITE_TODO.md): persist each run (timestamp/settings/results) + its **actual** cost and
  surface a history view.
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

## iOS on-device testing (deferred — long-term; needs an iPhone)
**Policy (owner 2026-07-08): iOS *development* continues near-term as normal, but all iOS *on-device
testing* is postponed to this long-term list** until an iPhone is available. Code + mock-test iOS freely;
just don't gate near-term work on device verification. Deferred device checks:
- **Drive-relay live E2E** — phone→Drive→Mac on a real iPhone (sign-in, single photo, multi-page segment +
  Mac tag card, Box/Folder markers, Finish), mirroring the verified Android run. (The OAuth *implementation*
  — `ASWebAuthenticationSession` — is tracked as near-term dev in `SUITE_TODO.md`; only its on-device
  verification lives here.)
- **Camera capture + full connect/capture UX** — the simulator has no camera, so real capture, pairing,
  and the LAN / USB / cloud transports can only be verified on a physical device.

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
- → **Shared provider text-completion client.** `TagGenerator` and `CollectionSegmenter` duplicate ~85 lines of
  callLLM/callGateway/callAnthropic/callGemini/callMistralChat (differ only by max_tokens; already drifted on
  the Mistral signature). Extract one shared text client taking a maxTokens param. **Promoted to the near-term
  queue** (owner, 2026-07-15) — now in [`SUITE_TODO.md`](../SUITE_TODO.md).
- **Shared finalize/organize helpers.** startProcessing / resumeRun / resumeBatch each duplicate the
  "organize into collection folders" + run-completion blocks verbatim. Extract `organizeCollectionFolders` +
  `finalizeRun`. Touches the Tier-2 file-move path → adversarial-review before shipping.
- **Unify the box/folder color-retag logic** across applyReviewEdits / updateClassification /
  applyDocumentReviewEdits (three copies that have slightly drifted — confirm the intended behavior first).
- → **Smaller de-dups:** shared `highestLeadingNumber(in:)` (CollectionSegmenter + LiveCaptureProcessor);
  `ThinkingLevel.budgetTokens` + the Anthropic max_tokens bump (4 clients — budgets differ by call type);
  a shared transient-status friendly-message helper (4 OCR clients); one `acceptedImageExtensions` constant
  (3 files); shared `englishMonthNames` / `monthTag` (LiveCaptureProcessor + OCRProcessor); a segment-JSON
  schema builder (2 sites); OCRResult `.with(...)` copy helpers; `GatewayConfig.fromDefaults()` (3 views); a
  `liveProcessingMode` enum instead of "stage"/"live" magic strings; LLMRotationDetector.rotate →
  ImageEncoding.rotate; Gemini cancelBatch via the shared URL builder. **Promoted as one "de-dup sweep" item to
  the near-term queue** (owner, 2026-07-15) — now in [`SUITE_TODO.md`](../SUITE_TODO.md).
- ✅ **Value decision — recent-years cap:** the companions differed (iOS 5, Android 6). **Owner decided 2026-07-15:
  cap at 5** (change Android 6→5). Now a near-term item in [`SUITE_TODO.md`](../SUITE_TODO.md).

### Shared `ArchiveCore` Swift package — ✅ SHIPPED (W0, 2026-07)
Both stages shipped in the W0 refactor (`49c0162`–`b90800f`) — this is done, kept here only as a record:
- ✅ **3a — read-only shared model.** `packages/ArchiveCore/` (SPM, UI-free) holds the shared read model —
  `DocumentTags` + facet parsing, `PDFFormatStatus`, `TagSimilarity`, `DuplicateNames`, `FileLink`,
  `CopyTextCleaner`, links/thumbnails; both apps depend on it via local-package wiring in each `project.yml`.
- ✅ **3b — unified audited write path.** `ArchiveCore/Tags/TagWrite.swift`'s `CoordinatedTagWriter` unifies the
  audited write surface (trustworthy-read guard §3, verify-by-re-read multiset+label §8, inverse-delta undo);
  Reader's `TagWriter` and Processor's `MacOSTagger` both delegate to it, so the safety-critical tag code can no
  longer drift. The Reader Prime Directive + Processor Tier-2 guarantees are preserved.

### → Live Capture output-folder control — PROMOTED (owner, 2026-07-15)
Now a near-term item in [`SUITE_TODO.md`](../SUITE_TODO.md). (Motivated 2026-07-06: Process-live **Finish
session** wrote finalized collections to `~/Downloads/` with no way to choose; add an output-folder picker in
the Live Capture pane mirroring the Process-Files controls.)

### ✅ Phone "Finish" button — DECIDED 2026-07-15: remove it
Found 2026-07-06 that the phone "Finish" (`CaptureViewModel.finishSession()` → `POST /session/complete`) is
near-useless and misleading — the Mac handler only sets a status string, it does **not** start finalize.
**Owner decided 2026-07-15: option (c) — remove the button** from both companions (keep the harmless Mac
`/session/complete` route so older companions still work). Now a near-term item in
[`SUITE_TODO.md`](../SUITE_TODO.md). **End segment** stays the phone's only "done" action.
