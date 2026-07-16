# Execution Plan — Local Agent CLI provider (subscription/enterprise auth, no API key)

- **Status:** proposed (not started)
- **Created:** 2026-07-10
- **App:** Archive Processor (`ArchiveProcessor/`)
- **Tracking:** `SUITE_TODO.md` → *Active execution plans*
- **Tier:** 2 (touches the OCR core + the run-config snapshot that crash-resume decodes)

---

## Why

Many academics have **enterprise Claude or Gemini accounts** that grant web/chat access but **no API key
and no API gateway** — the exact gap Processor's current provider paths (BYO Anthropic/Gemini/Mistral key,
or the OpenAI-compatible gateway) can't fill. But the capable vendors now ship **first-party CLIs that
authenticate against a subscription/entitlement rather than a metered API key**:

- **Claude Code** (`claude`) — logs in via OAuth against a Pro/Max, or Team/Enterprise subscription (the
  workspace admin enables Claude Code seats). Usage draws on the subscription's limits; no API key, no
  Console billing.
- **Gemini CLI** (`gemini`) — logs in with "Login with Google" and honors **Gemini Code Assist** licenses
  (incl. Standard/Enterprise).
- **OpenAI Codex CLI** (`codex`) — its **"Sign in with ChatGPT"** authenticates against a ChatGPT
  Plus/Pro/Team/Enterprise/**Edu** subscription rather than an API key; runs headless via `codex exec`.

All three run headless and accept image input, so Processor can drive OCR + tagging through the user's
existing entitlement. This path holds **no key** — auth lives entirely in each CLI's own login.

## Goal & scope

Add a **Local Agent CLI backend** that runs OCR, tagging, and document/collection segmentation by shelling
out to a locally installed, subscription-authenticated CLI. **Claude Code, Gemini CLI, and OpenAI Codex CLI
are all first-class targets** (none is conditional on the others).

**In scope:** Process Files + Live Capture OCR, tag generation, and segmentation via the CLI.

**Out of scope (v1 — mirrors the existing gateway path):** batch mode and LLM-based rotation are **skipped**
when this backend is active.

## Non-goals (deliberately excluded)

- **Manual / assisted paste-bridge** (export prompt+image, human pastes into their chat, pastes the reply
  back) — out of scope for this plan.
- **Browser / desktop-UI automation** of claude.ai / gemini.google.com or the desktop apps — violates both
  vendors' terms and risks getting the academic's institutional account suspended.
- **Bundled OpenAI-compatible sidecar** (see Design decision 1) — deferred.
- Batch + LLM-rotation on this path in v1.

---

## Design decision 1 — native subprocess vs. bundled sidecar → **native (chosen)**

| | **A. Native Swift `LocalAgentClient` (chosen)** | B. Local OpenAI-compatible sidecar (rejected) |
|---|---|---|
| Mechanism | Swift `Process` spawns `claude -p …` / `gemini …` / `codex exec …` | Bundle a Node/Python server wrapping the CLI/SDK that speaks OpenAI `/chat/completions` on `127.0.0.1`; reuse the existing gateway config |
| Pipeline changes | Small (see Design decision 2) | Zero — it's just a gateway pointing at localhost |
| Distribution | **Self-contained** — depends only on the CLI the user installed | Must bundle + sign a runtime; we own a translation shim |

**Rejected B** because bundling and signing a runtime complicates distribution (Processor is ad-hoc-signed,
unsandboxed) and saddles us with a translation shim to maintain. Native `Process` spawn is fine today
(unsandboxed); note it for any future App-Store path (deferred anyway).

**MVP = subprocess-per-call** (simple, correct, some per-call startup latency). A **persistent
`stream-json` session** to amortize CLI startup is a documented Phase 4 perf follow-up.

## Design decision 2 — how the backend rides the run config → **additive sibling optional (chosen)**

**Constraint (not a choice):** runs snapshot their settings (`PendingRun` / `PendingBatch` /
`SessionProcessingConfig`) so a crash-resume — or a mid-run settings change — continues with the settings
the run *started* with. The gateway already rides in that snapshot (`gatewayConfig: GatewayConfig?`,
threaded through the pipeline and Codable-persisted). The local-agent backend must be captured the same way,
so *some* plumbing is unavoidable. The only question is the shape of the carrier.

**Chosen — additive sibling optional:** leave `gatewayConfig: GatewayConfig?` **exactly** as-is (unchanged
type, unchanged persisted encoding) and thread a companion `localAgent: LocalAgentConfig?` (default `nil`)
alongside it. Construction sites prefer `localAgent` when set.

- **Why:** the change is **append-only** — old in-flight run snapshots decode byte-for-byte unchanged (the
  new optional is simply absent → `nil`). This aligns with the codified persistence invariant
  (`ProviderModels.swift` / `DefaultsKeys.swift`: "appending is safe; changing shape needs migration") and
  keeps the highest-consequence surface in this app — **crash-resume of an in-flight capture** — untouched.
- **Cost accepted:** two optionals where "both set" is a latent illegal state. Contained by (a) the
  mutually-exclusive Settings toggles (`useGateway` / `useLocalAgent`) and (b) a one-line precedence check
  at the ~3–4 client-construction sites. Also slightly more forwarding edits than the rejected enum (the
  companion value must be threaded wherever `gatewayConfig` is), but all mechanical and compiler-checked.

**Rejected alternative — enum-widen** `gatewayConfig: GatewayConfig?` → `backend: ExternalBackend?`
(`.gateway | .localAgent`): a cleaner single "external backend" concept that makes the both-set state
unrepresentable and scales to more backends — **but its only real cost lands squarely on the resume-critical
Codable shape**, forcing a back-compat decoder on the exact path we most protect. The external-backend set
is small (gateway, local-agent, maybe the deferred sidecar — a native OpenAI provider would be a first-class
`LLMProvider` case, not this seam), so the enum's extensibility win doesn't justify touching resume decoding.

---

## Integration surface (the seam)

Every provider reduces to two operations, both already abstracted:

- **Image OCR** — `AnthropicClient.ocr()` / `GeminiClient` / `OpenAICompatibleClient.ocr()`: take a JPEG →
  prompt+image → parse the reply via `OCRPrompt.parseResponse` → `OCRResult`.
- **Text completion** — `LLMTextClient.complete()` (tagging/segmentation), and
  `OpenAICompatibleClient.textCompletion()`.

The gateway path is selected at ~3–4 construction sites (`LLMTextClient.swift` early-return;
`OCRProcessor+OCR.swift` `classifyCallGateway` + the OCR branch) and its `GatewayConfig?` is threaded through
~30 call sites across `OCRProcessor+{OCR,Pipeline,Tagging,ReviewFlows}.swift`, `LiveCaptureProcessor.swift`,
and `LLMRotationDetector.swift`. The local-agent backend plugs into the same construction sites and rides the
same threading (per Design decision 2).

---

## Component work breakdown

1. **`OCR/LocalAgentClient.swift`** — exposes the same two methods as `OpenAICompatibleClient`
   (`ocr(...) -> OCRResult`, `textCompletion(...) -> String`).
   - OCR: `ImageEncoding.loadImageAsJPEG(url:scale:)` → temp JPEG in the scratch dir; build the prompt with
     `OCRPrompt.build(...)`; spawn the CLI headless (`claude -p --output-format json` with the image
     referenced by path; `gemini` with its file arg), passing the **prompt via stdin or a temp file, never
     argv** (dodges arg-length + escaping); capture stdout JSON → extract text → `OCRPrompt.parseResponse`
     → `OCRResult`. Clean up the temp file.
   - Text: same, prompt-only, returns the string.
   - Robustness: resolve an **absolute** CLI path (no PATH injection); per-call timeout; map non-zero
     exit / stderr → the friendly-error taxonomy the OCR clients already use; parse defensively and
     version-check (pin `--output-format json`).
2. **`Models/LocalAgentConfig.swift`** — `Codable`, `Sendable`: `tool` (**extensible enum**; in scope:
   `claude`, `gemini`, `codex` — Codex = OpenAI's Codex CLI via "Sign in with ChatGPT", which authenticates
   against a ChatGPT Plus/Pro/Team/Enterprise/**Edu** subscription rather than an API key), resolved
   `binaryPath`, optional `modelOverride`, concurrency cap. (Any shared type touching `ProviderModels.swift`
   is a SHARED HOTSPOT — append only.)
3. **`OCR/LocalAgentValidator.swift`** — mirrors `KeyValidator`: detect the binary (`--version`) + confirm
   signed-in with a 1-token round-trip. New statuses `cliNotFound`, `cliNotLoggedIn`,
   `cliEntitlementMissing` (e.g. Gemini-for-Workspace grant that doesn't authorize the CLI, or a Claude
   Team/Enterprise seat without Claude Code enabled), reusing `.rateLimited` / `.offline` / `.providerBusy`.
   Plain-English messages; never surface raw stderr.
4. **Settings (`SettingsView`)** — add `useLocalAgent` alongside `useGateway` (mutually exclusive), a tool
   picker (Claude Code / Gemini CLI), an optional path override, and a model field. New `DefaultsKeys`
   (additive): `useLocalAgent`, `localAgentTool`, `localAgentBinaryPath`, `localAgentModel`. Per the
   **settings-UX convention**, every new control gets a `?` help popover and grays out when irrelevant.
5. **Onboarding (`ProviderKeyWizard` / `ProviderKeySpec`)** — a `LocalAgentSpec` analog carrying **two
   specs from the start** (`claude`, `gemini`): blurb "Use your existing Claude/Gemini subscription — no API
   key or card. Requires the CLI installed and signed in," deep links to each CLI's install docs, and a
   **Detect + Verify** button driving `LocalAgentValidator`. One-line ToS note: personal use of your own
   subscription on your own archive is intended use.
6. **Cost estimator (`CostEstimator` + pinned Settings pane)** — branch for this backend: show **"Included
   in your subscription — usage limits apply"** instead of a dollar figure, and surface windowed rate limits.
7. **Pacing** — subprocess calls bypass the `NetworkSession` HTTP in-flight limiter, so add a dedicated
   **low concurrency cap** (1–2) for this path and graceful **usage-window** handling (CLI "limit reached,
   resets at HH:MM" → a status the existing retry/resume honors). Don't hammer a subscription.
8. **Pipeline wiring** — thread `localAgent` per Design decision 2; construction sites prefer it when set;
   **skip batch + LLM-rotation** when active (same as gateway).

---

## Phases

- **Phase 0 — Spike / gate (do first).** On a real machine, validate the exact headless invocation **for
  all three CLIs**: `claude -p`, `gemini`, and `codex exec` image round-trips (flags, image-input mechanism,
  JSON output shape). This gates the invocation *details* per CLI — not whether any provider is in scope.
  None is dropped; if a CLI's flags differ from assumed, Phase 1's adapter adapts. (`claude` done — see
  below; `gemini` + `codex` pending install + entitlement.)
- **Phase 1** — `LocalAgentClient` + `LocalAgentConfig` + the additive threading; **fake-CLI unit tests**
  (a shell stub echoing canned JSON — deterministic, $0, no network, same spirit as the file-relay
  stand-in). Build clean, no new warnings.
- **Phase 2** — Settings + Detect/Verify + wizard (both specs) + cost-pane "subscription" branch +
  pacing / usage-window handling.
- **Phase 3** — wire into Process Files + Live Capture; skip batch/rotation; real-CLI e2e smoke (extend
  `test-smoke.sh` to run this path when a CLI is detected, else skip).
- **Phase 4 (optional perf)** — persistent `stream-json` CLI session (one long-running child, framed
  request/response) to amortize per-call startup; N sessions for parallelism.

### Phase 0 result — Claude Code: VALIDATED on this machine (2026-07-10)

Confirmed empirically (Gemini CLI + OpenAI Codex CLI pending — neither `gemini` nor `codex` is installed on
this machine; both are entitlement-gated, see Risks):

- **Setup matches the target no-API scenario.** `claude` v2.1.72 at `~/.local/bin/claude`, authenticated
  from stored credentials — **no `ANTHROPIC_API_KEY`/token env var set** (subscription/OAuth, not an API key).
- **Working headless OCR invocation** (validated end-to-end with a synthetic text image — the exact token
  came back):
  `claude -p "<prompt referencing the temp image path>" --allowedTools Read --output-format json --model <m> --no-session-persistence`
  → JSON whose `.result` is the model's text (feed straight to `OCRPrompt.parseResponse`), plus
  `.usage` / `.total_cost_usd`.
- **Image input** = write the temp JPEG (Processor already does this via `ImageEncoding`) and reference its
  path; pre-approve the vision read with `--allowedTools Read` — **no `bypassPermissions` needed** (respects
  the never-bypass norm).
- **It's an agent, not a bare model** — the call did a Read tool-turn *then* answered (`num_turns: 3`,
  ~9.6 s for a trivial image). Two consequences: (1) use **`--append-system-prompt`** to enforce the OCR
  output contract (`OCRPrompt` classification/rotation/text markers), since Claude Code injects its own
  system prompt — and verify `parseResponse` still gets clean output; (2) agentic + spawn overhead makes
  subprocess-per-call slow at corpus scale → **Phase 4 matters** (persistent `stream-json` session, and
  passing the image as an inline content block to skip the Read turn); keep concurrency modest.
- **Nested-session guard** — `claude` refuses to launch while `CLAUDECODE` is set (nested Claude Code
  session). Irrelevant to standalone Processor; a dev/test gotcha only (unset it to test from inside a
  session).
- **Cost pane** — the returned `usage` + `total_cost_usd`, plus `--max-budget-usd`, feed the
  "drawn from subscription" estimate.

## Daemon build plan (bounded sessions — what's unattended vs. what needs a key/owner)

**The point of this section:** an unattended daemon cannot install a CLI, obtain an entitlement, or launch
`claude` from inside its own Claude Code session (the `CLAUDECODE` nested-session guard). But **almost all of
the code is buildable + testable at $0 with no key and no GUI** via the fake-CLI harness. So the plan splits
cleanly into daemon-buildable sessions and a small keyed/owner verification tail. **Do the sessions top-to-bottom,
one per fresh session; each is a bounded, checkpoint-committable unit.** SUITE_TODO tracks these as `W13.cli-1…4`.

Daemon-buildable (unattended, $0, no key, no GUI — build clean + fake-CLI unit tests + self-review):
- **`W13.cli-1` — client + config + additive threading (Phase 1).** `OCR/LocalAgentClient.swift` (the two
  methods) + `Models/LocalAgentConfig.swift` (append-only; SHARED-HOTSPOT discipline) + thread the companion
  `localAgent: LocalAgentConfig?` (default `nil`) beside `gatewayConfig` per Design decision 2. Tests: a **fake
  CLI** (a committed shell stub echoing canned JSON — same spirit as the FileRelay stand-in) drives
  `LocalAgentClient` deterministically; **plus the resume-safety test** — a run snapshot serialized *before* this
  change still decodes with `localAgent` absent → `nil`. **Tier-2** (OCR core + resume snapshot), but the whole
  gate is satisfiable unattended (byte-level decode test + fake-CLI functional test). Build clean, 0 new warnings.
- **`W13.cli-2` — validator + Settings (Phase 2a).** `OCR/LocalAgentValidator.swift` (`cliNotFound` /
  `cliNotLoggedIn` / `cliEntitlementMissing` + reuse `.rateLimited`/`.offline`/`.providerBusy`; plain-English,
  never raw stderr) + the Settings controls (`useLocalAgent` mutually exclusive with `useGateway`, tool picker,
  path override, model field, additive `DefaultsKeys`, `?` help + gray-out per the settings-UX convention).
  Build-verifiable; the **Detect+Verify live round-trip and the visual gray-out are GUI/owner → Morning Review.**
- **`W13.cli-3` — wizard + cost pane + pacing (Phase 2b).** `LocalAgentSpec` analog carrying the `claude` +
  `gemini` specs, cost-pane "Included in your subscription — usage limits apply" branch, and the dedicated
  low concurrency cap (1–2) + usage-window handling (bypasses the `NetworkSession` HTTP limiter). Build-verifiable.
- **`W13.cli-4` — pipeline wiring (Phase 3, code half).** Prefer `localAgent` at the ~3–4 construction sites;
  **skip batch + LLM-rotation when active** (same as gateway). Extend `test-smoke.sh` to exercise this path via
  the **fake CLI** (and to *skip* gracefully when no real CLI is detected). Build clean; fake-CLI e2e green.

Keyed / owner tail (NOT daemon-buildable — flag to Morning Review, do not guess):
- **Phase 0 for `gemini` + `codex`** — install + confirm entitlement (Gemini needs *Code Assist*/API, not the
  chat-app tier; Codex needs the workspace admin to enable "Sign in with ChatGPT"). Owner/device.
- **Real-CLI live OCR smoke** — the `claude` path is validated (2026-07-10) but a *live* end-to-end run must be
  driven **outside** a Claude Code session (the nested-session guard) → owner/keyed session, or after the CLIs
  above are entitled.
- **Phase 4 (optional perf)** — persistent `stream-json` session. Deferred; own follow-up when perf matters.

## Verification & tiering

- **Tier-2.** Touches the OCR core and the run-config snapshot that crash-resume decodes. The additive
  design keeps the snapshot encoding unchanged, so the focused functional test is: **an in-flight run
  started before the upgrade still resumes** (decodes cleanly with the new `localAgent` field absent). The
  fake-CLI harness makes `LocalAgentClient` deterministically testable at $0 — so the Tier-2 gate is fully
  satisfiable **unattended** for `W13.cli-1…4` (adversarial self-review of the threading + decode + fake-CLI
  functional test); only the real-CLI live smoke is deferred to the keyed/owner tail above.
- **Tier-1** every commit as usual (build clean / no new warnings / self-review).

## Risks & unknowns

- **Gemini entitlement is a per-user *environment* condition, not a scope cut — and the common academic case
  is a miss.** Confirmed 2026-07-10 against the owner's Stanford plan: **Gemini Enterprise Standard/Pro are
  the chat-*app* tiers** (metered as chat queries/day, images/day, Deep Research/day — 40 queries/day on
  Standard) and expose **no CLI / API / Code-Assist surface**, so they do **not** authorize the Gemini CLI.
  The CLI needs a **Gemini Code Assist** license (a *distinct developer product* with confusingly identical
  "Standard/Enterprise" tier names), a **Gemini API / Vertex AI** entitlement, or a personal-Google
  Code-Assist login. **We build the Gemini CLI route anyway (owner's call):** it's correct for users who
  *do* have Code Assist / API, and the **Detect + Verify** step surfaces `cliEntitlementMissing` with clear
  guidance for those who don't (rather than failing silently). Same detection covers Claude Team/Enterprise
  seats without Claude Code enabled.
- **Codex / ChatGPT-Edu entitlement — the door exists but may be shut.** Unlike Gemini's app tiers, OpenAI's
  Codex CLI *is* the sanctioned non-API path (it authenticates against the ChatGPT subscription, incl. Edu).
  But Enterprise/Edu workspaces are admin-managed: **Codex "Sign in with ChatGPT" generally must be enabled
  by the workspace admin and may be off by default**, and Codex is a coding agent, so headless image-OCR
  support + output shape need Phase 0 verification (same agent-wrapper nuance as Claude Code —
  `--append-system-prompt` equivalent to pin the OCR contract). Ships regardless; `cliEntitlementMissing`
  guides users to ask IT to enable Codex.
- **ToS** — using your own subscription on your own archive is intended use; **do not** turn Processor into a
  hosted service reselling that capacity. One-line note in the wizard.
- **CLI output drift** — pin `--output-format json`, parse defensively, version-check.
- **Perf** — subprocess-per-call startup latency at corpus scale; Phase 4 mitigates.
- **Distribution** — `Process` spawn is fine unsandboxed / ad-hoc-signed today; note for any future
  App-Store path (deferred).

## Docs to move with the code (definition of done)

Same commit as the shipping code: `ArchiveProcessor/CLAUDE.md` OCR section (add this as a 3rd escape hatch
beside custom models + the gateway), `README.md`, `ArchiveProcessor/POTENTIAL_FEATURES.md` (the "Local model
support" line is the closest existing item — reword/relocate), flip the `SUITE_TODO.md` checkbox, and
**delete this plan** once the feature ships (git keeps the history).
