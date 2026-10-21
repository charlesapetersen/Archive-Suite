# Archive Processor — Project Guide

## Overview
A native macOS app for processing collections of historical archive photographs. Two primary functions: (1) OCR via LLM models, and (2) macOS filesystem tagging.

---

## ⛑️ Recovery Core Directive (data safety) — bulletproof AND always recoverable

This app writes **irreplaceable data**: archival photos that can never be re-shot. So the bar is not just
"the app should work" — it is **two independent guarantees**, and *both* must hold for every change to the
capture/finalize/output path (`Capture/`, `Net/`, `Tagging/`, PDF/image output):

1. **Bulletproof** — the happy path never loses data: durable-manifest-before-ack, idempotent `(group,seq)`,
   drain-gated finish, crash-resumable staging.
2. **Strong recovery points** — *when the app fails anyway* (bug, crash, bad move, wrong folder), the
   operator can still get their files back. Design every destructive step so failure is **recoverable**,
   not just unlikely.

The three non-negotiable rules that implement this (added 2026-07-07 after a live-capture finalize deleted a
run's originals — see `KNOWN_ISSUES.md` "finalize deleted a run's originals"):

- **Confirm before you delete.** NEVER delete a source photo until its processed output is *verified on disk
  at the destination*. Deletion keys off "the output actually landed" (`executePlans` → `filedGroupIds`),
  **never** off "we staged it" / "finalize returned no hard error." A silently-missing output must keep its
  source, not drop it.
- **Trash, don't `rm`.** All post-processing deletions of capture data go through
  `CaptureSession.trashOrRemove` (macOS Trash), never `FileManager.removeItem`. A wrong call is then
  recoverable from the Trash.
- **Keep a second copy until it's safe.** Both the raw source photos **and** the processed PDFs/JPGs/JSON
  (with tags) live in the **visible backup folder** (`<session>/` and `<session>/_processed/`) until finalize
  confirms the destination has them. Recovery data is never hidden or hard-purged while a run is in flight.

Guard: this is Tier-2 (adversarial review + a functional test on scratch copies) for any edit to the paths
above. When "bulletproof" and "recoverable" seem to conflict, ship both — err toward keeping data.

---

## Primary Function 1: OCR

### LLM Provider & Model Selection
Dropdown menus for provider and model. The **built-in** models are those listed below — don't silently add others to the built-in lists. Alongside the cloud providers, Settings offers an on-device **Apple Vision** transcription backend; users can also add extra model IDs, point at an OpenAI-compatible endpoint, or drive a local subscription-authed **Local Agent CLI** (Claude Code / Gemini / Codex — no API key).

**Anthropic**
- claude-sonnet-4-6
- claude-opus-4-6

**Google Gemini**
- gemini-3.8-flash (default, W41.app-ocr-default; a page it refuses goes to a second reader — `OCR/OCRRefusalFallback.swift`, in the order `availableRoutes` builds them from what is set up: Claude (plan, else key), Qwen3.6 27B on OpenRouter, OpenAI `gpt-5.4-mini`, then Mistral OCR)
- gemini-3.5-flash-lite
- gemini-3.1-flash-lite
- gemini-3.5-flash
- gemini-3.1-pro
- gemini-3-flash-preview
- gemini-2.5-flash
- gemini-2.5-flash-lite
- gemini-2.5-pro

**Mistral**
- mistral-ocr-latest (Mistral OCR 3)
  - Note: Mistral returns markdown-formatted text

**OpenAI (ChatGPT)** — first-class provider (`LLMProvider.openai`, W13.oai-1/2/3), routed through the reused `OCR/OpenAICompatibleClient.swift`; BYO OpenAI API key (Keychain account `OpenAI`).
- gpt-5-nano (default)
- gpt-5-mini
- gpt-5.4-mini
- gpt-5.4
- gpt-5.5
  - Note: model IDs + per-1M pricing are the current GPT-5 generation from the owner-provided SoCOCRbench source (2026-07-16), ordered cheapest→flagship; a **live-key OCR smoke** is the final ID confirmation (Daemon Report). All five are marked `supportsThinking` and take `reasoning_effort` from the Thinking level (gpt-5.4-mini included: OpenAI lists reasoning-effort support for it, default `none` — `Models/ProviderModels.swift`). No batch or LLM-rotation path in v1 (like Mistral) — local Vision handles rotation; OpenAI Batch API is a later phase.

**OpenRouter** — first-class provider (`LLMProvider.openrouter`, W41.app-openrouter), through `OCR/OpenAICompatibleClient.swift` `openRouter(model:apiKey:)`; BYO key (Keychain account `OpenRouter`). Its models are exactly `OpenRouterRoute.catalog` (`Models/ProviderModels.swift`), no custom models, each pinned as the bench ran it (`provider.order`, `allow_fallbacks: false`, `quantizations`, a `max_price` at the pinned price, temperature 0):
- qwen/qwen3-vl-235b-a22b-instruct, deepinfra fp8 (default; panel 93.95 NES, $1.22 per 1,000 pages)
- qwen/qwen3.6-27b, chutes fp8, reasoning off (94.28)
- z-ai/glm-5.3-flash, z-ai fp8, reasoning minimal (measured for segmentation; its OCR is not)
  - Note: a model outside the catalog gets no client, so no call goes unpinned. No batch, no LLM rotation (local Vision), Qwen3.6 27B is the refusal second reader after Claude, ahead of OpenAI `gpt-5.4-mini` and Mistral OCR (`OCRRefusalFallback`, W41.app-openrouter-fu1). A 200 whose `finish_reason` is error, or an in-body provider error, is a failed page (code 503, retried), never a transcription. GLM-5.3 Flash is also the segmentation approach `glm` (`Segmentation/WindowTransports.swift` OpenRouter arm; `segbench-results/options.json`, written by `method_openrouter.py option-glm`).

**Apple Vision (on-device)** — first-class local transcription backend (`LLMProvider.appleVision`, W13.vision-1/2) using `VNRecognizeTextRequest`; model `macOS Vision`. It has no API key, network request, or per-page cost. The Settings backend picker exposes language, fast-recognition, minimum-confidence, and custom-vocabulary controls; the run snapshot carries them through Process Files and Live Capture. With **Use an LLM for text-only judgement** off, Vision runs entirely offline and supports **No tagging** or **Copy source file tags**. With it on, Vision still performs image OCR locally, then a separately selected **direct** LLM receives only the extracted text for classification, segmentation, date extraction, and generated tags — no image bytes, image URL, gateway, or Local Agent route enters that second call. Batch and LLM rotation remain off; CPU-bound Vision work uses the Mac's performance-core count. Vision is best on clean typescript and weaker on handwriting or heavy skew, where a cloud VLM can be stronger; it is additive and never the default.

**Cheap-first OCR cascade** (W41.app-ocr-cascade, `OCR/OCRCascade.swift`; off by default). Settings → **Escalate failed pages to** picks one built-in model of any keyed provider; on the direct-provider path a page the run's model fails on (`length`, `unparsable`, a no-text server error, a Gemini refusal) is read again by it. Never escalated: transport errors, timeouts, 429/503/529, key/quota/request errors, a remote gateway, the Local Agent, Apple Vision as first reader. A per-run breaker (`OCRCascade.Breaker`: 20, then at most a quarter of the pages) bounds the spend; the choice is frozen in the run snapshot and the paid-batch journal; the kept text is marked in `OCRResult.secondReader`. Every client fails a cut-off reply as `length` rather than saving the cut text. Full trigger list, the Vision word-count option and the failure path: `KNOWN_ISSUES.md` §W41.app-ocr-cascade. Contract: `scripts/test-ocr-cascade.sh`.

**Institutional computing import** (W41.app-institutional-compute, `OCR/InstitutionalComputeImport.swift`, `Views/OCRView+InstitutionalCompute.swift`). The Files tab's **Use institutional computing text…** takes the cluster-neutral kit's bulk `--out` folder (`scripts/segbench/institutional-compute/README.md` §Bulk), chosen per run. `InstitutionalComputeImport.load` reads `_meta/**/*.json` off the main actor, requiring the input image's SHA-256, model and nonblank `cluster` name. Nothing is inferred from filenames or from the institution: missing provenance matches nothing. At Start it freezes into `SessionProcessingConfig.institutionalComputeImport` on the page-reader path (direct provider, non-batch; no gateway, Local Agent, Apple Vision or pre-OCRed input). `performOCRCall` hashes each input before rotation; a match takes the cluster's text, rotation 0, and one text-only classification call to the run's model (failure leaves it unclassified). `OCRResult.imported` records cluster, model, preset, precision, job and kind; the PDF header names `<cluster> · <model> (<precision>, job <id>)`, with both labels made safe for the header's separator and single line. The metadata hash and reader must still match at use time. Every other page is read as usual; estimates still count every page. Retry/Rotate & re-run always requests a fresh read. `PendingRunRuntimeConfig.institutionalComputeFolder` reloads the folder on resume (gone folder → no import). Read-only: nothing writes to the bulk folder or inputs. No migration: no app output has been kept. Limits: `KNOWN_ISSUES.md`. Contract: `scripts/test-institutional-compute-import.sh`.

**Each page's reader by its kind** (W41.app-page-kind, `OCR/PageKindClassifier.swift` + `PageKindRouting.swift`, `Views/OCRView+PageKind.swift`; off by default). Settings → **Choose each page's reader by its kind**. The file list classifies each dropped image on this Mac (W41.bench-kind-classifier's recommendation: Vision text lines, ink periodicity, tables and the image feature print into two logistic regressions, weights bundled from `segbench-results/kind-classifier-model.json`, about 0.6 s a page, macOS 26) and preselects the first pick in `OCRPageGuidance` for that kind among the built-in models of keyed providers; a page under 0.8 confidence, with no kind, or with no runnable pick keeps the run's model. Each row shows the kind and reader with a menu to choose another; the cost pane has a batch menu and a caption, and the estimate adds each routed page's price less the run model's. At Start the choices are frozen into `SessionProcessingConfig.pageReaders` (and the resume record); `performOCRCall` reads a planned page with its model on the direct, non-batch path only (a missing key at read time keeps the run's model), passes it on to the cascade, and records `OCRResult.pageReader` (kind, confidence, reason, reader, prices), which names the reader in the PDF header and adds the price difference to the run history. Limits: `KNOWN_ISSUES.md`. Contract: `scripts/test-ocr-page-kind.sh` (with a parity check against the bench's own predictions when its private cache is present).

### Custom models, OpenAI-compatible gateway & Local Agent CLI (shipped)
- **Custom models:** users can add extra Anthropic/Gemini model IDs via **Manage custom models…** in Settings (`Views/ManageModelsView.swift`, persisted by `Models/ModelSelectionStore.swift`) — so the dropdowns are not limited to the built-in lists above.
- **OpenAI-compatible gateway:** toggle **Use gateway** in Settings (`@AppStorage` `useGateway` + `gatewayBaseURL`/`gatewayModelID`, with a separate **Gateway** key in Keychain) to route OCR through any OpenAI-compatible chat-completions endpoint (self-hosted or proxied). Client: `OCR/OpenAICompatibleClient.swift` (reuses the shared `OCRPrompt.build`); config is carried as `GatewayConfig` (`Models/ProviderModels.swift`). The gateway path has **no** batch or LLM-rotation support (both are skipped when `useGateway` is on): the Batch toggle is disabled, but the rotation controls stay enabled and an LLM rotation mode silently falls back to local Vision (`OCR/LLMRotationDetector.swift`, `OCR/OCRProcessor+OCR.swift` `detectRotation`; suspect `S-029`).
  - **One-click "Fill in OpenAI preset"** (W13.oai-3): in gateway mode a preset button prefills the public OpenAI endpoint (`https://api.openai.com/v1`), a default OpenAI model, a display name, and the cost profile — reading the model ID + pricing from the single source of truth `LLMModel.openaiModels` (`applyOpenAIGatewayPreset()` in `Views/SettingsView.swift`), so a verified-pricing edit there flows through. It looks for the cheapest **non-reasoning** model (the gateway sends plain `max_tokens`, which OpenAI reasoning models reject — the param adapter lives only on the native `.openai` path) — but every built-in OpenAI model is now marked reasoning, so it falls back to `gpt-5-nano` (open suspect `S-025`); GPT-5 reasoning models go through the Direct API provider. A **custom base URL covers Azure OpenAI / OpenAI-compatible proxies** (apply the preset, then edit the URL). Note: OpenAI is also a first-class **Direct API** provider (above) — the gateway preset is for Azure/proxy/self-host routing to an OpenAI-format endpoint.
- **A model on this Mac (W41.app-local-models, `Models/LocalModelRoute.swift`, `Views/LocalModelSettingsView.swift`):** in gateway mode, **A model on this Mac** (`gatewayLocalModel` → `GatewayConfig.localModel`) marks the endpoint as an open-weight model served locally (LM Studio, Ollama, `mlx_vlm.server`). Settings recommends a model by this Mac's memory, fills the gateway fields at $0, and **Check server** lists its models. The route differs from a gateway where W41.mac-local-measure said it must: a 4,096-token cap, a streamed repetition check that closes the request, one re-read with a repetition penalty, a 600 s timeout failing as `length`, temperature 0, one page at a time, and always the stand-in bearer `local` (never a saved key). **Send pages it fails to the escalation model** (`gatewayLocalEscalates`) is off by default, since a local model may have been chosen to keep pages on the Mac. Full behaviour: `KNOWN_ISSUES.md` §W41.app-local-models. Contract: `scripts/test-local-models.sh`.
- **Local Agent CLI backend (shipped, W13.cli-1…4):** the third escape hatch, for users with an enterprise/subscription **Claude Code / Gemini CLI / OpenAI Codex** entitlement but **no API key or gateway**. Pick **Local CLI Agent** in the Settings **OCR backend** picker (`@AppStorage` `useLocalAgent`, mutually exclusive with `useGateway`; tool/path/model + **Detect & Verify** + a guided **Set up (guided)…** wizard). OCR/classify/tag/segment then shell out to the locally installed, subscription-authed CLI (`OCR/LocalAgentClient.swift`: no shell, prompt on stdin not argv, absolute-path binary, per-call timeout, friendly errors — never raw stderr) instead of a metered API. Config is carried as `LocalAgentConfig` (`Models/LocalAgentConfig.swift`, `LocalAgentConfig.fromDefaults`) threaded **alongside** `GatewayConfig` through the run snapshot (additive optional — crash-resume of an in-flight run stays byte-compatible) and **preferred at the client-construction sites** (localAgent > gateway > direct). Durable PDF headers and Process-Files history name that actual CLI as `Local CLI Agent (<tool>)`, retain its explicit model override (or `CLI default`), and record $0 rather than crediting/pricing the selected direct-provider fallback. Like the gateway, it **skips batch + LLM-rotation** (subprocess path, low fixed concurrency 1–2 + usage-window pacing; holds **no key** — auth is the CLI's own login). Cost pane shows "Included in your subscription — usage limits apply". Only `claude` is Phase-0-validated; `gemini`/`codex` invocation details are `VERIFY` placeholders pending an install+entitlement spike (owner tail). The guided wizard offers `claude` and `gemini` only (`LocalAgentSpec.onboardable`); Codex is reached through the Settings tool picker. The Batch toggle is not disabled under the Local Agent (`Views/SettingsView.swift` disables it only for gateway, Vision and pre-OCRed input); the run ignores it. Fake-CLI harness (`scripts/localagent-fake-cli.sh` + the `localagent-*-test.swift` standalone tests + the `[3.5]` section of `scripts/test-smoke.sh`) covers the whole path at $0. `LocalAgentClient.runAsync` stops its child when the calling task is cancelled, and signals exit through `terminationHandler` (W36.seg-opt-subscription: `waitUntilExit()` on a GCD thread missed 12 exits in 300 calls).

### Thinking Mode
For models that support low/high thinking, include a dropdown: Low / High.

### Cost Estimator
- Display estimated cost before processing based on file count and selected model
- Show standard vs. batch pricing side by side — the batch total appears only when batch mode is on, on a direct provider, with no pre-OCRed input (`Views/OCRView.swift` `ap.ocr.batchTotal`); Apple Vision, the Local Agent and an unpriced gateway show a note instead of a dollar figure
- Update dynamically as files are added

### Batch Processing
- Toggle button to enable batch mode
- Batch processing: lower cost, significantly longer return time
- Cost estimator must reflect batch discount

### Concurrency
- Process files via multiple workers/threads for speed

---

## File Input
- Drag-and-drop onto the app
- File selection button (standard macOS open panel)
- Accepted formats: JPEG, PNG, TIFF, HEIC (standard image formats for archive photos), plus PDF (`Views/OCRView.swift` `isImageFile`): normal runs take images and PDFs — a multi-page PDF auto-routes to the re-OCR transform, a single-page one is OCR'd like an image — and pre-OCRed input takes PDFs only
- A chosen or dropped folder is read one level deep (`contentsOfDirectory` in `Views/OCRView.swift`), not recursively — open suspect `S-028`

---

## OCR Output Format

### Per-file output
Each input image → one PDF with the same base filename.

**Page 1:** The original image (full page)

**Page 2:** OCR text
- Header: `Extracted text.`
- Subheader: `[Provider] · [Model] · [Day Month Year]` (e.g., `Anthropic · claude-sonnet-4-6 · 9 March 2026`)
- Body: Full OCR text, well-formatted and laid out
- **Critical:** All text must fit on a single page. Page 2 must be arbitrarily tall — no text overflow to a third page.
- If no text returned: `No text returned by model.` followed by the error code/reason if provided.
- Gemini-specific: Gemini may refuse copyrighted text with error `"Recitation"` — handle and display this error clearly.

### Batch log file
Opt-in: Settings → **Write a processing log file** (`DefaultsKeys.writeLogFile`, off by default). When on, after all
files are processed, `writeLogFile` (`OCR/OCRProcessor+Pipeline.swift`) writes `ArchiveProcessor_Log_<timestamp>.txt` listing:
- All files that failed to produce OCR text
- Error reason for each

---

## Primary Function 2: Tagging

### Document Segmentation
Archive photos do not mark document boundaries. The app must infer them using heuristics.

**Certain break points:**
- Photographs of boxes → new box
- Photographs of folders → new folder

**Heuristic break points (documents):**
- Newspaper/magazine article: headline
- Letter: To/From lines, signature
- Memo: title line
- Report/Draft: title
- Text ending mid-page (document ends)
- Text continuing to fill the page (document continues)

Common document types: newspaper articles, magazine articles, letters, memos, reports, drafts.

### Tags Applied to Each File

> **Single source of truth:** the exact tag vocabulary + 2-page PDF format Archive Processor *writes*
> (and Archive Reader *reads*) is authoritatively specified in [`../SPEC/tag-format.md`](../SPEC/tag-format.md)
> (Suite root). Any change to what's written here must update that SPEC and the Reader together.

Applied using macOS filesystem tags (via `xattr` / NSFileManager / `tag` CLI or similar).

**Date tags (most important)**
1. Year tag: e.g., `1968` — or a whole **decade** `1970s` (typed verbatim into the manual Year field;
   the LLM tagger never emits it; written unchanged by `GeneratedTags.allTags`/`MacOSTagger`).
2. Month tag: e.g., `03 March` (format: `MM Month`)
- If date cannot be determined: estimate year from surrounding documents; never estimate month; always add tag `Date Uncertain`

**Subject tags**
- 2–6 tags per document
- General but not too general
- Examples: `Democratic Party`, `taxes`, `elections`, `education`, `transportation`, `business`, `literature`, `economics`

**Special tags**
- Photographs of **boxes** → macOS `Red` tag
- Photographs of **folders** → macOS `Purple` tag
- Every output (PDF **and** any exported original image) → a trailing **`Unread`** tag, applied **last**, for triage. Only in real-tagging modes (`.automatic`/`.autoDate`/`.human`) — never for "No tagging" or "Copy source tags". Implemented via the **required** `stampUnread:` argument on `MacOSTagger.applyTags`, passed as `TaggingMode.stampsUnread` from the run's mode/config. There is no ambient flag — W16.cfg4 made the choice per-call and W16.cfg6-fu deleted the `MacOSTagger.stampUnread` global it replaced.

### API Efficiency for Tagging
- Minimize API calls — batch OCR results where possible before making tagging calls
- Reuse OCR output; do not re-query the image for tagging if text is already extracted

---

---

## Primary Function 3: Live Capture (phone companion + streaming)

Photograph documents with a phone companion — **Android** (`ArchiveCapture/`, Kotlin + Compose + CameraX) or **iPhone** (`ArchiveCaptureiOS/`, SwiftUI + AVFoundation, XcodeGen, Swift 5 language mode) — and stream them to the Mac's Live Capture tab. Both companions speak the same protocol + relay contract and share the streaming UX; the phone holds **no API keys** (the Mac does OCR + tagging).

- **Streaming + never-lose-a-photo (the core invariant).** Each photo's bytes upload **as it is shot** (Workstream S) via a durable on-phone disk queue + auto-retry; a page is marked sent only after the Mac's durable ack. On the Mac every page funnels through `CaptureSession.ingest(...)`, which writes the manifest **before** acking and replaces idempotently on `(group, seq)` — so the phone deletes its sole copy of an un-retakeable photo only once the Mac is durable. **"End segment" is the only "done" action** on the phone: the pages have already streamed, so it is purely the logical grouping — it confirms the document boundary and sends the segment's tags; it does **not** gate byte transfer.
- **Two transports we maintain, behind one seam.** The phone transport is abstracted as `SegmentTransport`, the Mac receiver as `CaptureReceiver`; every receiver calls `ingest` and acks only on a durable return, so the invariant is transport-agnostic.
  - **LAN (default)** — direct phone→Mac HTTP to `CaptureServer` (`NWListener`, fixed port 48627). Zero-config whenever the venue network permits device-to-device.
  - **USB local relay** — `Net/USBBridge.swift` keeps `adb reverse` asserted so a USB-tethered Android reaches `127.0.0.1:<port>`; the Mac stays on venue Wi-Fi. Android-only.
  - **Google Drive cloud relay** — the wireless fallback for client-isolated networks (and off-site capture): the phone uploads each object to the user's Drive, the Mac pulls and feeds the same `ingest`. Built behind the `RelayObjectStore`/`FileRelayReceiver` seam — the offline `FileRelay` shared-directory stand-in proves the whole contract with no auth; `DriveObjectStore` is the production backend (`drive.file` scope, per-file; the Mac deletes each object after durable receipt). Mac side is built + live-validated (with the Android phone on 2026-07-07, below; no record of it is in `verification/evidence/`); the **Android** phone `DriveRelayTransport` is **shipped + verified end-to-end** (2026-07-07 — phone→Drive→Mac over a real Drive account: sign-in, single photo, multi-page segment + tag card, Box/Folder markers, Finish), via on-device AppAuth Google sign-in (`net/DriveAuth.kt`); the iOS transport is built + mock-tested (`scripts/test-drive-transport.sh`), but iOS Drive **sign-in cannot work yet**: `Net/DriveAuth.swift` still carries the placeholder client id `YOUR_IOS_CLIENT_ID.apps.googleusercontent.com` and the sign-in button always shows (not yet — `W40.i-fix-ios-drive-oauth-client`; tokens kept in `UserDefaults` → `W40.i-fix-ios-drive-token-keychain`). Canonical object format (names, JSON, fingerprint) → [`../SPEC/relay-object-format.md`](../SPEC/relay-object-format.md); change all sides together.
  - **Cloud-relay OAuth setup (one-time, per Google account, in the builder's own GCP project):** full steps in **[`ArchiveCapture/README-oauth.md`](ArchiveCapture/README-oauth.md)**. In short — the Mac uses a **Desktop** OAuth client (loopback PKCE + client secret; entered in Settings → Live Capture, secret in Keychain `DriveClientSecret`); the Android phone uses an **Android** OAuth client (package `com.archiveprocessor.capture` + signing SHA-1, **"Custom URI scheme" enabled** in the client's *Advanced Settings* — off by default, else Google blocks the request; reversed-client-ID redirect, no secret). ⚠️ **The Android client ID is NOT in git** — it is bound to the package name + signing SHA-1, so it cannot be shared between installations; it is read at build time from the gitignored `ArchiveCapture/local.properties` (`driveOAuthClientId=…`) and reaches `DriveAuth.kt` through `BuildConfig`. An unconfigured build still compiles and LAN/USB capture is unaffected — only Drive sign-in is disabled. `drive.file` is **per-project**, so both clients see the same folder — **Mac and phone must sign in to the same Google account.** Client id/secret are trimmed on use (`DriveAuth.init`) — a pasted trailing space reads as `invalid_client`.
- **Rejected transports (don't re-open):** Mac/phone personal hotspot (forces the Mac off venue Wi-Fi + internet → no live OCR), iOS MultipeerConnectivity/AWDL P2P (iOS-only, a specialized stack to maintain), Bluetooth (far too slow for multi-MB photos), and **AirDrop / Quick Share** (no programmatic API, a manual per-file Accept, and files land in Downloads — bypassing `ingest`, the `(group,seq)` dedup, and the ack contract).
- **Pairing + connect flow (ground truth).** The Mac shows ONE combined QR encoding `{host, port, token, name}` PLUS an **optional** `relay` key (`LiveCaptureView.pairingPayload`; `host` = the primary `en0`/`en1` IPv4, `token` = the persisted 32-char high-entropy `session.lanToken`; pinned port survives Mac restarts, QR hides once paired). There is **no Mac-side transport picker** (A5, removed as a footgun): the Mac ALWAYS runs the LAN `CaptureServer` and ADDITIONALLY runs the Drive relay watcher whenever it's signed into Google Drive AND a session is active (sign-in = enablement; the Drive poll is gated to active sessions to save quota). The six-character `relay` value (`session.token`) is emitted only while signed in and is **additive** — an older companion ignores it and still pairs over LAN byte-for-byte; a current companion reads it so any phone-side choice (Wired/Wi-Fi/Cloud) works from the single scan. Companion QR parsers (`MacEndpoint`) read `relay` optionally (`relayToken`), tolerating its absence. LAN/USB HTTP routes use `Authorization: Bearer <token>` (bad token → 401, unknown route → 404); Drive objects use the separate relay code. Both companions gate on a saved endpoint (`endpoint != nil` → capture screen), so a **Re-pair** control (`disconnect()` → `POST /session/disconnect` → the Mac re-shows the QR) is the only way back to the scanner — needed to move a USB-paired phone (saved host `127.0.0.1`) to Wi-Fi or to a different Mac. Captured items are retained across a disconnect and re-upload to the new endpoint. P0/P1 shipped honest connect diagnostics (short reachability preflight → unreachable / refused / unauthorized) so pairing never fails silently. **Sign into Google Drive BEFORE pressing Start** for cloud relay this session: the Drive watcher starts at Start (`CaptureSession.start()`), so a mid-session sign-in doesn't start it until the next session (owner-accepted 2026-07-08 — A5 "Finding-2"; the dual status shows "Drive off — sign in" until then).
- **LAN transport security — accepted risk (do not re-promote the crypto redesign).** The LAN transport is **plaintext HTTP with a persistent bearer token**, so a device that can observe local Wi-Fi traffic can recover the token and replay photo/control requests. **Owner decision 2026-07-18 — accepted, not fixed:** no TLS/AEAD, no companion changes, no packet-capture harness (do **not** re-promote LANSEC-5/6/7). Rationale — the payload is photographs of **public archival records the owner intends to publish** (confidentiality ≈ worthless); integrity loss is bounded by the **Recovery Core Directive** (idempotent `(group, seq)`, originals retained in the visible backup folder, deletions via Trash) so a forged overwrite is caught at tag-card review and is recoverable; and the attack needs an adversary **physically co-located** in the reading room. **The residual risk is real (not hypothetical) via a correlation:** venues that enforce client isolation block the LAN transport *entirely* (which is why the USB bridge and Drive relay exist), so LAN capture succeeds precisely on the open/shared-PSK guest networks that ARE sniffable — it is simply low enough to accept. **Operator guidance: on untrusted venue Wi-Fi, use the USB bridge (Android) or the Drive relay (either phone); reserve LAN for a trusted network.** The reachability-only credential weakness is **fixed by W16.lan2**: LAN/USB now uses a persisted ~158-bit `lanToken` plus per-source failed-auth backoff, while the SPEC-pinned six-character Drive-relay code stays separate and never authenticates the LAN server. **Pairing is QR-only, no discovery:** the Mac advertises `_archivecap._tcp` (`CaptureServer.swift:68`) and the iOS companion *declares* the type in its `Info.plist` (`NSBonjourServices`), but **neither companion browses for it** (no `NWBrowser`/`NetServiceBrowser`), so the advertised service is inert and any "Bonjour discovery" verification step is moot. Full accepted-risk record + the already-shipped mitigations (header-first admission, connection/memory caps, `constantTimeEquals`, `isSafeGroupId`): [`KNOWN_ISSUES.md`](KNOWN_ISSUES.md) §"Live Capture LAN channel".
- **On the phone:** full-res shutter; **Box** (red) / **Folder** (purple) markers; minimal on-phone tagging (Quality: Unrated or `Q1`–`Q3`, with a per-page `Q3` override; year/month). The Q-only protocol is a clean cutover: companions and Mac exchange `Q1`–`Q3` or omit the field for Unrated, and the Mac writes the same canonical token to Finder in enabled tagging modes. **No tagging** leaves it and all metadata untouched, while Copy source otherwise preserves an existing source tag spelling verbatim. A **queue-depth heartbeat** (`POST /phone/status`, `X-Pending`) tells the Mac how many photos are still un-sent.
- **On the Mac:** an auto-advancing, keyboard-driven **tag card** per document segment (subjects via `SystemTagsProvider` autocomplete; editable date/Quality), gated on the segment-complete signal so it appears only for a *completed* segment. **Finish is drain-gated** — the Mac surfaces "phone still has N to send" and holds finalize until the heartbeat reports the phone has drained, so no segment finalizes partial.
- **Backup folder (data safety) — the recovery point.** Every photo lands in a durable, **user-visible** folder — `~/Pictures/Archive Processor Live Capture/<session>/` (`CaptureSession.backupRoot`) — kept until the run's output is fully finalized. As of the **Recovery Core Directive** (below) that folder holds **both** the raw source JPEGs **and**, in a `_processed/` subfolder, the streamed **PDFs/JPGs/JSON with their tags** (`LiveCaptureProcessor.stagingDir(for:)` — staging now lives inside the backup folder, not hidden Application Support). So if the app fails any time before finalize, the operator can recover *both* originals *and* processed output from one Finder folder. A **Backup Folder** button in `LiveCaptureView` reveals it. Finalize deletes a source **only** after its processed output is *confirmed on disk at the destination* (`finalize` keys deletion off `executePlans`'s `filedGroupIds`, never off "was staged"), and all such deletions go to the **Trash** via `CaptureSession.trashOrRemove` — never a hard delete. Legacy Application-Support staging folders are not migrated: they are read in place (`LiveCaptureProcessor.legacyStagingRoot`) and pruned on launch once orphaned; empty finalized folders are pruned on launch (never one that still holds a photo *or* a `_processed` output).
- **Two processing modes (Settings, `liveProcessingMode`):**
  - **Stage for later** — captures collect, then hand off to Process Files for a batch run.
  - **Process live** — each segment is OCR'd **on arrival**, tagged, turned into a **PDF + renamed original image** (dual output), merged if multi-page, and staged as you shoot. At **Finish session**, confirm each collection's name (auto-suggested from the box-label OCR, **fuzzy-matched against existing folders** to append; new files continue that folder's `NNNNN` numbering). Durable + resumable (staging manifest; failed-OCR retry).
- **Shared per-item Processing pane (A1).** The Live Capture Processing list and the Process Files "Files" list render from **one** shared component — `Views/Shared/{ProcessableItem, ProcessableItemRow, ProcessableItemListView, ModelChoiceView}.swift` — via thin adapters (`FileItem`, `SegmentItem`) mapping `OCRJob` / `SegmentStatus` into a normalized `ItemState` + `ItemAction` vocabulary: failure reason + provider·model, per-item retry / retry-with-model / rotate-&-re-run / view-text / reveal. Live's bulk **"Retry N failed"** is the all-failed case of the same `LiveCaptureProcessor.retryFailed(groupIds:override:)` path; Files-side `OCRProcessor.retryOne(...)` is the shared single-file retry seam. The finish-window rules, each load-bearing — full reasoning, the three-way sheet analysis and the adversarial catches are in [`KNOWN_ISSUES.md`](KNOWN_ISSUES.md) §"REFERENCE: the shared Processing pane during a finish":
  - **Every Live retry is refused while `isFinalizing`, in `retryFailed` itself** (`W3.cap-r3-fu7`) — not only in the view, because the "Retry with model" sheet's Apply is deferred. The view's `.disabled` / withheld actions only avoid offering what would be refused.
  - **`proceedToFinishIfReady` refuses to START a finish while a per-item sheet is up** (`W3.cap-r3-fu9`) — a HOLD, not a refusal; placing it in `finishSession` instead would DISCARD the finish. The per-item sheet targets therefore live on `LiveCaptureProcessor`, not in the view's `@State`. ⚠️ Re-adding a view `@State` target compiles cleanly and silently disables the guard; that leg is uncovered.
  - **The finishing scrim is meant to freeze the panel** (`W3.cap-r3-fu10`, `isFinishingScrimUp`) — for the pointer only; keyboard/VoiceOver rely on `.disabled` alone (making it modal to focus + AX is `W3.cap-r3-fu10-fu1`).
  - **An emptied Captured pane still offers Finish and Clear while `hasUnfiledWork`** (`W3.cap-r3-fu12`); Finish is additionally `.disabled` on the narrower `canFinish`, and the two gates must stay separate (v1 shipped an enabled-but-inert Finish). Open: `W3.cap-r3-fu12-fu1`, `-fu2`.
  - **Failure taxonomy is label-only (Tier-2):** `LiveCaptureProcessor.labelStagedRecord(_:type:outcome:results:)` is the ONE labeller (`.failed(.noOutput/.incompleteOutput)`, `succeededNoText`) for first write, rotation-review regeneration and manifest resume. It never changes a finalize/deletion decision — deletion still keys off `executePlans`' `filedGroupIds` + `pagesComplete`.
- **Per-file locations:** see the **Implementation map** (`Capture/`, `Net/`, `Views/`) + its companion note below.

---

## Settings & Tools

- **Settings window (⌘,)** — `Views/SettingsView.swift`, a `Settings { }` scene. All durable settings (provider/model/API mode+key, input/batch/resolution, rotation, tagging options, custom models, live-capture mode) in a grouped `Form`, with a **pinned live cost-estimate pane** (estimates a 1,000-file run, each file at the default 3 MB standard image size). Shared with the main window via `@AppStorage`/UserDefaults + Keychain. The **output folder** is chosen in the Process Files view; the **tagging-mode dropdown** is there too and is also a full control in Settings (Tagging section). The pane's batch total shows only with batch mode on, and it also carries a Segmentation line.
- **Tools tab** — `Views/ToolsView.swift`: **Compare Models** + **Test Resolution** (one-off diagnostics via `OCRProcessor.performResolutionTestCall`; Test Resolution reads at six fixed points, 10/20/40/60/80/100%, and shows text, a similarity badge and a word diff, no cost; disabled with no API key) + **Processing History** (past Process Files runs and their estimated cost).

---

## Test Files
- Located in `Test Files/` directory within the project (gitignored; **not in git** — no recovery via git).
- Deliberately slimmed to a representative + test-critical **minimum** (2026-07-18): all of
  `Ground Truth Segmentation/` (the tier-2 regression anchor — its CSVs + image sequences) and
  `Collection Segmentation*/` are kept whole; the OCR/QA collections (`Herrnstein`, `DeaverLLM`,
  `Dean Papers`, `Deaver and Hannaford`, `Surrey`) each keep a 20–40-file representative sample. The
  culled remainder (~13 GB) was moved to the macOS Trash, not hard-deleted.
- **Don't modify the surviving files, and don't delete the ground-truth folders** — they back the
  smoke/tier-2 tests. Only create new output files (never inside `Test Files/`).

---

## API Keys & LLM Calls
- **LLM/API calls are allowed and expected** — this app is built around them, and running them is a normal part of development and verification. The constraint is **cost, not permission**: keep spending low and get a key first.
- **Do not store API keys in code or config files** — Keychain, or user-provided at runtime, only.
- Before any **paid** run: (1) write a short test plan, (2) estimate the cost **and state it**, (3) use an already-provisioned key (`$OCR_KEY` / Keychain). **No permission step** — money was de-gated 2026-08-13 (`../AGENTS.md` §*Gating baseline*); ask the owner ONLY if no key exists for that provider at all.
- Keep costs low: prefer the cheapest capable model for tests (e.g., `gemini-2.5-flash-lite`, `claude-sonnet-4-6`) and the smallest input set that proves the behavior.

---

## Architecture Notes (macOS Native)
- Language: Swift (macOS app + iPhone companion, `ArchiveCaptureiOS/`) + Kotlin (Android companion, `ArchiveCapture/`)
- UI framework: SwiftUI (AppKit where needed); iPhone companion is SwiftUI + AVFoundation; Android is Jetpack Compose + CameraX
- Concurrency: Swift concurrency (async/await + TaskGroup) for parallel OCR workers; **Swift 6 strict concurrency** (`@MainActor`, `Sendable`, `nonisolated(unsafe)` for the few write-once statics)
- PDF generation: Core Graphics (dynamic page sizing for the text page)
- Filesystem tagging: `NSFileManager` extended attributes (`NSURLTagNamesKey`, `NSURLLabelNumberKey`)
- Networking: URLSession for LLM API calls; an `NWListener` HTTP receiver for Live Capture (`Net/CaptureServer.swift`)
- Settings: durable settings in `UserDefaults`/`@AppStorage` (shared across the main window and the ⌘, Settings scene) + Keychain for keys
- Build: XcodeGen — `project.yml` is authoritative; the generated `.xcodeproj` is **not committed** (gitignored). After cloning run **`./bootstrap.sh`** (installs XcodeGen if missing and regenerates every project); thereafter run `xcodegen generate` whenever files are added (never hand-edit `.pbxproj`). Prerequisite if not using bootstrap: `brew install xcodegen`.

---

## Concurrent / multi-agent development

**Worktree-first is mandatory** — the rule + rationale live in the root [`../CLAUDE.md`](../CLAUDE.md)
(*How we work* + *Worktree-first*). The per-app specifics below (build isolation, ownership lanes, shared
hotspots) assume you're already isolated in your own worktree.

**Worktree lifecycle** (paths contain a space — always quote):
```bash
git worktree add "../ap-wt-<lane>" -b <branch>   # isolated sibling checkout on its own branch
cd "../ap-wt-<lane>/ArchiveProcessor" && xcodegen generate   # required: .xcodeproj isn't committed
# ...work, build (below), commit...
git worktree remove "../ap-wt-<lane>"   # ./build is gitignored, so it doesn't block removal
```

**Per-worktree build isolation** — give each worktree its own DerivedData so concurrent builds don't collide:
```bash
xcodebuild -scheme ArchiveProcessor -configuration Debug -derivedDataPath ./build/DD build
# iOS companion (W40.i1): the generic destination needs the bundled SDK only, no simulator runtime.
(cd ../ArchiveCaptureiOS && xcodegen generate && \
 xcodebuild -scheme ArchiveCaptureiOS -destination 'generic/platform=iOS Simulator' -configuration Debug -derivedDataPath ./build/DD build)
```
`./build` is already gitignored, so per-worktree DerivedData is never committed. Note: `-derivedDataPath` isolates DerivedData and module caches but **not** the shared user-level Clang cache (`CACHE_ROOT`) — treat it as "separate DerivedData per worktree," not fully sandboxed.

**Ownership lanes** — avoid two instances editing the same lane at once:
- **Android** — `ArchiveCapture/` (Gradle, Kotlin). Fully independent.
- **iPhone** — `ArchiveCaptureiOS/` (Swift 5). Back in the verify loop since W40.i1 (2026-10-21; parked
  2026-07-18 to 2026-10-21): the health gate builds it (`ios-build`). Independent *except* the phone↔Mac protocol.
- **macOS OCR core** — `Sources/ArchiveProcessor/{OCR, Models, Capture, Net}`.
- **macOS Views + Tagging** — `Sources/ArchiveProcessor/{Views, Tagging}`.

**Shared hotspots that force cross-lane coordination:**
- **`Models/ProviderModels.swift` enums** (`LLMProvider`, `ThinkingLevel`, `DocumentClassification`, `TaggingMode`, `RotationMode`): all **`String`-backed, `Codable`, and persisted** (UserDefaults + encoded snapshots). **Never rename a case or change an explicit rawValue string** — that orphans users' saved settings. Appending new cases is safe; reordering cases is harmless (the persisted key is the string, not the position). (Exception taken under the no-production-material directive, 2026-08-01: W36.seg-opt-review removed `TaggingMode.autoDateManualSeg`, now `autoDate` + the Segmentation approach Manual; a stale stored value reads as the default.)
- **Phone↔Mac protocol:** `Net/CaptureServer.swift` (Bearer-authed routes `GET /ping`, `POST /photo`, `POST /segment/complete`, `POST /session/complete`, `POST /phone/status`, `POST /session/disconnect`) ↔ both companions' `MacClient` (`ArchiveCaptureiOS/.../Net/MacClient.swift` + Android `net/MacClient.kt`). The cloud-relay transport shares a second contract — the object format in [`../SPEC/relay-object-format.md`](../SPEC/relay-object-format.md) (`Net/RelayObjectFormat.swift` ↔ the phones' mirror). Change all sides together. *(The gate's `ios-build`
  step builds the iOS mirror, and `scripts/test-relay-golden.sh` checks its `RelayObjectFormat.swift` for parity.)*
- **The two `project.yml` files.**
- **`packages/ArchiveCore` (shared Swift package).** The tag/PDF/link contract both apps depend on. Its
  `CoordinatedTagWriter` (`Tags/TagWrite.swift`) is the single Finder-tag write choke-point — Processor's
  `MacOSTagger` is a *fresh-write adapter* over it and Reader's `TagWriter` a *delta adapter*, so no app calls
  `setResourceValue` directly and the coordinated write + verify can't drift. `DocumentTags`, `PDFFormatStatus`,
  `DurableLink` and `PDFThumbnailer` are the shared cross-app types. A change here is
  **Tier-2** and must build+test **all three** apps (Reader + Processor + Notes), not just Processor. SPEC:
  [`../SPEC/tag-format.md`](../SPEC/tag-format.md); build lane: `swift test` in `packages/ArchiveCore` (~100
  tests; wired via `project.yml` → `packages: ArchiveCore`, `path: ../../packages/ArchiveCore`).

**Rules:** never hand-edit `.pbxproj` (edit `project.yml` + `xcodegen generate`, now also required after clone); keep commits small and rebase often; build-verify before every commit.

---

## Verification & review policy (no human in the loop)

This project is maintained by Claude with **no human reviewer, no CI, and minimal automated tests**, yet it
writes **irreplaceable data** (archival photos that can't be re-shot), uses strict Swift-6 concurrency, and
spends real money on API calls. So verification is **deliberate and tiered by risk** — not the same effort on
every change. **Decision (2026-07-04): yes, do adversarial review before pushing — but tier it as below** so
the cost matches the risk instead of running a heavy review on every trivial edit.

**Tier 1 — every commit (always):** build clean with **no new warnings** (`xcodegen generate` + `xcodebuild … build`),
and self-review the diff (`/code-review`, or read your own diff critically). Cheap; catches most regressions.

**Tier 2 — high-blast-radius changes (adversarial, regardless of diff size):** any change touching a class of
bug that has **no undo** gets a multi-agent *adversarial* review — independent skeptic agents that try to
break it — plus a targeted functional test where feasible. **For the Live Capture / phone↔Mac path
(`Capture/`, `Net/`), that functional test is `scripts/e2e-phone-mac.sh`** — the full round-trip E2E
(emulator ↔ real headless Mac; details in the Smoke-tests block below). This tier is triggered by edits to:
- `Capture/`, `Net/` (Live Capture durability, the phone↔Mac protocol, crash-recovery/manifest logic),
- file-writing tag/output code (`Tagging/MacOSTagger.swift`, PDF/image output, collection numbering that could **overwrite** files),
- batch/manifest persistence, or anything changing `@MainActor`/`Sendable`/actor isolation.

**Tier 3 — before every release (DMG + GitHub release; done sparingly):** run a **multi-agent adversarial
review of the whole accumulated diff since the last release** (the *find → refute* pattern: finders propose
defects, a second set of agents tries to refute each, only survivors are real), and a **live smoke test** if
the OCR/tagging/PDF path changed. Cut the release only after it comes back clean.

**The env-gated drivers are Debug-only (W40.a5).** Every `*TestDriver.swift`, `SegmentationProofDriver.swift`
and `*Contract.swift` is wrapped whole in `#if DEBUG`, as is their dispatch in `ContentView` and the stub branch of
`NetworkSession.activeTestTransport`; every driver script runs the Debug build. A new driver gets the same wrapper.
Check with `nm <Release binary> | swift demangle | grep -E 'TestDriver|Contract'`, which should print nothing.

**Smoke tests (the cheap regression gate).** The suite dispatcher and the app-local scripts make Tier-1 a
one-liner — run the relevant lane before pushing an OCR/pipeline change or as a sanity gate:
- **`ArchiveProcessor/test-smoke.sh`** — headless end-to-end OCR: reads the Gemini key from the Keychain
  (never printed/persisted), builds Debug, then drives the **real** Process-Files pipeline
  (OCR → segmentation → tagging → PDF) on exactly **2 tiny images** via `ProcessFilesTestDriver`
  (`PROCESSFILES_TESTMODE=1` + `ARCHIVEPROC_HEADLESS=1`), and asserts a `TEST_DONE` marker plus ≥1 output
  PDF. All I/O is isolated to a `mktemp -d` scratch (own IN/OUT dirs, deleted on exit) — it never writes
  `Test Files/` or a real corpus. Inputs come from `Test Files/` when present, else 2 synthetic text PNGs
  are generated (CoreGraphics/CoreText, headless). Spend is tiny (2 images × `gemini-2.5-flash-lite`, a
  few cents). A key-free run log persists under `.maintenance/test-results/` (gitignored) for FAIL triage.
- **`ArchiveReader/test-smoke.sh`** — Reader build + full unit-test suite (`xcodebuild test`, ~135 tests);
  no OCR/network/corpus.
- **`./test-smoke.sh archivecore|processor|reader|notes|all`** (Suite root; mirrors `launch.sh`) dispatches to
  the shared ArchiveCore package and all three apps. `archivecore` runs `swift test` in
  `packages/ArchiveCore`; default `all` runs it **first**, before Reader, Notes, and Processor, so a shared
  contract failure is reported before a dependent app build or paid OCR. `chmod +x`'d; the dispatcher calls
  `bash <script>` so it works even if the exec bit is lost. This is the deeper Tier-1 companion to the pre-existing
  `scripts/test-smoke.sh` (raw per-provider OCR calls) and `scripts/test-tier2.sh` (multi-case pipeline).

**Visual / render verification.** XCUITest reports only the accessibility tree, not pixels — it won't catch a
GUI that renders blank/wrong. Reader's headless render guards (`RenderProbe` / `DocumentRenderGuardTests`)
therefore still protect the **2-page PDF output** Processor writes (`PDFGenerator`), verifying the Reader-side
read of exactly what Processor produced. Processor now also has the `ArchiveProcessorUITests` UI target:
run `ops/gui/vm-gui-runner.sh processor xcuitest` for its $0, off-screen scratch checks and
`ops/gui/vm-gui-runner.sh processor sighted` to **read pixels**. The suite sets `ARCHIVEPROC_HEADLESS=1` and
guest `mktemp` IN/OUT paths, so it cannot use a key, CLI login, or a real corpus; it covers the Anthropic
key-wizard copy, multi-page-PDF auto-re-OCR UI, and Local Agent wizard/cost panes. See
[`../ops/gui/README.md`](../ops/gui/README.md) and `AGENTS.md` → *GUI verification*.

**Full phone↔Mac round-trip E2E — `scripts/e2e-phone-mac.sh`** (see `scripts/E2E-PHONE-MAC.md`). The only
test that exercises *both* real apps end to end: a real headless Mac session (`LIVECAPTURE_AUTOSTART`) paired
over LAN to the `ap_test36` emulator running the identical Android app, which "captures" known fixtures via
the **debug-only inject seam** (`files/test_inject.jpg`, stripped from release). The Mac OCRs with a real
key (`LIVECAPTURE_OCRKEY`), auto-skips tag cards (`LIVECAPTURE_AUTOSKIPTAGS`), auto-finalizes
(`LIVECAPTURE_AUTOFINALIZE`, **gated on `LIVECAPTURE_TESTOUT`** so it can never file into the real corpus)
and drops `DONE.txt`; then `assert_mac.py` checks each fixture's unique OCR token + year survived the whole
pipeline, and per-doc phone screencaps are checked. Deterministic + unattended (emulator only). Run:
`OCR_KEY=<key> caffeinate -di ArchiveProcessor/scripts/e2e-phone-mac.sh` (falls back to the Keychain key).
**Needs:** the Mac free + awake (headless, but a live app session — don't drive its GUI meanwhile), the
`ap_test36` emulator + android-36 image installed, `xcodegen` on PATH, and a Gemini key (env or Keychain);
spends ~a few cents. It's the Tier-2 functional gate for `Capture/`/`Net/` — **not** a per-commit/CI check
(use `test-smoke.sh` for that). It pairs over `10.0.2.2`, so it never touches USB: for the `adb reverse` tunnel
run `scripts/usb-reverse-probe.sh` (free, no key; real headless app + emulator; W40.d6).

**Cadence:** **push commits to `origin` frequently** — a clean build + Tier-1 self-review (and Tier-2 for
high-blast-radius diffs) is enough to push; don't hoard local commits. **Releases are the sparse milestone:**
build a DMG + tag a GitHub release only occasionally (a coherent, release-worthy batch), gated by the Tier-3
review above. In short: push often, release rarely.

**Always adversarially *verify* findings before acting on them.** With no human to sanity-check, a plausible-
but-wrong "fix" is its own risk: have a second agent try to *refute* each finding (default to "not a bug" when
uncertain) before you change code. The `Workflow` tool's find→verify pattern is the intended vehicle; a durable
example script lives at `.maintenance/` during active maintenance sessions.

---

## Releasing (macOS DMG + GitHub release)

Versioning is by **git tag** (`vMAJOR.MINOR.PATCH`, e.g. `v3.8.1`) — the tag is the source of truth; `Info.plist` `CFBundleShortVersionString` is left at "1.0". Patch bump for internal-only changes (refactors), minor for user-facing features. Distribution is **owner-only** — signed with the suite's local **self-signed** cert
(`CODE_SIGN_IDENTITY: "Archive Suite Dev"`, not ad-hoc since 2026-08-07), still not notarized, so a fresh
macOS may need right-click→Open the first time. Rationale + setup: root [`CLAUDE.md`](../CLAUDE.md)
§*Conventions* and [`../ops/setup-signing-cert.sh`](../ops/setup-signing-cert.sh). Unlike Reader/Notes this
target **declares** no `get-task-allow` / `disable-library-validation`: its entitlements are xcodegen-generated
from `project.yml`'s `entitlements.properties`, which is not config-scoped, so adding them would ship the key
in every configuration. Xcode still injects `get-task-allow` into the Debug signature automatically. Processor
has no app-hosted XCTest target or SwiftUI previews, so W28.cert-fu2 sets `ENABLE_DEBUG_DYLIB: NO` in the
target's **Debug config** and never needs `disable-library-validation`. Release keeps its default executable
layout, hardened runtime, and strict library validation; its target config also sets
`CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO`, because the signed-product audit caught Xcode injecting
`get-task-allow` into Release despite its absence from the map. The Release signature must contain neither
debug entitlement.

**GitHub CLI gotcha:** the real CLI is **`/opt/homebrew/bin/gh`** — call it by full path, because a shadowing Python tool named `gh` is first on `PATH` (bare `gh` fails with an argparse error). It is authenticated as `charlesapetersen` (`repo` scope), so `gh release create` can publish and upload assets.

Build → package → publish:
```bash
cd ArchiveProcessor && xcodegen generate
xcodebuild -scheme ArchiveProcessor -configuration Release -derivedDataPath ./build/rel build
APP="ArchiveProcessor/build/rel/Build/Products/Release/ArchiveProcessor.app"   # from repo root
STAGE=$(mktemp -d); cp -R "$APP" "$STAGE"/; ln -s /Applications "$STAGE/Applications"   # drag-install layout
hdiutil create -volname "Archive Processor <ver>" -srcfolder "$STAGE" -ov -format UDZO "/tmp/ArchiveProcessor-<ver>.dmg"
/opt/homebrew/bin/gh release create v<ver> "/tmp/ArchiveProcessor-<ver>.dmg" \
  --title "Archive Processor <ver>" --target main --notes "…"
```
The `.dmg` is a build artifact — never commit it (build under gitignored `build/` or `/tmp`).

---

## Project Structure
```
Archive Processor/
├── CLAUDE.md, README.md, AGENTS.md, prompts.md, POTENTIAL_FEATURES.md, KNOWN_ISSUES.md
├── macOS/                             # macOS app (XcodeGen: project.yml)
│   └── Sources/ArchiveProcessor/{Models, OCR, Tagging, Capture, Net, Views}/
├── ArchiveCapture/                    # Android companion app (Gradle)
├── ArchiveCaptureiOS/                 # iPhone companion app (XcodeGen: project.yml)
│   └── Sources/ArchiveCaptureiOS/{Net, Capture, Camera, UI}/
└── Test Files/                        # Do NOT modify; write outputs only
```

**Two former "god files" are split for concurrent work** (behavior unchanged):
- `OCR/OCRProcessor.swift` — the `@MainActor` class now holds only stored state + member types; its methods live in `OCRProcessor+{Pipeline,OCR,Tagging,ReviewFlows}.swift` (extensions) and its top-level model types in `OCRProcessor+Types.swift`. When adding a method, put it in the extension matching its concern; **all stored properties stay in `OCRProcessor.swift`** (Swift extensions can't add stored properties).
- `Views/OCRView.swift` — the main view; its sheets/rows/diff engine are separate `OCRView+*.swift` files (FileRowView, the review/model/resolution sheets, WordDiff).

**Refactor notes (behavior-preserving splits).** The `OCRProcessor` split is deliberately **coarse** (4 concern-extensions, not one-file-per-method): related state-mutating logic stays together, which lowers cross-file tracing cost for an agent — so there is intentionally no `+Persistence`/`+BatchOCR`/`+MainPipeline`. When verifying a future large move-only refactor: run the git move-proof (`git show --color-moved | grep …`) **tty-independently** — piping makes it pass for *any* commit, so it proves nothing on its own; audit access-level changes by **census-diffing** private members rather than grepping (Swift `internal` is keyword-less, so a grep can't see it); gate on a **warnings delta** to catch Swift-6 isolation drift (and beware an initial "0 warnings" that is really a cached build masking pre-existing ones). Testing-coverage gap to remember: the batch/instance-method GUI path (`startProcessing → review → performTaggingPhase → finalize`) is **not** exercised by `LiveCaptureTestDriver`, which only drives the live-staging `nonisolated` statics.

See the README's "Project Structure" for the full annotated file tree, and the **Concurrent / multi-agent development** section above for ownership lanes and shared hotspots.

---

## Implementation map

Per-file index (one line each); the folder tree + god-file-split rationale are under "Project Structure"
above, ownership lanes + shared hotspots under "Concurrent / multi-agent development."

`macOS/Sources/ArchiveProcessor/`
```
ArchiveProcessorApp.swift      @main App; main window + ⌘, Settings scene.
ContentView.swift              Top-level tab host (Process Files · Live Capture · Tools).
Models/                        UI-free settings, pricing, keys, shared enums:
  ProviderModels.swift         Persisted, String-backed shared enums (LLMProvider/ThinkingLevel/
                               DocumentClassification/TaggingMode/RotationMode) + GatewayConfig. SHARED HOTSPOT.
  DefaultsKeys.swift           Single source of truth for UserDefaults/@AppStorage key strings.
  ModelSelectionStore.swift    Shared persistence of per-provider selected model + output dir.
  ProviderKeySpec.swift        Per-provider config driving the guided key-onboarding wizard.
  LocalAgentConfig.swift       Local Agent CLI backend selection (tool/path/model/concurrency cap); SHARED HOTSPOT (append-only; rides run snapshot).
  LocalAgentSpec.swift         Per-CLI config driving the guided Local Agent onboarding wizard (no key; claude/gemini).
  KeychainHelper.swift         Store/read API keys in the macOS Keychain.
  CostEstimator.swift          Per-model cost math (standard vs batch) for the estimator pane.
  TimeEstimator.swift          Rough wall-clock processing-time estimate for a batch.
OCR/                           OCR pipeline + provider clients:
  OCRProcessor.swift           @MainActor Process-Files pipeline controller — stored state here; methods
                               in +Pipeline/+OCR/+Tagging/+ReviewFlows, types in +Types (see god-file note).
  AnthropicClient·GeminiClient·MistralClient.swift   Single-shot OCR client per provider.
  OpenAICompatibleClient.swift OCR via any OpenAI-compatible gateway endpoint; also native OpenAI and the pinned
                               OpenRouter provider (`openRouter`; routes in ProviderModels `OpenRouterRoute`).
  BatchOCR.swift               Batch (discounted, async) OCR clients + shared error-body parsing.
  OCRCascade.swift             Cheap-first cascade: a failed page goes to the user's escalation model (W41.app-ocr-cascade).
  InstitutionalComputeImport.swift  Cluster bulk text matched by image SHA-256; per-page cluster provenance (W41.app-institutional-compute).
  PageKindClassifier.swift     Each page's kind on this Mac: the bench's Vision-signal + feature-print regressions (W41.app-page-kind).
  PageKindRouting.swift        Kind → the guide's first runnable pick; the run's PageReaderPlan and per-page PageReaderRecord.
  OCRRefusalFallback.swift     Second readers for a page Gemini refuses (W41.app-ocr-default).
  OCRPrompt.swift              Shared OCR prompt builder (all providers except Mistral OCR).
  ImageEncoding.swift          Shared image→JPEG downscale/encode (byte-identical across providers).
  NetworkSession.swift         Global in-flight-request limiter (the rate-limit choke point).
  KeyValidator.swift           Validate a pasted key with one cheap live call → plain-English status.
  LocalAgentClient.swift       OCR/text via a subscription-authed CLI (claude/gemini/codex) subprocess; dedicated concurrency cap + usage-window pacing.
  LocalAgentValidator.swift    Detect + verify a CLI is installed & signed in → plain-English Status (CLI analog of KeyValidator).
  RotationDetector.swift       Local (Vision) upright-rotation detection.
  LLMRotationDetector.swift    Vision-LLM upright-rotation detection (compares the 4 candidates).
  PDFGenerator.swift           Build the 2-page output PDF (image + dynamic-height OCR-text page).
  PDFTextExtractor.swift       Read OCR text + classification back out of existing PDFs.
  PDFToImageConverter.swift    Render PDF pages to JPEGs for OCR input.
  SampleOCRTester.swift        One-off sample-OCR test helper.
  SegmentJSONBuilder.swift     Pure shared builder for the per-segment `.json` metadata sidecar (body +
                               fields, optional box/folder format override). Both Process-Files and Live
                               writeSegmentJSON delegate to it; callers own the URL + atomic disk write.
Tagging/                       Finder-tag writing + segmentation (Tier-2 — writes irreplaceable data):
  MacOSTagger.swift            Fresh-write ADAPTER over `ArchiveCore.CoordinatedTagWriter`; writes Finder tags
                               (subjects/date/Quality/color + trailing Unread) — no direct `setResourceValue` here.
  TagGenerator.swift           LLM tag generation (subjects + date) from OCR text.
  DocumentSegmenter.swift      Infer document boundaries (Start/Continuation) from OCR/classification;
                               `enclosureOf` (W37) from the OCR `[enclosure]` marker, never adjacency.
  CollectionSegmenter.swift    Group files into box/folder collections.
  SystemTagsProvider.swift     Existing-subject autocomplete for tagging UIs, over the persisted
                               `ArchiveCore.TagVocabulary` (per-root CorpusWalker harvest + what the
                               operator types + every verified write). No Spotlight since W26.vocab.
Segmentation/                  W36 window segmenter (not Tier-2: proposes boundaries, writes nothing). Contract:
                               `execution-plans/segmentation/04-options-build.md` Part 3 §2. `TaggingMode` says who
                               tags, `SegmentationApproach` who segments; `SegmentationPlan` joins them.
  RunSegmentation.swift        `SegmentationPlan` (automatic+manual → the per-page review sheet as before;
                               autoDate/human+manual → `ManualSegmentTagView`; any other approach → windows), the
                               flagged-gap model (`FlaggedReview`: items, keep/split/join → classifications, count
                               line, skim note), and the transport a run's keys / `claude` give.
  (pipeline half)              `OCR/OCRProcessor+WindowSegmentation.swift` `runWindowSegmentationStage`: box/folder
                               confirm → windows → `Views/FlaggedBoundaryReviewSheet` → the skim
                               (`DocumentSegmentReviewSheet` with note + Checked marks). Called from startProcessing,
                               the pre-OCRed path, resumeRun and resumeBatch. Limit/error → "check the rest myself"
                               or stop (resumable: `PendingRun.segmentationWindows`/`segmentationAnswers`).
                               Self-test: `SegmentationReviewTestDriver`, `scripts/test-segmentation-review.sh`;
                               VM UITest `testFlaggedBoundaryPassNeedsEveryAnswerBeforeDone`.
  SegmentationApproach.swift   `SegmentationApproach` (manual/claude/gemini/openai/mix, `DefaultsKeys.segmentationApproach`,
                               default manual; with nothing saved, a Gemini key preselects `gemini`, W41.app-seg-default);
                               `SegmentationOptions` decodes the bundled `segbench-results/options.json`
                               (window shape, rule, level, voters, figures); `WindowVoter.catalog` + prompt-id check.
  WindowSegmenter.swift        Port of the bench: 7/3 windows, reply parser, per-voter combine, min/mean rules, the
                               concurrent runner (retry once; gaps no answer covered → flagged at 0; usage limit →
                               stop keeping answered windows, resumable).
  WindowPrompts.swift          Prompts w1/g1, verbatim from the bench (the test compares the rendering byte for byte).
  WindowTransports.swift       API (Anthropic/Gemini/OpenAI, injectable HTTP seam), `claude -p` (temp dir of page
                               files), and per-provider routing.
  LocalSegmenter.swift         The `local` approach (W41.app-local-seg): the corpus-trained Qwen3.5 2B through mlx-vlm
                               on this Mac, no key; `LocalWindowTransport` (1,024 px, thinking off, one server check
                               before the first window, one window at a time), the chooser's Mac and memory notes.
                               Its options.json row: `method_openrouter.py option-local-seg`.
  SegmentationEngineTestDriver.swift   $0 headless self-test (`SEGMENTATION_ENGINE_TEST=1`,
                               `scripts/test-segmentation-engine.sh`): reproduces the bench's verdict on every gap
                               of a recorded box (`scripts/segbench/engine-fixture-deaver.json`, from
                               `export_engine_fixture.py`), plus rules, failure, usage limit and transports.
  SegmentationChooser.swift    The chooser's row text + cost (Part 3 §3-4); UI in `Views/SegmentationChooserView.swift`.
                               Self-test: `SegmentationChooserTestDriver`, `scripts/test-segmentation-chooser.sh`.
  PlanUsage.swift              The Claude plan route (W36.seg-opt-subscription, `segbench-results/usage.md`): the
                               `stream-json` meter (`rate_limit_event`), `PlanCalibration` (points per notional
                               dollar; rule-7 discards), `PlanCalibrationStore` (median of the last 5 runs, in
                               `DefaultsKeys.segmentationPlanCalibration`), `PlanRunGate` (pause at a 90% five-hour
                               meter; the one first-run question), `ClaudeRoute` (key or plan, asked only when both
                               exist). Never reads the CLI's login. Self-test: `SegmentationPlanTestDriver`,
                               `scripts/test-segmentation-plan.sh`.
  ChatGPTPlanTransport.swift   The ChatGPT plan route (W36.seg-opt-siwc): the voter's windows through the Responses
                               API with the Sign in with ChatGPT token (`store: false`, `stream: true`, SSE; only a
                               completed response answers), OpenAI's subscription_sharing_* codes mapped to stop /
                               fail / retry, `ChatGPTRoute` (key or plan, asked only when both exist). The account is
                               `Net/ChatGPTAuth.swift`; the controls `Views/ChatGPTPlanControls.swift`. Self-test:
                               `SegmentationChatGPTTestDriver`, `scripts/test-segmentation-chatgpt.sh` (fake server).
Capture/                       Live Capture core (Tier-2):
  CaptureSession.swift         Owns a live session: incoming folder, token, received photos, receiver
                               lifecycle, ingest(...) (durable-manifest-before-ack, idempotent (group,seq)),
                               backup folder, segment-complete / drain-gate state.
  CaptureModels.swift          CaptureGroupType + captured-photo/group types (mirrors the phone).
  SessionProcessingConfig.swift  Locked snapshot of all processing settings for the session.
  LiveCaptureProcessor.swift   Streams OCR/tag/PDF per segment as it arrives; end-of-session finalize.
                               Stages into the VISIBLE backup folder (`<session>/_processed/`); finalize
                               deletes a source only after its output is confirmed at the destination
                               (`filedGroupIds`), via the Trash. (Recovery Core Directive.)
  LiveCaptureTestDriver·ProcessFilesTestDriver·FileRelayTestDriver.swift   Headless env-gated end-to-end
                               test drivers (live-staging / Process-Files GUI / FileRelay invariants).
                               Every `*TestDriver`/`*ProofDriver`/`*Contract` file is wrapped in `#if DEBUG`
                               and dispatched from ContentView only in Debug (W40.a5); scripts build Debug.
                               `scripts/lint-release-drivers.sh` (a gate step) fails a new file without it.
  LiveCaptureRecoveryTestDriver.swift   $0/no-OCR headless self-test (`LIVECAPTURE_RECOVERYTEST=1`) of the
                               data-safety invariants: confirm-before-delete + trash-not-rm.
  ProcessFilesTagWarningTestDriver.swift   $0/no-OCR headless self-test (`PROCESSFILES_TAGWARN_TEST=1`) of
                               the W23.m5/h5-fu output-warning contract: a refused Finder-tag write and a
                               placeholder image page are REPORTED, not swallowed by `try?`.
  DualDateTestDriver.swift     $0/no-OCR headless self-test (`DUAL_DATE_TEST=1`, `scripts/test-dual-date.sh`)
                               of W37.dual-date: enclosure marker/relation, cover date → `Sent With`, JSON/
                               resume round-trips, PDF source-date header lines (written by Live Capture only:
                               Process Files renders its PDF before tagging and does not rewrite it).
Net/                           Phone↔Mac transports + cloud relay (Tier-2; the protocol is a SHARED HOTSPOT):
  CaptureServer.swift          LAN HTTP/NWListener receiver; Bearer-authed routes (see hotspot list).
  ChatGPTAuth.swift            Sign in with ChatGPT, natively (OpenAI's devkit is JS): loopback `/callback` + PKCE,
                               `dynamic_agent_client` registration (the issued client id kept for refresh/re-sign-in),
                               RS256 ID-token check against the discovery JWKS, serialized rotating refresh, revoke on
                               sign-out. Tokens in the Keychain (`ChatGPTPlanCredentials`), host id in defaults.
  CaptureReceiver.swift        The receiver role: accept phone pages → ingest, ack only on durable.
  CaptureValidation.swift      Shared group-id safety (path-traversal guard) for both receivers.
  USBBridge.swift              Keeps adb reverse asserted so a USB phone reaches 127.0.0.1:<port>.
  FileRelayReceiver.swift      Watched-directory relay receiver (offline cloud stand-in) + ScanReport.
  RelayObjectFormat.swift      Canonical relay object names/JSON/fingerprint; see SPEC/relay-object-format.md.
  DriveObjectStore.swift       RelayObjectStore over Google Drive (the production cloud relay).
  DriveClient.swift            Drive REST v3 client behind a mockable HTTP seam.
  DriveAuth.swift              Google OAuth (loopback PKCE, drive.file scope).
Views/                         SwiftUI (+ AppKit where needed):
  OCRView.swift                Process Files window; its rows/review/model/resolution sheets + WordDiff live
                               in OCRView+*.swift (see god-file note).
  LiveCaptureView.swift        Live Capture tab: pairing QR, session status, tag cards, Backup Folder reveal.
  SettingsView.swift           The ⌘, Settings scene (grouped Form + pinned live cost-estimate pane).
                               Page-kind note under the model picker: `OCR/OCRPageGuidance.swift` (W41.app-ocr-hierarchy).
  ToolsView.swift              Tools tab: Compare Models + Test Resolution + Processing History.
  CollectionFinalizeSheet.swift  End-of-session: name each collection or append to an existing folder.
  BoxFolderConfirmSheet.swift  Confirm/reclassify every box/folder identification.
  ManualTaggingSheet·ManualSegmentTagView.swift  Sequential manual per-segment tagging.
  ManageModelsView.swift       Add/remove custom model IDs (beyond the built-in lists).
  ProviderKeyWizard.swift      Guided BYO-key onboarding wizard (driven by ProviderKeySpec).
  LocalAgentWizard.swift       Guided Local Agent CLI onboarding wizard (no key; driven by LocalAgentSpec).
  TagInputField·KeyboardTokenField.swift  Autocompleting tag entry + its AppKit keystroke field.
  ArchiveThumbnail·ZoomableImageView.swift  Thumbnail + full-image zoom viewer.
  DropReceiver.swift           Drag-and-drop file intake.
```

**Companions** (separate build; the phone↔Mac protocol + relay object format are the only shared surface):
- **iPhone** — `ArchiveCaptureiOS/Sources/ArchiveCaptureiOS/`: `App.swift`/`ContentView.swift`;
  `Camera/CameraController.swift`; `Capture/{CaptureModels,CaptureViewModel,SessionStore}.swift` (durable
  capture queue); `Net/{MacEndpoint,MacClient,SegmentTransport,FileRelayTransport,DriveRelayTransport,
  DriveClient,DriveAuth,RelayObjectFormat}.swift`; `UI/{ConnectScreen,CaptureScreen,QRScannerView,CameraPreview,
  SegmentTagSheet}.swift`. Own `project.yml` (`xcodegen generate` after adding files); camera capture needs
  a physical device (the simulator has none).
- **Android** — `ArchiveCapture/` (Gradle, Kotlin + Compose + CameraX), the mirror:
  `net/{MacClient,MacEndpoint,QrAnalyzer,SegmentTransport,FileRelayTransport,DriveRelayTransport,DriveClient,
  DriveAuth,RelayObjectFormat}.kt`, `capture/{CaptureModels,CaptureViewModel}.kt`,
  `data/{SessionStore,PhoneBackup,Prefs}.kt`, `ui/{ConnectScreen,CaptureScreen,SegmentTagSheet}.kt`. Fully
  independent except the phone↔Mac protocol.

**W25.retry-backend correction (2026-09-05).** The earlier A1 discussion of a "retry-with-model" sheet is
superseded: all retries reproduce their immutable run/session backend, the provider/model picker is removed,
and the only per-item retry sheet controls image rotation. Live Capture uses
`retryFailed(groupIds:rotation:)`; its processor-held `rotationRetryTarget` remains part of the finalization
guard, but cannot alter routing or credentials.
