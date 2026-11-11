# W46.ocr-input-colour-dropout — a stamp in a second ink, dropped from the OCR input only

Owner, 2026-11-10 (point 6): "UIUC 156" tests how well the readers resolve a red stamp. The OCR input here is one colour channel of the raw image, the one in which the mark is lightest (`colour_dropout.py`), the same size as raw, so it is an R02.2 OCR input; the reading copy is untouched. `ocr_colour_dropout.py` made everything below; the truth of the 60 selected pages is **draft**.

## Verdict

- **Apple Vision (accurate, macOS 27.2): dropout does not help.** All 40 stamp-class pages 71.07 → 71.76 NES (+0.69 [-1.34, +3.06]); the 16 with a drafted coloured mark +3.38 [-0.14, +8.38]; controls -4.22 [-8.92, +0.06]; the 96 with the gate -0.0 [-0.0, +0.0]. Words of the text under the marks missed: 7.74% raw, 6.65% dropout.
- **Gemini 3.7 Flash (gateway): dropout does not help.** All 40 stamp-class pages 90.8 → 83.6 NES (-7.2 [-12.58, -2.69]); the 16 with a drafted coloured mark -0.33 [-0.91, +0.22]; controls -0.71 [-1.99, +0.01]; the 96 with the gate +0.0 [+0.0, +0.0]. Words of the text under the marks missed: 1.05% raw, 1.78% dropout.

UIUC 00156 itself: Vision 93.2 → 95.5 NES, its lines under the mark 14 → 6 holding 43 → 46 words, body words missed 16 → 4 of 195; Gemini 99.9 → 99.3. One page is the case that raised the question, not evidence for a rule.

No R02 change is proposed: R02.1 (nothing applied before OCR) stands, and W46.settings gains no switch.

**Reading it.** Where a real coloured mark lies over the text, dropout probably helps Vision: +3.38 [-0.14, +8.38] on the 16, with fewer words of the text under the mark missed (8.94% → 6.18%), short of the paired interval. But the cue cannot tell a stamp from coloured print, and on the coloured-print pages it fires on Vision ties (-1.11) while Gemini loses -11.78 (coloured printed words go faint in the channel and Gemini leaves them out). Gemini already reads through the stamps: 1.05% of the text under the marks missed on raw. The gate fires on no control (they are their own class); dropout applied to them anyway costs Vision -4.22 and Gemini -0.71, so dropout without a gate is harmful, and this gate fires on 1 of the 96, which no reader reads differently. A route worth having would need a cue that separates stamps from coloured print, and an owner-checked truth for the borderline Vision gain; both are filed behind W46.nice-to-have.

## Every set, per reader

NES ×100 against the truth, paired Δ dropout − raw with its 95% bootstrap interval (ocr_panel_score.paired), pages moved more than 2 points either way, and the words of the truth's text (the marks' own words taken out) that the reading misses. "route Δ" is dropout followed by the mark layer's reading as page text, against raw: reported to show that it is not how the mark should be kept (below).

| reader | set | n | raw | dropout | Δ [95%] | helped / harmed | text missed raw → dropout | route Δ |
|---|---|---|---|---|---|---|---|---|
| Apple Vision (accurate, macOS 27.2) | stamp class, all 40 | 40 | 71.07 | 71.76 | +0.69 [-1.34, +3.06] | 10 / 6 | 7.74% → 6.65% | -2.77 |
| Apple Vision (accurate, macOS 27.2) | stamp class, a coloured mark in the draft | 16 | 80.13 | 83.51 | +3.38 [-0.14, +8.38] | 5 / 1 | 8.94% → 6.18% | -0.25 |
| Apple Vision (accurate, macOS 27.2) | stamp class, no coloured mark in the draft | 24 | 65.03 | 63.93 | -1.11 [-3.15, +0.7] | 5 / 5 | 6.32% → 7.2% | -4.45 |
| Apple Vision (accurate, macOS 27.2) | controls, 20 | 20 | 89.44 | 85.22 | -4.22 [-8.92, +0.06] | 3 / 6 | 9.62% → 15.36% | -32.18 |
| Apple Vision (accurate, macOS 27.2) | the owner's 96, dropout wherever a mark exists (ungated) | 96 | 83.01 | 82.6 | -0.4 [-1.22, +0.34] | 8 / 10 | 9.88% → 10.1% | -0.91 |
| Apple Vision (accurate, macOS 27.2) | the owner's 96, the gate | 96 | 83.01 | 83.0 | -0.0 [-0.0, +0.0] | 0 / 0 | 9.88% → 9.87% | -0.51 |
| Apple Vision (accurate, macOS 27.2) | the 96, the pages the gate fires on | 1 | 97.18 | 97.02 | -0.15 [-0.15, -0.15] | 0 / 0 | 7.53% → 6.75% | -48.69 |
| Gemini 3.7 Flash (gateway) | stamp class, all 40 | 40 | 90.8 | 83.6 | -7.2 [-12.58, -2.69] | 1 / 10 | 1.05% → 1.78% | -20.81 |
| Gemini 3.7 Flash (gateway) | stamp class, a coloured mark in the draft | 16 | 92.32 | 91.99 | -0.33 [-0.91, +0.22] | 0 / 2 | 1.54% → 1.88% | -19.79 |
| Gemini 3.7 Flash (gateway) | stamp class, no coloured mark in the draft | 24 | 89.78 | 78.0 | -11.78 [-19.96, -4.56] | 1 / 8 | 0.47% → 1.65% | -21.49 |
| Gemini 3.7 Flash (gateway) | controls, 20 | 20 | 93.72 | 93.01 | -0.71 [-1.99, +0.01] | 0 / 1 | 6.12% → 6.14% | -38.32 |
| Gemini 3.7 Flash (gateway) | the owner's 96, dropout wherever a mark exists (ungated) | 96 | 96.73 | 96.73 | +0.0 [+0.0, +0.0] | 0 / 0 | 0.57% → 0.57% | -0.52 |
| Gemini 3.7 Flash (gateway) | the owner's 96, the gate | 96 | 96.73 | 96.73 | +0.0 [+0.0, +0.0] | 0 / 0 | 0.57% → 0.57% | -0.52 |
| Gemini 3.7 Flash (gateway) | the 96, the pages the gate fires on | 1 | 99.54 | 99.54 | +0.0 [+0.0, +0.0] | 0 / 0 | 0.0% → 0.0% | -49.49 |

## Vision's lines under the mark (40 stamp-class pages)

Lines whose box the mark layer covers by at least 2%: raw 262 lines holding 1298 words (5.0 a line), dropout 285 lines holding 2244 words (7.9 a line). More words on longer lines are what the stamp had broken or hidden; the lines are also the placement stage's geometry (05-placement.md), so dropout for Vision's lines alone is one of the filed follow-ups.

## The mark kept as a mark

The mark layer (`colour_dropout.mark_layer`: the mark's colour excess, dark on white) read with the panel prompt. Of the drafted marks' words on the 40 stamp-class pages, those found in the layer's reading, and the words read there that are no mark word (the layer also holds coloured print, letterheads and rules):

- Apple Vision (accurate, macOS 27.2): 10 of 73 mark words, 876 other words.
- Gemini 3.7 Flash (gateway): 54 of 73 mark words, 2459 other words.

## Selection

By colour only, never by a reader: `colour_dropout.cue` on 3772 originals (the 5,000-file Reader sample's JPEG originals, its UIUC pages from their HEIC originals, and UIUC 00156). Stamp class: a mark of one hue (peak share ≥ CONC) over dark text (share of the mark on ink ≥ STAMP_OVER), the dark text most of the ink; 103 pages, the 40 with the most text under the most mark drawn, at most 5 per collection, 00156 forced in. Control class: the coloured ink is the text; 170 pages, 20 drawn. The draft lists a coloured mark on 16 of the 40 stamp-class pages; the rest are coloured print (letterheads, coloured type, rules), which the cue cannot tell from a stamp, so the gate as an app would apply it is all 40. Of the 96, the gate fires on 1 (p041) and 59 have a coloured mark at all (the ungated arm). Thresholds: `{"SURVEY": 800, "SAT": 0.3, "INK_CHROMA": 0.16, "INK_LUM": 0.5, "NEAR": 3, "BLOB": 0.25, "MIN_MARK": 0.0015, "MAX_MARK": 0.15, "CONC": 0.6, "STAMP_OVER": 0.15, "STAMP_SHARE": 0.45, "STAMP_INK": 0.008, "CONTROL_SHARE": 0.65, "CONTROL_PIECES": 40}`.

## Measurement card

- **Truth.** The 96: the owner's truth. The 60: Gemini 3.7 Flash's draft through the gateway (medium reasoning, the raw and the dropout image both, the panel prompt with each coloured mark listed apart), the same family as one scored reader, so Gemini's figures lean its way on both arms; the owner has not checked it. `colour_dropout_sheet.py` builds the boxed sheet for the disputed places under the mark (blind), filed as its own item. The draft saw the dropout image, which could favour a dropout reading where the two disagree.
- **Selection.** By the colour cue alone (above); no reader chose a page. The marked/unmarked split uses the draft's marks list, so it is the drafter's, and is said where it is used.
- **Comparison.** Same images, sizes and settings per reader: Vision accurate with language correction, en-US; Gemini through the gateway at temperature 0, low reasoning, the panel prompt. Raw on the 96 for Gemini is W46.fix-ocr-scorers-paid's reading of the same frozen image. The dropout input is the plain channel, as the owner's note measured it.
- **Noise.** Paired bootstrap intervals over pages; Vision is deterministic (no rerun floor); Gemini's rerun floor on the 96 is 0.49 points (ocr-rerun-noise.md), applied as a tie bound. n is 40, 16, 24, 20 and 96.
- **Scope.** One dropout method (a single plain channel, chosen by the mark's hue), one cue, two readers. It does not settle a masked dropout (whitening only the mark's pixels), dropout for placement only (Vision's lines from dropout, the reader's text from raw), or pages outside the Reader sample's collections.

## Cost and tools

Gateway: 242 calls of gemini-3.7-flash, $1.22 estimated (the gateway's own figure $1.2233 on 242 of 242 calls, 1.00 times the estimate on them), against this item's $2.00 cap and the $7 rule. Vision and the cue: $0, on this Mac under the heavy lock.

The cached `segbench-dewarp` binary (built 2026-10-31) read less text on macOS 27.2 than the bench's segbench-ocr on the same frozen images: on 53 of the 96 its NES was more than 5 points off, and its mean on the 96 was 60.0 against the bench's 83.1. Built again from the same `dewarp.swift`, it gives the bench's text character for character (checked on p001, p004, p005 and p006), and every Vision figure here is from the rebuild; the cached binary was replaced with it (the old one kept beside it).
