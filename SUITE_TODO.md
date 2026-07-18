# Archive Suite — working to-do queue

The **near-term** to-do queue for both apps (see root `CLAUDE.md` §Docs & backlog convention). Long-term
ideas live in each app's `POTENTIAL_FEATURES.md`; detailed in-flight plans live in `execution-plans/`
(indexed below, deleted when shipped). Full-codebase review: the paced method in `REVIEW.md`. Unattended /
autonomous runs: `ops/autonomous/README.md` (durable plan → self-resume daemon), which drains this queue one
bounded item per fresh session.
Paths repo-root-relative; Reader source = `ArchiveReader/macOS/Sources/ArchiveReader/`,
Processor source = `ArchiveProcessor/macOS/Sources/ArchiveProcessor/`.

Legend — effort S/M/L · risk low/med/high · **needs:** none | gui (drive app at runtime) | owner
(account/manual) | corpus-write (safety-sensitive).

## ⭐ TOP PRIORITY — pre-flight for a 2-week unattended run (owner, 2026-07-16)

- [x] **Autonomous 2-week unattended hardening** — `execution-plans/autonomous-2wk-hardening.md` — **DONE
  2026-07-16/17** (supervised sessions, each adversarially reviewed + prove-the-mechanism'd before install).
  All workstreams shipped: **WS1** crash-restart posture (launchd KeepAlive; reboot-survival out of scope) ·
  **WS2** disk-space guard (park+alert on low free) · **WS3** worktree reclamation (safe, no unpushed-work
  loss) · **WS4** per-item attempt cap (park a mis-sized item) · **WS5** `STATUS.md` check-in digest · **WS6**
  remote push alerts · **WS7** periodic build+test+coherence health gate (park on red) · **WS8** Morning-Review
  rotation (`compact-plan.sh` Pass 2) · **WS9** `blocked-on` dependency gating (`next-queue-item.sh`) · **WS10**
  needs-owner hold queue · **WS11** paced whole-project review cadence (`next-review-unit.sh`) · **WS12**
  keychain partition-list fix. Each with a committed regression harness (`ops/autonomous/tests/prove-*.sh`).
  Out of scope (owner): reboot/auto-login, cumulative-cost ceiling.
  **Owner actions to start a long run (standing, not blocking):** run `./ops/autonomous/fix-keychain-access.sh`
  once (DONE 2026-07-17: Gemini/Anthropic/Mistral partition-listed), then `./ops/autonomous/arm.sh` (the run is
  currently DOWN; `arm.sh` now defaults to launchd KeepAlive / crash-restart — use `arm.sh nohup` only if you
  want GUI-verify).

## 🎯 Project focus & ON-HOLD areas (owner, 2026-07-09)

**Focus now:** the **wired (USB) + wireless (LAN/Wi-Fi) phone↔Mac transmission** path and the **Android**
companion — plus the core Mac pipeline (OCR/tag/PDF/finalize) and the Reader, which continue as normal.

**ON HOLD — maintain-only** (keep them compiling / mirror shared-contract changes so they don't rot, but
**no new feature development, and NOT a code-review or bug-fix target**):
- **iOS companion** — `ArchiveProcessor/ArchiveCaptureiOS/`.
- **Cloud (Google Drive) relay transport** — Mac `Net/{DriveObjectStore,DriveClient,DriveAuth}.swift` + the
  `FileRelayReceiver`/`RelayObjectStore` cloud path (incl. the offline `FileRelay` stand-in); both companions'
  `DriveRelayTransport`/`DriveAuth`/`DriveClient`. The `RelayObjectFormat` wire contract stays frozen — only
  mirror it if a focused change forces it.

*Maintain-only* means: if a protocol/SPEC change on the focus path (LAN/USB, Android) requires it, mirror the
minimum into iOS/cloud so they still build — but don't invest effort or reviews there. **Code reviews + fixes
concentrate on:** LAN transport (`Net/CaptureServer.swift`, `CaptureReceiver`, non-Drive `Net/`), USB
(`Net/USBBridge.swift`), the **Android** app (`ArchiveCapture/`), and the Mac pipeline + Reader.

## Active execution plans (`execution-plans/`)
- `devonthink-import.md` — **PLANNING (Archive Notes; HIGH-risk, Tier-2 + reconciliation gate)**: import the
  owner's personal **DEVONthink 3** database (`Test Files/…/Devonthink database for export.dtBase2`, 7.6 GB,
  ~40k rtf/rtfd/txt notes+excerpts) into Archive Notes, losslessly. 3-stage offline pipeline (JXA extract →
  frozen JSON manifest → pure transform → materialize a **fresh** store) + a stop-on-flag verification gate.
  Owner decisions locked (2026-07-17): text notes+excerpts incl. embedded images; archival `file://` →
  durable `archivereader://` Reader links; **primary + additional dates**; pointer-notes → a **Related-notes**
  section. Net-new Notes work: multi-date model (per-date timeline index rows) + Related-notes. Correctness
  core = replicants (shared `uuid` → memberships) vs near-duplicates (different `uuid` → date consolidation),
  and the link-conversion contract (nothing survives as `file://`/`zotero://`/`x-devonthink-item://`; only
  internet URLs stay `://`). See §9 open decisions + §8 owner prerequisites (a Reader root over Archival Photos).
- ~~`autonomous-2wk-hardening.md`~~ — **SHIPPED 2026-07-16/17** (all 12 workstreams; see the DONE rollup above
  + `ops/autonomous/README.md` for the mechanisms, and `ops/autonomous/tests/prove-*.sh` for the proofs). Plan
  deleted per the "delete a shipped plan" convention — git history keeps the detailed Progress log.
- ~~`openai-chatgpt-provider.md`~~ — **SHIPPED (Processor, W13.oai-1/2/3)**: OpenAI/ChatGPT as a first-class
  provider — (1) native `LLMProvider.openai` (model list + param-family adapter + onboarding/validation/cost,
  routed through the reused `OpenAICompatibleClient`) and (2) a one-click **OpenAI gateway preset**. All
  daemon-buildable sub-tasks landed (build-verified, additive + opt-in, default provider unchanged); the
  live-key OCR smoke + OpenAI Batch API (Phase 4) remain the **keyed/owner tail** (see the keyed-tail note in
  Wave 13 + Morning Review). **Plan deleted on ship** (git history keeps it).
- `local-agent-cli-provider.md` — **READY (daemon-buildable), Processor**: drive OCR/tagging through a locally
  installed, subscription-authenticated CLI — **Claude Code + Gemini CLI + OpenAI Codex CLI**, all first-class —
  for enterprise Claude / Gemini / ChatGPT(Edu) accounts with no API key. Additive `localAgent` config sibling to
  the gateway (append-only, keeps resume-critical snapshots unchanged). Tier-2, but the whole gate is satisfiable
  **unattended** via a committed fake-CLI harness ($0). The plan now carries a **Daemon build plan** splitting it
  into `W13.cli-1…4` (unattended) + a keyed/entitlement tail (gemini/codex install; real-CLI live smoke — blocked
  inside a Claude Code session by the nested-session guard). Claude path validated on-machine 2026-07-10.
  → queued in **Provider expansion (Wave 13)** below.
- ~~`archive-notes/` (00a, 01–08)~~ — **SHIPPED** (NEW APP: Archive Notes, W0–W8). The per-wave plans were
  **deleted on ship** (git history keeps them). `execution-plans/archive-notes/00-overview.md` is **RETAINED** as
  the authoritative interface contract (§2 locked decisions, §5 front-matter schema, **§16 Interface Contract**
  cited by `ArchiveNotes/CLAUDE.md`). Cleanup item: fold §16 into `ArchiveNotes/CLAUDE.md` or promote to `SPEC/`,
  then delete — see **Suite doc hygiene** below.
- ~~`index-parallelization.md`~~ — **SHIPPED** (parallel+batched index build + bm25 ranked search +
  search-during-index refresh). Plan deleted.
- ~~`index-pruning.md`~~ — **SHIPPED** (gated content-index pruning). Plan deleted.
- ~~`decades-date-facet.md`~~ — **SHIPPED** (decade date facet). Plan deleted.
- ~~`reader-smart-folders-scoped.md`~~ — **SHIPPED** (smart folders as scoped root). Plan deleted.
- ~~`reader-gui-test-harness.md`~~ — **SHIPPED** (W7.1–W7.5). XCUITest target, accessibilityIdentifiers,
  DEBUG-gated fixture-root override, `make-gui-fixture.sh`, initial test suite (navigation, tag cloud,
  viewer, preview, filter, sort, degrade). Plan deleted.

## Provider expansion — Wave 13 (Processor; daemon-buildable) — queued 2026-07-16
The two proposed provider plans, now **elaborated with a "Daemon build plan"** each so a fresh autonomous session
can build them: each sub-task below is **unattended, $0, no key, no GUI** (build clean + fake-CLI/unit tests +
self-review), with the live-key verification split out to a **keyed/owner tail** (below) that is flagged to
Morning Review, NOT skipped. Do top-to-bottom, one bounded sub-task per session. **OpenAI first (Tier-1, smaller,
reuses the existing OpenAI-format client), then CLI (Tier-2).** New provider changes stay **additive + opt-in** —
never flip the default provider until the keyed live test passes. Legend as above.

**OpenAI / ChatGPT provider** (plan `openai-chatgpt-provider.md` shipped + deleted W13.oai-1/2/3; Tier-1;
SHARED HOTSPOT = the persisted `LLMProvider` enum, append-only):
- [x] **W13.oai-1 — native provider wiring.** Append `case openai` to `LLMProvider` (append-only), add
  `LLMModel.openaiModels` + the model-family param adapter (`max_completion_tokens`/no-`temperature`/
  `reasoning_effort`), route `.openai` through the reused `OpenAICompatibleClient` at the ~6–8 switch sites.
  ⚠️ Model IDs + pricing = clearly-marked `// VERIFY` placeholders (a wrong price is a silent estimator bug →
  Morning Review). | files: Models/ProviderModels.swift, OCR/OCRProcessor+OCR.swift, OCR/LLMTextClient.swift,
  OCR/LLMRotationDetector.swift, Models/KeychainHelper.swift | M | low | none
  — ✅ shipped: `.openai = "OpenAI"` appended; `openaiModels` (all IDs/pricing `// VERIFY`); param adapter
  (`OpenAICompatibleClient.openAI(model:apiKey:)` → `max_completion_tokens` for reasoning models, gateway path
  byte-identical); `.openai` arms added to all **12** exhaustive `LLMProvider` switches (OCR/classify/text route
  via the factory; batch/cancel/rotation defensive-`nil` since `supportsBatch=false`; CostEstimator image-tokens
  placeholder + rotation `nil`). Additive + opt-in — default provider unchanged. KeychainHelper needed no change
  (account = `provider.rawValue`). Build clean, 0 new warnings. **Live OCR + model-ID/pricing verification =
  keyed/owner tail → Morning Review** (Processor has no unit target; smoke needs a live key). ProviderKeySpec /
  onboarding / validation / CostEstimator rows = W13.oai-2; gateway preset + docs = W13.oai-3.
- [x] **W13.oai-2 — onboarding + validation + cost.** `ProviderKeySpec.openai` (+ `onboardable`),
  `KeyValidator.validateOpenAI` (`GET /v1/models`), `ThinkingLevel → reasoning_effort`, `CostEstimator` rows
  (placeholder-priced per above). | files: Models/ProviderKeySpec.swift, OCR/KeyValidator.swift, Models/CostEstimator.swift | S | low | none
  — ✅ shipped: `ProviderKeySpec.openai` added to `onboardable` (guided wizard now offers OpenAI: platform.openai.com
  deep links, `sk-` precheck, no-free-tier cost/card notes, API-not-trained privacy note; URLs/wording `// VERIFY`
  → keyed tail). `KeyValidator.validateOpenAI` (cheap `GET /v1/models` Bearer → 200 works / 401·403 invalidKey /
  429 rateLimited / 5xx providerBusy; mirrors `validateMistral`; documents that /v1/models 200s even with no
  credits → live smoke surfaces insufficient-quota). `ThinkingLevel.openAIReasoningEffort` (low/high) wired through
  the `openAI(model:apiKey:thinkingLevel:)` factory, **gated on `supportsThinking`** so `reasoning_effort` is sent
  only to reasoning models; threaded at the OCR + tagging-text call sites (classification stays reasoning-free).
  Settings gained an **OpenAI manual key field** (generic `keyField` helper, Save/Validated chips) + guided-button/
  help wording; `ContentView.hasAnyKey` counts an OpenAI key. `CostEstimator` `.openai` arms already landed in
  oai-1. Additive + opt-in — default provider unchanged. Build clean, 0 new warnings; Tier-1 self-review.
  **GUI visual (Settings OpenAI row + wizard) + live OCR smoke = keyed/owner tail → Morning Review** (GUI blocked
  this run by the Keychain "Always Allow" seed still being unset under the stable dev cert).
- [x] **W13.oai-3 — gateway "OpenAI" preset + docs.** One-click preset prefilling base URL/model/cost (note:
  custom base URL covers Azure OpenAI / proxies); update CLAUDE.md provider list + README. | files: Views/SettingsView.swift, docs | S | low | none
  — ✅ shipped (code `d866924`; docs/tracker this commit): a **"Fill in OpenAI preset"** button in the
  API-Gateway settings section (`Views/SettingsView.swift` → new `applyOpenAIGatewayPreset()`) prefills the
  public OpenAI endpoint (`https://api.openai.com/v1`), the default model, a display name, and the `.openai`
  cost profile — reading the model ID + pricing from the single source of truth `LLMModel.openaiModels`
  (now the verified GPT-5 gen from `3be8c3d`), so a later pricing/ID edit flows through automatically. It fills
  the cheapest **non-reasoning** model (`gpt-5.4-mini`): the gateway path sends plain `max_tokens`, which OpenAI
  reasoning models reject — the param adapter lives only on the native `.openai` path — so reasoning models go
  via Direct API. A
  HelpButton notes a custom base URL covers **Azure OpenAI / OpenAI-compatible proxies** and that the key goes
  in the Gateway key field. Docs in this commit: Processor **CLAUDE.md** (OpenAI added to the built-in
  provider/model list + the preset note), **README** (4th provider row + table + preset + batch/key-field
  accuracy), **POTENTIAL_FEATURES** (retired the first-class-OpenAI wishlist item). **Plan
  `execution-plans/openai-chatgpt-provider.md` DELETED** — all daemon-buildable OpenAI sub-tasks (W13.oai-1/2/3)
  shipped. Additive + opt-in; default provider unchanged. Build clean, 0 new warnings; Tier-1 self-review.
  **Keyed/owner tail → Morning Review:** the live-key 2-image OCR smoke through gateway + native `.openai`
  (final model-ID confirmation) + OpenAI Batch API (Phase 4); GUI visual (preset button + field fill) deferred
  (GUI off this run).

**Local Agent CLI provider** (plan `execution-plans/local-agent-cli-provider.md` SHIPPED + deleted at W13.cli-4;
Tier-2; fake-CLI harness made the whole gate unattended-satisfiable at $0 — the daemon-buildable code half
W13.cli-1…4 is COMPLETE; only the keyed/owner tail below remains):
- [x] **W13.cli-1 — client + config + additive threading.** `472f850` (config) + `9778572` (client) + `02471bb`
  (threading) + `44730bc` (tests) — `Models/LocalAgentConfig.swift` (Codable/Sendable, append-only
  `LocalAgentTool` claude/gemini/codex, no key) + `OCR/LocalAgentClient.swift` (ocr + textCompletion via
  `Process`: no shell, prompt on stdin not argv, absolute-path binary not `$PATH`, temp-JPEG-by-path,
  concurrent-drain + SIGTERM→SIGKILL timeout, friendly errors never raw stderr; `claude` validated, gemini/codex
  `// VERIFY`) + `localAgent: LocalAgentConfig?` (default nil) threaded into `PendingRun` + `SessionProcessingConfig`
  beside gateway. Tests: committed fake-CLI stub + `localagent-mechanism-test.swift` (standalone $0, **14/14 PASS
  this session** — subprocess plumbing + resume-safety Codable semantics) + in-app `LocalAgentTestDriver` (real
  client + real PendingRun round-trip; RUN via `test-localagent.sh` **deferred → Morning Review**, GUI-off). Tier-2
  gate met unattended (adversarial review + headless functional proof + build clean, 0 warnings). | M | med | none
- [x] **W13.cli-2 — validator + Settings.** `a2be2c7` (checkpoint 1/2: validator+probe) + this commit
  (checkpoint 2/2: Settings). `OCR/LocalAgentValidator.swift` — CLI analog of `KeyValidator`: `detectAndVerify`
  does resolve-binary → `--version` liveness → 1-token round-trip and maps to a plain-English `Status`
  (`cliNotFound`/`cliNotLoggedIn`/`cliEntitlementMissing` + reused `rateLimited`/`offline`/`providerBusy`);
  pure `classify` code→Status. `LocalAgentClient` gained public `probe()`+`ProbeOutcome` (prompt-only round-trip,
  no image ⇒ zero corpus surface) + `cli_entitlement_missing` in the shared error taxonomy (never raw stderr;
  preserves the `fail`→`cli_exit_3`/`notlogged`→`cli_not_logged_in` invariants). Settings: a 3-way **OCR backend**
  picker (Direct API / API Gateway / **Local CLI Agent**) over a `backendMode` binding that centralizes the
  `useLocalAgent` XOR `useGateway` invariant; tool picker + path/model fields + a **Detect & Verify** button
  (wired to the validator) + `?` help; additive `DefaultsKeys`. Additive + opt-in; default backend unchanged.
  **Tier-2** gate met unattended: build clean 0 new warnings + `$0`/no-key/no-GUI `scripts/localagent-validator-test.swift`
  (**27/27 PASS** — exhausts the code taxonomy incl. entitlement + drives the real fake CLI e2e) + adversarial
  self-review. **Interim state (until W13.cli-4 wires the pipeline):** selecting Local Agent mode *persists* the
  config but the pipeline still routes Direct/Gateway (config inert, same as cli-1's threaded-but-unconsumed
  carrier). Live Detect+Verify round-trip + visual gray-out + the cost-pane "subscription" branch (cli-3) →
  GUI/Morning Review. | M | low | none
- [x] **W13.cli-3 — wizard + cost pane + pacing.** `03e65ec` (pacing) + `971c9fd` (wizard) + `584eb32`
  (cost pane). **PACING:** `LocalAgentClient` wraps `invoke()` in a dedicated `RequestLimiter(limit: 2)` (the
  subprocess path bypasses `NetworkSession`'s HTTP limiter) + `parseUsageWindowReset()` reads a reset instant
  out of a CLI rate-limit message (relative / bare-Retry-After / absolute "resets 3pm", with a
  window-size-vs-wait guard + next-occurrence rollover) into `lastUsageWindowResetAt`; the finer per-run 1–2
  cap + OCR-loop honoring land in cli-4. **WIZARD:** `LocalAgentSpec` (claude + gemini; Codex stays on the
  Settings tool picker) + `LocalAgentWizard` (mirrors `ProviderKeyWizard`) wired into Settings via a "Set up
  (guided)…" button + sheet. **COST:** "Included in your subscription — usage limits apply" branch in the
  SettingsView pinned pane + the OCRView Files-tab card (display-only — Local Agent isn't an `LLMProvider`, no
  `CostEstimator` math change). **Tier-2 gate met unattended:** build clean 0 new warnings +
  `scripts/localagent-pacing-test.swift` **18/18 PASS** ($0/no-key/no-GUI: parser table incl.
  guards/rollover/nil + the `RequestLimiter(2)` ceiling holds & every acquire is released) + adversarial
  self-review. **Keyed/GUI tail → Morning Review:** live wizard Detect+Verify + cost-pane/wizard visual (a
  GUI launch this session hit the blocking Keychain modal — owner "Always Allow" seed still needed) +
  install-link/wording verify. | S | low | none
- [x] **W13.cli-4 — pipeline wiring.** `4ee2475` (ckpt1: seams) + `23166b9` (ckpt2: thread+populate) + this
  doc-sync commit. `LocalAgentConfig.fromDefaults` + `currentLocalAgent` mirror; client-construction seams
  (`LLMTextClient.complete`, `performOCRCall`, `classifyViaLLM`) prefer `localAgent` (localAgent > gateway >
  direct); threaded the companion `localAgent:` beside every `gatewayConfig` (TagGenerator, CollectionSegmenter,
  the OCRProcessor OCR/Tagging/Pipeline/ReviewFlows sites, multi-page re-OCR, LiveCaptureProcessor, OCRView,
  ToolsView, `SessionProcessingConfig.fromDefaults`). **Batch + LLM-rotation skipped when active** (OCRView forces
  batchMode=false + defensive dispatch/history guards; `detectRotation` → local Vision). **Resume-safe:** the
  production `PendingRun` persists `localAgent` and both fresh-run + resume paths restore `currentLocalAgent`
  (self-review caught both were missing). `test-smoke.sh` gains a `[3.5]` **fake-CLI** section (runs the $0
  standalone tests + real-CLI probe with graceful skip). Build clean, 0 new warnings; Tier-2 gate met unattended
  (adversarial self-review + `localagent-wiring-test.swift` 18/18 + `localagent-mechanism-test.swift` 14/14).
  Plan `execution-plans/local-agent-cli-provider.md` DELETED (shipped). **Keyed/owner tail → below.** | M | med | none

**Keyed / owner tail (NOT daemon-buildable — do not attempt unattended):**
> The *visual* half of these (does the wizard / Settings row / cost pane look right) is now dischargeable in a
> GUI-on / Morning-Review session via the live sighted loop (`ops/gui/capture-window.sh` + `cliclick` → read the
> shot); only the *live-key / account* halves stay genuinely owner-gated. Don't park a pure visual check on the
> owner as "GUI blocked."
- **⏸️ ON HOLD (owner 2026-07-16) — OpenAI live 2-image OCR smoke** through gateway + native `.openai` (needs an
  OpenAI key). Come back to it. _(Model-ID + pricing `// VERIFY` placeholders are RESOLVED — `openaiModels` is now
  the current GPT-5 generation (gpt-5-nano/-mini/5.4-mini/5.4/5.5) priced per the owner-provided SoCOCRbench
  source; the live-key smoke remains the final ID confirmation, but nothing is blocked on it: the provider is
  additive + opt-in.)_
- [ ] **W13.cli Phase 0 — install `gemini` + `codex` CLIs and confirm entitlements (owner).** Was buried in this
  prose note with no checkbox, so nothing ever tracked it (owner asked for it to be a real item, 2026-07-16).
  Install both CLIs, sign in with the enterprise/Edu accounts, and confirm each is entitled to run OCR. Gates the
  real-CLI live OCR smoke for W13.cli-1…4 (the `claude` path additionally can't run inside a Claude Code session —
  nested-session guard). The fake-CLI harness already covers the code path at $0, so this gates only final
  "shipped". | S | low | owner
- Later phases (not now): OpenAI Batch API (Phase 4) + CLI persistent-`stream-json` perf (Phase 4). Land the
  build-verified code first; these gate final "shipped".

## Known-issues work — Wave 14 (cross-app; owner-requested 2026-07-16)
Actionable open items pulled from the three `KNOWN_ISSUES.md` + the Processor streaming-residuals review, ordered
by value. **Android straggler is first (HIGH).** Each notes what's daemon-buildable vs. the keyed/GUI verify tail.
Legend as above.
- [x] **W14.1 — Android/iOS straggler: never finalize a partial segment [HIGH]** _(Processor KNOWN_ISSUES →
  "Per-capture streaming — residual refinements" #1; focus path: Android + LAN)._ The data-loss guard already
  ships (a straggler is never deleted), but a page still un-UPLOADED when `segment/complete` arrives is **not
  auto-filed** — it lingers unfiled in the Captured pane. **Fix (both companions, kept in sync):** the phone
  **defers `sendSegmentComplete`** (and `finishSession`'s `/session/complete`) until **every page of the segment
  is confirmed `UPLOADED`** — record a pending-complete group, flush it when its last page hits `UPLOADED` from
  BOTH the upload-success path and the auto-retry path. So the Mac never finalizes a partial segment. **Tier-2**
  (Capture/Net, phone↔Mac protocol — no wire-format change: this is send-*timing*, not a new field). Daemon-buildable:
  Android `./gradlew :app:assembleDebug` + iOS `xcodebuild` build-clean + adversarial self-review of the
  defer/flush logic on both companions. **Keyed/owner verify tail:** the on-device / emulator E2E
  (`scripts/e2e-phone-mac.sh`, needs a Gemini key + the `ap_test` emulator; XCUITest admin-prompt caveat) →
  Morning Review. | files: ArchiveCapture/capture/CaptureViewModel.kt, ArchiveCaptureiOS/.../Capture/CaptureViewModel.swift | M | med | none(build)/owner(E2E)
  **✅ ALREADY SHIPPED `ce55511` (2026-07-07); verified + tracker-reconciled 2026-07-17.** The defer/flush fix
  was already in code on BOTH companions: `endedSegments` is the pending-complete record; `trySendSegmentComplete`
  gates on ALL pages `UPLOADED` (Android `CaptureViewModel.kt:527` / iOS `:369`) and is the ONLY caller of the
  transport `segmentComplete(...)` — flushed from the upload-success path (Android `:622` / iOS `:456`), the
  auto-retry loop (Android `:229` / iOS `:524`), and reconnect (`:209`/`:508`). The `session/complete` this item
  also named is **dead code** on the phone (the transport `sessionComplete()` has no caller — the phone "Finish"
  button that once sent it was removed; "Finish session" is a Mac-side backstop). Adversarial refutation (independent
  read of both companion trees) could not break the gate on either side. KNOWN_ISSUES #1 marked FIXED-in-code to
  match #2/#3/#4. **Keyed/owner tail unchanged:** on-device/emulator E2E (`scripts/e2e-phone-mac.sh`) → Morning Review.
- [x] **W14.2 — Reader write-target identity re-verification (Safety §6) [MED]** — shipped `838b456` (primitive)
  + `d393ff3` (Reader adapter). Added opaque `FileIdentity` (backed by `fileResourceIdentifier`, compared via
  `isEqual:` — **never** `.documentIdentifierKey`, which mutates on read) + an opt-in `expectedIdentity:` param on
  `CoordinatedTagWriter.write` that **re-verifies the resolved URL's identity inside the `NSFileCoordinator` block
  before any write and aborts with `.identityMismatch`** on a moved/replaced file; threaded `expecting:` through the
  Reader `TagWriter.apply`/`setReadState` adapter (default nil = behavior-preserving). Tier-2 gate met unattended:
  build clean, 0 new warnings; +8 scratch-copy tests (4 primitive + 4 adapter; the deterministic safety case =
  a *different* file at the same path → abort + replacement untouched) — ArchiveCore 100 green (stable ×3),
  ArchiveReaderTests 23 green. **Follow-up (armed below):** wire capture-at-selection at live call sites so the
  mechanism is armed in production — see "W14.2-fu". | M | med | none
- [x] **W14.2-fu — Arm §6 identity check at live Reader call sites [MED, follow-on to W14.2]** — shipped
  `1a7c6cb` (checkpoint: `ArchiveFile.liveIdentity()` on-demand capture + the identity-carrying
  `TagWriter.apply(_:to:[(url,identity)])` batch overload + a scratch-copy test) + this commit (arming +
  docs). All **6** `NavigationModel` `TagWriter.apply`/`setReadState` call sites — `mark`, group edit
  (⌘I), inline edit/read-state, corpus-wide rename (via the batch overload), and **undo** — now capture
  the file's `FileIdentity` **lazily at edit time** (via `liveIdentity()`, never at bulk discovery, so the
  `ArchiveFile` "no per-file I/O" fast path is untouched) and pass it through `expecting:`. Undo re-verifies
  against the identity captured at the ORIGINAL edit (undo stack now carries per-write identity), so a file
  swapped under its path between edit and undo is skipped, not mis-tagged. **Tier-2 gate met unattended:**
  build clean, 0 new warnings; behavior-preserving threading (identical accounting) + the §6 write-path is
  fully unit-tested on scratch copies (existing 3 §6 adapter tests + the new batch test) + adversarial
  self-review; ArchiveReaderTests 199/200 (the 1 failure is the pre-existing `DeepLinkTests.testRevealAndSelectNoRoot`
  env flake, unrelated). No visible UI effect (invisible safety guard, only fires on a file swap), so no
  GUI drive; an optional live regression smoke on a scratch corpus → Morning Review. | files: ArchiveReader
  Views/NavigationModel.swift, Core/ArchiveFile.swift, Core/TagWriter.swift | done
- [x] **W14.3 — Notes: extract-paste imports inline-image BYTES [MED]** _(Notes KNOWN_ISSUES → "Extracts
  create/copy-paste follow-ups")._ The copy side embeds image bytes and Create/Append persist them, but the live
  extract-editor **paste** handler still inserts image *references* without importing the payload's bytes into the
  extract's own `assets/` (and rewriting refs on name collision) — so a live copy→paste renders missing-asset
  placeholders until re-saved via Create/Append. **Fix:** in `MarkdownEditorView.handlePassagePaste` →
  `ExtractBuilder.pastedExtractMarkdown`, import the `com.archivenotes.passage` payload bytes into the extract's
  `assets/` (reuse `ItemAssetStore` reserve→write; no-overwrite guard) and rewrite refs on collision. Store +
  payload bytes both already exist. **Tier-1/2** (writes to the Notes store — scratch-testable). Daemon-buildable +
  unit-testable (`ExtractBuilder`/`ItemAssetStore` tests); GUI copy→paste drive → Morning Review. | files:
  ArchiveNotes/.../Editor/MarkdownEditorView.swift, Core/ExtractBuilder.swift | done — new
  `pastedExtractMarkdown(from:importingAssetsVia:)` overload imports each segment's bytes into the extract's own
  `assets/` via `ItemAssetStore.addAsset` (reserve→write, no-overwrite guard) + rewrites `](assets/…)` refs on
  collision; `handlePassagePaste` wires it in. +3 scratch Tier-2 tests (byte-on-disk, no-clobber disambiguation,
  nil-import resilience); full ArchiveNotesTests green (189 XCTest + 513 swift-testing). Also unbroke the Notes
  test bundle (`67f8938`: W14.2's new `TagWriteError.identityMismatch`). GUI copy→paste drive → Morning Review.
- [x] **W14.4 — Notes W7 polish cluster [LOW]** ✅ COMPLETE 2026-07-17 (`592049a` a + `7ef833d` d + `d615589` c +
  this commit b/docs) _(Notes KNOWN_ISSUES → W7-S2/S3/S4 follow-ups, all four addressed)._ (a) dropped the
  always-succeeds `[NSValue]` cast in `EditorPassageSource` (warning gone); (b) `NoteEditorPane.handleOpen` now
  fronts+focuses the featuring window (`openWindow(id:)` + `NSApp.activate`) on jump-to-source, and
  `NotesModel.create/appendToExtract` route the new/updated extract through `openItem` so the Extracts window
  selects (and raises) it; (c) new `NotesModel.itemsGeneration` (bumped in `replaceItems`) drives a reactive
  chip re-style in `MarkdownEditorView` on any item-set change — gated to chip-bearing docs, scroll preserved;
  (d) per-window `NotesAppSettings.windowHiddenColumns(for:)` (Note window hides the always-blank Sources
  column, Extracts shows it), wired through `NotesTableView`/`ColumnPickerHeaderView`. +7 unit tests; full Notes
  unit suite 709 green (520 swift-testing + 189 XCTest), build clean 0 new warnings. **Tier-1.** **Live GUI drive
  → Morning Review:** window raise/focus (b), cross-window chip recolor (c), two-window column visibility (d).
- [x] **W14.5 — Processor legacy staging-manifest rotation review [LOW, do last]** ✅ COMPLETE 2026-07-17
  (Processor KNOWN_ISSUES #1). Fix option 1 shipped: `loadStagingManifest()` now migrates a legacy manifest
  (bare `[StagedSegment]`, no `retained`) via new `migrateLegacyManifestSegments(_:sourcesPresent:)` — it
  DROPS each legacy segment whose source photos all still exist (deleting its stale staged output) so the
  existing resume path re-processes it from scratch (re-OCR + re-tag → proper `retained` → a COMPLETE rotation
  review), then rewrites the manifest in current format (idempotent). **Data safety (Recovery Core Directive):**
  a legacy segment whose source is gone is KEPT as-is (today's behavior) — we never delete regenerable output we
  can no longer rebuild; raw sources always stay in the backup folder. Tier-2 met unattended: build clean, 0 new
  warnings; +5 scratch checks in `LiveCaptureRecoveryTestDriver` (drop-reprocessable / keep-unreprocessable /
  delete-stale-output / preserve-unrecoverable) → **ALL PASS ($0, no OCR)** + adversarial self-review (confirmed
  `session.groups` is computed from `session.photos`, so dropped segments' pages are guaranteed present to
  re-OCR). **Full E2E verify (legacy manifest + OCR key to actually reprocess) → keyed/owner → Morning Review.**
  | files: Capture/LiveCaptureProcessor.swift, Capture/LiveCaptureRecoveryTestDriver.swift | S | low | owner(verify)

**Parked — explicitly NOT a Wave-14 work item:** Processor cloud/relay **post-finalize reclassify → duplicate
output** (A11, MED, Drive-milestone) lives entirely in the **Google-Drive relay path**, which is **ON HOLD /
maintain-only** (see §Project focus). Leave parked until the Drive milestone is un-held; do not build it unattended.

## Archive Notes — DEVONthink import (owner, 2026-07-17)
- [ ] **Import the personal DEVONthink database into Archive Notes** — plan
  `execution-plans/devonthink-import.md` (PLANNING). Losslessly migrate the owner's 7.6 GB DEVONthink 3
  "Meritocracy Project" DB (~40k notes+excerpts) into Archive Notes: 3-stage offline pipeline (JXA extract →
  frozen JSON manifest → pure transform → materialize a **fresh** store) + a stop-on-flag reconciliation
  gate. Delivers net-new Notes features (multi-date primary+additional with per-date timeline rows;
  Related-notes section) and a deletable import toolchain. **Owner prerequisites (§8):** a Reader root over
  `~/Desktop/Google Drive/Archival Photos/`, a copy of the `.dtBase2`, a fresh output store; resolve §9 open
  decisions. Next step = **DTI-0 spike & ground-truth** on a DB copy. | HIGH risk · Tier-2 · **needs:** owner
  + corpus-safety
- [ ] **Reader/Notes: PDF + JPEG dual image reference** (owner, 2026-07-17). Let a Reader image entity — and
  thus the durable link surfaced in Notes — reference **both** an archival PDF and its JPEG partner (opens the
  PDF by default; user can switch to the higher-detail JPEG when the PDF lost resolution). Naming/paths mirror
  1:1 (`Archival Photos/<Coll>/00140 — Swarthmore.pdf` ↔ `Archival Photos JPEGS/<Coll>/00140 — Swarthmore.jpg`),
  so the partner is derivable by filename. Supports the DEVONthink import (see `execution-plans/devonthink-import.md`
  §4a) but is a standalone Reader feature. **Verify:** headless render guards (`RenderProbe`/`DocumentRenderGuardTests`)
  that both the PDF page and the JPEG partner render non-blank; the live sighted loop (`ops/gui/`) for the in-viewer
  PDF↔JPEG switch. | Reader + Notes + ArchiveCore (durable-link/image entity) | M | med | none

## Suite doc hygiene (owner / small) — 2026-07-16
- [ ] **Fold Archive Notes `00-overview.md` §16 (Interface Contract) into `ArchiveNotes/CLAUDE.md` or promote to
  `SPEC/`, then delete the plan.** The per-wave Notes plans shipped + were deleted; `00-overview.md` is retained
  only because §2/§5/§16 are still cited by `ArchiveNotes/CLAUDE.md`. Doc-only; Tier-1. | S | low | none
- **Worktree hygiene (standing rule, not a to-do).** The 4 stray `suite-wt-2026071[45]-…` worktrees this note
  used to list are **gone** (cleaned 2026-07-16) — don't go looking for them. Standing rules: remove your own
  worktree once your work is pushed, and **never touch a worktree you didn't create.** In particular **IGNORE the
  Codex worktree** — `~/Documents/GPT/archive-suite-processor-fixes` (branch `wt/codex-processor-bugfixes-*`) is
  a different agent's and routinely holds uncommitted WIP: do not clean it, remove it, salvage it, or surface it
  to the owner as a stray. Leave it entirely alone (owner instruction 2026-07-16; also in `AGENTS.md`).

## Owner GUI-pass follow-ups — 2026-07-16 (from the interactive Reader + Processor GUI review)
Surfaced during the owner's live GUI pass. Each is scoped + daemon-buildable unless flagged owner-decision/Tier-2. Legend as above.
- [x] **Guided key setup for Anthropic (Processor).** The onboarding wizard's `onboardable` list is
  `[.gemini, .mistral, .openai]` — Anthropic has only a manual key field. Add `ProviderKeySpec.anthropic`
  (console.anthropic.com deep links, `sk-ant-` precheck, cost/privacy notes) so Anthropic gets the same guided flow.
  **Verify:** drive the wizard with `ops/gui/capture-window.sh` + `cliclick` and read the shot — the visual half is
  no longer owner-gated (TCC granted). | files: Models/ProviderKeySpec.swift (+ `onboardable`) | S | low | none
  — ✅ shipped: `ProviderKeySpec.anthropic` added (mirrors the `.openai` spec — console.anthropic.com deep
  links for keys/billing/privacy, `sk-ant-` precheck, honest no-free-tier cost/privacy/card notes; URLs +
  wording `// VERIFY`) and prepended to `onboardable` → `[.anthropic, .gemini, .mistral, .openai]` (enum order,
  Anthropic is the lead provider). The item under-scoped its file list: the spec's `validate` closure needs a
  validator, so **`KeyValidator.validateAnthropic`** was also added (cheap `GET /v1/models` with
  `x-api-key`+`anthropic-version: 2023-06-01` — matching the app's Anthropic OCR clients; 200 works / 401·403
  invalidKey / 429 rateLimited / 5xx providerBusy; like OpenAI, /v1/models 200s even for an unfunded account →
  live smoke surfaces that). Keychain account = `LLMProvider.anthropic.rawValue` ("Anthropic"), so the wizard
  writes the same slot the app reads. The wizard is fully generic (the only provider-specific branch,
  `geminiRegionWarning`, returns nil for Anthropic — same as OpenAI). Additive + opt-in; no default-provider
  change. Build clean, 0 new warnings; Tier-1 self-review. **GUI visual (wizard "Set up (guided)…" → Anthropic
  step) → Morning Review** (GUI off this run).
- [x] **OpenAI LLM rotation detection (Processor).** `.openai` is wired to LOCAL Vision rotation only
  (`LLMRotationDetector.swift:72` + `CostEstimator.rotationModelCost` return nil — defensive, like Mistral/gateway).
  OpenAI is a capable vision model, so wire `.openai` into the LLM candidate-compare rotation path + add its
  `rotationModelCost` arm, matching Anthropic/Gemini (keep local Vision as the free default; Mistral genuinely can't
  → leave nil). | files: OCR/LLMRotationDetector.swift, Models/CostEstimator.swift, OCR/OCRProcessor+OCR.swift | M | low | none
  — ✅ shipped: `.openai` wired into the LLM candidate-compare rotation path — extended the `LLMRotationDetector`
  provider guard + added `askOpenAI` (OpenAI vision chat: `image_url` data URLs, Bearer auth,
  `choices[0].message.content` parse; endpoint via `OpenAICompatibleClient.openAIBaseURL`) on a new
  **non-reasoning** `cheapOpenAIModel = gpt-5.4-mini` (deterministic `temperature: 0` + `max_tokens: 8`; a
  reasoning model would reject `temperature` and could burn the tiny budget on hidden reasoning). Added the
  `CostEstimator.rotationModelCost` `.openai` arm `(0.75, 4.50)` + a tiling-accurate per-candidate token estimate
  (765), so the cost estimate now matches the runtime path. Local Vision stays the free default; Mistral/gateway
  still nil; any call failure falls back to local Vision. **`OCRProcessor+OCR.swift` needed no change** —
  `detectRotation` already passes `provider` through generically (the item over-scoped its file list, like
  W13.oai-1). Additive + opt-in; default provider unchanged. Build clean, 0 new warnings; Tier-1 self-review.
  **Live-key OpenAI rotation smoke (does gpt-5.4-mini pick the upright candidate?) + final model-ID/pricing
  confirm → keyed/owner tail → Morning Review.**
- [ ] **Auto-route multi-page-PDF drops to re-OCR; retire the mode toggle (Processor) — owner-clarified 2026-07-16.**
  A dropped multi-page PDF should just run the re-OCR flow (render each page → LLM-OCR → interleaved image/OCR-text
  PDF) automatically — **no text-layer heuristic.** Owner's rule: `preOCRedInput` exists only to send input through
  the **tagging pipeline** (segment + tag), which is **not relevant to a multi-page PDF** (an assembled document, not
  a page stream to segment). So: multi-page PDF dropped → auto re-OCR; keep `preOCRedInput` as the separate
  tagging-pipeline path (single-page/image input); retire the manual "Re-OCR multi-page PDF" Settings toggle.
  **Tier-2** (PDF output). **Verify:** a render guard on the interleaved image/OCR-text PDF output (the 2-page-SPEC
  surface `DocumentRenderGuardTests` already guards from the Reader side) + `ops/gui/` for the drop-zone / toggle
  removal. | files: Views/OCRView.swift, OCR/OCRProcessor+Pipeline.swift | M | med | none
- [x] **Reader tag-filter → token field (selected tags INSIDE the box) [BUG-3 pane shift] — SHIPPED `b5a5a01`,
  owner-verified 2026-07-16 ("no longer pushes the left margin, all is good").** Selected subject filters used to
  render as separate buttons beside the "Add tag filter…" combo box, so each chip's width tipped the content column
  past the window and the root `HStack` re-centered, dragging the file table left. Two container attempts failed
  (a capped horizontal `ScrollView` reserved its max eagerly → overflowed on the FIRST chip; a wrapping
  `FlowLayout` got squeezed to ~one chip wide and piled vertically). Fix: new `Views/SubjectFilterTokenField.swift`
  — an `NSTokenField` whose tokens ARE the filters, bounded (220 pt), single-line, horizontally scrolling, with LOW
  horizontal compression resistance, so adding filters adds **zero** width to the bar → shift fixed by
  construction, and tags live in the box as the owner expected. Replaced/deleted the `TagFilterField` combo box
  (its only call site). Build clean; Reader units 194/195 (the 1 failure is the pre-existing env-only
  `DeepLinkTests.testRevealAndSelectNoRoot`). | files: Views/SubjectFilterTokenField.swift (new),
  Views/NavigationWindowView.swift, Views/TagFilterField.swift (deleted) | done
- **Processing History view — KEEP (owner-confirmed 2026-07-16).** The Tools-tab history view (W12-cost, promoted
  from POTENTIAL_FEATURES 2026-07-15; records actual run cost + a run log, writes only its own store) stays. No action.

### Owner dispositions — Morning-Review sweep, 2026-07-16
Owner went through the owner-only queue. Recorded here so none of it gets re-surfaced as an open ask:
- **Environment: TCC grants (Accessibility / Screen Recording / Automation) are SET, verified live.** Sessions can
  drive + screenshot the GUI themselves — see `AGENTS.md` → *GUI verification*. The Processor's Keychain
  "Always Allow" is **seeded**, so its GUI launches unattended. **Stop deferring visual checks to the owner as
  "GUI blocked"** — that claim was stale and cost the owner a lot of pointless eyeballing.
- [x] **Visual-render test tooling — the pixels XCUITest can't see (NEW 2026-07-17).** XCUITest only reads the
  accessibility tree (element exists/hittable); it is blind to whether a PDF/scan actually *drew*. Added two
  layers: **(1) headless pixel guards** — `RenderProbe.swift` renders a SwiftUI view (`ImageRenderer`) or a PDF
  page (ArchiveCore `PDFThumbnailer`) to real pixels and asserts on them (`assertRendersNonBlank`,
  `nonWhiteFraction`); `DocumentRenderGuardTests.swift` guards the **2-page PDF SPEC** (page 0 scan / page 1 OCR)
  + a negative "blank page IS flagged" test; runs in the unit bundle with **no launch / no TCC prompt** → health-
  gate-safe. Reference-image diffs via **swift-snapshot-testing** (`SnapshotTests.swift`, new SPM dep). Rendered
  PNGs are logged as `ARTIFACT <name>: <path>` + attached to the .xcresult so a session can `Read` them.
  **(2) live sighted loop** — `ops/gui/capture-window.sh` grabs a running window's on-screen pixels (needs GUI-on)
  to pair with `cliclick`. Installed `imagemagick` for image ops. Reader units 205/206 pass (the 1 failure is the
  known env-only `DeepLinkTests.testRevealAndSelectNoRoot`). Pre-push adversarial review (workflow) fixed 3 issues
  (OCR fixture ink margin vs font-smoothing, uniform grey/black blank detection, AppleScript arg injection in the
  capture script). Considered Appium mac2 → **rejected** (same XCUITest substrate, so same a11y-tree blindness +
  extra TCC surface). | files: ArchiveReader/macOS/Tests/
  ArchiveReaderTests/{RenderProbe,DocumentRenderGuardTests,SnapshotTests}.swift, ArchiveReader/macOS/project.yml,
  ops/gui/{capture-window.sh,README.md}, AGENTS.md | done
- **DROPPED — Live Capture output-folder default** ("forget about this", owner 2026-07-16). The Downloads-if-unset
  default stays; the picker already lets the operator change it. Not an open question.
- **iOS is ON HOLD — read §Project focus before listing anything iOS.** The iOS Drive-relay OAuth client was
  surfaced to the owner in error: iOS *and* the Google-Drive relay are BOTH on-hold/maintain-only. Anything in
  `ArchiveCaptureiOS/` or the Drive path is out of scope until un-held; don't re-list it.
- [ ] **Notes: extract a shared numeric sort-date combiner in ArchiveCore [LOW].** `Item.sortDate`
  (`ArchiveNotes/Store/Item.swift`) re-implements the shared `*10_000/*100` formula instead of reusing
  `ArchiveCore.DocumentTags.sortDate` (ArchiveCore exposes no `(year,month,day,decade)→Int?` combiner for Notes'
  `date:String?`+`datePrecision` input). Drift is already caught by a value-parity test
  (`ItemSortDateTests.testItemSortDateMatchesArchiveCoreSharedFormula`), and sort order is display-only (never
  written to a corpus → no file-safety stakes) — so this is a **low-priority** de-dup, below the W9 Notes
  gap-closure. Tier-1. | files: packages/ArchiveCore (new combiner), ArchiveNotes Store/Item.swift | S | low | none
- **CLOSED — `sessionComplete()` dead protocol surface: WON'T DO, PARKED (owner 2026-07-16).** ~30 lines of
  unreachable code in both companions' `SegmentTransport`/`MacClient`/`DriveRelayTransport`/`FileRelayTransport`
  (nothing calls it; the Mac's `/session/complete` route stays as a harmless no-op for older phones). Removing it
  would mean editing the *frozen* `RelayObjectFormat` wire contract (`encodeSessionComplete` +
  `sessionCompleteMatchesGolden`) and the on-hold Drive path for zero functional gain. **Do not re-raise** unless
  the Drive milestone is un-held AND `RelayObjectFormat` is already being edited for another reason.
- [ ] **R13d REVERSED — remove `ArchiveSuite` stamping from Notes; drop the exclusion feature entirely
  (owner decision 2026-07-16: "Forget about excluding other tagged files. Notes should no longer tag things as
  ArchiveSuite").** The marker was only ever written, never consumed (no Reader filtering / Processor stamping /
  back-fill), so the whole feature goes rather than getting finished. Scope:
  - Stop stamping: drop `suiteMarker` from the managed vocabulary (`ArchiveNotes/Core/NotesTagVocabulary.swift:11`
    → `ArchiveSuiteMarker.tagName`) so `NotesTagProjector` neither adds **nor removes** it; the marker-filter in
    `Core/ItemSummaryDisplay.swift:39-43` then becomes dead and can go too.
  - **⚠️ Decide the projector semantics deliberately — this is the Tier-2 trap.** `NotesTagProjector` *manages*
    its token set: if the marker stays "managed" but merely "not desired", the next projection **strips
    `ArchiveSuite` from the owner's existing note files** (a real tag WRITE). Removing it from the managed set
    instead leaves existing stamps in place, inert. Default = **leave existing stamps alone** (no corpus write);
    only strip them if the owner explicitly asks. Whichever is chosen, prove it with a scratch-copy test.
  - Retire the now-unused marker surface: `packages/ArchiveCore/Sources/ArchiveCore/ArchiveSuiteMarker.swift`
    (check `Links/RootMarker.swift` — the root marker is a *separate* durable-link concern and must survive).
  - **SPEC** (`SPEC/tag-format.md:71`, the "Suite marker" row) — the tag/PDF contract is the **highest-risk shared
    surface**: update it in the SAME commit as the code. This also **inverts W9 Phase A's "finish the SPEC
    `ArchiveSuite` marker section"** — that sub-task is now "remove it".
  - Drop the `(later)` behavior/data follow-on's marker half (Reader hides `ArchiveSuite` / corpus back-fill /
    Processor stamping) — see that item below.
  **Tier-2** (tag-write path + the shared SPEC): adversarial review + a scratch-copy functional test; NEVER the
  real corpus. | files: ArchiveNotes Core/{NotesTagVocabulary,NotesTagProjector,ItemSummaryDisplay}.swift,
  packages/ArchiveCore/ArchiveSuiteMarker.swift, SPEC/tag-format.md | M | med | none

## Archive Notes — NEW APP (SHIPPED W0–W8, 2026-07; `execution-plans/archive-notes/00-overview.md` retained)
Owner-specced third Suite app; foundational decisions locked (D1–D10, `00-overview.md §2`). **All waves shipped;
the per-wave plans (`00a`, `01`–`08`) were deleted on ship** (git history + the W0–W8 `[x]` records below are the
account); only `00-overview.md` is retained as the authoritative interface contract. DevonThink informs **only**
the 3-pane browsing shell — everything else (note appearance, link/provenance UI, replication semantics) is
purpose-built for the historian's provenance-first workflow. **Owner decision points (early):** (a) **R13d** —
the `ArchiveSuite` *exclusion* effect is deferred to the later behavior/data follow-on (see `00 §2` call-out).
**Confirmed (owner):** the FULL **ArchiveCore extraction + Reader/Processor migration is W0 — done FIRST** (`00a`),
before any Notes-specific work.
- [x] **W0** **ArchiveCore extraction + Reader/Processor migration (FIRST)** — create `packages/ArchiveCore`, move
  the shared tag/PDF/date contract (facet parser + `sortDate` + read + the audited **write** path + Processor
  vocabulary/formatting + `PDFTextExtractor`/`PDFFormatStatus` + new `RootMarker`/`DurableLink` + `ArchiveSuite`
  recognition) out of both shipping apps and migrate them onto it; behavior-preserving, parity-gated, one audited
  write seam; adds the SPEC delta — `00a-archivecore-refactor.md` — **Tier-2** (TagWriter + both apps + SPEC)
  (S0 `f050d88` → S5 `cd7ff4f` → S6 `b90800f`)
- [x] **W1** scaffold + app skeleton **depending on the W0 ArchiveCore** — `01-scaffolding-and-core.md` — Tier-2 (scaffold)
  (S1 `7cddf60` → S2 `254fd73` → S3 `91c3c45` → S4 `220b582` → S5 docs)
- [x] **W2** store + front-matter I/O + virtual folders/replication + FTS5 index — `02-storage-model-and-index.md` — Tier-2 (writers)
  (S1 `64eaa9c` → S2 `02201f0` → S3 `2404852` → S4 `afd06c7` → S5 org graph + organization.json)
- [x] **W3** rich-text/Markdown editor (WYSIWYG + raw toggle, inline images) — `03-rich-text-markdown-editor.md` — Tier-1
  (S1 `0db7f61` → S2 `16e0f43` → S3 `1f740b3` → S4 `2261b1f` → S5 `78a9fb5` → S6 perf+cache+tests)
- [x] **W4** source blocks + page thumbnails + Reader URL scheme/reveal + durable links — `04-sources-and-cross-app-linking.md` — Tier-2 (Reader deep-link)
  (S1 `0b7b89d` → S2 `8a7012c` → S3 `1e81b71` → S4 `f477f3a` → S5 `15c690c` → S6 `0ddf88e` → S7 reveal+preview)
- [x] **W5** Zotero metadata / citations / chips — `05-zotero-integration.md` — Tier-1
  (S1 `3704c6a` → S2 `2dac700` → S3 `97547c1` → S4 `f420346` → S5 settings + degrade polish)
- [x] **W6** viewers + search/filter/sort + replication UI + templates + dates/quality — `06-viewers-search-replication.md` — Tier-2 (delete path)
  (S1 `27d3952` → S2 `70bfd1e` → S3 `c37f175` → S4 `92f84f4` → S5 `3d46c0d` → S6 `598d2f2` → S7 dates & quality UI)
- [x] **W7** extracts (snapshot + provenance, blocks→notes, jump-to-source) — `07-extracts.md` — Tier-1
  (S1 `f5efe60` → S2 `71ca1db` → S3 `50920ce` → S4 `c8c93ee` → S5 `328bff3` → S6 app-quit/window-close autosave flush)
- [x] **W8** tests + XCUITest/cliclick GUI harness (scratch corpus) — `08-testing-and-gui-verification.md` — Tier-1/2
  (S1 `0f164ed` → S2 `6ef2244` → S3 `3aa27e2` → S4 `6f22159` → S5 `2a412c9` → S6 `6ce10a6` →
  S7 GUI-harness scaffold `98a4afc`–`0e7472c` → S8 per-wave GUI checks `f79e279`–`267ca8d` +
  S8b probe-queryability + owner-eye README → S9 durable-link E2E `17a2d27`/`7d2dcb8` + `GUI_SAFETY.md`)
  — **W8 COMPLETE (GUI-on):** full `ArchiveNotesUITests` suite (G0–G11 + Smoke) **13/13 TEST EXECUTE SUCCEEDED**;
  the `an.status.indexReady` probe is now XCUITest-queryable (G0); owner-eye checks (G2/G6/G11 + chip clicks)
  documented in `ArchiveNotes/scripts/GUI-HARNESS.md`. **Completes Archive Notes (Wave 11 / W0–W8).**
- [ ] **W9 (gap-closure)** post-ship reconciliation from the 2026-07-16 plan-vs-build review (all W0–W8 verified
  substantially complete + data-safe; these are the promised-but-absent / partial / built-but-not-wired deltas)
  — `09-gap-closure.md` — mixed Tier-1/Tier-2 per item; ends with a **verification review (Phase E)** that gates
  deleting the plan:
  - **Phase A — docs/tracker (DOC):** write `ArchiveNotes/README.md` + `AGENTS.md`; add Notes to root `README.md`;
    finish the SPEC `ArchiveSuite` marker section (**Tier-2**); delete shipped plans `00a`/`03`/`07`/`08`; fix stale
    `SUITE_TODO`/`CLAUDE.md`-map entries; add `SMOKE_TEST.md`; drop `@testable` in `DocumentTagsTests`.
  - **Phase B — wire built-but-dead features (HIGH→MED):** Zotero auto-fill action + note-level chips (dead code,
    no UI); note retitle/tag-edit path; page-thumbnail render end-to-end (Reader passes `thumbnailer:nil`); consume
    `archivenotes://open`; embed image bytes on the extract menu path; guided root re-grant. Mostly **Tier-2**.
    **Verify the render items** (page-thumbnail end-to-end) with a headless render guard — the `RenderProbe`/
    `DocumentRenderGuardTests` pattern over Notes' in-app `PDFThumbnailer` — so a blank thumbnail can't pass.
  - **Phase C — safety-net tooling (MED):** add `archivecore` smoke step; Processor write-surface lint; extend the
    lint to ArchiveCore (uncaught `import AppKit` in Core) + run on Notes; scope Notes smoke to `-only-testing`;
    (opt) fix the documented tag-projector concurrent lost-update race. **Tier-2**.
  - **Phase D — secondary UI/polish (LOW–MED):** folder drag-reparent, richer row context menu, template-body
    editing, quality quick-edit, `roundup` UI-or-remove, raw-parse-failure banner, empty states, off-main
    large-paste parse + minor coverage/cosmetic. Tier-1.
  - **Phase E — verification review:** re-run the plan-vs-build gap analysis + drive the features at runtime to
    prove every A–D item is actually done + **wired** (not "built but dead" again) before flipping this checkbox.
    Use headless render guards (`RenderProbe`/`DocumentRenderGuardTests`) for pixel truth (thumbnail / PDF pane
    actually drew) and the live sighted loop (`ops/gui/`) for chip / empty-state / raw-parse-banner rendering.
- [ ] **(later)** behavior/data follow-ons (W0 already unified the *code*): **unified suite storage path** — Tier-2, separately gated.
  - ~~Reader parses/**hides** `ArchiveSuite` in-UI; corpus **back-fill** + Processor **stamping**~~ — **DROPPED
    (owner 2026-07-16).** The whole `ArchiveSuite` marker/exclusion feature is reversed: Notes stops stamping it
    (see the "R13d REVERSED" item above) and nothing will consume it, so there is nothing to hide, back-fill, or
    stamp. This also removes the only reason for a corpus-wide tag back-fill — the Suite's single
    highest-risk operation. Do not re-propose it.

## ✅ Document-viewer bugs (owner-reported 2026-07-06) — RESOLVED & owner-verified
All fixed and confirmed by the owner (round-3 commit `d4eedba`): open-maximized + remember-size with no
flash; text selection after cycling (fresh `PDFView` per page); zoom persistence across cycling *and* as
default incl. trackpad-pinch (`PDFViewScaleChanged` capture); top-anchored zoom; splitter persistence.
Files: `DocumentWindowView`/`DocumentViewerModel`/`PDFPaneView`/`AppSettings`/`ArchiveReaderApp`.

## P0 — Finish the Suite publish (network back)
- [x] Push merged history: `main` + `suite-v1.0.0` pushed to `origin` (0 diverged). ✅ 2026-07-06
- [x] Publish release: `suite-v1.0.0` LIVE with `ArchiveSuite-1.0.0.dmg` (4.48 MB) attached. ✅
- [x] Verify online: release published, asset `uploaded`; `origin/main` == locally build-verified tree. ✅
- [x] **Phase F DONE** — redirect banner pushed to the old `archiveprocessor` README; repo **archived** (read-only, `isArchived=true`). ✅ 2026-07-06

## P1 — Quick local wins (S, low-risk, no network)
- [x] Cite `SPEC/tag-format.md` as the shared-contract source of truth from BOTH per-app `CLAUDE.md`. ✅
- [x] Reconcile Reader `CLAUDE.md` prose to SPEC (doc-only; code already correct): page-2 line verbatim/any-ext/may-be-absent; Year 3–4 digits; BC note clarified; Box/Folder/OCR-Failed subjects noted. ✅
- [x] Regression test: `Box`/`Folder`/`OCR Failed` classify as plain subjects (SPEC #3) — added; **110 tests green**. ✅
- [x] Close stale checkbox: near-term-UI item **E3** confirmed shipped & ticked. ✅
- [x] Processor: "Import tag vocabulary from CSV" — added `Import from CSV…` button + file drop target on the vocabulary editor (`SettingsView.swift`; NSOpenPanel + newline/comma parse, de-dupe). macOS build green, no new warnings. ✅
- [x] **Android `targetSdk` 34→36 — DONE 2026-07-08** (builds clean + Android-16 emulator smoke PASSED). Toolchain: installed `platforms;android-36` + `build-tools;36.0.0`; AGP 8.6.1→8.9.1; Gradle 8.9→8.11.1; `compileSdk`/`targetSdk` 34→36; `:app:assembleDebug` **BUILD SUCCESSFUL** (JDK 21). **On-device smoke on the `ap_test36` (API-36 / Android 16) emulator PASSED:** app launches, both connect screens render with correct system-bar insets (no edge-to-edge clipping — screenshots checked), full capture flow drove (pair → 2× shutter → End segment → Skip → Box marker), **camera opened** (CameraService connect), and the phone→Mac protocol ran against a stub (`/ping`, 20× `/phone/status` heartbeat, 3× `/photo`, `/segment/complete`) — **no crash, no foreground-service/permission FATAL, 0 FATAL EXCEPTION**. *(Nice-to-have before Play submission: a final pass on a physical Android 15/16 device — emulator ≈ device but not identical.)* | files: ArchiveCapture/ | done
- [x] Reconcile Bonjour service-name mismatch — iOS now advertises `_archivecap._tcp` (matches the Mac) in both `ArchiveCaptureiOS/project.yml` + generated `Info.plist`; iOS project regenerates clean. ✅

## P2 — Reader features (no network; local build/test)
- [x] Non-standard-PDF **detection layer** — `Core/PDFFormatStatus.swift` (standard/unreadable/noTextLayer; page count is NOT a defect signal — merged >2-page PDFs are legit); persisted in the v2 content index. **117 tests green, lint clean.** ✅
- [x] Surface it — filter-bar "N need attention" toggle (`needsAttentionOnly` filter), health-popover row, per-row ⚠ badge. ✅
- [x] Viewer banner for image-only docs ("no OCR text layer") in the document window — build green. ✅
- [x] Tag near-duplicate detection — `Core/TagSimilarity.swift` (union-find + length-scaled Levenshtein) + `SimilarTagsSheet` review UI (Merge drives the existing audited rename). 130 tests green, lint clean. ✅
- [x] Duplicate-filename disambiguation — `Core/DuplicateNames.swift` + a dimmed containing-folder subtitle for rows sharing a base name. 135 tests green, lint clean. ✅
- ~~Side-by-side compare of two selected documents~~ — **dropped (owner: not doing this), 2026-07-06.**

**→ Reader P2 is COMPLETE** (non-standard-PDF cluster · tag near-duplicate finder · document-viewer bugs · dup-filename; side-by-side dropped).

## P2 — Reader performance
- [x] **Parallelize + batch the content-index build** *(Part A — build speed)* — bounded parallel
  `withTaskGroup` extraction + `upsertBatch` + WAL/`synchronous=NORMAL` + `existingMTimes()` +
  `performMaintenance`. 185 tests green. Tier-2 APPROVE. | done
- [x] **Ranked (bm25) search + search-during-index refresh** *(Parts B+C)* — bm25 relevance-ranked
  search (SQL `ORDER BY bm25`, column weights name=10/class=5/body=1, ordered `[String]` return,
  `ftsRank` map, `.relevance` auto-sort, lifecycle + persistence coercion) + auto-refresh active FTS
  query on index pass completion. 186 tests green. Tier-2 APPROVE. | done
- [x] **Prune the content index** — gated cache eviction: `!isGathering && !files.isEmpty` +
  two-emission absence confirmation + component-boundary root scope + batched deletes. Its own pass
  (`pruneIfSettled`), not folded into `startIndexing`. Root-switch resets pending-prune state.
  Corpus-wide counts now correct at source (the `among:`-scoped workaround stays as defense-in-depth).
  191 tests green (5 new). Tier-2 APPROVE (7/7 vectors). | done

## Owner-requested batch (2026-07-09) — Processor output + Reader UX/viewer
Captured verbatim from the owner; file hints are from the Reader/Processor Implementation Maps (verify
at implementation). Not yet scoped into execution plans — the **decades** item likely warrants one
(cross-app + SPEC). Legend as above (S/M/L · risk · needs).

### Archive Processor
- [x] **Multi-column OCR output layout** — `textColumns` setting (1/2/3, default 1) in Settings +
  ProcessingProfiles; body text on page 2 flows into N CoreText columns (header stays single-column,
  full-width). Threaded through OCRProcessor, SessionProcessingConfig, LiveCaptureProcessor (Codable-safe
  with `decodeIfPresent` fallback). Build clean 0 new warnings. Tier-2 APPROVE (7/7 vectors). 7 synthetic
  tests green. GUI-verify deferred: verify on a real multi-column newspaper scan → Morning Review. | done
- [x] **Multi-page PDF → per-page LLM OCR → single alternating image/OCR-text PDF** _(owner-requested 2026-07-15; SHIPPED — new "Re-OCR multi-page PDF" Process-Files mode)_
  — a NEW Process-Files mode: accept an existing **multi-page PDF**, render EACH page to an image, send each
  page-image to the LLM for OCR (re-OCR the page images — distinct from the existing `preOCRedInput` mode, which
  only extracts the embedded text layer), and output ONE PDF whose pages **alternate image, OCR-text, image,
  OCR-text, …** (each source page → its image page + a selectable OCR-text page). **Mostly assembles from
  existing primitives:** `PDFGenerator.mergeDocumentPDFs` already interleaves image1,text1,image2,text2,…;
  `OCRProcessor.performOCRCall` is already per-single-image; `PDFGenerator.generate` builds the per-page
  image+text unit. **New bits:** a "render ALL pages" variant of `PDFToImageConverter` (today hard-codes
  `page(at: 0)`); a pipeline branch in `OCRProcessor.startProcessing` / `convertPDFInputs` that fans one input
  PDF into N page-jobs then reuses generate+merge; a mode toggle beside `preOCRedInput` (+ a `DefaultsKeys` entry)
  in `OCRView.swift`. **Tier-2** (PDF-writing output — adversarial review + scratch-copy functional test, NEVER
  the real corpus). SPEC: add a short note to `SPEC/tag-format.md` §2-page structure (the interleaved shape
  already matches multi-page-document output + is covered by the "consumers must not hard-assume 2 pages" clause,
  so it's a coordinated Processor+Reader+SPEC clarification, not a format break). |
  files (verify at impl): OCR/PDFToImageConverter.swift, OCR/PDFGenerator.swift (generate + mergeDocumentPDFs),
  OCR/OCRProcessor+OCR.swift (performOCRCall, convertPDFInputs), OCR/OCRProcessor+Pipeline.swift (startProcessing),
  Views/OCRView.swift (intake + mode toggle), SPEC/tag-format.md | M | med | none
  — **DONE:** `DefaultsKeys.reOCRMultiPagePDF` + `ProcessingProfileStore`; `PDFToImageConverter.renderAllPages`
  (fail-loud, no partial set); `OCRProcessor.performMultiPagePDFReOCR` (render all pages → per-page OCR via
  `performOCRCall` → `PDFGenerator.generate` per page → `mergeDocumentPDFs` into ONE alternating image/OCR-text
  PDF), branched in `startProcessing` BEFORE `preOCRedInput`; a pure transform (no Finder tags — output never
  overwrites the input via `uniqueOutputURL`). Settings toggle (mutually exclusive with pre-OCRed; disables
  batch + separate-image export), Process-Files "Drop PDFs here" intake + PDF accept-gate + grayed Tagging box.
  SPEC §2-page-structure interleaved-variant note added. **Tier-2:** adversarial self-review + `$0`/key-free
  functional test `scripts/test-multipage-reocr.sh` (`MultiPageReOCRTestDriver`, 11/11 PASS incl. the
  input-overwrite guard); merge-safety regression still green; build clean, 0 new warnings. GUI visual check
  (toggle render / drop-zone flip) deferred → Morning Review (launch-time Keychain prompt blocks it unattended).
- [ ] **De-dup sweep from the 2026-07-04 maintainability audit — REMAINDER ONLY** _(promoted 2026-07-15;
  re-scoped 2026-07-16 after finding suite-v1.2.0 already did most of it)_. **`f1d2263` (suite-v1.2.0) ALREADY
  SHIPPED 5 of the listed consolidations — do NOT redo:** `highestLeadingNumber` (→ `Capture/CollectionNumbering.swift`),
  `monthTag`/`englishMonthNames` (→ `GeneratedTags`), `acceptedImageExtensions` (→ `ImageEncoding`),
  `GatewayConfig.fromDefaults()`, `liveProcessingMode` **enum**. **GENUINE REMAINDER (~6, verified still duplicated
  in-tree 2026-07-16):** a shared transient-status friendly-message helper (4 OCR clients); a segment-JSON schema
  builder (2 sites); `OCRResult.with(...)` copy helpers; `LLMRotationDetector.rotate` → `ImageEncoding.rotate`
  (`LLMRotationDetector.swift:150` still a private copy — its own comment says "mirrors ImageEncoding.rotate");
  `ThinkingLevel.budgetTokens` + the Anthropic max_tokens bump (4 clients — `thinkingBudget` is 1024/4000,
  512/2000, and two `budget` vars, i.e. budgets differ **by call type**, so KEEP that difference — this one is
  request-body-affecting if mis-merged); Gemini `cancelBatch` via the shared URL builder.
  ⚠️ **VERIFICATION CONSTRAINT:** the Processor has **no unit-test target** and its only functional test needs an
  OCR API key (deleted W4.0.a) — so "prove equivalence" here = build-green + byte-identical diff inspection; the
  `budgetTokens` sub-item (request-body-affecting) should be done in a keyed/owner session, not guessed unattended.
  **Tier-1** (touches no write path). | files: OCR/*, Capture/LiveCaptureProcessor.swift, Views/* | M | low | none
  — **W12-dedup progress 2026-07-16 — 5 of 6 shipped** (byte-identical, build-clean, no new warnings):
  (1) `LLMRotationDetector.rotate` → shared `ImageEncoding.rotate` `af8cf66`; (2) shared
  `OCRErrorMessages.transientStatusMessage(_:)` across all 4 clients' `parseErrorResponse` + (3) Gemini
  `cancelBatch` via `makeBatchURL` `6c52dd4`; (4) `OCRResult.with(classification:rotationDegrees:)` copy helper —
  7 review/retry re-creations, preserves errorCode (the W9.1 footgun) `94d4ef6`; (5) **segment-JSON sidecar
  builder** — Tier-2 (file-WRITE format): new pure `OCR/SegmentJSONBuilder.swift` (`cf4f509`) that both
  `OCRProcessor.writeSegmentJSON` + `LiveCaptureProcessor.writeSegmentJSON` now delegate to — disk-write surface
  (sidecar-URL + atomic write) left unchanged; the OCRProcessor-only `box_label`/`folder_label` divergence is a
  `formatOverride:` param via `SegmentJSONBuilder.labelFormatOverride`. Proven byte-identical to BOTH originals
  by a $0 key-free 12-case / 30-assert driver (`SEGMENT_JSON_TEST=1` + `scripts/test-segment-json.sh`,
  `6d9a877`; call sites wired in the flip commit) — ALL PASS. **⏸️ 1 REMAINING is OWNER/KEYED — Wave-12 SKIP
  (do NOT attempt unattended):** (6) **`ThinkingLevel.budgetTokens`** — request-body-affecting (512/2000 vs
  1024/4000 differ by call type) → keyed/owner session per the VERIFICATION CONSTRAINT above (Processor has no
  unit target + its only functional test needs the deleted OCR key). See Morning Review.
- [x] **Shared provider text-completion client** — **ALREADY SHIPPED `f1d2263` (suite-v1.2.0), before the
  2026-07-15 promotion re-listed it.** `OCR/LLMTextClient.swift` is the shared text-completion client;
  `TagGenerator` + `CollectionSegmenter` both delegate to it, each keeping its own `maxTokens`/timeout so request
  bodies stay byte-identical (the Mistral-signature drift was reconciled deliberately, not blind-merged).
  Verified in-tree 2026-07-16 (file present; both callers reference it). Promoted-in-error 2026-07-15 (`1ee659c`) —
  the POTENTIAL_FEATURES source entry was stale.
  | files: Tagging/TagGenerator.swift, Tagging/CollectionSegmenter.swift, OCR/LLMTextClient.swift | done
- [x] **Live Capture output-folder picker** — **ALREADY SHIPPED `782dfdd` (suite-v1.2.0), before the 2026-07-15
  promotion re-listed it.** LiveCaptureView has the picker (`chooseOutputFolder()` + NSOpenPanel), a "Choose…"
  button, the current-destination "Output folder" row, a `?` HelpButton, and gray-out in Stage-for-later mode —
  unified on the SAME `DefaultsKeys.outputDirectory` as Process Files (one source of truth). Verified in-tree
  2026-07-16. Promoted-in-error 2026-07-15 (`1ee659c`). **Residual (owner):** the owner's promoted wish said the
  default should be "not Downloads"; the shipped default is Downloads-if-unset (visible + changeable via the
  picker). Whether to change the default (and to what — last-used vs a dedicated folder) is an owner call →
  Morning Review. | files: Views/LiveCaptureView.swift | done
- [x] **Cost tracking + processing history** _(promoted 2026-07-15; SHIPPED 2026-07-16)_ — persist each run's **actual**
  cost plus a run log (timestamp, provider/model, file count, results/failures) and surface a simple history view.
  `CostEstimator` already does the per-model math for *estimates*; this records **actuals** and accumulates them.
  Writes only its own store (Application Support / UserDefaults) — **never** the corpus. **Tier-1**.
  | files: Models/CostEstimator.swift, Models/DefaultsKeys.swift, Views/ToolsView.swift (or a new history view) | M | low | none
  — **SHIPPED:** `Models/ProcessingHistory.swift` — `ProcessingRun` + in-memory `RunHistorySnapshot` (params captured at
  run start; cost = the SAME `CostEstimator` math the pre-run pane shows, applied to what ACTUALLY ran — no provider
  returns per-call token usage) + bounded (200) `ProcessingHistoryStore` (JSON in UserDefaults, never the corpus).
  `OCRProcessor` records at EVERY genuine completion tail (startProcessing + resumeRun pre-OCRed/standard + resumeBatch;
  resume snapshots rebuilt from the persisted manifest + live rotation/scale); cancel/interrupt paths never record.
  `Views/ProcessingHistoryView.swift` — a Tools-tab sheet (per-run provider·model/mode/counts/cost, summary totals,
  confirm-gated Clear; cost footnoted as an estimate, not billed). **Tier-1** verified: build clean, 0 new warnings +
  `$0`/no-key/no-GUI headless self-test `scripts/test-processing-history.sh` (`ProcessingHistoryTestDriver`, 19/19 PASS,
  against a THROWAWAY UserDefaults suite — never the operator's real history). Visual GUI check deferred (launch-time
  Keychain prompt blocks the Processor GUI unattended) → Morning Review.
- [x] **Global keyboard shortcuts + dark-mode pass** _(promoted 2026-07-15; re-scoped 2026-07-16; VERIFIED 2026-07-16)_ —
  Tier-1 audit; **no code change needed** (both sub-items already correct in-tree — churning clean code would be worse).
  **(a) Shortcut coverage — complete & correct:** `Views/ProcessingCommands.swift` exposes the two main-window
  commands (⌘R Start Processing, ⌘⌥P Cycle Provider) as a menu-bar `CommandMenu` = the single source (key
  equivalents shown; routes via `NotificationCenter` → MainActor observers with a `TextEditingGuard` so a shortcut
  never steals a keystroke). Every OTHER `.keyboardShortcut` in the app is a `.defaultAction`/`.cancelAction`/⌘Return
  **scoped to a modal sheet** (correctly NOT global menu commands) — matches the Reader's "menu bar = single source"
  convention. **(b) Dark-mode — static audit clean:** all chrome uses adaptive `Color(nsColor: .controlBackgroundColor
  / .windowBackgroundColor / .textBackgroundColor)`; text uses `.primary`/`.secondary`/`.tertiary` + adaptive accents;
  `white`/`black` literals appear ONLY for document/paper rendering (thumbnail/PDF-output/OCR-test canvases — must
  stay), modal scrims (`black.opacity(…)` — intentional dimming), and glyphs/text on dark scrims or saturated colored
  badges; the one AppKit token field sets `drawsBackground = false` (the adaptive pattern). No custom `Color` palette/
  extension, no named-image chrome (`Image(systemName:)` only), no forced `.preferredColorScheme` / `NSApp.appearance`
  / `window.backgroundColor` override. **Human visual dark-mode spot-check deferred → Morning Review** (the Processor
  GUI can't launch unattended — blocking login-Keychain prompt; no Processor XCUITest harness). | files (audited):
  Views/* (all), Views/ProcessingCommands.swift | S | low | none | done
- [x] **Incremental processing (skip already-processed files)** _(promoted 2026-07-15; SHIPPED 2026-07-16)_ —
  re-running a directory now processes only new/changed files instead of redoing everything (matters at 150k scale).
  Skip key = the owner-specified one: an existing `<output>/<base>.pdf` whose mtime is no older than the source.
  **Fail safe: when in doubt, PROCESS** — never silently skip a file that needed processing. **Tier-2** (a wrong
  skip = silently missing output). | files: OCR/OCRProcessor+Pipeline.swift, Views/OCRView.swift | M | med | none
  — **DONE:** new pure `OCR/IncrementalSkip.swift` (`partition(inputs:outputDirectory:)`) is the safety-critical
  decision core; skips a source ONLY when its base name is unique among inputs, the candidate `<out>/<base>.pdf`
  is a distinct file (not the source itself), exists as a regular file, both mtimes are readable, and source
  mtime ≤ output mtime — every ambiguity falls through to PROCESS. Opt-in toggle `DefaultsKeys.skipAlreadyProcessed`
  (default OFF, Settings ▸ Input & Processing; also a `ProcessingProfile` key). Filtered at the top of
  `startProcessing` and confined to plain per-file output (skipped for Live Capture pre-grouped handoffs,
  collection-organized, and merged runs, where an output can't be attributed to one source — a safe no-op there);
  the skipped count is surfaced in the completion status, and an all-skipped run finishes with a clear
  "nothing to do". **Tier-2 verified** (no-key Processor): headless `$0` `scripts/test-incremental-skip.sh`
  (`IncrementalSkipTestDriver`, INCREMENTAL_SKIP_TEST=1) — **13/13 PASS** across every fail-safe branch,
  mktemp-isolated (never the corpus) — plus adversarial diff review + build clean, 0 new warnings. GUI visual
  check (toggle + status line) deferred → Morning Review (Processor GUI launch = blocking login-Keychain prompt).

### Capture companions (Android + iOS) — owner decisions 2026-07-15
- [x] **Remove the phone "Finish" button** _(owner decision 2026-07-15 — "get rid of it"; premise found STALE —
  already done, reconciled 2026-07-16 `W12-finish-button`)_ — the phone's **Finish**
  (`CaptureViewModel.finishSession()` → `MacClient.sessionComplete()` → `POST /session/complete`) is near-useless
  and actively misleading: the Mac handler (`CaptureServer.swift` ~L242) only sets a status string and returns OK —
  it does **not** start finalize, so the operator must still click **Finish session** on the Mac. **End segment**
  stays the phone's only "done" action; the Mac's Finish session stays the finalize trigger. Remove the button +
  its call from **both** companions (keep them in sync). **Leave the Mac's `/session/complete` route in place** (a
  harmless no-op) so an older/unupdated companion still works — do NOT change the protocol in the same pass.
  | files: ArchiveCapture/ui/CaptureScreen.kt + capture/CaptureViewModel.kt,
  ArchiveCaptureiOS/UI/CaptureScreen.swift + Capture/CaptureViewModel.swift | S | low | none
  — **ALREADY DONE (stale premise, like recent-years/de-dup).** The phone **Finish button + its `finishSession()`→
  `sessionComplete()` UI call are already gone from BOTH companions** — removed in `ce55511` ("Live capture: End
  segment is the only 'done' action"). Verified in-tree 2026-07-16: neither `CaptureScreen.swift` nor
  `CaptureScreen.kt` has a Finish button (both only expose **End segment** = `finishDocumentSegment()` →
  `segmentComplete(...)`, the segment signal — NOT `sessionComplete`); a full-tree grep finds **zero callers of
  `sessionComplete()`** in either companion's UI/Capture/Net; both UIs even carry a "there is no separate Finish"
  comment. The Mac's `POST /session/complete` route is intact (`CaptureServer.swift:284`), as the item requires.
  So the actionable scope (remove the button + its UI call, keep the Mac route) is fully satisfied — no code change.
  **Residual (OUT OF SCOPE this pass → Morning Review):** `sessionComplete()` survives as **dead protocol surface**
  in the Net/ transport layer (the `SegmentTransport` protocol + `MacClient`/`DriveRelayTransport`/`FileRelayTransport`
  impls, both companions). Removing it would touch the **frozen** `RelayObjectFormat` wire contract
  (`encodeSessionComplete` + the `sessionCompleteMatchesGolden` test) and the maintain-only cloud path, i.e. it
  **"changes the protocol"** — which the item explicitly forbids "in the same pass." Left as an optional future
  protocol-cleanup pass (owner-gated). Doc-only reconciliation (Tier-1, no build needed — tree == `a624ccf`).
- [x] **Cap recent years at 5 (both companions)** _(owner decision 2026-07-15; SHIPPED 2026-07-16)_ — both
  companions now cap the recent-years quick-chip list at **5** (was 6): iOS `Array(ys.prefix(5))`
  (`CaptureViewModel.noteYear`) + comment; Android `.take(5)` (`Prefs.noteYear`) + `max 5` doc comment. Kept in
  sync. Migration-safe (a previously-stored 6th year is truncated on the next `noteYear`; it is only a UI
  convenience list — no tag/corpus write, so Tier-1). **Verified:** iOS `xcodebuild` **BUILD SUCCEEDED** + Android
  `./gradlew :app:assembleDebug` **BUILD SUCCESSFUL**, no new warnings; no unit test asserts the cap. Visual
  chip-count check (needs seeding ≥6 recent years then opening the tag sheet on device/emulator — an
  E2E-harness-level drive, disproportionate for a one-line display cap) → Morning Review.
  | files: ArchiveCaptureiOS/.../Capture/CaptureViewModel.swift (recentYears), ArchiveCapture/.../data/Prefs.kt (recentYears) | S | low | none

### Archive Reader — layout & panels
- [x] **Adjustable + collapsible side panels** — `PanelDivider` (drag-to-resize, 140–350 / 160–400
  clamped, `@AppStorage`-persisted widths); sidebar + tag cloud toggle via toolbar buttons + View menu
  shortcuts ⌥⌘S / ⌥⌘T; animated expand/collapse. 191 tests green, 0 warnings. | done
- [x] **Add/remove columns in the file list** — right-click the column header → checkmark menu to
  show/hide any column (except File name); visibility persisted via UserDefaults. `ColumnPickerHeaderView`
  subclass + `AppSettings.hiddenColumns`. |
  files: Views/AppKitTableView.swift, Core/AppSettings.swift | done
- [x] **Make tags editable in the file list _again_** — `TagTokenCellView` (NSTokenField in NSTableCellView)
  replaces the plain-text tags cell; edit-start base snapshot + freeze-during-edit + WYSIWYG commit on blur,
  all routing through `commitSubjectEdit` → `TagWriter`. Tier-2 APPROVE (6/6 vectors). 191 tests green,
  0 warnings. GUI write-verify deferred (screen locked). | done

### Archive Reader — tag cloud & filters
- [x] **No dates in the tag cloud** — exclude Year/Month/Day **and decade** facets; show subjects only
  (facet classification already exists in `DocumentTags`). | files: Views/NavigationWindowView.swift
  (tag-cloud panel), Core/DocumentTags.swift | S | low | done
- [x] **Remove date tags from the tag filter search** — months/years/decades must not appear as
  suggestions/targets in the tag filter field. | files: Views/TagFilterField.swift, Core/DocumentTags.swift | S | low | done
- [x] **Logarithmic tag-cloud sizing** — size by `log(count)` (or similar) so a 1000-count outlier doesn't
  crush the 2/10/20/100/1000 gradient into uniformly tiny text. | files: Views/NavigationWindowView.swift | S | low | done
- [x] **Wrap (not clip) file tags in the list** — `usesAutomaticRowHeights` + multi-line `NSTokenField`
  (`wraps = true`, top/bottom constraints). Build clean, 191 tests green. GUI-verify deferred (screen
  locked). | files: Views/AppKitTableView.swift | S | low | done

### Archive Reader — dates & decades (CROSS-APP + shared SPEC)
- [x] **Decade tags ("1970s", "1980s")** _(plan: `execution-plans/decades-date-facet.md`)_ — SHIPPED.
  SPEC + Reader parse/sort/display/topicalTags + write-path safety (year supersedes decade) +
  Processor Year-field help text. 12 new unit tests (182 total green). Tier-2 APPROVE. Defaults
  applied for the 4 open questions (italic=yes, no Reader decade editor, no hard validator, cloud/filter
  exclusion structural). Plan deleted. | done

### Archive Reader — search
- [x] **Incremental (as-you-type) OCR search** — debounced 150ms Combine pipeline on `$fullTextQuery`
  triggers `runFullTextSearch()` as-you-type; FTS5 MATCH + bm25 is indexed and fast at scale; existing
  `ftsGeneration` token handles superseded queries. `.onSubmit` removed (debounce handles it); clear
  button still calls explicitly for instant feedback. 191 tests green, 0 new warnings.
  | files: Views/NavigationWindowView.swift, Views/NavigationModel.swift | done
- [x] **In-viewer find, scoped to the open PDF(s)** _(owner-requested 2026-07-14)_ — ⌘F find bar over the
  open PDF(s): highlights ALL matches (yellow), next/prev navigation (⌘G / ⇧⌘G, wrapping) with a global
  "N of M" count, and searches ACROSS every open document (both panes = page 0 + page 1) — not the corpus
  FTS. New `Core/DocumentFind.swift`: pure `FindNavigator` (reading-order match list + wrap cursor) +
  `DocumentFindScanner` (per-pane match counts via `PDFDocument.findString`). `PDFPaneController` grows
  find-highlight state reapplied on every view rebuild (mirrors the persisted-zoom pattern), so highlights
  survive page cycling; cross-document jumps set the pane target then change `index` so the rebuild applies
  it with no timing race. 10 new unit tests (`DocumentFindTests`, incl. a synthesized text-PDF scanner
  check); build clean 0 new warnings. Read-only → Tier-1. Live GUI drive (highlight render / scroll /
  next-prev / cross-doc jump) → Morning Review (GUI off). | files: Core/DocumentFind.swift,
  Views/DocumentViewerModel.swift, Views/PDFPaneView.swift, Views/DocumentWindowView.swift,
  ArchiveReaderCommands.swift | M | low | done
- [x] **Full-text search snippet previews (keyword-in-context)** _(promoted from POTENTIAL_FEATURES 2026-07-15;
  SHIPPED 2026-07-16 — `80725d3` core, `d797ea8` UI)_ —
  show a `snippet()`-style **keyword-in-context** excerpt for each search hit (the matched OCR text with the query
  term highlighted) so results are scannable without opening each doc. FTS5 has `snippet()` **built in** and the
  content index **already stores the OCR `body`**, so this is a **search-UI addition, not an indexing change** —
  it layers on the shipped bm25 relevance ranking (and is distinct from the in-viewer find above: this is the
  corpus/library search). Read-only, no writes → **Tier-1**. Was deferred out of the `index-parallelization` plan
  (owner, 2026-07-09), which shipped ranking but explicitly not previews. | files (verify at impl):
  Search/ContentIndex.swift, Views/NavigationModel.swift, Views/NavigationWindowView.swift | M | low | none
  — **DONE:** `ContentIndex.searchRanked(query,snippetLimit)` returns every bm25-ordered match path (unchanged
  filtering surface) **plus** bounded FTS5 `snippet()` KWIC previews for the top hits — `snippet()` reads each
  doc body, so a `path IN (…)` filter caps the work at the top N rather than every match at 150k scale (an
  `ORDER BY bm25 … LIMIT` would still evaluate `snippet()` for every scanned row). New pure `Search/SearchSnippet.swift`
  (STX/ETX marker vocabulary shared by the SQL builder + the UI; robust segment parser). `NavigationModel` stores
  per-path snippets (`ftsSnippets`, cleared at every reset site) + `searchSnippet(for:)`; the AppKit list name cell
  grows to a dimmed 2nd keyword-in-context line for a hit (matched terms bold + faint adaptive-yellow wash) via the
  existing `usesAutomaticRowHeights`. **Tier-1** verified: 15 new unit tests (`SearchSnippetTests` + `ContentIndexTests`)
  green; build clean, no new warnings; **GUI-verified** by a new fixture XCUITest (`testOCRSearchShowsKeywordInContextSnippet`,
  **TEST SUCCEEDED**) that OCR-searches a body-only term ("California", in 9/11 fixture bodies, in no filename) and
  asserts the snippet line renders end-to-end. (Pre-existing env-only unit failure `DeepLinkTests.testRevealAndSelectNoRoot`
  — owner's real `archiveRootBookmark` in the shared unit-target UserDefaults — is unrelated → Morning Review.)

### Archive Reader — sort & smart folders
- [x] **Drop the top-bar Sort button; sort via column headers** — removed the toolbar Sort menu; primary
  sort via native column-header click (already wired via `sortDescriptorPrototype`); right-click header →
  secondary sort (asc/desc) + remove-secondary + reset-to-default via `ColumnPickerHeaderView`. Dead
  SwiftUI-Table sort code removed (`ArchiveFileComparator`, `sortComparators`, `applyTableSort`). 191 tests
  green, 0 warnings. | done
- [x] **Smart folders behave like a scoped root** — selecting a saved search enters a base scope; user
  filters layer on top; Clear returns to the base set, not the whole root. Sidebar shows a durable
  highlight. Scope persists across relaunch. `LibraryFilter.effective` merge for Save/summary. 170 tests
  green. Tier-2 APPROVE. | done

### Archive Reader — viewer & preview
- [x] **Single-page PDF with an embedded text layer → show its text as plain text (right pane)** — in both
  the document viewer and the navigator Preview, when a PDF has selectable text but no OCR page-2, extract
  the text layer via `embeddedText` and render it as selectable plain text in the right pane. Build clean,
  191 tests green. GUI-verify deferred (screen locked). | done
- [x] **Preview gets its own default zoom** — independent of the document viewer's persisted zoom; default
  to **full page** until the user changes it; on open, **focus the image pane** so keyboard zoom works
  immediately. `PDFPaneController(persists: false)` in preview mode; focus via async dispatch on appear.
  Build clean, 191 tests green. GUI-verify deferred (screen locked). | done
- [x] **⌘0 = "fit full page" everywhere zoom applies** — `.focusedObject(model)` on PreviewSheet
  publishes the viewer model so the existing Document menu ⌘0 (Fit Page) + zoom shortcuts reach the
  preview. Build clean, 191 tests green. GUI-verify: Document menu confirmed; preview-specific test
  deferred (scratch corpus not Spotlight-indexed). | done
- [x] **View non-PDFs (e.g. JPG) in the viewer** — tagged non-PDF images (JPG/PNG/TIFF/HEIC/BMP/GIF)
  now open in viewer + preview via PDFPage(image:) wrapping in DocumentViewerModel.loadCurrent().
  Build clean, 191 tests green. GUI-verify deferred (scratch corpus not Spotlight-indexed). | done

## Owner-requested (2026-07-10) — Reader
- [x] **Exclude a subfolder (inside the root) from indexing _and_ display** — a Settings control to
  name one or more folders under the current root that the Reader should treat as out of scope: their
  files are neither shown in the library nor added to the content index. UI lives in the Reader's
  **Settings** scene (`ArchiveReaderApp.swift:30` — add an "Excluded folders" section / list; a folder
  picker scoped under root that appends rows, each removable). Persist the exclusions (path prefixes,
  and/or security-scoped bookmarks like `RootFolderStore`) via `AppSettings`/a small store. **Apply at
  BOTH gates so "not indexed" and "not shown" actually hold:** (1) _display_ — filter files whose path is
  under an excluded prefix in `NavigationModel.libraryDidChange`/`recompute` (discovery is Spotlight-wide
  by tag in `ArchiveLibrary`, so match on path prefix, not search scope); (2) _index_ — skip excluded
  paths in `ContentIndexer.startIndexing`, **and prune already-indexed rows** under a newly-excluded
  folder (reuse the gated-prune path so search stops matching them; growth stays bounded). Reversible:
  un-excluding re-includes + re-indexes on the next library change. Edge cases: exclusion must be a
  descendant of root; overlapping/nested exclusions dedupe to the outermost; an excluded folder that
  later disappears is a no-op. Mostly build+unit verifiable (path-prefix filter, prune-on-exclude);
  GUI-verify the Settings list + that excluded rows vanish from the list and OCR search. **Not Tier-2**
  (no tag/corpus writes — read/index-side only). | files: `ArchiveReaderApp.swift` (Settings scene),
  new `Search/ExcludedFoldersStore.swift` (or `Core/AppSettings.swift`), `Views/NavigationModel.swift`,
  `Search/ContentIndexer.swift`, `Search/ArchiveLibrary.swift` | M | low

## Deferred from the 2026-07-09/10 autonomous run → queued for next autonomous run
Correctness bugs from that run's review shipped (`848c9d2`, `f866a0f`, `14118c0`); the items below were
consciously deferred (perf-only / LOW / GUI infra / new idea). All armed in `.maintenance/AUTONOMOUS_PLAN.md`
as **Waves 7–10** for the next daemon run (relaunch the daemon to start it — `ops/autonomous/README.md`).
- [x] **Prefix-match as-you-type OCR search** _(W10.1)_ — `ftsMatchExpression` appends `*` to the last token
  (>2 chars) for FTS5 prefix queries ("news" → "newspaper"). Min-length gate skips wildcard for ≤2-char tokens.
  3 new tests (196 total green), 0 warnings.
- [x] **Reader perf (deferred W6.2/W6.5)** _(W8.1)_ — (a) `displayedByID` rebuild gated by `displayedGeneration` counter (skips O(N) dict rebuild on unrelated `updateNSView` calls); (b) `tagCloud` cached + invalidated in `recompute()`. 193 tests green, 0 warnings.
- [x] **Processor OCR throughput (deferred W6.5 — M3–M5). Tier-2** _(W8.2)_ — M3 `handleOCRResult` PDF gen →
  `Task.detached(.utility)`; M4 `processBatchResults` rotation → bounded-concurrent `withTaskGroup`; M5
  Anthropic batch submit → incremental JSON serialization (1-image peak vs all-images). Tier-2 APPROVE
  (18 attack vectors). Build clean 0 warnings. | files: `OCR/OCRProcessor+OCR.swift`, `OCR/BatchOCR.swift` | M | low
- [x] **Processor OCR LOW cleanup (W6.4 L1–L4)** — L1 Gemini `cancelBatch` apiKey → `urlComponentEncoded`; L2
  preserve `errorCode` across 4 OCRResult re-creations; L3 documented `nonisolated(unsafe) static var` concurrency
  contract (write-once-per-run on MainActor, happens-before child tasks); L4 cache previous JPEG in Anthropic +
  Gemini batch loops. Build clean 0 warnings. | files: `OCR/BatchOCR.swift`, `OCR/OCRProcessor+ReviewFlows.swift`,
  `OCR/OCRProcessor.swift` | S | low
- [x] **Reader GUI test harness (XCUITest)** — W7.1–W7.5 shipped (target + accessibilityIdentifiers + fixture-root override + make-gui-fixture.sh + suite). **W7.6 (fixup) — all 14 tests now EXECUTE and PASS** (were 13/14 skipping): fixed the sandbox↔Spotlight fixture load (DEBUG off-Spotlight directory enumeration, since NSMetadataQuery returns nothing for a temporary-exception path), UITest↔owner shared-UserDefaults isolation (no view-state restore/persist in test mode — was inheriting the owner's live filter AND clobbering their settings), the tag-cloud element-type query + row/header click hittability, and marked the UI-test classes `@MainActor` (test-target warnings 171→32). PDFView content panes aren't XCUITest-queryable (framework limit) — asserted via observable chrome instead. | L | med

## P2 — Processor (KI#3 done; rest bucketed by how it can be verified)
**Done:**
- [x] KNOWN_ISSUES #3: zoomed-image scroll monitor no longer swallows scroll app-wide — scoped to the image via a hit-test-transparent probe (`ZoomableImageView.swift`); SwiftUI drag/pinch intact, no OCR/output logic touched. Build clean. ✅  ← GUI-verify (zoom a page >100%, confirm the filmstrip scrolls).

**Heads-down doable now (macOS, build-verifiable, NOT phone-gated):**
- [x] **[A1 — SHIPPED; owner-gated live-verify remains]** **Owner-requested (2026-07-07): bring the Live Capture Processing pane up to the Process Files "Files" pane's level of detail — on shared central code.** Today the Processing pane in Live Capture is too sparse: when a document **fails OCR the user gets no reason**, and there's **no way to (re)process just one or two files**. It should show the same per-file detail as the Process Files "Files" pane (status, OCR text/error reason, per-file actions) and offer the same **granular fallback/retry options** (retry a single file, change model/rotation and re-run, etc.). The pane likely needs to be **larger** to fit this. **DRY — don't invent it twice:** factor the Process Files file-list + row + per-file action UI into a **shared component** so both the Process Files pane and the Live Capture Processing pane render from one central source, rather than two parallel implementations. Mostly build-verifiable; verify the failure/retry paths in a live run. **Tier-2** if it touches the finalize/retry write path. | files: Views/OCRView.swift (+OCRView+*), Views/LiveCaptureView.swift, Capture/LiveCaptureProcessor.swift, new shared row/pane component | L | med
  - **Progress (2026-07-07, A1 design `.maintenance/A1-shared-pane-design.md` steps 1–9):** SHIPPED — shared `Views/Shared/{ProcessableItem,ProcessableItemRow,ProcessableItemListView,ModelChoiceView}.swift`; Files pane adopts it (`FileItem` adapter, identical render); Live pane fully adopts it (`SegmentItem` adapter, reasons + per-item retry / retry-with-model / rotate-&-re-run / view-text / reveal + grown scrollable box); `LiveCaptureProcessor.retryFailed(groupIds:override:)` generalized (G1 = all-failed footer); failure taxonomy un-conflated (`succeededNoText` for filed image-only docs — labeling only, deletion path untouched); `OCRProcessor.retryOne(...)` extracted. Builds clean, no new warnings. **Files pane inline-disclosure action UI shipped** (overnight, commit `d068a99`): tap-to-expand rows surface retry / retry-with-model / rotate-&-re-run / view-text / reclassify via `OCRProcessor.retryOne(...)` + `ModelChoiceSheet` + `FileTextViewerSheet`; review-mode keyboard/tap gestures preserved (expand only outside review mode). `.fileAsImageOnly` not surfaced (auto-files via `succeededNoText`). **REMAINING:** live-run GUI verification of the new reasons/retry paths (owner-gated).
- [x] **shipped `f1d2263`, suite-v1.2.0** — Behavior-preserving de-dups (audit `wf_4373722d-e70`): shared text-completion client; finalize/organize helpers; box/folder color-retag; small cluster (`highestLeadingNumber`, `monthTag`, `acceptedImageExtensions`, `GatewayConfig.fromDefaults`, `liveProcessingMode`); reconcile iOS(5)/Android(6) recent-years cap. | M | low
- [x] **shipped `b1fc5d4`, suite-v1.2.0** — No-API local features: processing profiles/presets + main-window global shortcuts (start / switch provider). | Views/SettingsView.swift, Views/OCRView.swift, new store | M | low
- [x] **shipped `782dfdd`, suite-v1.2.0** — Output-folder picker in the Live Capture pane (+`?` help + gray-out); unify with Process Files `outputDirectory`. **Tier-2** (output path) — add the picker + wire the EXISTING setting; don't change write/move logic. | M | low
- [x] **shipped `d2de49d`, suite-v1.2.0 (owner live-verified pairing).** **Remove the Mac Transport picker — auto-run both receivers.** The phone already chooses its transport at pairing (Wired/Wi-Fi/Cloud), so the Mac-side lan/cloud setting is redundant + a footgun (left on Cloud, Wi-Fi pairing silently dies, and vice-versa — hit live 2026-07-07). Instead: the Mac always runs the LAN `CaptureServer`, and *also* runs the Drive relay watcher automatically whenever it's signed into Google + a session is active (sign-in = the enablement, not a mode). Drop the Transport picker from `SettingsView` (keep the "Sign in to Google Drive" config); emit ONE combined pairing QR (host/port/token + relay token) so any phone-side choice works from a single scan; show dual status (Listening + Watching Drive). Gate the Drive poll to active sessions to save quota. **Tier-2** (Capture/Net/Views) — worktree + adversarial review; verify LAN via the android-ui-test-harness + the cloud path with a paired phone. | Capture/CaptureSession.swift, Views/SettingsView.swift, Views/LiveCaptureView.swift | M | low
- [x] Connectivity UX — **superseded/shipped** by the cloud-transport integration (legible Wi-Fi failure + reachability preflight landed; USB + Drive relay is now the direction). ✅

**Live-session / phone-gated (drive Live Capture — ideally a paired phone — to verify; do interactively, like the viewer bugs):**
- [x] **shipped `338dc1b`, suite-v1.2.0 (B2)** — Keep OCR/progress live while the per-segment tag card is open (looks hung today). | Views/LiveCaptureView.swift | S
- [x] Tag card: when the Spotlight tag index is still building, present UI saying so instead of silently-empty autocomplete. ✅ `SystemTagsProvider.isReady` (false until first gather) → SegmentTagCard shows a spinner + "building tag suggestions…" that clears when the query finishes. | Views/LiveCaptureView.swift (SegmentTagCard), Tagging/SystemTagsProvider.swift
- [x] After rotation review, if finalize/processing is still running, show a throbber so the gap before collection naming doesn't look hung. ✅ LiveCaptureView overlay: "Finishing — processing segments…" shown while `isFinalizing && no sheet` (the regen gap; gated off during the finalize move which has its own spinner). View-only — no Capture/ change needed. | Views/LiveCaptureView.swift
- [x] **shipped `6ea268a`, suite-v1.2.0 (B4)** — Re-pair coordination: auto re-show QR on phone re-pair; split "listening" vs "connected"; verify USBBridge re-runs `adb reverse`. | Net/, Views/LiveCaptureView.swift, companions | M
- [x] **shipped `6ea268a`, suite-v1.2.0 (B5; residual `resolvedGroupIds` resurface tracked as B9 in KNOWN_ISSUES)** — Streaming residuals (mostly shipped in the cloud-transport work — Finish drain-gate + phone queue-depth + "End segment = the only done action" landed): finish/verify any remainder — `needsResend` for P10/reclassify in-flight, `completedDocGroups` persistence across Mac restart. | Capture/LiveCaptureProcessor.swift, companions | M
- [x] **shipped `7aace39` + audit fix, suite-v1.2.0 (see KNOWN_ISSUES ✅ FIXED)** — KNOWN_ISSUES #2: merged multi-page docs leave exported originals loose — thread per-page image URLs into `organizeOutput`. **Tier-2 file-move**; needs a live pipeline run. | OCR/CollectionSegmenter.swift, Capture/LiveCaptureProcessor.swift | M

> **✅ INTEGRATED 2026-07-07.** The standalone clone's `feat/live-capture-cloud-transport` work — a full
> **Drive-relay cloud-transport** system (D1–D8: `DriveClient`/`DriveObjectStore`/`DriveAuth`/
> `DriveRelayTransport` for Mac+iOS+Android, `FileRelay`, phone queue-depth + Finish drain-gate;
> LIVE-validated, already adversarially reviewed) — was ported into the monorepo under `ArchiveProcessor/`
> as **27 commits (history preserved)** via `git am --directory`, merged to `main`, and pushed. Both apps
> build; offline invariant tests pass (RELAY GOLDEN ✅, FileRelay 8/8). The standalone clone was then
> **retired**: its 6.3 GB `Test Files` corpus moved into `ArchiveProcessor/Test Files/` (gitignored), the
> folder deleted, and the stale `com.archivereader.autobuild` launchd relic removed. This **supersedes** the
> "connectivity UX" item above (cloud/USB transport is the new direction). The architecture now lives in
> `ArchiveProcessor/CLAUDE.md` §Function 3; the relay contract in `SPEC/relay-object-format.md`; the
> on-device walkthrough in `ArchiveProcessor/LIVE_CAPTURE_ANDROID_TEST.md`.

- [x] **Owner-gated: live Google Drive end-to-end test — DONE 2026-07-07.** Android phone→Drive→Mac verified end-to-end (sign-in, single photo, multi-page segment + Mac tag card, Box/Folder markers, Finish; photo durable in the Mac session + backup folder). Fixes landed: `DriveError` legibility + `DriveAuth.init` whitespace-trim; console setup (Desktop client for Mac, Android client + SHA-1 + **Custom URI scheme enabled** for the phone) captured in the Processor CLAUDE.md Live Capture section. ✅
- [x] **iOS Drive-relay on-device OAuth — implemented.** `DriveAuth.swift` (`ASWebAuthenticationSession` + PKCE, `drive.file` scope, thread-safe `TokenStore` for `DriveClient`'s blocking token provider); `CaptureViewModel` gains `TransportMode` (.lan/.drive) + auto-selects Drive when QR has a relay token and user is signed in (falls back on LAN-unreachable too); `ConnectScreen` gains a "Sign in to Google Drive" section. `project.yml` registers the reversed-client-ID URL scheme. **Placeholder client ID** — needs a real iOS OAuth client in GCP project YOUR_GCP_PROJECT (bundle ID `com.archiveprocessor.capture.ios`, "Custom URI scheme" enabled). iOS build clean, no new warnings. On-device testing deferred → `ArchiveProcessor/POTENTIAL_FEATURES.md`. | ArchiveCaptureiOS | M

## P3 — Suite structural
- [x] Processor Implementation Map added to `ArchiveProcessor/CLAUDE.md` — 2026-07-07. ✅
- [x] De-nest the `App/App` folders → `App/macOS/`. Both apps build (0 warnings), 161 Reader tests green, DMG verified. ✅
  - *(`ArchiveCore` shared-package extraction moved to `ArchiveProcessor/POTENTIAL_FEATURES.md` — deferred, 2026-07-08.)*

## Flagged — need the owner present / GUI / a scratch-corpus write
- [x] **GUI-verified 2026-07-08 (owner-driven, on the AR-Smoke scratch corpus, checked at the on-disk xattr level):** Reader inline tag-editor commit — Return-commit ✓, blur-commit of a completed token ✓. Found the half-typed-fragment case *dropped* the word (the documented no-lost-tag safety) yet left a misleading phantom chip; owner chose **WYSIWYG** instead, so `SubjectTokenField` now commits the field's tokens on blur (typed text sticks). Adds route through `TagWriter` (no tag loss); Tier-2 APPROVE. | files: Views/SubjectTokenField.swift | done
- [x] **Perf-checked the nav Table 2026-07-08 (owner-driven GUI, 40k synthetic scratch corpus): the SwiftUI `Table` JANKS at scale.** Scroll stutters; filter-box *keystrokes* lag + can beachball (per keystroke it re-filters 40k AND re-diffs the whole Table on the main thread); sort is slow. Discovery/load of 40k was fine — it's the Table view layer. At the ~150k production target this would be worse. → spawned the follow-up below.
- [x] **Reader: swap the nav SwiftUI `Table` → AppKit `NSTableView`** — `AppKitTableView.swift` (`NSViewRepresentable` wrapping `NSScrollView`+`NSTableView` with `NSTableViewDiffableDataSource`): virtualized rows + cell reuse (fixes scroll); incremental snapshot apply (fixes sort); debounced `filterSearchText` (150 ms, fixes the typing beachball). `ContextMenuTableView` subclass for right-click menu; `ContextMenuActions` trampoline bridges NSMenu items to `NavigationModel`. Model + `TagWriter` untouched (no data-safety surface). Build clean, 161 tests green. **Full GUI re-verify deferred → Morning Review (owner-gated).** ✅
- [x] Remove stray `InlineTest` tag on the SCRATCH corpus — **N/A: scratch corpus (`AR-Smoke/Batch-A/00001`) no longer exists on disk** (directory empty, file cleaned up). No action needed. ✅

## Excluded (not "now": need cost / owner accounts)
- Processor Tier-1 `test-smoke.sh` / Tier-2 `test-tier2.sh` (real OCR → keys + API cost); Reader cloud-drive support; Reader creation-date-mirror (would write metadata onto the real corpus).
- ~~Processor App-Store / Play submission (Phase 4)~~ — **DROPPED (owner 2026-07-16: "we're not doing this any
  time soon").** Off the list entirely; don't re-surface it as an owner action item.
  - [x] **G5 — cheap Tier-1 smoke gate shipped (2026-07-07).** New Suite-root `./test-smoke.sh processor|reader|all` (mirrors `launch.sh`) → `ArchiveReader/test-smoke.sh` (build + full unit suite, **135 tests, free**) + `ArchiveProcessor/test-smoke.sh` (headless **2-image** OCR via `ProcessFilesTestDriver`, `gemini-2.5-flash-lite`, ~a few cents, `mktemp` scratch-isolated, key never printed). Distinct from the cost-heavy `scripts/test-smoke.sh` (raw per-provider calls) + `scripts/test-tier2.sh` (multi-case pipeline) above. Both verified PASS. ✅

## Processor/Capture — WS11 paced re-review findings (2026-07-18, autonomous)
Lean-review re-pass of `ArchiveProcessor/macOS/Sources/ArchiveProcessor/Capture/` (18 commits since the
2026-07-08 original review). 6 finder-level findings, **4 MED / 2 LOW, no HIGH** → none routed to the owner
HOLD queue. Every fix is **Tier-2** (Capture/ no-undo path): a fix session must adversarially re-confirm +
run a scratch-copy functional test before shipping. ⚠️ The Opus-max **refute-verify was budget-truncated**
(verifiers stopped to protect the session usage window — see memory `workflow-pacing-usage-window`); these are
finder-level candidates (only #1's premise manually confirmed). Report: `.maintenance/review/Processor-Capture.md`.
- [ ] **W3.cap-r1 [MED · tag/PDF SPEC]** `LiveCaptureProcessor.swift:640/647/673` — the live path writes tags via the raw `[String]` `MacOSTagger.applyTags` overload (no `colorIsAuthoritative`), so a document segment whose subject is literally "Red"/"Purple" is promoted to a Finder color label (Red=6/Purple=3) → the Reader mis-parses it as a box/folder photo (SPEC subject-collision). KNOWN_ISSUES #5's fix (derive authoritative color from classification) was applied to the batch merge path but **never to the live streaming path**. *(Premise manually confirmed: raw overload at all 3 call sites.)* | Capture | Tier-2
- [ ] **W3.cap-r2 [MED]** `LiveCaptureProcessor.swift:333` — live-OCR dedup keys `pageTasks`/`startedPhotoIds` on the ephemeral `CapturedPhoto.id`, but `CaptureSession.ingest` mints a fresh `CapturedPhoto` (id) on the idempotent-replace/re-upload path (`CaptureSession.swift:516`); a phone auto-retry after a dropped ack bypasses the `!startedPhotoIds.contains(photo.id)` guard (line 301) → a **duplicate paid OCR call** + the prior Task orphaned. | Capture | Tier-2
- [ ] **W3.cap-r3 [LOW]** `CaptureSession.swift:539/549` — `removePhoto`/`removePhotoIfSafe` delete a photo from `session.photos` but never tell `liveProcessor` to cancel that photo's in-flight OCR Task → deleting/reclassifying a page mid-OCR leaves a paid OCR call running + Task/result orphaned in `pageTasks`. | Capture | Tier-2
- [ ] **W3.cap-r4 [MED · misfile]** `LiveCaptureProcessor.swift:385` — `backfillCollections` corrects `staged[i].collectionKey` for an out-of-order Box but never updates the parallel `retained[groupId].collectionKey`; the rotation-review regeneration path reads `collectionKey` from `retained` and overwrites the staged entry → silently reverts the correction → **misfiles the document into the wrong collection folder**. | Capture | Tier-2
- [ ] **W3.cap-r5 [MED · misfile]** `LiveCaptureProcessor.swift:409` — `finalizeSegment` pins `collectionKey` (line 409) before its OCR/tag awaits, but `backfillCollections` skips groups already in `finalizedGroups` yet not yet in `staged`; an out-of-order relay Box delivered during that await can never re-pin the in-flight document → **misfile**. | Capture | Tier-2
- [ ] **W3.cap-r6 [LOW · data-loss]** `LiveCaptureProcessor.swift:996` — `finalize()`'s allFiled branch trashes the whole `stagingDir` after the `executePlans` move await; a straggler segment that finalizes *during* that await writes fresh output into the same `stagingDir` and is not in `plans` → its processed output is discarded and a dangling `staged` entry points into the Trash. | Capture | Tier-2
