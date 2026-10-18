# Models built for the hard scripts and hands (W43.script-specialists)

Runner: `scripts/segbench/corpus/specialists.py` (kraken lane) and `trocr_lines.py` (a TrOCR line model on the
same lines). Scores: `specialists.csv` (by model and stratum, paired against the reference routes) and
`specialists-pages.csv` (by page, public page ids, no text). Same frozen pages, checksums and scorer as
`routes.py`; see this folder's README for the strata and their caveats.

## Which strata the reference routes read worst

The better of Gemini 3.8 Flash and Qwen3-VL 235B on each page, NES % (failures scored 0):

| stratum | best of the two | pages under 50 | Gemini | Qwen (the open-weight route) |
|---|---:|---:|---:|---:|
| N4 Hebrew book hands | 46.5 | 30 of 40 | 46.1 | 12.3 |
| L7 charters before 1600 | 59.4 | 22 of 80 | 58.0 | 42.5 |
| L5 Romance and Dutch hands | 64.5 | 26 of 80 | 63.2 (iForal 44.6) | 54.1 (iForal 29.0) |
| N1 Arabic manuscripts | 77.2 | 4 of 40 | 74.7 | 44.8 |
| L6 German Kurrent | 82.5 | 3 of 80 | 72.9 | 47.7 |
| N3 Greek minuscule | 89.9 | 1 of 40 | 88.8 | 47.9 |
| L8 early print | 90.5 | 0 of 80 | 87.8 | 86.7 |

For a hosted reader the gaps are N4, L7 and L5. For open weights, every stratum but L8 is 30-75 points below Gemini.

## Results: the kraken lane on this Mac (2026-10-17)

Eight open models, 16-25 MB each (TrOCR Kurrent 0.3B), on the 320 frozen pages of L5, L6, L7, N3 and N4. kraken
7.1.1's default blla segmenter cut each kept original into lines once (about 30 s a page on one core); every
model read the same lines (about 9 s a page on the CPU; TrOCR about 25 s on MPS). NES %, failures as 0 (none
failed); the paired columns are the model minus the reference route on the same pages, NES points, with the 95%
bootstrap interval.

| stratum | model | trained on a test source | NES | 2nd | chrF | minus Gemini | minus Qwen |
|---|---|---|---:|---:|---:|---:|---:|
| L5 | **CATMuS Medieval 1.5** | none listed (see below) | **65.6** | 67.0 | 70.4 | +2.4 (-1.3 to 6.2) | +11.5 (7.5 to 16.0) |
| L5 | TRIDIS | Königsfelden (not this stratum) | 59.1 | 61.4 | 54.4 | -4.1 (-6.9 to -0.9) | +5.0 (1.1 to 9.2) |
| L5 | McCATMuS | unknown | 47.0 | 48.2 | 35.1 | -16.2 | -7.1 |
| L6 | **Mannheim german_handwriting** | none listed | **72.6** | 73.6 | 54.9 | -0.2 (-8.1 to 8.0) | +24.9 (20.9 to 29.2) |
| L6 | dh-unibe TrOCR Kurrent | unknown | 67.3 | 68.3 | 56.7 | -5.6 (-13.2 to 2.6) | +19.6 (14.8 to 24.2) |
| L6 | kurrent_v3 (german_handwriting + 12 pages) | none listed | 64.2 | 65.8 | 41.4 | -8.6 | +16.5 |
| L6 | McCATMuS | unknown | 39.1 | 39.6 | 23.7 | -33.8 | -8.6 |
| L7 | TRIDIS | **Königsfelden** | 46.4 | 47.6 | 34.9 | -11.5 (-16.3 to -6.4) | +3.9 (-1.3 to 8.9) |
| L7 | CATMuS Medieval 1.5 | none listed | 38.7 | 40.4 | 24.0 | -19.2 | -3.8 (-8.2 to 0.4) |
| N3 | BBAW greek_minuscule_s9-12 | unknown | 63.2 | 70.5 | 34.7 | -25.5 (-28.5 to -20.8) | +15.4 (11.4 to 20.0) |
| N4 | BiblIA_01 | **BiblIA** | 49.3 | 49.4 | 70.1 | +3.2 (-4.2 to 10.2) | +37.0 (30.3 to 43.6) |

By source, NES (Gemini's on the same pages in brackets): L5 Castilian 77.2 CATMuS (71.3), iForal 45.7 CATMuS
(44.6); L6 Kurrent 74.9 german_handwriting (70.4), READ 2017 65.8 (80.3).

**What it says.**
- **For an open-weight reader, a script model is worth having.** On L5, L6, N3 and N4 the best kraken model beats
  Qwen3-VL 235B, the open-weight reference route, by 11.5 to 37 NES points, at 16 MB on a laptop CPU, where Qwen
  ran 75 of its 440 pages into the token limit. The comparison with the open-weight models that FarmShare runs
  (Qwen3.6 27B, W43.sweep-farmshare) is still to make.
- **Against Gemini, two match it and none clearly beats it.** Mannheim's German handwriting model ties Gemini on
  L6 (-0.2, interval -8.1 to 8.0) and beats it on the Kurrent pages; CATMuS Medieval is 2.4 points ahead on L5,
  an interval that includes 0, ahead on the Castilian pages and level on iForal. CATMuS was trained on HTRomance
  Spain, BnF manuscripts edited by the same group that published the Castilian test set; the documents are
  different as far as the record shows, which was inferred, not checked page by page.
- **The charters (L7) have no open answer.** TRIDIS, trained on the Königsfelden corpus itself, is still 11.5
  below Gemini, and CATMuS, which has no Middle High German, is 19 below. The Bern models built for these
  charters are trained on them (not run).
- **Hebrew: BiblIA's own model, trained on BiblIA, ties Gemini on NES** (+3.2, -4.2 to 10.2), loses on the
  second score (49.4 against Gemini's 67.8 without vowel points: the model writes none, so the score barely moves
  for it) and wins on chrF (below). It is an upper bound, not a specialist: no clean Hebrew model exists.
- **Greek: the BBAW model, trained on 9th-12th c. hands, is 25 points below Gemini** on EPARCHOS's 16th c.
  ones (no marks: 70.5 against 90.3).
- **chrF, which hardly sees line order, splits the two kinds of loss.** Gemini's chrF on these strata is L5 61.1,
  L6 67.2, L7 44.1, N3 79.3, N4 47.9. BiblIA's model is 22 chrF points above Gemini on N4 (70.1) and CATMuS 9 above
  on L5 (70.4): there the NES gap is largely reading order (two columns, the masorah, marginalia placed where blla
  puts them), and a better line order would raise their NES. Mannheim's L6 model (54.9) and the L7 and N3 models
  (24-35) are below Gemini on chrF too, so their losses are in the letters, not the order.
- McCATMuS, a generic 16th-21st c. model, is below Qwen everywhere; a fine-tune on 12 pages of one writer
  (kurrent_v3) lost 8 points against its base.

**Caveats.** Every model gets blla's default segmentation and reading order, not the segmenter it was trained
with (BiblIA ships its own); a model trained on another segmenter's lines is disadvantaged here. BiblIA_01 writes
lines in visual order, reversed to logical by grapheme before scoring. No model was tuned on these pages.

## The candidates (survey, 2026-10-17)

From the models' own Zenodo and Hugging Face records. **Contamination** is the main finding: three of the newest
broad historical models were trained on our test sources. Kiessling's kraken **PP-OCRv6** (Zenodo 21788410) and
**Party** (20642057) list EPARCHOS, Muharaf, Königsfelden, OCR-D, HTR-United, iForal and VOC; **CHURRO-3B**
(`stanford-oval/churro-3B`) lists Königsfelden, iForal, the HTR-United Castilian set, VOC and OCR-D. Those can be
labelled references, never a stratum's specialist.

| stratum | run here (Mac, kraken lane) | FarmShare, needs a login | not run: trained on the test source |
|---|---|---|---|
| L5 | CATMuS Medieval 1.5, TRIDIS, McCATMuS | CHURRO-3B (contaminated); Loghi for the Dutch pages (likely trained on VOC) | Levenson's Castilian models (8406222) |
| L6 | Mannheim german_handwriting, kurrent_v3, McCATMuS, dh-unibe TrOCR Kurrent | dh-unibe `qwen3.5-4b-german-xix-v2` and `qwen3vl-german-xix-v2` (Qwen 4B line models, no licence stated), CHURRO-3B | – |
| L7 | CATMuS Medieval 1.5, TRIDIS (v2 lists Königsfelden: labelled) | CHURRO-3B (contaminated) | dh-unibe trocr-medieval-escriptmask, qwen3vl-medieval-german-v3 (both Königsfelden) |
| N1 | – (no clean kraken model for manuscripts; OpenITI's is for print) | Qari-OCR 0.4.0 (`NAMAA-Space/Qari-OCR-0.4.0-VL-4B-Instruct`, Apache-2.0, page level), Fanar-2-Oryx-IVU 7B, CHURRO-3B | Muharaf kraken models (14295489), Phoenix |
| N3 | BBAW greek_minuscule_s9-12 (9th-12th c. hands; EPARCHOS is 16th c.) | CHURRO-3B | PP-OCRv6, Party |
| N4 | BiblIA_01, as a labelled upper bound only | CHURRO-3B | Sofer Mahir models (include BiblIA) |
| L8 | – (already 88-91) | – | – |

**Hosted** (listed only; W43.sweep prices them, `execution-plans/paid-runs-deferred.md`): Transkribus public
models, Text Titan II for L5 and L7 and The German Giant I (CER 8.3% on its own test) for L6, at 1 credit a
handwritten page in the app and half that through the API (250 credits €59.50; Scholar plan €99 a year with 900
credits). No hosted specialist was found for Arabic, Greek or Hebrew manuscripts. eScriptorium has no paid service.

**Coordination with W43.sweep and W43.sweep-farmshare:** those run general models. The models here are the
script-specific ones, so none is in both. CHURRO-3B is a general historical model and belongs to whichever runs
first on FarmShare, with the contamination labels above.
