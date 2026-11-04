# Gemini given corrected handwriting lines (W46.ocr-ppocrv6-hands-paid)

Gemini 3.7 Flash through the Stanford gateway, using the Qwen arm’s frozen 0/8/16 image/text example pack, with each crop a separate image. Scores are NES points. Only the Blackwell holdout tests a documented same hand; the Shils folder is a hand proxy, and the other cohorts test transfer with unverified hand identity. The 40 L1 pages include three Blackwell diary pages (other volumes) and two Blackwell correspondence pages; they are not all known different hands.

On the one documented Blackwell diary hand: 8 lines +0.25 NES (95% page interval -0.62 to +1.11, n=12); 16 lines -0.46 NES (95% page interval -1.40 to +0.45, n=12). These page-conditional results do not establish an OCR default for a new hand. The intervals are pointwise, without adjustment across the example conditions.

**Support:** 201 successful replies / 213 attempted conditions; 10 gateway failures retained without retry. Failure reasons: retained HTTP 502: 9, retained lost connection: 1, content_filter: 2. Both-answered differences use matched successful pairs; strict scores count failures as zero. All fixed conditions are accounted for; complete does not mean every request succeeded.

## Measurement card

- **Truth:** public By the People transcriptions (CC0). Owner targets use the post-sheet truth (W46.ocr-hands-rescore); Gemini 3.8/Claude drafted it and 114 hand places were checked, with 10 unresolved. Owner figures are reference agreement, not independent model rankings. The 19 typed controls found no error, with an exact 95% passage-error upper bound of 17.6%. Examples are the existing PP-OCRv6-aligned corrected lines: model-filtered, not a random line draw. Owner exemplar lines predate the sheet corrections and may retain reference errors.
- **Selection:** fixed Qwen pack: 40 seeded L1 pages, all 19 owner hand pages, 12 held-out Blackwell diary pages. Blackwell examples come only from its 24 training pages. Shils leaves the target page out; source-image hashes reject aliases. No target truth enters the prompt. Owner targets include the 16 scored hand pages and three agreement-only letters (p086, p094, p096), which remain unvalidated. L2 is not an adaptation cohort because no verified same-hand example pool was prepared.
- **Comparison:** identical 2400 px/quality-90 target JPEGs across 0/8/16 examples; quality-95 line crops, eight examples the prefix of sixteen; same target prompt as the Qwen pack. Each example is a separate crop paired with its corrected line text; no target or example crop is scaled locally. Temperature 0, low reasoning, 8192-token output cap, gateway cache disabled. Single attempts; capped, empty or transport failures are separate and score zero only in strict sensitivity. Qwen uses the same example images with no thinking; this is not a controlled model-only comparison. These subsets enter their own panel, not whole-96 or whole-895 charts.
- **Noise:** 10,000-round paired page bootstrap, both-answered headline and failure=0 sensitivity. Public transfer additionally bootstraps collection clusters. A single diary and four Shils pages cannot estimate variation across hands. The inherited hosted floor is 0.60 points (twice the measured handwritten-kind rerun range; the 96-wide floor is 0.49); public and prompt-specific noise is not established. Eight zero-example repeats were initially preselected but omitted under the narrower resume scope. An interval spanning zero or a gap inside the inherited floor does not establish a gain.
- **Scope:** zero-training adaptation on these pages and examples only; no app default, fine-tune or new-hand population claim. Cross-hand transfer cannot answer same-hand adaptation. No corpus modified; no target transcription supplied to a model.

## Paired conditions

| cohort | examples | answered / attempted / fixed n | NES answered | NES strict | missed words % | added words % |
|---|---:|---:|---:|---:|---:|---:|
| blackwell-held-out | 0 | 12 / 12 / 12 | 83.67 | 83.67 | 13.85 | 16.99 |
| blackwell-held-out | 8 | 12 / 12 / 12 | 83.92 | 83.92 | 13.57 | 17.69 |
| blackwell-held-out | 16 | 12 / 12 / 12 | 83.20 | 83.20 | 14.97 | 17.62 |
| owner-Shils-folder-proxy | 0 | 4 / 4 / 4 | 95.72 | 95.72 | 4.17 | 6.56 |
| owner-Shils-folder-proxy | 8 | 4 / 4 / 4 | 91.63 | 91.63 | 3.98 | 5.57 |
| owner-Shils-folder-proxy | 16 | 4 / 4 / 4 | 91.68 | 91.68 | 2.78 | 5.57 |
| owner-transfer | 0 | 15 / 15 / 15 | 91.64 | 91.64 | 2.63 | 5.22 |
| owner-transfer | 8 | 15 / 15 / 15 | 90.76 | 90.76 | 2.72 | 5.27 |
| owner-transfer | 16 | 15 / 15 / 15 | 92.73 | 92.73 | 2.42 | 5.18 |
| public-L1-transfer | 0 | 36 / 40 / 40 | 91.52 | 82.36 | 12.94 | 5.32 |
| public-L1-transfer | 8 | 37 / 40 / 40 | 91.43 | 84.57 | 11.19 | 5.95 |
| public-L1-transfer | 16 | 35 / 40 / 40 | 91.39 | 79.96 | 17.75 | 5.20 |

| cohort | examples | Δ vs zero, both answered (95% CI) | Δ strict (95% CI) | collection-clustered (95% CI) |
|---|---:|---|---|---|
| blackwell-held-out | 8 | +0.25 (-0.62 to +1.11; n=12) | +0.25 (-0.62 to +1.11; n=12) | across-hand interval not estimated |
| blackwell-held-out | 16 | -0.46 (-1.40 to +0.45; n=12) | -0.46 (-1.40 to +0.45; n=12) | across-hand interval not estimated |
| owner-Shils-folder-proxy | 8 | -4.09 (-12.47 to +0.16; n=4) | -4.09 (-12.47 to +0.16; n=4) | across-hand interval not estimated |
| owner-Shils-folder-proxy | 16 | -4.04 (-12.75 to +0.39; n=4) | -4.04 (-12.75 to +0.39; n=4) | across-hand interval not estimated |
| owner-transfer | 8 | -0.88 (-2.54 to +0.44; n=15) | -0.88 (-2.54 to +0.44; n=15) | across-hand interval not estimated |
| owner-transfer | 16 | +1.09 (-0.11 to +2.59; n=15) | +1.09 (-0.11 to +2.59; n=15) | across-hand interval not estimated |
| public-L1-transfer | 8 | -0.28 (-1.27 to +0.50; n=36) | +2.21 (-0.91 to +7.58; n=40) | -0.28 (-0.92 to +0.50; n=36) |
| public-L1-transfer | 16 | -0.02 (-1.52 to +1.36; n=35) | -2.40 (-7.84 to +0.89; n=40) | -0.02 (-1.82 to +1.27; n=35) |

## Stability and owner sensitivity

Zero-example repeats: 0.
No new repeats were run: the owner resume scope was only the 135 untouched conditions, then the six finished under the $2.60 cap. The eight repeats in the initial design were omitted; no prompt-specific rerun floor is established.

Owner pages without unresolved sheet places (the nine clear pages of the original 16), kept apart by cohort; the four-page Shils inference remains descriptive:

| cohort | examples | Δ vs zero, both answered (95% CI) |
|---|---:|---|
| owner-Shils-folder-proxy | 8 | -8.34 (-16.68 to -0.01; n=2) |
| owner-Shils-folder-proxy | 16 | -8.37 (-17.12 to +0.38; n=2) |
| owner-transfer | 8 | -1.88 (-4.84 to +0.43; n=7) |
| owner-transfer | 16 | +0.14 (-0.39 to +0.58; n=7) |

## Cost and provenance

Charged against the owner-revised $2.60 working item cap: $2.47678, including $0.80 retained for 10 uncertain outcomes. Known-usage list-rate estimate $1.67678 at $0.75/$3.75 per million input/output tokens (including reasoning); gateway’s own figure $1.65751 on 203 of 203 attempts. The cap counts the larger for each request; any unknown request keeps its full reservation. No retries. The initial 24-request pilot cost $0.1950195 and projected $1.7958 for 221 calls. The owner revised the working cap from the initial agent-set $1 estimate to $2.50 (OWNER_AUTHORIZATIONS.md, 1565f7d9), then to $2.60 (44860fc8, 2026-11-03) only so the $0.08 reservation guard could finish the six untouched Blackwell conditions; all pilot answers were preserved, not re-called. A sheet alternative was prepared but made no paid call and is not an accuracy arm. The owner’s 2026-11-01 evening answer retained the ten old allowances without exact billing reconciliation; nine 502 replies and one lost connection remain failed, never repeated. Both-answered comparisons omit these pairs; strict sensitivity counts them as zero. These missing responses limit the transfer comparison and are not recognizer failures. Stanford PTA, not subscription usage.

Frozen pack SHA-256 `6f644e4d11b075429095642fa5b71e254bed99604726d5d951dfa0736c7a7b07`; truth-index SHA-256 `051664c1e67ec8b713181f198f21af20bef43aa5ff18c42b8afdc7d4f89c3210`. Private input pack `~/.local/state/archive-autonomous/artifacts/hand-icl-20261101`, target truth `hand-icl-truth-20261101`, responses/ledger/receipt `hand-icl-gateway-20261101`. The receipt records the runner hash and code commit; each ledger outcome pins request and response hashes, usage, finish reason, returned model and time. Shared inputs are read-only. No rendered or model scratch created; only paid replies and audit receipts retained.

Reproduce: `python3 ops/autonomous/heavy-run.py run -- uv run --offline --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex python ArchiveProcessor/scripts/segbench/hand_icl_gateway.py report`.
