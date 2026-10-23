# The CHAOS-style altered-word probe on 20 typed owner pages (W46.fix-ocr-scorers)

20 typewritten pages of the owner's 96, 60 words altered by one letter, of which 6 failed the eye check of their crops and are left out, so 54 are scored (`scripts/segbench/chaos_probe.py`; images, truths and the word list are private, in the cache). **recall** is the share of altered words the reading reproduces as printed (CHAOS-Bench's measure); **corrected** means the reading has the original, expected word instead. NES is against the altered truth.

| route | pages read | copied (recall) | corrected | other | unread | NES |
|---|---:|---:|---:|---:|---:|---:|
| ppocrv6-medium | 20 | 52 (96%) | 0 | 2 | 0 | 92.4 |
| apple-vision | 20 | 48 (89%) | 2 | 4 | 0 | 95.3 |
| gemini3.7-flash-gw | 20 | 34 (63%) | 20 | 0 | 0 | 97.8 |
| qwen3.5-4b | 20 | 30 (56%) | 20 | 4 | 0 | 95.6 |
| qwen3-vl-8b | 19 | 15 (28%) | 32 | 4 | 3 | 92.2 |
| glm-ocr | 20 | 12 (22%) | 39 | 3 | 0 | 96.3 |
| lightonocr3-0.8b | 20 | 6 (11%) | 46 | 2 | 0 | 96.4 |
| paddleocr-vl1.5 | 19 | 6 (11%) | 44 | 1 | 3 | 93.5 |
| lightonocr3-4b | 20 | 3 (6%) | 48 | 3 | 0 | 97.0 |
