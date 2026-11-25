# Archive Processor — Project Guide

@AGENTS.md

## Overview
A native macOS app for processing collections of historical archive photographs: (1) OCR via LLM models, (2) macOS filesystem tagging, (3) Live Capture from the phone companions, which this guide also covers.

This guide holds the rules and commands for every agent. Reference detail (model lists, per-function descriptions, the
**Implementation map**) is in [`REFERENCE.md`](REFERENCE.md), read on demand; it never relaxes a rule here.

## ⛑️ Recovery Core Directive (data safety) — bulletproof AND always recoverable

This app writes **irreplaceable data** (archival photos that can't be re-shot). Every change to the
capture/finalize/output path (`Capture/`, `Net/`, `Tagging/`, PDF/image output) keeps **both** guarantees ($0 check: `LIVECAPTURE_RECOVERYTEST=1`):
1. **Bulletproof** — the happy path never loses data: durable-manifest-before-ack, idempotent `(group,seq)`,
   drain-gated finish, crash-resumable staging.
2. **Strong recovery points** — when the app fails anyway (bug, crash, bad move, wrong folder), the operator can
   still get the files back: design every destructive step so failure is **recoverable**, not just unlikely.

Three non-negotiable rules (2026-07-07, after a finalize deleted a run's originals — `KNOWN_ISSUES.md`):
- **Confirm before you delete.** NEVER delete a source photo until its output is *verified on disk at the
  destination* (`executePlans` → `filedGroupIds`), **never** off "we staged it" / "finalize returned no hard
  error". A silently-missing output keeps its source.
- **Trash, don't `rm`:** capture-data deletions go through `CaptureSession.trashOrRemove`, never
  `FileManager.removeItem`, so a wrong call stays recoverable.
- **Keep a second copy until it's safe:** raw photos **and** processed PDFs/JPGs/JSON (with tags) stay in the
  **visible backup folder** (`<session>/`, `<session>/_processed/`) until finalize confirms the destination has
  them; never hidden or hard-purged while a run is in flight.

Any edit to these paths is Tier-2 (adversarial review + a functional test on scratch copies). If "bulletproof"
and "recoverable" seem to conflict, ship both — err toward keeping data.

## OCR rules (Primary Function 1)

- **Built-in models** are the REFERENCE.md §LLM Provider & Model Selection lists (`Models/ProviderModels.swift`);
  don't silently add others. OpenRouter's benched routes (`OpenRouterRoute.catalog`, makers' endpoints in
  `makerRoutes`) stay pinned as benched (`provider.order`, `allow_fallbacks: false`, open models at their
  `quantizations`, temp 0) and stand for their maker's model (`LLMModel.measuredModel`). Any other image model in the
  listing, or any id typed in Manage custom models, is unpinned (`OpenRouterRoute.unpinned`: no provider order,
  OpenRouter's fallbacks on), marked not measured, always `data_collection: "deny"`; a typed id
  with no listed price is `LLMModel.unpriced` (no estimate, no ceiling, the note says so); an id neither listed nor
  typed gets no client. `max_price` is the price the run's estimate showed (`OpenRouterRoute.ceiling`); segmentation's
  OpenRouter voter keeps the bench's prices. Claude 4.7+ refuse a `budget_tokens`. Price sources, key-only routing:
  REFERENCE.md §"OCR, Live Capture and Releasing rules — full wording".
- **One way to read a page** (W42.int-s2): every client is a VisionOCRKit `PageReader`, and `PageReaders.reader`
  (`OCR/PageReaders.swift`) is the only place that picks one (Local Agent, then gateway, then provider). Never call a
  client's `ocr` elsewhere: `scripts/check-page-reader-seam.sh` fails on it, and on a provider with no reader.
- **One owner of app-managed local models** (W49.proc-local-model-supervisor): `LocalModels/LocalModelSupervisor.swift`
  installs the one uv/Python/mlx-vlm runtime and runs `LocalModelWorker.py`, one model resident at a time (the old one
  has exited before the next loads; none over 10 GB), with Live-Capture-aware keep-alive and `withStage` for a stage
  that reads many pages with one model. Never start a Python/MLX process elsewhere: `scripts/check-local-model-seam.sh`
  fails on it. Contract: the `S` lines of `scripts/test-local-models.sh`.
- **One post-OCR tail** (W49.proc-unified-pipeline-1): every Process Files route ends through
  `OCR/OCRProcessor+PostOCRFinalizer.swift`; `scripts/check-pipeline-seam.sh` fails a copied stage. A run that journals
  each reading first (a standard run, its resume) writes each output PDF once there, after the reviews
  (`materializeDeferredOutputs`, W49.proc-unified-pipeline-2); a paid batch and a retry after the run write at once.
  Contract: `scripts/test-deferred-output.sh`.
- **The macOS 27 on-device model** (`OCR/OnDeviceModelClient.swift`, W47.wh-readers-lost-clients) is the second
  Apple Vision model (`apple-fm-27`), chosen only on the reading card (lower-scoring, owner call 15); its loop stop
  fails a page whose reply starts repeating, as a page at the token cap fails on every client.
- **Apple Vision** is additive, never the default. Its optional text-only judgement call goes to a **direct** LLM
  with the extracted text only — no image bytes, image URL, gateway or Local Agent. With judgement and image correction
  off, Vision is fully offline (No tagging / Copy source tags only).
- **A failed reply is never a transcription:** an OpenRouter 200 with `finish_reason` error, or an in-body provider
  error, is a failed page (503, retried); every client fails a cut-off reply as `length`, never saving cut text.
- **Cascade** (`OCR/OCRCascade.swift`, off by default) never escalates transport errors, timeouts, 429/503/529,
  key/quota/request errors, a remote gateway, the Local Agent or Apple Vision as first reader; a per-run breaker
  bounds spend. Contract: `scripts/test-ocr-cascade.sh`.
- **Institutional computing import** matches only on the image's SHA-256 with model and nonblank `cluster`
  recorded (never filenames or institution; missing provenance matches nothing), rechecked at use; Retry/Rotate always
  reads fresh; read-only on the bulk folder and inputs; direct non-batch path only (never gateway, Local Agent,
  Vision or pre-OCRed input); header labels sanitised (separator, one line); estimates count every page.
  Contract: `scripts/test-institutional-compute-import.sh`.
- **Page-kind routing** is off by default. Contract: `scripts/test-ocr-page-kind.sh`.
- **Read-poorly flag** (`OCR/ReadQualityFlag.swift`, `ReadQualityDisagreement.swift`) is UI only, never written to a
  file. Vision's own reading: character-weighted line confidence under 0.9815, only under the default Vision settings it was fitted with.
  Another reader: its text disagrees with Vision's reading of the image past that reader's own cut (`post_read_flag.py`
  `app_readers`, which checks the Swift table); a route the bench has not read has no rule. The run summary names the
  files and what each cut was measured on, the history counts them, rebuilds pass it on. Contract:
  `scripts/test-read-quality-flag.sh` (and section 4b of `scripts/test-local-models.sh`).
- **A model on this Mac** always sends the stand-in bearer `local`, never a saved key; escalating its failed pages
  is off by default (pages may be meant to stay on the Mac). Its measured limits (4,096-token cap, streamed
  repetition check + one re-read with a repetition penalty, 600 s → `length`, temp 0, one page at a time) are required. Contract: `scripts/test-local-models.sh`.
- **Gateways and the Local Agent skip batch. Remote gateways support LLM rotation.** Local Agent (`OCR/LocalAgentClient.swift`): no shell,
  prompt on stdin not argv, absolute-path binary, per-call timeout, friendly errors (never raw stderr), **CLI-owned login**,
  with API charges reported for a key-backed Claude sign-in; only `claude` is validated (`gemini`/`codex` are `VERIFY`
  placeholders); `runAsync` signals exit via `terminationHandler` (`waitUntilExit()` on GCD missed exits) and kills
  its child on cancel. Precedence localAgent > gateway > direct; concurrency 1–2
  + usage-window pacing; the header/history keep the model override or `CLI default` and never price the
  direct-provider fallback. At 90% of the five-hour meter or at a hard usage limit, new Claude subscription reads wait
  for the reset and resume on the plan. $0 harness: `scripts/test-localagent.sh`.
- **Requirements:** Low/High thinking where supported; a live cost estimate before processing, standard vs batch
  side by side, **reflecting the batch discount** (batch totals require batch mode, a direct provider, and
  fresh OCR). Vision, Local Agent and unpriced gateways show a billing note. Batch toggle; parallel workers.
  Input: drag-and-drop or open panel; JPEG, PNG, TIFF, HEIC, PDF (pre-OCRed: PDFs only). Model
  defaults (REFERENCE.md) are item decisions: don't change them silently. A live-key OCR smoke is the final OpenAI model-ID check.
- **Output: each input image → one PDF, same base filename.** Page 1 the image; page 2 the text under `Extracted
  text.` and `[Provider] · [Model] · [Day Month Year]`. **Critical: page 2 is arbitrarily tall — all text on one
  page, never a third**, well-formatted and laid out. No text → `No text returned by model.` + the error code/reason. Show Gemini's
  `"Recitation"` refusal clearly. The batch log is opt-in (`DefaultsKeys.writeLogFile`, off) and lists each failed file with its error reason.

## Tagging rules (Primary Function 2)

- **The tag vocabulary + 2-page PDF format are specified in [`../SPEC/tag-format.md`](../SPEC/tag-format.md);**
  a change to what is written updates that SPEC and the Reader together (Tier-2).
- **Segmentation** is inferred: a box photo → new box, a folder photo → new folder; document heuristics in
  REFERENCE.md §Document Segmentation.
- **Date tags (most important):** year `1968` or decade `1970s` (a decade only typed by hand; the LLM never emits it; written verbatim);
  month `MM Month`. Date undetermined: estimate the year from surrounding documents, **never estimate the month**,
  always add `Date Uncertain`.
- **Typing a date:** each card has one Date field, read by ArchiveCore `DateFieldEntry.archiveDate` (the suite's one
  date field), stored as the same Year/Month/Day strings (`Tagging/TypedDateTags.swift`); Sent with is folded below it. Unreadable text disables Save. Live Capture keeps a year and month.
- **Subjects:** 2–6 per document, general but not too general. Box photos → `Red`; folder photos → `Purple`.
- **`Unread`**: every output (PDF **and** any exported original) gets it, applied **last**, only in real-tagging
  modes (`.automatic`/`.autoDate`/`.human`), never "No tagging" or "Copy source tags"; via the **required**
  `stampUnread:` of `MacOSTagger.applyTags` (from `TaggingMode.stampsUnread`), no ambient flag (W16.cfg6-fu).
- **No tagging** and **Copy source** mark label PDFs with Collection ID. Copied tag names stay verbatim.
- **A refused Finder-tag write or a placeholder image page is REPORTED**, never swallowed by `try?` (W23.m5/h5-fu;
  `PROCESSFILES_TAGWARN_TEST=1`).
- **Quality** crosses the capture protocol as `Q1`–`Q3` (omitted = Unrated) and is written to Finder as that token.
- **API efficiency:** batch OCR results and reuse OCR text. Image passes are gateway dating and item fields, optional
  local 8B dating, and the local 8B item-field call (owner call 23). The Mac item-field calls share a fresh Vision read.

## Live Capture rules (Primary Function 3)

- **The phone holds no API keys** (the Mac does OCR + tagging).
- **Never lose a photo.** A page is marked sent only after the Mac's durable ack. Every receiver, on every
  transport, goes through `CaptureSession.ingest(...)`: manifest written **before** the ack, idempotent on
  `(group, seq)`, ack only on a durable return; only then does the phone delete its sole copy.
  The phone queues each photo durably on disk with auto-retry and keeps captured items across a disconnect/Re-pair,
  re-uploading to the new endpoint. **The Mac deletes a Drive relay object only after durable receipt.**
- **"End segment" is the phone's only "done" action** — grouping and tags, never a gate on byte transfer. Tag
  cards appear only for *completed* segments; **Finish is drain-gated** on the phone's heartbeat.
- **The protocol and [`../SPEC/relay-object-format.md`](../SPEC/relay-object-format.md) change on all sides together.**
- **Drive relay** ([`ArchiveCapture/README-oauth.md`](ArchiveCapture/README-oauth.md)): ⚠️ the Android OAuth client
  ID is **NOT in git** (gitignored `ArchiveCapture/local.properties`; iOS: gitignored
  `ArchiveCaptureiOS/Config/DriveLocal.xcconfig`); the Android ID is bound to package + signing SHA-1 and needs
  **"Custom URI scheme" enabled**; an unconfigured build still compiles, LAN/USB unaffected. Scope
  `drive.file`; Drive/ChatGPT tokens and the Mac's `DriveClientSecret` live in the Keychain (iOS: this device only);
  the phone has no secret. The ChatGPT plan route sends `store: false`; only a completed response answers.
  **Mac and phone sign in to the same Google account**, the Mac before Start (a mid-session sign-in waits for the
  next session; owner-accepted, A5). The iPhone uses the relay only by an explicit Cloud choice, never on its own.
- **Rejected transports (don't re-open):** personal hotspot, MultipeerConnectivity/AWDL, Bluetooth, AirDrop /
  Quick Share. No Mac-side transport picker (A5, removed as a footgun).
- **LAN security — accepted risk (owner, 2026-07-18):** plaintext HTTP + persistent bearer token; no TLS/AEAD, no
  companion changes, no packet-capture harness — **do not re-promote LANSEC-5/6/7 or the crypto redesign.** It rests
  on the shipped mitigations, which stay: high-entropy `lanToken` + failed-auth backoff, header-first admission,
  connection/memory caps, `constantTimeEquals`, both receivers' `isSafeGroupId` path-traversal guard. Untrusted Wi-Fi: USB
  (either phone) or Drive relay; LAN only on a trusted network. The Drive-relay code never authenticates the LAN server. Pairing is QR-only. Record: `KNOWN_ISSUES.md` §"Live Capture LAN channel".
- **Backup folder:** legacy staging is read in place, not migrated; launch pruning never removes a folder still holding a photo
  *or* a `_processed` output.
- **Finish-window rules**, each load-bearing (`KNOWN_ISSUES.md` §"REFERENCE: the shared Processing pane during a
  finish"): `retryFailed` itself refuses every Live retry while `isFinalizing`, not only the view. A finish is
  **held** (`proceedToFinishIfReady`) while a per-item sheet is up, so sheet targets live on `LiveCaptureProcessor` —
  ⚠️ a view `@State` target compiles and silently disables the guard, untested. The scrim freezes the pointer only;
  keyboard/VoiceOver rely on `.disabled`. An emptied Captured pane still offers Finish and Clear while
  `hasUnfiledWork`; Finish is also `.disabled` on the narrower `canFinish`; the two gates stay separate. Failure
  taxonomy is label-only (Tier-2): `labelStagedRecord(...)` is the ONE labeller and never changes a
  finalize/deletion decision (that keys off `filedGroupIds` + `pagesComplete`).
- **Retries reproduce the immutable run/session backend** (W25.retry-backend): no provider/model picker; the one
  per-item retry sheet controls rotation; `rotationRetryTarget` stays in the finalization guard and cannot alter
  routing or credentials.

## Test Files
- `Test Files/` is gitignored — **no recovery via git**; a slimmed minimum (REFERENCE.md §Test Files).
- **Don't modify the surviving files or delete the ground-truth folders** (`Ground Truth Segmentation/`,
  `Collection Segmentation*/`) — they back the smoke/tier-2 tests. Create outputs only, never inside `Test Files/`.

## API Keys & LLM Calls
- **LLM/API calls are allowed and expected**; the constraint is **cost, not permission**.
- **Never store API keys in code or config files** — Keychain or user-provided at runtime only.
- Before any **paid** run: (1) a short test plan, (2) estimate the cost **and state it**, (3) an already-provisioned
  key (`$OCR_KEY` / Keychain). No per-item owner grant (`../AGENTS.md` §*Gating baseline*), but $7 of real money per
  piece of work is the ceiling without asking: if this run plus what the item has already spent would pass $7, ask
  first (unattended: in the Daemon Report; root `../CLAUDE.md`). Also ask if no key exists for that provider.
- Keep costs low: the cheapest capable model as `../ArchiveOCRBench/` currently measures it, the smallest
  input set that proves the behaviour.

## Concurrent / multi-agent development

**Worktree-first is mandatory** (root [`../CLAUDE.md`](../CLAUDE.md)). Quote paths (they contain a space). Run
`xcodegen generate` in each new worktree (`./bootstrap.sh` after a clone). Each worktree gets its own DerivedData:
```bash
xcodebuild -scheme ArchiveProcessor -configuration Debug -derivedDataPath ./build/DD build
(cd ../ArchiveCaptureiOS && xcodegen generate && \
 xcodebuild -scheme ArchiveCaptureiOS -destination 'generic/platform=iOS Simulator' -configuration Debug -derivedDataPath ./build/DD build)
```
`-derivedDataPath` does **not** isolate the shared user-level Clang cache (`CACHE_ROOT`) — not fully sandboxed.

**Ownership lanes** (one instance per lane): Android `ArchiveCapture/`; iPhone `ArchiveCaptureiOS/` (Swift 5;
gate step `ios-build`); macOS OCR core `Sources/ArchiveProcessor/{OCR, Models, Capture, Net}`; macOS Views +
Tagging `{Views, Tagging}`.

**Shared hotspots (coordinate across lanes):**
- **`Models/ProviderModels.swift` enums** (`LLMProvider`, `ThinkingLevel`, `DocumentClassification`,
  `TaggingMode`, `RotationMode`) are `String`-backed and persisted: **never rename a case or change an explicit
  rawValue** (orphans saved settings); appending is safe. `LocalAgentConfig` is append-only (rides the run snapshot).
- **Phone↔Mac protocol:** `Net/CaptureServer.swift` ↔ both companions' `MacClient`, and
  `Net/RelayObjectFormat.swift` ↔ the phones' mirror (`scripts/test-relay-golden.sh` checks iOS). Change all sides
  together. Keep UIKit, AVFoundation and Photos out of iOS `Capture/CaptureQueue.swift`, `CaptureModels.swift` and
  `SessionStore.swift` (host-tested, `scripts/test-ios-capture-queue.sh`); an iOS queue fix adds its failing test
  to `HostTests/`.
- **The two `project.yml` files.**
- **`packages/ArchiveCore`:** `CoordinatedTagWriter` is the single Finder-tag write choke-point; no app calls
  `setResourceValue` directly. A change here is **Tier-2** and must build+test **all three** apps (Reader +
  Processor + Notes), plus `swift test` in `packages/ArchiveCore`. SPEC: `../SPEC/tag-format.md`.

**Rules:** never hand-edit `.pbxproj` (edit `project.yml` + `xcodegen generate`, also after clone and when adding
files, including in `ArchiveCaptureiOS/`); keep commits small and rebase often; build-verify before every commit.

**Code-structure rules** (REFERENCE.md §Project Structure, §Implementation map):
- `OCRProcessor` methods go in the matching per-area `OCRProcessor+<Area>.swift` extension (Pipeline, OCR, Tagging,
  ReviewFlows, WindowSegmentation, MixedPDFRecovery; types in `+Types.swift`). Keep them coarse: a new file only for a
  new pipeline area. **All stored properties stay in `OCRProcessor.swift`**.
- A move-only refactor: run the move-proof **tty-independently** (piped, it passes for any commit), census-diff
  private members, gate on a warnings delta (beware a cached "0 warnings"). `LiveCaptureTestDriver` does **not** exercise the batch GUI path.
- `Tagging/` is Tier-2; `Segmentation/` is not (writes nothing). `WindowPrompts.swift` is verbatim from the bench
  (a test compares byte for byte). `enclosureOf` uses the OCR `[enclosure]` marker, never adjacency. `PlanUsage`
  reads its meter from the CLI stream; `PlanRunGate` pauses at a 90% five-hour meter; Claude/ChatGPT routes ask "key or
  plan" only when both exist. A segmentation gap no window answer covered is flagged at 0 (contract:
  `execution-plans/segmentation/04-options-build.md` Part 3 §2). Segment `.json` sidecars come from
  `SegmentJSONBuilder`; callers write atomically. Single sources: `DefaultsKeys` (defaults keys),
  `LLMModel.openaiModels` (OpenAI IDs/pricing); `NetworkSession` is the request choke point; `ImageEncoding` output
  is byte-identical across providers. `nonisolated(unsafe)` only for write-once statics. No Spotlight (W26.vocab).

## Verification & review policy (no human in the loop)

No human reviewer or CI, irreplaceable data, real money: verification is **tiered by risk** (2026-07-04).

**Tier 1 — every commit:** clean build, **no new warnings** (`xcodegen generate` + `xcodebuild … build`); self-review
the diff (`/code-review`, or read it critically).

**Tier 2 — anything with no undo, any diff size:** a multi-agent *adversarial* review plus a targeted functional
test where feasible, for edits to `Capture/`, `Net/` (durability, protocol, crash-recovery/manifest); file-writing
tag/output code (`Tagging/MacOSTagger.swift`, PDF/image output, collection numbering that could **overwrite**
files); batch/manifest persistence; `@MainActor`/`Sendable`/actor isolation. **For `Capture/`/`Net/` the
functional test is `scripts/e2e-phone-mac.sh`.**

**Tier 3 — before every release:** a multi-agent *find → refute* review of the whole diff since the last release,
plus a **live smoke test** if the OCR/tagging/PDF path changed. Release only when clean.

**Always adversarially *verify* findings before acting:** a second agent tries to refute each (default "not a bug").

**Env-gated drivers are Debug-only (W40.a5):** every `*TestDriver.swift`, `SegmentationProofDriver.swift`,
`*Contract.swift`, their `ContentView` dispatch and `NetworkSession.activeTestTransport`'s stub branch sit whole in
`#if DEBUG`, and a new driver too (`scripts/lint-release-drivers.sh` fails one without); scripts run Debug.
`nm <Release binary> | swift demangle | grep -E 'TestDriver|Contract'` must print nothing.

**Smoke tests** before pushing an OCR/pipeline change: `ArchiveProcessor/test-smoke.sh` (headless real pipeline,
2 tiny images, a few cents; Keychain key, never printed or persisted; scratch I/O only, never `Test Files/` or a real corpus); `./test-smoke.sh
archivecore|processor|reader|notes|all` (Suite root); `scripts/test-smoke.sh`, `scripts/test-tier2.sh`.

**Visual:** XCUITest sees no pixels. UI runs off-screen in the VM: `ops/gui/vm-gui-runner.sh processor xcuitest` ($0; headless, guest `mktemp` paths: no key, CLI
login or real corpus) or
`… processor sighted` (pixels). See `AGENTS.md` → *GUI verification*.

**Phone↔Mac E2E** (`scripts/E2E-PHONE-MAC.md`): `OCR_KEY=<key> caffeinate -di ArchiveProcessor/scripts/e2e-phone-mac.sh`
(a few cents): the Tier-2 gate for `Capture/`/`Net/`, **not** per-commit. Needs the Mac free + awake (don't drive
its GUI meanwhile). Auto-finalize is gated on `LIVECAPTURE_TESTOUT` so it can never file into the real corpus; its
inject seam is debug-only. Prerequisites and pairing (never USB): REFERENCE.md §Verification & review policy.

**Cadence:** push often (clean build + Tier-1, plus Tier-2 where it applies); a DMG + GitHub release is the sparse
milestone, gated by the Tier-3 review. Push often, release rarely.

## Releasing (macOS DMG + GitHub release)

- Releases ship in the combined Suite DMG, tagged `suite-vMAJOR.MINOR.PATCH` (root [`../CLAUDE.md`](../CLAUDE.md)
  §*Releasing*); the bare `vX.Y.Z` tags (to `v3.8.2`) are this app's pre-merge history. `CFBundleShortVersionString` stays "1.0".
  Patch for internal-only changes, minor for user-facing features. Distribution is owner-only.
- Signed with the self-signed **`CODE_SIGN_IDENTITY: "Archive Suite Dev"`** (not ad-hoc), not notarized. The
  target **declares no** `get-task-allow` / `disable-library-validation`; Debug sets `ENABLE_DEBUG_DYLIB: NO`
  (W28.cert-fu2; valid while there is no app-hosted XCTest target or SwiftUI previews); Release keeps hardened runtime + strict library validation and
  `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO`. **⛔ The Release signature must contain neither debug entitlement.**
  Why: REFERENCE.md §Releasing.
- **Call `gh` by full path, `/opt/homebrew/bin/gh`** — a shadowing Python `gh` is first on `PATH`.

The release build + DMG + `gh release` commands are in REFERENCE.md §Releasing (a Tier-3, owner-gated step).
The `.dmg` is a build artifact — never commit it (build under gitignored `build/` or `/tmp`).

## Reference (read on demand)

Every original section is in [`REFERENCE.md`](REFERENCE.md) under its original heading (Primary Function 1–3 and
subsections, File Input, OCR Output Format, Settings & Tools, Architecture Notes, Project Structure, the Implementation map); its
Background part holds the full wording of the sections and bullets compacted here. A rule stated there still binds.
