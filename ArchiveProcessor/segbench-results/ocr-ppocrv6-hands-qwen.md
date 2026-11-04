# Qwen3.6-27B given corrected handwriting lines (W46.ocr-ppocrv6-hands-qwen)

Qwen3.6-27B (FP8) on vLLM on one Sherlock H100, given 0, 8 or 16 corrected line images of a hand, each crop a separate image followed by its corrected reading, then the target page. Scores are NES points. Only the Blackwell holdout tests a documented same hand; the Shils folder is a hand proxy; the owner-transfer and public L1 cohorts get Blackwell examples and test transfer across hands, not adaptation.

**Verdict.** On the one documented Blackwell diary hand (12 held-out pages): 8 lines -1.34 NES (95% page interval -3.30 to +0.30); 16 lines -0.68 NES (95% page interval -2.18 to +0.58). Page-conditional on this hand; not an OCR default for a new hand. Intervals are pointwise, unadjusted across the two example counts.

**For the training kit:** putting a hand's corrected lines in Qwen3.6-27B's prompt is not an adaptation route on this evidence. No cohort at 8 or 16 lines moved by more than its interval allows, the documented hand's point estimates are below zero, and most answers changed only slightly. A kit user who wants a reader adapted to a hand needs training (W46.ocr-ppocrv6-hands) or another model; this run says nothing about Gemini, whose arm (W46.ocr-ppocrv6-hands-paid) is its own report, `ocr-ppocrv6-hands-paid.md`.

**Support:** 213 of 213 fixed conditions answered; every reply ended normally (finish {'stop': 213}); the longest reply was 511 tokens against the 8,192 cap, so no reply was cut off. Failed conditions: 0.

## Measurement card

- **Truth:** public By the People transcriptions (CC0) for the Blackwell holdout and L1 pages. Owner targets use the post-sheet truth (W46.ocr-hands-rescore): model-drafted, 114 hand places owner-checked, 10 unresolved, so owner figures are agreement with that reference (OCR-1), not rankings. Example lines are the existing PP-OCRv6-aligned corrected lines, filtered by alignment error against the base recognizer (not a random line draw); the owner example lines predate the sheet corrections. No Claude subagent drew or read any line or page.
- **Selection:** the frozen pack (`hand_icl.py prepare`, seed `W46.ocr-ppocrv6-hands-qwen-20261101`): 40 seeded L1 pages, all 19 owner handwritten pages, the 12 test-role Blackwell pages of the training volume. The owner cohorts hold the 16 scored hand pages and the three agreement-only letters (p086, p094, p096, in owner-transfer), whose truth is the drafters' agreement, never adjudicated and not on the hand sheet. Blackwell examples come only from its 24 training pages; Shils examples from the other three Shils pages; source-image hashes reject aliases. No page was chosen by a tested route or by ABBYY text.
- **Comparison:** identical 2400 px / quality-90 target JPEGs across conditions, eight examples the prefix of sixteen, one prompt, temperature 0, no thinking, 8,192-token cap, 32,768-token context, at most 17 images, one sequence, fp8 KV cache, eager. Snapshot `e89b16ebf1988b3d6befa7de50abc2d76f26eb09`, vLLM 0.31.0+cu129, transformers 5.17.0. Every recorded request hash was recomputed from the frozen pack and matched. The Gemini arm (W46.ocr-ppocrv6-hands-paid) uses the same pack and is reported apart (`ocr-ppocrv6-hands-paid.md`); no model comparison is drawn here.
- **Noise:** 10,000-round paired page bootstrap within each cohort; public L1 also bootstraps by collection. One diary and four Shils pages cannot estimate variation across hands. No repeat run was made, so no prompt-specific rerun floor exists; the inherited hosted handwritten floor (0.60 points) is a reference, not this route's floor. A gap whose interval spans zero is a tie.
- **Scope:** zero-training prompting on these pages and examples only. Not an app default, not a fine-tune comparison on the same pages, no claim about a new hand, another collection, the 96 or the 895. These subsets do not enter the whole-96 or whole-895 charts.

## Paired conditions

| cohort | examples | answered / n | NES | missed words % | added words % |
|---|---:|---:|---:|---:|---:|
| blackwell-held-out | 0 | 12 / 12 | 78.56 | 21.33 | 23.01 |
| blackwell-held-out | 8 | 12 / 12 | 77.23 | 22.52 | 23.64 |
| blackwell-held-out | 16 | 12 / 12 | 77.88 | 20.70 | 22.73 |
| owner-Shils-folder-proxy | 0 | 4 / 4 | 93.44 | 9.54 | 8.75 |
| owner-Shils-folder-proxy | 8 | 4 / 4 | 92.45 | 10.74 | 9.74 |
| owner-Shils-folder-proxy | 16 | 4 / 4 | 93.09 | 9.74 | 8.75 |
| owner-transfer | 0 | 15 / 15 | 88.75 | 9.24 | 10.62 |
| owner-transfer | 8 | 15 / 15 | 89.13 | 8.89 | 10.27 |
| owner-transfer | 16 | 15 / 15 | 89.27 | 8.11 | 10.23 |
| public-L1-transfer | 0 | 40 / 40 | 87.21 | 12.53 | 10.14 |
| public-L1-transfer | 8 | 40 / 40 | 87.03 | 12.61 | 10.14 |
| public-L1-transfer | 16 | 40 / 40 | 87.71 | 11.94 | 11.01 |

| cohort | examples | Δ vs zero (95% page CI) | collection-clustered (95% CI) |
|---|---:|---|---|
| blackwell-held-out | 8 | -1.34 (-3.30 to +0.30; n=12) | one hand/folder: not estimated |
| blackwell-held-out | 16 | -0.68 (-2.18 to +0.58; n=12) | one hand/folder: not estimated |
| owner-Shils-folder-proxy | 8 | -1.00 (-3.32 to +0.37; n=4) | one hand/folder: not estimated |
| owner-Shils-folder-proxy | 16 | -0.35 (-1.39 to +0.38; n=4) | one hand/folder: not estimated |
| owner-transfer | 8 | +0.37 (-0.62 to +1.86; n=15) | one hand/folder: not estimated |
| owner-transfer | 16 | +0.51 (-0.75 to +2.11; n=15) | one hand/folder: not estimated |
| public-L1-transfer | 8 | -0.18 (-0.59 to +0.20; n=40) | -0.18 (-0.60 to +0.10; n=40) |
| public-L1-transfer | 16 | +0.50 (-0.49 to +2.06; n=40) | +0.50 (-0.49 to +2.29; n=40) |

Owner sensitivity, the 9 pages of the original 16 with no unresolved sheet place (descriptive; still a model-drafted reference):

| cohort | examples | Δ vs zero (95% page CI) |
|---|---:|---|
| owner-Shils-folder-proxy | 8 | +0.16 (-0.24 to +0.55; n=2) |
| owner-Shils-folder-proxy | 16 | +0.38 (+0.37 to +0.40; n=2) |
| owner-transfer | 8 | -0.14 (-0.37 to +0.02; n=7) |
| owner-transfer | 16 | -0.21 (-0.68 to +0.12; n=7) |

## Copying, speed and cost

Example readings (12+ characters) found verbatim in the target answer: 0 of 492 at 8 lines (0 answers), 2 of 926 at 16 (2 answers). The prompt forbids copying; a verbatim hit can also be a phrase genuinely repeated on the target page. The examples reached the model: median prompt 4279 / 5069 / 5811 tokens at 0/8/16 examples. The answer was character-identical to the zero-example answer on 8 of 71 pages at 8 lines and 7 at 16.

Median request 11.4 s (0/8/16 examples: 11.7 / 11.2 / 11.4 s), longest 27.6 s, 42 min of requests in total on one NVIDIA H100 80GB HBM3; largest prompt 6741 tokens. The 24-request pilot projected 43 min; the allocation ran 46 min including startup (Slurm 50741268). The first attempt (50696432) failed in 10 s before the model started (node-local scratch not bound into the container); no request was repeated. Sherlock allocation only; no money spent.

Frozen pack SHA-256 `6f644e4d11b075429095642fa5b71e254bed99604726d5d951dfa0736c7a7b07`; truth index `051664c1e67ec8b713181f198f21af20bef43aa5ff18c42b8afdc7d4f89c3210`; ledger `53150bd72ded0be1526d3d00d6bdfde900d24a49c8b0e7d93a9a5b0327d20583`. Private pack and results `~/.local/state/archive-autonomous/artifacts/hand-icl-20261101`, target truth `hand-icl-truth-20261101`.

Reproduce: `python3 ops/autonomous/heavy-run.py run -- uv run --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex python ArchiveProcessor/scripts/segbench/hand_icl.py report`.
