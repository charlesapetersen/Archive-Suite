# What was left out on licence alone, screened (W46.licence-freed-sweep)

The owner's call of 17 Nov 2026 (`14-owner-calls.md` call 12) allows AGPL, GPL and non-commercial models as optional
downloads with their licence shown. This item screens what the review had excluded on licence alone and that no other
item covers (W46.dewarp-placement took DvD and DocTr++, W46.ocr-family-coverage Chandra-2 and CHURRO). Each candidate
went through a small pilot on inputs an earlier item already scored, with every incumbent rerun or read back beside it,
so only the new arm is new. A full run was made only where the pilot could change a pick.

Script: `scripts/segbench/licence_sweep.py` (subcommands `layoutreader`, `hunyuan-prep`, `readers`, `bln600`,
`signature`, `gutenocr-prep`, `gutenocr-lines`), with new arms in `ocr_mac_local.py` (HunyuanOCR-1.5, FastVLM),
`dewarp_extra_arms.py` and `dewarp_placement.py` (DocScanner, DocGeoNet) and `place_hands.py` (GutenOCR). Figures:
`licence-sweep-*.json` and `dewarp-placement.json`. All of it ran on this Mac. No API call was made and nothing was
spent.

## The verdicts

| Candidate | Stage | Licence | Pilot | Verdict |
|---|---|---|---|---|
| LayoutReader | reading order | CC BY-NC-SA 4.0 | the three layout-order panels in full | ties the free rows-first XY-cut on lines, loses on regions: no pick changes |
| HunyuanOCR-1.5 | Mac reader | Tencent Hunyuan community licence, not for users in the EU, UK or South Korea | 25 of the 96, then the 96 in full | ties Apple Vision, behind LightOnOCR-3 4B 8-bit and Xiaomi-OCR-0: no pick changes |
| FastVLM 0.5B | Mac reader | Apple AMLR (research only) | the 96 | 45 of 96 run to the token cap; strict NES 0.281: no |
| GutenOCR-3B | placement lines | CC BY-NC 4.0 | the 41 place-hands pages | inconclusive: its boxes come back squeezed in height on this runtime; a rerun on its reference runtime is filed (W46.gutenocr-lines-ref) |
| Surya-2 | placement lines | OpenRAIL-M | none possible | surya-ocr 0.24 has no line detector: no |
| DocScanner-L, DocGeoNet | dewarp | the authors' non-commercial licence | the 64 dewarp-placement pages in full | both crop the page; the guard holds them back: no |
| tech4humans signature detector | marks | YOLOv8s AGPL-3.0, gated | an ungated sibling from the same authors, Apache-2.0 | ties the YOLO11m marks detector on recall, worse at IoU 0.5: no |
| LensVLM-9B | reader | Apple AMLR | not run | a Qwen3.5-9B fine-tune for questions over compressed text images, not an OCR model; Qwen3.5-9B is measured, and the family rule (call 12) counts it as one |
| LayoutLMv3 (layout) | layout regions | CC BY-NC-SA 4.0 | not run | filed behind W46.nice-to-have (W46.licence-freed-rest) |
| DE-GAN, DocEnTr, DocDiff | restorers | various non-commercial | not run | low priority after the enhancement null; filed behind W46.nice-to-have |
| BLN600 | test material | CC BY-NC-ND 4.0 | Apple Vision on 40 excerpts | usable newspaper reading truth; Vision 0.947 |
| DocSplit | test material | CC BY-NC 4.0 | read the data | same construction as TABME; images not shipped: no |
| M6Doc | test material | academic use | read the annotations | no text truth, so the reading pick cannot be scored on it: no |
| Brno Mobile (B-MOD) | test material | CC BY 4.0 (Zenodo) | read the data | line crops only, so it cannot test a page sharpness cut: no |

## Reading order: LayoutReader

LayoutReader (hantian/layoutreader @629be376, LayoutLMv3-large fine-tuned on ReadingBank) is one more orderer in
`layout_order.py`'s three panels. It gets each set's boxes top to bottom, scaled to 0-1000 by the page size, as
MinerU feeds it. No page had more than 510 boxes. Every other orderer was rerun beside it, and all of them reproduce
`layout-order.json` exactly.

| Kendall tau, valid pages | LayoutReader | XY-cut, rows first | kraken's own order | App line sort | App region sort |
|---|---|---|---|---|---|
| Benchmark lines, all (35 of 40) | 0.990 | 0.979 | 0.984 | 0.911 | 0.954 |
| Benchmark lines, multi-column (15) | 0.986 | 0.990 | 0.991 | 0.833 | 0.983 |
| DocLayout-YOLO regions, all (19 of 40) | 0.921 | 0.952 | | 0.866 | 0.994 |
| L9 newspapers (15) | 0.839 | 0.574 | 0.293 | 0.198 | 0.905 |

Paired over pages, page bootstrap:

- **Benchmark lines.** Against XY-cut: +0.011 (−0.004 to +0.038), and −0.004 (−0.012 to +0.002) on multi-column pages.
  Against kraken: +0.005 (−0.006 to +0.017). Against the app's line column sort: +0.078 (+0.023 to +0.142). All but
  the last are ties, and XY-cut, a free rule, already beats the app's line sort.
- **Regions.** Against the app region sort: −0.073 (−0.14 to −0.019).
- **L9.** −0.067 (−0.167 to +0.014) against the app region sort, and −0.043 (−0.175 to +0.077) against PP-DocLayoutV3's
  own order, the newspaper pick.

The first run read the model's output as each box's position rather than the reading sequence. A synthetic
two-column page caught it (the columns came out interleaved), and the fix was made before the scored run.

## Mac readers: HunyuanOCR-1.5 and FastVLM

Both ran through `ocr_mac_local.py collect` on the 96 (the panel's frozen originals, temperature 0), scored with the
W41 Mac rows' scorer; rescoring LightOnOCR 8-bit the same way matches its row in `ocr-scorers-pages.csv` exactly.

**HunyuanOCR-1.5** (tencent/HunyuanOCR @47644ecc, bf16; the Tencent Hunyuan community licence, which does not extend to
users in the EU, the UK or South Korea, so a download offered in the app has to show that restriction). It used its
card's document-parsing prompt; the card's repetition penalty (1.08) was not applied, as for every reader here. It
needed two shims, both checked:

- mlx-vlm 0.7.4 (and 0.8.0) knows only HunyuanOCR 1.0's vision model type. `licence_sweep.py hunyuan-prep` links the
  1.5 snapshot with that one config name changed. The load is not strict for one extra tensor, an lm_head that is
  byte-for-byte the tied embedding; with it dropped, the strict load passes.
- mlx-vlm's BPE streaming detokenizer has no byte for a full-width bar some of its tokens carry. It raised on p010, so
  this reader decodes with the tokenizer itself.

On all 96, strict NES 0.853 with no failure. Two of the agreement-only originals ran to the 8,192-token cap. The
reference row it would replace or join is LightOnOCR-3 4B 8-bit, the Mac handwriting download.

| Paired on the 96 (strict NES, page bootstrap) | Incumbent | HunyuanOCR-1.5 minus it |
|---|---|---|
| Apple Vision | 0.831 | +0.023 (−0.014 to +0.061) |
| LightOnOCR-3 4B 8-bit | 0.892 | −0.038 (−0.072 to −0.009) |
| Xiaomi-OCR-0 bf16 | 0.887 | −0.034 (−0.061 to −0.011) |
| PaddleOCR-VL 1.6 bf16 | 0.888 | −0.035 (−0.074 to +0.003) |
| Qwen3-VL 8B 4-bit | 0.897 | −0.043 (−0.092 to +0.004) |
| PP-OCRv6 medium | 0.769 | +0.085 (+0.034 to +0.141) |

By kind: typewritten 0.906 (50 pages), printed 0.805 (28), handwritten 0.798 (16), mixed 0.658 (2). It runs at about
38 s a page median, with a 4.7 GB peak. A lighter model than LightOnOCR-3 4B, but it reads worse, handwriting
included, so it changes no pick. The 895 half was not run: the 96 settle that it changes no pick, and the Sherlock
size rule asks why a run is needed.

**FastVLM 0.5B** (mlx-community bf16 @81ffe929; Apple AMLR, research only) is a general VLM with no OCR prompt of its
own; it was asked for a plain transcription. 45 of 96 pages ran to the 4,096-token cap. Strict NES was 0.281,
−0.611 (−0.687 to −0.531) against LightOnOCR-3 4B 8-bit and −0.550 against Apple Vision. Its processor code imports
torch and timm, so it ran from this item's own venv (mlx 0.32.3 and mlx-vlm 0.7.4, as the lab's, plus torch and timm).
Peak memory 2.1 GB; 3.7 s a page median.

## Placement lines: GutenOCR-3B and Surya-2

**GutenOCR-3B** (bevaya/GutenOCR-3B @fd16c80c, Qwen2.5-VL-3B fine-tuned for grounded OCR; CC BY-NC 4.0) was asked for
its LINES output (text plus a box for each line) on the 41 place-hands pages: 21 owner hand pages and 20 Bentham. The
page went in at 1,792 px on its longer side, each side a multiple of 28. Each box became a line piece, pieces on one
row were joined as for the other box detectors, and the lines were aligned with McCATMuS CTC (`place_hands.py align
gutenocr ctc-mccatmus`). They were then dragged and scored like every place-hands hypothesis.

Two shims were needed:

- Its two bf16 shards hold no lm_head, though its config says untied. The repository's single-file copy carries one;
  range-read on 18 Nov, it is byte-identical to the shards' embed_tokens, so declaring them tied is exact
  (`licence_sweep.py gutenocr-prep`).
- In bf16 (7.5 GB) the model swapped past run-guarded's 2 GB limit beside the other sessions, so it ran as mlx-vlm's
  8-bit conversion (vision tower left in bf16, 4.3 GB).

The shipped placer's 244 page rows, re-dragged with this build of the writer and drag tool, equal their stored rows.

| Line pass, lines both score | Shipped placer (blla + McCATMuS conf) | GutenOCR + McCATMuS conf |
|---|---|---|
| Owner hands, truth reading, word writer | 34.9 (166/475) | 3.8 (18/475), −31.2 (−37.7 to −25.4) |
| Owner hands, truth reading, lab writer | 44.0 (209/475) | 3.4 (16/475), −40.6 (−49.4 to −32.4) |
| Bentham, truth reading, word writer | 51.9 (163/314) | 15.0 (47/314), −36.9 (−44.9 to −29.6) |

**This does not measure the model.** Its lines number about what kraken finds (15 against 20 on p007, 20 against 23
and 25 against 28 on two Bentham pages), and their x extents match kraken's lines. Their y extents stop at about 0.6
of the page's height, on 11 pages checked (p007: the last box ends at y 896 of 1,792, and kraken's last line at
1,510). So the boxes come back squeezed in height on this runtime, and every drag misses. Four pages also ran to the
6,144-token cap. Its processor files disagree (`preprocessor_config.json` names Qwen2VLImageProcessorFast,
`processor_config.json` Qwen3VLImageProcessor), and that is the likeliest cause. The authors' reference runtime
(transformers, `qwen_vl_utils`) was not tried. `W46.gutenocr-lines-ref` reruns it there before any verdict.

**Surya-2.** surya-ocr 0.24 (the Surya-2 release, checkpoint surya-ocr-2.5) has no text-line detector any more. One
VLM, served through llama.cpp, vLLM or mlx-vlm, returns layout blocks with their HTML, and nothing at line level, so
it cannot supply the placer's lines. The 0.22 line detector was scored in W46.place-hands: 0.804 baseline F, −19.6
line pass against the shipped placer.

## Dewarp: DocScanner-L and DocGeoNet

Both ran as `dewarp_placement.py` arms on the 64 place-curved-owner pages, after Apple's quad, on CPU. Each runs its
repository's own network (a U2NETP page mask, then the rectifier) at its own input size (288 and 256 px). The weights
are the authors' Google Drive releases. UVDoc's and DvD's rows were rerun beside them and reproduce unchanged.

| 24 bound or curled pages, line pass vs the route | DocScanner-L | DocGeoNet | UVDoc (for reference) |
|---|---|---|---|
| Reading copy | −18.4 (−30.1 to −8.5), 279 lines cut | −22.7 (−33.8 to −13.0), 296 cut | |
| Guard passes | 0 of 24 | 1 of 24 | 12 of 24 |
| Guarded copy | 0.0 | −0.1 (−0.3 to 0.0) | +3.2 (+0.4 to +7.7) |
| Placement only, one run a line | −9.1 (−14.6 to −5.3) | −10.6 (−16.2 to −6.0) | −8.9 |
| Their flat pairs, guarded | +0.5 (−1.1 to +2.8) | 0.0 | +1.1 |

Like DvD, both crop into the page, which is why the guard holds them back. Placement through either loses for the
reason dewarp-placement found: the carried-back lines still bend on the kept photograph. UVDoc stays the only
dewarper with a guarded gain.

## Signature detection: the tech4humans detector

The named model, tech4humans/yolov8s-signature-detector (AGPL-3.0), is gated, and its weights need a logged-in Hugging
Face account that has accepted its terms. The same authors' Conditional DETR-50, trained on the same Tobacco800 plus
signatures data, is Apache-2.0 and ungated (@9582471a). It stood in on `marks_detect.py`'s 32 owner-core pages (45
marks), matched class-agnostic as marks-detect scores the YOLO11m arm.

| Conf floor | Boxes | Loose-hit recall (IoU ≥ 0.1) | Precision | IoU ≥ 0.5 |
|---|---|---|---|---|
| 0.05 | 65 | 14/45 = 31% (15 to 52) | 22% | 5/45 |
| 0.25 | 18 | 8/45 = 18% (7 to 31) | 44% | 2/45 |
| 0.5 | 7 | 4/45 = 9% (2 to 21) | 57% | 2/45 |

At its default floor it ties YOLO11m (AnnoPage plus SignverOD: 8/45 = 18%, precision 53%) on loose-hit recall and is
worse at IoU 0.5 (2/45 against 6/45). It finds 2 of the 4 signatures and initials. A request for the gated model is
not worth the owner's time unless he wants it measured as named.

## Test material

- **BLN600** (Sheffield ORDA 25439023 v2, 600 nineteenth-century British Library newspaper excerpts with human
  transcriptions). Apple Vision at the app's settings, on 40 seeded excerpts, scored 0.947 NES (0.929 to 0.962),
  median 0.965, 5 under 0.9. This is usable newspaper reading truth beside L9's 15 pages. It is article crops, so it
  tests reading, not layout. The zip is AES-encrypted under a published password, which Python's zipfile cannot
  read; `tar --passphrase` can.
- **DocSplit** (amazon/doc_split). Packets spliced from RVL-CDIP-N-MP, modern business PDFs. Its images are not
  shipped (its toolkit rebuilds them, with Textract OCR). It is the same construction as TABME, which the
  segmentation bench already scores, and has no archival material.
- **M6Doc**. 9,080 pages with 74 region classes, its newspapers from 2020. It has no text truth, so the layout pick's
  metric (reading NES through the regions) cannot be scored on it, and DocLayout-YOLO was trained on it.
- **Brno Mobile (B-MOD)**. Scientific-paper pages photographed on 23 phones. Only the line crops are published (the
  Zenodo record holds b-mod_lines.zip alone), so it cannot test a page-level capture sharpness cut. Its line-level
  difficulty labels might test a line-level one, which is not a question on the queue.

## Not run

- **LensVLM-9B** (apple, AMLR). A Qwen3.5-9B fine-tune that answers questions over compressed renderings of text,
  using tools to expand pages. It is not an OCR model. Qwen3.5-9B itself is measured on the 96 (4-bit, 91.95 strict),
  and call 12 counts versions within one family as one. Its bf16 weights are 18.8 GB.
- **LayoutLMv3 as a layout detector.** Its published layout head is a detectron2 PubLayNet fine-tune (five classes, on
  modern articles), and detectron2 has no Mac wheel. LayoutReader, the LayoutLMv3 orderer, is measured above.
- **DE-GAN, DocEnTr, DocDiff.** Binarisers and cleaners. The enhancement null covers five methods, and the measured
  binariser (SBB) cost Apple Vision −5.3. Low priority, as the item says.
- These go behind W46.nice-to-have as `W46.licence-freed-rest`.

## Measurement card

- **Truth.** Each panel's own, unchanged:
  - The historical reading-order benchmark's and NewsBench's (layout order).
  - The owner's 96 truth pages (readers). The owner checked these.
  - kraken blla's lines (dewarp).
  - The place-hands truth lines, owner-audited for the hand pages (GutenOCR).
  - The reconciled marks core (signatures).
  - BLN600's human transcriptions.
- **Selection.** Every set is a frozen one an earlier item chose. The 40 BLN600 excerpts are a seeded random sample.
  No tested route and no ABBYY text chose anything.
- **Comparison.** Each new arm sees the same inputs and settings as the incumbents beside it. Incumbents were rerun in
  the same process (layout order, dewarp) or read from their committed per-page rows (readers, placement, marks).
- **Noise.** Every arm here is deterministic on one machine (greedy decoding, CPU or MLX), so the rerun floor is 0 and
  the paired interval alone tests a gap.
- **Scope.**
  - The readers ran on the 96 only. HunyuanOCR-1.5's 895 half was not run, since the 96 show it changes no pick.
  - FastVLM's prompt is ours, since it has none of its own.
  - The signature result is a stand-in for the gated model, not the model itself.
  - BLN600 was read by Apple Vision alone.
  - GutenOCR's placement figures are this runtime's, not the model's (above).
  - `ocr-scorers.json` and `ocr-scorers.md` are not regenerated: a full `ocr_rescore.py` run here would drop six Sherlock routes whose raw results are no longer on this Mac. The two new routes' 192 page rows were appended to `ocr-scorers-pages.csv` from the same rescore, whose rows for an untouched route (LightOnOCR-3 4B 8-bit) equal the committed ones on all 96 pages.
