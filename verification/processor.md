# Archive Processor — feature ledger

Format and statuses: [`README.md`](README.md). Written by `W40.b3`, 2026-10-21.

- **Sources the promises were written from (rule 3, before the code was opened):** `ArchiveProcessor/README.md`
  (§Features, §Live Capture), `ArchiveProcessor/CLAUDE.md` (Recovery Core Directive, Primary Functions 1-3, Settings
  & Tools, OCR Output Format; the Implementation Map for feature names only), `ArchiveProcessor/TESTING.md` (Tier 2B
  checklist §2.0-2.14, Tier 2D driver list), `ArchiveProcessor/LIVE_CAPTURE_ANDROID_TEST.md` (Runs A-C, Mac side
  only), and `SPEC/tag-format.md` (§Invariants 3, 5, 6, 7 and §2-page PDF structure).
- **Sources read at:** `8a03097c`; code traced at the same commit.
- **Count:** `unproven 39 · works 10 · broken 2 · fixed-pending-recheck 1 · unverifiable-here 1` (2026-11-19, after
  `W40.fix-processor-non-reading-reply`; works: P-19, P-27, P-33, P-34, P-38, P-40, P-45, P-47, P-50, P-53; broken: P-23,
  P-32; fixed-pending-recheck: P-29).

**Order of work (rule 3).** The *Promise* and *Promised in* of every row were committed first, before any
implementation file was opened (`d3db14f3`). The rest was traced afterwards by four read-only passes, and every
`file:line` was then checked mechanically (the file exists and the line is inside it) and a sample by eye.

**Runtime evidence.** Only `W40.d6` (USB) and the `W40.a3` phone↔Mac round trip ran the real app through a
promise, and both are taken in where they apply. A green suite is not runtime evidence (README §Statuses), so the
`W40.a3` VM suite moves no row. Processor's tests are almost all headless shell drivers (`ArchiveProcessor/scripts/
test-*.sh`, Tier 2D of `TESTING.md`), named under *Real-path test* by script; the UITest bundle has eighteen methods
and none starts a run. The journeys (`W40.d1`-`d5`) provide the evidence.

**Drift.** Where the code does not do what the promise says, *Notes* starts with **Drift** (rows P-01 to P-06,
P-08, P-10, P-12, P-17, P-20, P-22, P-25, P-26, P-28 to P-30, P-32, P-35, P-42, P-47). A drift note is input for
`W40.b5`; it is not a reproduced bug and does not make the row `broken` (rule 5). Suspects found while tracing are
`S-024`-`S-039` in [`SUSPECTS.md`](SUSPECTS.md). One defect was reproduced: the Drive store's mock test cannot
compile (P-46, `W40.fix-drive-script-path`). Doc-against-doc drift is listed at the end.

Paths are relative to `ArchiveProcessor/macOS/Sources/ArchiveProcessor/` unless they start with `scripts/`
(`ArchiveProcessor/scripts/`), `packages/` or `evidence/`. UITests are `ArchiveProcessorUITests/<Class>.<method>`.

The phone side of Live Capture is the capture ledger's ([`capture.md`](capture.md), `C-` rows, `W40.b4`). Rows here
cover the Mac: the receiver, the tag card, the drain gate, staging, finalize and the backup folder.

---

## Shell, settings and keys

### P-01 · Three areas and a Settings window

- **Promise:** the window has three areas chosen at the top — Process Files, Live Capture, Tools — and a native
  Settings window opens with ⌘, holding every durable setting; the tagging mode and output folder stay in Process
  Files.
- **Promised in:** `README.md` intro, §Settings window; `CLAUDE.md` §Settings & Tools; `TESTING.md` §2.0, §2.1.
- **Reached by:** launch → `ArchiveProcessorApp.swift:25` (`ContentView()`) → segmented picker over `Mode`
  (`ContentView.swift:116`, `:19`) → `switch mode` (`:132`): `OCRView` (`:134`), `LiveCaptureView` (`:136`),
  `ToolsView` (`:138`). ⌘, → `Settings { SettingsView() }` (`ArchiveProcessorApp.swift:44`). Output folder
  `Views/OCRView.swift:760`; tagging picker `Views/OCRView.swift:516`.
- **Real-path test:** `ArchiveProcessorUITests/ProcessorUITests.testDefaultProcessFilesShowsScratchDropZoneAndTaggingPanel`
  (Files area); ⌘, is opened by `AccessibilityAuditUITests.testMainScreensPassAuditInLightMode` and
  `TransientStateUITests.testCommonTransitionsShowNoTransientState`. No test clicks the Tools or Live Capture segment
  (Live Capture is entered only through the launch flag `-APUITestLiveCaptureFinishingScrim`, `ContentView.swift:7-11`).
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
- **Notes:** **Drift.** The tagging mode does not only "stay in Process Files": it is also a full control in
  Settings (`Views/SettingsView.swift:881`). `TESTING.md` §2.0 orders the areas Files / Tools / Live Capture; the
  code and README order them Files / Live Capture / Tools.

### P-02 · Live cost and time estimate in Settings

- **Promise:** a pinned pane in Settings recomputes, as settings change, the cost (OCR, rotation, tagging,
  collection ID; standard and batch) and the processing time (per phase) of a 1,000-file run at the standard image
  size.
- **Promised in:** `README.md` §Settings window; `CLAUDE.md` §Settings & Tools; `TESTING.md` §2.1 last item.
- **Reached by:** ⌘, → `SettingsView.body` (`Views/SettingsView.swift:178`) → `costPane` (`:262`) →
  `CostEstimator.estimate` (`:276`) and `TimeEstimator.estimate` (`:283`) at 1,000 files and
  `effectiveStandardImageMB` (`:263`).
- **Real-path test:** none for the figures. `ProcessorUITests.testLocalAgentSettingsAndFilesShowSubscriptionCostAndGuidedSetup`
  checks only that `ap.settings.costPane` exists with the Local Agent text. `scripts/test-processing-history.sh`
  exercises `CostEstimator`, not the pane; nothing covers `TimeEstimator`.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
- **Notes:** **Drift.** The batch total shows only when the batch toggle is on (`:295`), not always beside the
  standard one. Apple Vision, Local Agent and a gateway with no pricing show other content (`:271-275`). The pane
  also has a Segmentation line no source promises (`:305`).

### P-03 · Cost estimate before a Process Files run

- **Promise:** once files are added, Process Files shows the estimated cost before processing, standard and batch
  side by side, updated as files are added or removed and as the model changes.
- **Promised in:** `README.md` §Cloud and on-device OCR, §Other Features; `CLAUDE.md` §Cost Estimator; `TESTING.md`
  §2.2.
- **Reached by:** drop files on the drop zone (`Views/OCRView.swift:901`) → `costEstimate` (`:197`) →
  `GroupBox("Cost Estimate")` (`:631`): "Total (standard)" (`:694`), "Total (batch)" (`:703`, `ap.ocr.batchTotal`).
- **Real-path test:** `MoneyJourneyUITests.testStoredBatchFlagOnOpenAIStillSuppressesPageReaders`
  compares standard and batch estimates in Process Files and inspects the requests sent on Start.
  `ProcessorUITests.testMultiPageScratchPDFDisablesTaggingAndExplainsAutoReOCR` checks `ap.ocr.pdfPageCost`.
- **Runtime evidence:** OpenAI showed a $0.0052 batch estimate alongside a $0.0105 standard estimate with the stored Batch flag on. Both reads took the standard path. [Independent VM evidence](evidence/processor/W49.proc-suspects-money-check.md).
- **Status:** `broken` — W49.proc-fix-s027 (S2) for unsupported batch estimates.
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
  - 2026-11-21 W49.proc-suspects-money-check — `broken` on the tested path.
- **Notes:** **Drift.** Batch is shown only with batch mode on, no gateway and no pre-OCRed input (`:701`).
  Vision, Local Agent and an unpriced gateway replace the dollar figure (`:554`, `:603`, `:621`). The Gemini
  refusal reader's cost is excluded from the totals (`:713-718`). See also S-027.

### P-04 · Guided API-key setup

- **Promise:** a first-run wizard, and a Set up keys button in Settings, walk the user through creating a key
  (step-by-step, the exact console page); a pasted key is format-checked and confirmed with a live sample-OCR call
  before it is saved; per-provider status chips in Settings show which keys are set and working.
- **Promised in:** `README.md` §Guided API-Key Setup; `CLAUDE.md` Impl Map `ProviderKeySpec`, `KeyValidator`,
  `ProviderKeyWizard`.
- **Reached by:** Settings button `ap.settings.guidedKeySetup` (`Views/SettingsView.swift:686-690`) → sheet →
  `ProviderKeyWizard` (`:704`). First run: `ContentView.onAppear` → `maybePresentKeyOnboarding`
  (`ContentView.swift:93`, `:146`), only when no key of any kind exists. Validate (`Views/ProviderKeyWizard.swift:148`)
  → `validate()` (`:196`) → `KeyValidator` (`OCR/KeyValidator.swift:49`); optional sample OCR (`:155-159`) →
  `SampleOCRTester`. Status chips: `keyStatusChip` (`Views/SettingsView.swift:732`).
- **Real-path test:** `ProcessorUITests.testAnthropicGuidedKeySetupShowsConsoleCostPrivacyAndKeyShape` opens the
  wizard from Settings and checks the Anthropic page text. The tests leave two paths open: the first-run
  presentation and a successful save to a real Keychain.
- **Runtime evidence:** The [independent VM reproduction](evidence/processor/W49.proc-suspects-messages-check.md)
  showed Validated beside an empty OpenAI field. `MessageJourneyUITests.testWizardReportsRefusedKeySave` now
  drives the same Validate button with a successful synthetic provider reply and a refused save. It checks the
  wizard's provider result and Keychain warning, then checks **Save failed** in Accounts after revisiting the panel.
- **Status:** `fixed-pending-recheck` — W49.proc-fix-s024 for S-024.
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
  - 2026-11-21 W49.proc-suspects-messages-check — S-024, see runtime evidence.
  - 2026-11-22 W49.proc-fix-s024 — the wizard reports the Keychain refusal and Accounts shows it.
- **Notes:** **Drift.** The key is confirmed by a cheap model-list call (`OCR/KeyValidator.swift:48`), not a sample
  OCR, and saved straight after (`Views/ProviderKeyWizard.swift:206`); the sample OCR is a separate optional
  button. The format check only shows a caption (`:144-147`), it does not block Validate. The wizard covers
  Anthropic, Gemini, Mistral and OpenAI (`Models/ProviderKeySpec.swift:135`), not OpenRouter. The Settings button
  label omits Anthropic (`Views/SettingsView.swift:687`). Suspect `S-024`.

### P-05 · Keys only in the Keychain, one field per provider

- **Promise:** each provider (Anthropic, Gemini, Mistral, OpenAI, OpenRouter, Gateway) has its own key field in
  Settings; keys are stored only in the macOS Keychain, masked, never in code, config files or logs.
- **Promised in:** `README.md` §Cloud and on-device OCR, §Guided API-Key Setup, §Settings window; `CLAUDE.md` §API
  Keys & LLM Calls, §Settings & Tools; `TESTING.md` §2.1.
- **Reached by:** ⌘, → `apiKeySection` (`Views/SettingsView.swift:685`) → `keyField` (`:708`) → `SecureField`
  (`:711`) → `KeychainHelper.save` (`:721`). Six accounts: Anthropic, Gemini, Mistral, OpenAI, OpenRouter, Gateway
  (`:690-696`; Gateway only with Use gateway on).
- **Real-path test:** none. Every test runs headless, where `KeychainHelper` is a no-op
  (`Models/KeychainHelper.swift:18-35`). Nothing scans output or logs for a leaked key.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
- **Notes:** **Drift.** README §Settings window lists five key fields, without OpenRouter; `TESTING.md` §2.1 lists
  three providers. The Gemini key travels in the URL query (`OCR/GeminiClient.swift:40`, `OCR/KeyValidator.swift:55`);
  nothing found logs those URLs, but a URL quoted in an error would carry it.

## OCR — readers and routes

### P-06 · Built-in providers and models, with a thinking level

- **Promise:** provider and model dropdowns offer exactly the built-in lists (Anthropic Sonnet/Opus 4.6; Gemini
  with `gemini-3.8-flash` the default; Mistral OCR; OpenAI GPT-5 family, `gpt-5-nano` default; OpenRouter's pinned
  catalog); models that support it get a Low/High thinking dropdown, hidden otherwise.
- **Promised in:** `CLAUDE.md` §LLM Provider & Model Selection, §Thinking Mode; `README.md` provider table;
  `TESTING.md` §2.1. Sources disagree: see Notes.
- **Reached by:** ⌘, → provider picker (`Views/SettingsView.swift:482`, `ap.settings.providerPicker`) → model
  picker (`:491`) over `selectedProvider.models` (`Models/ProviderModels.swift:21`); thinking picker (`:510`) gated
  by `supportsThinking`. Default = first entry (`Models/ModelSelectionStore.swift:48`).
- **Real-path test:** none through the UI. `scripts/test-ocr-refusal.sh` asserts `gemini-3.8-flash` is the Gemini
  default; `scripts/test-openrouter.sh` the OpenRouter pinning; `scripts/test-thinking-budgets.sh` the budget
  mapping. The Anthropic, Mistral and OpenAI lists, `gpt-5-nano` as default and the picker's show/hide are untested.
- **Runtime evidence:** 2026-11-18 W40.d3 (`verification/evidence/processor/W40.d3-providers.md`): the Anthropic
  (`claude-sonnet-4-6`) and Mistral (`mistral-ocr-latest`) clients each read three RG 165 photos through Process Files
  in the VM, every PDF passing the checker. OpenAI is `unverifiable-here` (no key, by the owner's 2026-10-11 ruling).
  The pickers and thinking levels are still unexercised.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
  - 2026-11-18 W40.d3 — Anthropic and Mistral clients work on real photos; OpenAI unverifiable here; the pickers
    keep the row `unproven`.
- **Notes:** **Drift.** README's provider table says four cloud providers with no OpenRouter, a Gemini default of
  3.1 Flash Lite, and a list without `gemini-3.8-flash` or `gemini-3.5-flash-lite`; the code and `CLAUDE.md` make
  `gemini-3.8-flash` the default (`Models/ProviderModels.swift:229`). `TESTING.md` §2.1 lists three providers.
  `CLAUDE.md` says `gpt-5.4-mini` takes no `reasoning_effort`, but the code marks it `supportsThinking: true`
  (`Models/ProviderModels.swift:371`).

### P-07 · Custom model IDs

- **Promise:** Settings › Manage custom models… adds extra Anthropic or Gemini model IDs, which then appear in the
  model dropdown, persist across relaunch, and are the model used (named in the PDF's page-2 subheader).
- **Promised in:** `CLAUDE.md` §Custom models; `README.md` §Project Structure (`ModelSelectionStore`); `TESTING.md`
  §2.1, §2.11.
- **Reached by:** ⌘, → Manage custom models… (`Views/SettingsView.swift:522`) → `ManageModelsView`
  (`Views/ManageModelsView.swift:3`) → Add Model… → `AddModelView.addModel` (`:158`) → `CustomModelStore.add`
  (`Models/ProviderModels.swift:704`); `LLMProvider.models` appends them (`:31`).
- **Real-path test:** none.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
- **Notes:** blank cost fields become 0 with no warning (`Views/ManageModelsView.swift:177-178`). The button also
  shows for OpenAI, Mistral and OpenRouter, but the sheet offers only Anthropic and Gemini (`:84`).

### P-08 · OpenAI-compatible gateway, with an OpenAI preset

- **Promise:** Use gateway routes OCR through any OpenAI-compatible endpoint (base URL, model ID, its own Gateway
  key, user-supplied pricing); batch and LLM rotation are greyed out on that path; Fill in OpenAI preset prefills
  OpenAI's endpoint, cheapest non-reasoning model and pricing.
- **Promised in:** `CLAUDE.md` §Custom models, gateway & Local Agent; `README.md` §Cloud and on-device OCR;
  `TESTING.md` §2.1, §2.10.
- **Reached by:** ⌘, → OCR backend picker (`Views/SettingsView.swift:430-440`) → API Gateway fields (`:442-475`);
  Fill in OpenAI preset (`:448` → `applyOpenAIGatewayPreset`, `:1061`). Run: `Views/OCRView.swift:1305`
  (`startProcessing`) → `processor.startProcessing(gatewayConfig:)` (`:1363`) → `OpenAICompatibleClient.gateway`
  (`OCR/OpenAICompatibleClient.swift:23`, from `OCR/OCRProcessor+OCR.swift:1760`).
- **Real-path test:** partial: `scripts/test-local-models.sh` (`LOCALMODELS_TEST=1`) runs `performOCRCall` with a
  `GatewayConfig` over the no-wire seam (the local variant). The preset check below applies the public Settings
  control. The real Gateway key, estimates and live response remain open.
- **Runtime evidence:** [Independent VM reproduction](evidence/processor/W49.proc-suspects-messages-check.md) via
  `MessageJourneyUITests.testOpenAIPresetBuildsLegacyTokenLimit`. The Settings preset selected GPT-5.4 mini
  and Start built a request with `max_tokens: 8192`. The VM verified the help and request mismatch. Live
  OpenAI acceptance remains open.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
  - 2026-11-21 W49.proc-suspects-messages-check — S-025, see runtime evidence.
- **Notes:** **Drift.** `TESTING.md` §2.1 and §2.10 say the gateway greys out the LLM rotation controls.
  The gateway can request a comparative vote. See P-25 for what happens when that request fails.

### P-09 · A model on this Mac

- **Promise:** in gateway mode, A model on this Mac marks the endpoint as a local LM Studio / Ollama / mlx server;
  Settings recommends a model by the Mac's memory and fills the fields at $0, Check server lists the server's
  models; the route caps tokens, detects a repetition loop in the streamed reply, reads a looped page once more,
  runs one page at a time, never sends a saved key, and escalates a failed page to the cloud only when the user
  allows it.
- **Promised in:** `CLAUDE.md` §A model on this Mac (`W41.app-local-models`, `-fu1`).
- **Reached by:** ⌘, → API Gateway → `LocalModelSettingsView` (`Views/SettingsView.swift:443`; toggle
  `Views/LocalModelSettingsView.swift:26`, recommendation `:37`, fill `:80`, Check server `:94`). Run: one worker
  (`OCR/OCRProcessor+OCR.swift:27`) → `OpenAICompatibleClient` local branch (`OCR/OpenAICompatibleClient.swift:27`):
  4,096-token cap (`:63`), streamed loop stop and second reading (`:138-176`), escalation only when allowed
  (`OCR/OCRProcessor+OCR.swift:1801-1812`), stand-in key (`Models/ProviderModels.swift:641`).
- **Real-path test:** `scripts/test-local-models.sh` (`OCR/LocalModelsTestDriver.swift`) runs the real
  `performOCRCall` over `NetworkSession.testTransport`: cap, temperature, stand-in key, timeout, loop guards,
  second reading, escalation, one worker, $0 estimate. Not covered: a real local server, the rendered
  recommendation, Check server, the Settings → run-snapshot hand-off (the driver builds `GatewayConfig` itself).
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.

### P-10 · Local Agent CLI backend

- **Promise:** with no API key, Local CLI Agent runs OCR, classification, tagging and segmentation through an
  installed, signed-in Claude Code (Gemini CLI and Codex unvalidated); a guided Set up wizard and Detect & Verify
  check are built in; batch and LLM rotation are skipped; the cost shows "Included in your subscription — usage
  limits apply"; PDF headers and history name the CLI and record $0.
- **Promised in:** `README.md` §Cloud and on-device OCR; `CLAUDE.md` §Local Agent CLI backend (`W13.cli-1`…`4`).
- **Reached by:** ⌘, → backend Local CLI Agent (`Views/SettingsView.swift:432`) → `localAgentControls` (`:637`;
  Detect & Verify `:658`; Set up (guided)… `:664`). Run: `Views/OCRView.swift:1364` (`LocalAgentConfig.fromDefaults`,
  `Models/LocalAgentConfig.swift:92`) → `OCR/OCRProcessor+OCR.swift:1757` (`LocalAgentClient.ocr`). Batch forced
  off at `Views/OCRView.swift:1354`.
- **Real-path test:** `ProcessorUITests.testLocalAgentSettingsAndFilesShowSubscriptionCostAndGuidedSetup` (cost
  text in both places, CLI picker, wizard). `scripts/test-localagent.sh` (`LOCALAGENT_TEST=1`, fake CLI) drives the
  real `LocalAgentClient` and resume. `scripts/test-processing-history.sh` checks the PDF header and history name
  `Local CLI Agent (claude)` at $0. A real signed-in CLI and Detect & Verify remain open.
- **Runtime evidence:** [Independent VM reproduction](evidence/processor/W49.proc-suspects-messages-check.md) via
  `MessageJourneyUITests.testCodexEndsPageBeforeThePromisedRetry`. Process Files Start, with a Codex stub
  reporting a future reset, made one invocation and ended before that reset with the log saying it would
  pace and retry.
  See also the [earlier VM provider check](evidence/processor/W40.d3-providers.md).
- **Status:** `unverifiable-here` (needs a signed-in `claude` CLI beside a running app: the owner's guided session)
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
  - 2026-11-18 W40.d3 — `unverifiable-here`.
  - 2026-11-21 W49.proc-suspects-messages-check — S-018, see runtime evidence.
- **Notes:** **Drift.** README says the guided wizard covers Claude Code, Gemini CLI and Codex; it offers Claude and
  Gemini only (`Models/LocalAgentSpec.swift:11`, `:63`). The Batch toggle stays enabled under the Local Agent
  (`Views/SettingsView.swift:758`) and is silently ignored at run time.

### P-11 · Apple Vision on this Mac

- **Promise:** Apple Vision transcribes on-device with no key, network or cost, with language, fast-recognition,
  minimum-confidence and custom-vocabulary controls; with the text-only LLM judgement off, No tagging or Copy source
  tags gives a fully offline run; with it on, only Vision's text (never the image) goes to a separately selected
  direct LLM for classification, dates, segmentation and tags.
- **Promised in:** `README.md` §Cloud and on-device OCR; `CLAUDE.md` §Apple Vision (`W13.vision-1`/`2`).
- **Reached by:** ⌘, → backend Apple Vision → `appleVisionControls` (`Views/SettingsView.swift:585`: languages
  `:589`, fast `:592`, confidence `:595-603`, vocabulary `:604`, LLM judgement `:613`). Run:
  `Views/OCRView.swift:799` (`canStartProcessing`, `visionWorkflowIsSupported` `:180`) → `OCR/OCRProcessor+OCR.swift:1763`
  → `VNRecognizeTextRequest` (`OCR/VisionClient.swift:86-90`).
- **Real-path test:** `scripts/test-vision-hybrid.sh` (`VISIONHYBRID_TEST=1`) checks the judgement request carries
  no image; `scripts/test-vision-ocr.sh` compiles the real `VisionClient` against two generated PNGs. Not covered:
  the Settings controls and a whole offline run through Process Files.
- **Runtime evidence:** 2026-11-18 W40.d3 (`verification/evidence/processor/W40.d3-providers.md`): the shipped
  `VisionClient` read three RG 165 photos on the host with the default settings (`scripts/test-vision-ocr.sh
  <images>`: 19, 28 and 24 lines). A whole Process Files run cannot be shown here: Vision fails in the VM guest
  (`KNOWN_ISSUES.md`; W40.d1 saw it on six photos).
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
  - 2026-11-18 W40.d3 — the client reads real photos on the host; the whole offline run stays unshown.

### P-12 · A second reader for a page Gemini refuses

- **Promise:** a page the default Gemini model refuses is read by a second reader (Claude, then Qwen3.6 27B on
  OpenRouter) rather than coming back empty.
- **Promised in:** `CLAUDE.md` Gemini model list and OpenRouter note (`W41.app-ocr-default`,
  `W41.app-openrouter-fu1`).
- **Reached by:** a Gemini run → `performOCRCall` (`OCR/OCRProcessor+OCR.swift:1715`, `refusalFallback` on by
  default) → `OCRCascade.resolve` (`:1805`, `OCR/OCRCascade.swift:152`) → `OCRRefusalFallback.readRefusedPage`
  (`OCR/OCRRefusalFallback.swift:111`) → `availableRoutes` (`:60`).
- **Real-path test:** `scripts/test-ocr-refusal.sh` (`OCRREFUSAL_TEST=1`, `OCR/OCRRefusalFallbackTestDriver.swift`)
  runs the real `performOCRCall` over the no-wire transport, with routes injected (`routesOverride`, `:101`) in
  place of the Keychain and CLI lookup. Not covered: building the routes from real keys, a real refusal.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
- **Notes:** **Drift.** The code's order is Claude (plan, else key), Qwen3.6 27B on OpenRouter, then OpenAI
  `gpt-5.4-mini`, then Mistral OCR (`OCR/OCRRefusalFallback.swift:60-98`); `CLAUDE.md` names only the first two.

### P-13 · Cheap-first OCR cascade

- **Promise:** with an escalation model set (off by default), a page the run's model fails on — cut off, unparsable,
  server error with no text, Gemini refusal — is read again by that model; transport errors, timeouts, rate limits,
  key errors, gateways, the Local Agent and Vision-as-first-reader never escalate; the kept reading is named in the
  PDF header and its cost added to the run; a breaker caps escalations at 20 then a quarter of the run.
- **Promised in:** `CLAUDE.md` §Cheap-first OCR cascade (`W41.app-ocr-cascade`).
- **Reached by:** ⌘, → Escalate failed pages to (`Views/SettingsView.swift:528-545`, `ap.settings.cascadeRoute`;
  disagreement toggle `:554`) → `OCRCascade.fromDefaults` (`OCR/OCRProcessor+Pipeline.swift:298`) →
  `OCRCascade.resolve` (`OCR/OCRProcessor+OCR.swift:1805`): `isEscalatable` (`OCR/OCRCascade.swift:129`),
  `Breaker.admit` (`:67`).
- **Real-path test:** `scripts/test-ocr-cascade.sh` (`OCRCASCADE_TEST=1`, `OCR/OCRCascadeTestDriver.swift`) runs the
  real `performOCRCall` over the no-wire transport: triggers, the never-escalate list, the header naming the
  escalation route, cost on the result, the breaker (20, then a quarter). Not covered: the Settings picker as
  rendered, a real provider reply.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
- **Notes:** neither README nor `TESTING.md` mentions the cascade. The pre-run estimate does not include
  escalation cost; the history does (`OCRResult.secondReader.estimatedCost`).

### P-14 · Each page's reader chosen by its kind

- **Promise:** with Choose each page's reader by its kind on (off by default), each dropped image is classified on
  the Mac and the guide's first runnable pick for that kind is preselected; each row shows the kind and reader with
  a menu to change it; the estimate adds the price difference; the reader is named in the PDF header.
- **Promised in:** `CLAUDE.md` §Each page's reader by its kind (`W41.app-page-kind`).
- **Reached by:** ⌘, → Choose each page's reader by its kind (`Views/SettingsView.swift:562`) → `pageKindsActive`
  (`Views/OCRView.swift:168`) → on drop `pageKinds.update(files)` (`:312`, `Views/OCRView+PageKind.swift:40`) → row
  line `PageKindRowLine` (`Views/OCRView.swift:951`); at Start `processor.pageReaders = pageReaderPlan` (`:1337`) →
  `OCR/OCRProcessor+OCR.swift:1747`; header `OCR/PDFGenerator.swift:277`.
- **Real-path test:** `scripts/test-ocr-page-kind.sh` (`OCRPAGEKIND_TEST=1`, `OCR/OCRPageKindTestDriver.swift`):
  classifier weights, routing, the plan, the estimate, the real `performOCRCall`, history and a row render. Not
  covered: the Settings toggle, the Start freeze, drag and drop.
- **Runtime evidence:** With Batch off, two OpenAI pages followed the GPT-5 nano selection. With Batch stored on, the menu disappeared and both standard requests used GPT-5.4 mini. [Independent VM evidence](evidence/processor/W49.proc-suspects-money-check.md).
- **Status:** `broken` — W49.proc-fix-s027 (S2) when Batch is stored on for OpenAI.
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
  - 2026-11-21 W49.proc-suspects-money-check — `broken` on the tested path.
- **Notes:** limits are in Processor `KNOWN_ISSUES.md` (PDFs are not classified; the 0.8 floor is unmeasured). The
  feature is dropped whenever the raw batch toggle is on, even for a provider with no batch (S-027).

### P-15 · Institutional computing text import

- **Promise:** Use institutional computing text… takes a cluster kit's bulk output folder; a page whose image
  SHA-256 matches a record with model and cluster name takes the cluster's text (plus one text-only classification
  call), the PDF header names the cluster and job, every other page is read as usual, and nothing is written to the
  folder or the inputs.
- **Promised in:** `CLAUDE.md` §Institutional computing import (`W41.app-institutional-compute`).
- **Reached by:** Files tab → Use institutional computing text… (`Views/OCRView+InstitutionalCompute.swift:23`,
  shown at `Views/OCRView.swift:726-727`) → open panel → `InstitutionalComputeImport.load`
  (`OCR/InstitutionalComputeImport.swift:56`); frozen at Start (`Views/OCRView.swift:1338`); matched by SHA-256 in
  `performOCRCall` (`OCR/OCRProcessor+OCR.swift:1722`); header `OCR/PDFGenerator.swift:268`.
- **Real-path test:** `scripts/test-institutional-compute-import.sh` (`INSTITUTIONAL_COMPUTE_IMPORT_TEST=1`) runs the
  real load and the real `performOCRCall`; `ProcessorUITests.testInstitutionalComputingImportOffersNeutralFolderChooser`
  drives the real button and panel. Not covered: the Start hand-off and a whole run with an import.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.

### P-16 · Custom OCR prompt

- **Promise:** the user can append instructions to the default OCR prompt.
- **Promised in:** `README.md` §Cloud and on-device OCR.
- **Reached by:** ⌘, → Tagging & Segmentation → Custom prompt (optional) (`Views/SettingsView.swift:951`) →
  `Views/OCRView.swift:1307-1311` (`SegmentationContext.customPrompt`) → `OCRPrompt.build(…, customPrompt:)`
  (`OCR/OCRPrompt.swift:6`, appended `:56`).
- **Real-path test:** `scripts/test-ocr-prompt.sh` tests `OCRPrompt.build` with custom text. Not covered: the
  Settings → run → client plumbing and the batch path.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
- **Notes:** the control sits under Tagging & Segmentation, not an OCR section.

### P-17 · Size-based image resolution

- **Promise:** the resolution slider targets a fraction of a standard image size (default 3 MB, set in Settings),
  so larger files are downscaled more and average or small files are left full-resolution.
- **Promised in:** `README.md` §Cloud and on-device OCR, §Size-based image resolution; `TESTING.md` §2.1.
- **Reached by:** ⌘, → Image resolution slider (`Views/SettingsView.swift:772`) and Standard image size (`:779`) →
  `Views/OCRView.swift:1312` → `targetDimensionScale` (`OCR/OCRProcessor+OCR.swift:1740`, defined
  `OCR/OCRProcessor.swift:117`).
- **Real-path test:** `scripts/test-manifest-persistence.sh` check B8 calls `targetDimensionScale` directly. Not
  covered: the encode itself, the batch path.
- **Runtime evidence:** at 100% and a 3 MB target, direct Gemini submitted 602,467 B at 985×739. Gemini batch submitted the original 12,349,513 B at 2000×1500. [Independent VM evidence](evidence/processor/W49.proc-suspects-money-check.md).
- **Status:** `broken` — W49.proc-fix-s026 (S2) for batch sizing.
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
  - 2026-11-21 W49.proc-suspects-money-check — `broken` for a dense JPEG in Gemini batch.
- **Notes:** **Drift.** The batch path is not size-based: it passes the raw slider fraction to
  `ImageEncoding.loadImageAsJPEG(scale:)` (`OCR/OCRProcessor+OCR.swift:787-801`). The shared cap remains 2,048 px (S-026).

### P-18 · Parallel OCR workers and previous-page image context

- **Promise:** OCR runs in parallel across a configurable worker pool (Settings › Parallel OCR workers, default 4);
  optionally the previous page's image is sent with the current one (Gemini, Anthropic) to improve classification,
  roughly doubling per-image cost, with OCR still parallel.
- **Promised in:** `README.md` §Previous-page image context; `CLAUDE.md` §Concurrency; `TESTING.md` §2.4.
- **Reached by:** ⌘, → Parallel OCR workers (`Views/SettingsView.swift:826-829`) → `schedulingWorkerCount`
  (`OCR/OCRProcessor+OCR.swift:25`) → task group (`OCR/OCRProcessor+Pipeline.swift:2099-2109`). Send previous page
  image (`Views/SettingsView.swift:917`, enabled only for a per-page-classifier plan, `:922`) →
  `Views/OCRView.swift:1310` → `OCR/OCRProcessor+Pipeline.swift:2116`.
- **Real-path test:** none. `scripts/test-batch-resume.sh` only checks the worker count persists and resumes.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
- **Notes:** **Drift.** README names Gemini and Anthropic for the previous image; the OpenAI-compatible and Local
  Agent clients send it too (`OCR/OpenAICompatibleClient.swift:46`, `OCR/LocalAgentClient.swift:86`). The Settings
  help limits it to Automatic tagging with Manual segmentation, which README does not say. The worker count is
  forced to 1 for a local model and fixed for Vision, also unstated.

### P-19 · Batch processing

- **Promise:** Anthropic, Gemini and Mistral offer a batch mode at half price; batch state persists to disk and
  survives restarts; a pending batch resumes with one click; a running batch can be cancelled server-side; an
  uncertain submission stops and keeps its recovery journal rather than resubmitting; a finished chunk with no pages
  is re-read, then its files are reported failed without holding up the run.
- **Promised in:** `README.md` §Batch Processing and its two sub-sections; `CLAUDE.md` §Batch Processing;
  `TESTING.md` §2.8, §2.13.
- **Reached by:** ⌘, → Batch mode (`Views/SettingsView.swift:752`; disabled for gateway, Vision, pre-OCRed `:758`)
  → `Views/OCRView.swift:1354` → `OCR/OCRProcessor+Pipeline.swift:2857` (`provider.supportsBatch`) →
  `performBatchOCR`. Resume Batch (`Views/OCRView.swift:463` → `resumePendingBatch` `:1260` →
  `OCR/OCRProcessor+Pipeline.swift:1419`); Cancel (`Views/OCRView.swift:781` → `OCRProcessor.cancel`,
  `OCR/OCRProcessor+Pipeline.swift:2496`).
- **Real-path test:** `scripts/test-batch-resume.sh` (`BATCHRESUME_TEST`, `Capture/BatchResumeTestDriver.swift`) and
  the `OCR/Batch*Contract.swift` files it runs: parse, journal, cancel retention, resume, the uncertain-outcome and
  empty-chunk sentences. The scratch S-051 script drives Gemini batch creation against a loopback server.
  The Batch toggle itself is outside that headless run.
- **Runtime evidence:** 2026-11-18 W40.d4, `verification/evidence/processor/W40.d4-batch.md`: real Mistral
  (`mistral-ocr-latest`) and Anthropic (`claude-sonnet-4-6`) batches of three RG 165 photos through Process Files in
  the VM, submitted, polled and collected (3 of 3 each, every PDF passes the checker; the providers report 3
  succeeded); an Anthropic batch stopped right after submission was cancelled server-side (3 canceled) and its
  journal deleted. Gemini `unverifiable-here` (no direct key, owner 2026-11-13; no batch through the gateway).
  The S-051 scratch run found that a complete Gemini 401 takes the same recovery path as a cut-off 200.
  Both warn of an uncertain submission and offer Resume with zero acknowledged IDs. [S-051 evidence](evidence/processor/W49.proc-s051-verify.md).
- **Status:** `works` (Anthropic, Mistral; Gemini `unverifiable-here` against the real provider)
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
  - 2026-11-18 W40.d4 — real batch submit, poll, collect and a cancel: `works` for Anthropic and Mistral.
- **Notes:** Settings disables Batch for unsupported providers. A stored Batch flag still affects standard OpenAI runs and their estimates (S-027). [Independent VM evidence](evidence/processor/W49.proc-suspects-money-check.md).

### P-20 · Automatic retry and the retry dialog

- **Promise:** files failing on 429/503/529 are retried with exponential backoff; remaining failures open a dialog
  to retry them, and the loop continues until all succeed or the user continues. A retry reproduces the run's own
  backend and changes only rotation.
- **Promised in:** `README.md` §Automatic Retry; `CLAUDE.md` §W25.retry-backend correction; `TESTING.md` §2.13.
  Sources disagree: see Notes.
- **Reached by:** no control: on failure the run calls `retryHighUseFailures` (`OCR/OCRProcessor+OCR.swift:1871`;
  one pass after 10 s over `isRetryableError`, `:1860`), then `retryLoopForFailedFiles`
  (`OCR/OCRProcessor+Pipeline.swift:3285`) raises the retry sheet (`Views/OCRView.swift:383`), and `retryOne`
  (`OCR/OCRProcessor+Pipeline.swift:3340`) reuses the run's locked config.
- **Real-path test:** `scripts/test-retry-backend.sh` (`RETRY_BACKEND_TEST`) for the backend lock;
  `scripts/test-network-session.sh` for transport backoff and no double-charge. No test drives the dialog.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
- **Notes:** **Drift.** README says 429/503/529 retry with exponential backoff; OCR POSTs are `.nonIdempotent`
  (`OCR/GeminiClient.swift:48`), so `OCR/NetworkSession.swift:289-291` backs off only on 429, and 503/529 get one
  fixed 10 s pass. README says the dialog retries "with a different provider/model/API key"; that picker was
  removed (`W25.retry-backend`, `CLAUDE.md` last section).

### P-21 · Pre-OCRed PDF input

- **Promise:** PDFs that already carry OCR text are processed without OCR calls: text is extracted, classified by
  text-only calls, then tagged and organised normally, without overwriting the input.
- **Promised in:** `README.md` §Pre-OCRed PDF Input; `TESTING.md` §2.9.
- **Reached by:** ⌘, → Pre-OCRed PDF input (`Views/SettingsView.swift:746`) → Start →
  `OCR/OCRProcessor+Pipeline.swift:2927` → `performPreOCRedProcessing` (`OCR/OCRProcessor+OCR.swift:81`) →
  `PDFTextExtractor.extract` (`:105`) → text-only classification.
- **Real-path test:** none (`Capture/ProcessFilesTestDriver.swift:178` always sets `preOCRedInput: false`).
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
- **Notes:** the output of a pre-OCRed run is the input file itself (`OCR/OCRProcessor+OCR.swift:120`): its bytes are
  kept, but its Finder tags are rewritten. README frames this path as re-tagging; `TESTING.md` §2.9 says only
  "re-OCR or passthrough per design".

## Input

### P-22 · Adding files

- **Promise:** images can be dragged onto the window, chosen in an open panel, or found recursively in a chosen
  folder; JPEG, PNG, TIFF and HEIC are accepted (and PDF for pre-OCRed input), others ignored gracefully.
- **Promised in:** `README.md` §File Input; `CLAUDE.md` §File Input; `TESTING.md` §2.3.
- **Reached by:** the Files pane's `DropReceiver` calls `OCRView.handleDroppedURLs`. Add Files… calls
  `OCRView.selectFiles`. Both reach `OCRView.admit` and filter with `ProcessFilesTree.isInput` against
  `ImageEncoding.acceptedImageExtensions` and PDF.
- **Real-path test:** the PDF UITests (`ProcessorUITests.testMultiPageScratchPDFDisablesTaggingAndExplainsAutoReOCR`,
  `.testInstitutionalComputingImportOffersNeutralFolderChooser`) feed a PDF through `handleDroppedURLs` by a UI-test
  seam. S-048 drove the actual Add Files panel and Finder drop with a synthetic PNG and ran Start.
- **Runtime evidence:** 2026-11-21 · `1f5cc337` · [S-048 scratch run](evidence/processor/W49.proc-s048-verify.md).
  Both intake routes accepted the PNG. Adding it twice created two rows and sent two OCR requests.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
- **Notes:** **Drift at the original trace.** The README described a recursive search while folder intake read one
  level (S-028). Since W47.ct-processor-intake, the picker and drag-and-drop both call `OCRView.admit`, which asks
  whether to read subfolders. W49.proc-s049-verify updated the README to describe that choice (S-049). The code
  accepts PDFs in every mode.

## Output

### P-23 · The two-page PDF

- **Promise:** each input image produces one PDF with the same base name: page 1 the oriented image, page 2 headed
  `Extracted text.` with `[Provider] · [Model] · [D Month YYYY]`, the text all on one page however long; no text →
  `No text returned by model.` and the reason (Gemini's `Recitation` shown clearly).
- **Promised in:** `README.md` §PDF Output; `CLAUDE.md` §OCR Output Format; `SPEC/tag-format.md` §2-page PDF
  structure; `TESTING.md` §2.4, §2.13.
- **Reached by:** every run: `OCR/OCRProcessor+OCR.swift:1599-1606` → `PDFGenerator().generate`: image page
  (`OCR/PDFGenerator.swift:53`), `makeTextPage` (`:255`; header and subheader `:259-285`; no-text body `:301-304`).
- **Real-path test:** `scripts/test-tier2.sh` with `scripts/tier2_assert.py:88-90` (two pages, page-2 header) — paid,
  live key. `scripts/test-dual-date.sh` covers the source-date lines. Not covered: the no-text body, Recitation,
  a long text on one page. (Reader's render guards read Processor's format, not this generator's output.)
- **Runtime evidence:** W40.d1, 2026-11-18: 113 two-page PDFs from the whole RG 165 box (OpenRouter, Qwen3.8 Flash), all with the
  sentinel and provenance line; the 18 that got a `Date evidence:` line have their source-name line changed (U+00A0
  to a space) and a broken xref entry ([`evidence/processor/W40.d1-bulk-ocr.md`](evidence/processor/W40.d1-bulk-ocr.md)).
  Fixed by `W40.fix-processor-evidence-rewrite-name`, 2026-11-19: the same paid run again, 113 outputs, 10 with a
  `Date evidence:` line, every name line the file's (U+00A0 kept), qpdf 0 warnings, checker 0 failures (same evidence file).
  W40.d2, 2026-11-19: a class changed in a review (Box, Folder, Continuation) reaches the tags but not page 2, whose
  `Classification:` keeps the reader's proposal, in the per-page review and in Segment & Tag alike ([`evidence/processor/W40.d2-review-dialogs.md`](evidence/processor/W40.d2-review-dialogs.md)).
- **Status:** `broken` — `W40.fix-processor-review-classification-stale` (S3)
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
  - 2026-11-18 W40.d1 — `unproven` → `broken`: the date-evidence rewrite changes the source-name line on 18 of 113 outputs.
  - 2026-11-19 W40.d2 — stays `broken`: page 2's Classification is not rewritten after a review.
  - 2026-11-19 W40.fix-processor-evidence-rewrite-name — stays `broken` (W40.d2's defect): the source-name line and the
    xref entry are fixed, re-run on the whole box.

### P-24 · Multi-page documents merged into one PDF

- **Promise:** when enabled, continuation pages are merged with their document-start page into a single multi-page
  PDF.
- **Promised in:** `README.md` §Multi-Page Document Merging.
- **Reached by:** ⌘, → Merge multi-page documents (`Views/SettingsView.swift:940`) → `Views/OCRView.swift:1334` →
  `performDocumentMerging` (`OCR/OCRProcessor+Tagging.swift:1310`, from `OCR/OCRProcessor+Pipeline.swift:3191`) →
  `mergeDocumentPDFs` (`:1365`).
- **Real-path test:** `scripts/test-merge-safety.sh` (`Capture/MergeSafetyTestDriver.swift`) calls
  `performDocumentMerging`; `scripts/test-processfiles-tagwarn.sh` its bookkeeping. Not covered: the toggle, merging
  after a real segmentation.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
- **Notes:** the merged file is `<base>_merged.pdf`, and merge turns off the incremental skip
  (`OCR/OCRProcessor+Pipeline.swift:2696`); README says neither.

### P-25 · Rotation detected and corrected

- **Promise:** sideways or upside-down images are detected (locally by Vision, or by the LLM) and output PDFs always
  show them upright; folder photos orient by the folder tab.
- **Promised in:** `README.md` §Image Orientation Correction; `CLAUDE.md` Impl Map `RotationDetector`,
  `LLMRotationDetector`; `TESTING.md` §2.7.
- **Reached by:** ⌘, → Detect rotation (`Views/SettingsView.swift:853`) → `Views/OCRView.swift:1306` →
  `detectRotation` (`OCR/OCRProcessor+OCR.swift:1732`, defined `:1827`) → `RotationDetector` or
  `LLMRotationDetector` → `mergeRotation` (`:1856`) → `PDFGenerator.makeImagePage`. Folder-tab rule in the prompt
  (`OCR/OCRPrompt.swift:42`). The manual rotation pass: P-32.
- **Real-path test:** the manual pass only: `ReviewDialogsJourneyUITests` (W40.d2, VM).
- **Runtime evidence:** W40.d2, 2026-11-19: the Review rotation pass, 90° clicked on one photo, is baked into its
  PDF's page 1. In that run, all photos were proposed 0°. [Manual review evidence](evidence/processor/W40.d2-review-dialogs.md).
  On 2026-11-21, `MessageJourneyUITests.testComparativeVoteFailureLeavesSidewaysPageWithoutWarning`
  rendered a sideways image without a warning after a synthetic HTTP 500 in single-vote comparative mode.
  A usable synthetic vote turned the same image upright. [Independent VM reproduction](evidence/processor/W49.proc-suspects-messages-check.md).
- **Status:** `broken` — W49.proc-fix-s029 for S-029.
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
  - 2026-11-19 W40.d2 — stays `unproven`: the manual pass works by click; detection is unproven.
  - 2026-11-21 W49.proc-suspects-messages-check — S-029, see runtime evidence.
- **Notes:** The default agreement mode reports a failed cloud check when it needs a vote. Both comparative modes
  can fall back silently.

### P-26 · Run log and on-screen errors

- **Promise:** after a run a `.txt` log lists every file that produced no OCR text and why; the full error text is
  visible in the file pane; progress shows in real time.
- **Promised in:** `README.md` §Other Features; `CLAUDE.md` §Batch log file; `TESTING.md` §2.4, §2.13.
- **Reached by:** ⌘, → Write a processing log file (`Views/SettingsView.swift:831`, off by default `:75`) →
  `writeLogFile` (`OCR/OCRProcessor+Pipeline.swift:3396`) → `ArchiveProcessor_Log_<timestamp>.txt` (`:3443`). Row
  errors `Views/Shared/ProcessableItemRow.swift:213-217`; View text sheet `Views/OCRView+FileRowView.swift:149-151`.
- **Real-path test:** the Process Files folder intake and Start, with the run log enabled.
- **Runtime evidence:** [Independent VM reproduction](evidence/processor/W49.proc-suspects-messages-check.md) via
  `MessageJourneyUITests.testRunLogLosesOneOfTwoSameNamedFailures`. Folder intake and Start produced two
  failed same.jpg outputs in different folders. The status and run log counted one failure and the log
  showed one reason.
- **Status:** `broken` — W49.proc-fix-s030 for S-030.
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
  - 2026-11-21 W49.proc-suspects-messages-check — S-030, see runtime evidence.
- **Notes:** **Drift.** README, `CLAUDE.md` §Batch log file and `TESTING.md` §2.4 read as always-on; it is opt-in and
  off by default. Suspect `S-030`.

### P-27 · Per-segment JSON metadata

- **Promise:** optionally, each segment gets a JSON metadata file.
- **Promised in:** `README.md` §Document Segmentation & Tagging step 4; `CLAUDE.md` Impl Map `SegmentJSONBuilder`.
- **Reached by:** ⌘, → Export segment JSON metadata (`Views/SettingsView.swift:911`, on by default `:84`) →
  `Views/OCRView.swift:1356` → `writeSegmentJSON` (`OCR/OCRProcessor+Tagging.swift:622`, `:895`) →
  `SegmentJSONBuilder.buildData`. Live: `Capture/LiveCaptureProcessor.swift:1164`.
- **Real-path test:** `scripts/test-segment-json.sh` (builder byte-identity), `scripts/test-dual-date.sh` (W37 keys);
  `scripts/tier2_assert.py:93` checks the sidecar exists (paid). Nothing runs with the toggle off.
- **Runtime evidence:** W40.d1, 2026-11-18: every document start of the 113-photo run has its sidecar ([`evidence/processor/W40.d1-bulk-ocr.md`](evidence/processor/W40.d1-bulk-ocr.md)).
- **Status:** `works`
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
  - 2026-11-18 W40.d1 — `unproven` → `works`: the bulk run, toggle on (the default).
- **Notes:** ships on, though README says "optional". The two write sites disagree about box and folder segments:
  `:622` writes them with a label override, the late path (`:1174`) skips them.

### P-28 · Enclosure dates

- **Promise:** a page the OCR marks as an enclosure is related to its covering document; the cover's date is
  carried as `Sent With`, and the PDF header shows the source dates; JSON and resume round-trip it.
- **Promised in:** `SPEC/tag-format.md` §W37.dual-date; `CLAUDE.md` Impl Map `DocumentSegmenter.enclosureOf`,
  `DualDateTestDriver`.
- **Reached by:** no control: the OCR prompt asks for `[enclosure]` (`OCR/OCRPrompt.swift:25`, parsed `:103`) →
  `DocumentSegmenter.segment(enclosureFlags:)` (`Tagging/DocumentSegmenter.swift:16`, from
  `OCR/OCRProcessor+Tagging.swift:1322`) → `EnclosureDates.applySentWith` (`:1160`, `:1204`); JSON `:1302`. PDF
  source-date lines: `EnclosureDates.pdfSourceDates` (`Tagging/DocumentSegmenter.swift:210`), used only by Live
  Capture (`Capture/LiveCaptureProcessor.swift:1387-1399`).
- **Real-path test:** `scripts/test-dual-date.sh` (`DUAL_DATE_TEST=1`, `Capture/DualDateTestDriver.swift`): marker,
  relation, `Sent With`, JSON and resume round-trips, header lines. Not covered: a real OCR reply, the manual UI.
- **Runtime evidence:** 2026-11-21 · `d1ec616d` · [S-047 scratch run](evidence/processor/W49.proc-s047-verify.md).
  Agreement between OCR and the window kept the relation. A split dropped it. The separate dual-date
  driver verified the tag writer with a valid relation and with no relation.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
- **Notes:** **Drift.** The source-date header lines are written only in Live Capture; Process Files renders the PDF
  before tagging and does not rewrite it (`OCR/OCRProcessor+OCR.swift:1604`), as `SPEC/tag-format.md` §W37 itself
  says. The split-cover case is S-047.

## Segmentation and tagging

### P-29 · Every image classified

- **Promise:** every image is classified as Box Label, Folder Label, Document Start or Document Continuation;
  Mistral, which takes no prompt, classifies by text heuristics.
- **Promised in:** `README.md` §Document Classification; `CLAUDE.md` §Document Segmentation.
- **Reached by:** drop images → Start (`Views/OCRView.swift:773`, ⌘R `:364`) → `startProcessing` (`:1305`) →
  `performOCRCall` (`OCR/OCRProcessor+OCR.swift:1699`); classification is part of the OCR prompt
  (`OCR/OCRPrompt.swift:50`, parsed `:74`); Mistral uses `MistralClient.heuristicClassify`
  (`OCR/MistralClient.swift:60`).
- **Real-path test:** `scripts/test-tier2.sh` cases 03-04 (paid; ground truth only warns below 60%). Nothing
  exercises the Mistral heuristic.
- **Runtime evidence:** W40.d1, 2026-11-18: 110 of 113 photos classified, 97 as the truth has them; 3 replies that were not a
  reading kept as the page text with no classification and the job `succeeded` ([`evidence/processor/W40.d1-bulk-ocr.md`](evidence/processor/W40.d1-bulk-ocr.md)).
- **Status:** `fixed-pending-recheck` — `W40.fix-processor-non-reading-reply`: an OpenRouter or OpenAI reply with no
  classification line is now `unparsable` (`OCR/OpenAICompatibleClient.swift` `completedReply`), so the page fails and a
  cascade reads it again; stubbed in `scripts/test-ocr-cascade.sh`. Not yet rechecked on a real run.
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
  - 2026-11-18 W40.d1 — `unproven` → `broken`: a non-reading reply leaves the image unclassified and counted as succeeded.
  - 2026-11-19 W40.fix-processor-non-reading-reply — `broken` → `fixed-pending-recheck`.
- **Notes:** **Drift.** For pre-OCRed PDFs Mistral classifies with a `mistral-small-latest` chat call
  (`OCR/OCRProcessor+OCR.swift:614-615`), not heuristics. Apple Vision returns no classification
  (`OCR/VisionClient.swift:112-114`) unless its LLM judgement is on.

### P-30 · Choice of segmentation approach

- **Promise:** the user chooses how a run is segmented — manual, Claude, Gemini, ChatGPT, a mix, a model on this
  Mac — each shown with its rough accuracy, how much checking it leaves and its cost (dollars by API key, a share of
  the plan when run on a Claude or ChatGPT subscription).
- **Promised in:** `CLAUDE.md` Impl Map `Segmentation/` (`SegmentationApproach`, `SegmentationChooser`,
  `PlanUsage`, `ChatGPTPlanTransport`, `LocalSegmenter`); `SUITE_TODO_DONE.md` `W36.seg-decision`,
  `W36.seg-opt-chooser`, `W36.seg-opt-subscription`, `W36.seg-opt-siwc`, `W41.app-local-seg`, `W41.app-seg-default`.
- **Reached by:** the approach picker `ap.segmentation.picker` (`Views/SegmentationChooserView.swift:7`), in
  Process Files (`Views/OCRView.swift:539`) and Settings (`Views/SettingsView.swift:874`) → stored in
  `DefaultsKeys.segmentationApproach`, read at Start (`OCR/OCRProcessor+Pipeline.swift:297`); row text and cost
  `SegmentationRow.make` (`Segmentation/SegmentationChooser.swift`).
- **Real-path test:** `ArchiveProcessorUITests/ProcessorUITests.testSegmentationChooserShowsEachApproachWithFiguresAndCost`
  drives the real picker; `scripts/test-segmentation-chooser.sh` checks the figures. Not covered: the `glm` and
  `local` rows, plan-versus-key cost lines, the Gemini preselect.
- **Runtime evidence:** The [independent VM reproduction](evidence/processor/W49.proc-suspects-money-check.md)
  recorded three OpenAI OCR requests before the missing Gemini key appeared. The replacement Tart regression
  `MoneyJourneyUITests.testMissingGeminiSegmentationKeyBlocksStartBeforeAnyRead` sees the reason at Start,
  checks the disabled button and presses ⌘R with zero requests recorded. The accompanying eligibility test
  covers manual segmentation, No tagging and a pre-grouped photo handoff. The `W36.seg-opt-proof` record in
  `SUITE_TODO_DONE.md` ran the approaches end to end before this ledger.
- **Status:** `fixed-pending-recheck` — W49.proc-fix-s032 for S-032.
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
  - 2026-11-21 W49.proc-suspects-money-check — `broken` on the tested path.
  - 2026-11-22 W49.proc-fix-s032 — Start applies the selected window route's credential rules before reading.
- **Notes:** **Drift.** ChatGPT gets tokens and an approximate dollar figure, not a plan share
  (`Segmentation/SegmentationChooser.swift:253-257`); only Claude has a meter.

### P-31 · Flagged boundaries, then a skim

- **Promise:** with an automatic approach, the boxes and folders are confirmed, the run segments in windows, the
  uncertain boundaries are put to the user one by one (keep, split, join) and every one must be answered before
  Done; then a skim of the whole result; hitting a usage limit or error offers "check the rest myself" or stop, and
  the run resumes from the answered windows.
- **Promised in:** `CLAUDE.md` Impl Map `RunSegmentation`, `OCRProcessor+WindowSegmentation`;
  `SUITE_TODO_DONE.md` `W36.seg-opt-review`, `W36.seg-opt-proof`.
- **Reached by:** any approach but manual with a tagging mode, Start → `runWindowSegmentationStage`
  (`OCR/OCRProcessor+WindowSegmentation.swift:58`, from `OCR/OCRProcessor+Pipeline.swift:3098`; also resume and
  pre-OCRed): box/folder confirmation (`:62`), proposals (`:115`), flagged pass (`:83`), skim (`:104`). Done is
  disabled until every gap is answered (`Views/FlaggedBoundaryReviewSheet.swift:120-122`). Limit/error alert:
  `Views/OCRView.swift:1388-1403`.
- **Real-path test:** `scripts/test-segmentation-review.sh` (`Segmentation/SegmentationReviewTestDriver.swift`) calls
  the real stage on synthetic pages with recorded answers: confirmation, flagged pass, skim, resume, usage limit,
  Stop; renders no sheet. `ProcessorUITests.testFlaggedBoundaryPassNeedsEveryAnswerBeforeDone` drives the real sheet,
  opened by a seam (`_uiTestShowFlaggedReview`). `scripts/test-segmentation-proof.sh` is the paid real route.
- **Runtime evidence:** none in `verification/evidence/` (see P-30 on `W36.seg-opt-proof`).
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
- **Notes:** the confirmation lists only pages already classed box or folder and is skipped when there are none
  (`OCR/OCRProcessor+ReviewFlows.swift:500-515`). Flagged answers persist only after Done.

### P-32 · Per-page segmentation review dialog

- **Promise:** after OCR, a full-screen dialog shows every file as a thumbnail (size slider 60-800 px) with
  classification and rotation radio buttons and live preview; keys `1`-`4` set the class, `[`/`]` rotate, `↑`/`↓`
  move, Return confirms.
- **Promised in:** `README.md` §Segmentation Review, §Image Orientation Correction; `TESTING.md` §2.4, §2.6.
- **Reached by:** Start with a plan that shows it → `showFullSegmentationReview`
  (`OCR/OCRProcessor+ReviewFlows.swift:433`) → `.reviewWindow` (`Views/OCRView.swift:415`) →
  `DocumentSegmentReviewSheet`: slider 60-800 (`Views/OCRView+DocumentSegmentReviewSheet.swift:74`), keys 1-4
  (`:171-200`), arrows (`:150-157`), Return (`:216`).
- **Real-path test:** `ReviewDialogsJourneyUITests` (W40.d2, VM: `scripts/journey-review-dialogs.sh`), the real Start on
  six rehearsal photos: every key by itself as the window opens, after a row click and after a radio click, in both this
  dialog and the Review rotation pass; Escape asks; Return confirms. `scripts/test-segmentation-review.sh` waits on `awaitingDocumentReview` but
  never draws the sheet or sends keys.
- **Runtime evidence:** W40.d2, 2026-11-19: the dialog opens on every photo; the slider works; by click, Box, Continuation
  and the trash reach the output (the removed photo has no PDF, the Continuation carries its document's tags). The keys
  3, ↓, 2, X and Return changed nothing and did not confirm ([`evidence/processor/W40.d2-review-dialogs.md`](evidence/processor/W40.d2-review-dialogs.md)).
  W40.fix-processor-review-keys, 2026-11-20: the window is now focusable and focused on open, and a click in a row
  gives the keys back; in the VM 1-4, X, ↑/↓, ←/→, [ ], Escape and Return all acted, the footer counting each change.
  Paid-batch Resume skipped the whole-run page review and showed only the later per-collection page review. [Independent VM evidence](evidence/processor/W49.proc-suspects-filing-check.md).
- **Status:** `broken` — `W40.fix-processor-resume-reviews` (S2)
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
  - 2026-11-19 W40.d2 — `unproven` → `broken`: the promised keys do nothing; the clicks work.
  - 2026-11-20 W40.fix-processor-review-keys — `broken` → `works`: the keys reach the review (focus fix), journey-tested.
  - 2026-11-21 W49.proc-suspects-filing-check — `works` → `broken` on this path.
- **Notes:** **Drift.** The rotation radios and `[`/`]` are not in this dialog: they appear only in the separate,
  opt-in Review rotation pass (`rotationOnly`, `:15-16`, `:201-213`; enabled by `reviewRotation` with rotation on,
  `OCR/OCRProcessor+Pipeline.swift:3084`). Keys 1 and 2 work only when document classes are shown (`:171-181`). The
  Documents switch defaults on and controls the whole-run review on fresh runs with model-proposed boundaries
  (W49.proc-s046-review-toggle). The fresh pipeline still skips the later per-collection review. S-046
  [documents the earlier mismatch and its verification](evidence/processor/W49.proc-s046-verify.md).
  Ordinary Resume bypasses the whole-run review with either saved setting. A saved On opens the per-collection
  review after tagging ([S-050 VM evidence](evidence/processor/W49.proc-s050-verify.md)).

### P-33 · Generated tags

- **Promise:** each segment gets a year tag and an `MM Month` tag (`Date Uncertain` and an estimated year when the
  date cannot be read; never an estimated month), 2-6 subject tags, its format, author and recipient.
- **Promised in:** `README.md` §Document Segmentation & Tagging; `CLAUDE.md` §Tags Applied to Each File;
  `TESTING.md` §2.4.
- **Reached by:** Automatic mode, Start → `performAutomaticTaggingWithReview` (`OCR/OCRProcessor+Pipeline.swift:3129`)
  → `performTaggingPhase` (`OCR/OCRProcessor+Tagging.swift:1028`) → `TagGenerator.generateTags`
  (`Tagging/TagGenerator.swift:8`) → `GeneratedTags.allTags` (`packages/ArchiveCore/Sources/ArchiveCore/Tags/GeneratedTags.swift:77`).
- **Real-path test:** `scripts/test-tier2.sh` cases 03-05 with `scripts/tier2_assert.py:113-121` (paid; month and
  subject count only warn). ArchiveCore `GeneratedTagsTests` covers ordering. Nothing covers the prompt or the
  reply parse.
- **Runtime evidence:** W40.d1, 2026-11-18: 62 segments tagged; every document has a year or `Date Uncertain`, one month at
  most in its exact form, and 2-6 subjects ([`evidence/processor/W40.d1-bulk-ocr.md`](evidence/processor/W40.d1-bulk-ocr.md)).
- **Status:** `works`
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
  - 2026-11-18 W40.d1 — `unproven` → `works`: Automatic tagging on the whole box (S-042, the failed-call path, stays open).
  - 2026-11-20 W49.proc-fix-s042 — the failed-call path: a call that fails is named in the status line and the log,
    not counted as tagged (`scripts/test-tagging-failure.sh`; the W40.d1 cap test and a stand-in 500 in the VM). S-042
    cleared; Live Capture's same path is S-045.
  - 2026-11-21 W49.proc-s045-verify — in Live Capture an injected HTTP 500 filed a PDF with OCR and the phone
    date but no model subjects. The row and Finish summary showed success without a warning.
    [Evidence](evidence/processor/W49.proc-s045-verify.md). Independent check queued as `W49.proc-s045-check`.
- **Notes:** "never an estimated month" and "2-6 subjects" are prompt rules only (`Tagging/TagGenerator.swift:61`,
  `:64`); code enforces only the cap of 6 (`Tagging/ControlledVocabulary.swift:14`). Suspect `S-033`.

### P-34 · Finder tags written: colour and `Unread` last

- **Promise:** outputs get their tags as macOS Finder tags; boxes are Red, folders Purple (never promoted from a
  subject string); in real-tagging modes `Unread` is appended once, last, on every PDF and exported image; a failed
  tag read is never written over as empty.
- **Promised in:** `README.md` §Document Segmentation & Tagging step 3; `CLAUDE.md` §Special tags; `SPEC/tag-format.md`
  §Invariants 3, 5, 6, 7; `TESTING.md` §2.4.
- **Reached by:** Start with a tagging mode → `tagOutput` (`OCR/OCRProcessor+Tagging.swift:170`) →
  `writeOutputTags` → `MacOSTagger.applyTags` (`Tagging/MacOSTagger.swift:75`; `Unread` last `:134`; copy-source
  verbatim `:88-91`) → ArchiveCore `CoordinatedTagWriter`.
- **Real-path test:** `scripts/test-tag-vocabulary.sh` compiles the real `MacOSTagger.swift`: box gets Red and a
  trailing `Unread`, a "Red Scare" subject stays a subject, copy-source is verbatim, a missing file throws.
  `scripts/test-processfiles-tagwarn.sh` covers `writeOutputTags`, a refused write and the colour helpers.
  `scripts/test-tier2.sh` + `tier2_assert.py:103-111` checks a whole run (paid).
- **Runtime evidence:** Live Capture: `W40.a3-phone-e2e.md` (`evidence/capture/W40.a3-phone-e2e.md`). Process Files: W40.d1,
  2026-11-18, 113 outputs: tag xattrs equal the guest's reading byte for byte, `Unread` once and last, label photos
  their `Box`/`Folder` token and no colour ([`evidence/processor/W40.d1-bulk-ocr.md`](evidence/processor/W40.d1-bulk-ocr.md)).
- **Status:** `works`
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
  - 2026-11-18 W40.d1 — `unproven` → `works` for Process Files. The promise's Red and Purple are drift (the SPEC dropped them with W40.suite-item-types).
- **Notes:** ArchiveCore `MacOSTaggerParityTests` tests a copy of the transform, not the Processor adapter, so it is
  not a real-path test.

### P-35 · Tagging modes

- **Promise:** Automatic, Auto date, Human, No tagging and Copy source tags each behave as named: No tagging writes no
  tags and no `Unread`; Copy source passes the source file's tags through verbatim with no `Unread`.
- **Promised in:** `CLAUDE.md` §Special tags; `README.md` §Other Features (source tag pass-through); `SPEC/tag-format.md`
  §Invariant 6; `TESTING.md` §2.5.
- **Reached by:** the Tagging picker (`Views/OCRView.swift:516-521`, also `Views/SettingsView.swift:882`) →
  `processor.taggingMode`; copy-source sets `passSourceTags` (`Views/OCRView.swift:37`); `stampsUnread`
  (`Models/ProviderModels.swift:122`).
- **Real-path test:** `scripts/test-tier2.sh` cases 01-02 (`none`, `copySource`; paid) with `tier2_assert.py:97-102`;
  `scripts/test-tag-vocabulary.sh` (copy-source verbatim). The independent VM journey selects both modes and reads
  the tags of the filed PDFs. Auto date and Human have no headless run
  (`Capture/ProcessFilesTestDriver.swift:124` refuses them); `ReviewDialogsJourneyUITests` runs Human (W40.d2, VM).
- **Runtime evidence:** W40.d2, 2026-11-19: Human with the Manual approach writes only the typed tags and `Unread` ([`evidence/processor/W40.d2-review-dialogs.md`](evidence/processor/W40.d2-review-dialogs.md)).
  Automatic: W40.d1. Auto date remains unproven.
  With Collection ID on, No tagging wrote Box and Folder markers. Copy source file tags wrote those markers but removed both source Finder tags from the label PDFs. All four other PDFs kept both tags. [Independent VM evidence](evidence/processor/W49.proc-suspects-filing-check.md).
  W40.fix-processor-copy-label-tags, 2026-11-23: in the same VM journey, No tagging produced the two
  label markers and four untagged document PDFs. Copy source file tags preserved both source tags
  on all six PDFs and added the respective marker to each label. The input copies kept their tags
  in both runs.
- **Status:** `fixed-pending-recheck` — W40.fix-processor-copy-label-tags (S-034).
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
  - 2026-11-19 W40.d2 — stays `unproven`: Human and Automatic shown, the other three not.
  - 2026-11-21 W49.proc-suspects-filing-check — `unproven` → `broken` on this path.
  - 2026-11-23 W40.fix-processor-copy-label-tags — `fixed-pending-recheck`. SPEC invariant 6 records
    owner call 30's label-marker exception.
- **Notes:** **Drift.** `TESTING.md` §2.5 still names "Auto date + manual seg", folded into Auto date by
  `W36.seg-opt-review`.

### P-36 · Controlled vocabulary

- **Promise:** a subject vocabulary can be typed one per line or imported from CSV (button or drop); when set, the
  LLM may choose only from it.
- **Promised in:** `README.md` §Custom Tag Vocabularies; `TESTING.md` Tier 2D `test-controlled-vocabulary.sh`.
- **Reached by:** ⌘, → Tagging, Automatic mode only (`Views/SettingsView.swift:924`): text box, Import from CSV…
  (`:930`), drop (`:936`) → `Views/OCRView.swift:1339` → prompt (`Tagging/TagGenerator.swift:64`) →
  `ControlledVocabulary.enforce` (`:189`).
- **Real-path test:** `scripts/test-controlled-vocabulary.sh` compiles the real `ControlledVocabulary.swift`. The CSV
  parser (`Views/SettingsView.swift:1105`, private) is untested.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
- **Notes:** a non-UTF-8 CSV is ignored silently (`:1106`).

### P-37 · Tagging review

- **Promise:** after tag generation the tags show in the file pane; double-clicking a file edits its
  classification; Redo tagging regenerates with the updated segmentation; Complete proceeds to collection
  organisation.
- **Promised in:** `README.md` §Tagging Review.
- **Reached by:** Automatic mode → `awaitingFinalReview` (`OCR/OCRProcessor+Tagging.swift:481`) → file pane tags
  (`Views/OCRView.swift:968`); double-click or Return → `SegmentationEditSheet` (`:978-981`, `:1027-1030`); Redo
  Segmentation & Tagging (`:863`) / Complete (`:868`) → `redoTagging` / `confirmFinalReview`
  (`OCR/OCRProcessor+ReviewFlows.swift:305-315`).
- **Real-path test:** `ReviewDialogsJourneyUITests` presses Complete (W40.d2, VM). `ProcessFilesTestDriver` answers the
  gate with `confirmFinalReview` and draws nothing.
- **Runtime evidence:** W40.d2, 2026-11-19: the review shows each file's class, rotation and tags and the segment list;
  Complete finishes the run ([`evidence/processor/W40.d2-review-dialogs.md`](evidence/processor/W40.d2-review-dialogs.md)). Redo and the double-click edit sheet were not driven.
  Automatic paid-batch Resume filed tagged PDFs without displaying final tagging review. [Independent VM evidence](evidence/processor/W49.proc-suspects-filing-check.md).
- **Status:** `broken` — `W40.fix-processor-resume-reviews` (S2)
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
  - 2026-11-19 W40.d2 — stays `unproven`: Complete works; Redo and the edit sheet unproven.
  - 2026-11-21 W49.proc-suspects-filing-check — `unproven` → `broken` on this path.
- **Notes:** the button is "Redo Segmentation & Tagging"; it rebuilds segments from the edited classifications
  (`OCR/OCRProcessor+Tagging.swift:493-497`). This review applies to Automatic. Call 30 requires it on paid-batch
  Resume unless explicitly skipped (S-035). Ordinary Resume still opens the final
  tagging review ([S-050 VM evidence](evidence/processor/W49.proc-s050-verify.md)).

### P-38 · Manual per-segment tagging

- **Promise:** in the human and manual-segmentation modes, the user segments and tags each segment in turn, with
  subject autocomplete from existing tags.
- **Promised in:** `CLAUDE.md` Impl Map `ManualTaggingSheet`, `ManualSegmentTagView`, `SystemTagsProvider`;
  `TESTING.md` §2.5 (Human).
- **Reached by:** Human or Auto date with approach Manual → `performManualSegmentAndTag`
  (`OCR/OCRProcessor+Tagging.swift:724`, from `OCR/OCRProcessor+Pipeline.swift:3137`) → `ManualSegmentTagView`
  (`Views/OCRView.swift:424`; autocomplete `Views/ManualSegmentTagView.swift:463`). With a proposing approach, or
  Live Capture Auto date groups → `performManualTaggingPhase` (`OCR/OCRProcessor+Tagging.swift:503`) →
  `ManualTaggingSheet` (`Views/OCRView.swift:421`).
- **Real-path test:** `ReviewDialogsJourneyUITests` run B drives Segment & Tag (W40.d2, VM). `ManualTaggingSheet`: none
  here (the Live Capture tag cards, W40.d5, are the nearest).
- **Runtime evidence:** W40.d2, 2026-11-19: B, F, X, → and Return on the canvas; two documents tagged by typing a date, a
  subject and a quality; every output carries exactly its own document's tags in the SPEC's tokens ([`evidence/processor/W40.d2-review-dialogs.md`](evidence/processor/W40.d2-review-dialogs.md)).
  Autocomplete was not exercised.
- **Status:** `works` (Segment & Tag)
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
  - 2026-11-19 W40.d2 — `unproven` → `works` for Segment & Tag; `ManualTaggingSheet` and autocomplete still unproven.

### P-39 · Collections identified, named and numbered

- **Promise:** with collection segmentation on, collection names are read from box-label text, similar names are
  clustered and title-cased, the user reviews and corrects them, and output PDFs are filed into collection folders
  as `000001 Collection Name.pdf` (continuing past an older folder's five-digit names), never overwriting an existing file.
- **Promised in:** `README.md` §Collection Segmentation & Organization, §Collection Name Review; `CLAUDE.md`
  Tier-2 list (collection numbering); `TESTING.md` Tier 2D `test-collection-organize.sh`.
- **Reached by:** ⌘, → Collection ID + file renaming (`Views/SettingsView.swift:889`) → `performCollectionSegmentation`
  (`OCR/OCRProcessor+ReviewFlows.swift:64`) → `CollectionSegmenter.segment` (`Tagging/CollectionSegmenter.swift:21`;
  LLM clustering `:167`, fallback `:239`, `normalizeCollectionName` `:259`) → `CollectionReviewSheet`
  (`Views/OCRView.swift:380`) → `organizeOutput` (`Tagging/CollectionSegmenter.swift:298`) →
  `CollectionNumbering.highestLeadingNumber` (`Capture/CollectionNumbering.swift:11`).
- **Real-path test:** `scripts/test-collection-organize.sh` (`Capture/CollectionOrganizeTestDriver.swift`) runs the real
  `organizeOutput` on synthetic files: numbering, no overwrite, merged output. The independent VM journey
  clicks Confirm and Organize after editing a live collection name. It uses stand-in names.
- **Runtime evidence:** Confirm and Organize used the typed box name. A parent component placed six PDFs outside the selected output folder, a separator nested them, and a blank filed them loose. [Independent VM evidence](evidence/processor/W49.proc-suspects-filing-check.md).
- **Status:** `broken` — `W40.fix-processor-collection-name-filing` (S1)
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
  - 2026-11-21 W49.proc-suspects-filing-check — `unproven` → `broken` on this path.
- **Notes:** the name review is opt-in (`confirmCollectionIDs` defaults to false, `Views/SettingsView.swift:82`),
  though README calls it the final step. S-036 reproduces when clicking the button without submitting the field.

### P-40 · Box and folder confirmation

- **Promise:** before segmentation proceeds, every box and folder identification is shown to be confirmed or
  reclassified.
- **Promised in:** `CLAUDE.md` Impl Map `BoxFolderConfirmSheet`, `RunSegmentation`.
- **Reached by:** Start → `showBoxFolderConfirmation` (`OCR/OCRProcessor+ReviewFlows.swift:495`; from the per-page
  path `OCR/OCRProcessor+Pipeline.swift:3110`, the window stage `OCR/OCRProcessor+WindowSegmentation.swift:62`,
  pre-OCRed `OCR/OCRProcessor+OCR.swift:181`) → `BoxFolderConfirmSheet` (`Views/OCRView.swift:418`).
- **Real-path test:** `ReviewDialogsJourneyUITests` drives the sheet after the per-page review (W40.d2, VM).
  `scripts/test-segmentation-review.sh` covers it as the window stage's first step.
- **Runtime evidence:** W40.d2, 2026-11-19: two photos marked Box in the review arrive as Box; the second, turned to
  Folder by its radio, carries `Folder` and no `Box` ([`evidence/processor/W40.d2-review-dialogs.md`](evidence/processor/W40.d2-review-dialogs.md)). Page 2 does not follow (P-23).
  Paid-batch Resume omitted the label confirmation with both a box and a folder in the saved batch. [Independent VM evidence](evidence/processor/W49.proc-suspects-filing-check.md).
- **Status:** `broken` — `W40.fix-processor-resume-reviews` (S2)
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
  - 2026-11-18 W40.d1 — stays `unproven`: the headless driver answers the gate with no sheet drawn; `W40.d2` drives the dialogs.
  - 2026-11-19 W40.d2 — `unproven` → `works` on the per-page path (tags; page 2 is P-23's defect).
  - 2026-11-21 W49.proc-suspects-filing-check — `works` → `broken` on this path.
- **Notes:** it lists only pages already classed box or folder, so a box photo misread as a document is caught only
  by the per-page dialog. Skipped in the manual window, for Live Capture pre-grouped runs and in a resumed batch
  (S-035). A resumed ordinary Automatic + Full manual run also skips it, even with both label types
  saved ([S-050 VM evidence](evidence/processor/W49.proc-s050-verify.md)).

## Tools

### P-41 · Compare Models

- **Promise:** one image is run through several provider/model combinations side by side with differences
  highlighted, and a model can be adopted from the results.
- **Promised in:** `README.md` §Tools tab; `CLAUDE.md` §Settings & Tools; `TESTING.md` §2.12.
- **Reached by:** Tools tab (`ContentView.swift:138`) → Compare Models… (`Views/ToolsView.swift:68-75`) → image drop
  (`:131-135`) → `runModelTest` (`:210`) → `performResolutionTestCall` (`OCR/OCRProcessor+OCR.swift:1938`) →
  `ModelTestResultsSheet` (Highlight differences, Use: `Views/OCRView+ModelTestResultsSheet.swift:32`, `:123`) →
  `ModelSelectionStore.saveModel` (`Views/ToolsView.swift:152-163`).
- **Real-path test:** none. No UITest opens the Tools tab.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
- **Notes:** Compare Models ignores a gateway or Local Agent configuration (`Views/ToolsView.swift:214-223`).

### P-42 · Test Resolution

- **Promise:** one image is OCRed at 10-100% resolution to show the accuracy/cost trade-off, and a resolution can be
  adopted.
- **Promised in:** `README.md` §Tools tab; `CLAUDE.md` §Settings & Tools; `TESTING.md` §2.12.
- **Reached by:** Tools tab → Test Resolution… (`Views/ToolsView.swift:77-84`) → drop sheet (`:117-122`) →
  `runResolutionTest` (`:182`) at 10, 20, 40, 60, 80, 100% → `ResolutionTestSheet`
  (`Views/OCRView+ResolutionTestSheet.swift:92-103`) → adopt writes `imageResolutionPercent`
  (`Views/ToolsView.swift:128-131`).
- **Real-path test:** none.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
- **Notes:** **Drift.** No cost is shown: the sheet gives text, a similarity badge and a word diff. README and
  `TESTING.md` §2.12 promise the cost trade-off. Six fixed points, not a continuous 10-100%. The button is disabled
  without an API key (`:82`), so it cannot be used with Apple Vision.

## Live Capture — the Mac side

### P-43 · Pairing by QR

- **Promise:** the Live Capture tab shows one QR (host, port, token, name, and a relay code when signed in to Drive);
  the token and port persist across Mac restarts; the QR hides once a phone pairs; a phone's Re-pair makes the Mac
  show it again. Pairing is QR-only, no discovery.
- **Promised in:** `README.md` §Live Capture (Pairing); `CLAUDE.md` §Pairing + connect flow; `LIVE_CAPTURE_ANDROID_TEST.md`
  A1, A5.
- **Reached by:** Live Capture tab → Start (`Views/LiveCaptureView.swift:201`) → `CaptureSession.start()`
  (`Capture/CaptureSession.swift:503`) → `server.start()` (`:512`). QR box `Views/LiveCaptureView.swift:312` from
  `pairingPayload` (`:372-381`); hidden on phone contact (`Capture/CaptureSession.swift:197-202`); Show QR (`:306`
  of the view); a phone Re-pair (`Net/CaptureServer.swift:582`) → `phoneDidDisconnect`
  (`Capture/CaptureSession.swift:252`) shows it again.
- **Real-path test:** none. The E2E and USB probe read port and token from the headless READY line.
- **Runtime evidence:** none (`W40.a3-phone-e2e.md` paired by manual entry, not a scan).
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
- **Notes:** the pinned port 48627 (`Net/CaptureServer.swift:53`) silently falls back to a system port when busy
  (`:106-111`), so "persists" is conditional. Bonjour is still advertised (`:72`) with no browser, as `CLAUDE.md`
  says. Suspect `S-037` (no QR at all without an en0/en1 IPv4), superseded by `W40.i-usb-mac`'s fix: the QR now
  shows whenever the server listens, with a fallback or empty host.

### P-44 · LAN receiver: durable before ack

- **Promise:** each photo is written to the manifest before the Mac acks it, and a resend of the same `(group, seq)`
  replaces rather than duplicates; routes need the bearer token (bad token 401, unknown route 404), with backoff on
  failed auth.
- **Promised in:** `CLAUDE.md` §Streaming + never-lose-a-photo, §LAN transport security, §Pairing (routes);
  `README.md` §Architecture; `LIVE_CAPTURE_ANDROID_TEST.md` C5, C6.
- **Reached by:** phone `POST /photo` → `Net/CaptureServer.swift:502` → `CaptureSession.ingest`
  (`Capture/CaptureSession.swift:595`; ack depends on the manifest write `:640`). Routes `Net/CaptureServer.swift:498-591`;
  auth and throttle `:172-199`, `:427-460`.
- **Real-path test:** `scripts/test-manifest-persistence.sh` (admission outcomes and manifest-write failure,
  `Capture/ManifestPersistenceTestDriver.swift:605-714`, `:786-850`); `scripts/test-recovery.sh` (a resend of the
  same `(group, seq)` gives one photo and no second OCR, `Capture/LiveCaptureRecoveryTestDriver.swift:777-797`).
  Both call Swift directly, not over HTTP; nothing exercises the auth backoff.
- **Runtime evidence:** partial. 2026-10-11 · `0511d85c` · [`evidence/capture/W40.a3-phone-e2e.md`](evidence/capture/W40.a3-phone-e2e.md):
  real `POST /photo` from the emulator ended in three PDFs. 2026-10-08 · `2154db2` ·
  [`evidence/processor/W40.d6-usb-transport.md`](evidence/processor/W40.d6-usb-transport.md): real `GET /ping` 200 with
  the token, 401 without. Ack order, resend, 404 and backoff were not shown.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
- **Notes:** backoff is a 429 after five free 401s, then 2-30 s exponential (`Net/CaptureServer.swift:427-460`); no
  guide states it.

### P-45 · USB tunnel (Android)

- **Promise:** the Mac keeps `adb reverse` asserted so a USB-tethered Android reaches the Mac at `127.0.0.1` with no
  shared Wi-Fi, re-asserting on replug and re-pair.
- **Promised in:** `README.md` §Live Capture; `CLAUDE.md` §USB local relay; `LIVE_CAPTURE_ANDROID_TEST.md` B1, B2.
- **Reached by:** Start (`Views/LiveCaptureView.swift:201`) → listener ready → `serverDidStart`
  (`Capture/CaptureSession.swift:549`) → `USBBridge.startReverse` (`:561`, `Net/USBBridge.swift:20`), re-asserted
  every 5 s; Re-pair → `reassertNow()` (`Capture/CaptureSession.swift:257`).
- **Real-path test:** `scripts/usb-reverse-probe.sh`: the real headless app with no device, then an emulator; the app
  creates the mapping, an in-device ping answers, and the app heals after `adb reverse --remove-all`. Not covered:
  the re-pair re-assert, a physical phone.
- **Runtime evidence:** 2026-10-08 · `2154db2` · [`evidence/processor/W40.d6-usb-transport.md`](evidence/processor/W40.d6-usb-transport.md)
  (+ `W40.d6-usb-probe-REPORT.txt`).
- **Status:** `works`
- **History:**
  - 2026-10-21 W40.b3 — row written; `works` for the Mac side and the tunnel, taken in from `W40.d6`'s evidence,
    which named this row before the ledger existed (README §Evidence).
- **Notes:** `works` covers the Mac and the tunnel on the emulator. A physical Android over a real cable is
  `unverifiable-here` (a phone with USB debugging and this Mac's adb key) and belongs to the capture ledger (`W40.b4`).
  `adb` outside the four fixed paths fails silently (`Net/USBBridge.swift:50-57`).

### P-46 · Google Drive cloud relay, Mac side

- **Promise:** once signed in to Google Drive (Settings › Live Capture, Desktop OAuth client), the Mac pulls the
  phone's objects from Drive during an active session, ingests them through the same pipeline, and deletes each
  object after a durable receipt.
- **Promised in:** `README.md` §Live Capture (Transports); `CLAUDE.md` §Google Drive cloud relay, §Cloud-relay OAuth
  setup; `SPEC/relay-object-format.md`.
- **Reached by:** ⌘, → Cloud relay (Google Drive) (`Views/SettingsView.swift:976`) → Sign in (`:994` →
  `signInToDrive` `:1024` → `DriveAuth.signIn`, `Net/DriveAuth.swift:65`); Start → `cloudRelay.start()`
  (`Capture/CaptureSession.swift:513-516`) → `FileRelayReceiver.scanOnce` (`Net/FileRelayReceiver.swift:125`) →
  `ingest`; receipt `:206`, delete `:207`.
- **Real-path test:** `scripts/test-filerelay.sh` drives the receiver over a local directory store;
  `ProcessorUITests.testFileRelayQuarantinesEmptyGroupInVM` the same in the VM; `scripts/test-drive-store.sh` the Drive
  store over a mock (but see Notes); `scripts/test-drive-live.sh` the real Drive (owner-gated).
- **Runtime evidence:** none. `W40.a3-relay-golden.md` shows format parity, not a pull from Drive. `CLAUDE.md` says the
  Mac side is "live-validated" (2026-07-07); there is no evidence file for it.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
  - 2026-10-21 W40.fix-drive-script-path — both scripts' path fixed; the mock test passes 10/10 and runs in the health
    gate as `drive-store` ([`evidence/processor/W40.fix-drive-script-path.md`](evidence/processor/W40.fix-drive-script-path.md)).
    Still `unproven`: a mock pass is not a pull from Drive.
- **Notes:** (fixed 2026-10-21, history above) `scripts/test-drive-store.sh:10` and `scripts/test-drive-live.sh:16` compile from
  `$REPO/ArchiveProcessor/Sources/ArchiveProcessor/Net`, where `$REPO` is already `ArchiveProcessor/` — a path that
  does not exist since the de-nest. **Reproduced** 2026-10-21: the script fails at `swiftc` with "error opening input
  file" ([`evidence/processor/W40.b3-drive-store-path.md`](evidence/processor/W40.b3-drive-store-path.md)), so the Drive
  store has no runnable mock test; filed `W40.fix-drive-script-path` (S3). The row is not `broken`: the feature
  itself was not shown failing. A sign-in after Start takes effect only at the next Start
  (owner-accepted, `CLAUDE.md` §Pairing).

### P-47 · Tag card per completed segment

- **Promise:** each completed segment pops an auto-advancing tag card: subject tags with autocomplete from existing
  tags, the phone's date and 0-3 Quality editable (0 writes no tag, 1-3 write `Q1`-`Q3`), fully keyboard-driven.
- **Promised in:** `README.md` §Live Capture (On the Mac); `CLAUDE.md` §On the Mac, §On the phone (Quality);
  `LIVE_CAPTURE_ANDROID_TEST.md` A4.
- **Reached by:** phone End segment → `POST /segment/complete` (`Net/CaptureServer.swift:543`; relay object
  `Net/FileRelayReceiver.swift:229`) → `markSegmentComplete` (`Capture/CaptureSession.swift:839`) → `pendingTagGroup`
  → sheet (`Views/LiveCaptureView.swift:114-121`) → `SegmentTagCard` (`:897`) → Save (`:1109`) / Skip (`:1118`) →
  `applyMacTags` / `skipMacTags` (`Capture/CaptureSession.swift:917`, `:936`).
- **Real-path test:** `PROCESSOR_JOURNEY=livecapture ops/gui/vm-gui-runner.sh processor xcuitest` (`LiveCaptureJourneyUITests`, real companion on a headless AVD; W40.d5) fills, skips and saves cards by hand. Also `scripts/test-manifest-persistence.sh`
  (persistence and rollback on a failed Save); `scripts/test-recovery.sh` (phone Q3, card 0 writes no tag, copy-source
  quality).
- **Runtime evidence:** 2026-10-21 · W40.d5 · [`evidence/processor/W40.d5-live-capture.md`](evidence/processor/W40.d5-live-capture.md): with Copy source file tags, the typed subject, typed year and
  picked Q2 landed as `W40d5 Dean Alpha`, `1973`, `Q2` on their PDF, a skipped card's PDF carried none. With Apple
  Vision's default No tagging the same card values were written nowhere. 2026-10-29 · W40.fix-live-vision-drops-card-tags
  · same file, run 6: in the default No tagging the same cards gave `1973`, `W40d5 Dean Alpha`, `Q2` / none /
  `W40d5 Dean Bravo`, with no Unread and no colour.
- **Status:** `works`.
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
  - 2026-10-21 W40.d5 — `broken`: works in Copy source mode, the card's tags are dropped in No tagging.
  - 2026-10-29 W40.fix-live-vision-drops-card-tags — `works`: No tagging writes what a person set, never a generated tag.
- **Notes:** **Drift.** "Fully keyboard-driven": ⏎ on an empty field saves (`Views/LiveCaptureView.swift:1086-1089`),
  but Skip has no keyboard route and esc only clears the draft (`:1102-1107`). S-021 (Android relay) can stop a card
  appearing.

### P-48 · Finish waits for the phone to drain

- **Promise:** Finish shows "phone still has N to send" and holds finalize until the phone's heartbeat reports
  nothing pending, so no segment finalizes partial.
- **Promised in:** `CLAUDE.md` §On the Mac; `LIVE_CAPTURE_ANDROID_TEST.md` A6.
- **Reached by:** `CaptureServer` receives `POST /phone/status` and calls `CaptureSession.updatePhonePending`.
  `LiveCaptureView` calls `LiveCaptureProcessor.requestFinish`, then `proceedToFinishIfReady` gates `finishSession`.
- **Real-path test:** `scripts/test-recovery.sh` holds Finish while `updatePhonePending(1)` is fresh and releases it on
  0 (`Capture/LiveCaptureRecoveryTestDriver.swift:2652-2701`); direct calls, nothing rendered.
- **Runtime evidence:** the `W40.a3` E2E finished through `requestFinish`. The [independent relay run](evidence/processor/W49.relay-suspects-check.md) filed one of two photos and kept the late arrival in Backup.
- **Status:** `broken` — W49.proc-fix-s038 (S2) for relay drain.
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
  - 2026-11-21 W49.relay-suspects-check — independently confirmed S-038. Fix queued as `W49.proc-fix-s038`.
- **Notes:** a phone silent for 20 s stops blocking Finish (`CaptureSession.phonePendingActive`).
  The Drive relay carries no heartbeat, so its drain gate has no pending count from the start.

### P-49 · The backup folder and recovery

- **Promise:** every received photo, and in `_processed/` every staged PDF/JPG/JSON with tags, is kept in
  `~/Pictures/Archive Processor Live Capture/<session>/` until finalize confirms the destination has it; a Backup
  Folder button reveals it; a source is deleted only after its output is confirmed at the destination, and only to
  the Trash.
- **Promised in:** `CLAUDE.md` §Recovery Core Directive, §Backup folder; `README.md` §Live Capture (Backup folder);
  `LIVE_CAPTURE_ANDROID_TEST.md` C4.
- **Reached by:** Backup Folder button (`Views/LiveCaptureView.swift:180-184`) → `revealBackupFolder`
  (`Capture/CaptureSession.swift:793`); every photo written by `ingest` (`:610-616`); staging in `_processed`
  (`Capture/LiveCaptureProcessor.swift:395-397`); `finalize` (`:1998`) → `executePlans` (`:2316`) →
  `sourcesSafeToRetire` (`:2420`) → `clearFiled` (`:2154`) → `trashOrRemove` (`Capture/CaptureSession.swift:376`).
- **Real-path test:** `scripts/test-recovery.sh` (confirm-before-delete, Trash not remove, placeholder sources held,
  stragglers; `Capture/LiveCaptureRecoveryTestDriver.swift:164-404`, `:634-735`). Direct calls; the reveal button is
  untested.
- **Runtime evidence:** 2026-10-21 · W40.d5 · [`evidence/processor/W40.d5-live-capture.md`](evidence/processor/W40.d5-live-capture.md): after a hand-driven finalize every original and `_processed`
  reached `~/.Trash` 8 s after the last PDF was on disk (guest `stat`: PDFs …928/…964/…020, Trash ctime …028), the
  session folder kept only `manifest.json`; with the output folder read-only nothing filed and both originals stayed.
  The Backup Folder button was not pressed, so the row stays `unproven` on that part alone.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
  - 2026-10-21 W40.d5 — Trash ordering and keep-on-failure shown; the reveal button not.
- **Notes:** in Stage for later nothing ever retires the backup photos (the only `clearFiled` caller is the live
  finalize), so they stay until a manual Clear. Safe, but not "until the run's output is finalized".

### P-50 · Stage for later

- **Promise:** in Stage for later mode captures collect in Live Capture and are sent to Process Files for a normal
  batch run.
- **Promised in:** `README.md` §Live Capture (Two processing modes); `CLAUDE.md` §Two processing modes;
  `LIVE_CAPTURE_ANDROID_TEST.md` B3.
- **Reached by:** ⌘, → When capturing (`Views/SettingsView.swift:961`, default stage `:90`) → Process N →
  (`Views/LiveCaptureView.swift:576`) → `stageForProcessing` (`:721`) → `orderedFilesAndGroups`
  (`Capture/CaptureSession.swift:948`) → `onProcess` (`ContentView.swift:136`) → `Views/OCRView.swift:317-343`.
- **Real-path test:** `PROCESSOR_JOURNEY=livecapture ops/gui/vm-gui-runner.sh processor xcuitest` (`LiveCaptureJourneyUITests`, real companion on a headless AVD; W40.d5), stage phase (clicks Process N → and checks Process Files has the photos);
  `Capture/LiveCaptureRecoveryTestDriver.swift:3927`, `:4015` check the filtering in `orderedFilesAndGroups`.
- **Runtime evidence:** 2026-10-21 · W40.d5 · [`evidence/processor/W40.d5-live-capture.md`](evidence/processor/W40.d5-live-capture.md): two photos from the phone, "Process 2 →", Process Files listed both
  with the session's tagging mode and the cost line.
  Two scratch photos were offered again after processing and after relaunch. Each produced two OCR requests. [Independent VM evidence](evidence/processor/W49.proc-suspects-money-check.md).
- **Status:** `broken` — W49.proc-fix-s039 (S2) for repeat handoff after completing processing.
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
  - 2026-10-21 W40.d5 — `works`.
  - 2026-11-21 W49.proc-suspects-money-check — `broken` on the tested path.
- **Notes:** handing off the files itself sends zero OCR requests. Repeating Start reads the same originals again.

### P-51 · Process live

- **Promise:** in Process live mode each segment is OCRed on arrival, tagged, made into a PDF and a renamed copy of
  the original image, merged if multi-page and staged while shooting continues; at Finish the user confirms each
  collection's name (suggested from the box label, fuzzy-matched to existing folders to append), and new files
  continue the folder's numbering.
- **Promised in:** `README.md` §Live Capture (Two processing modes); `CLAUDE.md` §Two processing modes;
  `LIVE_CAPTURE_ANDROID_TEST.md` A6.
- **Reached by:** `ingest` → `activateProcessingIfNeeded` (`Capture/CaptureSession.swift:228`, `:641`) →
  `photoIngested` (`Capture/LiveCaptureProcessor.swift:910`) → `finalizeSegment` (`:1097`) after the card
  (`segmentResolved` `:1033`). Finish → `beginFinalize` (`:1979`) → `CollectionFinalizeSheet`
  (`Views/LiveCaptureView.swift:123-125`); suggestions `candidateName` / `fuzzyMatches`
  (`Capture/LiveCaptureProcessor.swift:2664`, `:2684`); numbering `:2338`.
- **Real-path test:** `scripts/e2e-phone-mac.sh` (real OCR to finalize; auto-skips the card and auto-names the
  collection). `scripts/test-recovery.sh` numbering in a populated folder; `scripts/test-collection-organize.sh`
  merged-image filing. No test of merge on arrival or the box-label suggestion.
- **Runtime evidence:** partial. 2026-10-11 · `0511d85c` · [`evidence/capture/W40.a3-phone-e2e.md`](evidence/capture/W40.a3-phone-e2e.md):
  OCR on arrival, three tagged PDFs filed into one collection. The collection was auto-named, merge was off, rotation
  off, and only PDFs were asserted, so the name sheet, the fuzzy match, merging and the renamed image copies were not
  shown. 2026-10-21 · W40.d5 · [`evidence/processor/W40.d5-live-capture.md`](evidence/processor/W40.d5-live-capture.md): Apple Vision OCR on arrival, Finish by hand, the collection named in the sheet,
  three PDFs numbered 00001-00003; the fuzzy match, merging and numbering into an existing folder still not shown. A
  finalize that files nothing (read-only output) shows no message at all: `W40.fix-live-finalize-failure-silent` (S3).
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
  - 2026-10-21 W40.d5 — evidence added; still `unproven` (append, merge not shown).
- **Notes:** `similarity()` scores any substring match 0.9 with no minimum length
  (`Capture/LiveCaptureProcessor.swift:2693-2695`), so a folder named "A" ranks high for most names.

### P-52 · Live sessions survive a crash; failed segments retry

- **Promise:** a mid-session crash reloads the staging manifest and never re-OCRs a processed segment; each
  segment's failure reason shows in the Processing pane, which offers per-item retry, rotate-and-re-run, view text
  and reveal, plus a bulk Retry N failed; retries are refused while finishing.
- **Promised in:** `README.md` §Live Capture (Process live); `CLAUDE.md` §Shared per-item Processing pane;
  `LIVE_CAPTURE_ANDROID_TEST.md` C2.
- **Reached by:** relaunch → `CaptureSession.init` (`Capture/CaptureSession.swift:440`, `latestUnprocessedSession`
  `:1060`); staging manifest loaded in `LiveCaptureProcessor.activate` (`Capture/LiveCaptureProcessor.swift:499-536`).
  Retry: row actions (`Views/LiveCaptureView.swift:153-164`), bulk button (`:862`) → `retryFailed`
  (`Capture/LiveCaptureProcessor.swift:706`; `isFinalizing` guard `:760`).
- **Real-path test:** `scripts/test-recovery.sh` (resume rows failed and retryable, resume buys no OCR, retry buys one
  call, refusal while finalizing; `Capture/LiveCaptureRecoveryTestDriver.swift:3560-3640`, `:777-797`).
  `ProcessorUITests.testFinishingScrimBlocksLiveCaptureKeyboardAndAccessibilityRoutes` and
  `.testEmptyPaneClearNamesCountAndConfirmsSummaryLoss` cover the pane during and after a finish, not retry.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-21 W40.b3 — row written, `unproven`.
- **Notes:** after a relaunch the mode is undecided (`Capture/CaptureSession.swift:169`); the manifest reloads only on
  the next photo or when the user presses Process N →. README implies it reloads on its own.

### P-53 · An Appearance setting: System, Light or Dark

- **Promise:** Settings offers Appearance with System (the default, following macOS), Light and Dark; a choice
  changes every open window, sheet and panel at once and is restored at the next launch, before the first window.
- **Promised in:** `README.md` §Settings window; `SUITE_TODO.md` W48.appearance-processor (owner, 2026-10-29).
- **Reached by:** ⌘, → `Views/SettingsView.swift` `appearanceSection` (`@AppStorage(AppAppearance.defaultsKey)`) →
  `AppAppearance.follow()` (`Models/AppAppearance+AppKit.swift`; the value type and key are ArchiveCore's), called from
  `ArchiveProcessorApp.init` unless `-ArchiveUITestAppearance` forced a mode → `NSApplication.shared.appearance`.
- **Real-path test:** `AppearanceSettingUITests.testPickingLightAndDarkChangesOpenWindowsLiveAndSurvivesARelaunch`
  (picks Dark, Light, Dark with the History sheet and Settings open, checks each window's pixels, relaunches,
  picks System) and `.testTheUITestArgumentStillWinsOverTheStoredChoice`; the `…BySetting` variants of
  `AccessibilityAuditUITests` and `VisualReviewUITests.testTour*`; `ArchiveCoreTests/AppAppearanceTests` (value,
  default, titles).
- **Runtime evidence:** [`evidence/processor/W48.appearance-verify.md`](evidence/processor/W48.appearance-verify.md) (VM, `57596365`).
- **Status:** `works`
- **History:**
  - 2026-10-29 W48.appearance-processor — row written, `unproven`.
  - 2026-10-30 W48.appearance-processor — builder's VM runs green (AppearanceSettingUITests 2/2, whole suite 0 failures, the BySetting audit and tours); still `unproven` until W48.appearance-verify.
  - 2026-11-04 W48.appearance-verify — re-checked at HEAD in the VM by a session that did not build it: every promise holds, Light and Dark, by setting, with System seen under a Light and a Dark guest; the History sheet, the relaunch and the argument; audits and both tours pass. `works`: [`evidence/processor/W48.appearance-verify.md`](evidence/processor/W48.appearance-verify.md).

## Source drift — doc against doc, for `W40.b5`

- `TESTING.md` Tier 2D says the Processor has "no test target at all"; `project.yml` has the
  `ArchiveProcessorUITests` bundle, and `CLAUDE.md` §Visual / render verification says so.
- `TESTING.md` Tier 2B suggests "a handful from the 586 `*.pdf`" in `Test Files/`; `CLAUDE.md` §Test Files says the
  folder was slimmed to a minimum on 2026-07-18.
- `TESTING.md` §2.1 lists three providers and §2.5 the removed "Auto date + manual seg"; README lists four cloud
  providers; the code and `CLAUDE.md` have five plus Apple Vision (P-05, P-06, P-35).
- README §Previous-page image context names Gemini and Anthropic; the Settings help ties it to the per-page
  classifier plan (P-18).
- README §Automatic Retry still describes a retry "with a different provider/model/API key"; `CLAUDE.md`'s
  `W25.retry-backend` correction removed it (P-20).
- README §Image Orientation Correction and §Segmentation Review put rotation in the segmentation review; the code
  has a separate Review rotation pass (P-32).
- README says the guided Local Agent wizard covers Codex; `CLAUDE.md` says only `claude` is validated and the
  others are `VERIFY` placeholders (P-10).
- README §Tools tab and `CLAUDE.md` §Settings & Tools list two tools; the Tools tab also has a Processing History
  card (`Views/ToolsView.swift:86`).
- `CLAUDE.md` §Live Capture says the Drive relay's Mac side is "live-validated"; no evidence file records it (P-46).

