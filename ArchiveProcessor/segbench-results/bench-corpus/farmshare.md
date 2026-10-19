# Free open-weight sweep on FarmShare (W43.sweep-farmshare)

The fixed original 440-page public reference set, not the later 895-page expansion. Three existing kit
presets, official FP8 checkpoints, one L40S apiece: Qwen3.6 27B, Qwen3.5 27B, Qwen3.6 35B-A3B. Same panel
prompt, 2,400 px JPEG bytes, 8,192 output tokens, temperature zero and thinking off. BF16 KV cache, 16 maximum
sequences, eight concurrent requests: do not treat speed as directly interchangeable with older FP8-KV runs.
Every attempted page is scored, with caps/missing/malformed replies as zero. No paid reference run.

| route | public NES | answered of 440 | capped |
|---|---:|---:|---:|
| Qwen3.6 27B | 51.3 | 372 | 68 |
| Qwen3.5 27B | 49.8 | 345 | 95 |
| Qwen3.6 35B-A3B | 52.4 | 380 | 60 |
| CHURRO-3B, its own XML prompt | 69.9 | 403 | 37 |

Per-stratum figures: `farmshare.csv`; numeric public-page scores: `farmshare-pages.csv`. CHURRO was run once
under W43.script-specialists, with known training overlap on L5/L7/L8; its detailed comparison and uncertainty
are in `specialists.md`. Gemini's existing public reference is 70.3, Qwen3-VL 235B 51.6. These comparisons are
about the seven measured historical strata, not generic accuracy on modern English archive pages.

On the owner's original 96 accuracy photos, Qwen3.5 27B scores 95.33 with all 96 answered, compared with the
existing Qwen3.6 27B's 95.25; 0.08 points is not evidence to change the recommendation. It reads 1,026 photos
per GPU-hour in this run. CHURRO scores 89.09 (94/96 answered), so its public-corpus strength does not make it
the general archive reader. Earlier Qwen3.6 35B/27B owner rows are reused instead of duplicated.

The newer Qwen3.8 Flash Next caches contain metadata only. The cached Intel W4A16 AutoRound checkpoint's
index reports **278.35 GB** of tensors, because many layers remain 16-bit; the earlier estimate that a 4-bit
180B model fits this node is not borne out by that checkpoint. The official FP8 index reports 185.50 GB,
leaving inadequate serving headroom on four 48 GB cards at the kit's .92 memory-utilization ceiling. The
architecture is registered in installed vLLM; checkpoint size, not a missing registry entry, excludes these
builds. No hundreds-of-GB download or speculative whole-node allocation was made. These facts do not prove
that a future different 4-bit build cannot fit. No FP4 kernel assumption was made.

No clear general-archive replacement for Qwen3.6 27B emerges among the selected candidates. CHURRO is useful
on historical scripts as a labelled reference. Larger and hosted sweeps remain separate; no paid benchmarking,
new weights publication or app default change. Jobs: 1855424/25/26, plus shared CHURRO 1855420; all completed
with exit zero. Numeric owner96 results and timings are in `../farmshare/truth/`. No money spent.
