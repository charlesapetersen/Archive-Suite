# On-device models on Deaver (development box)

Same windows, prompt (method_window_cues's, the owner's cues) and assembly as the cloud runs (`cues-models-Deaver.md`); images shrunk to 1024 px. Run under the Vision OCR lab's memory guard. Own photo labels. One box.

| model | pages in exact doc | false splits | false merges | failed windows | mean s/window | peak GB |
|---|---|---|---|---|---|---|
| Qwen3.5-4B, 4-bit | 57.4% | 28 | 6 | 0 | 33 | 5.5 |
| Gemma 4 12B, 4-bit | 46.8% | 37 | 1 | 8 | 60 | 12.3 |
| Qwen3-VL-8B, 4-bit | 53.2% | 16 | 10 | 1 | 57 | 7.9 |
