# Strand K deep read: kind identification and mixed pages

Date 2026-10-21. Deep read for the processing review (`execution-plans/processing-review/00-plan.md`, Phase 1,
strand K). This strand had no screen, so section 0 is a short screen done here first (arXiv listing API, Semantic
Scholar until it rate-limited, Hugging Face model and dataset API, GitHub search API, vendor documentation, web
search), then the full reads. Tags: [M] measured in the source at the location given; [I] my inference from
measured figures; [?] not verified (abstract, snippet, a page I could not open). Our own figures cite the file under
`ArchiveProcessor/segbench-results/`, `ArchiveOCRBench/` or the sibling notes in this folder (C-ocr, D-enhancement,
E-layout, F-placement), which this note builds on and does not repeat.

Full reads: the ÚFAL ATRIUM page classifier (arXiv 2507.21114 v6, the HTML in three parts; the Hugging Face card
`ufal/vit-historical-page`; the GitHub README `ufal/atrium-page-classification`); Vafaie et al., *Handwritten and
Printed Text Identification in Historical Archival Documents* (ARCHIVING 2022, PDF, all six pages); Vafaie et al.,
*Improvements in Handwritten and Printed Text Separation in Historical Archival Documents* (2023, PDF, all six
pages); SignaTR6K (arXiv 2307.07887 v3, HTML, the results and dataset sections); the region-aware handwriting
descriptor paper (arXiv 2607.15936 v1, HTML, Tables 1-5 and the dataset section); Jo et al., *Handwritten Text
Segmentation via End-to-End Learning of CNN* (arXiv 1906.05229, HTML); the handwritten-forms VLM benchmark (arXiv
2604.16504 v1, HTML, Tables 2-3); the Azure Document Intelligence Read, Amazon Textract `Block` and Google Document
AI `Document` references; the kraken advanced-use page (5.2). Skims with figures taken: 1804.00236 (FCN marginalia),
1904.12387 (TMIXT), 2412.13859 (zero-shot RVL-CDIP), 2201.09575 (ICDAR 2021 historical document classification),
2404.19259 (DELINE8K), the NAF dataset README, the OCR-D typegroups classifier README, the Transkribus Text Titan II
post. Our own data: a fresh pass over `ocr-pages.csv` (29 routes x 96 pages, with each reader's own kind label and
Vision's kind) and `ArchiveOCRBench/difficulty.md` §5-6.

## 0. Screen

Twenty-nine candidates. Verdicts: READ (read in full here), SKIM (figures taken from the abstract or one table),
DROP (reason given). Searches that found nothing are named in section 8.

| # | Candidate | What it is | Verdict |
|---|---|---|---|
| 1 | ÚFAL ATRIUM page classification (2507.21114; `ufal/vit-historical-page`) | 11-class page classifier splitting handwritten, printed and typewritten text, 48,499 pages of 1920-2020 institute reports, MIT code, HF weights | READ |
| 2 | Vafaie et al. ARCHIVING 2022 (WGM-SYN, WGM-MOD) | Pixel separation of typewriting, print and handwriting on 1945-1960s German reparation files; synthetic crops from real pages; OCR effect measured | READ |
| 3 | Vafaie et al. 2023, *Improvements…* | Same group, three synthesis pipelines, IoU and OCR figures on 30 scans and 50 microfilms | READ |
| 4 | SignaTR6K (2307.07887, ICCV 2023 workshop) | Pixel separation with an overlap class on legal typescript; also scores WGM-SYN | READ (D note has its headline; this read adds the WGM-SYN result and access terms) |
| 5 | Region-aware handwriting descriptor (2607.15936, July 2026) | Lightweight sentence-level handwritten/printed classifier, two Chinese datasets | READ, then set aside: modern Chinese assignments, no code |
| 6 | Jo et al. 2019 (1906.05229) | End-to-end CNN removes handwriting from print; OCR before and after | READ: the one direct OCR-effect figure for handwriting over print |
| 7 | Handwritten-forms VLM benchmark (2604.16504, April 2026) | 17 VLMs on a printed form with handwritten entries; per-model accuracy, WER, CER | READ: the nearest published "one strong reader on a mixed page" figure |
| 8 | Azure DI Read v4.0, Textract `Block.TextType`, Document AI `StyleInfo.handwritten` | Per-line or per-token handwriting flags from the commercial services | READ (documentation) |
| 9 | kraken per-script model mapping | The one open mechanism that routes lines of one page to different recognisers | READ (documentation) |
| 10 | 1804.00236, FCN on handwritten annotations | 50 historic German pages, pencil marks, mean IoU 95.6; dataset released | SKIM |
| 11 | TMIXT (1904.12387) | Mixed pages transcribed without classifying first, about 80% on modified IAM | SKIM: Tesseract-era, no data |
| 12 | Zero-shot RVL-CDIP with LLMs and GPT-4V (2412.13859) | Genre classification (letter, memo, form, handwritten…) zero-shot | SKIM |
| 13 | ICDAR 2021 Historical Document Classification (2201.09575) | Font group, script, date classification on 70,000 pages | SKIM: print-era classes, no typewriter |
| 14 | OCR-D `ocrd_typegroups_classifier` | Per-page or per-region font-group classifier used to pick OCR models; Manuscript class in the line model | SKIM (README) |
| 15 | Transkribus Text Titan II | One model for print and handwriting; test set 81% handwriting | SKIM (vendor post) |
| 16 | AnnoPage (2503.22526) | Handwritten inscription and Stamp boxes on 7,550 pages, CC BY 4.0 | In D note; reused |
| 17 | OmniDocBench notes subset | Born-digital detectors fail on handwriting; VLMs do not | In E note; reused |
| 18 | NAF dataset (herobd) | 860 US National Archives form images with field boxes and partial transcriptions | SKIM |
| 19 | DELINE8K / NAFSS (2404.19259) | Synthetic handwriting-over-preprinted-form segmentation; real NAFSS benchmark | SKIM |
| 20 | TALLIP 2021 annotation spotting | 300 annotated scientific pages, underline/encirclement/inline/marginal classes | DROP: paywalled, access unknown [?] |
| 21 | HPSegNet (ICDAR 2024 workshops) | Handwritten/printed separation network | DROP: paywalled, the named GitHub repository is empty |
| 22 | PHD-AS, MAD-HPTS | Chinese assignment and synthetic datasets behind #5 | DROP: no URL, modern Chinese |
| 23 | 1303.4614 (Belaïd 2013), 1303.3087, 1408.2015 | Pre-deep-learning separation and annotation removal | DROP: superseded; 1408.2015's 89% removal on 50 pages noted |
| 24 | 2106.14989 Cascade R-CNN handwriting localisation | Boxes around handwriting on invoices for redaction, 10 fps | DROP: no data, no figures |
| 25 | French PDF-to-Markdown benchmark (2602.11960) | Has a handwritten-forms category; proprietary models more robust | DROP: no per-category figures on the abstract page |
| 26 | Hugging Face `handwriting detection` models (sanjit106 YOLOv8, Danny0602 YOLO11, borisloktev Qwen2.5-3B QLoRA) | Uncarded hobby detectors | DROP: no cards, no figures |
| 27 | Hugging Face `handwritten printed` search | One CRNN OCR model, no classifier | DROP |
| 28 | ICDAR 2025 competitions | No track on mixed handwritten and printed pages | DROP (recorded as a negative) |
| 29 | Postcards (Pélingre, Tabbone) | Hybrid detector plus VLM beats whole-postcard VLM | In E note, [?]; reused |

## 1. Question

Three questions. First, page kind: how well can a page be called typed, handwritten, printed, newspaper, form,
clipping or table before it is read, with what runs on each route, and how does our classifier (139 of 144 on the
hand, 13 of 14 forms) compare with the field and with what the readers say about the page themselves. Second, kind
changes between the pages of one document: whether per-page routing is right or a document should carry one kind.
Third, kind changes within a page (a typed letter with a handwritten postscript, a form with handwritten entries, a
page with marginal notes): whether to split the page into typed and handwritten regions, send each to the reader
that suits it, and reassemble the text in order. The settling question is whether one strong reader on the whole
mixed page is already good enough, so that region routing helps only the cheaper routes.

## 2. What the field does now

**Page kind is a solved classification problem on scans, and nobody has published it for phone photographs.** The
one recent system built for exactly our three-way hand distinction is the ÚFAL ATRIUM classifier: eleven classes,
of which six are text by hand (`TEXT_HW`, `TEXT_P`, `TEXT_T` for handwritten, printed and typewritten paragraphs,
`LINE_HW`, `LINE_P`, `LINE_T` for the same in tabular or form layouts) plus `TEXT` for a page mixing kinds, trained
on 48,499 pages from 37,328 archaeological-institute documents dated 1920-2020 [M, HF card; thesis §2]. Fine-tuned
CNNs and ViTs reach 99.1-99.2% top-1 (RegNetY-16GF 99.16 or 99.21, the two tables disagree; ViT-L/384 99.12; a
fine-tuned CLIP ViT-B/16 99.14), while zero-shot CLIP manages 35.7% mean and 50.1% at best, so the task is learned,
not prompted [M, Tables 3.3, 5.1]. The confusions are the ones we know: `TEXT` (mixed) against `TEXT_T`
(typewritten), with EfficientNet-S right on only 85% of `TEXT` pages and sending 13% to `TEXT_T`, and the best model
at 94% [M, §5.3.1]. On 1.28 million unlabelled pages the model is unsure (top-1 under 0.9) on 35-57% of
`LINE_HW` pages and 24-43% of `TEXT_HW` pages against 8-16% of printed pages [M, Table 5.5]: handwriting on forms is
where a page classifier hesitates. The ICDAR 2021 competition did the print-era version of the task (font group
98.48%, script 88.84%, dating MAE 21.9 years) [M, 2201.09575 abstract], and OCR-D ships a per-page or per-region font
group classifier whose line model has a Manuscript class, used to pick the recogniser [M, README]. Genre
classification (letter, memo, form, handwritten) zero-shot with a frontier VLM sits at 69.9% on RVL-CDIP's 16
classes [M, 2412.13859 Table 3]; it is not the route to kind.

**Within-page separation has moved from pixels to boxes, and the pixel results on real archival pages are weak.**
The pixel-separation line (Jo et al. 2019, FCN-light, WGM-MOD, SignaTR6K) trains on synthetic crops because nobody
has pixel truth for real pages. On modern synthetic data IoU is high (handwriting 97.8 [M, 1906.05229 Table I];
SignaTR6K mean 89.10 with printed 73.05 and handwritten 94.89 [M, Table 3]); on the one synthetic set built from real
20th-century archival typescript with handwriting (WGM-SYN) the best figures are mean IoU 0.50 for the FIZ model
(printed 0.42, handwritten 0.36, background 0.74) [M, ARCHIVING 2022 Table 1], 71% with cleaner synthesis
[M, 2023 Table 2] and 58.93% for SignaTR6K's four-class model [M, 2307.07887 §results]. Round stamps are read as
handwriting and framed stamps as print by all of them [M, 2022 Fig. 7; 2023 Fig. 5]. The lightweight 2026 descriptor
method is sentence-level classification on Chinese assignments (96.9% on its own set, 83.8% on camera-captured
PHD-AS, against an FCN at 98.3 and 91.5) with no code [M, 2607.15936 Tables 1-2]. Detection with boxes is what the
usable datasets give: AnnoPage's Handwritten inscription and Stamp classes (strand D), the 50-page AnnotationDB_1 of
pencil marginalia on historic German pages (mean IoU 95.6 for an FCN-8s) [M, 1804.00236 §results], NAF's 860 US
National Archives forms with field boxes [M, README], and DELINE8K's synthetic handwriting over preprinted forms
with a real NAFSS benchmark [M, 2404.19259 abstract].

**Separating helped the old OCR engines a lot; the VLM-era evidence is that one strong reader copes.** Removing
handwriting from one scribbled real document took OCR accuracy from 71.13% to 92.50% (engine unnamed)
[M, 1906.05229 Table II]. Reading only the separated printed layer of 30 reparation files with Transkribus's print
model gave flexible character accuracy 0.588 with the old separator and 0.723 with the FIZ one [M, 2022 Table 2],
and 0.800 on scans and 0.833 on microfilm with the 2023 pipelines against 0.723 and 0.644 [M, 2023 Table 2]. Those
are gains of a separation stage for a reader that cannot read handwriting. The VLM-era benchmarks do not separate:
17 VLMs read whole printed-plus-handwritten maternity forms, with Gemini 3.1 Pro and GPT 5.4 at 0.85 field accuracy
(WER 0.50, CER 0.31 for Gemini), Claude Sonnet 4.6 0.75, Haiku 4.5 0.65, GPT-5 mini 0.57 [M, 2604.16504 Tables 2-3];
TMIXT read mixed IAM pages "without the need to classify text in advance" at about 80% in 2018 [M, abstract];
Transkribus now trains one model for print and hands and tests it on 2,016 pages, 81% handwriting [M, blog];
Kiessling's PP-OCRv6 line model is trained on print (OCR-D) and hands (IAM and others) together (C-ocr claim 48).
No source read here isolates whole-page against region-routed reading of a mixed page with a current VLM. The
nearest proxies run the other way for pipelines: OmniDocBench's detectors see handwritten notes as figures
(DocLayout-YOLO mAP 9.54 on notes; MinerU text edit 0.984 against Qwen2-VL-72B's 0.168) (E-layout claims 9-10).

**The commercial services already give a per-line kind, and kraken gives the routing mechanism.** Azure Document
Intelligence Read returns a `styles` entry per text line with `isHandwritten` and a confidence [M, Read v4.0
"Handwritten style extraction"]; Textract returns `TextType` `HANDWRITING` or `PRINTED` on text blocks [M, `Block`
reference]; Document AI returns `styleInfo.handwritten` on each `Token` [M, `Document` reference]. kraken reads one
page with several recognisers by mapping a line's script tag to a model (`-m Grek:porson.mlmodel -m
Latn:antiqua.mlmodel`, with `default:` and `ignore`), but its default segmenter emits "a single line type and a
generic text region class", so the tags must come from a trained segmenter or from outside [M, kraken 5.2 advanced].
Nothing open does the same by hand (typed against handwritten) out of the box.

## 3. Claims table

| # | Source | Claim | Figure | Conditions | Tag | Location |
|---|---|---|---|---|---|---|
| 1 | ÚFAL ATRIUM 2507.21114 v6 | Page classes split hand three ways and form layouts from paragraphs | 11 classes: DRAW, DRAW_L, PHOTO, PHOTO_L, LINE_HW, LINE_P, LINE_T, TEXT_HW, TEXT_P, TEXT_T, TEXT (mixed) | 48,499 pages, 37,328 documents, 1920-2020, Czech archaeological reports, scans as PDF | M | §2, Table 2.1; HF card |
| 2 | same | Top-1 accuracy of fine-tuned models | RegNetY-16GF 99.21 (Table 3.3) / 99.16 (Table 5.1); ViT-L/384 99.12; ViT-B/384 98.92; EfficientNetV2-M 98.90; DiT-Base-RVL 98.72; random forest 75.34 | 38,625 train / 4,823 test per fold | M | Tables 3.3, 5.1 |
| 3 | same | Zero-shot CLIP fails; fine-tuned CLIP matches | zero-shot mean 35.69, best 50.08 (ViT-B/32); fine-tuned ViT-B/16 99.14 | 7 epochs | M | §5 CLIP |
| 4 | same | Mixed pages confuse with typewritten | EfficientNet-S TEXT 85% with 13% to TEXT_T; RegNetY-16GF TEXT 94%; DiT-Large TEXT 91% | | M | §5.3.1 |
| 5 | same | Handwriting on forms is where the classifier hesitates | top-1 under 0.9: LINE_HW 56.5% (Brno) / 35.2% (Prague); TEXT_HW 43.3 / 23.6; LINE_T 45.2 / 20.3; TEXT_T 24.6 / 21.5; TEXT_P 16.4 / 10.8; LINE_P 16.0 / 7.9; all pages 17.2 / 14.0 | 629,978 + 651,159 unlabelled pages | M | Table 5.5 |
| 6 | ÚFAL README, HF card | Sizes, licences, runtime | params 48-305M, 224-384 px, 213 MB-1.2 GB; code MIT; weights MIT; dataset "Public Domain" on the card, "CC BY-NC 4.0" in the README; CPU "slow", 2 GB at batch 4; no latency figure | transformers 4.x only for the timm models | M (licence conflict ?) | README; card |
| 7 | Vafaie ARCHIVING 2022 | The material and the synthetic set | 150 colour scans + 153 microfilm documents (hand-filled forms, typewritten certificates, testimonials); region crops 117 handwritten + 320 printed (microfilm), 202 + 447 (colour); 3,764 synthetic 256x256 crops, three labels | post-1945 Baden-Württemberg reparation files | M | §WGM-SYN |
| 8 | same | Pixel IoU on WGM-SYN test crops | WGM-MOD printed 0.42, handwritten 0.36, background 0.74, mean 0.50 (0.49 with CRF); FCN-light 0.24 / 0.26 / 0.72 / 0.41 | 429 test crops; FCN-8 variant, 294,952 params, 50 epochs | M | Table 1 |
| 9 | same | OCR on the separated printed layer | mean OCR (flexible character accuracy, Transkribus print model) FCN-light 0.588, +CRF 0.465, WGM-MOD 0.672, +CRF 0.723 | 30 real documents, truth by archivists | M | Table 2 |
| 10 | same | Stamps break the two-class scheme | round stamps read as handwriting, framed stamps as print | | M | Fig. 7 |
| 11 | Vafaie 2023 | Cleaner synthesis lifts IoU and OCR | mean IoU 50-52% (pipeline 1) to 69-71% (pipelines 2-3); OCR FCA on 30 scans 72.34 to 80.06 (bin2_ph), on 50 microfilms 64.37 to 83.25 (unbin_mf) | crop counts Table 1 (bin_mix 4,260; unbin_mix 3,280); Transkribus print 0.3, CER 1.60% on its validation | M | Tables 1-2 |
| 12 | SignaTR6K 2307.07887 v3 | Four-class separation with overlap; WGM-SYN result | SignaTR6K mean IoU 89.10 (PT 73.05, HT 94.89, BG 99.36) vs prior 83.02; WGM-SYN 58.93 vs 50.00; 24-30M params | 200 legal documents; data by form, licence unnamed; no code | M | results, dataset sections |
| 13 | Jo et al. 1906.05229 | Removing handwriting lifts OCR; synthetic training | OCR accuracy 71.13 to 92.50 on one real document; synthetic 146,391 patches from IAM + PRImA + 141 forms; H IoU 97.80 synthetic | engine unnamed; one document | M | Tables I-II |
| 14 | RHD 2607.15936 | Lightweight sentence-level classification | MAD-HPTS 96.9 (FCN 98.3), PHD-AS 83.8 (FCN 91.5); runtime 8.7 s vs 67.5 s | Chinese/English/Japanese printed sheets with added handwriting; 4,800 camera photos of Chinese assignments; no code | M | Tables 1-2 |
| 15 | Handwritten-forms VLM benchmark 2604.16504 | One strong reader on a printed-plus-handwritten form | field accuracy Gemini 3.1 Pro 0.85 (WER 0.50, CER 0.31, hallucination 0.08), GPT 5.4 0.85, Gemini 3.1 Flash Lite 0.84, Claude Sonnet 4.6 0.75, Opus 4.6 0.73, Haiku 4.5 0.65, GPT-5 mini 0.57 | 49 maternity records (46 for Claude); medical abbreviations; data not released | M | Tables 2-3 |
| 16 | TMIXT 1904.12387 | Mixed pages read without prior classification | about 80% transcription accuracy | modified IAM; 2018 tools | M | abstract |
| 17 | 1804.00236 | Pencil marginalia on historic pages are detectable at pixel level | mean IoU 95.6 (FCN-8s, Inception augmentation); 91.3 plain; DeepLab v2 89.2 | 40 train/val + 10 test pages from four German libraries; dataset at tc11 AnnotationDB_1 | M | §results |
| 18 | Azure DI Read v4.0 | Per-line handwriting flag | `styles[].isHandwritten` with `confidence`, spans to lines; supported handwritten languages only | | M | "Handwritten style extraction" |
| 19 | Textract `Block` | Per-block kind | `TextType` in {HANDWRITING, PRINTED} | | M | API reference |
| 20 | Document AI `Document` | Per-token kind | `Token.styleInfo.handwritten` (bool), with bold, italic, fontSize, fontType | processors returning it unstated | M | REST reference |
| 21 | kraken 5.2 | Per-type recognisers on one page | `-m Grek:porson.mlmodel -m Latn:antiqua.mlmodel`, `default:`, `ignore`; default segmenter emits one line type | tags are script, not hand | M | advanced.html |
| 22 | OCR-D typegroups classifier | Production per-region font classifier | DenseNet-121, 12 font groups (no manuscript); colwise line model adds Manuscript; Apache-2.0; archived 2024 | | M | README |
| 23 | ICDAR 2021 HDC (Brno) | Print-era page classification | font 98.48%, script 88.84%, location 79.69%, dating MAE 21.91 y | ~70,000 pages | M | 2201.09575 abstract |
| 24 | 2412.13859 | Zero-shot genre classification | GPT-4-Vision 69.9 ± 2.0 on RVL-CDIP-160x5; GPT-4 on OCR 61.8 | 16 classes incl. handwritten, form, letter, memo | M | Table 3 |
| 25 | Transkribus Text Titan II | One model for print and hands | about 47% CER reduction over Titan I; test 2,016 pages, 81% handwriting, 19% print; no mixed-page figure | vendor | M | blog 2026-06-25 |
| 26 | NAF dataset | US archival forms with field boxes | 708 / 75 / 77 images; printed-text transcriptions from Tesseract, train set barely corrected | | M | README |
| 27 | DELINE8K 2404.19259 | Synthetic handwriting over preprinted forms, real NAFSS benchmark | models trained on earlier sets "perform poorly" on NAFSS; data at github Tahlor/deline8k | licence unstated | M (figures ?) | abstract |
| 28 | `kind-classifier.md` (ours) | Our classifier, leave-one-folder-out | hand 139/144 (handwritten 33/34, typewritten 70/72, printed 34/35, mixed 0/3); forms 141/144, 13/14 found, 2 false; about 0.6 s a page; qwen3.5-4b 127/144, 2b 104/144 | 144 owner pages, 3 mixed | M | §1-2, §5 |
| 29 | same | What routing by kind is worth | routed by true labels 97.26; best single reader Claude Sonnet 5.5 96.47; our LR 96.26 (lost 1.00) | 96 truth pages, the guide's picks | M | §4 |
| 30 | `ocr-truth.md` | Mixed is rare and disputed in the truth draw | mixed 2 of 100 (226 words, 19% disputed) vs typewritten 2%, printed 3%, handwritten 9% | kind is Claude's label; mixed means no kind covers most of the page | M | drafts table |
| 31 | `ocr-pages.csv` (my pass) | The two mixed pages read whole | p009 (DEC Records, 1993, 160 words): 0.30-0.73 NES across 29 routes, best Gemma4 31B 0.732, Gemini 3.1 Pro 0.657, GPT-5.4 mini 0.622, Claude Sonnet 5.5 0.581, Gemini 3.8 Flash 0.549 with 267 words out; p031 (URI admissions, 50 words): 0.95-0.99 for 19 of 29 routes, Gemini 3.8 Flash 0.993, Apple Vision 0.892, LightOnOCR-3 4B 0.806 | Vision called p009 "photograph" | M | rows for p009, p031 |
| 32 | same | The readers' own kind label against the truth label | agree: Qwen3-VL 235B 94/96, Claude Sonnet 5.5 92/96, Mistral Medium 3.5 90/96, Gemini 3.1 Pro 89/94, Gemini 3.8 Flash 87/94, Qwen3.6 27B 86/95, GPT-5.4 mini 81/95, Gemini 3.5 Flash Lite 77/94, Qwen3-VL 8B 75/94, GPT-5.6 luna 69/95, Qwen3-VL 30B-A3B 64/94; pooled: handwritten pages called mixed 65 of 392, typewritten called mixed 75 of 1,226, printed called typewritten 111 of 673; the 2 mixed pages called mixed 27, handwritten 17, typewritten 4 of 48 labels | prompt asks one KIND per page, "mixed when no one kind covers most of it" | M | `said_kind` column |
| 33 | `difficulty.md` §5-6 | Self-labels as a routing signal | readers say handwritten on 7-16 of the 16 handwritten pages, right 90-100% when they do; as a flag for a poor reading AUC 0.57-0.70 (readers' label), 0.51-0.68 (Vision's handwriting call); routing by the hard-kind label vs failure alone +0.45 / -0.55 / +0.18 / -0.85 NES at $0.5 / $1 / $2 / $5 per 1,000: no reliable gain | 96 pages, half chosen half scored | M | §5, §6 |
| 34 | `difficulty.md` §5 | Mixed pages are about 8% of the real corpus by the reader's own label | Qwen3.6 27B on 2,000 random corpus pages: typewritten 1,202, printed 487, mixed 167 (8.4%), handwritten 144; failure rate by kind 0.4-1.2% | no truth | M | bulk pilot table |
| 35 | `bench-corpus/README.md`, `open-sweep-20261019.md` | The public set holds a mixed stratum at scale | L4 ledgers and forms (Freedmen's Bureau registers: printed headings, handwritten entries) 80 pages: open routes 28.2-70.0 NES (Qwen3.5 27B 70.0, Qwen3.6 27B 69.3, GLM-OCR 59.7, LightOnOCR-3 4B 55.0, PP-OCRv6 44.5, PaddleOCR-VL 28.2); L3 typescripts 89.7-96.0; L1 hands 46.0-88.4 | no hosted route on L4 yet (paid hold) | M | stratum table |
| 36 | `ocr-page-guidance.json` | By-kind picks the router sends to | handwritten Gemini 3.8 Flash 96.0; typewritten Gemini 3.8 Flash 98.7; printed Claude Sonnet 5.5 96.3 / Qwen3.6 27B 94.8; forms Qwen3.6 27B 96.2 (4 pages) | 96 pages | M | file |
| 37 | F-placement §5 | Apple Vision on handwriting | finds about 78% of handwritten lines and 82% of words, 561 missed per 1,000 words | HW-COVERAGE | M | F note |
| 38 | C-ocr §5 | Mac handwriting reader | LightOnOCR-3 4B 8-bit 89.67 NES on the 16 handwritten pages; Gemini 3.8 Flash 95.97, Claude 92.43, Qwen3.6 27B 92.15 | `ocr-mac-local-hw.md`, `difficulty.md` | M | C note |

## 4. Code, weights, data and licences

| Item | Code | Weights or data | Licence | Mac-runnable | Cluster needs |
|---|---|---|---|---|---|
| ÚFAL ATRIUM classifier | github ufal/atrium-page-classification, MIT | HF `ufal/vit-historical-page` (EfficientNetV2-S/M, ViT-B 224/384, RegNetY-16GF, ViT-L/384; 213 MB-1.2 GB) | code and weights MIT [M]; dataset Public Domain (card) or CC BY-NC 4.0 (README) [?], LINDAT handle 20.500.12800/1-6184 (unreachable 2026-10-21) | yes: torch CPU or MPS, 48-87M params at 224-384 px; the README calls CPU slow but gives no figure; a 87M ViT at 384 px is of the order of our detectors (0.4-0.5 s a page) [I] | none; a fine-tune on our pages is minutes on one GPU [I] |
| WGM-SYN and WGM-MOD (FIZ) | github ISE-FIZKarlsruhe/Wiedergutmachung, MIT | `wgm_mixed.h5`, WGM-SYN train/test crops in the repository [M README]; real pages not released | MIT [M] | yes: Keras FCN-8 of 295K params | none |
| SignaTR6K | none | 6,257 crops by request form | licence unnamed [M] | n/a | n/a |
| AnnotationDB_1 (1804.00236) | none | tc11.cvc.uab.es/datasets/AnnotationDB_1: 50 pages, PAGE and PNG | unstated [M] | data only | none |
| AnnoPage, SignverOD, tech4humans signature detector | strand D | strand D | CC BY 4.0; CC0; AGPL-3.0 weights | strand D | strand D |
| NAF dataset | github herobd/NAF_dataset | 860 form images, boxes, partial transcriptions | not stated on the README read [?] | data | none |
| DELINE8K / NAFSS | github Tahlor/deline8k | synthetic set and real benchmark | unstated [M] | data | none |
| kraken (per-script model mapping) | Apache-2.0 | Zenodo models; Kiessling PP-OCRv6 medium (print and hands) | Apache-2.0 | yes, CPU (C note: about 9 s a page reading, 30 s blla) | none |
| OCR-D typegroups classifier | Apache-2.0, archived | `densenet121.tgc`, `colwise_classifier.tgc` | Apache-2.0 | torch CPU | none |
| Azure DI Read, Textract, Document AI | vendor | per-line or per-token handwriting flags | vendor terms; Azure Read is about $1.50 per 1,000 pages at list [?] | API | none |
| Our classifier (`kind-classifier-model.json`, `PageKindClassifier.swift`) | in the app | Apple Vision signals, feature print, two logistic regressions | ours | yes, about 0.6 s a page, macOS 26 | none |
| Vision OCR lab sorter (`Recogniser.pageKind`) | lab | none | ours | yes, about 4.3 s a page | none |

## 5. Comparison with what we measured

**Page kind.** Our classifier and the field agree on what is easy and what is hard. Ours is right on 139 of 144
owner pages for the hand, with one handwritten page called typewritten and the three mixed pages all wrong
(claim 28); ATRIUM's 99% comes with the same confusion, mixed against typewritten (claim 4), and the same
hesitation on handwriting in form layouts (claim 5). The difference is scale and evidence: ATRIUM is trained on
48,499 labelled pages of 20th-century institute paperwork with a held-out test of 4,823, ours on 144 pages from
one corpus, fitted and scored leave-one-folder-out, with 14 forms and 3 mixed pages. ATRIUM also carries two
things ours lacks: a `TEXT` class for mixed pages and `LINE_*` classes that split form layouts by hand, which our
forms regression does not. What ATRIUM lacks is our capture: it was trained on scans in PDF, and no published page
classifier has been run on phone photographs of boxes. Our Vision-signal model has seen only photographs. The
cross-corpus test (test 1) is cheap and settles whether to replace, combine or keep.

**What a kind label is worth** depends on the route, and our measurement says so plainly: on the 96, routing by the
true labels reads 97.26 against 96.47 for the best single reader (claim 29), so at the premium tier the whole value
of page-kind routing is under a point. The guide's by-kind picks differ by 2-3 points between the top readers
(claim 36), and the Mac and cheap routes differ by far more on handwriting (Vision misses a fifth of handwritten
lines, claim 37; LightOnOCR-3 4B 89.67 against Gemini 95.97, claim 38). So kind routing is a cheap-route feature,
which is what the settling question anticipated.

**What the readers say about the page themselves** is measured here for the first time against the truth label:
the strong readers agree with it on 87-94 of the 93-96 pages they labelled, the small and cheap ones on 64-83
(claim 32). The errors are systematic: handwritten pages called mixed (17% of such labels), typewritten called mixed (6%), printed called
typewritten (16%). As a routing signal the label gives no reliable gain over escalating on failure alone
(claim 33), and it arrives after the page has been read, so it cannot choose the reader; it can only trigger a
second read. The field has no comparable measurement; Transkribus and the VLM benchmarks never ask the model what
it saw. ATRIUM's finding that zero-shot CLIP cannot classify pages (claim 3) is consistent with the weak labels of
the small VLMs.

**How common mixed pages are** depends on the definition, and our two definitions disagree by a factor of four. The
truth draw's "mixed when no one kind covers most of the page" gave 2 of 100 and the classifier draw 3 of 144
(claims 28, 30); Qwen3.6 27B's own label on 2,000 random corpus pages gave 167 mixed, 8.4% (claim 34), which reads
as "any page with both kinds". The second definition is the one that matters for a text layer that must carry the
postscript and the marginal note. The field's prevalence figures are of the same shape: 9.84% of the modern
documents behind FCN-light had overlapping text [M, 2023 §related work, citing Dutly et al.]; ATRIUM's `TEXT` class
exists because mixed pages were common enough to need it. Strand D's planned 150-page marks set, drawn by VLM
pre-flag rather than at random, is the right instrument, and test 2 fixes the definition before it is drawn.

**Within-page separation.** The pixel methods were built for 20th-century typescript with handwriting, on material
very like ours (hand-filled forms, typewritten certificates, reparation files), and they do not work well enough
there: mean IoU 0.50-0.71 on synthetic crops of the real pages, stamps misread (claims 8, 10, 11). The one
pixel-level set that reaches 0.89 is modern legal typescript (claim 12). Strand D already chose boxes over pixels
for marks; this read confirms it for kind regions too, and adds that the per-line flag is the field's practical
unit: Azure, Textract and Document AI all return it (claims 18-20), and kraken's per-script mapping is the open
mechanism for sending lines to different recognisers (claim 21). Our own free per-line signal exists: the
ink-periodicity measure that separates typewriting from print in `kind-signals.swift` is computed over Vision's
lines, and per line it is a typewriter detector (test 4) [I].

**The settling question, as far as the evidence goes.** For the premium and subscription routes one strong reader
on the whole page is adequate on everything measured: Gemini 3.8 Flash reads our handwritten pages at 96.0 and
typewritten at 98.7 (claim 36); the easy mixed page p031 reads at 0.99 (claim 31); on a hard printed-plus-handwritten
medical form the frontier readers reach 0.85 field accuracy where Haiku and GPT-5 mini fall to 0.65 and 0.57
(claim 15), which is a reader-strength gap, not a layout gap. The hard mixed page p009 is hard for every reader
(0.30-0.73) and several emit far more words than the truth holds (claim 31); one page cannot say whether regions
would help it, but it is the page to try. For the Mac and cheap routes the case for region routing is the old OCR
case restated with current numbers: the printed layer read alone gained 0.13-0.19 FCA for a print-only reader
(claims 9, 11); OCR went from 71 to 93 when handwriting was removed (claim 13); Vision loses a fifth of handwritten
lines (claim 37); the open routes read L4's printed-plus-handwritten registers at 28-70 (claim 35). A typed letter
with a handwritten postscript read by Vision or PP-OCRv6 loses the postscript; sending the postscript's box to
Gemini or LightOnOCR-3 recovers it for one small call. That is the design the cheaper routes need, and it is
exactly strand D's marks pipeline (detect boxes, crop, read each with the handwriting reader, place and label) with
one more class, so the two should be built once (E-layout §6.2's two streams).

**Kind changes between pages.** The app already routes page by page: the file list classifies each image and a page
under 0.8 confidence keeps the run's model [M, `ArchiveProcessor/CLAUDE.md`, W41.app-page-kind]. Nothing is
measured about how often kind changes inside a document, because the kind sets were drawn one page per document.
The field's page-stream work uses sequence models to find document boundaries (strand A) and treats page type as a
boundary cue, not the reverse; no source read here smooths per-page kind over a document (search in §8). The owner
corpus has the data to measure it: the five segmentation boxes (914 pages with document truth) run through the
classifier give the churn rate and the confidence of the pages that churn, for nothing (test 5). The design the
evidence supports is a document prior used only below the confidence floor [I].

**Where a public benchmark makes ours less necessary, and what to borrow.**

- ATRIUM: borrow the model as a second opinion on every page we have (144, 96, 895, 2,000 bulk-pilot pages), and
  its eleven-class scheme as the vocabulary for our labels (`TEXT` for mixed, `LINE_*` for forms by hand). Its
  dataset is measurement-only until the licence conflict is resolved. It does not replace our test because it has
  no photographs.
- WGM-SYN's synthesis pipeline (MIT): borrow it to make typed-plus-handwritten crops from our own pages for a
  region or line classifier; do not borrow its model (IoU 0.50).
- SignaTR6K: request it only if a pixel route is ever revived; not now.
- AnnotationDB_1 (50 pages, pencil marginalia on historic print) and AnnoPage (strand D): the public anchors for
  mark boxes on print; NAF and NAFSS for US forms with handwritten entries, the nearest public analogue of L4.
- The commercial per-line flags: Azure's `isHandwritten` with confidence is a cheap way to draft per-line kind truth
  for the marks set (about $0.08 for 50 pages at list [?]), checked by the owner, rather than drawing it by hand.
- The handwritten-forms benchmark's metric split (field accuracy, WER/CER on free text, hallucination rate) is the
  right scorer for L4 and for mixed pages: body text and entered text scored apart.
- Not worth borrowing: the Chinese assignment sets (modern, no URL), RVL-CDIP for kind (genre, scans), TMIXT.

## 6. Strand-specific questions

### 6.1 Page kind against our classifier and the readers' own labels, by route

Ranked by evidence for our pages.

1. Our Vision-signal and feature-print regressions (R1): 139/144 hand, 13/14 forms, 0.6 s a page, no download,
   leave-one-folder-out; wrong on all 3 mixed pages, no clipping or newspaper class (claim 28). The default until
   test 1 says otherwise.
2. ATRIUM (R2, R7): 99.1-99.2% on 4,823 held-out scans of 20th-century paperwork, with mixed and form-by-hand
   classes; unmeasured on photographs; 87M params runs on any Mac tier (claims 1-6).
3. The Vision OCR lab's sorter (R1): newspaper, photograph, handwriting, other; 14 of 16 handwritten pages found,
   1 false, 4 s a page; nothing on typewritten against printed (`difficulty.md` §6).
4. A small VLM asked two words (R2): qwen3.5-4b 127/144, 2b 104/144, 1.3-2.2 s a page, weak on typewritten against
   printed (claim 28).
5. The reader's own label (R3-R5): 87-94/96 for strong readers, 64-83 for cheap ones, after the page is read; no
   routing gain measured (claims 32-33). Useful as a second-read trigger and as a label to store, not as a router.
6. The commercial services (R6): per-line handwriting flags, a kind per page by aggregation; unmeasured on our
   pages; priced per page.

For clippings and newspapers the kind comes from layout, not hand: the lab's sorter has a newspaper class, ATRIUM
has none, and E-layout's detector classes (American Stories' headline, article, byline) are the right vocabulary.
For tables and forms, Vision's document request finds 7 of 14 owner forms and our regression 13 of 14 (claim 28);
ATRIUM's `LINE_*` classes are the field's version and split the form by hand, which decides the reader.

### 6.2 Kind changes between the pages of one document

Per-page routing is what the app does, and the field gives no reason to change it. The open question is the
confidence floor: a page under 0.8 keeps the run's model, which is right when the run's model is strong and wrong
when the run's model is Vision and the page is a handwritten enclosure in a typed letter. A document prior (the
kind of the surrounding pages, after segmentation) is the natural fallback for those pages, and its value is
bounded by the churn rate test 5 measures. On the owner's boxes most documents are typed letters and memos with
occasional handwritten pages (the corpus is 60% typewritten by the reader's label, claim 34), so churn is expected
to be low and concentrated at enclosures [I].

### 6.3 Kind changes within a page: split, route, reassemble

The design the evidence supports, by route:

- Detect, do not segment pixels. Boxes from a detector fine-tuned on AnnoPage's Handwritten inscription and Stamp
  classes plus synthetic typed-plus-handwritten crops (WGM-SYN's recipe on our pages), or per-line flags from
  Vision lines plus the ink-periodicity and feature-print signals (R1), or the service's own flags (R6). Pixel
  separation on this material reaches IoU 0.50-0.71 and misreads stamps (claims 8, 10-12).
- Route by region kind: typed and printed regions to the route's print reader (Vision, PP-OCRv6, GLM-OCR, or the
  whole-page VLM), handwritten regions to the handwriting pick (Gemini 3.8 Flash; LightOnOCR-3 4B on the Mac);
  stamps to the marks reader; signatures detected and labelled (D §6.5). kraken's per-type mapping is the pattern
  for the specialist lane once the segmenter emits a hand tag (claim 21).
- Reassemble as two streams, not one permutation: the body in reading order from the geometric ordering stage, the
  handwritten regions placed at their boxes and labelled (E §6.2, F §6.3-6.4). Score the body with NES and the
  order metrics, the regions with D's marks metric and the forms benchmark's field split (claim 15).
- For R4 and R5 the whole page stays the default and the detector runs only to label and place marks (D), because
  the measured gain of kind routing at that tier is under a point (claim 29) and the frontier readers hold mixed
  forms at 0.85 where cheap ones fall to 0.57-0.65 (claim 15).

### 6.4 The settling question

One strong reader on the whole mixed page is good enough for the premium and subscription routes on every
measurement available (claims 15, 29, 31 for p031, 36), with one unresolved hard page (p009) and one unmeasured
property: whether the whole-page reader transcribes and labels the handwritten annotation as an annotation, which
is strand D's marks test, not an accuracy question. For the Mac, the cheap API and the specialist lanes, region
routing is where the gain is, and the gain is large wherever a print-only or print-weak reader meets handwriting
(claims 9, 11, 13, 35, 37). So: build the region pipeline once, for marks and for kind, gated by route, and test
whether it also rescues pages like p009 at the premium tier.

## 7. Tests to run on our material, ranked

Every model or variant run on the 895 public pages is also run on the owner's 96 truth pages with the same settings
in the same item (owner, 2026-10-20). Prices use the bench's measured $0.0042 a page for Gemini 3.8 Flash
(`bench-corpus/README.md`). Classifiers and detectors are free on every route.

1. **ATRIUM against our classifier, cross-corpus.** Profiles: all (it decides the app's classifier). Run
   `ufal/vit-historical-page` (ViT-B/384 and RegNetY-16GF) zero-shot on the 144 labelled owner pages, the 96, the
   895 (kind truth from the strata: L1-L2 and L5-L7 handwritten, L3 typewritten, L4 forms as `LINE_*`, L8-L9 and
   N5-N6 printed) and the 2,000 bulk-pilot pages (Qwen3.6 27B's labels, no truth). Map its classes to ours; report
   hand accuracy, form recall, the `TEXT` class against our mixed pages, confidence distributions by kind (its
   Table 5.5 pattern), seconds a page and memory on the M3 Pro. Then fit a small head on its embeddings with our
   144 pages, leave-one-folder-out, against our 139/144. Free, Mac; the 2,895-page pass on Sherlock or FarmShare if
   the Mac is slow.
2. **Fix the mixed-page definition and measure prevalence.** Profiles: all. On the 2,000 bulk-pilot pages, four
   labels per page: our regression, the lab's sorter, ATRIUM, and Qwen3.6 27B's existing label; owner adjudication
   of 100 pages where they disagree plus 50 where all say mixed. Defines "mixed" for strand D's marks draw (any
   handwritten region of N or more words on a typed or printed page) and gives its corpus share. Free, Mac; about
   an hour of owner review.
3. **Whole page against region-routed reading on mixed pages.** Profiles: all; the decisive test for the settling
   question. Set: strand D's 150-page marks set once labelled, L4's 80 registers, the L3 typescripts that carry
   annotations (By the People's images; count by detector), p009 and p031. Arms: whole page by Gemini 3.8 Flash,
   Qwen3.6 27B, LightOnOCR-3 4B, GLM-OCR, Apple Vision; region-routed with the same readers on typed regions and
   Gemini 3.8 Flash or LightOnOCR-3 4B on handwritten regions, boxes from the detector of test 6 (until it exists,
   from the owner's labels as an oracle). Score body NES, D's marks transcription rate, E's order metrics, and the
   forms benchmark's field split on L4. Free on the cluster for the open readers; paid arm about 310 pages x 1.3
   calls x $0.0042, about $1.70 in all, under the $3 rule.
4. **Per-line kind from free signals.** Profiles: laptop first. Vision line boxes with per-line ink periodicity and
   a per-line feature print, fitted on the marks set's line labels, against Azure Read's `isHandwritten` per line
   on 50 of the same pages (about $0.08 at list [?]) and against the owner's labels. Decides whether the Mac can
   route lines without a detector download. Free apart from Azure.
5. **Kind churn inside documents.** Profiles: all. Our classifier over the 914 segmentation pages with their
   document truth: how many documents hold more than one kind, where the change falls (enclosures, last pages), and
   the confidence of the pages that change. Decides whether a document prior is worth building under the 0.8 floor.
   Free, Mac, an hour.
6. **One detector for marks and kind regions.** Profiles: all; coding-agent kit. YOLO11m fine-tuned on AnnoPage
   (Handwritten inscription, Stamp), SignverOD (signature, initials, redaction, date) and synthetic typed-plus-
   handwritten crops made from our own pages by WGM-SYN's recipe (MIT), with a Core ML export; evaluated on the
   marks set for box recall by class, with PP-DocLayoutV3's Seal and Aside Text boxes as a free comparison (E test
   6). This is strand D's test 6.5 with one more class; file it once. Free on Sherlock; AnnoPage is 5 GB.
7. **Inline region tags from the whole-page reader.** Profiles: premium, subscription. Change the prompt from one
   KIND per page to inline tags per passage ("[handwritten] ... [/handwritten]", stamps likewise) for Gemini 3.8
   Flash and Claude Sonnet 5.5 on the marks set and the 96; score tag spans against the labelled boxes and check
   body NES does not move. Decides whether R4 and R5 can supply the second stream without a detector. Paid: about
   250 pages x 2 readers, about $1.05 for Gemini plus the Claude plan route at $0.
8. **L4 three ways.** Profiles: all. Whole page, table-region crops (E test 3) and per-cell crops for GLM-OCR,
   Qwen3.6 27B and Gemini 3.8 Flash on L4 and the 12 tables in the 96, scored with the forms benchmark's split
   (printed headings against handwritten entries). Paid: 92 pages, about $0.40.

## 8. Open questions

- ATRIUM's dataset licence: the Hugging Face card says Public Domain, the README says CC BY-NC 4.0, and the LINDAT
  record did not load. The weights are MIT either way; the data is measurement-only until the record is read.
- No published page classifier has been run on phone photographs, and no published pixel or region separator has
  been run on them either; every figure above is on scans or microfilm.
- Whether p009's failure is a mixed-page failure or a photograph-of-a-photograph failure (Vision called it a
  photograph, and several readers emitted 136-270 words for 160): one page, to be opened and read before test 3.
- Document-level smoothing of per-page kind: nothing found (searches: "document-level smoothing per-page
  classification multi-page consistency", "page type sequence model archival scans"; the hits were page-stream
  segmentation, strand A). Test 5 is the first measurement.
- A mixed-page track in the competitions: none at ICDAR 2025 (the competitions page and the HTR, notes, Indic and
  FEST tracks were checked); the French PDF-to-Markdown benchmark has a handwritten-forms category with no public
  per-model figures on its abstract page.
- Whether Apple's `RecognizeDocumentsRequest` exposes any handwriting attribute: none found in the WWDC25 session,
  the `DocumentObservation` reference or three third-party write-ups; the lab's sorter infers it from ink shape.
- SignaTR6K's access terms (a form, no licence) and whether its overlap class would transfer to pencil over
  typescript; not pursued because boxes won.
- The handwritten-forms benchmark's data is unreleased, so its metric split is borrowed and its pages are not.

## 9. Route table

| Route | Best candidate(s) for kind and mixed pages | Evidence | Licence on this route | Settling test |
|---|---|---|---|---|
| R1 Mac built-in (Vision, Core ML, Foundation Models) | Our Vision-signal + feature-print regressions for page kind (shipped, off by default); per-line kind from Vision line boxes with ink periodicity and feature print; the lab's sorter for newspaper/handwriting; no handwriting attribute in Vision's own API found | 139/144 hand, 13/14 forms, 0.6 s a page [M, claim 28]; Vision finds 78% of handwritten lines [M, claim 37]; per-line signals unmeasured | Apple terms; ours | tests 1, 4, 5 |
| R2 Mac open weights, 16 GB | ATRIUM ViT-B/384 or RegNetY-16GF (87M, 345 MB) for page kind beside ours; a Core ML YOLO11 marks-and-kind detector (test 6); readers by region: GLM-OCR 8-bit on typed regions, LightOnOCR-3 4B on handwritten regions | ATRIUM 99.1% on scans [M, claim 2], unmeasured on photos; LightOnOCR-3 4B 89.67 on handwritten pages [M, claim 38]; GLM-OCR 59.7 on L4 whole [M, claim 35] | MIT weights; Apache-2.0 readers | tests 1, 3, 6 |
| R2 Mac open weights, 32-64 GB+ | the same classifier and detector; Qwen3.6 27B whole page for typed and mixed pages, handwritten regions to it as well or to Gemini if a key exists | Qwen3.6 27B 92.15 on handwritten pages, 69.3 on L4 [M, claims 35, 38]; its own kind label 86/95 [M, claim 32] | Apache-2.0 | test 3 |
| R3 cheap API (OpenRouter) | kind from the Mac (R1 or ATRIUM), not from the model; typed regions to the cheap model, handwritten regions to Gemini 3.8 Flash; the model's own label kept as a second-read trigger only | cheap readers' labels 64-83/96 [M, claim 32]; label routing no gain [M, claim 33]; Qwen3-VL 235B leads Gemini by nothing on the 96 but trails 18.7 on the 440 [M, bench README] | Apache-2.0 classifier; API terms | tests 3, 7 |
| R4 premium API (Gemini, Claude, OpenAI, Mistral; batch) | whole page; the detector runs for marks and placement only; inline region tags in the prompt (test 7) as the second stream | routing by true kind +0.8 over the best single reader [M, claim 29]; mixed form 0.85 field accuracy for Gemini 3.1 Pro and GPT 5.4 [M, claim 15]; p031 0.99, p009 0.55-0.66 [M, claim 31] | API terms | tests 3 (paid arm), 7 |
| R5 subscriptions via a local agent CLI | as R4 at $0 per call; Claude Sonnet 5.5's own label is the most accurate among the paid readers (92/96) | [M, claim 32]; no plan-route figure for mixed pages [I] | plan terms | test 7 through the Claude plan |
| R6 commercial document services | Azure DI Read for per-line `isHandwritten` with confidence (also a searchable PDF at no extra cost); Textract `TextType`; Document AI `styleInfo.handwritten`; Transkribus Text Titan II as one model for both with no mixed-page figure | [M, claims 18-20, 25]; none measured on our pages; Azure about $1.50 per 1,000 pages at list [?] | vendor terms | test 4 (50 pages, about $0.08) |
| R7 cluster (Sherlock design target, FarmShare) | ATRIUM over the 895 and the 2,000; the YOLO11 marks-and-kind detector trained on AnnoPage + SignverOD + WGM-recipe synthetic crops; kraken per-type mapping with a hand-tagging segmenter for the specialist lane | AnnoPage YOLO11m mAP50 0.658 (D note); kraken mapping [M, claim 21]; WGM-SYN recipe MIT [M] | MIT, Apache-2.0, CC BY 4.0, CC0 | tests 1, 3, 6 |
| R8 hybrids (cascades, stage splits) | kind on the Mac, reader by kind per route; one detector for marks and kind regions; regions routed only on R1-R3 and the specialist lane, whole page on R4-R5 with inline tags; a document prior only under the 0.8 confidence floor; the reader's own label as a second-read trigger | claims 29, 33, 35, 37 together; two-stream target (E §6.2) | mixed; the shipped detector Apache-2.0 or MIT | tests 3, 5, 6 define the gate |
