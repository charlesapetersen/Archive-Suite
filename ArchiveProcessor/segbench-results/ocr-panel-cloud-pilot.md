# W41.ocr-panel-cloud — pilot preparation, awaiting transfer approval

**No paid calls were made. No cloud accuracy or measured cloud cost is available yet.**

The owner answered the initial spending gate on 2026-10-15: run three pages per model, well under $1,
then ask again with the measured cost of the full 99-original panel. The full run is not approved.
The pilot is prepared for the local panel's fixed pages p010 (clipping), p062 (typescript/bullets), and
p086 (difficult handwriting). It reuses the exact frozen 2400 px JPEG bytes and transcription prompt.
p086 is agreement with the drafting models, not independently adjudicated accuracy.

Automatic approval review rejected the paid pilot command: it did not accept the answer recorded in the
project's plan as trusted authorization to transmit the private archival images to OpenRouter and incur
charges. No alternative paid path was attempted. The new gate is
`W41.ocr-panel-cloud-transfer-owner-ok`: authorize these exact three images to
`https://openrouter.ai/api/v1/chat/completions` (the twelve pinned chat routes) and
`https://api.mistral.ai/v1/ocr` (the production app client), within a combined **$0.75** ceiling.
The question is recorded in the Daemon Report and the dependency is mirrored in `SUITE_TODO.md`.

## Prepared routes and controls

`ArchiveProcessor/scripts/segbench/ocr_cloud.py` permits only `prepare`, `pilot`, and `report`.
The manifest accepts exactly the three original images. There is no full-run command. All twelve models
from the brief are configured; providers are frozen to Google AI Studio, Anthropic, OpenAI, Mistral, or
DeepInfra fp8 (the two Qwen rows). Fallbacks are disabled. Every billable call has a write-ahead reservation;
unknown outcomes block continuation, and settled failures are not bought again. Calls are serial.

The public endpoint catalogs were read on 2026-10-15; private frozen copies and the manifest are in
`/tmp/w41-ocr-panel-cloud/`. Before spending, set `OCR_CLOUD_CACHE` if a different private cache is wanted.
The runner preserves the local panel's $2 ledger separately and does not count its spend against this item.
The local usage proxy suggests roughly $0.13–$0.44 for the chat pilot, not a measured cloud quote.

The combined ceiling holds $0.012 apart for dedicated OCR. The app's floating `mistral-ocr-latest` alias
now resolves to **OCR 4.1** (confirmed by the authenticated, read-only `/v1/models` response), at
[$4 per 1,000 pages](https://docs.mistral.ai/inference/pricing).
The pilot pins the resolved `mistral-ocr-4-1` ID and verifies the returned model and one-page usage.
`ocr-cloud-mistral.swift` compiles the production `MistralClient`, `ImageEncoding`, `NetworkSession`, and
error-message code, with dependency-only types for the app's model/result store. Unlike the chat panel,
the app encoder caps this route at 2048 px and JPEG quality 0.85, and dedicated OCR takes no panel prompt.
Raw replies and page usage are recorded privately. Billing remains a published-price calculation;
the client exposes no dollar charge. An explicit local-fixture mode skips both Keychain and network.

The shared runner still reserves full endpoint contexts by default. Only the cloud wrapper uses a
32,768-token input allowance for the short prompt and one image in the documented bounded families:
[Gemini's media tiers](https://ai.google.dev/gemini-api/docs/media-resolution),
[Claude's visual limits](https://platform.claude.com/docs/en/build-with-claude/vision), and
[the three OpenAI models at high detail](https://developers.openai.com/api/docs/guides/images-vision).
This is a conservative budgeting bound, not measured token usage. Mistral and Qwen retain full-context
reservations; the largest runs first (Mistral Large, $0.730153) and settles before the next call. Actual
bound violations stop the run and prevent a restart from buying another call.

Gemini 3.1 Pro/3.8 Flash request low reasoning; Gemini 3.5 Flash/Flash-Lite and GPT-5.4 Mini request minimal.
Other capable routes request reasoning off; Qwen3-VL Instruct has no reasoning control. Temperature is
zero except Claude/OpenAI, whose catalogs do not advertise it; it is omitted there. Output cap: 8192.

## Verified offline

- 20 existing panel tests and 11 cloud tests pass on synthetic scratch inputs, with no network or Keychain.
  They cover the three-page authority, price tiers/cap, fixed routes, uncertain calls, and resume refusal
  after a bound breach. Incomplete pilots withhold the combined full-panel estimate.
- The headless Mistral driver builds under the Mac heavy lock with `-warnings-as-errors`. A synthetic
  3000×2000 JPEG and recorded JSON fixture exercise the production encoder, client, response parser and
  network seam. Expected text/usage are preserved; the source image's hash is unchanged. No app GUI,
  API request, or Keychain access occurs in this functional check.
- Separate adversarial review informed the budget bounds, reasoning settings, restart refusal and
  incomplete-report handling. App source and the real corpus were not changed.

Resume steps and the compile command are in `execution-plans/items/W41.ocr-panel-cloud.md`.
