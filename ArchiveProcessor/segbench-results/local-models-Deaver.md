# On-device models on Deaver (development box)

Same windows, prompt (method_window_cues's, the owner's cues) and assembly as the cloud runs (`cues-models-Deaver.md`); images shrunk to 1024 px. Run under the Vision OCR lab's memory guard. Own photo labels. One box.

| model | pages in exact doc | false splits | false merges | failed windows | mean s/window | peak GB |
|---|---|---|---|---|---|---|
| Qwen3.5-4B, 4-bit | 57.4% | 28 | 6 | 0 | 33 | 5.5 |
| Gemma 4 12B, 4-bit | 46.8% | 37 | 1 | 8 | 60 | 12.3 |
| Qwen3-VL-8B, 4-bit | 53.2% | 16 | 10 | 1 | 57 | 7.9 |
| Qwen3.5-4B fine-tuned for segmentation, 4-bit | 87.9% | 4 | 2 | 0 | 33 | 5.5 |
| Qwen3.5-2B fine-tuned for segmentation, 4-bit | 75.2% | 1 | 10 | 2 | 16 | 3.6 |
| Qwen3.5-4B fine-tuned for segmentation, 8-bit | 88.7% | 1 | 3 | 0 | 38 | 7.3 |
| Qwen3.5-2B fine-tuned for segmentation, 8-bit | 90.1% | 3 | 3 | 0 | 19 | 4.3 |

## Larger open models through OpenRouter (W41.seg-large), and on FarmShare (W41.farmshare-seg)

The same request, images at the same 1024 px, sent to OpenRouter (`method_openrouter.py`), one provider and precision pinned per model; reasoning off, temperature 0. Seconds are the cloud's, not a Mac's; the memory column is an estimate of the 4-bit weights alone, not measured.

| model, route | pages in exact doc | false splits | false merges | failed windows | mean s/window | GB to hold | cost |
|---|---|---|---|---|---|---|---|
| Qwen3.5 27B (27B dense), OpenRouter deepinfra fp8 | 95.0% | 0 | 3 | 0 | 10 (cloud) | ~17 (4-bit, est.) | $0.201 |
| Qwen3.5 27B (27B dense), FarmShare L40S vLLM fp8 | 96.5% | 0 | 2 | 0 | 92 (L40S) | ~17 (4-bit, est.) | $0.000 |
| Qwen3.5 4B, untrained (4B dense), FarmShare L40S vLLM bf16 | 56.0% | 29 | 1 | 0 | 19 (L40S) | ~3 (4-bit, est.) | $0.000 |
| Qwen3.5 4B, fine-tuned on a quarter of the corpus (pilot) (4B dense), FarmShare L40S vLLM bf16 | 92.2% | 2 | 2 | 0 | 16 (L40S) | ~3 (4-bit, est.) | $0.000 |
| Qwen3.5 4B, fine-tuned (4B dense), FarmShare L40S vLLM bf16 | 92.2% | 1 | 3 | 0 | 16 (L40S) | ~3 (4-bit, est.) | $0.000 |
| Qwen3.5 2B, fine-tuned (2B dense), FarmShare L40S vLLM bf16 | 88.7% | 4 | 3 | 0 | 8 (L40S) | ~1.5 (4-bit, est.) | $0.000 |
| Qwen3.6 35B-A3B (35B, 3B active), OpenRouter deepinfra fp8 | 91.5% | 0 | 4 | 0 | 5 (cloud) | ~21 (4-bit, est.) | $0.074 |
| Gemma 4 31B (31B dense), OpenRouter crusoe bf16 | 81.6% | 7 | 3 | 0 | 28 (cloud) | ~19 (4-bit, est.) | $0.062 |
| Qwen3.5 122B-A10B (122B, 10B active), OpenRouter siliconflow fp8 | 84.4% | 6 | 3 | 0 | 13 (cloud) | ~70 (4-bit, est.) | $0.184 |
| Qwen3.6 35B-A3B (35B, 3B active), OpenRouter darkbloom fp4 | 87.9% | 2 | 5 | 0 | 13 (cloud) | ~21 (4-bit, est.) | $0.042 |

**FarmShare (W41.farmshare-seg-run, 2026-10-15).** The same 51 requests (`farmshare/fs_seg.py`), answered by the official `Qwen/Qwen3.5-27B-FP8` served by vLLM 0.31 on one FarmShare L40S, 16 windows at a time: 96.5% of pages in the exact document, no false split and two false merges, against OpenRouter's 95.0% for the same model at fp8. 307 s for the box, 1,749 pages an hour per GPU; its seconds a window are with 16 in flight, so they do not compare with the cloud's. An earlier run the same day, through a route since replaced by this one (32,768 tokens, eight images a prompt), gave 93.6% (one false split, three merges): the same model and windows at temperature 0 moved by three points between runs, so a point or two between these rows is noise, as the verdict below says of small counts. No money.

**The corpus-trained segmenters (W41.seg-finetune, W41.seg-mac-model, 2026-10-17).** The "fine-tuned for segmentation" rows above are the Qwen3.5 4B and 2B trained on the owner's corpus and converted to MLX on this Mac; the FarmShare bf16 rows are the same models (and the untrained 4B) on an L40S. The fine-tuned FarmShare rows come from the five-box run, so Deaver reads a point or two from the development-only run. Full figures and the reading: `seg-students.md`.

**Verdict (2026-10-13).** Local segmentation is not closed. Qwen3.5 27B, which a 32 GB Mac could hold at 4-bit, reached 95.0% against the cloud models' 97.9% (two more false merges, no false splits), with smaller images than theirs (1024 px against 1600). That is near enough for a fine-tune, or a 4-bit run on a Mac, to be worth discussing; it is far from the 4B-12B models' 47-57%. Three cautions. It is one box of 149 pages, where each mistake moves the figure by several points, and bigger did not mean better: the 122B scored below the 27B. These ran at fp8 or bf16, and a Mac runs 4-bit: the one fp4 build offered (Qwen3.6 35B-A3B) lost 3.6 points to its fp8 run, so expect a 4-bit 27B somewhat below 95%. And the seconds are the cloud's: a dense 27B on a Mac reads seven pages far slower than the 4B-12B rows above.
