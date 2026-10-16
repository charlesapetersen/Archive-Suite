# Page-kind classifier (W41.bench-kind-classifier)

Measured 2026-10-16 on 184 labelled page images: the OCR truth set's 99, the resolution ladder's half and quarter copies of 20 of them, 27 Statistics-tagged corpus photos and 3 small corpus PDFs drawn at random and labelled by looking, and Vision OCR's 15 held-out handwriting photos. Every method runs on the Mac with no paid call: Apple Vision, and open weights already in the Vision OCR lab's cache. Reproduce: `kind_classifier.py draw`, `labels`, `signals`, `vlm --model KEY` under run-guarded.sh, then `report` (header of `scripts/segbench/kind_classifier.py`). Page images and labels stay in the private cache.

## 1. The hand: handwritten, typewritten, printed

144 pages at their own resolution: handwritten 34, typewritten 72, printed 35, mixed 3. Right = the hand the label gives; for the learned rows each page is scored by a model fitted without any page from its folder. Mixed pages count as handwriting for the learned rows, which have no mixed class (the guide has no mixed kind either).

| method | right | handwritten found | typewritten | printed | handwriting called on a typed or printed page |
|---|---:|---:|---:|---:|---:|
| Vision OCR sorter (handwriting, else typewritten) | 102/144 | 31/34 | 70/72 | 0/35 | 2 |
| Vision sorter + ink periodicity (cut chosen leave-one-out) | 117/144 | 31/34 | 64/72 | 21/35 | 2 |
| Vision signals, logistic regression (leave-one-folder-out) | 116/144 | 32/34 | 64/72 | 19/35 | 3 |
| Vision signals + feature print, logistic regression (leave-one-folder-out) | 139/144 | 33/34 | 70/72 | 34/35 | 1 |
| The same without Vision OCR's sorter as an input (leave-one-folder-out) | 139/144 | 33/34 | 70/72 | 34/35 | 1 |
| qwen3.5-2b-mlx4 (mlx-vlm, 1024 px, two-word answer) | 104/144 | 34/34 | 60/72 | 7/35 | 3 |
| qwen3.5-4b-mlx4 (mlx-vlm, 1024 px, two-word answer) | 127/144 | 30/34 | 65/72 | 29/35 | 0 |

The periodicity cut on all the pages is harmonic ≥ 0.097.

Confusions of the best row (Vision signals + feature print, logistic regression (leave-one-folder-out)):

| truth \ said | typewritten | printed | handwritten | mixed | right |
|---|---:|---:|---:|---:|---:|
| typewritten | 70 | 1 | 1 | 0 | 70/72 |
| printed | 1 | 34 | 0 | 0 | 34/35 |
| handwritten | 1 | 0 | 33 | 0 | 33/34 |
| mixed | 0 | 1 | 2 | 0 | 0/3 |

## 2. Forms and tables

The same 144 pages: 14 are mainly a table or a form (4 in the truth set, 10 found among the drawn pages by looking).

| method | right | forms found | false calls |
|---|---:|---:|---:|
| Vision document request finds any table | 134/144 | 7/14 | 3 |
| Vision table share of the page (cut chosen leave-one-out) | 132/144 | 5/14 | 3 |
| Vision signals + feature print, logistic regression (leave-one-folder-out) | 141/144 | 13/14 | 2 |
| qwen3.5-2b-mlx4 | 132/144 | 8/14 | 6 |
| qwen3.5-4b-mlx4 | 138/144 | 11/14 | 3 |

The share cut on all the pages is ≥ 0.145 of the page.

## 3. Low resolution

The ladder's 20 pages at three sizes (60 images) and the 3 small pages drawn from the corpus; low resolution is the quarter rung, where the readers fall (Qwen3.6 27B 96.1 → 95.3 → 71.7 by rung), and the one drawn page judged blurred by looking. The cut is chosen leaving out every size of the page being judged.

| method | right | low found | false calls | cut on all |
|---|---:|---:|---:|---:|
| median text line height in pixels | 46/63 | 10/21 | 6 | ≤ 13.2 px |
| long side of the image in pixels | 56/63 | 21/21 | 7 | ≤ 1024 px |

Measured instead: an image that Qwen3.6 27B reads at least 10 points worse than the same page's original. 8 of the 60 ladder images are (7 of the 20 quarter, 1 half): the fall is page by page, and pages with 6 px lines can read as well as their originals.

| method | right | dropped found | false calls | cut on all |
|---|---:|---:|---:|---:|
| median text line height in pixels | 53/60 | 2/8 | 1 | ≤ 7.0 px |
| long side of the image in pixels | 56/60 | 5/8 | 1 | ≤ 585 px |

On the 144 pages at their own size, 1 have a median line under the cut: r03.

## 4. What a wrong kind costs in reading accuracy

The guide's first pick for each kind (handwritten → gemini3.8-flash, printed → claude-sonnet5.5, forms → qwen3.6-27b, typewritten → gemini3.8-flash, low-resolution → gemini3.1-flash-lite), on the 96 truth pages that have NES for every pick. A page goes to its flag's pick when it has one (low resolution first), else to its hand's. "Lost" is the mean NES, in points, of the routed reading below the reading the labelled kind would have chosen; a misroute can also gain.

Routed by the labels: 97.26. Every page to one reader: claude-sonnet5.5 96.47, gemini3.1-flash-lite 91.61, gemini3.8-flash 94.47, qwen3.6-27b 94.28.

| classifier | pages routed as labelled | mean NES | lost | worst page |
|---|---:|---:|---:|---:|
| Labels for hand and form, image size for low resolution | 95/96 | 96.50 | +0.76 | 73.4 |
| Vision sorter + periodicity + table share + image size | 79/96 | 92.74 | +4.52 | 100.0 |
| Vision sorter + periodicity + table share, no low-resolution flag | 80/96 | 93.51 | +3.76 | 100.0 |
| Feature-print LR for hand and form + image size | 91/96 | 95.49 | +1.77 | 97.2 |
| Feature-print LR for hand and form, no low-resolution flag | 92/96 | 96.26 | +1.00 | 97.2 |
| qwen3.5-2b-mlx4 hand and form, no low-resolution flag | 72/96 | 94.24 | +3.03 | 100.0 |
| qwen3.5-4b-mlx4 hand and form, no low-resolution flag | 90/96 | 95.21 | +2.05 | 100.0 |

On the 20 quarter-rung pages, the guide's low-resolution pick reads 89.7; a missed flag sends the page to its hand's pick, which was not run at that size except qwen3.6-27b (71.7). So a missed low-resolution page costs about 18 points when it lands on qwen3.6-27b, and is unmeasured for the others.

## 5. Speed and memory on the M3 Pro (18 GB)

| step | s a page (median) | peak memory |
|---|---:|---:|
| Vision text lines (accurate) + ink periodicity | 0.21 | OS models, not measured apart |
| Vision document request (tables) | 0.38 | OS models, not measured apart |
| Vision feature print | 0.01 | OS models, not measured apart |
| Vision OCR's sorter (W41.bench-vision-kind) | about 4.3 | – |
| qwen3.5-2b-mlx4 | 1.31 (load 1.0 s) | MLX 2.78 GB, footprint 3.6 GB (run-guarded) |
| qwen3.5-4b-mlx4 | 2.23 (load 1.7 s) | MLX 4.08 GB, footprint 4.9 GB (run-guarded) |
## 6. Recommended for W41.app-page-kind

**Apple Vision's signals and its image feature print, with a logistic regression for the hand and one for forms** (`kind-classifier-model.json`, fitted on all 144 pages; `kind-signals.swift` measures its inputs), and **no low-resolution flag yet**. It needs no model download and runs in about 0.6 s a page on the M3 Pro with the OS's own models; Vision OCR's sorter adds nothing to it as an input (the same 139 of 144 either way) and costs about 4 s a page, so it is left out. Scored with each folder left out of the fitting, it gets the hand right on 139 of 144 pages and finds 13 of 14 forms with 2 false calls; routed by the guide it reads 96.26 NES on the 96 accuracy pages, 1.00 points below routing by the true kinds (97.26) and above the best single reader. Its weights come from these pages and folders, so the app should keep the user's default when its top probability is low, and refit as labelled pages grow.

The small vision-language models are slower and worse at the distinction that matters most for the guide, typewritten against printed (the printed pick is a different reader), though they find handwriting. Low resolution is left out because neither definition is caught well: image size finds the quarter rung but also flags small originals the readers read well, which cost NES when routed to the low-resolution pick, and text height does not predict which pages actually fall. Every corpus photo is 2,592 px or more, and 12 of 1,500 sampled PDFs with no JPEG have a page image under 1,100 px (3 of them born-digital), so the case is rare.

## Limits

144 pages from one corpus, with few forms (14) and few mixed pages (3). The drawn pages were labelled by one reader looking at contact sheets, not blind; the truth set's kinds are its own. The 15 held-out handwriting photos come from one collection, and the drawn forms from nine folders, most of them one university's admissions records, so leaving a folder out may still flatter the learned rows. The learned rows owe nearly everything to the feature print: on Vision's scalar signals alone the hand is right on 116 of 144. The Vision OCR sorter judged the panel originals at vision-ocr f8f97d2 (W41.bench-vision-kind) and the other pages at ff798aa. NES lost is measured only on the 96 truth pages; a missed low-resolution page is unmeasured for most readers. Seconds a page are medians from one run.

