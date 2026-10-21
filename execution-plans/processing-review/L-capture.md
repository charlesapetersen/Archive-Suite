# Strand L deep read: phone capture in imperfect conditions

Date 2026-10-21. Deep read for the processing review (`execution-plans/processing-review/00-plan.md`, Phase 1,
strand L). This strand had no screen, so section 0 is a brief screen done here. Tags: [M] measured or stated in the
source at the location given; [I] my inference from measured figures; [?] not verified (abstract, search snippet,
vendor page, or a part of a source I could not read). "Computed here" means a figure I derived from our own files
with `ArchiveProcessor/scripts/segbench/capture_attrs.py`, reading the private page table and `segbench-results/ocr-pages.csv`.

Built on, not repeated: `D-enhancement.md` (dewarping backward maps, DocRes/GCDRNet, PreP-OCR's VLM-barely-gains
finding, invented-text metric, AnyPhotoDoc6300, RealDAE); `E-layout.md` (Real5's pipeline collapse, RT-DocLayout's
module swap on skew, DocPTBench's unwarping arm); `C-ocr.md` (resolution ladder reading, loops as a difficulty
signal); `F-placement.md` (HW-COVERAGE p094, straight runs on curved lines). Where this note cites a figure from one
of those, the tag is the note's.

Full reads (eight): PureDocBench (arXiv 2605.07492v2, HTML main text; appendices absent from the HTML); *Analysing
the Robustness of VLMs to Common Corruptions* / TextVQA-C (2504.13690v1); *How Robust is OCR-Reasoning?* / OCR-Robust
(2606.26041); DocIQ (2509.17012v1); SD7K / FSENet (2308.14221v4); Q-Doc (2511.11410v1); *Handheld Video Document
Scanning* (2411.00576v1); Real5-OmniDocBench (2603.04205) sections 3 and Table 1 only, for the capture conditions E
did not record. Targeted reads: DocPTBench §4.2 and supplementary 7.2 (2511.18434); DeepSeek-OCR Tables 1-4
(2510.18234v1); Augraphy's README; the Brno Mobile OCR project page; the Frontiers 2026 OCR-based DIQA paper; the
Scientific Reports 2026 blur paper (PMC copy); SynDoc4DSFN's OCR table (PMC copy); MatteViT's OCR table
(2512.08789v1); *Reading in the Dark* (2604.23685); VLM-RobustBench (2603.06148); the DocScan help page; the UK
National Archives' photography rules; the Zenodo records of SmartDoc-QA and SmartDoc 2015 Challenge 2. Not
reachable: the SmartDoc site (certificate mismatch), HAL (bot wall), the Brno and GNHK PDFs (binary), the Sensors
page (403), Apple's and Android's reference pages (JavaScript shells), FADGI's 3rd-edition PDF (not attempted as a
fetch; its ppi tables are tagged [?]).

## 0. Screen

Thirty-nine candidates. Verdict: READ (full), TARGET (a section or a page), SKIM (figures from abstract or README),
DROP, or BUILT (already read by another strand; this note builds on it).

| # | Candidate | What it is | Verdict | Why |
|---|---|---|---|---|
| 1 | PureDocBench (2605.07492) | 1,475 pages in Clean / Digital / Real tracks; Real = phone capture of prints and photocopies, screen photos, social-media compression; 50+ models | READ | The one current benchmark that separates digital degradation from real recapture across general VLMs, E2E specialists and pipelines |
| 2 | Real5-OmniDocBench (2603.04205) | 1,355 pages x 5 physical conditions | TARGET (capture sections) | E has the model figures; the lighting and pose definitions were missing |
| 3 | DocPTBench (2511.18434) | 981 simulated + 400 physical photos; unwarping arm | TARGET (§4.2, 7.2) | E read it; the photometric-residue sentences and figure were not recorded |
| 4 | Wild-OmniDocBench via TeleOCR (2608.12898) | OmniDocBench printed, deformed, photographed | BUILT (D) | D read TeleOCR; no new capture detail there |
| 5 | AnyPhotoDoc6300 via DvD (2505.21975) | 6,300 real pairs, 3 lightings, 2 angles | BUILT (D) | GPL-3.0 data, gated |
| 6 | TextVQA-C / GQA-C (2504.13690) | ImageNet-C corruptions on OCR-dependent VQA | READ | Only paper found that sweeps blur, noise, JPEG and pixelation against an OCR-bearing task |
| 7 | OCR-Robust (2606.26041) | 812 OCR images, 5 perturbations x 3 severities, 18 models incl. Gemini 3 Flash, Qwen3-VL, PaddleOCR-VL+LLM | READ | Current models, OCR task, a pipeline-versus-VLM row |
| 8 | VLM-RobustBench (2603.06148) | 49 augmentations on MMBench/MMMU-Pro | SKIM | No OCR task; useful for the resampling-versus-JPEG contrast |
| 9 | FICO (ACL Findings 2026) | VLMs under visual perturbation incl. JPEG, upscaling blur | DROP | Snippet only; no document task visible |
| 10 | *Evaluating robustness under noisy conditions* (2509.12492) | lighting, motion blur, compression; captioning/VQA metrics | DROP | Not OCR; conflicts with 6 on JPEG and cannot be compared |
| 11 | SmartDoc-QA (CBDAR 2015; Zenodo 5293201) | 4,260 phone images of 30 documents (modern, old administrative letters, receipts), controlled light, blur, angle; OCR truth | TARGET (record) | The only public phone-captured set with historical-looking paper and OCR truth; CC BY 4.0 |
| 12 | SmartDoc 2015 Challenge 2 (Zenodo 2572929) | 8,470 phone-captured test images, mobile OCR competition | SKIM | CC BY 4.0, 38.8 GB; results figures unretrieved |
| 13 | Brno Mobile OCR Dataset (1907.01307) | 19,725 phone photos of 2,113 scientific pages, 23 devices, >500k lines, easy/medium/hard | TARGET (project page) | Largest phone-captured OCR set; non-commercial |
| 14 | GNHK (ICDAR 2021) | camera-captured English handwriting, CC BY 4.0 | SKIM | Notes and lists, not archives; the one camera-captured handwriting set |
| 15 | DocIQ / DIQA-5000 (2509.17012) | 500 phone-captured documents x 10 enhancements, MOS; SmartDoc-QA correlation | READ | Current DIQA state of the art measured against OCR accuracy |
| 16 | Q-Doc (2511.11410) | MLLMs asked to judge SmartDoc-QA quality and name distortions | READ | Tests the "ask the reader whether the photo is good" idea directly |
| 17 | OCR-based DIQA (Frontiers Signal Processing, 2026) | 12 focus features + XGBoost predicting OCR accuracy; proposes a retake gate | TARGET | The only paper proposing capture-time routing; tested on a realistic private set |
| 18 | Hybrid spatial blur detection (Sci. Rep. 2026) | Laplacian + FFT blur map on smartphone handwriting | TARGET (PMC) | Smartphone handwriting; MATLAB, no code |
| 19 | Fast glare detection (1911.05189) | block CNN glare heatmap | SKIM | No figures on the abstract page |
| 20 | Handheld Video Document Scanning (Adobe, 2411.00576) | on-device frame classifier: page turn, hand covering, blur, glare, out of frame | READ | The capture-time design closest to a companion app, with device latencies |
| 21 | DocScan app + ScanTent (Transkribus) | live focus/perspective/positioning guidance, auto-shoot | TARGET (help page) | The humanities field's capture companion |
| 22 | Apple VisionKit document camera | perspective-corrected, enhanced output | SKIM | Apple's page is a JavaScript shell; behaviour from third-party write-ups [?] |
| 23 | CameraX ImageCapture defaults | our Android companion's capture settings | SKIM | Defaults from forum posts [?]; our code sets none |
| 24 | AVCapturePhotoSettings defaults | our iOS companion's capture settings | SKIM | JPEG, balanced quality [M docs mirror]; flash default [?] |
| 25 | SD7K / FSENet (2308.14221) | 7,620 shadow pairs at 2462x3699 | READ | Largest shadow set; needed to know whether it is phone-captured (it is not) and whether OCR was measured (it was not) |
| 26 | Shadow datasets OSR, Kligler, Jung, RDD via SynDoc4DSFN (Sensors 2024) and MatteViT (2512.08789) | small real shadow sets; Tesseract edit distance before and after removal | TARGET (OCR tables) | The only shadow-removal OCR figures found |
| 27 | Shadow-removal survey (Vicinagearth 2025) | nine datasets catalogued | DROP | Paywalled; 25-26 cover the datasets we need |
| 28 | Augraphy (2208.14558; GitHub) | document degradation library, MIT | TARGET (README) | The synthetic-degradation tool for our tests; need its class list and whether it has camera effects |
| 29 | DeepSeek-OCR (2510.18234) | vision-token compression curve; resolution modes vs OmniDocBench | TARGET (Tables 1-4) | The cleanest published resolution-versus-accuracy curve for a document VLM |
| 30 | *Reading in the Dark* (2604.23685) | low-light scene text; frozen enhancer before OCR | SKIM | Scene text; one measured "enhancer before OCR" result |
| 31 | NTIRE 2025 low-light, MILL, MD-LLID | low-light enhancement sets | DROP | Not documents, no OCR |
| 32 | MIDV-500/2019/2020 | identity-document video, low light, projective distortion | DROP | ID cards; licensing and content far from pages |
| 33 | WildReceipt | receipt photos for key extraction | DROP | KIE, not capture quality |
| 34 | CDLA | 5,000 Chinese academic layout images | DROP | Layout set; source format not photographic as far as the README shows [?] |
| 35 | M6Doc photographed subset | 500 photographed book pages | BUILT (E) | Non-commercial, by request |
| 36 | DocUNet, DIR300, UVDoc benchmark, RealDAE, DocEng photographed binarisation | dewarp and appearance sets | BUILT (D) | |
| 37 | FADGI Technical Guidelines, 3rd ed. (2023) | ppi and tone targets by material and star level | SKIM [?] | Scanner and copy-stand guidance; its ppi floors give a yardstick for our 2400 px cap |
| 38 | UK National Archives photography rules; Columbia RBML, New School, Bryn Mawr guides | what researchers may do in a reading room | TARGET (TNA page) | Fixes the capture envelope: no flash, no tripods, stands if available |
| 39 | JPEG-quality-versus-OCR studies | | DROP: none found | Search "JPEG compression quality effect on OCR accuracy study digitization" returned vendor blogs and a 2012 OPF post announcing tests; no controlled sweep with a modern engine |

## 1. Question

Our pages are phone photographs taken in archive reading rooms: handheld, no flash, mixed or dim light, shadows from
hands and the phone, glare on glossy paper, perspective and curl, pages lying in folders and boxes with neighbours
in the frame, colour casts, occasional motion blur, and a capture app's own processing when the user does not use
ours. Which of these defects cost which stage (segmentation, OCR, layout, placement, dating) how much; whether to
warn or re-shoot at capture or repair afterwards; what the measured evidence says about resolution and JPEG for VLM
OCR; whether any public camera-captured set resembles our material and which to borrow; and what small set of our
own capture-defect tests settles the open points.

## 2. What the field does now

**The capture effect is now measured on modern print, and it sorts systems into three bands.** PureDocBench
rebuilds 1,475 pages three ways and finds average losses from Clean of 3.34 points on the Digital track and 11.61 on
the Real track (phone capture of prints and photocopies, screen photos, compressed screenshots); split by system
class the Real losses are 14.23 for pipeline specialists, 12.99 for end-to-end OCR specialists and 9.30 for general
VLMs [M, §3.2, Fig. 3, Table 2]. Real5 takes the same 1,355 pages through five physical conditions and shows the
same ordering with the condition named: a pipeline falls from 84.68 on scans to 37.98 under skew and 73.38 under
its five illumination setups, while Gemini-3 Pro moves between 88.86 and 89.53 across all five [M, Table 1].
DocPTBench's unwarping arm shows that geometric correction recovers most of a pipeline's photograph loss (PaddleOCR-VL
37.5 to 15.9 against 10.5 on the original) but that "photometric degradations such as uneven lighting and motion
blur are not addressed by geometric correction" [M, Table 2, §4.2]. None of the three has archival paper,
handwriting or a page in a box.

**Which optical defect hurts a VLM most: blur, then pixelation; not JPEG, not brightness.** The only per-corruption
sweeps are on general VLMs. On TextVQA-C (one 2023 model) defocus blur costs about 7 points of 57.5, zoom blur
takes 49 to 45, contrast 57.4 to 51.6, Gaussian noise 57 to 53, and JPEG is "relatively stable" [M, §5]. On
VLM-RobustBench (nine 2025-26 open models) upsampling costs up to 34 points, pixelation 11-13, downsampling 5-10,
glass blur about 8 at its lowest severity, motion blur about 7, and JPEG 0.2-0.6 at its highest severity [M]. On
OCR-Robust (18 current models on 812 OCR images) glass blur has the highest mean relative drop of the five kept
perturbations (0.445) and pixelation was excluded because it made text unrecognisable (0.461); the strongest systems
keep 92-93% of clean accuracy at the worst severity, and robustness does not grow with size (InternVL3.5-14B keeps
more than 38B) [M, Table 3, §3]. The perturbations in that benchmark are small (motion kernel 5-7 px, glass blur
radius 2-3 px), so these are gentle degradations by phone standards.

**Quality assessment predicts OCR accuracy where blur is the variable, and fails where it is not.** Focus measures
and shallow regressors reach PCC 0.85-0.91 against OCR accuracy on SmartDoc-QA, whose images were shot by a robot
arm through a designed grid of blur, light and angle [M, Frontiers 2026 Tables 2-5]; the same features reach PCC
0.76 with one OCR engine and 0.39 with another on 100 realistic phone photos of books, notes and receipts [M, §4.3].
DocIQ, the current learned DIQA model, reaches SRCC 0.909 on SmartDoc-QA with a 1600x1600 input and layout masks
from DocLayout-YOLO [M, Table I], and releases nothing. Asking a multimodal model to judge the photo does worse:
on Q-Doc the best coarse quality correlation is SRCC 0.46 (DeepSeek-VL2 with chain of thought) and GPT-4o's is 0.13
[M, Table 2]. The one capture-time system with a published design and device figures classifies live frames
rather than scoring them: Adobe's on-device model labels page turns and capture events with attributes "out of
focus or motion blur", "content obscured by glare", "hand covering content", at 38.7 FPS on a Pixel 7 Pro CPU
[M, 2411.00576 Tables 2-4]; Transkribus's DocScan gives live focus, perspective and positioning guidance and
auto-shoots when the page stops moving [M, help page]. Neither releases code.

**Repair afterwards is measured only with classical engines, and shadows are the clearest case.** Shadow removal
on OSR takes Tesseract's edit distance from 172 on the shadowed input to 25-29 after any modern remover [M,
SynDoc4DSFN Table 5]; no shadow paper measures a VLM, SD7K (the big set) measures no OCR at all, and its pairs were
shot by a Canon on a copy stand, not a phone [M, §3]. D already found the general pattern: appearance restoration
halves Tesseract's error and moves GPT-4o by half a point (PreP-OCR), and dewarping helps a 7B VLM on extreme curls
(DvD). Low-light enhancement before a recogniser can hurt: a frozen enhancer raised a scene-text CER from 53.16 to
53.57 on synthetic low light and lowered it from 25.26 to 23.20 on 60 real night images [M, 2604.23685 Tables 3-4].

**Resolution is the capture variable with the steepest measured curve for a document VLM.** DeepSeek-OCR reads
English pages at 96.5% precision with 64 vision tokens when the page holds 600-700 text tokens and 59.1% when it
holds 1,200-1,300 (compression 10.5x to 19.7x); at 100 tokens the same pages read at 98.5% to 87.1% [M, Table 2];
its OmniDocBench overall edit distance falls from 0.32 at 512 px to 0.205 at 640, 0.156 at 1024, 0.117 at 1280 and
0.083 with tiles [M, Table 4]. That is the published form of our own ladder: the loss is a function of text per
vision token, so it is page-dependent, which is what the kind-classifier note found (7 of 20 quarter-rung pages
fell 10 points or more, "pages with 6 px lines can read as well as their originals") [M, `kind-classifier.md` §3].

**Archival guidance treats a phone as the wrong instrument and says nothing about it.** FADGI's guidelines are
written for scanners and copy stands with targets and star levels [M, LoC blog; ppi tables [?]]. Reading-room rules
fix the envelope instead: the UK National Archives allows phones and tablets, forbids flash, tripods and selfie
sticks, lends a limited number of camera stands, and gives no image-quality guidance [M, TNA page]; the US National
Archives and university libraries say the same in different words [?, search summaries]. So the user cannot add
light, cannot stabilise except by a borrowed stand, and must photograph from above a table.

## 3. Claims table

| # | Source | Claim | Figure | Conditions | Tag | Location |
|---|---|---|---|---|---|---|
| 1 | PureDocBench 2605.07492v2 | Tracks and sizes | 1,475 source pages x 3 = 4,425 images; Digital = ten templates (aging, binding, photocopying, compression, lighting, geometric); Real = phone capture of prints, phone capture of photocopies, screen photography, screenshots with social-media compression; 83 Real images unreadable in human review (Filtered set 1,392) | parameters in App. F, absent from the HTML | M | §2, Table 3 |
| 2 | PureDocBench | Average loss from Clean | Digital 3.34, Real 11.61; pipeline specialists 5.17 / 14.23, E2E specialists 4.14 / 12.99, general VLMs 1.84 / 9.30 | | M | §3.2, Fig. 3 |
| 3 | PureDocBench | Per-model Clean / Digital / Real | Gemini 3.6 Flash 79.97 / 79.11 / 75.73; Claude Opus 5 82.99 / 72.94 / 75.27; Gemini-3.1-Pro 70.04 / 69.28 / 71.98; GLM-5.3-Flash 83.04 / 81.03 / 74.99; Qwen3.8-27B 80.45 / 78.86 / 73.59; Qwen3.6-27B 70.20 / 67.49 / 59.18; Qwen3.5-9B 73.87 / 73.34 / 65.45; Qwen3-VL-8B 72.44 / 72.03 / 62.73; GLM-OCR 68.65 / 63.06 / 58.31; dots.ocr 72.01 / 65.95 / 55.68; olmOCR-2-7B 69.36 / 65.87 / 56.10; PaddleOCR-VL-1.6 64.46 / 59.29 / 54.24; TeleOCR 87.16 / 79.40 / 69.08; largest drop Dolphin-v2 -20.98 | predominantly Chinese-English; "limited coverage of handwriting and historical books" | M | Table 2, App. A |
| 4 | PureDocBench | Release | dataset, source documents, generation tools and evaluation code public at github.com/zhihengli-casia/PureDocBench | licence not stated in the text read | M; licence [?] | abstract |
| 5 | Real5 2603.04205 | Capture conditions | scan: Canon C5840 at 1200 dpi (standard, low-quality via repeated print-scan, slanted, stapled, bound); warp: centre fold, cylindrical roll, dense crumple, dog-ear/curl, book-spine arc; screen: five displays; illumination: low light, partial shadow, coloured light, flashlight spot, light refracted through glass; skew: pitch, roll, yaw, compound, extreme tilt; phones from Apple, Xiaomi, OPPO | no angles or lamp types given | M | §3 |
| 6 | Real5 | Overall by condition (scan / warp / screen / illumination / skew) | Gemini-3 Pro 89.47 / 88.90 / 88.86 / 89.53 / 89.45; Qwen3-VL-235B 89.43 / 89.99 / 89.27 / 89.27 / 86.56; GPT-5.2 84.43 / 76.26 / 76.75 / 80.88 / 75.00; PaddleOCR-VL-1.6 94.74 / 92.48 / 92.78 / 93.28 / 92.66; GLM-OCR 92.67 / 90.68 / 91.75 / 91.12 / 85.39; dots.ocr 86.87 / 86.01 / 87.18 / 87.57 / 84.27; MinerU2.5 90.06 / 83.76 / 89.41 / 89.57 / 75.24; DeepSeek-OCR 2 89.59 / 66.53 / 71.65 / 76.02 / 61.28; PP-StructureV3 84.68 / 59.34 / 66.89 / 73.38 / 37.98; Marker 70.27 / 58.98 / 63.65 / 66.31 / 41.27 | | M | Table 1 |
| 7 | Real5 | Illumination text edit distance | PP-StructureV3 0.158, Marker 0.259, Qwen3-VL-235B 0.060, Gemini-3 Pro 0.073, GLM-OCR 0.059, MinerU2.5-Pro 0.050, PaddleOCR-VL-1.6 0.042 | seven systems | M | Table 5 |
| 8 | DocPTBench 2511.18434 | Photographs and unwarping | 981 simulated + 400 physical photos of 100 originals "under four distinct and challenging conditions" (unnamed); unwarping by the commercial TextIn `crop_enhance_image` API; overall edit (En) original / photographed / unwarped: PaddleOCR-VL 10.5 / 37.5 / 15.9; MinerU2.5 11.1 / 37.3 / 17.3; dots.ocr 12.5 / 33.7 / 16.3; DeepSeek-OCR 13.4 / 54.4 / 22.1; olmOCR2 16.1 / 27.8 / 17.5; Gemini 2.5 Pro 14.8 / 18.2 / 16.9; Qwen-VL-Max 16.6 / 27.7 / 19.0 | | M | Table 2, §3 |
| 9 | DocPTBench | Photometric residue | "Photometric degradations such as uneven lighting and motion blur, are not addressed by geometric correction"; DeepSeek-OCR "still 8.7 points worse on Unwarping than Original" | no per-lighting breakdown; licence unstated | M | §4.2, Supp. 7.2 |
| 10 | TextVQA-C 2504.13690v1 | Corruption sweep on an OCR-dependent task | LLaVA-1.5 only; 19 ImageNet-C corruptions x 5 severities; clean 57.5; defocus about -7 (to about 50 at s5); motion to 51-52; glass 56 at s5; zoom 49 to 45; contrast 57.4 to 51.6; pixelate 51 to 45; Gaussian noise 57 to 53; impulse about 53 from s3; JPEG "relatively stable"; brightness "smallest degradation" | values only in charts; the text is internally inconsistent on glass blur | M | §5.1-5.5 |
| 11 | OCR-Robust 2606.26041 | Perturbations | glass blur radius 2 / 2.5 / 3 px; motion blur kernel 5 / 6 / 7 px; elastic alpha 10 / 15 / 20; colour shift 3-5 px; snow 0.1-0.3; OpenCV and PIL; 812 images (482 OCR1.0: documents, scene text, receipts, handwriting, screenshots; 330 OCR2.0: charts, geometry, tables) | 13 other candidates piloted and dropped, incl. defocus, pixelate, glare, moire, rotation | M | §3 |
| 12 | OCR-Robust | Robustness by model (OCR1.0: clean / RCR / WCR) | Gemini-3-Flash 80.71 / .986 / .920; Gemini-3-Flash-Thinking 79.05 / .998 / .932; GPT-5.2 74.69 / .911 / .799; Qwen3-VL-8B-Thinking 79.67 / .961 / .875; Qwen3-VL-32B-Instruct 72.82 / .954 / .826; Qwen3-VL-8B-Instruct 54.15 / .903 / .770; InternVL3.5-38B 62.86 / .933 / .794; InternVL3.5-14B 55.81 / .939 / .838; PaddleOCR-VL-1.5 + Gemini-3-Flash-T 65.15 / .938 / .796 | RCR = relative accuracy kept at low severity, WCR at worst | M | Table 3 |
| 13 | OCR-Robust | Which hurts | glass blur mean relative drop 0.445, highest kept; pixelate 0.461 excluded as unrecognisable; colour shift drives OCR2.0 losses over 40% for several models at s3; WCR 0.826 on OCR1.0 vs 0.676 on OCR2.0; code at github.com/pasterinjlu/OCR-Reasoning-Robust | | M | §3, Fig. 8, Table 3 |
| 14 | VLM-RobustBench 2603.06148 | Resampling vs photometric | upsample (high) 26.3-33.9 pp; elastic 23-29; pixelate 11.4-13.0 (family means); downsample 4.9-9.7; glass blur (low) about 8.1; motion blur (high) about 7.3 (InternVL); shot noise 5.1-12.9; JPEG 0.2-0.6 | MMBench/MMMU-Pro; no OCR task; 9 models | M | results |
| 15 | DeepSeek-OCR 2510.18234v1 | Precision vs compression (Fox, English) | 64 tokens: 96.5% at 10.5x (600-700 text tokens), 93.8% at 11.8x, 83.8% at 13.2x, 85.9% at 15.1x, 79.3% at 16.5x, 76.4% at 17.7x, 59.1% at 19.7x; 100 tokens: 98.5% at 6.7x to 87.1% at 12.6x | 100 pages | M | Table 2 |
| 16 | DeepSeek-OCR | Resolution modes and OmniDocBench overall edit | Tiny 512 px / 64 tokens 0.32; Small 640 / 100 0.205; Base 1024 / 256 0.156; Large 1280 / 400 0.117; Gundam tiles 0.083; Gundam-M 0.077 | | M | Tables 1, 4 |
| 17 | DocIQ 2509.17012v1 | DIQA-5000 | 500 originals printed at 300 dpi and phone-captured, 100 per distortion (shadow, occlusion, blur, creases, moire), x10 enhancements; 15 raters, MOS | not released | M | §3 |
| 18 | DocIQ | Correlation with OCR accuracy on SmartDoc-QA (PLCC / SRCC) | DocIQ 0.9218 / 0.9086 (CACC), 0.9107 / 0.8989 (WACC); StairIQA 0.9138 / 0.8921; HyperIQA 0.8900 / 0.8828 | input 1600x1600 plus layout masks from DocLayout-YOLO and MinerU; ResNet50; no code, weights or data release stated | M | Table I |
| 19 | Q-Doc 2511.11410v1 | Composition | 4,260 SmartDoc-QA images; 660 single-distortion (180 underexposed, 120 motion blur, 240 defocus, 120 clean); 3,600 multi-distortion | | M | Table 1 |
| 20 | Q-Doc | MLLMs judging quality | coarse SRCC / PLCC: DeepSeek-VL2 0.4474 / 0.3713, +CoT 0.4603 / 0.3886; GPT-4o 0.1321 / 0.0610; Llama-3.2-11B 0.2122 / 0.2069; multi-distortion identification GPT-4o 34.54 raw / 62.54 balanced; "inconsistent scoring, distortion misidentification, and severity misjudgment"; code at github.com/cydxf/Q-Doc | zero-shot; 2024-25 models | M | Tables 2-4, §4 |
| 21 | Frontiers DIQA 2026 | Features and fit | 12 features (Tenengrad, Tenengrad variance, variance of Laplacian, modified Laplacian, MLoG, Brenner, median differences, Vollath, gradient energy, squared gradient, histogram range, skew angle); SmartDoc-QA 2,130 images (30 docs x 71 angles); XGBoost PCC 0.8533 (Tesseract labels), 0.8528 (FineReader), 0.7853 (Paddle), 0.9139 (Keras-OCR) | 100-fold CV; the text's 0.9239 and Table 5's 0.9139 disagree | M | Tables 2-6 |
| 22 | Frontiers DIQA 2026 | Realistic set | private 100 images, 20 documents (books, handwritten notes, receipts) x 5 conditions, Redmi 10 default camera: PCC 0.7613 (Keras labels), 0.3911 (Paddle labels); Fig. 2 "directs images either for retake or to the OCR engine based on predicted accuracy", no threshold given; no code | | M | §4.3, Fig. 2 |
| 23 | Sci. Rep. 2026 (HSBDRA) | Blur map on smartphone handwriting | Laplacian variance in a local window OR FFT high-frequency energy, threshold 90-120, morphology; 417 handwritten images from over 200 people (Karnataka) on phones, two synthetic blur levels; F-measure 0.9894 / PSNR 17.39 / SSIM 0.9336 at level 1; Tesseract CER listed as a metric but no before/after values; MATLAB, i7-12700K, no GPU; no code; data on request; CC BY-NC-ND | detection accuracy of the blur mask itself not reported | M | Tables 5-7, 13 |
| 24 | Adobe 2411.00576v1 | Capture-time frame model | 632 videos, 144 people, >1M frames; CapE attributes: hand covering content, hand covering page not content, content out of frame, page out of frame, out of focus or motion blur, content obscured by glare, page lifted, two pages, graphical; PCN = reduced MobileNetV2 + 2-layer LSTM on 64x64 grey; CapN = MobileNetV2 at 320x320; CPU FPS Pixel 7 Pro 557 / 38.7, OnePlus N10 274 / 17.2, Moto X4 49 / 4.8; page-turn F1 0.97 on PUCIT | no per-attribute accuracy; no code or data release | M | §3-5, Tables 1-4 |
| 25 | DocScan help page | Capture guidance | guidance on focus, perspective and positioning; automatic capture when a page is turned and "DocScan detects no other movement"; lock white balance and exposure; grid overlay; automated cropping with a few extra pixels; Android only, iOS via a third-party app | no thresholds; no output resolution stated | M | help.transkribus.org/docscan |
| 26 | SD7K 2308.14221v4 | Dataset | 7,620 triplets, mean 2462x3699; Canon EOS M6 on a stand, fixed exposure, remote shutter, occluder removed between shots; sunlight, 80 W 3000 K LED, 80 W 6000 K LED; 30+ occluders; shadow area 41.38% +- 13.58%; "text and picture" (manga, papers, figures); no OCR experiment; FSENet 29.34 M params, 0.75 s at 1024, 7.93 s at full size, "cannot run in real time or on edge devices"; code, models and data on GitHub; licence not stated | not phone-captured | M | §3, Tables 1-2, §5.4 |
| 27 | SD7K | Older shadow sets | Bako 81 triplets; Kligler 300 (25 entities, 2424x2013); Jung 87 (602x860); RDSRD 540 synthetic | | M | Table 1 |
| 28 | SynDoc4DSFN (Sensors 2024, PMC11154307) | Shadow removal helps Tesseract | OSR images with detectable text: edit distance shadowed 172.26; STCGAN-BE 28.52; BEDSR-Net 28.20; DHAN 26.64; DSFN 25.14; OSR 237 triplets (26 documents, coloured shadows); Kligler 300 pairs (handwritten, printed, posters, fonts); Jung 87 pairs; all resized to 512x512; code github.com/ym4t50/SynDoc4DSFN | Tesseract version and image count not given | M | §5.4, Table 5, Table 1 |
| 29 | MatteViT 2512.08789v1 | Shadow removal and Tesseract on RDD | edit distance: Liu et al. 142.43, BEDSR-Net 125.07, ShaDocFormer 149.79, DocDeShadower 138.68, MatteViT 113.21; no shadowed-input row; 512x512; no code; no size or runtime | | M | Table 2 |
| 30 | *Reading in the Dark* 2604.23685 | Enhancer before a recogniser | TrOCR CER on synthetic low light 53.16, with frozen SRDACE in front 53.57; on 60 real night images 25.26 to 23.20; jointly trained 14.43; RLLIE 13.66 | scene text | M | Tables 3-4 |
| 31 | Brno Mobile OCR (project page; 1907.01307) | Phone-captured OCR set | 2,113 pages of scientific papers, 19,725 photos, 23 devices, >500k lines, "unrestricted conditions", "various amount of blurriness, illumination etc."; LSTM baseline CER easy 0.33 / medium 5.65 / hard 32.28 (WER 1.93 / 22.39 / 72.63); "non-commercial research purpose only"; Zenodo 10.5281/zenodo.15310981; test scored by upload | subset criterion not stated | M; test withheld [I] | project page |
| 32 | SmartDoc-QA (Zenodo 5293201) | Phone-captured QA set | 30 documents of three types: modern documents, old administrative letters, receipts; varying light, "different types of blur", perspective angles; transcriptions, OCR results and the capture parameters per image; CC BY 4.0; 13.7 GB | 4,260 images, Galaxy S4 and Lumia 920 on a robot arm [?, snippets]; labels from Tesseract and FineReader [M, Frontiers §3] | M (record); counts and devices [?] | Zenodo record |
| 33 | SmartDoc 2015 Challenge 2 (Zenodo 2572929) | Mobile OCR competition data | sample 12.2 GB + test 26.6 GB; CC BY 4.0; 8,470 test images, 5 entries, ranked by character accuracy, "CCC" insensitive to light [?, search snippets] | results figures not retrieved | M (record); figures [?] | Zenodo record |
| 34 | GNHK README | Camera-captured handwriting | "unconstrained camera-captured images of English handwritten text", CC BY 4.0; 687 images [?] | | M (licence); count [?] | github.com/GoodNotes/GNHK-dataset |
| 35 | Augraphy README | Degradation classes | LightingGradient, ShadowCast, ReflectedLight, Jpeg, LowLightNoise, SubtleNoise, BleedThrough, Folding, Geometric, BadPhotoCopy, Faxify and about 35 more; blur only as DepthSimulatedBlur in a benchmark table; no camera or perspective preset; "eventually" camera-phone augmentations; MIT (Sparkfish 2023); v8.2.6 | | M | README |
| 36 | TNA photography rules | Reading-room envelope | hand-held cameras, phones, tablets allowed for personal use; "Flash photography is not permitted"; tripods, selfie sticks and integral stands not permitted; camera stands with screw mounts lent, limited; good handling takes priority; no image-quality guidance | | M | nationalarchives.gov.uk page |
| 37 | Our companions (code read) | Capture settings | iOS: `session.sessionPreset = .photo`, `AVCapturePhotoSettings()` default, `fileDataRepresentation()`; Android: `ImageCapture.OutputFileOptions.Builder(file)` with no capture mode, JPEG quality, flash or resolution set; no focus, exposure, blur, glare or framing check anywhere in either app (grep) | | M | `CameraController.swift` 66-92; `CaptureScreen.kt` 412-423 |
| 38 | Platform defaults | What those defaults mean | AVCapturePhotoSettings default: JPEG codec and file type, `photoQualityPrioritization` balanced [M, docs mirror and WWDC21]; flash default [?]; CameraX default capture mode MINIMIZE_LATENCY and JPEG quality 95 [?, forum and PR] | | M / ? | sources named |
| 39 | Our Processor (code read) | What the Mac sends to a reader | `ImageEncoding.maxOCRDimension = 2048`, JPEG quality 0.85, never upscales; the user "resolution" slider targets megabytes, not pixels; segmentation windows at 1,600 px | the bench ran every page at 2400 px, JPEG 90 [M, `ocr-panel-local.md` line 17] | M | `ImageEncoding.swift` 7-69; `SettingsView.swift` 768 |
| 40 | Our truth set (`pages.tsv`, computed here) | Capture attributes of the 67 originals | cameras: iPad 38 (2592 px), iPad mini 2 5 (2592), iPhone 6 6 (3264), iPad mini 6 (4032), Pixel 9 8 (4080), Pixel 6 3 (4080), Pixel 4a 1 (4032); long side median 2592; Laplacian-variance median 774 (typewritten 780, printed 890, handwritten 506) | the measure is `ocr_truth.py sharpness()`: variance of a 4-neighbour Laplacian on a 1024 px grey thumbnail | M | `pages.tsv`; `ocr_truth.py` 307-315 |
| 41 | Ours (computed here) | Phone original against PDF image, typed and printed pages only | NES on 45 originals / 32 PDF images: Apple Vision 85.7 / 88.5; LightOnOCR-3 4B 8-bit 86.3 / 94.5; Qwen3-VL 8B 95.3 / 95.0; Qwen3.6-27B 96.1 / 97.1; Qwen3-VL-235B 94.0 / 96.4; Gemini 3.8 Flash 95.3 / 99.4 (2 originals failed); Gemini 3.5 Flash-Lite 95.1 / 98.5; Gemini 3.1 Pro 96.6 / 99.5; Claude Sonnet 5.5 96.6 / 99.4; Mistral OCR 4.1 93.5 / 96.6; GPT-5.6 luna 95.9 / 95.3; gemma4-31b 92.8 / 96.3 | "PDF image" = the page image inside an owner PDF where no photo survives, so already processed (ABBYY's 1-bit text mask over a shrunken background, `PHOTO-SIZE-DECISION`); material also differs | M; attribution to capture [I] | `toolsL/capture_attrs.py` output |
| 42 | Ours (computed here) | Global sharpness does not predict NES | Spearman rho between Laplacian variance and NES on typed+printed originals: -0.25 (Qwen3.6-27B) to +0.32 (Vision), 25 of 29 routes within +-0.13; the middle tertile scores lowest for 25 of 29 routes; long side rho -0.23 to +0.13 | 45 pages | M | same |
| 43 | Ours (by eye, this read) | The six worst typed/printed originals | p082 55.9 (neighbouring page's column and a copyright label in frame, white type on purple), p034 72.3 (rotated handwritten folder label at the edge, pencil marks, warm cast), p018 74.9 (blank form, rubber stamp, torn edges, underlying page's numbers intruding at the right, top line cut), p011 77.0 (chart with hand lettering, show-through, dim warm light), p013 80.4 (typed with red marginalia and red show-through), p100 81.5 (faint type, dot leaders, heavy show-through, ink cross-out); none out of focus, none motion-blurred, none shadowed across text, none with glare | mean NES across 20-29 routes | M (scores); defects by eye | images in the private cache |
| 44 | Ours (`HW-COVERAGE`, F) | Motion blur on a handwritten page | p094 "motion-blurred photo; mostly missed": 2 of 17 lines covered, about 25% of words inside a Vision box | one page | M | `HW-COVERAGE-2026-10-15.tsv` |
| 45 | Ours (`ocr-panel-local.md`) | Resolution ladder, 20 pages, original / half / quarter | Qwen3.6-27B 96.07 / 95.33 / 71.70; Qwen3.5-27B 85.46 / 93.52 / 58.27; Qwen3-VL 8B 95.14 / 93.36 / 66.74; Qwen3.6-35B-A3B 94.77 / 94.87 / 68.97; gemma4-31b 90.27 / 92.61 / 86.02; Mistral Small 24B 91.66 / 90.53 / 62.97; Gemini 3.1 Flash-Lite 95.73 / 90.75 / 89.74; Apple Vision 80.13 / 79.47 / 52.69 | half and quarter of the native source, each capped at 2400 px | M | lines 61-118 |
| 46 | Ours (`kind-classifier.md`) | The fall is page by page | 7 of 20 quarter and 1 of 20 half images read 10+ points worse for Qwen3.6-27B; "pages with 6 px lines can read as well as their originals"; text height does not predict the fall; every corpus photo is 2,592 px or more | | M | §3, §5 |

## 4. Code, weights, data and licences

| Item | What it gives this strand | Licence | Mac-runnable | Cluster needs | Verdict |
|---|---|---|---|---|---|
| Real5-OmniDocBench | five-condition photographed benchmark with 20 published rows; the illumination and warp folders | images Apache-2.0, annotations OmniDocBench research-only [M, E claim 8] | evaluator yes | 16 GB download; 6,775 images | Borrow; E's test 1 already runs it |
| PureDocBench | Clean / Digital / Real tracks; generation tools | public on GitHub; licence unstated [?] | generation tools likely Python [I] | moderate | Borrow the Real-track protocol and tools once the licence is read |
| DocPTBench | 400 physical photos with an unwarping arm | unstated [M, E] | | | Design only, as E said |
| SmartDoc-QA | 4,260 phone photos incl. old administrative letters, with blur / light / angle parameters per image and OCR truth | CC BY 4.0 [M] | yes | 13.7 GB | Borrow: the one free capture-parameter anchor on historical-looking paper (test 7) |
| SmartDoc 2015 Challenge 2 | 8,470 phone-captured pages | CC BY 4.0 [M] | | 38.8 GB | Low priority; modern print, old engines |
| Brno Mobile OCR | 19,725 phone photos, line truth, easy / medium / hard | non-commercial research only [M] | | | Measurement only; scientific papers |
| GNHK | camera-captured handwriting | CC BY 4.0 [M] | | | Possible camera-captured handwriting anchor; notes, not archives |
| SD7K + FSENet | 7,620 shadow pairs; a 29 M-param remover | unstated [M] | FSENet PyTorch; 7.93 s full-res on an unnamed GPU, MPS plausible [I] | yes | Research comparison for shadow repair; copy-stand photos, no OCR figures |
| OSR, Kligler, Jung, RDD | small real shadow sets; the only shadow-removal OCR figures (Tesseract) | unstated [?] | | | Cite, do not build on |
| DIQA-5000 / DocIQ | DIQA state of the art | nothing released [M] | n/a | n/a | Cite only |
| Q-Doc | protocol for asking a VLM to judge quality | code public, licence unstated [M] | yes | | Borrow the three-level protocol for test 8 |
| OCR-Robust | perturbation code, 18-model table | code public (paper CC BY 4.0); data from mixed sources [M] | yes | | Borrow the RCR / WCR / CRI metrics for our degradation ladder |
| Augraphy | 45 degradation classes incl. ShadowCast, LightingGradient, ReflectedLight, Jpeg, LowLightNoise, Folding; no camera preset, no blur, no perspective | MIT [M] | yes, CPU Python | yes | Borrow for test 3, with OpenCV motion/defocus blur and perspective added |
| Adobe handheld video model | the capture-time attribute design and device latencies | no release [M] | n/a | n/a | Design reference for the companion |
| DocScan | live capture guidance | app free; source licence not checked [?] | Android app | n/a | Design reference; not a dependency |
| Apple Vision `DetectDocumentSegmentationRequest` (macOS 15, iOS 17; `VNDetectDocumentSegmentationRequest` iOS 15) | page quad and mask on device, for framing checks and the quad crop | system | yes; iOS companion too | n/a | R1 and the companion's framing check (D claim: corners only, no curvature) |
| DocRes, UVDoc, GCDRNet, jere1882 denoiser | repair candidates | MIT / MIT / MIT / MIT [M, D] | yes with patches [D] | | D's tests 1-2 supply the repair arms |

## 5. Comparison with what we measured

**The capture penalty exists in our own data and is small for strong readers.** Holding kind fixed (typewritten
and printed only), phone originals read 0.1 to 8.2 points below the processed PDF images for 25 of 29 routes
(claim 41). The gap is largest for the laptop readers (LightOnOCR-3 4B +8.2, Apple Vision +2.7 with a lower
base) and the Gemini Flash models (+3.3 to +4.1), small for Claude Sonnet 5.5 and Gemini 3.1 Pro (+2.8, +2.9) and
near zero or reversed for Qwen3-VL 8B, GPT-5.6 luna, Mistral Large 4 and Gemini 3.5 Flash. The processed images are ABBYY's
1-bit text mask over a shrunken background, so this is "photograph versus binarised copy", and the two groups
are different documents; it is an upper bound on what capture costs typed pages here [I]. It is the same order
as PureDocBench's 9.30-point general-VLM loss on real recapture and smaller than its 14.23 for pipelines (claim 2),
which fits: our routes are VLMs and Vision, and our photographs are flatter and better lit than a stress benchmark.

**The defects that cost our typed pages are not the optical ones.** The six worst phone originals (claim 43) are
hurt by what is in the frame (a neighbouring page's text column, a folder label at the edge, an underlying page's
numbers, a copyright label), by the material (show-through of the overleaf on three of six, faint carbon type,
white type on purple), and by mixed content (red marginalia, a stamp, hand-lettered chart labels). None is
blurred, shadowed across text or glared. The one blur failure we have is on a handwritten page, where Vision found
2 of 17 lines (claim 44). So for this corpus the capture problems are framing and content scope, and the readers'
disagreement with the truth about what to transcribe is what the score measures; the optics are good enough that
no route shows a sharpness effect (claim 42).

**Our global sharpness measure is confounded and should not be used as a defect tag.** The Laplacian variance
tracks ink density more than focus: the "high" tertile is dense print, the "low" tertile is sparse handwriting and
memos (5,699 words over 31 pages against 13,825 over 33), and within typed pages the middle tertile scores worst
because the hard pages happen to sit there. The field's result is the same: focus measures predict OCR accuracy
where blur was the designed variable (PCC 0.85-0.91 on SmartDoc-QA) and poorly on realistic photos (0.39-0.76,
claim 22). Any capture-time blur signal has to be measured inside text regions and calibrated on pages like ours.

**Resolution is the one capture variable we have measured properly, and the field now explains it.** The ladder
(claim 45) and DeepSeek-OCR's compression curve (claim 15) are the same phenomenon: a document VLM's accuracy is a
function of text per vision token, which is why our quarter-rung loss is page by page (claim 46) and why Gemini
Flash-Lite, with a larger or adaptive token budget, holds at 89.7 where the Qwen family falls to 58-72. What we
have not measured is JPEG. The app sends 2048 px at quality 0.85 (claim 39), the bench ran 2400 px at 90, and no
controlled JPEG sweep with a modern document reader exists (screen row 39); the general-VLM sweeps put JPEG's cost
at 0.2-0.6 points even at ImageNet-C's harshest setting (claims 10, 14), so the expectation is nil, but the app's
2048 cap is a 15% linear reduction of the bench's images and sits between the half rung (no loss) and the original.
Test 5 settles both.

**What transfers from the photographed benchmarks and what does not.** Transfers: the band ordering (pipelines
worst, OCR specialists next, general VLMs best; claims 2, 6); the layout module as the fragile part (E); unwarping
recovering geometry but not light or blur (claims 8-9); shadows as a large loss for classical engines and a small
one for VLMs (claims 7, 28). Does not transfer: the severities. Real5's skew is "extreme tilt" and its warps are
crumples and rolls; our pages lie in boxes, upright after rotation, at a few degrees. PureDocBench's Real track
photographs prints and photocopies of born-digital pages with no show-through, no marginalia, no stamps, no
coloured paper. OCR-Robust's blur kernels are 5-7 px on images of unstated size. So the published losses are ceilings
for our geometry and floors for our material, and none of them measures framing, which is our actual problem.

**Where a public benchmark makes our own less necessary.** For "how robust is reader X to pose, warp, lighting and
screen capture on modern print", Real5 answers with 20 rows and E's test 1 adds our staged route to it; we should
not build a photographed modern-print set. For "which optical corruption hurts a VLM most", OCR-Robust and
VLM-RobustBench answer (blur and pixelation, not JPEG) and we need only confirm on our pages. For "can a VLM judge
photo quality", Q-Doc answers no for 2024-25 models; test 8 re-asks with ours because the models have moved. For
blur and light on historical-looking paper with controlled parameters, SmartDoc-QA's old-letters subset is free
and already labelled by capture parameter; it replaces a controlled re-shoot we cannot do on archive material.

**What to borrow and run ourselves.** Real5's evaluator and folders (E). OCR-Robust's RCR / WCR metrics (relative
accuracy kept at low and worst severity) for our own degradation ladder, so a reader's fragility is a number beside
its clean NES. Augraphy's shadow, lighting, reflection, low-light-noise and JPEG classes plus our own motion blur,
defocus and perspective for the synthetic ladder (test 3). Q-Doc's protocol for test 8. SmartDoc-QA's old letters
for test 7. Adobe's capture-event attribute list as the schema for our defect tags (test 1), since it is the one
list built from a million real handheld frames.

## 6. Strand-specific questions

### 6.1 Which capture defects matter for which stage, with the measured effect sizes

| Defect | OCR (VLM routes) | OCR (Vision, PP-OCR, small specialists, pipelines) | Layout (E) | Placement (F) | Segmentation and dating |
|---|---|---|---|---|---|
| Framing: neighbours, labels, underlying pages in frame; edges cut | Our worst typed pages (claim 43): the readers transcribe or omit the extra text and lose 20-45 NES against a truth that scopes one page [M scores; I cause]. Not measured anywhere else. | Same, plus detector regions on the neighbour [I] | Unmeasured; a text column of another page is a region to any detector [I] | Vision places whatever it reads; no loss [I] | A neighbour's letterhead or date is a false cue for both; a cut top line removes the letterhead date (p018 "WAR DEPARTMENT" cut) [I] |
| Pose and perspective (skew) | 0 to -1 for Gemini-3 Pro, Qwen3-VL-235B; -9 for GPT-5.2 (claim 6); our pages are upright at a few degrees after rotation [E] | -47 for PP-StructureV3, -29 for Marker, -28 for DeepSeek-OCR 2, -15 for MinerU2.5 (claim 6) | DocLayout-YOLO 48.74 vs RT-DocLayout 91.66 on Real5 skew [E claim 2] | A homography keeps lines straight; sloped runs suffice [F §6.5] | Unmeasured; windows at 1,600 px are read by a VLM, so the VLM figures apply [I] |
| Curl and folds (warp) | -0.6 Gemini-3 Pro; +0.6 Qwen3-VL-235B; -8 GPT-5.2 (claim 6); DvD: 7B VLM MMCER 0.576 to 0.215 on extreme curl [D] | -25 PP-StructureV3; -23 DeepSeek-OCR 2; unwarping recovers most of it (37.5 to 15.9) (claims 6, 8) | DocLayout-YOLO 74.70 vs 91.25 on warp [E] | A straight run across a curved line errs by the sagitta; dewarp on means the layer sits on the dewarped copy [F] | Unmeasured |
| Illumination: low light, partial shadow, coloured light, spot, refraction | 0 to -2 for Gemini-3 Pro, Qwen3-VL-235B, GLM-OCR (claim 6); text edit 0.060-0.073 (claim 7) | -11 PP-StructureV3 (claim 6); shadow removal takes Tesseract's edit distance 172 to 25 on OSR (claim 28) | DocLayout-YOLO 83.65 vs 92.16 on illumination [E] | Vision's line finding under shadow unmeasured; p022 "dark background" confounded the ink measure [F] | Unmeasured; a shadow across a date stamp is the plausible case [I] |
| Glare on glossy paper | No figure anywhere; OCR-Robust piloted and dropped glare (claim 11); Adobe labels it as a capture event (claim 24) | None | None | None | None |
| Motion blur | OCR-Robust motion kernel 5-7 px: WCR 0.92 for Gemini-3-Flash down to 0.77 for Qwen3-VL-8B-Instruct across all five perturbations (claim 12); VLM-RobustBench about 7 pp at high severity (claim 14); DocPTBench names it as the unrepaired residue (claim 9) | Vision found 2 of 17 lines on p094 (claim 44); Brno's hard subset WER 72.6 vs easy 1.9 (claim 31) | Unmeasured | Vision's geometry fails first: 25% of words in a box on p094 (claim 44), so the text page is the fallback [F] | Unmeasured |
| Defocus and glass blur | glass blur the worst kept perturbation, MRD 0.445 (claim 13); defocus -7 of 57.5 (claim 10) | same as motion | | | |
| Resolution (px per character) | quarter rung -25 to -40 for Qwen, -6 for Flash-Lite, -4 for gemma4-31b, page by page (claims 45-46); DeepSeek-OCR 96.5% to 59.1% over 10x to 20x compression (claim 15) | Vision 80.1 to 52.7 at quarter (claim 45) | Unmeasured; detectors run at 640-1036 px anyway [E] | Word boxes shrink with the image; unmeasured | Windows at 1,600 px: unmeasured |
| JPEG compression | 0.2-0.6 pp at ImageNet-C's harshest level (claim 14); "relatively stable" (claim 10); app 0.85 vs bench 0.90 unmeasured | Unmeasured with a modern engine (none found) | | | |
| Colour cast, coloured paper | brightness "smallest degradation" (claim 10); colour shift drives chart/table losses, not document text (claim 13); p082's white-on-purple is our one case [M by eye] | Unmeasured | | | Stamps and postmarks are red or purple on cream; unmeasured [I] |
| Show-through and faint ink (material, not capture) | 3 of our 6 worst typed pages (claim 43); readers transcribe ghost text or miss faint type [I] | Vision misses faint pencil (HW-COVERAGE p094, p096) [F] | | Faint strokes fall out of the 1-bit stencil at 1/6 and 1/8 background (PHOTO-SIZE) [M] | |
| Capture-app processing (binarisation, "photocopy" filters) | Content-removing by construction (D §6.1); our PDF images are such copies and read 1-8 points better on typed pages (claim 41) but the owner's rule forbids them as reading copies | | | | Stamps, pencil and marginalia are what such filters remove (D) |

Reading the table: for the premium and 27B-class routes, geometry and light cost about nothing and blur and
resolution cost a lot; for the laptop and pipeline routes, geometry and light cost a lot and are repairable; for
every route the framing and material problems are unmeasured by the field and are what actually hurt our typed
pages.

### 6.2 Quality assessment at capture against repair afterwards

The evidence sorts the defects by whether repair can work at all.

- **Not repairable after the fact: motion blur, defocus, missing content (cut edges), and resolution.** No
  restorer recovers strokes a blurred exposure never recorded; DocPTBench names blur as what unwarping leaves
  (claim 9), the deblurrers D catalogued measure PSNR not OCR, and diffusion restorers invent text (D §6.4). A page
  whose edge is cut cannot be completed. Resolution is fixed at the shutter. These are the capture-time cases, and
  blur is the only one of them that happens to our pages without the user knowing (p094).
- **Repairable, and worth repairing only for some routes: perspective, curl, shadow, uneven light.** For the frontier
  and 27B routes the measured loss is 0-2 points, so repair is a cost with no gain, and D found that appearance
  work moves GPT-4o by half a point. For Apple Vision, PP-OCRv6, GLM-OCR behind a detector, and any pipeline, the
  losses are 11-47 points and dewarping recovers most of the geometric part (claims 6, 8); shadow removal is the one
  photometric repair with large measured OCR gains, for Tesseract (claim 28). D's tests 1-2 are the repair arms;
  this strand adds that they should run on the pages tagged with the defect they address, not on all pages.
- **Neither: framing and material.** A neighbour in frame is a scoping question for the pipeline (crop to the page
  quad, or keep the neighbour and label it), not a repair; show-through is the document.

So the capture-time check is justified for a short list, and the design the field converged on is a frame
classifier with named events, not a quality score (claims 24-25; the scorers fail off their training grid, claim
22, and VLM judges fail, claim 20). For our companions, which today set nothing and check nothing (claim 37), the
list is:

1. **Blur**, measured as a focus statistic inside detected text regions, not over the frame (claim 42 is the
   warning), calibrated on our pages by test 4; shown as a warning with a one-tap retake, never as a block.
2. **Framing**: the page quad from `VNDetectDocumentSegmentationRequest` on the live frame; warn when a quad edge
   touches the frame edge (content cut) and when a second large quad or text mass sits inside the frame
   (neighbour). This is the defect that cost our typed pages.
3. **Exposure**: share of clipped highlights inside the quad (glare), mean luminance (low light, which becomes
   blur because the shutter lengthens without flash, claim 36). Lock exposure and white balance on the page as
   DocScan does (claim 25).
4. **Settings**: set `flashMode = .off` and `FLASH_MODE_OFF` explicitly, since reading rooms forbid flash and the
   iOS default is unverified (claim 38); on Android set `CAPTURE_MODE_MAXIMIZE_QUALITY` (which waits for focus and
   exposure to settle before the shot [?, forum]) or JPEG 95-100 explicitly rather than inherit a forum-reported
   default; on iOS raise `photoQualityPrioritization` from the default `.balanced` to `.quality` where the device
   allows [M WWDC21 for the default; the gain for document shots is unmeasured].
5. **Never auto-process.** VisionKit's document camera and the scanner apps return a perspective-corrected,
   enhanced image and do not expose the original [?]; our companions keep the raw JPEG, which the owner's rule
   requires. Dewarping and crop happen on the Mac, optionally, with the backward map kept (D).

The Mac side then repairs by route and by tag: quad crop and perspective for everyone (edge-loss count reported, D
test 1), dewarp and deshadow only ahead of the laptop and pipeline readers and only on tagged pages, nothing ahead
of the frontier readers except the resolution cap. Blur-tagged pages go to the handwriting-style fallback F already
has (text page, escalation), because no reader will recover them.

### 6.3 What the measured evidence says about resolution and compression for VLM OCR

- Resolution: measured by us and explained by the field (section 5). The working figures: half of 2400 px costs
  under two points for most readers; a quarter costs 25-40 for the Qwen and Mistral classes, 27 for Vision, 6 for
  Gemini Flash-Lite and 4 for gemma4-31b (claim 45); the fall is per page and follows text per token, not
  text height (claims 15-16, 46). Our effective sampling: a letter page at 2400 px is about 218 ppi, an iPad photo
  at 2592 px about 236 ppi, a Pixel photo 371 ppi before the cap [I from claim 40]. FADGI's floors for text
  documents are commonly quoted as 300 ppi at three stars and 400 at four [?, vendor pages]; the app's 2048 px cap
  is about 186 ppi on a letter page [I], under every such floor, and the measured loss at half resolution says the
  readers do not care, which is the point of measuring rather than following the guideline.
- Compression: no measured effect worth the name on general VLMs (0.2-0.6 pp at ImageNet-C's worst JPEG, claims
  10, 14); nothing measured on a document reader; nothing on the 0.85-versus-0.90 question. PureDocBench's Real track
  folds "social-media compression" into one chain and does not separate it (claim 1). Expectation nil; test 5
  confirms at no cost on the open routes.
- Resampling: the one surprising figure is VLM-RobustBench's upsampling, up to 34 points on general tasks (claim
  14). We never upscale (claim 39), and should not start.

### 6.4 Do public camera-captured sets resemble archival reading-room photographs, and which to borrow

None does. The closest on each axis: SmartDoc-QA for paper (old administrative letters, with the blur, light and
angle of every image recorded; CC BY 4.0); Real5 for conditions (five physical conditions on the same pages, 20
published rows; images Apache-2.0); DocPTBench for the unwarping arm; Brno for scale and handheld realism (23
devices, unrestricted conditions; non-commercial, scientific papers); GNHK for camera-captured handwriting (notes
and lists, CC BY 4.0); SD7K for shadows (copy stand, not a phone; no OCR). None has pages lying in boxes with
neighbours, folder labels, show-through, stamps or marginalia, and none photographs 20th-century typescript. Borrow
Real5 (E), SmartDoc-QA's letters (test 7), Augraphy and OCR-Robust's metrics (test 3), Q-Doc's protocol (test 8),
and Adobe's attribute list as our tag schema (test 1). Do not borrow Brno (licence, content), MIDV, WildReceipt,
CDLA (not capture sets), or SD7K beyond citing it.

The 895 public pages are scans and renders throughout: By the People, Bentham, the Freedmen's Bureau, HTR-United,
Königsfelden, OCR-D, NewsBench, Muharaf, Digital Peter, EPARCHOS, BiblIA, heiDATA are digitisation projects, and
OmniDocBench's pages are PDF renders with a few photographed figures [I from the README's source list; the manifest
has no capture field]. So on the 895 every capture test is a synthetic one, and the both-sets rule means each
synthetic variant run there also runs on the 96 in the same item.

### 6.5 A small set of our own capture-defect tests

Section 7 ranks them. The two that make the rest possible are the defect tagging of the 96 originals (an hour of
looking, no calls) and the synthetic degradation ladder (both sets, open routes free), because every other
question here is "by defect" and we have no defect labels.

## 7. Tests to run on our material, ranked

Prices use the measured $0.0042 a page for Gemini 3.8 Flash on the 440 (C). Open readers run on Sherlock or
FarmShare at the throughputs already measured; Apple Vision and the small models on the Mac. The both-sets rule
applies: a variant run on the 895 is run on the 96 in the same item, the 96 first.

1. **Defect tags for the 96 and the ladder pages.** Profiles: all (it is the labelling every other test needs). A
   per-page sheet with Adobe's attributes extended for our material: neighbour or label in frame, edge cut, hand
   in frame, perspective over about 5 degrees, curl, shadow across text, glare patch, low light, motion blur,
   defocus, colour cast or coloured paper, show-through, faint ink, mixed kinds. A subagent drafts from the
   images, the owner spot-checks 20 pages (about 20 minutes; an owner review session, so judge the timing). Then
   recompute every saved route's NES by tag with no new calls, and report the per-tag loss against untagged pages
   of the same kind. Expected from the six pages already seen: framing and show-through dominate, optics do not.
   Free.
2. **Synthetic degradation ladder, both sets.** Profiles: laptop, cheap API, cluster. On the 96 originals and the
   895: Augraphy ShadowCast, LightingGradient, ReflectedLight, LowLightNoise, Jpeg (q 60 / 75 / 85) and OpenCV motion
   blur (kernels 9 / 17 / 31 px at 2400 px), defocus (sigma 1.5 / 3 / 5), perspective (5 / 12 / 20 degrees), three
   severities each; readers Apple Vision, GLM-OCR on DocLayout-YOLO regions, LightOnOCR-3 4B, Qwen3.6-27B. Score
   NES and OCR-Robust's RCR / WCR per reader per defect, plus the loop rate (C: loops are a difficulty signal).
   Paid arm: Gemini 3.8 Flash on 48 of the 96 at the worst severity of each of 8 defects, about $1.60. Output: the
   loss curves that set the companion's warning thresholds and tell each route which repairs pay. Free on the
   cluster; the Mac for Vision.
3. **Capture-time signals against the loss.** Profile: laptop and the companions. On the 96 originals and test 2's
   images, compute what a phone can compute live: Laplacian variance and Tenengrad inside Vision text boxes (not
   the frame), clipped-highlight share inside the page quad, mean luminance, quad-to-frame margin and second-quad
   presence from `DetectDocumentSegmentationRequest`. AUC of each against a 5-point loss for the route in question;
   choose thresholds per reader class. Decides what the companions warn about and at what level. Free, Mac.
4. **Framing: quad crop against raw.** Profiles: all. On the 67 originals, Apple quad plus perspective versus raw,
   for the saved-route readers, with D's edge-loss count; separately, a hand crop to the page for the six worst
   pages to measure how much of their loss is scope. Joins D's test 1 (its "Apple quad" arm) rather than
   duplicating it; this strand adds the hypothesis and the six pages. Paid: 67 pages for Gemini 3.8 Flash, about
   $0.30; free for open readers and Vision.
5. **The app's actual encoding.** Profiles: all. The 96 at 2048 px / q 0.85 (the app), 2400 / 90 (the bench), 1600 /
   90 (the segmentation window) through Vision, Qwen3.6-27B and LightOnOCR-3 4B; paid arm Gemini 3.8 Flash, about
   $0.80 for two extra settings. Settles whether `maxOCRDimension` and 0.85 cost anything and whether the bench's
   figures describe the app.
6. **Repair by tag (with D).** Profiles: laptop, cluster. D's dewarp and deshadow arms run only on pages test 1 tags
   with curl / perspective and shadow / low light, scored against the same pages raw, reader by reader; the
   expectation from claims 6-8 and 28 is gains for Vision and PP-OCRv6, none for Gemini and the 27B. Free.
7. **SmartDoc-QA's old letters as a controlled anchor.** Profile: cluster. The letters subset (CC BY 4.0, inside the
   13.7 GB) through Vision, GLM-OCR regions and Qwen3.6-27B, scored against its transcriptions and grouped by the
   recorded blur, light and angle parameters. Gives blur-and-light curves on historical-looking paper with
   controlled parameters, which we cannot shoot ourselves on archive material; and a public figure beside test 2's
   synthetic curves to say whether Augraphy's degradations are the right strength. Free.
8. **Reader self-report of quality (Q-Doc redone with our readers).** Profiles: cheap and premium API. Ask Gemini
   3.8 Flash and Qwen3.6-27B for a quality verdict and a defect list per page on the 96 originals and test 2's
   images; compare with test 1's tags and with the measured loss. If a 2026 model does what the 2024-25 models could
   not, the app can flag doubtful pages without a second model. About $0.40 for Gemini on the 96; Qwen free.
9. **Segmentation under capture defects.** Profiles: all; coding-agent kit. The feature model and the 2B student
   on a development box's windows after test 2's shadow, perspective and blur at one severity; page-pair accuracy
   against the clean run. No source measures this; the expectation is a small loss for the student and none for
   the rule features [I]. Free.
10. **A real re-capture series on stand-ins.** Profile: laptop; owner time. Twenty printed pages of public-domain
    scans (typed, printed, a form, a hand) photographed by the owner five ways with the companion: on a stand,
    handheld, handheld dim, with a hand shadow, under a desk lamp on glossy stock; about 40 minutes. Truth is the
    scan's text. The only way to get real motion blur and glare with known truth; low in the ranking because tests
    2 and 7 give most of the curve without the session, and the owner-review timing rule applies.

## 8. Open questions

1. PureDocBench's degradation parameters (Appendix F) and its data licence were not in the HTML; the GitHub
   repository would settle both before its tools are borrowed.
2. SmartDoc-QA's device and count details come from search snippets; the Zenodo record confirms the licence and the
   three document types but not the numbers.
3. Whether VisionKit's document camera exposes the uncorrected capture; Apple's page did not render. Relevant only
   if a user brings scanner-app output rather than our companion's photographs.
4. CameraX's default capture mode and JPEG quality (95, MINIMIZE_LATENCY per forum posts) and AVCapturePhotoSettings'
   default flash mode: both should be read from the reference pages or tested on a device before the companions set
   them explicitly.
5. FADGI's ppi floors by material and star level were not read from the 3rd-edition PDF.
6. Whether the owner's "PDF image" pages differ in material from the phone originals enough to explain claim 41's
   gap; test 4's hand crops and test 1's tags will say.
7. Whether any of the 895's strata carry a capture field in their source metadata; the manifest has none, and the
   scan-not-photo conclusion is an inference from the sources' nature.
8. Glare has no measured OCR effect anywhere; test 10 is the only route to one.
9. Whether `DetectDocumentSegmentationRequest` finds the page quad on cluttered box photographs with neighbours and
   labels (D's open question 7); test 3 measures it as a by-product.

## 9. Route table

| Route | Best candidate(s) for capture handling | Evidence | Licence on this route | Settling test |
|---|---|---|---|---|
| R1 Mac built-in (Vision, Core ML) | `DetectDocumentSegmentationRequest` quad for framing checks and the perspective crop; Vision text boxes as the region for a focus statistic; Core Image histogram for clipped highlights and luminance; on iOS the same via `VNDetectDocumentSegmentationRequest` in the companion; no repair beyond crop | Vision is the most capture-fragile reader we have (quarter rung 52.7, p094 2 of 17 lines; claims 44-45); shadow removal's large Tesseract gains (claim 28) predict gains for Vision; nothing measured on our pages yet | system | 3, 4, 6 |
| R2 Mac open weights (16 / 32 / 64 GB+) | UVDoc or DocRes dewarp (MIT) and DocRes deshadow or classical shading division (D) ahead of GLM-OCR-on-regions, LightOnOCR-3 4B or PP-OCRv6, on tagged pages only; nothing ahead of Qwen3.6-27B; Augraphy (MIT) for the kit's robustness tests | LightOnOCR-3 4B shows the largest photo penalty among our routes (+8.2, claim 41); pipelines lose 11-47 on light and pose and recover most on unwarping (claims 6, 8); 27B-class loses 0-2 on Real5 conditions but 11 on PureDocBench's Real track (claim 3) | MIT (DocRes, UVDoc, Augraphy); Apache-2.0 readers | 2, 5, 6 |
| R3 cheap API (OpenRouter) | send the raw photo at the bench's 2400 / 90 after the Mac's quad crop; no repair; Qwen3-VL-235B as the robust pick (Real5 skew 86.56), Qwen3.6-27B second | Qwen3-VL-235B 86.6-90.0 across five conditions (claim 6); Qwen3.6-27B 70.20 to 59.18 clean-to-real (claim 3); Gemini 3.5 Flash-Lite +3.3 photo penalty (claim 41) | API terms | 2 (open-model arms), 5 |
| R4 premium API (Gemini, Claude, OpenAI, Mistral; batch) | raw photo, quad crop only; blur pages flagged for the text-page fallback or a second reader rather than repaired | Gemini-3 Pro 88.86-89.53 across all five conditions (claim 6); Gemini 3.6 Flash 79.97 / 75.73 clean / real and Claude Opus 5 82.99 / 75.27 (claim 3); our +2.8 to +4.1 photo penalty for the Gemini and Claude routes on typed pages (claim 41); glass and motion blur the residual (claims 9, 13) | provider terms | 2 (paid arm), 4, 8 |
| R5 subscriptions via a local agent CLI | as R4; the CLI's own image downscaling is unknown and may undercut the 2400 px cap | no capture figure for the plan route; the resolution curve (claims 15, 45) says the CLI's resize is the risk | plan terms | 5 run through the CLI |
| R6 commercial document services | none recommended for capture; Azure DI Read's limits (10,000 px, text at least 12 px on 1024x768) and Transkribus's DocScan guidance are the only capture-related facts found; no Document AI, Textract or Extend figure on photographed robustness (search: "Document AI Textract photographed document skew shadow accuracy" returned marketing pages) | F claim on Azure limits [M]; DocScan (claim 25) | vendor terms | none planned under the paid-run hold |
| R7 cluster (Sherlock, FarmShare) | the synthetic ladder over 895 + 96 (Augraphy + OpenCV); SmartDoc-QA letters as the anchor; FSENet (29 M params, 7.9 s a page) and DvD (AGPL) as research comparisons for shadow and curl repair; OCR-Robust's metrics | claims 15, 26, 28, 31-32; nothing on archival photographs anywhere | MIT / unstated (SD7K) / AGPL (DvD) / CC BY 4.0 (SmartDoc-QA), acceptable in a user's own kit as research tools | 2, 6, 7, 9 |
| R8 hybrids | companion warns at capture on blur, framing and exposure (events, not a score) and keeps the raw JPEG; Mac crops to the quad for every route and reports edge loss; dewarp and deshadow only ahead of laptop and pipeline readers on tagged pages; frontier readers get the raw crop; blur-tagged pages skip repair and go to F's text-page fallback or the cascade; tags travel with the page so the run report can say why a page read badly | claims 20-25 (what works at capture), 6-9 and 28 (repair by route), 41-44 (our own losses); the routing design mirrors D §6.2 and F §6.7 | mixed, as above | 1 and 3 define the warnings; 2, 4 and 6 define the repair gate |
