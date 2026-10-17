# On-device models on Herrnstein (development box)

Same windows, prompt (method_window_cues's, the owner's cues) and assembly as the cloud runs (`cues-models-Herrnstein.md`); images shrunk to 1024 px. Run under the Vision OCR lab's memory guard. Own photo labels. One box.

| model | pages in exact doc | false splits | false merges | failed windows | mean s/window | peak GB |
|---|---|---|---|---|---|---|
| Qwen3.5-4B, 4-bit | not collected (0 windows run) | | | | | |
| Gemma 4 12B, 4-bit | not collected (0 windows run) | | | | | |
| Qwen3-VL-8B, 4-bit | not collected (0 windows run) | | | | | |
| Qwen3.5-4B fine-tuned for segmentation, 4-bit | 90.6% | 8 | 1 | 0 | 31 | 5.5 |
| Qwen3.5-2B fine-tuned for segmentation, 4-bit | 90.1% | 0 | 7 | 0 | 15 | 3.6 |
| Qwen3.5-4B fine-tuned for segmentation, 8-bit | 91.2% | 4 | 2 | 0 | 36 | 7.3 |
| Qwen3.5-2B fine-tuned for segmentation, 8-bit | 88.4% | 2 | 3 | 0 | 18 | 4.4 |

## Larger open models through OpenRouter (W41.seg-large), and on FarmShare (W41.farmshare-seg)

The same request, images at the same 1024 px, sent to OpenRouter (`method_openrouter.py`), one provider and precision pinned per model; reasoning off, temperature 0. Seconds are the cloud's, not a Mac's; the memory column is an estimate of the 4-bit weights alone, not measured.

| model, route | pages in exact doc | false splits | false merges | failed windows | mean s/window | GB to hold | cost |
|---|---|---|---|---|---|---|---|
| Qwen3.5 27B (27B dense), OpenRouter deepinfra fp8 | not collected (0 windows run) | | | | | ~17 |
| Qwen3.6 35B-A3B (35B, 3B active), OpenRouter deepinfra fp8 | not collected (0 windows run) | | | | | ~21 |
| Gemma 4 31B (31B dense), OpenRouter crusoe bf16 | not collected (0 windows run) | | | | | ~19 |
| Qwen3.5 122B-A10B (122B, 10B active), OpenRouter siliconflow fp8 | not collected (0 windows run) | | | | | ~70 |
| Qwen3.6 35B-A3B (35B, 3B active), OpenRouter darkbloom fp4 | not collected (0 windows run) | | | | | ~21 |
| Qwen3.5 27B (27B dense), FarmShare L40S vLLM fp8 | 91.7% | 7 | 1 | 0 | 83 (L40S) | ~17 (4-bit, est.) | $0.000 |
| Qwen3.5 4B, untrained (4B dense), FarmShare L40S vLLM bf16 | 76.2% | 20 | 3 | 1 | 18 (L40S) | ~3 (4-bit, est.) | $0.000 |
| Qwen3.5 4B, fine-tuned on a quarter of the corpus (pilot) (4B dense), FarmShare L40S vLLM bf16 | 95.0% | 2 | 2 | 0 | 14 (L40S) | ~3 (4-bit, est.) | $0.000 |
| Qwen3.5 4B, fine-tuned (4B dense), FarmShare L40S vLLM bf16 | 91.2% | 2 | 2 | 0 | 15 (L40S) | ~3 (4-bit, est.) | $0.000 |
| Qwen3.5 2B, fine-tuned (2B dense), FarmShare L40S vLLM bf16 | 88.4% | 2 | 3 | 0 | 8 (L40S) | ~1.5 (4-bit, est.) | $0.000 |
