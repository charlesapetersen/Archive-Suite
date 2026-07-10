# Execution Plan — OpenAI / ChatGPT provider (standard API + gateway preset)

- **Status:** proposed (not started)
- **Created:** 2026-07-10
- **App:** Archive Processor (`ArchiveProcessor/`)
- **Tracking:** `SUITE_TODO.md` → *Active execution plans*
- **Tier:** 1 + a live functional OCR test (touches the persisted `LLMProvider` enum — a SHARED HOTSPOT — but
  no file-writing/tag/SPEC path, so not Tier-2 by the triggers)

---

## Why / relationship to the CLI plan

Processor supports Anthropic, Gemini, and Mistral as first-class providers, plus an OpenAI-compatible
gateway escape hatch — but **no first-class OpenAI/ChatGPT provider** (it's on the wishlist:
`POTENTIAL_FEATURES.md` → *API & Extensibility* → "First-class OpenAI/GPT-4o provider"). This plan adds it
via the **two delivery modes the app already has**:

1. **Standard API** — a native `LLMProvider.openai` provider using an OpenAI **API key** (BYO, billed
   per-token by OpenAI), a first-class dropdown citizen like Anthropic/Gemini/Mistral.
2. **API Gateway** — a turnkey **OpenAI preset** for the existing OpenAI-compatible gateway (also covering
   Azure OpenAI / proxied endpoints).

> **This is the API-key path — distinct from [`local-agent-cli-provider.md`](local-agent-cli-provider.md),
> which is the subscription / no-API path (OpenAI Codex CLI "Sign in with ChatGPT").** They are
> complementary: a **ChatGPT Edu** user with no API access uses the *CLI* plan; a user with an OpenAI
> **platform API key** uses *this* one. Both can coexist.

The lift is small because `OCR/OpenAICompatibleClient.swift` **already speaks OpenAI's exact wire format**
(`/chat/completions` with `image_url` content parts for OCR, and `textCompletion` for tagging). So OpenAI's
own API essentially works through it today — the work is making it first-class and turnkey.

## Goal & scope

- **Standard API:** add `LLMProvider.openai` with a built-in model list, key onboarding + validation, cost
  data, OCR + tagging + (optional) rotation + (optional) batch — reusing the existing OpenAI-format client.
- **Gateway preset:** a one-click "OpenAI" gateway configuration (base URL + default model + cost prefilled),
  and confirm `OpenAICompatibleClient` works unchanged against `api.openai.com`.

## Non-goals

- The subscription / no-API Codex path (that's the CLI plan).
- Azure OpenAI as a *separate named provider* — covered by the gateway preset (custom base URL).
- Assistants / fine-tuning / Responses-API-only features in v1 (see Design decision 2).

---

## Design decisions

1. **Reuse `OpenAICompatibleClient`, don't duplicate (DRY).** The native OpenAI client is a thin config over
   the existing client (`baseURL: https://api.openai.com/v1`, the user's key, the chosen model) plus
   OpenAI-specific param/error handling — **not** a re-implementation of the OCR/text methods. This matches
   the repo's DRY value and the "shared text client" direction already noted in `POTENTIAL_FEATURES.md`.
2. **Chat Completions, not the Responses API, in v1.** `/v1/chat/completions` is what `OpenAICompatibleClient`
   already implements and works for the vision models we need (gpt-4o / gpt-4.1 / gpt-5 families). The
   Responses API (`/v1/responses`) is noted as a future option for newest reasoning-only features; not v1.
3. **Per-model-family param mapping (the real wrinkle).** `OpenAICompatibleClient` hardcodes
   `max_tokens: 8192`. OpenAI **reasoning models** (o-series, GPT-5 family) require `max_completion_tokens`
   instead of `max_tokens`, may **reject `temperature`**, and take `reasoning_effort`. So the native OpenAI
   path needs a small **param adapter keyed off the model id** (or an optional param-override hook on
   `OpenAICompatibleClient`). Map `ThinkingLevel` low/high → `reasoning_effort` for `supportsThinking` models.
4. **Vision/OCR** works as-is — OpenAI multimodal models accept the base64 `image_url` data URLs
   `OpenAICompatibleClient.ocr` already sends (via `ImageEncoding.loadImageAsJPEG`).

---

## Integration surface (the seam — confirmed 2026-07-10)

Adding `.openai` touches the same per-provider switch sites the other providers use:

- **Enum:** `Models/ProviderModels.swift` — append `case openai = "OpenAI"` to `LLMProvider` (append-only →
  persistence-safe per the invariant), add `LLMModel.openaiModels`, and extend `models` / `supportsBatch`.
  **SHARED HOTSPOT — cross-lane coordination.**
- **OCR client selection:** `OCR/OCRProcessor+OCR.swift:~857` switch (currently anthropic/gemini/mistral) →
  add `.openai` constructing the reused OpenAI client.
- **Text/tagging:** `OCR/LLMTextClient.swift:~25` switch → add `case .openai`.
- **Rotation (optional):** `OCR/LLMRotationDetector.swift:~69` → add `.openai` (chat/completions vision), or
  return `nil` like `.mistral` in v1.
- **Cost / estimate / batch selection switches:** `OCRProcessor+OCR.swift:244/349/437`,
  `OCRProcessor+Pipeline.swift:865` → add `.openai`.
- **Keys:** `Models/KeychainHelper.swift` account `LLMProvider.openai.rawValue` ("OpenAI").
- **Onboarding:** `Models/ProviderKeySpec.swift` — add `.openai` spec + include in `onboardable`.
- **Validation:** `OCR/KeyValidator.swift` — add `validateOpenAI` (cheap `GET /v1/models` with Bearer;
  map 401/403 → invalidKey, 429 → rateLimited, 5xx → providerBusy).
- **Cost:** `Models/CostEstimator.swift` + the built-in model list get OpenAI per-1M input/output pricing.
- **Batch (optional, Phase 4):** `OCR/BatchOCR.swift` currently has three per-provider batch structs
  (Anthropic / Gemini / Mistral) — add a 4th for the **OpenAI Batch API** (upload JSONL → create batch →
  poll → retrieve; 24 h, ~50% discount). Until then, batch is skipped for OpenAI (as the gateway path does).

## Model list (verify at build time)

Built-in OpenAI models — **model IDs and per-1M pricing must be re-verified against OpenAI's live pricing at
implementation time** (same discipline as the existing `ProviderKeySpec` "re-verify wording" note; do not
ship stale numbers). Candidate families: **GPT-5** (+ mini), **GPT-4.1** (+ mini/nano), **GPT-4o** (+ mini),
and a reasoning **o-series** (e.g. o4-mini). Pick a **cheap capable vision model as the default OCR model**
(analogous to Gemini Flash-Lite being the default) — likely a `*-mini` — pending verified pricing. Mark
reasoning-capable models `supportsThinking: true` and wire `reasoning_effort`.

---

## Phases

- **Phase 0 — validate the format (gateway half, nearly free).** With a real OpenAI **API key** (request
  from owner per the paid-run policy; a couple of `*-mini` images, a few cents), point the **existing
  gateway** at `https://api.openai.com/v1` and confirm `OpenAICompatibleClient.ocr` + `textCompletion`
  return clean, parseable output. This both **de-risks the client format** and **delivers the gateway
  approach** immediately.
- **Phase 1 — native provider.** Append `.openai` to `LLMProvider`; add the model list + Keychain account;
  wire the ~6–8 switch sites to route `.openai` through the reused OpenAI client + the param-family adapter
  (Design decision 3). Build clean, no new warnings.
- **Phase 2 — onboarding + validation + cost.** `ProviderKeySpec.openai` (deep links to
  platform.openai.com key creation + billing + data-use), `KeyValidator.validateOpenAI`, cost data, and the
  `ThinkingLevel → reasoning_effort` mapping.
- **Phase 3 — gateway preset + docs.** A one-click "OpenAI" preset that prefills the gateway base URL /
  default model / cost (and a note that a custom base URL covers **Azure OpenAI** / proxies). Update docs.
- **Phase 4 (optional) — OpenAI Batch API** as a 4th `BatchOCR` struct for the discounted batch path.

## Verification & tiering

- **Tier-1 + a live functional OCR test** with a real OpenAI key: run the smoke pipeline (or
  `test-smoke.sh`-style 2-image run) end-to-end through the native provider and assert a PDF + extracted
  text. No file-writing/tag/SPEC change, so no adversarial (Tier-2) gate required — but the persisted
  `LLMProvider` enum is a **SHARED HOTSPOT**, so coordinate the enum append and keep it append-only.
- **Cost:** request an OpenAI key from the owner before the paid run; estimate first; use the cheapest
  capable `*-mini` vision model and the smallest input that proves the path.

## Docs to move with the code (definition of done)

Same commit as the shipping code: `ArchiveProcessor/CLAUDE.md` (add OpenAI to the built-in provider/model
list + note the gateway preset), `README.md`, `ArchiveProcessor/POTENTIAL_FEATURES.md` (retire the
"First-class OpenAI/GPT-4o provider" wishlist item), flip the `SUITE_TODO.md` checkbox, and **delete this
plan** once shipped.
