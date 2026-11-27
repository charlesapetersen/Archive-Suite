# W46.ocr-family-coverage: readers from families never measured, on the 895 and the 96

The owner asked on 2026-11-17 for readers from families the bench had never measured. Four came back from Sherlock.
**CHURRO-3B now leads N6 (Devanagari print)**: 92.0 strict, +13.3 points (+11.7 to +15.0) over Xiaomi-OCR-0, which was
the pick there. No other group's pick changes. CHURRO does not lead the English hands it was not trained on (L1 −5.2,
L2 −7.9 against Qwen3.6 27B), so it is not a cluster hand reader. On the owner's 96, olmOCR-2 7B (92.45) and Chandra-2
(92.32) read better than LightOnOCR-3 4B (+3.0 and +2.9, intervals clear of 0) but stay behind Qwen3.6 27B (−1.9 and
−2.0) and the cluster leader Qwen3.5 27B (95.40). dots.ocr is behind on both sets. DeepSeek-OCR-2 and MinerU2.5-Pro
failed at engine load and read nothing; their rerun is `W46.ocr-family-coverage-rerun`. No money spent.

## Runs and failures

Sherlock batch 20261117-214529, submitted by the owner's session, collected 2026-11-26 (artifact
`$AGENT_STATE/artifacts/ocr-family-coverage-20261117`, copied to `family-{895,96}` in the shared Sherlock results cache).
One CPU setup job (52765234, 10 min), then one GPU job per model and set, the 96 after the 895. The routes are each
family's card route through vLLM 0.31.0 in process (`sherlock/family-coverage/family_run.py`, batches of 16), greedy,
8,192 new tokens, the frozen page JPEGs. The prompt, model revision and reduction to text per route are in the item's
kit and `ArchiveOCRBench/data/family-coverage-20261126.json`; every `prepared.json` reports `sha_check: matches`.

| Reader | Model (revision) | 895 job | 96 job | Outcome |
|---|---|---|---|---|
| olmOCR-2 7B fp8 | `allenai/olmOCR-2-7B-1025-FP8` (`40bd7202`) | 52765236 | 52765237 | complete |
| Chandra-2 | `datalab-to/chandra-ocr-2` (`af93b47d`) | 52765243 | 52765248 | complete |
| dots.ocr | `rednote-hilab/dots.ocr` (`c0111ce6`) | 52765252 | 52765254 | complete |
| CHURRO-3B | `stanford-oval/churro-3B` (`ca2150ea`) | 52765261 (its 455) | — (FarmShare's 96 stands) | complete |
| DeepSeek-OCR-2 | `deepseek-ai/DeepSeek-OCR-2` (`aaa02f38`) | 52765255 | 52765256 | **failed at load**, 96 cancelled |
| MinerU2.5-Pro-2605 1.2B | `opendatalab/MinerU2.5-Pro-2605-1.2B` (`08aaea84`) | 52765258 | 52765260 | **failed at load**, 96 cancelled |

- **The two failures** are one cause. vLLM 0.31 picks its new (v2) GPU model runner when `VLLM_USE_V2_MODEL_RUNNER`
  is unset, and that runner refuses a v1 logits processor class at engine load: `NGramPerReqLogitsProcessor is not a
  subclass of vllm.v1.worker.gpu.sample.logits_processor.LogitsProcessor` (DeepSeek's recipe processor), and the same
  for mineru-vl-utils 2.0.9's `VllmV1NoRepeatNGramLogitsProcessor`. Both died within a minute, before the pilot read a
  page. The kit now sets `VLLM_USE_V2_MODEL_RUNNER=0` for any route with such a processor (vLLM 0.31's `envs.py`: set
  to 0 it is False, the v1 runner) and records it in the settings; the three-page pilot gate will show at once if that
  runner is gone too. Their rerun is a new small pack, `W46.ocr-family-coverage-rerun`.
- **CHURRO-3B's 895 row** joins its 455 Sherlock readings to the FarmShare 440 (churro-1855420, its XML reduced by the
  same `churro_text`). Its pilot read one page of the 440 (`ocrd__aepinus_bekentnis_1548…_0007`); that page keeps its
  FarmShare reading, as the 440 row always had it. The two runs differ in hardware and vLLM version, not in prompt,
  preset or token cap.
- No page raised an error. A cap (8,192 tokens reached) or an empty reply scores 0 strict.

## Reading accuracy

NES %, failed pages as 0 (strict) and on each reader's own answered pages. The 96 are the 99 owner pages without the
three agreement letters; the bench headline sets p081 apart. Incumbents are the bench's rows.

| Set | Reader | Answered / n | Strict NES | NES answered | Caps |
|---|---|---:|---:|---:|---:|
| owner96 | olmOCR-2 7B (Sherlock) | 96/96 | 92.45 | 92.45 | 0 |
| owner96 | Chandra-2 (Sherlock) | 96/96 | 92.32 | 92.32 | 0 |
| owner96 | dots.ocr (Sherlock) | 95/96 | 90.52 | 91.5 | 3 (of 99) |
| owner96 | CHURRO-3B (FarmShare, 2026-10-18) | 94/96 | 89.09 | 91.07 | 2 |
| owner96 | qwen3.6-27b | 95/96 | 94.35 | 95.34 | |
| owner96 | lightonocr3-4b | 96/96 | 89.43 | 89.43 | |
| public895 | CHURRO-3B (455 Sherlock + 440 FarmShare) | 767/895 | 67.80 | 79.12 | 128 failed |
| public895 | Chandra-2 (Sherlock) | 771/895 | 60.73 | 70.50 | 123 |
| public895 | olmOCR-2 7B (Sherlock) | 693/895 | 53.45 | 69.04 | 182 |
| public895 | dots.ocr (Sherlock) | 715/895 | 52.72 | 65.99 | 174 |
| public895 | qwen3.6-27b | 798/895 | 63.26 | 70.95 | |
| public895 | lightonocr3-4b | 810/895 | 62.88 | 69.48 | |

On the 96 by kind (strict): olmOCR-2 typewritten 95.07, printed 91.70, handwritten 88.38; Chandra-2 94.30, 91.88,
89.48; dots.ocr 95.72, 87.69, 82.46. The kind leaders are hosted routes (typewritten 98.8, printed 96.3, handwritten
95.8); among cluster routes Qwen3.5 27B leads (97.61 typewritten, 95.13 printed). None of the three leads a kind.

The 895 by stratum (strict NES, 80 pages a stratum, L9 15, N 40):

| Reader | L1 | L2 | L3 | L4 | L5 | L6 | L7 | L8 | L9 | N1 | N2 | N3 | N4 | N5 | N6 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| CHURRO-3B | 83.2 | 65.7 | 94.3 | 52.4 | 62.8 | 69.4 | 53.9 | 92.6 | 40.2 | 69.2 | 3.3 | 84.7 | 57.9 | 46.2 | **92.0** |
| Chandra-2 | 85.9 | 72.5 | 94.2 | 59.3 | 54.2 | 34.9 | 38.2 | 86.0 | 63.8 | 54.0 | 10.6 | 51.2 | 36.0 | 65.5 | 67.4 |
| olmOCR-2 7B | 87.9 | 74.3 | 93.8 | 60.6 | 45.4 | 34.4 | 18.0 | 87.2 | 7.9 | 29.5 | 6.3 | 16.6 | 2.5 | 55.6 | 79.2 |
| dots.ocr | 76.2 | 65.3 | 93.7 | 60.6 | 46.9 | 24.2 | 18.7 | 87.4 | 57.4 | 29.5 | 8.7 | 16.3 | 13.1 | 79.3 | 64.8 |
| qwen3.6-27b | 88.4 | 73.5 | 96.0 | 69.3 | 50.5 | 46.3 | 34.1 | 86.2 | 93.6 | 43.6 | 17.1 | 41.4 | 45.8 | 80.7 | 63.3 |
| xiaomi-ocr-0 | 85.3 | 76.1 | 93.1 | 52.2 | 58.1 | 47.1 | 43.9 | 88.6 | 95.2 | 31.4 | 27.1 | 39.7 | 11.1 | 79.7 | 78.7 |

CHURRO's L5-L8, N1, N3 and N4 are its FarmShare readings, unchanged. Full 440/455 subsets and every stratum figure:
`family-coverage-20261126.csv`; per-page scores: `-pages.csv` and `../ocr-scorers-pages.csv`.

## Paired differences

New reader minus incumbent, NES points, 95% bootstrap interval (`ocr_new_open_paired.py`, `../new-open-paired.json`).
Under the tie rule (owner, 2026-11-24) a gap under 0.5 points is a tie and the interval makes none.

| Set | Reader | Against | Strict | Both answered | n both |
|---|---|---|---:|---:|---:|
| owner96 | olmOCR-2 7B | qwen3.6-27b | −1.90 (−4.48 to +0.84) | −2.79 (−4.97 to −1.01) | 95 |
| owner96 | olmOCR-2 7B | lightonocr3-4b | +3.02 (+0.41 to +5.93) | +3.02 (+0.41 to +5.93) | 96 |
| owner96 | Chandra-2 | qwen3.6-27b | −2.03 (−5.08 to +1.09) | −3.06 (−5.66 to −1.01) | 95 |
| owner96 | Chandra-2 | lightonocr3-4b | +2.89 (+0.21 to +5.75) | +2.89 (+0.21 to +5.75) | 96 |
| owner96 | dots.ocr | qwen3.6-27b | −3.83 (−6.91 to −0.82) | −3.88 (−5.76 to −2.23) | 94 |
| owner96 | dots.ocr | lightonocr3-4b | +1.09 (−2.20 to +4.39) | +1.80 (−1.03 to +4.93) | 95 |
| public895 | CHURRO-3B | qwen3.6-27b | +4.54 (+2.50 to +6.58) | +7.70 (+6.38 to +8.99) | 707 |
| public895 | CHURRO-3B | lightonocr3-4b | +4.92 (+3.06 to +6.71) | +8.34 (+7.23 to +9.48) | 726 |
| public895 | Chandra-2 | qwen3.6-27b | −2.53 (−4.11 to −0.93) | −1.06 (−2.07 to −0.10) | 716 |
| public895 | Chandra-2 | lightonocr3-4b | −2.15 (−3.58 to −0.72) | +0.24 (−0.75 to +1.18) | 731 |
| public895 | olmOCR-2 7B | qwen3.6-27b | −9.81 (−11.54 to −8.12) | −3.59 (−4.57 to −2.61) | 656 |
| public895 | dots.ocr | qwen3.6-27b | −10.54 (−12.14 to −8.97) | −6.71 (−7.77 to −5.67) | 670 |

The pick questions, strict, per stratum (n 80, N6 40):

- **N6 (Devanagari print):** CHURRO-3B − Xiaomi-OCR-0 (the pick) +13.30 (+11.72 to +14.98); − Infinity-Parser2-Pro
  +13.71 (+10.17 to +17.52). CHURRO-3B becomes the N6 leader. Chandra-2 − Xiaomi −11.29.
- **English hands:** CHURRO-3B − Qwen3.6 27B L1 −5.16 (−8.84 to −2.16), L2 −7.88 (−14.39 to −1.94), L3 −1.69; −
  Infinity L1 −8.91. Chandra-2 − Infinity L1 −6.24, L2 −7.56. Infinity-Parser2-Pro stays the L1-L3 cluster pick.
- **Forms (L4):** best new reader olmOCR-2 and dots.ocr at 60.6; Chandra-2 − Qwen3.5 27B (the pick) −10.70 (−17.74 to
  −4.08). No change.
- **Newspapers (L9), N2, N5:** every new reader trails the pick by 13 points or more.

## Speed

One Sherlock card per job, 48 or 80 GB, type not recorded. Collector seconds are the pilot plus the full pass, batches
of 16; model load is beside it and Slurm start-up is not counted. A page's own seconds are its batch's wall time, so
they are not a one-page latency.

| Set | Reader | Collector s | Load s | Pages/hour/GPU | Slurm elapsed |
|---|---|---:|---:|---:|---:|
| public895 | olmOCR-2 7B | 3,900 | 131 | 826 | 1:07:44 |
| public895 | Chandra-2 | 3,801 | 178 | 848 | 1:06:43 |
| public895 | dots.ocr | 2,891 | 116 | 1,115 | 0:50:24 |
| public895 (its 455) | CHURRO-3B | 2,122 | 96 | 774 | 0:37:15 |
| owner99 | olmOCR-2 7B | 73 | 129 | 4,909 | 0:03:52 |
| owner99 | Chandra-2 | 64 | 139 | 5,534 | 0:03:37 |
| owner99 | dots.ocr | 256 | 101 | 1,391 | 0:06:11 |

The 895's capped pages run to 8,192 tokens and dominate its time; the 96 has almost none. The batch used 3.94
GPU-hours (Slurm elapsed, the two failed loads included) and 10 CPU minutes, against the preparation's 9 expected and
40 reserved.

## Measurement card

- **Truth:** frozen public transcriptions on the 895 (not owner-checked); on the 96 the adjudicated panel truth with
  the owner's corrected hand sheet, drafted by Claude Opus 5.5 and Gemini 3.8 Flash. None of the four readers or its
  family drafted it. CHURRO-3B was trained on CHURRO-DS, the source of the 440's strata (OCR-15); N6 is one of the
  added 455's strata (`src_devanagari.py`), so whether its N6 pages overlap CHURRO-DS is `W46.ocr-churro-overlap`'s
  question, and its N6 lead carries OCR-15 until that check runs.
- **Selection:** the same frozen 895 and 96 every open reader read; no selection by a tested reader or by ABBYY text.
  The readers were chosen by family before any read a page (owner, 2026-11-17).
- **Comparison:** each family's card route and prompt, reduced to text by its own format, greedy, 8,192 new tokens,
  the same image bytes (sha256 checked per page on the 96). Settings that differ from a card (temperature 0 where
  olmOCR's pipeline samples at 0.1 with retries; a 8,192 cap where dots.ocr allows 24,000) are kept for comparability
  and listed in the kit. Route comparison, not a model comparison under one prompt.
- **Noise:** n 895 (40-80 a stratum) and 96, seeded paired 95% bootstrap intervals, one greedy reading each; the
  practical floor of 0.5 points is the tie rule. CHURRO's N6 lead is 26 times that floor and its interval is far from 0.
- **Scope:** whole-page transcription only. dots.ocr's layout boxes are saved (`boxes` in each record) and not
  scored. Not settled: DeepSeek-OCR-2 and MinerU2.5-Pro (rerun pending), CHURRO's training overlap on N6, whether
  these readers fit or behave this way on the Mac, and table-cell reading (`W46.ocr-cells-l4-more`).

## Reproduce

From `ArchiveProcessor/scripts/segbench/corpus`, with `SH=~/Library/Caches/ArchiveSuiteRehearsal/sherlock-results`
and `RC="~/Claude/Long term storage/FarmShare-20261019/recovery"`; scorer environment rapidfuzz, sacrebleu==2.5.1,
regex, numpy; every command under `python3 ops/autonomous/heavy-run.py run --`. `family-sacct.txt` is the artifact's
sacct.tsv as `JobID|JobName|State|Elapsed|AllocTRES`. `churro-3b-joined/` holds the 455's records plus the FarmShare
440's with `raw` reduced by `farmshare_results.churro_text` (the 440's copy of the pilot page wins).

```
farmshare_expanded_report.py --manifest "$RC/manifest-895.jsonl" --base "$RC/manifest-440.jsonl" \
  --name family-coverage-20261126 --out ../../../segbench-results/bench-corpus \
  --route "olmocr-2-7b=$SH/family-895/olmocr-2-7b-fp8/results/ocr/olmocr-2-7b-fp8:native" \
  --route "chandra-ocr-2=$SH/family-895/chandra-ocr-2/results/ocr/chandra-ocr-2:native" \
  --route "dots-ocr=$SH/family-895/dots-ocr/results/ocr/dots-ocr:native" \
  --route "churro-3b=$SH/family-895/churro-3b-joined:native"
farmshare_truth96.py --out ../../../segbench-results/farmshare/truth --sacct "$SH/family-sacct.txt" \
  --route "olmocr-2-7b=$SH/family-96/olmocr-2-7b-fp8:native" --route "chandra-ocr-2=$SH/family-96/chandra-ocr-2:native" \
  --route "dots-ocr=$SH/family-96/dots-ocr:native"
```

Then from `..`: `ocr_rescore.py --merge <route> --merge-set owner96|public895` for each route, `ocr_new_open_paired.py`,
`ocr_pages_export.py`, and from the repository root `python3 ArchiveOCRBench/build.py`. No inference is needed.
