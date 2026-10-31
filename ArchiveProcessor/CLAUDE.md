# Archive Processor — Project Guide

## Overview
A native macOS app for processing collections of historical archive photographs: (1) OCR via LLM models, (2) macOS filesystem tagging, (3) Live Capture from the phone companions, which this guide also covers.

This file holds the rules and commands; reference detail (model lists, per-function descriptions, the
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
  don't silently add others to them. OpenRouter's are exactly `OpenRouterRoute.catalog`, each pinned as benched (`provider.order`,
  `allow_fallbacks: false`, `quantizations`, `max_price`, temp 0), no custom models; a model outside it gets no client, so no call goes unpinned.
- **Apple Vision** is additive, never the default. Its optional text-only judgement call goes to a **direct** LLM
  with the extracted text only — no image bytes, image URL, gateway or Local Agent. With judgement off, Vision is
  fully offline (No tagging / Copy source tags only).
- **A failed reply is never a transcription:** an OpenRouter 200 with `finish_reason` error, or an in-body provider
  error, is a failed page (503, retried); every client fails a cut-off reply as `length`, never saving cut text.
- **Cascade** (`OCR/OCRCascade.swift`, off by default) never escalates transport errors, timeouts, 429/503/529,
  key/quota/request errors, a remote gateway, the Local Agent or Apple Vision as first reader; a per-run breaker
  bounds spend. Contract: `scripts/test-ocr-cascade.sh`.
- **Institutional computing import** matches only on the image's SHA-256 with model and nonblank `cluster`
  recorded, never on filenames or institution (missing provenance matches nothing), rechecked at use time;
  Retry/Rotate always reads fresh; read-only on the bulk folder and inputs; direct non-batch path only (never gateway, Local Agent, Vision or
  pre-OCRed input); header labels sanitised (separator, one line); estimates still count every page. Contract:
  `scripts/test-institutional-compute-import.sh`.
- **Page-kind routing** is off by default. Contract: `scripts/test-ocr-page-kind.sh`.
- **A model on this Mac** always sends the stand-in bearer `local`, never a saved key; escalating its failed pages
  is off by default (it may have been chosen to keep pages on the Mac). Its measured limits are required
  (W41.mac-local-measure: 4,096-token cap, streamed repetition check + one re-read with a repetition penalty, 600 s
  → `length`, temp 0, one page at a time). Contract: `scripts/test-local-models.sh`.
- **Gateway and Local Agent skip batch and LLM rotation.** Local Agent (`OCR/LocalAgentClient.swift`): no shell,
  prompt on stdin not argv, absolute-path binary, per-call timeout, friendly errors (never raw stderr), **no key**,
  $0 under the actual CLI's name; only `claude` is validated (`gemini`/`codex` are `VERIFY` placeholders);
  `runAsync` signals exit via `terminationHandler` (`waitUntilExit()` on GCD missed exits) and kills its child on
  cancel. Precedence localAgent > gateway > direct; concurrency 1–2 + usage-window pacing; the header/history keep
  the model override or `CLI default` and never price the direct-provider fallback. $0 harness:
  `scripts/localagent-fake-cli.sh`, `[3.5]` in `scripts/test-smoke.sh`.
- **Requirements:** Low/High thinking where supported; a cost estimate before processing, standard vs batch side
  by side, updated as files are added, **reflecting the batch discount** (batch total only with batch on, a direct provider and no pre-OCRed
  input; Vision / Local Agent / an unpriced gateway show a note, never a dollar figure); batch toggle; parallel workers. Input:
  drag-and-drop or open panel; JPEG, PNG, TIFF, HEIC, PDF (pre-OCRed input: PDFs only). Model defaults
  (REFERENCE.md) are item decisions (W41.app-ocr-default, W41.app-seg-default): don't change them silently. A
  live-key OCR smoke is the final OpenAI model-ID confirmation.
- **Output: each input image → one PDF, same base filename.** Page 1 the image; page 2 the text under `Extracted
  text.` and `[Provider] · [Model] · [Day Month Year]`. **Critical: page 2 is arbitrarily tall — all text on one
  page, never a third**, well-formatted and laid out. No text → `No text returned by model.` + the error code/reason. Show Gemini's
  `"Recitation"` refusal clearly. The batch log is opt-in (`DefaultsKeys.writeLogFile`, off) and lists each failed file with its error reason.

## Tagging rules (Primary Function 2)

- **The tag vocabulary + 2-page PDF format are specified in [`../SPEC/tag-format.md`](../SPEC/tag-format.md);**
  a change to what is written updates that SPEC and the Reader together (Tier-2).
- **Segmentation** is inferred: a box photo → new box, a folder photo → new folder; document heuristics in
  REFERENCE.md §Document Segmentation.
- **Date tags (most important):** year `1968` or decade `1970s` (manual Year field only; the LLM never emits it; written verbatim);
  month `MM Month`. Date undetermined: estimate the year from surrounding documents, **never estimate the month**,
  always add `Date Uncertain`.
- **Subjects:** 2–6 per document, general but not too general. Box photos → `Red`; folder photos → `Purple`.
- **`Unread`**: every output (PDF **and** any exported original) gets it, applied **last**, only in real-tagging
  modes (`.automatic`/`.autoDate`/`.human`), never "No tagging" or "Copy source tags"; via the **required**
  `stampUnread:` of `MacOSTagger.applyTags` (from `TaggingMode.stampsUnread`), no ambient flag (W16.cfg6-fu).
- **No tagging** leaves Quality and all metadata untouched; **Copy source** keeps a source tag's spelling verbatim.
- **A refused Finder-tag write or a placeholder image page is REPORTED**, never swallowed by `try?` (W23.m5/h5-fu;
  `PROCESSFILES_TAGWARN_TEST=1`). Process Files does not rewrite its PDF with source-date header lines.
- **Quality** crosses the capture protocol as `Q1`–`Q3` (omitted = Unrated) and is written to Finder as that token.
- **API efficiency:** minimise calls, batch OCR results before tagging; reuse OCR text, never re-query the image.

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
  ID is **NOT in git** (gitignored `ArchiveCapture/local.properties`, `driveOAuthClientId=…`; iOS: gitignored
  `ArchiveCaptureiOS/Config/DriveLocal.xcconfig`); the Android client ID is bound to package + signing SHA-1; an unconfigured build still compiles, LAN/USB
  unaffected; it needs **"Custom URI scheme" enabled**. Scope is `drive.file` (per file); Drive/ChatGPT tokens
  and the Mac's Drive client secret (`DriveClientSecret`) live in the Keychain (iOS: this device only); the phone has
  no secret. The ChatGPT plan route sends `store: false`, and only a completed response answers.
  **Mac and phone sign in to the same Google account**; the Mac signs in to Drive before Start — a mid-session
  sign-in waits for the next session (owner-accepted limitation, 2026-07-08, A5). The iPhone uses the relay only by an explicit Cloud choice; Wi-Fi never switches to Drive itself.
- **Rejected transports (don't re-open):** personal hotspot, MultipeerConnectivity/AWDL, Bluetooth, AirDrop /
  Quick Share. No Mac-side transport picker (A5, removed as a footgun).
- **LAN security — accepted risk (owner, 2026-07-18):** plaintext HTTP + persistent bearer token; no TLS/AEAD, no
  companion changes, no packet-capture harness — **do not re-promote LANSEC-5/6/7 or the crypto redesign.** The acceptance rests on the shipped mitigations:
  high-entropy `lanToken` + failed-auth backoff (W16.lan2), header-first admission, connection/memory caps,
  `constantTimeEquals`, both receivers' `isSafeGroupId` path-traversal guard (`Net/CaptureValidation.swift`). On
  untrusted venue Wi-Fi use the USB cable (either phone) or Drive relay; LAN only on a trusted network. The Drive-relay
  code never authenticates the LAN server. Pairing is QR-only (a Bonjour-discovery check is moot). Record:
  `KNOWN_ISSUES.md` §"Live Capture LAN channel".
- **Backup folder:** legacy staging is read in place, not migrated; launch pruning never removes a folder still holding a photo
  *or* a `_processed` output.
- **Finish-window rules**, each load-bearing (`KNOWN_ISSUES.md` §"REFERENCE: the shared Processing pane during a
  finish"): every Live retry is refused while `isFinalizing` **in `retryFailed` itself**, not only in the view
  (`W3.cap-r3-fu7`). `proceedToFinishIfReady` **holds** a finish while a per-item sheet is up (in `finishSession`
  it would discard it; `W3.cap-r3-fu9`), so sheet targets live on `LiveCaptureProcessor` — ⚠️ a view `@State`
  target compiles cleanly and silently disables the guard, untested. The finishing scrim freezes the pointer only;
  keyboard/VoiceOver rely on `.disabled` (`W3.cap-r3-fu10`). An emptied Captured pane still offers Finish and
  Clear while `hasUnfiledWork`; Finish is also `.disabled` on the narrower `canFinish`, and the two gates stay
  separate (`W3.cap-r3-fu12`). Failure taxonomy is label-only (Tier-2): `labelStagedRecord(...)` is the ONE
  labeller and never changes a finalize/deletion decision (that keys off `filedGroupIds` + `pagesComplete`).
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
  key (`$OCR_KEY` / Keychain). No permission step (de-gated 2026-08-13, `../AGENTS.md` §*Gating baseline*); ask the
  owner ONLY if no key exists for that provider at all.
- Keep costs low: the cheapest capable model (e.g. `gemini-2.5-flash-lite`, `claude-sonnet-4-6`), the smallest
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
- `OCRProcessor` methods go in the matching `OCRProcessor+{Pipeline,OCR,Tagging,ReviewFlows}.swift` extension
  (deliberately coarse: no `+Persistence`/`+BatchOCR`/`+MainPipeline`); **all stored properties stay in `OCRProcessor.swift`**.
- Verifying a move-only refactor: run the move-proof (`git show --color-moved | grep …`) **tty-independently**
  (piped, it passes for any commit); census-diff private members for access-level changes (grep can't see
  `internal`); gate on a warnings delta (beware a cached "0 warnings"). `LiveCaptureTestDriver` does **not**
  exercise the batch GUI path (`startProcessing → review → performTaggingPhase → finalize`).
- `Tagging/` is Tier-2; `Segmentation/` is not (writes nothing). `WindowPrompts.swift` is verbatim from the bench
  (a test compares byte for byte). `enclosureOf` uses the OCR `[enclosure]` marker, never adjacency. `PlanUsage`
  never reads the CLI's login; `PlanRunGate` pauses at a 90% five-hour meter; Claude/ChatGPT routes ask "key or
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
(a few cents). Needs the Mac free + awake (don't drive its GUI meanwhile), the `ap_test36` emulator + android-36
image, `xcodegen` on PATH, a Gemini key. Auto-finalize is gated on `LIVECAPTURE_TESTOUT` so it can never file into
the real corpus; its inject seam (`files/test_inject.jpg`) is debug-only, stripped from release. The Tier-2 gate for `Capture/`/`Net/`, **not** per-commit. It pairs over `10.0.2.2` and never touches USB; for `adb reverse`:
`scripts/usb-reverse-probe.sh` (free).

**Cadence:** push often (clean build + Tier-1, plus Tier-2 where it applies); a DMG + GitHub release is the sparse
milestone, gated by the Tier-3 review. Push often, release rarely.

## Releasing (macOS DMG + GitHub release)

- Version by **git tag** `vMAJOR.MINOR.PATCH` (the source of truth; `CFBundleShortVersionString` stays "1.0").
  Patch for internal-only changes, minor for user-facing features. Distribution is owner-only.
- Signed with the self-signed **`CODE_SIGN_IDENTITY: "Archive Suite Dev"`** (not ad-hoc), not notarized. The
  target **declares no** `get-task-allow` / `disable-library-validation` (entitlements aren't config-scoped, so
  they'd ship everywhere); Debug sets `ENABLE_DEBUG_DYLIB: NO` (W28.cert-fu2; valid while there is no app-hosted XCTest
  target or SwiftUI previews); Release keeps hardened runtime + strict library validation and
  `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` (Xcode otherwise injects `get-task-allow` into Release). **⛔ The Release signature must contain
  neither debug entitlement.** Why: REFERENCE.md §Releasing.
- **Call `gh` by full path, `/opt/homebrew/bin/gh`** — a shadowing Python `gh` is first on `PATH`.

The release build + DMG + `gh release` commands are in REFERENCE.md §Releasing (a Tier-3, owner-gated step).
The `.dmg` is a build artifact — never commit it (build under gitignored `build/` or `/tmp`).

## Reference (read on demand)

Every original section is in [`REFERENCE.md`](REFERENCE.md) under its original heading (Primary Function 1–3 and
their subsections, File Input, OCR Output Format, Settings & Tools, Architecture Notes, Project Structure, the
Implementation map); its Background part holds the full wording of Concurrent / multi-agent development,
Verification & review policy and Releasing. A rule stated there still binds.
