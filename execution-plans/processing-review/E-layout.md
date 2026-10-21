# Strand E deep read: layout analysis and reading order for photographed archival pages

Date 2026-10-20. Deep read for the processing review (`execution-plans/processing-review/00-plan.md`, Phase 1). The
screen is `E-screen.md`; the inventory `I-inventory.md`; strand C's note `C-ocr.md` already covers region-first OCR
on newspapers and is built on, not repeated. Tags: [M] measured in the source at the location given; [I] my
inference from measured figures; [?] not verified (abstract, search snippet, vendor page, or a part of a source I
could not read). Our own figures cite the file under `ArchiveProcessor/segbench-results/` or `vision-ocr/`.

Full reads: RT-DocLayout / PP-DocLayoutV3 (arXiv 2606.23344, HTML); Real5-OmniDocBench (2603.04205, HTML, and the
dataset card); Orli (2606.04166, HTML, and the repository README); *Detection is easy, reading order is the tax*
(the repository README, the LICENSE and the paper PDF `paper/paper.pdf`, text-extracted); the Docling layout models
paper (2509.11720, HTML); *Reading Order Inference for Complex Document Layouts* (2607.01018, HTML); OmniDocBench
(2412.07626, the page-type, metric and newspaper sections, and the repository README); American Stories (2308.12477,
the PDF text-extracted); the Institutional Newspapers Pipeline (2608.18972, the PDF text-extracted, sections 4 and
7); RealDocBench (2606.07401, HTML); DocPTBench (2511.18434, HTML, both halves). Skims with figures taken:
DocLayout-YOLO (2410.12628), *Modeling Layout Reading Order as Ordering Relations* (2409.19672), *From Codicology to
Code* (2506.20326), MinerU2.5 (2509.22186, layout stage only), the Surya README and the surya_layout2 card and LICENSE,
the PP-DocLayoutV3 card, the kraken 5.2 `ketos` page (reading-order training), the SegmOnto site, the Semantic
Scholar records of the two postcard papers.

Swaps against the screen. In: DocPTBench (a second photographed benchmark with an unwarping arm, absent from the
screen); *From Codicology to Code* (per-class figures for marginalia and stamps on historical pages; it replaces
YALTAi, whose figures are only in a PDF I did not read); the ordering-relations paper, promoted from SKIM because it
carries the one measured figure for how much of a form is read out of linear order; American Stories read in full
from the PDF because its linking rule and per-class mAP are not in the abstract. Out or demoted: the GLM-OCR report
(nothing layout-specific that the RT-DocLayout and Real5 papers do not give); MinerU2.5 (its paper has no ablation of
the two-stage split, which was the reason to read it); the PaddleOCR-VL-1.5 paper (its Real5 figures are in the Real5
paper); the postcards chapter (paywalled; abstract only, tagged [?]). Corrections to the screen: its row 12 (arXiv
2608.12898, "NaviDC-OCR") is TeleOCR, and the 96.87 / 88.53 figures are TeleOCR's; its row 37 places the postcards at
ONB Labs, but the dataset is 4,293 postcards from the Grand Est region of France, 1899-1930, by Pélingre and Tabbone
(the ONB AKON set is only a cited reference); its row 11 gives Real5's licence as CC BY 4.0, which is the paper's
licence, while the dataset card says Apache-2.0 with the annotations under OmniDocBench's terms; its row 15 names
"Glossa" as a dataset, but it is one of three layout regimes on 11 ALTO pages.

## 1. Question

For photographs of archival pages that are not newspapers (typed letters and memos, forms and ledgers, clippings
pasted on sheets, tables, pages with handwritten annotations and stamps), does a layout stage before the reader
help, hurt or do nothing, and for which reader sizes; which method gives the reading order on multi-column and
mixed pages (detector plus geometry, PP-DocLayoutV3's coupled order, kraken, Orli, LayoutReader, text-based
ordering, the reader's own order); can the layout regions feed the marks layer (annotations, stamps, signatures)
and the segmentation cues (letterheads, salutations, signatures as document starts and ends); which
photographed-page benchmark to borrow; what the licences allow in an app shipped to other users; and what runs on
a Mac.

## 2. What the field does now

**A detector in front of the reader is the production norm for dense print, and the gain is the reader's, not the
page's.** Every published pipeline on newspapers is layout-first: American Stories runs a YOLOv8m on 2,202 labelled
scans and gets article mAP 91.31 and headline 88.64 [M, Table 2]; the Harvard-Boston pipeline runs a YOLO26x over
1,473,635 scans into 83.1 million crops and reads each crop with Tesseract and dots.mocr, because whole-scan VLM
reading was "inconsistent and seemed to drop significantly on complex or dense scans" [M, §4.1]; the parsing
systems (MinerU2.5, PaddleOCR-VL, GLM-OCR) run a layout model inside and read crops at native resolution
(MinerU2.5: layout on a 1036x1036 thumbnail, crops up to 2048x28x28 pixels [M, §3.2]). Our own NewsBench rows say
the same, and say for whom: GLM-OCR goes from 29.2 NES whole-page on the 15 L9 pages to 0.969-0.973 on
DocLayout-YOLO regions, Tesseract from 0.677 to 0.919, Gemini 3.5 Flash Lite from 0.820 to 0.961, Claude Haiku 4.5
from 0.232 to 0.894, while Qwen3.6-27B whole-page scores 0.967 and gains nothing from regions (0.965 on
DocLayout-YOLO, 0.936 on PaddleX) [M, `newsbench-score.txt`; `open-sweep-20261019.md`]. So a layout stage is a
substitute for a reader large enough to hold a dense page, and a way to use a 1B reader where a 27B one was needed:
the GLM-OCR region job read 1,087 pages per GPU-hour on an L40S against 65 for Qwen3.6-27B whole-page, at the same
score [M, `farmshare/news/*/summary.json`].

**Nobody has measured a layout stage on ordinary archive pages, and the one proxy says it hurts on handwriting.**
No source read here isolates a detector's effect on single-column letters, memos or forms. The nearest evidence is
OmniDocBench's handwritten "notes" subset: DocLayout-YOLO reaches mAP 9.54 there against 57.54 on newspapers and
47.38 overall, LayoutLMv3 0.80 and DiT-L 0.21 [M, Table 6], and MinerU "detects all handwritten notes as figures",
scoring text edit distance 0.984 on notes where Qwen2-VL-72B scores 0.168 [M, §III, Table 3]. Detectors trained on
born-digital pages do not see handwriting as text. The postcards chapter (ICDAR 2026) reports the same shape on
historical paper: zero-shot VLMs "struggle with layout understanding on complete postcards" but transcribe zones
well, and the authors recommend a detector plus a VLM [?, abstract via search; full text paywalled].

**Photographs break the pipelines more than the VLMs, and the layout module is where they break.** Real5 recaptures
every OmniDocBench v1.5 page five ways with phones and a scanner. PP-StructureV3 falls from 84.68 on scans to 37.98
on skewed photographs and Marker from 70.27 to 41.27, while Gemini-3 Pro moves from 89.47 to 89.45 and Qwen3-VL-235B
from 89.43 to 86.56 [M, Table 1]. The RT-DocLayout paper swaps only the layout module in front of a fixed
PaddleOCR-VL-1.5 recogniser: DocLayout-YOLO gives 74.07 overall on Real5 and 48.74 on skew, PP-DocLayoutV2 85.83
and 77.03, RT-DocLayout (PP-DocLayoutV3) 92.05 and 91.66 [M, Table 2]. DocPTBench, built the same way from the 981
OmniDocBench pages, finds PaddleOCR-VL's English parsing edit distance rising from 10.5 to 37.5 on photographs and
its reading-order edit from 4.5 to 29.1, with unwarping recovering most of it (15.9), and attributes the collapse to
"rectangular bounding-box assumptions that clash with warped text" [M, Table 2, §4.1]. Both benchmarks are modern
born-digital content photographed; neither has archival paper.

**Reading order is the step the field undermeasures, and geometry solves most of it.** An independent working draft
(September 2026) holds detection fixed on 15 multi-column historical pages and swaps only the ordering rule: a
top-to-bottom sort gives Kendall tau 0.50, XY-cut 0.50, column clustering 0.99 (95% CI 0.98-1.00), kraken's native
order 0.97-1.00; with perfect line recognition assumed, naive order alone makes a median 82% word error, which
clustering cuts to 2% [M, Tables 1-3, §7]. The same gap appears on a 17th-century Swedish court hand and a
20th-century two-column English page [M, Table 2]. Learned order models trained on modern born-digital pages fail
on historical material: LayoutReader scores tau 0.16, 0.15 and 0.12 on those pages, worse than the naive sort
[M, §8], 24.6% correct successor edges on OmniDocBench multi-column pages against 75.3% for XY-cut [M, 2607.01018
Table 3], and segment-level F1 9.44 on forms [M, 2409.19672 Table 1]. The coupled relation head in PP-DocLayoutV3
is the one learned method with good figures, and only because it is coupled: the decoupled pointer variant scores
reading-order edit 0.189 against XY-cut's 0.074 and the coupled head's 0.041 [M, RT-DocLayout Table 3, §4.3].
Harvard's production answer is HDBSCAN on crop x-centres plus rules, at position accuracy 80.8% and tau 0.959
(micro) on 723 annotated newspaper scans [M, IDI §7.2, Table 6].

**Order on annotated pages is not a permutation.** The ordering-relations paper (EMNLP 2024) argues that one
sequence "does not adequately convey the complete reading order", because headers, footers and watermarks are read
apart from the body, a table reads two ways, and a form's question precedes its answer across intervening content;
on EC-FUNSD 23.76% of segments sit in non-linear order [M, §1-2.4]. That matches what our text layer needs: a body
stream in order, and marks placed and labelled as marks (strand D §6.5).

**The historical-HTR community orders lines by geometry and typology.** kraken's default is a heuristic; its
optional reading-order model "works purely on the typology and geometric features of the lines and regions", each
line a type plus its start, centre and end points, compared pairwise, validated by Spearman's footrule, and the
docs warn it "might not perform better than the default heuristic for simple text flows" [M, kraken 5.2 ketos].
Orli replaces that with an autoregressive model that emits baselines in reading order, trained on 196,691 pages
(51.3% Latin, 15.2% Hebrew, 4.2% Cyrillic, 3.4% Arabic, including "twentieth-century correspondence and
administrative records"), slightly above the cBAD 2019 state of the art on detection (F1 0.9340 vs Planet 0.931) and
near-perfect zero-shot order on two reading-order sets (tau 0.9967, 0.9971) but tau 0.2878 zero-shot on ABP, a
tabular set whose order follows "a dataset-specific traversal convention" [M, Tables 3-4, §6].

## 3. Claims table

| # | Source | Claim | Figure | Conditions | Tag | Location |
|---|---|---|---|---|---|---|
| 1 | RT-DocLayout 2606.23344 | Layout module swap in front of a fixed recogniser on OmniDocBench v1.5 | Overall / RO edit with PaddleOCR-VL-1.5: DocLayout-YOLO + XYCut 87.29 / 0.169; PP-DocLayoutV2 93.56 / 0.042; RT-DocLayout 94.50 / 0.042; with MinerU2.5 85.73 / 0.177, 92.00 / 0.051, 92.68 / 0.049 | params 20M / 53M / 33M; FPS 107.4 / 110.9 / 132.1 on an A100 at batch 32 | M | Table 1, Fig. 1 caption |
| 2 | RT-DocLayout | Same swap on Real5 (photographed) | DocLayout-YOLO overall 74.07 (scan 85.57, warp 74.70, screen 77.67, illumination 83.65, skew 48.74); PP-DocLayoutV2 85.83 (skew 77.03); RT-DocLayout 92.05 (93.43 / 91.25 / 91.76 / 92.16 / 91.66) | PaddlePaddle authors; recogniser PaddleOCR-VL-1.5 | M | Table 2 |
| 3 | RT-DocLayout | Coupled order beats pointer and XY-cut; augmentation gives the skew robustness | RO edit: bbox+mask with XYCut 0.074; decoupled pointer 0.189; coupled 0.041; augmentation 0.042; Real5 skew overall 77.55 without augmentation, 91.66 with | | M | Table 3, §4.3 |
| 4 | RT-DocLayout | Design and training | RT-DETR query decoder; antisymmetric NxN relation matrix, sorted by expected predecessor count; masks not polygons in the paper; about 38k in-house pages (papers, textbooks, financial reports, slides, newspapers, exams, invoices); 25 classes incl. Seal, Header, Footer, Aside Text, Header Image, Footer Image, Vision Footnote, Vertical Text; warping simulated | no handwritten, historical or real photographed training pages named | M | §3.2, §3.4, §4.1.1, §4.1.3 |
| 5 | PP-DocLayoutV3 card | Licence and status | Apache-2.0; ECCV 2026; layout module of PaddleOCR-VL 1.5/1.6, GLM-OCR, Xiaomi-OCR-0 | | M | model card |
| 6 | Real5 2603.04205 | Pipelines collapse on photographs, VLMs hold | scan vs skew: PP-StructureV3 84.68 / 37.98; Marker 70.27 / 41.27; MinerU2.5-Pro 92.11 / 81.26; GLM-OCR 92.67 / 85.39; dots.ocr 86.87 / 84.27; Qwen3-VL-235B 89.43 / 86.56; Gemini-3 Pro 89.47 / 89.45; PaddleOCR-VL-1.6 94.74 / 92.66 | 1,355 pages x 5 conditions; phones from Apple, Xiaomi, OPPO; Canon C5840 scans | M | Table 1, §3.3 |
| 7 | Real5 | Reading order under skew | ROE: PP-StructureV3 0.417, Marker 0.543, GLM-OCR 0.156, MinerU2.5-Pro 0.107, Qwen3-VL-235B 0.091, Gemini-3 Pro 0.092, PaddleOCR-VL-1.6 0.058 | | M | Table 6 |
| 8 | Real5 card | Licence, size, structure | Apache-2.0 for images and repository; annotations are OmniDocBench v1.5's `OmniDocBench.json` under its terms; 6,775 images, about 16 GB, five folders; originals not listed in the tree | nine page types incl. notes; newspapers not named | M | dataset card, §3.1 |
| 9 | OmniDocBench 2412.07626 | Born-digital detectors fail on handwritten notes | layout mAP newspaper / notes / average: DocLayout-YOLO 57.54 / 9.54 / 47.38; LayoutLMv3 30.84 / 0.80 / 28.84; DiT-L 23.65 / 0.21 / 26.90 | 981 pages: 111 newspaper, 116 notes | M | Table 6, Table S3 |
| 10 | OmniDocBench | Pipelines and VLMs fail on opposite page types | text edit notes / newspaper: MinerU 0.984 / 0.171; Marker 0.651 / 0.192; GPT-4o 0.607 / 0.751; Qwen2-VL-72B 0.168 / 0.676; "MinerU detects all handwritten notes as figures" | | M | Table 3, §III, §5.1 |
| 11 | OmniDocBench | Reading order edit (EN) | MinerU 0.079, Mathpix 0.108, Marker 0.114, Qwen2-VL-72B 0.119, GPT-4o 0.128, InternVL2 0.317 | normalised edit distance over text blocks only | M | Table 2, §4.3 |
| 12 | OmniDocBench README | Licence | code Apache-2.0; "The dataset is for research purposes only and not for commercial use"; 1,651 pages in the current version | | M | README |
| 13 | Hist. reading-order benchmark (Jha, draft Sept 2026) | Detection ties, order splits | kraken blla F 0.91, tau 0.98, 10.6 s/page; YOLOv8m 0.91, 0.77, 1.2 s; Surya 0.78, 0.77, 5.0 s; Tesseract 0.59, 0.98; docTR 0.60, 0.81 | 40 pages, 8 languages, 15 multi-column; tau on matched lines with a 60%-and-15-lines validity guard; CPU or Apple MPS | M | Tables 1-2, §5 |
| 14 | same | Column clustering recovers order | multi-column tau on YOLO boxes: top-to-bottom 0.50 [0.47, 0.54], XY-cut 0.50, column clustering 0.99 [0.98, 1.00]; kraken native 0.97-1.00; order-induced word error median 82% (Swedish 93%) to 2%; Swedish scale-up to 28 pages 0.51 to 1.00, English to 8 pages 0.50 to 0.99 | perfect line recognition assumed for the word error | M | Table 3, §7, Fig. 4 |
| 15 | same | Off-the-shelf systems carry their domain's blind spot | Transkribus Text Titan II: manuscripts tau 1.00, two-column English print 0.51 and 0.50; PP-StructureV3: English 0.94, Swedish hand 0.44; LayoutReader 0.16 / 0.15 / 0.12 | spot checks on three pages | M | §8 |
| 16 | same | Licence | MIT (Abhishek Jha, 2026) | | M | LICENSE |
| 17 | Orli 2606.04166 | Detection and order | cBAD 2019 F1 0.9340 base, 0.9351 fine-tuned (Planet 0.931); cBAD order tau 0.9113; zero-shot OHG tau 0.9967, FCR 0.9971; ABP 0.2878 zero-shot, 0.8972 fine-tuned | order measured on matched lines only | M | Tables 3-4, §5.2 |
| 18 | Orli | Training data and design | 196,691 pages; Latin 51.3%, Hebrew 15.2%, Cyrillic 4.2%, Arabic 3.4%; 25% synthetic arXiv renderings; includes 20th-century correspondence and administrative records; ConvNeXtV2-tiny + RT-DETR encoder + 12-layer LLaMA-style decoder; 16-point baselines; greedy decoding | no speed figure; trained 32 h on three A40s | M | §3, §4.1, Table 1 |
| 19 | Orli README | Licence and runtime | Apache-2.0; kraken 7 plugin; weights `orli_base.safetensors` (Zenodo 10.5281/zenodo.20558179); input 1920x1440; "only works in bfloat16 precision", other precisions "likely to cause runaway generation" | CPU, MPS unstated | M | README |
| 20 | kraken 5.2 ketos | Reading-order model | features: line or region type plus start, centre, end points, pairwise; `ketos rotrain`, bundled by `roadd`; validated by Spearman's footrule; "might not perform better than the default heuristic for simple text flows" | | M | ketos.html |
| 21 | Docling heron 2509.11720 | Timings | CPU (EPYC 7763, 4 threads, batch 32): heron 0.643 s, egret-m 0.334 s, heron-101 0.988 s; A100 batch 100: heron 0.030 s; MPS (M3 Max, 64 GB) batch 50: heron 0.044 s, egret-m 0.033 s | 640x640 input | M | Table 5 |
| 22 | heron | Accuracy and data | canonical DocLayNet mAP heron 0.776, heron-101 0.780, egret-m 0.765; 150k pages from DocLayNet, DocLayNet-v2, WordScape; 17 classes incl. Form, Key-Value Region, Checkbox, Page-header, Page-footer; YOLO excluded for licence | no photographed or handwritten pages | M | Tables 1-3, §Data |
| 23 | DocLayout-YOLO 2410.12628 | Benchmarks and classes | D4LA mAP 70.3, DocLayNet 79.7; DocStructBench 10 classes (Title, Plain Text, Abandoned Text, Figure, Figure Caption, Table, Table Caption, Table Footnote, Isolated Formula, Formula Caption) over academic, textbook, market, financial subsets; 85.5 FPS on an A100 | no newspaper, handwritten or photographed pages | M | Tables 1-3, §5.1 |
| 24 | 2607.01018 | Training-free text-based order | ALTO 11 pages: 95.4% successor edges vs XY-cut 80.5, LayoutReader 22.5; wrap-around regime 94.8 vs 49.7; OmniDocBench multi-column (140 pages) macro 88.0 vs 75.3 vs 24.6; newspaper 74.2 vs XY-cut 96.2 | pythia-410M + BERT NSP over OCR lines with known boxes; 93.5 s/page on an A40, 6.8 GB; no code | M | Tables 2-3, §7.5 |
| 25 | 2409.19672 | Permutation is the wrong target for forms | 23.76% of EC-FUNSD segments in non-linear order; segment-level F1: LayoutReader 9.44, LayoutLMv3-large 82.38, human 99.28 | ROOR, 199 forms | M | §2.4, Table 1 |
| 26 | American Stories 2308.12477 | Layout-first newspaper pipeline | YOLOv8m on 2,202 scans, 48,874 objects; mAP articles 91.31, headlines 88.64, ads 78.4, overall 63.48; line detection 86.20; headline-article association F1 97.0; CER from layout 0.012 of 0.051 | ten labelled scans for evaluation; linking rule: vertical overlap over 1% of page width and headline bottom within 10% of page height above the article; CC-BY | M | Table 2, §Content Association, Supp. |
| 27 | IDI pipeline 2608.18972 | Crop-level reading at scale, geometric order | YOLO26x; 1,473,635 scans, 83,147,041 crops; dots.mocr on 8 L40S; order by HDBSCAN on x-centres plus rules: position accuracy 72.1% macro / 80.8% micro, tau 0.922 / 0.959 on 723 annotated scans; dots.mocr "not immune" to hallucinations and token loops, some "helpful" on damaged text, no rate | | M | §4.1, §7, Table 6 |
| 28 | RealDocBench 2606.07401 | Commercial and open layout on scanned regulated documents | adjusted F1: Extend v2 0.835, AWS Textract 0.726, PaddleOCR-VL 1.5 0.680, Azure DI 0.637, dots.ocr 0.317 | 1,500 rendered and scanned pages, 9 classes; no photographs named | M | Table 7, §3.3 |
| 29 | DocPTBench 2511.18434 | Photograph drop and unwarping | English overall edit original / photographed / unwarped: PaddleOCR-VL 10.5 / 37.5 / 15.9; MinerU2.5 11.1 / 37.3 / 17.3; dots.ocr 12.5 / 33.7 / 16.3; olmOCR2 16.1 / 27.8 / 17.5; Gemini 2.5 Pro 14.8 / 18.2 / 16.9; PaddleOCR-VL RO edit 4.5 to 29.1 | 981 simulated photos plus 400 physical photos of 100 originals; licence unstated | M | Table 2, §3.1, §7.3 |
| 30 | Codicology to Code 2506.20326 | Detectors on historical zones, small data | CATMuS mAP50:95: YOLOv11x-OBB 0.564, Co-DETR 0.492, Grounding DINO 0.452, YOLOv11x 0.425; MarginTextZone 0.163-0.338; RunningTitleZone 0.067-0.175; StampZone 0.864 (YOLO-gen); A6000 7-14 ms (YOLO) vs 102-140 ms (transformers) | 1,525 / 158 CATMuS images; medieval and early print; OBB "a fundamental necessity" | M | Tables 8-9, §5 |
| 31 | Surya README, surya_layout2 LICENSE | Licence and Mac speed | weights "AI Pubs Open RAIL-M (modified)": barred if the user's employer had over $5M revenue or raised over $5M, personal and research use exempt, barred for competing products; code Apache-2.0; Apple Silicon via llama.cpp 0.108 pages/s (p50 59 s); OldScan pass rate 41.8 | layout boxes carry a `position` reading-order index | M | README, LICENSE Attachment A |
| 32 | Postcards (Pélingre, Tabbone; ICDAR 2026; SUMAC 2025) | Hybrid beats whole-postcard VLM | VLMs "struggle with layout understanding on complete postcards" but transcribe zones well; pipeline YOLOv12x + EasyOCR; 4,293 postcards, Grand Est, 1899-1930 | abstract only; chapter paywalled; SUMAC paper CC BY | ? | Springer abstract via search; S2 record |
| 33 | SegmOnto site | Zone vocabulary covers marks | 15 zone types incl. MarginTextZone (subtypes note, commentary, correction, variants, criticalApparatus, addition), StampZone, SealZone, DamageZone, DigitizationArtefactZone; 6 line types | v0.9, 2023 | M | segmonto.github.io |
| 34 | NewsBench (our run) | Regions lift small readers, not a 27B | GLM-OCR regions 0.969-0.973 (whole-page L9 29.2 NES, 6/15 answered); Tesseract 0.677 to 0.919; Gemini 3.5 Flash Lite 0.820 whole, 0.920 PaddleX regions, 0.961 DocLayout regions (the last from NewsBench's scoresheet, C-ocr claim 46); Claude Haiku 4.5 0.232 to 0.894; gpt-5.6-luna 0.503 to 0.921; qwen3.8-flash 0.341 to 0.907; Qwen3.6-27B whole 0.967, DocLayout-YOLO regions 0.965, PaddleX regions 0.936; AS-YOLO regions 0.62-0.82 | 15 By the People pages; `overall` is 1-CER on lowercased alphanumerics | M | `farmshare/news/newsbench-score.txt`; `open-sweep-20261019.md`; `C-ocr.md` claim 46 |
| 35 | FarmShare news jobs | Throughput of the two routes | GLM-OCR on DocLayout-YOLO regions 1,087 pages/GPU-hour, NES 0.962 (panel normalisation); Qwen3.6-27B whole at 3,584 px 65 pages/GPU-hour, 0.959; Qwen3.8-27B whole 67 pages/GPU-hour, 0.884 with one page failed | one L40S, vLLM 0.31.0 | M | `farmshare/news/*/summary.json` |
| 36 | layout-compare (lab, 2026-10-16) | Three detectors are interchangeable on scanned newspapers | `wm_share` (the lab's word-miss share, region words aligned onto Vision's lines) with Vision as reader: YOLO 0.2654, PP 0.2665, heron 0.2655 (Vision alone 0.2963); with Paddle 0.2183 / 0.2253 / 0.2161; with Falcon 0.2135 / 0.2206 / 0.2116; detect 0.51 / 0.47 / 0.41 s a page on the M3 Pro CPU; peak RSS 1,241 / 794 / 1,439 MB; weights 72 / 128 / 164 MB; ink in text regions 0.858 / 0.861 / 0.945 | 15 pages, 11 newspapers and 4 whole-page scans; all print | M | `LAYOUT-COMPARE-2026-10-16.tsv`, `-fit.tsv` |
| 37 | OCR-LAYOUT (lab, 2026-10-07) | Detector faults | DocLayout-YOLO labels 4 of 6 `figure` boxes on headlines; PP-DocLayoutV3 at its default conf 0.5 covers 0.767 of text ink (paragraphs and a headline missed), 0.3 kept; PP's order "column by column, top to bottom, with a few neighbouring pairs swapped"; YOLO has no order | one newspaper and one ordinary page; both cover 1.000 of the ordinary page | M | TSV header |
| 38 | layout-compare | A detector can push a small reader into a loop | heron's 42 regions on s47 sent Falcon-OCR past the 600 s bound (1,206 s, two tries); alone an hour later 64.4 s | | M | TSV header |
| 39 | kind-classifier.md | Apple Vision as a zero-download table finder | "Vision document request finds any table" right on 134/144, forms found 7/14, 3 false calls; 0.38 s a page | 144 owner pages, 14 forms | M | §2, §5 |
| 40 | ocr-truth.md | What the 96 hold for this strand | 13 clippings and 12 tables in the 100 drawn; 2,187 clippings and 456 tables among 21,105 documents; 2 mixed-hand pages in 100 | | M | table, §41 |

## 4. Code, weights, data and licences

| Item | Code | Weights or data | Licence | Mac-runnable | Cluster needs |
|---|---|---|---|---|---|
| DocLayout-YOLO DocStructBench | github opendatalab/DocLayout-YOLO, AGPL-3.0 | HF juliozhao, Apache-2.0 (card) | weights Apache-2.0; code AGPL-3.0, which the app neither ships nor runs [M, lab] | yes: Core ML 72 MB, 0.51 s a page CPU, 1,241 MB [M, claim 36]; ONNX build matches within 0.0002 px | none; 85.5 FPS on an A100 |
| PP-DocLayoutV3 | PaddleOCR / PaddleX | HF PaddlePaddle, Apache-2.0 | Apache-2.0 [M, card] | yes: MLX float32 128 MB via mlx-vlm's `pp_doclayout_v3`, 0.47 s a page, 794 MB [M, claim 36]; ONNX community | none; 132 FPS on an A100 |
| docling-layout-heron | docling-project, MIT | HF docling-project, Apache-2.0 [M, inventory] | Apache-2.0 weights, MIT code; paper says "permissive" | torch only, 164 MB, 0.41 s a page, 1,439 MB [M]; no MLX or Core ML; MPS 0.044 s on an M3 Max [M, claim 21] | none |
| Surya (layout VLM) and surya_layout2 (fast detector) | Apache-2.0 | HF datalab-to | weights modified OpenRAIL-M: $5M revenue or funding cap on the user's employer, personal and research exempt, no competing products, restrictions must pass downstream [M, claim 31] | VLM via llama.cpp at 0.108 pages/s; layout2 on CPU torch | GPU via vLLM |
| kraken blla + optional RO model | kraken, Apache-2.0 | Zenodo models | Apache-2.0 | yes, CPU: 10.6 s a page [M, claim 13]; our specialists note measured about 30 s a page for blla on one core (`bench-corpus/specialists.md`) | none |
| Orli | github mittagessen/orli, Apache-2.0 | Zenodo 10.5281/zenodo.20558179 | Apache-2.0 [M, README] | unverified: bf16 only; CPU bf16 is slow and MPS bf16 untested here | GPU; 1920x1440 input |
| LayoutReader / ReadingBank | github doc-analysis | research use only [?, screen] | not for shipping; drop on performance anyway (claims 15, 24, 25) | n/a | n/a |
| 2607.01018 text-based ordering | no code released; generator and ALTO annotations "will be released" | | n/a | no: 93.5 s a page on an A40 | A40-class |
| Nemotron-Parse 2.0, granite-docling-258M, Unlimited-OCR, indra-ocr (joint layout+text) | per inventory | HF | OpenMDW-1.1; Apache-2.0; MIT; OpenRAIL-M ($20M) | MLX builds for Nemotron-Parse 2.0 and granite-docling; Unlimited-OCR MLX and Core ML; indra ONNX CPU [M, inventory] | none |
| Real5-OmniDocBench | OmniDocBench evaluator (Apache-2.0) | HF PaddlePaddle, 16 GB | images Apache-2.0; annotations under OmniDocBench terms (research only) [M, claims 8, 12] | evaluator yes | download and 6,775-image runs |
| DocPTBench | github Topdu/DocPTBench | | unstated [M, claim 29] | | |
| Wild-OmniDocBench | github VirtualLUOUCAS, zip | | unstated [?] | | |
| OmniDocBench v1.5-1.7 | Apache-2.0 | HF opendatalab | data research only [M] | yes | |
| Historical reading-order benchmark | harness/score.py | 40 pages with ALTO/PAGE order, predictions bundled | MIT [M] | yes | none |
| American Stories | github (linked) | HF dell-research-harvard/AmericanStories | CC-BY [M, claim 26]; the 2,202 labelled training scans' availability unverified [?] | yes | none |
| RealDoc-Bench-Layout | github extend-hq, Apache-2.0 code | HF Extend-AI | QA bank CC BY 4.0; layout track licence unstated [?] | yes | none |
| AnnoPage | strand D | Zenodo 5 GB | CC BY 4.0 [M, D-enhancement claim] | | |
| SegmOnto vocabulary and YALTAi models | github SegmOnto; Zenodo | | open (Zenodo, HF) [?, screen] | | |

## 5. Comparison with what we measured

**Newspapers.** Our rows and the field agree, and our run adds the throughput that the field leaves out: GLM-OCR
on DocLayout-YOLO regions matches Qwen3.6-27B whole-page (0.969 against 0.967) at seventeen times the pages per
GPU-hour (claim 35). Our three detectors are interchangeable on scanned newspapers to within 0.007 of word-miss
share (claim 36), which is why the lab kept DocLayout-YOLO: smallest weights, a Core ML build, and no torch. RT-
DocLayout's Table 2 is the measured claim that this choice is wrong on photographs (DocLayout-YOLO 48.74 on skew
against 91.66), and it is the one figure here that would change a decision. It needs checking on our material
because the paper is by the PaddlePaddle team, DocLayout-YOLO there runs with XY-cut rather than our column sort,
and the skew in Real5 is extreme 3D pose on modern pages; our box photographs are upright at a few degrees after the
app's rotation step, so the relevant Real5 conditions are illumination and warp, where the gap is 83.65 vs 92.16 and
74.70 vs 91.25 [M, claim 2].

**Ordinary pages: nothing measured, on either side.** We have no region-first result on a letter, memo, form or
clipping; the lab's one ordinary page shows both detectors covering all its text ink (claim 37), which says the
stage is harmless there, not useful. The field's proxy is OmniDocBench's notes (claim 9), and it predicts that a
born-digital detector in front of a handwritten page loses the page. Our kind router already separates handwritten
from typed and printed pages at 139 of 144 (`kind-classifier.md`), so the layout stage can be gated by kind without
new machinery. The owner corpus has 2,187 clippings and 456 tables (claim 40); the 96 hold 13 and 12 of them, so
a region-first test on the 96 has about 25 pages where it could matter and about 70 where the expected result is
no change.

**Reading order.** Our open sweep's PP-OCRv6 row is the field's finding reproduced on our pages: every page
answered, 23.6 NES on L9 and about 6 NES on the three OmniDocBench newspaper pages in N5, because lines came in
detector order and interleaved across columns [M, `open-sweep-20261019.md`, sample review]. The benchmark's 82%
order-induced word error (claim 14) and our 23.6 are the same effect under two metrics. The field's cheapest fix,
column clustering on detected boxes, is what the lab's "column sort" already is in spirit; whether it reaches 0.99
on our pages is unmeasured, since the lab aligned region words onto Vision's lines and scored words, not order.
NewsBench's `gap` column (the difference between an order-robust and an order-sensitive score) is the order signal
we already compute: it is 0.001-0.027 for the DocLayout rows and 0.13-0.23 for the failed whole-page rows
[M, claim 34], which says the column sort is adequate on these 15 pages. Nothing is measured for order on pages with
annotations, and no public set has photographed annotated pages with an order ground truth; strand D's planned
150-page marks set is where that ground truth has to come from.

**Photographs.** Real5 and DocPTBench measure the capture effect we assumed and had not measured (strand C's open
question 1), on modern content. Both say the layout module is the fragile part of a pipeline and that a large VLM
barely notices the photograph. Our half-size and quarter-size ladder measures resolution, not geometry. The
borrowing is direct: our full staged route on Real5's illumination, warp and skew subsets, scored with the
OmniDocBench evaluator, gives a photograph-robustness figure for our pipeline against twenty published rows at no
labelling cost (test 1).

**Where a public benchmark makes ours less necessary, and what to borrow.**

- Real5 (images Apache-2.0; annotations research-only, which is fine for internal measurement): borrow the
  five-condition protocol and the evaluator; do not build our own photographed-distortion set for layout. It
  cannot replace a test on archival paper, since it has no handwriting, no clippings, no stamps.
- DocPTBench: borrow the unwarping arm (original / photographed / unwarped) as the design for strand D's dewarp test
  on layout; the data licence is unstated, so measure with it, do not redistribute.
- The historical reading-order benchmark (MIT): borrow `harness/score.py`, the tau-with-validity-guard metric and
  the order-induced word error computation, and its 40 pages as a public anchor for any ordering stage; it is the
  one public set with line-level order on historical pages. Add our own pages to it rather than build a second
  harness.
- OmniDocBench's reading-order edit distance (`reading_order: Edit_dist`) and NewsBench's `gap`: run both on every
  staged output so order is scored apart from characters, as the survey of OCR evaluation (screen row 41) and the
  benchmark both ask.
- American Stories' linking rule (claim 26) is a two-line heuristic for headline-to-article association worth
  copying for clippings; its class set (article, headline, caption, byline, image, ad, table, masthead) is the right
  one for newspaper clippings and is CC-BY.
- Not worth borrowing: DocEng's photographed sets are binarisation competitions (32 documents, four phones, 2020;
  a 2023 edition) with no layout or order labels and no archival paper [?, search]; RealDoc-Bench-Layout is scanned
  and rendered regulated forms with a key-value class, useful only if we want a forms detector and only as a
  comparison with Textract and Azure (claim 28); Wild-OmniDocBench is an unlicensed zip; M6Doc is non-commercial and
  by request.

## 6. Strand-specific questions

### 6.1 Does layout-first help ordinary archive pages, and for which reader sizes

The evidence sorts pages into three groups.

Dense multi-column print (newspapers, clipping sheets with several items, programme and magazine pages): yes, for
every reader under about 10B and every OCR-specialist model, and it is the cheapest route to a newspaper score of
0.97 on a laptop or a cluster (GLM-OCR regions: 1B, 1,087 pages per GPU-hour). For 27B-class open models and the
frontier APIs the gain is nil on our 15 pages (claim 34) and the stage is a cost choice, not an accuracy one. For
Gemini 3.5 Flash Lite, Claude Haiku and gpt-5.6-luna, which are the cheap-API profile's models, the gain is large
(0.82 to 0.96, 0.23 to 0.89, 0.50 to 0.92).

Single-column typed and printed pages (most of the owner corpus): the expected effect is nothing, and the measured
ink coverage on the lab's one ordinary page is 1.000 for both detectors (claim 37). The costs of a stage are real
and measured: a detector adds 0.4-0.5 s a page on a Mac and 0.8-1.4 GB of memory (claim 36), it can mislabel a
headline as a figure (claim 37), and a reader that loops on a region can stall a page (claim 38). No source
measures a gain. The recommendation the evidence supports is a kind-gated stage: on, by default, for kinds the
router calls printed or mixed with a multi-column or clipping signal; off for typewritten single-column pages.

Handwritten pages: the proxy says harm (DocLayout-YOLO mAP 9.54 on notes; MinerU reads notes as figures, claim 9-10).
No detector read here was trained on handwriting except kraken's blla and Orli, which detect lines, not regions, and
the Codicology study, which shows a YOLO fine-tuned on manuscript zones reaching 0.56 mAP on medieval pages but only
0.16-0.34 on marginalia (claim 30). The stage should be off for handwritten kinds unless the marks layer (6.3) needs
boxes, in which case the detector is a marks detector, not a text-layout one.

Forms and ledgers (L4, 52-70 NES for every open route) and tables (12 in the 96): unmeasured either way. Heron and
PP-DocLayoutV3 carry Form, Key-Value Region, Checkbox and Table classes (claims 4, 22); Apple Vision's document
request finds 7 of 14 owner forms (claim 39). Whether a table-region crop read by a VLM beats the whole page is test
3's question.

What the reader-size rule means per profile: laptop profile (open weights 1-8B) and cheap API (Flash Lite, Haiku,
small OpenRouter models) gain from the stage on dense pages; premium API and 27B-class open models do not need it
for accuracy; the cluster profile uses it to trade a 27B reader for a 1B one at the same score.

### 6.2 Reading order on multi-column and mixed pages

Ranked by evidence for our material.

1. A detector's boxes plus a geometric ordering stage (column clustering on box centres). Tau 0.99 on 15 historical
   multi-column pages with CIs, era-invariant, negligible time (claim 14); Harvard's HDBSCAN version 0.959 micro tau
   on 723 newspaper scans in production (claim 27). XY-cut fails where full-width running heads bridge columns
   (claim 14) and on the glossa regime (claim 24). This is what the app's column sort approximates and it should be
   made explicit and measured.
2. PP-DocLayoutV3's coupled order head. Reading-order edit 0.042 on OmniDocBench v1.5 and the best figure on Real5
   skew among layout modules (claims 1-3); on our page it ordered column by column with a few neighbouring pairs
   swapped (claim 37). It costs nothing extra because the model is already a candidate detector. Its weakness is
   the training mix: no handwriting, no archival pages.
3. kraken blla's native order (tau 0.98 across 40 pages, 1.00 on the manuscripts; claim 13) and Orli (zero-shot
   0.997 on two sets, 0.288 on a tabular set; claim 17). These are line-level, trained on archival material, and
   the only orderers that have seen hands; they are slow (kraken 10-30 s a page on a Mac) and Orli's Mac run is
   unverified. They fit the handwritten kinds and the cluster.
4. The reader's own order (a VLM reading the whole page). Never isolated in any source; Real5's ROE for Gemini-3 Pro
   is 0.092 and Qwen3-VL-235B 0.091 under skew (claim 7), against 0.058 for a layout-first PaddleOCR-VL-1.6, so a
   large VLM orders a photographed modern page about as well as a pipeline does. On our L9 the 27B's `gap` is 0.017
   (claim 34). Adequate for the premium profile; unmeasured on annotated pages.
5. Text-based ordering (2607.01018): the only method that handles wrap-around and glossa layouts (94.8% edges where
   XY-cut gets 49.7%), but it loses to XY-cut on newspapers and costs 93 s a page on an A40 with no code (claim 24).
   A cluster-only check for pages the geometric stage flags as ambiguous, not a route.
6. LayoutReader: fails on historical pages, on multi-column OmniDocBench pages and on forms, in three independent
   measurements (claims 15, 24, 25). Dropped.

For mixed pages (body text with marginal notes, stamps, a signature block, a pasted clipping with its own order) the
right target is two streams, not one permutation: the body in reading order and the marks as labelled, positioned
items (claim 25; strand D §6.5). The ordering stage then runs on body regions only, and marks are excluded from the
order score. That also answers the screen's question 4: a permutation is the wrong target for an annotated page,
and the metric for the body stream is tau with a validity guard plus order-induced word error, both borrowed.

### 6.3 Layout regions as an input to the marks layer and to segmentation cues

Marks. Of the detectors we can run, only PP-DocLayoutV3 has a mark-like class (Seal), and it also has Header, Footer,
Aside Text, Header Image and Footer Image (claim 4); heron has Page-header, Page-footer, Form and Key-Value Region
(claim 22); DocLayout-YOLO has Title, Plain Text, Abandoned Text, Figure and captions (claim 23). None has a stamp,
signature or handwritten-annotation class, and none was trained on them. The field's class scheme for exactly these
is SegmOnto (MarginTextZone with note, commentary, correction, addition subtypes; StampZone; SealZone; DamageZone;
DigitizationArtefactZone; claim 33), and the dataset with the two classes we need on 20th-century print is
AnnoPage (Handwritten inscription, Stamp; strand D). The Codicology study's per-class figures set expectations: a
YOLO fine-tuned on historical zones finds stamps well (0.864) and marginalia badly (0.16-0.34) (claim 30), so a
marks detector will find stamps and signature blocks before it finds pencil notes. The practical design, which
strand D already proposes, is a second detector for marks beside the text-layout detector, or one detector
fine-tuned on both class sets; the text detector's Seal and Aside Text boxes are a free recall check for it, and its
Header, Footer and Title boxes tell the ordering stage what to leave out of the body stream.

Segmentation cues. Strand A found that visual layout features transfer worst across corpora ("document layouts
can be much more corpus-specific", A09) and that the owner's prompt cues (salutations, memo headings, bylines,
page numbers) are what the 2B student learned. A layout detector gives those cues a cheap, text-free form: a
Doc Title or Header region at the top of a page is a letterhead or memo heading; a Text block whose first line
Vision reads as a salutation marks a letter start; a handwritten mark region in the lower third of a typed page is
a signature block and a document end; a page whose only regions are Text with no title or header is a
continuation. No source measures region-class sequences as a page-stream segmentation feature. The test is cheap
(test 6): per-page region-class counts and positions from PP-DocLayoutV3 added to strand A's feature model on the
914 owner pages. The expectation from A09 is a small gain on the owner's typed boxes and none on Lincoln's
manuscripts.

### 6.4 Photographed-page benchmarks: which to borrow

Real5-OmniDocBench is the one to borrow for the capture effect: paired page-for-page with the digital annotations,
five conditions, twenty published rows, an Apache-2.0 image set and a public evaluator (claims 6-8). DocPTBench adds
the unwarping arm and 400 physical photographs of 100 originals (claim 29); borrow its design, not its data, until
its licence is stated. RealDoc-Bench from Extend is scanned and rendered regulated forms, not photographs, and its
value is the commercial comparison (claim 28). The DocEng photographed sets are binarisation competitions without
layout or order labels [?]. None of these has archival paper, handwriting, clippings or marks, so they measure
robustness, not our material; the archival anchor is the 40-page reading-order benchmark (MIT) plus our own 96 and
strand D's marks set.

### 6.5 Licences

Shippable in an app for other users: DocLayout-YOLO weights (Apache-2.0; the AGPL code is not shipped or run),
PP-DocLayoutV3 (Apache-2.0), heron weights (Apache-2.0) with Docling (MIT), kraken and Orli (Apache-2.0),
Nemotron-Parse (OpenMDW), granite-docling (Apache-2.0), Unlimited-OCR (MIT). Not shippable: Surya's layout weights
and surya_layout2 (the $5M employer revenue or funding cap and the non-compete clause bar a commercial archive or a
company, and the restrictions must be imposed on downstream users; personal and research use is exempt, so a
researcher may run it) and LayoutReader (research only). Measurement-only: OmniDocBench and Real5 annotations
(research only), DocPTBench and Wild-OmniDocBench (unstated). Data we may redistribute inside a kit: AnnoPage (CC BY
4.0), American Stories (CC-BY), the reading-order benchmark (MIT).

### 6.6 Mac runnability

Measured on the M3 Pro (18 GB): DocLayout-YOLO Core ML 0.51 s a page, 1,241 MB; PP-DocLayoutV3 MLX 0.47 s, 794 MB;
heron torch 0.41 s, 1,439 MB and a runtime the app does not ship (claim 36); Apple Vision document request 0.38 s
(claim 39); kraken blla about 30 s a page on one core (`specialists.md`), 10.6 s in the benchmark's CPU/MPS runs
(claim 13). Published: heron 0.044 s on an M3 Max GPU (claim 21); Surya's VLM 0.108 pages a second on Apple Silicon
through llama.cpp (claim 31), too slow for a layout stage. Unverified: Orli on MPS (bf16 only, claim 19). So every
memory tier runs a detector stage; the question for the 16 GB tier is the reader beside it, and the GLM-OCR
region route (1.4 GB at 8-bit) is the pairing the inventory and NewsBench both support.

## 7. Tests to run on our material, ranked

Every model or variant run on the 895 public pages is also run on the owner's 96 truth pages with the same
settings in the same item (owner, 2026-10-20). Prices are the measured ones in strand C ($0.0042 a page for Gemini
3.8 Flash on the 440). Detectors are free everywhere.

1. **Detector swap on photographs, reader fixed.** Profiles: all (it decides the shipped detector). DocLayout-YOLO
   with the app's column sort, PP-DocLayoutV3 with its own order, heron with column sort, and Apple Vision's
   document request, each feeding GLM-OCR; pages: the 96 (first), L9 and L4 of the 895, and Real5's illumination,
   warp and skew folders (3 x 1,355 images, 16 GB download). Score: NES and NewsBench `overall`, `bowF1`, `gap` on
   ours; the OmniDocBench evaluator (text edit, ROE) on Real5 so the result sits beside RT-DocLayout's Table 2.
   Settles whether DocLayout-YOLO's 48.74 on skew is real for our setup and whether it matters at our skew angles.
   Free on Sherlock or FarmShare; the Mac for the 96.
2. **Ordering stage with detection held fixed.** Profiles: all. On DocLayout-YOLO's boxes: app column sort, the
   benchmark's column clustering, Harvard's HDBSCAN rule, XY-cut, PP-DocLayoutV3's order, kraken blla native,
   Orli (cluster, bf16), and Gemini 3.8 Flash asked for boxes in order (paid arm). Pages: the 40 benchmark pages (a
   public anchor with ALTO order), our L9, and 30 owner pages with annotations drawn from strand D's marks set once
   labelled. Metric: tau with the validity guard and order-induced word error from `harness/score.py`, body stream
   only. Free except the Gemini arm (about 85 pages, under $0.50).
3. **Layout-first on ordinary pages, by kind.** Profiles: all. Whole page against regions, for GLM-OCR,
   LightOnOCR-3 4B, Qwen3.6-27B (cluster) and Gemini 3.8 Flash (paid), on the 96 split by kind (13 clippings, 12
   tables, typed single-column, handwritten) and on L3, L4 and L1 of the 895. Expected: no change on typed
   single-column pages, a loss on handwritten pages for the small readers, an unknown on clippings and tables.
   Decides the kind gate. Paid: 96 pages x 1 extra arm, about $0.40.
4. **Tiling control.** Profiles: laptop, cluster. The page cut into overlapping tiles with no detector, read by
   GLM-OCR and PaddleOCR-VL 1.5 on L9 and the clippings; against whole page and regions. Separates resolution from
   layout in the small readers' gain (screen question 2). Free.
5. **Handwriting harm check.** Profiles: laptop first. The four detectors on L1, L2 and the owner's handwritten
   pages: count text regions missed (Vision line boxes outside any text region) and regions labelled figure. The
   OmniDocBench notes figure predicts failure; the result sets the router's rule. Free, Mac.
6. **Region classes as segmentation and marks features.** Profiles: all; coding-agent kit. PP-DocLayoutV3's 25
   classes per page (counts, positions) added to strand A's feature model on the 914 owner pages; its Seal and
   Aside Text boxes scored for recall against strand D's marks labels as they arrive. Free, Mac.
7. **Joint layout-and-text models against the two-stage route.** Profiles: laptop (MLX), cluster. Nemotron-Parse
   2.0 and granite-docling-258M (MLX builds), Surya-2 (llama.cpp, measurement only), dots.ocr (MIT), on the 96, L9
   and L4: text score, ROE, seconds a page and memory on the Mac. Free.
8. **Our staged route through the Real5 evaluator, with strand D's dewarp as a pre-step.** Profile: cluster. Apple
   quad crop, optional UVDoc or DocRes, detector, GLM-OCR, on the Real5 warp and skew folders; compares our
   pipeline with twenty published rows and tells strand D whether dewarping helps the layout stage (DocPTBench says
   it recovers most of the photograph loss for pipelines). Free; shares the download with test 1.
9. **A user-trained ordering model as part of the kit.** Profile: coding agent, cluster. kraken `rotrain` and an
   Orli fine-tune on 20-50 owner-corrected PAGE XML pages from the marks set; measured on held-out pages with tau.
   Decides whether reading order belongs in the training kit. Free.
10. **Commercial layout spot check.** Profiles: commercial services. Azure Document Intelligence Layout and Textract
    Layout on 25 of the 96 (the clippings and tables), scored for regions and order with the same metrics; about
    $0.25 at the quoted $10 per 1,000 pages [?]. Only if the owner wants R6 populated with our own figures.

## 8. Open questions

- No source measures a layout stage on single-column typed or handwritten archival pages; tests 3 and 5 are the
  first such measurement anywhere that this reading found.
- Whether DocLayout-YOLO's Real5 collapse (claim 2) is the detector or the XY-cut post-processing the paper gave
  it; our column sort may behave differently. Test 1 answers it.
- Orli on Apple Silicon: bf16 only, and the README warns other precisions run away. Unverified.
- The postcards chapter's figures (the nearest published layout-first result on non-newspaper archival paper) are
  behind a paywall; only its abstract was read.
- American Stories' 2,202 labelled training scans: whether they are released with the dataset, which would give a
  CC-BY newspaper training set with the right classes.
- Whether PP-DocLayoutV3's Seal class fires on 20th-century rubber stamps, and whether any detector finds a pencil
  annotation on a typed page; no source has that figure, and strand D's marks set is the only route to it.
- Whether the 96's truth, a word sequence with line breaks dropped, can score order at all; NewsBench's `gap` needs
  the text in order, which it has, but region-level order needs boxes the truth does not carry.

## 9. Route table

| Route | Best candidate(s) for layout and order | Evidence | Licence on this route | Settling test |
|---|---|---|---|---|
| R1 Mac built-in (Vision, Core ML, Foundation Models) | Apple Vision `RecognizeDocumentsRequest` (paragraphs, tables, lists with regions; macOS 26) for regions; `DetectDocumentSegmentationRequest` for the page quad; DocLayout-YOLO as a Core ML package (72 MB) for a downloaded detector; Vision line boxes plus column clustering for order | Vision table request right on 134/144, forms 7/14 [M, claim 39]; DocLayout-YOLO Core ML 0.51 s a page [M, claim 36]; no layout or order accuracy measured for Vision's document request | Apple terms; DocLayout-YOLO weights Apache-2.0 | tests 1, 2 and 5 on the Mac; add Vision's document request as an arm |
| R2 Mac open weights, 16 GB | PP-DocLayoutV3 (MLX, 128 MB, 794 MB RSS) or DocLayout-YOLO, then GLM-OCR 8-bit (1.4 GB) on regions; granite-docling-258M (MLX) as the joint alternative | GLM-OCR regions 0.969-0.973 on L9 [M, claim 34]; detectors interchangeable on scans [M, claim 36]; granite-docling unmeasured | Apache-2.0 throughout | tests 1, 3, 7 |
| R2 Mac open weights, 32 GB | the same detector; readers LightOnOCR-3 4B or Qwen3-VL 8B 4-bit on regions for dense pages; Nemotron-Parse 2.0 (MLX, OpenMDW) as the joint alternative | LightOnOCR-3 4B whole-page L9 92.5 NES, 8B 85.3 [M, open sweep]; region gain for them unmeasured | Apache-2.0; OpenMDW-1.1 | tests 3, 4, 7 |
| R2 Mac open weights, 64 GB+ | Qwen3.6-27B 4-bit whole page, no layout stage needed for accuracy; detector optional for speed | Qwen3.6-27B whole 0.967 vs regions 0.965 [M, claim 34] | Apache-2.0 | test 3 confirms the no-gain on the 96 |
| R3 cheap API (OpenRouter) | detector on the Mac, then Gemini 3.5 Flash Lite, GLM-5.3 Flash or Qwen3.6-27B on regions; order from the detector stage, not the model | Flash Lite 0.820 whole to 0.961 regions; glm-5.3-flash-paddlex 0.916; qwen3.8-flash 0.341 to 0.907 [M, claim 34]; Qwen3-VL-235B Real5 skew 86.56 whole [M, claim 6] | Apache-2.0 detector; API terms | test 3's paid arm; test 2's Gemini arm |
| R4 premium API (Gemini, Claude, OpenAI, Mistral; batch) | whole page for Gemini 3.8 Flash and Claude Sonnet; detector first for Haiku-class and gpt-5.6-luna; order from the model on whole pages | Gemini-3 Pro Real5 scan 89.47 / skew 89.45, ROE 0.092 [M, claims 6-7]; Haiku 0.232 to 0.894, gpt-5.6-luna 0.503 to 0.921 [M, claim 34]; order on annotated pages unmeasured | API terms; detector Apache-2.0 | test 2 (Gemini boxes-in-order arm), test 3 |
| R5 subscriptions via a local agent CLI (Claude, ChatGPT plans) | as R4, whole page; the detector on the Mac if a plan model is Haiku-class | no plan-route layout figure; same models as R4 [I] | plan terms | test 3 through the plan route on the 96 |
| R6 commercial document services (Document AI, Azure, Textract, Extend, Transkribus) | none recommended; Extend v2 leads the one public layout track, Transkribus orders manuscripts and collapses on two-column print, PP-StructureV3 the reverse | RealDocBench adjusted F1 Extend 0.835, Textract 0.726, Azure 0.637 on scanned forms [M, claim 28]; Transkribus tau 1.00 / 0.51 [M, claim 15]; none measured on archival photographs; Document AI Layout Parser: no measurement found (search: "Document AI Layout Parser reading order"), price about $10 per 1,000 pages [?] | vendor terms; per-page fees | test 10 if wanted |
| R7 cluster (Sherlock design target, FarmShare) | PP-DocLayoutV3 or DocLayout-YOLO then GLM-OCR on regions (1,087 pages per GPU-hour, 0.969); kraken blla or Orli for line-level order on hands; Real5 and the 40-page benchmark as evaluators; research-licence data (OmniDocBench annotations) usable here | claims 34-35; Orli and kraken claims 13, 17; text-based ordering (93 s a page) as a check only | Apache-2.0 models; research-only annotations acceptable in a user's own kit | tests 1, 2, 4, 8, 9 |
| R8 hybrids (cascades, stages split across routes) | kind-gated layout stage: detector on the Mac for printed and mixed kinds, off for typed single-column and handwritten; body stream ordered geometrically, marks as a second stream (strand D); dense pages to a small reader on regions, hands to Gemini whole page; a loop on a region escalates the region, not the page | router 139/144 [M, kind-classifier]; region gain by reader size [M, claim 34]; notes mAP 9.54 [M, claim 9]; two-stream target [M, claim 25]; Falcon loop on a region [M, claim 38] | mixed; the shipped detector Apache-2.0 | tests 3, 5 and 6 together define the gate |
