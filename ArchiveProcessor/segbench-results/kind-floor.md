# The kind classifier's 0.8 floor, measured, with the document prior — W47.wh-kinds-floor

Made by `scripts/segbench/kind_floor.py` (method in its docstring). The app sends a page whose top class is at least 0.8 to the model guide's pick for its kind and keeps the run's model for the rest (`PageKindRouting.choose`). Asked by the owner on 2026-11-19 (call 15): measure the floor before routing under it is released or kept withheld.

## What it shows

- **The floor separates right calls from wrong ones.** At or over 0.8 the top class is right on 125 of 127 labelled pages (98%); under it on 12 of 17 (71%).
- **Routing the unsure pages by their top class anyway (cut 0) against the 0.8 floor**, on the 96: apple-vision +1.31 [-0.03, +3.44]; gemini3.1-flash-lite +1.05 [+0.00, +3.05]; qwen3.6-27b +0.05 [-0.07, +0.19]; gemini3.8-flash +1.67 [-0.00, +4.23]; claude-sonnet5.5 +0.01 [-0.08, +0.10]. Every interval reaches zero: a tie for each run model, leaning to routing where the run model is weak. No run model's mean falls by it.
- **The folder prior adds nothing measurable.** On the labelled pages under 0.8 that have a sure neighbour it is right on 5 of 8, the top class on 6; in reading, the prior at 0.8 against the floor alone: apple-vision +0.13 [-0.01, +0.38]; gemini3.1-flash-lite +0.03 [+0.00, +0.08]; qwen3.6-27b +0.02 [-0.06, +0.12]; gemini3.8-flash +0.00 [+0.00, +0.00]; claude-sonnet5.5 -0.00 [-0.04, +0.02].
- **A higher cut's apparent gain is one page.** p024, typewritten but called forms at 0.859, goes to qwen3.6-27b, whose stored reading is a transport failure scored 0; a cut of 0.9 sends it to the run model instead, which is nearly all of the 0.9 rows' gain over 0.8 for the three run models that read it well.
- **On the owner's boxes a document prior would change 20 of the 79 pages under 0.8** (typewritten → printed 11, printed → typewritten 7, forms → typewritten 1, handwritten → typewritten 1); 36 keep their top class, 21 are single-page documents with no prior and 2 have no sure page beside them. Whether those changes are right is not measured: the boxes have no kind truth.

## 1. Is the top class right above and below the cut

The 144 labelled owner pages, each scored by a classifier of the shipped form fitted without its folder: the kind (form, else hand) is right on 137 of 144.

| cut | pages at or over | right | pages under | right |
|---:|---:|---:|---:|---:|
| 0.5 | 141 | 134 (95%) | 3 | 3 (100%) |
| 0.6 | 136 | 130 (96%) | 8 | 7 (88%) |
| 0.7 | 131 | 128 (98%) | 13 | 9 (69%) |
| 0.8 | 127 | 125 (98%) | 17 | 12 (71%) |
| 0.9 | 112 | 111 (99%) | 32 | 26 (81%) |
| 0.95 | 105 | 105 (100%) | 39 | 32 (82%) |

A folder prior on the same pages (the majority kind of the sure calls on the other labelled pages of the folder; most folders give one to three pages, so most unsure pages have no neighbour):

| cut | pages under | with a neighbour | prior right | top class right on those |
|---:|---:|---:|---:|---:|
| 0.5 | 3 | 2 | 0 | 2 |
| 0.6 | 8 | 3 | 1 | 3 |
| 0.7 | 13 | 4 | 2 | 3 |
| 0.8 | 17 | 8 | 5 | 6 |
| 0.9 | 32 | 19 | 11 | 17 |
| 0.95 | 39 | 21 | 13 | 19 |

## 2. What the cut is worth in reading accuracy

The 96 OCR truth pages with NES for every route used. A sure page goes to the guide's first pick (handwritten and typewritten gemini3.8-flash, printed claude-sonnet5.5, forms qwen3.6-27b), an unsure page to the run's model. Cut 0 routes every page by its top class; "keep" reads every page with the run's model. Mean NES in points; differences with paired bootstrap 95% intervals. 12 of the 96 are under 0.8 (9 of them with the right top class); 4 of those have a folder neighbour.

**Run model apple-vision**: keep 83.07; routed by the true kinds 97.23.

| cut | prior | pages routed | mean NES | against keep | against the 0.8 floor |
|---:|:---:|---:|---:|---:|---:|
| 0.0 | — | 96 | 96.23 | +13.15 [+8.83, +17.81] | +1.31 [-0.03, +3.44] |
| 0.5 | — | 93 | 95.42 | +12.35 [+8.10, +16.71] | +0.51 [-0.16, +1.52] |
| 0.5 | folder | 95 | 95.44 | +12.37 [+8.20, +16.84] | +0.53 [-0.16, +1.61] |
| 0.6 | — | 90 | 94.93 | +11.85 [+7.57, +16.20] | +0.01 [-0.33, +0.35] |
| 0.6 | folder | 92 | 94.95 | +11.87 [+7.69, +16.21] | +0.03 [-0.29, +0.36] |
| 0.7 | — | 86 | 95.02 | +11.95 [+7.69, +16.42] | +0.11 [-0.03, +0.35] |
| 0.7 | folder | 88 | 95.04 | +11.97 [+7.73, +16.26] | +0.13 [-0.01, +0.39] |
| 0.8 | — | 84 | 94.91 | +11.84 [+7.80, +16.23] | +0.00 [+0.00, +0.00] |
| 0.8 | folder | 88 | 95.04 | +11.97 [+7.78, +16.29] | +0.13 [-0.01, +0.38] |
| 0.9 | — | 74 | 94.39 | +11.31 [+7.57, +15.46] | -0.53 [-2.50, +1.19] |
| 0.9 | folder | 84 | 94.78 | +11.71 [+7.96, +15.66] | -0.13 [-2.08, +1.54] |
| 0.95 | — | 70 | 94.30 | +11.23 [+7.43, +15.21] | -0.61 [-2.57, +1.05] |
| 0.95 | folder | 79 | 94.57 | +11.50 [+7.72, +15.55] | -0.34 [-2.29, +1.31] |

**Run model gemini3.1-flash-lite**: keep 91.59; routed by the true kinds 97.23.

| cut | prior | pages routed | mean NES | against keep | against the 0.8 floor |
|---:|:---:|---:|---:|---:|---:|
| 0.0 | — | 96 | 96.23 | +4.64 [+0.39, +9.06] | +1.05 [+0.00, +3.05] |
| 0.5 | — | 93 | 96.25 | +4.66 [+0.63, +9.17] | +1.06 [+0.02, +2.95] |
| 0.5 | folder | 95 | 96.25 | +4.66 [+0.59, +9.03] | +1.06 [+0.02, +2.98] |
| 0.6 | — | 90 | 95.30 | +3.71 [-0.26, +7.78] | +0.12 [-0.00, +0.34] |
| 0.6 | folder | 92 | 95.30 | +3.71 [-0.24, +7.86] | +0.12 [-0.00, +0.36] |
| 0.7 | — | 86 | 95.21 | +3.62 [-0.19, +7.63] | +0.03 [+0.00, +0.08] |
| 0.7 | folder | 88 | 95.21 | +3.62 [+0.02, +7.81] | +0.03 [+0.00, +0.08] |
| 0.8 | — | 84 | 95.18 | +3.59 [-0.11, +7.67] | +0.00 [+0.00, +0.00] |
| 0.8 | folder | 88 | 95.21 | +3.62 [-0.17, +7.55] | +0.03 [+0.00, +0.08] |
| 0.9 | — | 74 | 96.09 | +4.50 [+1.66, +8.24] | +0.91 [-0.22, +3.01] |
| 0.9 | folder | 84 | 96.13 | +4.54 [+1.73, +8.23] | +0.95 [-0.18, +3.04] |
| 0.95 | — | 70 | 96.06 | +4.47 [+1.61, +8.29] | +0.88 [-0.26, +2.99] |
| 0.95 | folder | 79 | 96.11 | +4.52 [+1.66, +8.07] | +0.93 [-0.21, +3.03] |

**Run model qwen3.6-27b**: keep 94.35; routed by the true kinds 97.23.

| cut | prior | pages routed | mean NES | against keep | against the 0.8 floor |
|---:|:---:|---:|---:|---:|---:|
| 0.0 | — | 96 | 96.23 | +1.88 [+0.83, +3.31] | +0.05 [-0.07, +0.19] |
| 0.5 | — | 93 | 96.25 | +1.90 [+0.87, +3.34] | +0.08 [-0.03, +0.20] |
| 0.5 | folder | 95 | 96.25 | +1.90 [+0.85, +3.32] | +0.08 [-0.03, +0.21] |
| 0.6 | — | 90 | 96.20 | +1.85 [+0.83, +3.19] | +0.03 [-0.05, +0.13] |
| 0.6 | folder | 92 | 96.20 | +1.85 [+0.83, +3.28] | +0.03 [-0.05, +0.13] |
| 0.7 | — | 86 | 96.19 | +1.84 [+0.78, +3.33] | +0.02 [-0.06, +0.12] |
| 0.7 | folder | 88 | 96.19 | +1.84 [+0.82, +3.28] | +0.02 [-0.06, +0.12] |
| 0.8 | — | 84 | 96.17 | +1.82 [+0.78, +3.25] | +0.00 [+0.00, +0.00] |
| 0.8 | folder | 88 | 96.19 | +1.84 [+0.81, +3.29] | +0.02 [-0.06, +0.12] |
| 0.9 | — | 74 | 95.87 | +1.52 [+0.58, +2.96] | -0.30 [-0.83, -0.01] |
| 0.9 | folder | 84 | 96.11 | +1.76 [+0.73, +3.16] | -0.06 [-0.23, +0.08] |
| 0.95 | — | 70 | 95.86 | +1.51 [+0.56, +2.88] | -0.31 [-0.81, -0.02] |
| 0.95 | folder | 79 | 96.10 | +1.75 [+0.70, +3.18] | -0.08 [-0.24, +0.07] |

**Run model gemini3.8-flash**: keep 94.43; routed by the true kinds 97.23.

| cut | prior | pages routed | mean NES | against keep | against the 0.8 floor |
|---:|:---:|---:|---:|---:|---:|
| 0.0 | — | 96 | 96.23 | +1.79 [-1.94, +5.55] | +1.67 [-0.00, +4.23] |
| 0.5 | — | 93 | 95.45 | +1.02 [-2.04, +4.33] | +0.90 [-0.00, +2.68] |
| 0.5 | folder | 95 | 95.45 | +1.02 [-2.05, +4.72] | +0.90 [-0.00, +2.68] |
| 0.6 | — | 90 | 94.56 | +0.13 [-2.91, +3.18] | +0.01 [-0.00, +0.02] |
| 0.6 | folder | 92 | 94.56 | +0.13 [-2.96, +3.22] | +0.01 [-0.00, +0.02] |
| 0.7 | — | 86 | 94.55 | +0.12 [-2.93, +3.20] | +0.00 [+0.00, +0.00] |
| 0.7 | folder | 88 | 94.55 | +0.12 [-2.96, +3.21] | +0.00 [+0.00, +0.00] |
| 0.8 | — | 84 | 94.55 | +0.12 [-2.92, +3.18] | +0.00 [+0.00, +0.00] |
| 0.8 | folder | 88 | 94.55 | +0.12 [-2.95, +3.21] | +0.00 [+0.00, +0.00] |
| 0.9 | — | 74 | 95.57 | +1.13 [-0.02, +3.31] | +1.01 [-0.01, +3.05] |
| 0.9 | folder | 84 | 95.57 | +1.14 [-0.01, +3.34] | +1.01 [-0.01, +3.05] |
| 0.95 | — | 70 | 95.57 | +1.13 [-0.02, +3.32] | +1.01 [-0.01, +3.05] |
| 0.95 | folder | 79 | 95.57 | +1.14 [-0.02, +3.33] | +1.01 [-0.01, +3.05] |

**Run model claude-sonnet5.5**: keep 96.47; routed by the true kinds 97.23.

| cut | prior | pages routed | mean NES | against keep | against the 0.8 floor |
|---:|:---:|---:|---:|---:|---:|
| 0.0 | — | 96 | 96.23 | -0.25 [-2.69, +1.37] | +0.01 [-0.08, +0.10] |
| 0.5 | — | 93 | 96.22 | -0.25 [-2.63, +1.31] | -0.00 [-0.08, +0.09] |
| 0.5 | folder | 95 | 96.23 | -0.25 [-2.72, +1.31] | +0.01 [-0.07, +0.10] |
| 0.6 | — | 90 | 96.21 | -0.26 [-2.81, +1.30] | -0.01 [-0.04, +0.02] |
| 0.6 | folder | 92 | 96.22 | -0.25 [-2.80, +1.33] | +0.00 [-0.03, +0.03] |
| 0.7 | — | 86 | 96.21 | -0.26 [-2.73, +1.30] | -0.01 [-0.04, +0.00] |
| 0.7 | folder | 88 | 96.22 | -0.26 [-2.69, +1.31] | -0.00 [-0.04, +0.02] |
| 0.8 | — | 84 | 96.22 | -0.25 [-2.61, +1.35] | +0.00 [+0.00, +0.00] |
| 0.8 | folder | 88 | 96.22 | -0.26 [-2.66, +1.29] | -0.00 [-0.04, +0.02] |
| 0.9 | — | 74 | 97.21 | +0.73 [+0.15, +1.51] | +0.99 [-0.08, +3.04] |
| 0.9 | folder | 84 | 97.20 | +0.72 [+0.11, +1.49] | +0.98 [-0.09, +3.05] |
| 0.95 | — | 70 | 97.20 | +0.73 [+0.14, +1.49] | +0.98 [-0.08, +3.04] |
| 0.95 | folder | 79 | 97.19 | +0.72 [+0.13, +1.48] | +0.97 [-0.09, +3.04] |

The truth pages under 0.9, by confidence: the guide's pick for the called kind and what it read, against each run model's reading (NES).

| page | called | truth | confidence | pick | pick NES | apple-vision | gemini3.1-flash-lite | qwen3.6-27b | gemini3.8-flash | claude-sonnet5.5 |
|---|---|---|---:|---|---:|---:|---:|---:|---:|---:|
| p034 | printed | printed | 0.433 | claude-sonnet5.5 | 96.5 | 21.4 | 98.3 | 98.8 | 22.0 | 96.5 |
| p071 | typewritten | typewritten | 0.492 | gemini3.8-flash | 100.0 | 98.6 | 100.0 | 100.0 | 100.0 | 100.0 |
| p070 | typewritten | typewritten | 0.497 | gemini3.8-flash | 99.4 | 98.7 | 99.4 | 99.4 | 99.4 | 98.7 |
| p029 | printed | printed | 0.502 | claude-sonnet5.5 | 99.8 | 99.8 | 99.8 | 99.0 | 99.8 | 99.8 |
| p018 | forms | forms | 0.548 | qwen3.6-27b | 85.5 | 45.1 | 0.0 | 85.5 | 0.0 | 82.5 |
| p015 | handwritten | handwritten | 0.565 | gemini3.8-flash | 94.4 | 87.0 | 89.3 | 90.5 | 94.4 | 96.8 |
| p011 | forms | printed | 0.642 | qwen3.6-27b | 79.0 | 90.0 | 69.8 | 79.0 | 78.5 | 78.5 |
| p021 | printed | printed | 0.643 | claude-sonnet5.5 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 |
| p023 | printed | typewritten | 0.660 | claude-sonnet5.5 | 99.9 | 98.6 | 100.0 | 100.0 | 99.9 | 99.9 |
| p084 | printed | printed | 0.676 | claude-sonnet5.5 | 99.9 | 99.2 | 100.0 | 98.9 | 99.9 | 99.9 |
| p013 | handwritten | typewritten | 0.775 | gemini3.8-flash | 76.7 | 77.5 | 74.2 | 78.6 | 76.7 | 78.0 |
| p008 | typewritten | typewritten | 0.800 | gemini3.8-flash | 99.9 | 88.8 | 99.9 | 96.1 | 99.9 | 99.8 |
| p058 | printed | printed | 0.812 | claude-sonnet5.5 | 100.0 | 87.5 | 98.9 | 99.8 | 100.0 | 100.0 |
| p019 | typewritten | typewritten | 0.858 | gemini3.8-flash | 99.2 | 96.6 | 97.5 | 97.5 | 99.2 | 99.2 |
| p024 | forms | typewritten | 0.859 | qwen3.6-27b | 0.0 (transport failure) | 50.2 | 97.0 | 0.0 | 97.2 | 97.5 |
| p078 | printed | printed | 0.873 | claude-sonnet5.5 | 100.0 | 98.8 | 99.3 | 79.6 | 99.5 | 100.0 |
| p091 | typewritten | typewritten | 0.875 | gemini3.8-flash | 100.0 | 92.9 | 100.0 | 99.9 | 100.0 | 100.0 |
| p097 | typewritten | typewritten | 0.875 | gemini3.8-flash | 100.0 | 98.5 | 100.0 | 99.4 | 100.0 | 100.0 |
| p027 | typewritten | typewritten | 0.881 | gemini3.8-flash | 100.0 | 96.9 | 93.4 | 94.1 | 100.0 | 99.9 |
| p063 | printed | printed | 0.883 | claude-sonnet5.5 | 100.0 | 99.8 | 100.0 | 100.0 | 100.0 | 100.0 |
| p075 | printed | printed | 0.894 | claude-sonnet5.5 | 99.8 | 96.0 | 99.9 | 99.9 | 99.8 | 99.8 |
| p065 | forms | forms | 0.898 | qwen3.6-27b | 99.4 | 30.5 | 99.4 | 99.4 | 100.0 | 96.8 |

## 3. The document prior on the five owner boxes

The 848 document pages in 463 documents (kind-churn.md), the shipped classifier as the app runs it. An unsure page takes the majority kind of the sure pages of its own document. No truth: this counts what the prior would change, not whether the change is right.

| cut | pages under | single-page document | no sure page beside it | prior agrees with the top class | prior differs | the changes |
|---:|---:|---:|---:|---:|---:|---|
| 0.5 | 3 | 0 | 0 | 2 | 1 | typewritten → printed 1 |
| 0.6 | 27 | 8 | 0 | 13 | 6 | typewritten → printed 3, printed → typewritten 2, handwritten → typewritten 1 |
| 0.7 | 45 | 11 | 0 | 22 | 12 | typewritten → printed 6, printed → typewritten 3, forms → typewritten 1, handwritten → printed 1, handwritten → typewritten 1 |
| 0.8 | 79 | 21 | 2 | 36 | 20 | typewritten → printed 11, printed → typewritten 7, forms → typewritten 1, handwritten → typewritten 1 |
| 0.9 | 143 | 40 | 8 | 69 | 26 | typewritten → printed 13, printed → typewritten 11, forms → typewritten 1, handwritten → typewritten 1 |
| 0.95 | 213 | 62 | 28 | 102 | 21 | typewritten → printed 12, printed → typewritten 6, forms → typewritten 2, handwritten → typewritten 1 |

## Measurement card

- **Truth.** Kind: the 144 labelled owner pages of `kind-classifier.md` (the truth set's kinds as the drafting models and the owner left them, the drawn pages labelled by a session looking; KND-1), mixed pages counted as handwriting as the app does. Reading: the 96 owner OCR truth pages' NES per route (`ocr-pages.csv`). The five boxes have no kind truth.
- **Selection.** Every labelled page and every truth page with all the routes; every document page of the five boxes. Nothing chosen by the classifier or a reader.
- **Comparison.** Every arm reads the same pages with the same stored readings; only the rule choosing the reader changes. The guide's picks were chosen on these 96 pages, which flatters routing against keeping one model.
- **Noise.** Paired bootstrap over the pages (4,000 resamples, seed 20261119); the readings are one run per route, so no rerun floor is applied here and a difference whose interval crosses zero is a tie. The folder prior has few pages with a neighbour, so its rows are small.
- **Scope.** Whether the 0.8 cut and a prior change the reading on single owner pages, and how many box pages a document prior would change. It does not measure the document prior's accuracy (no kind truth on the boxes), routing when a pick is not runnable, or the cost of the picks.
