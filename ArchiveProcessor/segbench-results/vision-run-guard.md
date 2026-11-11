# W46.vision-run-guard — a reference check on every bench Vision run, and one attempt to make the fault recur

Measurement review pass 13, P13-6. One `segbench-dewarp lines` run (2026-11-11 04:49, `ocr_colour_dropout.py vision`)
read 58 of the owner's 96 short, mean NES 60.0 against 83.1, with whole lines missing. It used the same binary, images
and settings as the good runs, and its cause is unknown (`dewarp-bin-reread.md`). Until now no runner checked more than
the exit code.

## The guard

`scripts/segbench/vision_guard.py`: `run()` replaces the bare call to `segbench-ocr` and to `segbench-dewarp lines` in
the 16 runners that read text with them (capture_ladder, chaos_probe, corpus/routes, corpus/sample, data, dewarp_guard,
enh_dewarp, enh_ocr_input, kit_mac_lora, marks_read, mixed_route, ocr_colour_dropout, ocr_panel, ocr_truth,
place_geom_real5, vision_reread). It reads four typed pages of the 96 (p004, p014, p035, p068: four collections,
originals and PDF images; no handwriting, clippings or tables) first and last in the same process as the run's own
jobs. A run is refused when a reference reading has more than one line fewer, or 3% fewer words, than the counts frozen
in `vision_reference.json`. Its new outputs are then moved aside to the cache's `vision-guard/quarantine/` (never
deleted), so a runner that skips existing outputs reads those pages again. The guard also refuses on another macOS build
or a changed reference image until `vision_guard.py freeze` is run again.

The frozen counts (26B123, three identical readings per tool; both tools read the four pages identically): p004 27 lines
/ 281 words, p014 23 / 192, p035 32 / 325, p068 44 / 327, the same as the good 27.2 readings in the cache. The faulty run
read them 11, 7, 12 and 16 lines, 65-75% fewer words, so it would have been refused on every one.

Not guarded: `segbench-dewarp quad` and `encode` (no text), `segbench-ocr-orient`, `segbench-ocr-lines`
(item_fields_retruth) and `layout_photo_vision`, which have other output forms and were not part of the fault.

## One attempt to reproduce

The 96 read 20 times by `segbench-dewarp lines` (sha256 `8c0741beaa66c9b4`), one process each, under the heavy lock,
16.0-16.5 s a run (`vision-run-guard.json`, counts and hashes only). **No short run.** Every run read 4,450-4,455 lines
and 29,191-29,223 words. Against the first run, the only pages that changed were three handwritten ones: p048 in 13 runs,
p050 in 7, p053 in 2. Every typed page read identically in all 20. The fault did not recur, so no app item is filed for
the Processor's own Vision reading; the guard is what catches it if it does.

## Measurement card

- **Truth.** None. Vision readings are compared with Vision readings of the same bytes, and nothing is scored.
- **Selection.** The references are the typed pages of the 96 that the faulty run read short, picked for four collections
  and both image sources; the reproduction reads all 96. Nothing chosen by a tested route or by ABBYY text.
- **Comparison.** Same binary, image bytes (the references hashed in the frozen file), settings and OS build in every run.
- **Noise.** Run-to-run on 27.2: typed pages identical (20 of 20 here; W46.dewarp-bin-reread, 1,532 of 1,536); three
  handwritten pages move. The guard's slack (one line, 3% of words) is a margin over a measured spread of zero on typed
  pages; the fault lost 65-75%.
- **Scope.** One fault in about 5,300 readings checked so far (3,400 in W46.dewarp-bin-reread, 1,920 here). It does not
  explain the fault, does not show whether a fault can strike part of a run between the start and end references, and
  says nothing about the Processor app's own Vision path.
