# W46.ocr-new-open-boxes: box readers on the 895 and the 96

The two completed cluster readers do not change an OCR pick. Their saved semantic block boxes are inputs for W46.place-print, whose line-selection test remains necessary. Granite fails the cluster pilot; its separate Mac arm is complete and shows why a 258M joint reader is not the R2 16 GB OCR alternative at these settings. No money spent.

## Runs and failures

Sherlock batch 20261031-131437, collected 2026-11-01. Unlimited-OCR: 50550127 (895), 50550130 (99 originals). Nemotron-Parse 2.0: 50569392 and 50569394. All four completed; each set has one job, identical frozen image SHA-256s and an identical both-set contract. The scored 96 exclude the panel's three agreement-only letters. `new-open-boxes-audit.json` verifies these identities and records the exact contracts.

- **Unlimited-OCR:** `baidu/Unlimited-OCR` at `8249d20b`, bf16, transformers 4.57.1, torch 2.13.0+cu129 (card torch 2.10). Card prompt `<image>document parsing.`, gundam crops (base 1024, image 640), sliding 35-gram block in a 128-token window. Greedy; its infer generate call replaces max_length with max_new_tokens 8192. Actual attention implementation was eager. Its ref/det tags are removed from reading text; blocks stay in emitted order.
- **Nemotron-Parse 2.0:** `nvidia/NVIDIA-Nemotron-Parse-2.0` at `4e021c03`, bf16, transformers 5.6.1, same torch. Its card's transformers route and prompt `</s><s><predict_bbox><predict_classes><output_markdown><predict_no_text_in_pic>`, repetition penalty 1.1, greedy, 8192 new tokens. Each block through the publisher's postprocess_text, Markdown text/tables, emitted order. This is not the unsupported vLLM server route.
- **Granite on Sherlock:** original 895 job 50536486 timed out after four hours during a fork deadlock before loading weights; 96 job 50536487 was cancelled without running. Owner session commit `56916c54` records the spawn diagnosis (50573600): model loaded in 0.4 s, then two of three pilot pages looped on handwriting until the 8192-token context filled. The pilot gate correctly stopped the arm. Those diagnostic readings/logs are not in this collected artifact; the original initialization log is. No full-set granite cluster score is invented.
- **Granite on the Mac:** IBM MLX build `ibm-granite/granite-docling-258M-mlx` at `e9939db2`, bf16, mlx-vlm 0.7.4, prompt `Convert this page to docling.`, temperature 0, 8192 output tokens. DocTags through docling-core 2.105.0 Markdown export, which omits page furniture; on parse failure, element texts with a recorded parse_error. Raw tags and element boxes retained. Resumed the 46 cached accuracy pages to all 96; no saved page was reread. The rejected cluster arm instead used `untied` weights at `55d41aa2` and an 8192 total context, so this does not measure a Mac-vs-cluster runtime gap.

Initial Unlimited setup lacked matplotlib; Nemotron's first setup conflicted with image NCCL pins, then its first retry lacked offline C-RADIO encoder code. Those attempts produced no scored readings; the completed replacements are above. No provider/request errors remain. EOS with no text is a blank, not an answer.

## Reading accuracy

NES %, failed/capped/blank pages as 0. Answered-only means each reader's own answered subset; paired comparisons below use the intersection. bowF1 is the order-free NewsBench score (Latin-script pages only on the 895, failures included). Order edit is the existing scorer's matched-text order measure, on its eligible answered pages only; it is not a geometric layout score.

| Set | Reader | Answered / n | Strict NES | NES answered | bowF1 | Order edit (eligible pages) |
|---|---|---:|---:|---:|---:|---:|
| public895 | Unlimited-OCR (Sherlock) | 790/895 | 41.54 | 47.06 | 0.360 | 0.058 (367) |
| public895 | Nemotron-Parse 2.0 (Sherlock) | 605/895 | 33.08 | 48.94 | 0.309 | 0.102 (296) |
| public895 | qwen3.6-27b | 798/895 | 63.26 | 70.95 | 0.626 | 0.066 (538) |
| public895 | lightonocr3-4b | 810/895 | 62.88 | 69.48 | 0.641 | 0.085 (567) |
| owner96 | Unlimited-OCR (Sherlock) | 94/96 | 83.68 | 85.46 | 0.847 | — |
| owner96 | Nemotron-Parse 2.0 (Sherlock) | 92/96 | 83.24 | 86.86 | 0.860 | — |
| owner96 | granite-docling-258M (Mac MLX) | 77/96 | 62.07 | 77.39 | 0.653 | — |
| owner96 | qwen3.6-27b | 95/96 | 94.35 | 95.34 | 0.960 | — |
| owner96 | lightonocr3-4b | 96/96 | 89.43 | 89.43 | 0.931 | — |

The public 895: Unlimited has 60 caps and 45 blanks (105 failures); Nemotron has 283 caps and 7 blanks (290 failures). The scored 96: Unlimited 2 caps, Nemotron 4. Nemotron's fifth owner cap is agreement-only p096. Full stratum and 440/455 subset figures are in `new-open-boxes-20261031.csv`; per-page numeric scores in `-pages.csv`.

## Paired differences

Each cell is the new reader minus the incumbent in NES points, 95% bootstrap interval. Answered uses only pages both answered. `ocr_new_open_paired.py` also records paired permutation p. Intervals crossing 0 are ties (local greedy routes, the existing rerun-noise rule).

| Set | Reader | Against | Strict | Both answered | n both |
|---|---|---|---:|---:|---:|
| owner96 | granite-docling-258M (Mac MLX) | qwen3.6-27b | -32.3 (-39.6 to -24.9) | -18.7 (-25.1 to -12.9) | 76 |
| owner96 | granite-docling-258M (Mac MLX) | lightonocr3-4b | -27.4 (-35.0 to -19.9) | -12.8 (-18.6 to -7.3) | 77 |
| owner96 | Nemotron-Parse 2.0 (Sherlock) | qwen3.6-27b | -11.1 (-16.0 to -6.4) | -9.2 (-12.9 to -5.8) | 91 |
| owner96 | Nemotron-Parse 2.0 (Sherlock) | lightonocr3-4b | -6.2 (-10.6 to -1.9) | -3.3 (-6.7 to +0.2) | 92 |
| owner96 | Unlimited-OCR (Sherlock) | qwen3.6-27b | -10.7 (-15.5 to -6.4) | -9.4 (-13.5 to -5.8) | 93 |
| owner96 | Unlimited-OCR (Sherlock) | lightonocr3-4b | -5.8 (-10.1 to -1.9) | -3.9 (-7.1 to -0.8) | 94 |
| public895 | Nemotron-Parse 2.0 (Sherlock) | qwen3.6-27b | -30.2 (-32.2 to -28.2) | -23.9 (-25.9 to -22.0) | 573 |
| public895 | Nemotron-Parse 2.0 (Sherlock) | lightonocr3-4b | -29.8 (-31.8 to -27.8) | -22.5 (-24.5 to -20.5) | 577 |
| public895 | Unlimited-OCR (Sherlock) | qwen3.6-27b | -21.7 (-23.4 to -20.0) | -22.7 (-24.3 to -21.0) | 715 |
| public895 | Unlimited-OCR (Sherlock) | lightonocr3-4b | -21.3 (-23.0 to -19.7) | -21.3 (-22.9 to -19.8) | 726 |

## Speed and memory

One Sherlock card per run, requested 48 or 80 GB; actual GPU type and peak VRAM were not recorded. Median seconds is each page's call; throughput is the collector including pilot, not the median's reciprocal. Load and Slurm startup are excluded from collector time.

| Set | Reader | Median seconds/page | Collector seconds | Load seconds | Pages/hour/GPU |
|---|---|---:|---:|---:|---:|
| public895 | Unlimited-OCR (Sherlock) | 11.98 | 31930.3 | 22.1 | 100.9 |
| public895 | Nemotron-Parse 2.0 (Sherlock) | 2.51 | 8386.4 | 41.8 | 384.2 |
| owner99 | Unlimited-OCR (Sherlock) | 10.60 | 1757.0 | 27.8 | 202.8 |
| owner99 | Nemotron-Parse 2.0 (Sherlock) | 1.93 | 335.8 | 46.1 | 1061.3 |

The four successful jobs used 11.84 GPU-hours (Slurm elapsed), plus 4.00 hours in the initial granite deadlock. This excludes the diagnosis jobs absent from returned sacct.tsv. Compare the preparation's about 10 expected and 52 GPU-hour ceiling. Granite Mac seconds, MLX peak memory, caps and kind figures are in [`../ocr-mac-local-hw.md`](../ocr-mac-local-hw.md); one Apple M3 Pro, 18 GB, one page at a time. Its model/working memory figure is MLX's allocator peak, not total process/system memory. The 2026-11-01 resume used the suite heavy lock; it produced no additional whole-process memory-guard row.

## Box handoff to W46.place-print

Private cached records: `~/Library/Caches/ArchiveSuiteRehearsal/sherlock-results/new-open-{895,96}/<reader>/results/ocr/<reader>/<page>.json`. Each holds image SHA, image dimensions, raw model reply, parsed text, semantic class and box coordinates. Contracts, model revisions and runner/parser hashes are beside them. The Mac tags are `ocr-panel-local/local/granite-docling-258m-mlx/<page>-original.raw.json`; successful parsed records retain element boxes.

- Unlimited boxes are in image coordinates divided by 999.
- Nemotron boxes are normalized to a **padded 1664×2048 canvas**, not the source image. Use its publisher's `transform_bbox_to_original` with the saved image size before comparing to truth.
- DocTags coordinates run 0–500 of the page. None of these semantic blocks guarantees line/word granularity or whole-line selection. Placement is not measured here.

Geometry below is on nonempty answered pages only, all 99 owner originals included. Defects are independent counts and can overlap; invalid boxes counts their union. Do not count capped/blank blocks as usable boxes or silently repair the emitted coordinates.

| Set | Reader | Answered pages with boxes | Boxes | Out of range | Reversed | Zero area | Invalid boxes |
|---|---|---:|---:|---:|---:|---:|---:|
| public895 | Unlimited-OCR (Sherlock) | 790 | 11396 | 13 | 34 | 295 | 334 |
| public895 | Nemotron-Parse 2.0 (Sherlock) | 605 | 2384 | 0 | 4 | 0 | 4 |
| owner99 | Unlimited-OCR (Sherlock) | 97 | 1428 | 1 | 0 | 0 | 1 |
| owner99 | Nemotron-Parse 2.0 (Sherlock) | 94 | 972 | 0 | 0 | 0 | 0 |

## Measurement card

- **Truth:** frozen public dataset transcriptions on the 895; adjudicated panel truth with the owner's corrected hand sheet on the 96. The two drafters were Claude Opus 5.5 and Gemini 3.8 Flash. None of these three readers or its model family drafted that truth. The public truth is not owner-checked.
- **Selection:** the same frozen 895 and 96 as the open sweep; no selection by a tested reader or ABBYY text. The three-page gate is a declared qualification step, so granite's public result is a refusal, not a 0 score.
- **Comparison:** native per-card runtimes/prompts and parsed text, temperature 0/greedy, one reading, 8192 new output tokens on the two completed cluster readers. Same prepared image checksums on both sets. Native Markdown, header handling, crop policy and repetition penalties differ by reader as disclosed above; this is a route comparison. Granite's cluster total-context limit differs from the Mac output limit.
- **Noise:** n=895 and 96, seeded paired 95% bootstrap intervals, one greedy reading. No stochastic rerun arm; intervals use the existing local-greedy tie rule. The bench headline lists p081 apart (95 pages); the 96 figures here include it, so its headline is not the same average.
- **Scope:** whole-page transcription and saved semantic blocks, not geometric layout accuracy, line selection, repetition-penalty tuning for granite, a Nemotron/Unlimited Mac port, or the Reading the Archive gated gold. No claim that a small cluster model fits or performs this way on the Mac.

## Reproduce

From `ArchiveProcessor/scripts/segbench`, using the shared cached sessions above (original collected artifact `$AGENT_STATE/artifacts/new-open-boxes-20261031`). All page-set scripts run under `python3 ops/autonomous/heavy-run.py run --` from repo root; scorer environment: rapidfuzz, sacrebleu==2.5.1, regex, numpy. No inference needed to reproduce the reports.

1. `corpus/farmshare_expanded_report.py --manifest <recovery>/manifest-895.jsonl --base <recovery>/manifest-440.jsonl --name new-open-boxes-20261031 --out ../../segbench-results/bench-corpus`, with `--route <reader>=<cache>/new-open-895/<reader>/results/ocr/<reader>:native` for both readers.
2. `corpus/farmshare_truth96.py --out ../../segbench-results/farmshare/truth --sacct <cache>/new-open-96/boxes-sacct-96.txt`, with `--route <reader>=<cache>/new-open-96/<reader>:native` for both readers. The normalized sacct receipt is from the artifact's tab-separated sacct.tsv.
3. `ocr_boxes_audit.py`, `ocr_rescore.py`, `ocr_new_open_paired.py`, `ocr_mac_local.py report`, `ocr_pages_export.py`; then `python3 ArchiveOCRBench/build.py` from repo root. The bench includes both cluster readers and the complete granite Mac arm on all applicable charts, while keeping its original difficulty fit unchanged. Receipts: `ArchiveOCRBench/data/new-open-boxes-20261031.json`.
