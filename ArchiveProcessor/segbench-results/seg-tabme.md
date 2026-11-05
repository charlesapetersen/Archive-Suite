# W46.seg-tabme — the students and the teacher on TABME++

Is the 2B student's 79% on the owner's test boxes a limit of the material (photographs, handwriting, mixed boxes)
or of the model? This item runs the trained 2B and 4B students and the Qwen3.5 27B teacher, at the local route's
settings (K = 7 image-and-text windows), over TABME++'s test split, clean scans with commercial OCR, for which the
field has published figures (A04, A05; `execution-plans/processing-review/A-segmentation.md`). The teacher also
runs on the text alone, the configuration A04 used for its zero-shot windows.

Source: `seg-tabme.json` (written by `scripts/segbench/seg_tabme.py score`), the stream summary
`seg-tabme-stream.json`. One Sherlock batch, pack `seg-tabme-20261105`, 7 jobs, all COMPLETED.

## Results (6,237 pages, 2,238 documents, 6,236 decisions)

| Arm | Boundary F1 (95% interval) | Pages in exact document | Doc F1 | Precision | Recall | False splits | False merges |
|---|---|---|---|---|---|---|---|
| Trained 2B, images and text | 0.814 (0.795-0.834) | 57.5% | 0.664 | 0.689 | 0.996 | 1,007 | 10 |
| Trained 4B, images and text | 0.820 (0.799-0.840) | 61.6% | 0.684 | 0.697 | 0.994 | 965 | 14 |
| 27B teacher, images and text | 0.768 (0.745-0.791) | 54.9% | 0.615 | 0.624 | 0.997 | 1,341 | 7 |
| 27B teacher, text only | 0.809 (0.788-0.830) | 59.8% | 0.666 | 0.682 | 0.995 | 1,037 | 12 |
| Every page a new document | 0.528 | 19.5% | 0.287 | 0.359 | 1.000 | 3,999 | 0 |

Page F1 in A05's sense (page 1 counted) equals boundary F1 to the third decimal on every arm. Intervals are a
bootstrap over truth documents (2,000 draws). Paired, boundary F1 points: 4B less 2B -0.4 to +1.5 (a tie; pages
exact +2.1 to +6.4 for the 4B); teacher text-only less 2B -1.8 to +0.8 (a tie); teacher with images less 2B -5.8 to
-3.4; teacher text-only less teacher with images +3.0 to +5.2.

**Published references on the same split** (not the same protocol; Comparison below):

| Route | Boundary / page F1 | Source |
|---|---|---|
| Mistral-7B LoRA, fine-tuned on TABME++ | 0.987 (doc F1 0.967) | A05 Table 4 |
| Phi-3-mini LoRA, fine-tuned on TABME++ | 0.973 | A05 Table 4 |
| Encoders and XGBoost, trained on TABME++ | 0.777-0.831 (doc F1 0.56-0.64) | A05 Table 4 |
| Gemini 3.1 Flash-Lite, zero-shot text, K = 7 | 0.863 | A04 Table 4 |
| Claude Haiku 4.5, zero-shot text, K = 7 | 0.782 | A04 Table 4 |
| GPT-5.4-mini, zero-shot text, K = 7 | 0.739 | A04 Table 4 |
| doc-split-v1, zero-shot | 0.704 | A20 card |

For contrast, the same 2B at the same settings on the owner's test boxes (Stanton and RG 165, default run,
`seg-window-modality.json`): boundary F1 0.928, pages exact 82.7%; on Lincoln 0.765 and 37.2%.

## What it shows

How it is read (measure-review pass 9, P9-9): material against model comes from the student-to-teacher gap here
against the same gap on our boxes, since the teacher was never trained on either; the teacher's text-only arm
against A04's K = 7 text windows is the one like-for-like outside comparison; A05 (page F1 over 5,000 synthetic
folders) is context only.

1. **The students do not transfer as they stand.** The 2B falls from boundary F1 0.928 and 82.7% pages exact on
   the owner's test boxes to 0.814 and 57.5% here, on clean scans with good OCR. Lower, not higher: the owner's
   figures are not a floor that easier material would lift.
2. **The drop is not the students' alone; the teacher falls with them.** On the owner's test boxes the 2B leads the
   teacher by 2.0 points of boundary F1 (0.928 against 0.908, one run, inside the 1.4-3.2-point floor a box); here
   it leads the teacher reading the same images and text by 4.6 points (paired 3.4 to 5.8) and ties the teacher
   reading the text alone. The student's standing against an untrained 27B does not shrink away from home, so the
   fall is the material, or more exactly this collection's document rule, not a capacity the 2B lacks and the 27B
   has. The 4B ties the 2B on boundaries (pages exact +2.1 to +6.4 for the 4B), as on the owner's boxes.
3. **Against A04, the teacher reads TABME++ like the zero-shot cloud models.** Text only at K = 7 it scores 0.809:
   between Claude Haiku 4.5 (0.782) and Gemini 3.1 Flash-Lite (0.863), above GPT-5.4-mini (0.739). A04's page order
   and prompt are not ours, so this places it and does not rank it; W46.seg-tabme-paid runs Gemini on our pack.
   For context only, A05's decoders fine-tuned on TABME++'s training split reach page F1 0.987 under its own
   protocol, and its trained encoders 0.78-0.83.
4. **Nearly every error is a false split, and the models agree on them.** Recall is 99.4-99.7% in every arm;
   precision is 62-70%. Of the 2B's 1,007 false splits, 567 are inside documents of eight or more pages, and 649
   false splits are shared by all four arms. The likely reason (inferred, not audited page by page): a TABME++
   "document" is the Truth Tobacco Industry Documents' catalogue unit, which can hold several letters, forms or
   reports filed as one, and a reader that has not learnt that convention cuts at each item.
5. **For the kit (`W46.review-phase4`).** On another collection the students behave like a zero-shot reader of
   about the 27B teacher's quality, at a seventh to a tenth of its GPU time. They can be offered to other users'
   material as a zero-shot default with a card that says so, not with the owner's figures as the expected accuracy.
   Reaching in-collection figures needs the collection's own rule, which is `W46.seg-adapt-lora`'s question.
6. **Images hurt the teacher on this material.** With page images the teacher splits 304 more gaps than with the
   text alone (paired +3.0 to +5.2 points for text only). The students, trained on images, do not lose this way.
   On the owner's photographs, text only cost the 2B 5-20 points (`seg-window-modality.md`), so this is a property
   of clean, letter-like scans, not a reason to drop images from the local route.

## Speed on one L40S (concurrency 16, vLLM 0.31)

| Arm | Wall (hours) | Pages per GPU-hour |
|---|---|---|
| 2B, images and text | 0.29 | 21,870 |
| 4B, images and text | 0.57 | 11,031 |
| Teacher, images and text | 3.10 | 2,013 |
| Teacher, text only | 1.88 | 3,316 |

The batch used about 6.1 GPU-hours of the 8-hour ceiling (sacct, including start-up and pilots).

## Measurement card

- **Truth.** TABME++'s own document ids (`bevaya/TABMEpp` at revision 46747c21), from the Truth Tobacco Industry
  Documents' cataloguing; not audited by us and not checked by the owner. No drafter or relative of a scored route
  made it.
- **Selection.** The whole test split, every page; no model and no ABBYY text chose it. Each document's pages are
  ordered by `pg_id` and documents follow the shards' row order, giving A04's 6,236 decisions exactly.
- **Comparison.** Our four arms share one pack, one prompt, one serving setup and one K = 7 window plan (2,080
  windows each); the text arm is the teacher's only. 1-2 windows per arm stayed unparsed after the retry and vote
  0.5, as everywhere. A04 and A05 are references only: A05 scores 5,000 synthetic folders that reuse documents, and
  A04's page order and prompt are not ours. OCR is the dataset's Microsoft OCR, not Apple Vision; 24 pages (0.38%)
  have no text.
- **Noise.** One run per arm. The intervals above are document-bootstrap intervals and do not include rerun noise;
  the 1.6-point rerun floor measured on Lincoln makes the 4B-2B and teacher-text-2B differences ties, while the
  teacher's image loss (3.0-5.2 points) and the 2B's lead over the teacher with images (3.4-5.8) are not. The
  student-to-teacher gap on the owner's boxes (2.0 points) is one run per model and inside that box's floor.
- **Scope.** One genre of clean 20th-century business scans with one catalogue's document rule. It does not say how
  the students do on other users' photographed or handwritten boxes, nor what a per-collection adaptation buys
  (`W46.seg-adapt-lora`). The paid Gemini arm at A04's own settings is `W46.seg-tabme-paid`.
