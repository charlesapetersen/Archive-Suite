# W46.truth-jpeg-upgrade — fifteen truth pages from their JPEG originals, 2026-10-29

Owner, 2026-10-22: the truth images are the JPEG originals, never the ABBYY-processed corpus PDFs. 33 of the 96 had been
built from the image inside the corpus PDF. Fifteen now come from the original: eight paired by `corpus_pairs.py` and
confirmed by the truth builder's grey correlation (0.76-0.98), and seven named by the owner on the 2026-10-23 sheet
(`truth-jpeg-owner-answers.tsv`; p083 and p084 correlate 0.43-0.48 only because the PDF is cropped and deskewed). The
other 18 keep the PDF image: 16 have no JPEG, p014's named file is itself a FineReader PDF, and p027's JPEG is not
found yet. Script: `scripts/segbench/truth_jpeg_upgrade.py`; the PDF images stay in the private cache's `pages-pdf/`.

## Does the truth still read true?

Three readers checked each truth text against the new image at full resolution. Thirteen hold. Two proposed edits,
neither caused by the image and neither applied here (the truth's hash is frozen into every panel's manifest, and the
truth is the owner's adjudication):

- p088: the handwritten "don't" at the foot is in the truth twice (after the phone number and again as the last
  words); the page has it once.
- p025: "San Francisco 4, California" may be "6" (the original shows a 6-like shape; the PDF image is ambiguous).

Both the old and the new readings below are scored against the unchanged truth, so the comparison is fair.

## What the PDF images cost per route

Each route read both images of the 15 pages at the panel's 2,400 px ceiling with its panel settings; NES is the
panel's score (`ocr_panel_score.score`, a failed page counting 0). The 96-page means on the PDF images reproduce
`ocr-pages.csv` exactly.

| route | pages | PDF image | JPEG original | change | sharper: PDF → JPEG | upscaled: PDF → JPEG | 96-page mean: PDF → JPEG |
|---|---|---|---|---|---|---|---|
| apple-vision | 15 | 0.889 | 0.847 | -0.042 | 0.853 → 0.821 (10) | 0.961 → 0.898 (5) | 0.813 → 0.807 |
| qwen3-vl-8b-mlx4 | 15 | 0.939 | 0.937 | -0.002 | 0.911 → 0.915 (10) | 0.995 → 0.981 (5) | 0.897 → 0.896 |
| lightonocr-3-4b-mlx8 | 15 | 0.933 | 0.920 | -0.013 | 0.904 → 0.898 (10) | 0.992 → 0.965 (5) | 0.891 → 0.889 |
| qwen3.5-9b-mlx4 | 15 | 0.871 | 0.870 | -0.001 | 0.816 → 0.813 (10) | 0.980 → 0.983 (5) | 0.919 → 0.919 |
| gemini3.7-flash-gw | 15 | 0.998 | 0.992 | -0.006 | 0.997 → 0.994 (10) | 0.999 → 0.988 (5) | 0.967 → 0.966 |

"Upscaled" is the five pages (p008, p028, p088, p091, p093) whose PDF image is a ~2x FineReader upscale of a small
original, so for them the original is smaller, not sharper. "Sharper" is the other ten.

**The PDF images cost nothing; if anything they help.** No route reads the originals better. On the ten pages where
the original is the sharper photograph the change is within ±0.4 points for the three MLX readers and Gemini; on the
five upscaled pages every route but Qwen3.5-9B loses 1-6 points, as a 550 px original would predict. Apple Vision
loses most, and most of it on p025, a thin sheet over another letter: the letter beneath shows through on both
images, but on the crisper original Vision reads it as text (138 words against 70 on the PDF image; 0.86 → 0.47).
A sharper photograph also makes the sheet behind more legible, which the truth rules leave out. On the 96 the
largest change is Apple Vision's 0.6 points; every other route moves 0.2 points or less, so no ranking on the bench
changes.

Two cautions. The truth was drafted (Claude Opus 5.5, Gemini 3.8 Flash) and adjudicated from the PDF images, which
favours them where the two images differ in what is legible. And only the five routes that cost nothing or almost
nothing were rerun; the OpenRouter panels and the cluster readers still read the PDF images of these 15 pages
(W46.truth-jpeg-rest).

Cost: the Mac routes are free. Gemini 3.7 Flash through the Stanford gateway, 29 calls (15 pages; a second run
started by mistake repeated 14 of them), about $0.13 estimated from its tokens at Gemini 3.8 Flash's list price.
