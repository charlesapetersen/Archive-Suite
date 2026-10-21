# Strand D deep read: enhancement, dewarping, deskewing, binarisation, marks

Written 2026-10-20 from full reads of the sources named below. Tags: [M] measured or stated in the source at the
location given; [I] my inference from a source; [?] not verified. "Code read" means the file itself was read, not
the README. Screen: `D-screen.md`; mapping question shared with `F-screen.md`.

Reads swapped against the screen's shortlist, and why:
- Added DocRes's and UVDoc's inference code (`inference.py`, `demo.py`, `utils.py`) in place of a second reading of
  the UVDoc paper. The code answers the grid, cropping and device questions the papers do not.
- Added the Rényi Space's `app.py` and `die_model.py` and the weights repository, because the owner's starting
  point was that model. Result: the weights are gated and the degradation generator is private (below).
- Added a catalogue of every "Rényi-like" restorer with public weights (owner's request, section 7), which meant
  reading twelve repositories and licence files rather than papers.
- Dropped the eScriptorium study (D32) to abstract level: the full text is behind HAL's bot wall and the journal PDF
  is over 10 MB. Its one finding stands [M abstract]; its figures are [?].
- Dropped the DocEng photographed-binarisation reports (D30, D31) to the organisers' page: the ACM pages are
  paywalled and the dataset host's certificate has expired. Kept as a lead, not a result.
- Kept TeleOCR but demoted it: its dewarping claim has no numbers anywhere in the paper (section 6.3).

## 1. Question

Which image changes to a photographed archival page are safe for the reading copy (geometry and contrast only,
nothing removed), which may feed OCR only, whether any of them improves a modern vision-language reader at all,
how to catch text that enhancement invents, how to keep and transcribe marks, and whether the Rényi DIE model is
anything we could use.

## 2. What the field does now

Dewarping is a solved-looking problem on its own benchmarks and an unsolved one on ours. Every current dewarper
(UVDoc, DocTr++, DocGeoNet, DocScanner, DvD, D2Dewarp, AADD, DocRes's dewarp task) predicts a backward mapping, a
grid of input coordinates for each output pixel, and resamples the photograph through it; none paints pixels. They
are trained on Doc3D (100k synthetic renders) plus small real sets, and scored on DocUNet (130 photos), DIR300 (300)
and the UVDoc benchmark (50) with MS-SSIM, local distortion (LD), aligned distortion (AD) and Tesseract CER. The
2025 papers (DvD, AADD) add a reader-based metric: run Qwen2.5-VL on the dewarped and the flat image and compare
transcripts (DvD's MMCER), or a text-line alignment metric (AADD's AAD). Those benchmarks are of whole, flat-lay,
modern printed pages photographed under strong curl; none is of archival paper in a box.

Appearance enhancement, deshadowing, deblurring and binarisation have converged on one generalist: DocRes (CVPR
2024, MIT) does five tasks with one 15.2M-parameter Restormer and a task prompt. Diffusion restorers (DocDiff,
NAF-DPM, PreP-OCR's ResShift, Uni-DocDiff, TAIR) are the 2023-2025 wave; "handwriting removal" and "seal removal"
appear in them as named tasks, which is exactly what the owner's rule forbids for the reading copy. The field
measures restoration with PSNR and SSIM against a clean target; OCR gain is measured, when at all, with Tesseract.
The only paper found that measures a frontier VLM before and after restoration (PreP-OCR) finds the VLM gains almost
nothing while Tesseract halves its error.

Marks are treated as three separate tasks with separate datasets: printed-versus-handwritten pixel separation
(SignaTR6K, legal documents), signature and stamp detection (Tobacco800, SignverOD, AnnoPage), and marginalia
detection on early books (Uppsala). No dataset pairs 20th-century typed pages with handwritten annotations and phone
distortion, and no paper tests a general VLM at finding marks with boxes.

## 3. Claims table

| Source | Claim | Figure | Conditions | Tag | Location |
|---|---|---|---|---|---|
| UVDoc (arXiv 2302.02887v2) | Network predicts a 45x31 2D grid and a 45x31 3D grid from a 488x712 input; the 2D grid is bilinearly interpolated to the original size and the original is sampled through it | 8M params | Images "tightly cropped" before input; assumes whole document visible | [M] | Sec. 4, Table 2, App. B |
| UVDoc code (`utils.py`) | Unwarp = `F.interpolate(point_positions, size=(W,H), bilinear, align_corners=True)` then `F.grid_sample(warped_img, grid, align_corners=True)`; `IMG_SIZE=[488,712]`, `GRID_SIZE=[45,31]` | n/a | Default bilinear sampling, default padding | [M] | `utils.py` `bilinear_unwarping` |
| UVDoc code (`demo.py`) | The model returns `point_positions2D` (the grid) as its first output; demo discards the second output and never saves the grid; the full-resolution original is what gets resampled | n/a | | [M] | `demo.py` |
| UVDoc paper | DocUNet: MS-SSIM 0.544, LD 6.83, AD 0.315, CER 0.172, ED 707 with Tesseract 4.0.0 | | DocUNet, document 64 excluded | [M] | Table 2, Sec. 6.1 |
| UVDoc README erratum | Paper's UVDoc-benchmark MS-SSIM and AD used half the benchmark; corrected full-benchmark values: UVDoc 0.785 / 0.119 (was 0.784 / 0.122), DocGeoNet 0.706 / 0.168, DocTr 0.697 / 0.160 | | 50-image UVDoc benchmark | [M] | README "Erratum" |
| PaddleOCR issue 15717 | `use_doc_unwarping=True` (UVDoc) cut off content near the edges including edge text; maintainers: after correction "only the corrected region" remains, turn unwarping off to keep the full image; closed without a fix 2025-09-09 | | PaddleOCR doc_preprocessor | [M] | issue thread |
| PaddlePaddle/UVDoc card | Apache-2.0; exposes a corrected image only; CER 0.179 on DocUNet | | | [M] | model card |
| DvD (arXiv 2505.21975) | Diffuses a 64x64 coordinate map, upsampled to full resolution; the map is a backward mapping with two coordinate channels; a dense spatial transform samples the input | 151.25M params | 3 denoising steps | [M] | Sec. 3.1, 3.4.2 |
| DvD | DocUNet Table 2: warped input MS-SSIM 0.246, LD 20.51, AD 1.026, CER 0.595, MMCER 0.576; DvD 0.549 / 6.61 / 0.279 / 0.366 / 0.215; UVDoc 0.544 / 6.83 / 0.315 / 0.384 / 0.402; PaperEdge MMCER 0.198 | | CER with an unnamed off-the-shelf OCR; MMCER with Qwen2.5-VL 7B prompted "OCR the plain text" | [M] | Table 2, Sec. 4 |
| DvD | 0.59 s per image at 3 steps; 1 step 0.21 s but AD 0.501; 50 steps worse (AD 0.467) | | Hardware not named | [M] | Table 5 |
| DvD | AnyPhotoDoc6300: 6,300 real pairs across 8 layouts, 3 lightings, 2 angles; warps are curves, folds, crumples | | Capture details deferred to App. E, absent from the HTML | [M] | Table 1, Sec. 4.1 |
| DvD repo | AGPL-3.0; weights on Google Drive (`model1852000.pt`, `line_model2.pth`, `seg.pth`, `seg_model.pth`); dataset on HF gated, licence gpl-3.0, 10.5 GB, empty card | | | [M] | GitHub API, HF dataset page |
| DocRes (arXiv 2405.04408v1) | One Restormer, 15.2M params, 183 GFLOPs; five tasks; DTSPrompt per task (dewarp: mask, x-map, y-map; deshadow: background; appearance: 255 minus image-minus-background; deblur: gradient; binarise: Sauvola result, threshold map, gradient) | | Trained at 256x256; Restormer accepts up to 1600x1600 | [M] | Sec. 3, 4 |
| DocRes | DIR300 dewarp MS-SSIM 0.6264, LD 6.83, AD 0.241 (DocGeoNet higher on MS-SSIM and LD in the same table); RealDAE appearance SSIM 0.9219 / PSNR 24.65; DIBCO'18 FM 89.82 | | | [M] | Table 1 |
| DocRes code (`inference.py`) | Dewarp: input resized to 256x256, first two output channels plus a base coordinate grid form a normalised backward map, 15 passes of 3x3 blur, `cv2.resize` to (w,h), `cv2.remap(im_org, ...)` on the original image; map not saved | | | [M] | `dewarping()` |
| DocRes code | Deshadow and appearance: 6-channel input (RGB + 3-channel prompt), 3-channel output used directly as the image when max side < 1600; above that, the image is resized to 1600x1600 (aspect ignored), and the output is reconstructed as `im_org / (resize(im_org)/pred)`; no tiling | | | [M] | `deshadowing()`, `appearance()` |
| DocRes code | `DEVICE = cuda if available else cpu`, but `model_init` loads with `map_location='cuda:0'` in one branch | | A one-line patch for CPU/MPS | [M] | `__main__`, `model_init` |
| GCDRNet code (`infer.py`) | GC-Net predicts a shadow map, upsampled, `model1_im = clamp(im_org/shadow, 0, 1)`; DR-Net takes `cat(im_org, model1_im)` and its prediction is the output image directly; `.cuda()` hard-coded; a 512 resize is overwritten by `im = im_org`, so the native padded size is processed | | MIT; weights on OneDrive; RealDAE 600 pairs | [M] | `infer.py` |
| DocTr++, DocGeoNet, DocScanner repos | `LICENSE.md` is a custom licence (Hao Feng, 2024): non-commercial only; "Any Commercial Use of the Algorithm is strictly prohibited without explicit prior written permission from the Author"; share-alike | | Inference writes rectified images only | [M] | each repo's `LICENSE.md` §2.2, 3.2 |
| DocScanner | DocScanner-T 2.6M, B 5.2M, L 8.5M params; only L weights released | | | [M] | README |
| DewarpNet | MIT; LiteRT port outputs a `[1,2,128,128]` backward map from a 256x256 input, host blurs, resizes and `grid_sample`s the original; 189 MB; 22.6 ms in-browser on an M4 Max via WebGPU | | Trained on Doc3D | [M] | GitHub API; HF card litert-community/DewarpNet-LiteRT |
| AADD (arXiv 2507.15000) | AAD metric: SIFT-flow from ground truth to dewarped image, Sobel gradients, gradient-weighted row and column flow deviations, averaged; needs the flat ground truth | | Reference-based | [M] | Sec. 3 |
| AADD repo | Apache-2.0 badge; "full code and models will be released after the final camera-ready"; README only | | | [M] | README |
| ForCenNet repo | README and assets only; no code, weights or licence | | | [M] | repo listing |
| TeleOCR (arXiv 2608.12898v3) | "eliminating geometric distortions alone substantially improves the performance of two-stage parsing models"; "End-to-end methods are generally more robust to geometric distortions" | none | No table, figure or number anywhere in the paper supports either sentence | [M] that the claim is unsupported | Intro, Sec. 3.2; all captions listed |
| TeleOCR | TeleOCR 1.2B: clean 86.90, digital-degraded 77.47, real-degraded 70.85 overall | | PureDocBench protocol; 7 looping outputs removed before scoring | [M] | Table 3, App. |
| TeleOCR | Wild-OmniDocBench overall: OvisOCR2 87.91 (end-to-end), PaddleOCR-VL-1.6 87.36, MinerU2.5-Pro 87.33, GLM-OCR 85.08 (decoupled); dots.ocr 81.84 | | Built on OmniDocBench v1.5 by printing, deforming and photographing | [M] | Table 2, Sec. 5.2 |
| PreP-OCR (arXiv 2505.20429, ACL 2025) | English CER raw / restored / restored+ByT5: Tesseract 5.91 / 2.81 / 2.00; GOT 11.18 / 7.11 / 6.65; GPT-4o 6.51 / 6.06 / 6.57 | | 9,606 English pages of 15th-19th c. books, scanned PDFs from Open Library, truth from Project Gutenberg aligned with RETAS; parentheses exclude pages over 25% CER | [M] | Table 4, Sec. 4.1, 5.4 |
| PreP-OCR | Restoration = ResShift on 256x256 patches, stride 128, four scan directions, 64 px border discarded, pixel-wise median fusion; median "suppresses outlier predictions caused by artifacts and stochastic noise" | | | [M] | Sec. 4.3 |
| PreP-OCR | GPT-4o's "contextually plausible but factually incorrect hallucinations" evade post-correction; Tesseract errors "locally contained and statistically predictable" | | temperature 0 | [M] | Sec. 5.4, App. C |
| PreP-OCR repo | No licence file; `resshift_deblur_prep_ocr.pth` (457 MB) on HF; ByT5 corrector not released; built on ResShift, which is under NTU S-Lab License 1.0 | | | [M] | README; ResShift README |
| TAIR (arXiv 2506.09993) | "text-image hallucination": diffusion restorers "generate plausible but incorrect text-like patterns"; SA-Text Level 2 with TESTR: DiffBIR detection F1 61.82, recognition None 21.64; TeReDiff 65.75 / 26.39 | | Scene text crops 512x512; no reference-free detector proposed | [M] | Abstract, Table 2, Sec. 5.1 |
| TAIR repo | Apache-2.0; TeReDiff checkpoint on Google Drive; SA-Text on HF | | | [M] | README |
| KIE-HVQA (arXiv 2506.20168v2) | OCR hallucination benchmark on degraded documents (blur, occlusion, low contrast); scores clear and not-clear characters separately; GPT-4o avg 30.21, Gemini 2.5 Pro 35.03, their 7B 58.05 | | "hallucination-free accuracy" never defined; reward weights not given | [M] | Table 1, Alg. 1 |
| Rényi blog (2024-11-22) | U-Net with skip connections trained on a synthetic generator of "over 30" noise types; removes scribbles, bleed-through, blurring, background patterns, restores faded text; one severely damaged page: Gemini/Lens CER 23-25% before, 5-6% after | one page | No paper, no page count, no engine named for the 5-6% | [M] | blog post |
| Rényi Space code | `app.py`: `hf_hub_download('gabar92/die', '2024_08_09_model_epoch_89.pt')` with a `DIE_TOKEN` secret; `die_model.py`: 4-level U-Net, 64-1024 channels, 4 input channels (RGB + previous prediction), 1 sigmoid output channel; input resized to 1500 and padded square; Gaussian noise std 0.05 added before each pass; 1-3 iterations | | `huggingface.co/gabar92/die` returns 401; the generator Space's README says generation logic "loaded at runtime from a private repository" | [M] | `app.py`, `die_model.py`, READMEs |
| SignaTR6K (arXiv 2307.07887) | 5,169 / 530 / 558 crops of 256x256 from 200 legal documents; pixel labels for printed, handwritten, overlap; best mean IoU 89.10 (printed 73.05, handwritten 94.89) vs prior 83.02 | | Overlap pixels counted in both classes; augmented test set; dataset by form; no code | [M] | Sec. 3, Table 3 |
| Marginalia (arXiv 2303.05929) | 513 labelled pages (Uppsala early books, 1400s on), boxes only; Faster R-CNN IoU 0.82; AttentionHTR applied without fine-tuning, no CER reported | | Apache-2.0 code; weights and data on Google Drive | [M] | Sec. 4-5; repo |
| AnnoPage (arXiv 2503.22526) | 7,550 pages, 27,904 boxes, 25 classes including "Handwritten inscription" (marginalia, glosses, provenance notes) and "Stamp"; YOLO11m mAP50 0.658 / mAP50-95 0.598 at 1024 px; CC BY 4.0 on Zenodo (5.0 GB, v1.1.0, 2025-11-05) | | Czech and German print, 1485 to present, mostly 1880-1950; axis-aligned boxes | [M] | Sec. 3, Table 1-2; Zenodo record |
| SignverOD | 2,765 images, 8,022 boxes: signature 4,551, redaction 1,912, initials 989, date 570; CC0; from Tobacco800, NIST SD2, cheques, GSA leases | | | [M] | datasetninja page |
| tech4humans YOLOv8s signature detector | mAP50 94.5, precision 94.7, recall 89.7 on Tobacco800 + signatures-xc8up (2,819 images); ONNX CPU 172 ms; weights AGPL-3.0, code Apache-2.0 | | 640 px input | [M] | model card |
| Apple Vision | `DetectDocumentSegmentationRequest` (macOS 15+) returns a `DetectedDocumentObservation` with the four corner points and a segmentation mask; `VNDetectDocumentSegmentationRequest` (macOS 12+) returns `VNRectangleObservation` | | Corners only; no curvature | [M] | Apple doc JSON |
| Apple Vision | `RecognizeDocumentsRequest` (macOS 26) returns containers (text, paragraphs, lines, words, tables, lists) each with a `boundingRegion: NormalizedRegion`, a polygon of normalised points; no rectification step is described | | | [M] | WWDC25 272 transcript; doc JSON |
| eScriptorium study (JDMDH 2023) | On 19th-century Spanish prints with Kraken, "binarisation methods give better results than the other", and combining techniques "did not significantly improve" prediction | none read | Full text unreachable (HAL bot wall, PDF > 10 MB) | [M] abstract only; figures [?] | abstract |
| DocEng photographed binarisation (2024-2026 editions) | Phone photographs of offset, laser and inkjet prints, flash on/off/auto; ground truth is the AND of two top algorithms, hand-corrected; ranked by PSNR, file size, time; no OCR | | Dataset at dib.cin.ufpe.br (certificate expired); 2024 report: 23 new and 75 classical algorithms | [M] organisers' page; dataset terms [?] | doceng2026 page; search |
| Our measurements (`ocr-panel-local.md`) | Quarter-resolution ladder (20 pages): Qwen3.5 27B 58.27, Qwen3.6 27B 71.70, Qwen3-VL 8B 66.74, Gemma4 31B 86.02, Gemini 3.1 Flash-Lite 89.74, Apple Vision 52.69 NES; half resolution costs most models under two points | | Ladder images are fractions of the native source, each capped at 2400 px | [M] | lines 17, 63-118; `W41-answers.md` 60, 133 |
| Our measurements (`kind-classifier.md`) | 7 of 20 quarter-rung pages and 1 half-rung page read at least 10 points worse than their originals for Qwen3.6 27B; the fall is page by page | | | [M] | line 53 |
| Our measurements (`ocr-truth.md`) | 100 truth pages: 67 from original photos; 12 handwritten, 2 mixed; 416 disputed spans, 3% of words | | Drafted by Claude and Gemini | [M] | tables |

## 4. Code, weights, data and licences

Dewarpers, by whether we could ship them.

| Method | Code | Weights | Licence | Outputs a map we can keep | Mac | Verdict |
|---|---|---|---|---|---|---|
| UVDoc | GitHub, `demo.py` | `model/best_model.pkl` in repo, 8M params | MIT [M] | Yes: `point_positions2D` is the backward grid; export is a one-line change [M code] | PyTorch, `grid_sample`; CPU fine at this size [I]; `torch.load` without `map_location` may need one [I] | Ship candidate |
| PaddleOCR UVDoc | PaddleOCR | HF | Apache-2.0 [M] | No, image only [M card]; crops edges [M issue] | Paddle on Mac is awkward [?] | Use the original instead |
| DocRes dewarp | GitHub `inference.py` | `docres.pkl`, `mbd.pkl` on OneDrive | MIT [M API] | Map exists in `pred` before `cv2.remap`; one line to save [M code] | Needs the `map_location` patch; 15.2M Restormer at 256x256 for dewarp is cheap [I] | Ship candidate |
| DewarpNet | GitHub; LiteRT port on HF | Yes (Doc3D-trained) | MIT [M] | Yes, `[1,2,128,128]` backward map [M card] | LiteRT runs on CPU/WebGPU; CoreML conversion plausible [I] | Baseline; older, 86.9M params |
| DvD | GitHub `run_sampling.py` | Google Drive, four checkpoints | AGPL-3.0 code [M]; dataset gpl-3.0, gated [M] | Yes, M0 is a full-resolution backward map [M paper] | 151M params, 3 steps, 0.59 s on an unnamed GPU; MPS feasibility [?] | Research comparison only; AGPL blocks bundling in the app |
| DocTr++, DocGeoNet, DocScanner | GitHub | Google Drive | Custom non-commercial, written permission for any commercial use [M] | Image only from the scripts [M README] | [?] | Comparison only; cannot ship |
| D2Dewarp | GitHub (no licence field, README unreadable) | [?] | none [M API] | [?] | [?] | Skip |
| AADD, ForCenNet | README only | none | n/a | n/a | n/a | Skip; AAD metric needs flat ground truth anyway |
| Apple Vision + Core Image | system | system | none needed | A homography (four corners), analytically invertible [I] | Yes | Baseline for crop and perspective; no curvature |
| DocAligner | GitHub | OneDrive | no licence file [M API] | Yes, a dense grid for clean-to-photo transfer [M README] | CuPy/CUDA correlation layer; no Mac [M README] | Cluster-only tool for label transfer, not a product path |

Restorers are catalogued in section 7.

Datasets and benchmarks we could borrow:

| Set | Licence | Size | What it gives us | Fit |
|---|---|---|---|---|
| UVDoc benchmark | code MIT; data licence not stated [M] | 50 real photos with flat truth and 2D/3D grids | Reference-based dewarp scoring; a check of our grid-export code | Modern prints, whole pages |
| DocUNet | public | 130 | The field's yardstick | Extreme curl; not archival |
| DIR300 | Google Drive, terms not stated [M] | 300 | Second yardstick | Same |
| AnyPhotoDoc6300 | gpl-3.0 (odd for data), gated [M] | 6,300 pairs, 10.5 GB | Real pairs with lighting and angle factors; the MMCER protocol | Modern documents; GPL terms for data unclear |
| RealDAE | not stated [M] | 600 pairs | Camera-captured appearance pairs | Closest appearance set to phone photos |
| AnnoPage | CC BY 4.0 [M] | 7,550 pages, 5 GB, YOLO labels | Handwritten-inscription and Stamp detectors, trainable | Czech/German print 1880-1950; the two classes we need |
| SignverOD | CC0 [M] | 2,765 | Signature, initials, redaction, date boxes | US business documents; redistributable |
| Tobacco800 | not found [?] | 1,290 | Signatures and logos on typed US documents | Nearest era; licence must be settled before use |
| SignaTR6K | by form, licence not stated [M] | 6,257 crops | Pixel-level printed/handwritten separation with overlap | Legal typescript; no code |
| DocEng photographed binarisation | [?] | per edition | Phone photos of prints with binary truth | Modern prints |
| DIBCO series | public | 10-20 per year | Binarisation truth | Scans, not photos |
| SA-Text, KIE-HVQA | not stated / HF | 100k / 400 | Hallucination test material | Scene text; ID cards and invoices |

## 5. Comparison with what we measured

What we have measured in this line is resolution and nothing else. The ladder shows that halving our 2400 px cap
costs most readers under two points and quartering it costs the Qwen family 25-40 points while Gemini Flash-Lite
holds (`ocr-panel-local.md`). Nothing published addresses that interaction, so it stays ours to own.

What the literature says that transfers:

- Dewarping is geometry-only by construction and the backward map is always there to keep. UVDoc's and DocRes's code
  prove it: the output pixel values are samples of the original photograph, and the grid is a tensor one line away
  from being saved. That settles the F-screen question of where a text layer lands: OCR the dewarped image, then
  carry each line box back to the original by reading the backward map at the box corners (no inversion is
  needed in that direction). Mapping the other way, original to dewarped, needs a scattered-data inverse of the
  grid, which is also cheap at 45x31. The OCR-D note that PAGE-XML has no field for the transform means we store
  the grid ourselves beside the page.
- The content a dewarper can lose is at the edges. UVDoc assumes a tightly cropped, fully visible document; PaddleOCR
  users lost edge text and the maintainers said the corrected region is all you get. Our box photographs show
  partial pages, neighbouring folders and hands; DocTr++ addresses partial pages but cannot be shipped. So the
  edge-loss count is the first thing any dewarp test on our pages must report.
- Dewarping helps a VLM, when the page is badly curled. DvD's Table 2 is the only place a VLM (Qwen2.5-VL 7B) is
  scored before and after dewarping: MMCER 0.576 warped to 0.215 dewarped on DocUNet. But DocUNet's pages are curled
  far beyond a page lying in a box, and the same table shows the VLM ranking dewarpers differently from Tesseract
  (PaperEdge is best for the VLM, DvD for Tesseract). Our pages are mostly flat-ish with perspective and mild curl,
  where the gain is unmeasured.
- Appearance restoration helps old engines and barely helps a frontier VLM. PreP-OCR's Table 4 is the cleanest
  evidence: on 9,606 pages of early books, restoration took Tesseract from 5.91% to 2.81% CER and GPT-4o from 6.51%
  to 6.06%, and the post-correction step made GPT-4o worse. The eScriptorium study (Kraken) agrees that binarisation
  helped most and stacking methods did not. TeleOCR's claim that dewarping helps staged pipelines more than
  end-to-end VLMs has no number behind it in the paper; the only distortion figures there are TeleOCR's own 16-point
  fall from clean to real-degraded (Table 3). Our pilot readers are Gemini 3.8 Flash and the Qwen 27B class; the
  expectation from the literature is small gains for them from appearance work and possibly real gains for Apple
  Vision and PP-OCRv6 on the Mac.
- No published metric catches invented text without a reference. TAIR names the failure and measures it with text
  spotters against truth; PreP-OCR relies on median fusion against artefacts and notes GPT-4o's hallucinations are
  not locally contained; KIE-HVQA scores unreadable characters separately. We have to build the added-words rate
  the plan already names (section 6.4).

Where a public benchmark makes our own less necessary: for ranking dewarpers against each other, the UVDoc benchmark
and DIR300 with AD and LD do that job and we should not rebuild it. For whether to dewarp at all on our material,
and for every appearance question, the public sets are modern prints or scans and the readers are Tesseract; those
need our truth set. Borrow DvD's MMCER protocol (reader-transcript CER between the processed and a reference) since
it fits our truth-set scorer directly, and AnnoPage's two classes with YOLO11 for mark detection.

## 6. Strand-specific questions

### 6.1 Classification of every candidate: geometry-only, contrast-only, content-removing

Geometry-only (output pixels are resampled input pixels; evidence is the code or the paper's definition):
UVDoc [M code], DocRes dewarp task [M code], DvD [M Sec. 3.1], DewarpNet [M LiteRT card], DocTr++, DocGeoNet,
DocScanner [I from their shared backward-map design; scripts write images only], Apple corners plus
CIPerspectiveCorrection [I: a homography]. Two caveats hold for all of them: bilinear resampling blurs thin pencil
strokes slightly, and cropping to the predicted document region can drop edge content (UVDoc's crop assumption,
PaddleOCR's issue, DvD's `seg.pth` segmentation stage [I]). Upright rotation and our downscaling belong here too.

Contrast-only by construction: none of the learned models fully. GCDRNet's first stage divides the image by a
predicted shading map, which cannot erase a mark (it rescales it), but its second stage predicts pixels directly
[M code]. DocRes's deshadow and appearance outputs are the network's three channels, not a gain field [M code]; the
division in its large-image branch reconstructs the prediction at full resolution rather than constraining it. The
only truly contrast-only operations available are classical: a shading estimate by large-kernel median or morphology
divided out (DocRes's own prompt construction does exactly this as a prompt), gamma, white balance. Those are what
the reading-copy option should use if it enhances at all.

Content-removing or content-inventing (free pixel prediction): Rényi DIE (removes scribbles by design) [M blog],
DocRes deshadow, appearance, deblur, binarise [M code], GCDRNet's DR-Net [M code], DE-GAN, DocEnTr, DocDiff, NAF-DPM,
PreP-OCR's ResShift, Uni-DocDiff (handwriting removal is a task) [M abstract], TAIR/TeReDiff (diffusion), SBB
binariser, jere1882 denoiser, GL-PGENet [?], every binariser. Diffusion models are additionally stochastic: two
runs differ, which is both the risk (invented glyphs) and the handle (section 6.4).

### 6.2 Which geometry-only dewarpers can we ship, run on a Mac, and export a grid

Shippable and grid-exporting: UVDoc (MIT, 8M params, grid is the model's first output) and DocRes's dewarp task
(MIT, map is `pred` before `cv2.remap`). DewarpNet (MIT) also qualifies but is older and 11 times larger. Apple's
document segmentation plus Core Image is free and exact for perspective but models no curvature, and is the natural
first stage: its quad gives UVDoc the tight crop it assumes.

Not shippable: DocTr++, DocGeoNet and DocScanner (custom non-commercial licence, written permission required); DvD
(AGPL-3.0; usable only as a separately distributed service or for research runs); PaddleOCR's wrapper (fine licence,
no grid, crops). Nothing has released weights for ForCenNet or AADD.

Mac: UVDoc and DocRes are small PyTorch models with standard ops and run on CPU or MPS after trivial device fixes
[I]; DvD's 151M-parameter diffusion at 3 steps is plausible on a 32 GB Mac but unmeasured [?].

### 6.3 Evidence that enhancement helps or hurts modern VLM OCR

Set out in section 5. In one line each: dewarping helped Qwen2.5-VL 7B from 0.576 to 0.215 MMCER on DocUNet's
extreme curls [M]; appearance restoration helped GPT-4o from 6.51 to 6.06 CER while halving Tesseract's error [M];
binarisation helped Kraken most and stacking gave nothing [M abstract]; TeleOCR's staged-versus-end-to-end claim is
asserted without a figure [M]. No source measures any of this on phone photographs of archival paper, on a 2025-26
frontier model, or on handwriting.

### 6.4 Measuring invented text: our metric

With ground truth (the owner's truth pages, a word sequence, whitespace-normalised as the scorer already does):

- Align OCR(enhanced) to the truth with the same word-level alignment the NES scorer uses. Count insertions (words
  with no truth counterpart) and substitutions whose output word is not within edit distance 1 of its truth word.
  Report **added-words rate** = insertions / truth words, and **rewritten-words rate** = such substitutions / truth
  words, beside NES. Do the same for OCR(raw). The enhancement's **invented-text delta** is the difference. A
  method can raise NES and raise the added-words rate at once; both are reported.
- **Restoration-only words**: words in OCR(enhanced) absent from the truth and absent from OCR(raw). These are the
  ones no reader saw before enhancement. Report their count per 1,000 words, and keep the list for reading.

Without ground truth (what the app can do on a user's page):

- **Two-reader confirmation.** OCR the raw page with the run's reader and with a reader from another family (Apple
  Vision is free on the Mac). Any word in OCR(enhanced) that neither raw reading contains is a suspect word. Report
  the suspect rate; above a threshold set on the truth pages, the page's enhanced reading is discarded in favour of
  the raw one.
- **Stability under reseeding** (diffusion restorers only). Run the restorer twice with different seeds; words that
  differ between the two enhanced OCRs are unstable and counted as suspect. This is PreP-OCR's median-fusion idea
  moved from pixels to words.
- **Mark-region check.** Inside every detected mark box (section 6.5), compare raw and enhanced pixels (mean absolute
  difference and ink-pixel count); a box whose ink count falls by more than a set share is reported as a removed
  mark. This is the test that decides whether a method may touch the reading copy.

The thresholds are set on the truth pages first, then the metric runs reference-free.

### 6.5 Detecting, separating and transcribing annotations, stamps, signatures and marginalia

Detection with boxes is the practical unit; pixel separation (SignaTR6K's method) has no code and its data is by
form. Two routes to test against each other: a YOLO11 detector fine-tuned on AnnoPage's Handwritten inscription
and Stamp classes (CC BY 4.0) plus SignverOD's signature, initials, redaction and date classes (CC0), and a general
VLM (Gemini 3.8 Flash, Qwen3.6 27B) prompted for boxes and a class per mark. The ready-made signature detector
(tech4humans, mAP50 94.5 on Tobacco800-class documents) is a free third arm but its weights are AGPL-3.0.

Separation is then a crop: each mark box becomes its own image for transcription by the handwriting reader the
guide already picks (Gemini 3.8 Flash for handwritten pages), with the box's position recorded so the transcript
sits in the text layer at its place and is labelled as a mark, not as body text. Stamps are read the same way;
signatures are detected and labelled, not transcribed.

The labelled set we need: about 150 pages, drawn not at random (the truth draw gave 2 mixed pages in 100 and the
kind-classifier draw 3 in 144) but by a VLM pre-flag over a few thousand corpus pages followed by hand selection,
across the five collections. Labels per page: a box and class for every mark (handwritten annotation, marginal
note, stamp, signature or initials, redaction, other), a transcription for each handwritten annotation and stamp
where legible, and a flag for marks overlapping printed text. PAGE-XML or YOLO text files; about 10 minutes a page
for the owner, so roughly a day of review spread over sessions. The same pages serve the mark-survival check in
6.4.

### 6.6 What the Rényi DIE model is, and whether anything open does the same job

From the blog and the Space's code: a plain 4-level U-Net (64 to 1024 channels, two 3x3 convolutions per level,
BatchNorm, ReLU), 4 input channels (RGB plus its own previous prediction, for 1 to 3 iterations), one sigmoid output
channel (grey), input resized to 1500 px and padded square, Gaussian noise of std 0.05 added before each pass.
Trained on synthetic pairs from a generator of "over 30" archival noise types (bleed-through, scribbles, fading
named). The checkpoint `2024_08_09_model_epoch_89.pt` lives in `gabar92/die`, which returns 401; the generator Space
loads its logic from a private repository. There is no paper and one page of quantitative evidence. It removes
scribbles by design, so even with weights it would be an OCR-input tool only.

Open models doing the same job (degraded-to-clean, free pixel prediction, trained on synthetic degradations):
DocRes's appearance and deshadow tasks and GCDRNet are the closest in target (camera-captured archival-looking
pages), DE-GAN and DocEnTr in architecture class (but DIBCO-trained and non-commercial), DocDiff and NAF-DPM in the
diffusion class, PreP-OCR's ResShift in training recipe (synthetic degraded book pages). Section 7 lists them.

## 7. Rényi-like restorers with public weights

"Rényi-like" here means a model that maps a degraded document image to a clean one, removing noise, stains,
bleed-through, shadows or scribbles. All of them are content-removing by construction (section 6.1) and so are
OCR-input candidates only. "OCR gain" says whether the authors measured a recogniser before and after.

| Model | Weights | Licence (read) | Tasks | Input handling | Mac | OCR gain measured | Usable as OCR-input preprocessor in our test |
|---|---|---|---|---|---|---|---|
| DocRes (CVPR 2024) | `docres.pkl`, `mbd.pkl`, OneDrive | MIT (GitHub API spdx) [M] | dewarp, deshadow, appearance, deblur, binarise, end2end | whole image, padded to a multiple of 8; above 1600 px resized to 1600x1600 | CPU/MPS after the `map_location` patch [M code] | No; PSNR/SSIM only [M] | Yes, first choice: one model, five arms, permissive |
| GCDRNet (TAI 2023) | OneDrive | MIT (sidebar, `LICENSE.txt`) [M] | appearance (illumination plus detail) | native size, padded; two UNeXt stages | CUDA hard-coded; patch `.cuda()` and `map_location` [M code] | No [M] | Yes, second choice: trained on RealDAE's real camera pairs |
| SBB binarisation (Berlin State Library) | HF `SBB/sbb_binarization` | Apache-2.0 [M] | binarisation | patches; ResNet-50 U-Net ensemble | TF-Keras on CPU [M card] | No; competition ranks only [M] | Yes, third choice: the binarisation arm, OCR-D's standard |
| NAF-DPM (2024) | Google Drive | MIT (sidebar) [M] | deblur, binarise | 256 px patches for DIBCO; diffusion, at most 20 steps; 9.4M params | PyTorch [I] | Yes: CER on the BMVC text-deblur set, via a CRNN loss and a commercial OCR for fine-tuning [M README] | Yes, as the deblur arm if our low-sharpness tertile shows a loss |
| DocDiff (ACM MM 2023) | `checksave/` deblur weights only | MIT [M] | deblur (weights); denoise, binarise, watermark and seal removal (claimed) | multiples of 8; T=100 DDIM for documents | PyTorch, 12 GB VRAM to train [M] | No [M] | Possible for deblur; seal removal is exactly what we must not ship |
| jere1882 document-image-denoising | HF, ONNX fp32 and int8 | MIT (code and weights) [M] | JPEG, blur and noise removal | 512 px tiles with 32 px overlap; 0.12M to 7.7M params | ONNX Runtime on CPU, 160 KB smallest [M] | No; PSNR [M] | Yes, as the cheap laptop arm; trained on rendered PDFs, not photos |
| PreP-OCR restoration (ACL 2025) | HF `resshift_deblur_prep_ocr.pth`, 457 MB | No licence file; base ResShift is NTU S-Lab License 1.0 (non-commercial) [M] | restoration of degraded book pages | 256 px patches, stride 128, median fusion | diffusion, [?] | Yes: Tesseract, GOT, GPT-4o CER (Table 4) [M] | Research comparison only (licence); the one model with VLM evidence |
| DE-GAN (TPAMI 2020) | Google Drive | GPL-3.0 file and "only allowed for academic research use" README, in conflict [M] | binarise, deblur, watermark removal; clean-up "will be added" | patch-based GAN, TensorFlow | [?] | No [M] | Comparison only |
| DocEnTr (ICPR 2022) | HF/Drive for 2012, 2017, 2018 | CC BY-NC 4.0 [M] | binarisation | 256 px splits, 8 or 16 px ViT patches | PyTorch [I] | No; PSNR [M] | Comparison only |
| Text-DIAE (AAAI 2023) | none ("Coming soon") | MIT [M] | recognition, enhancement | 64x256 | n/a | No | No |
| UDoc-GAN (ACM MM 2022) | Baidu Disk only | no licence file [M] | illumination correction (unpaired GAN) | [?] | [?] | Yes: Tesseract 5.0.1 ED/CER on DocUNet after DocTr/DewarpNet [M] | No (access, licence) |
| DocStormer (2023) | none | n/a | multi-degradation colour restoration | | | | No |
| GL-PGENet (2025) | none found | n/a | multi-degradation colour enhancement; SSIM 0.9480 RealDAE claimed | | | | No |
| DocShaDiffusion (2025) | "will be publicly available" | n/a | shadow removal | | | | Not yet |
| Uni-DocDiff (ACM MM 2025) | none found | n/a | six tasks incl. handwriting removal | | | | No |
| TAIR / TeReDiff (2025) | Google Drive | Apache-2.0 [M] | text-aware diffusion restoration of scene text | 512 px crops | diffusion, [?] | Yes: text-spotter F1 and recognition (Table 2) [M] | Possible, but scene text and generative; a hallucination probe rather than a preprocessor |
| Rényi DIE | gated (`gabar92/die` 401) | none stated | archival cleanup incl. scribbles | 1500 px, square-padded, 1-3 iterations | n/a | One page, CER 23-25% to 5-6% | No |
| DocGeoNet "appearance stage" | not a stage of DocGeoNet; the owner's list probably meant DocTr's illumination branch or DocRes | | | | | | n/a |

Pick to test first: DocRes (appearance and deshadow arms), GCDRNet, and the SBB binariser. DocRes and GCDRNet target
camera-captured appearance, which is our degradation; the binariser is the arm the humanities evidence says helps
older engines, so it tests whether Apple Vision and PP-OCRv6 on the Mac gain. NAF-DPM joins if the low-sharpness
tertile of the truth set shows a sharpness effect. PreP-OCR's weights are the comparison that carries the only VLM
evidence but cannot ship.

## 8. Tests to run on our material, ranked

Costs use the truth draft's measured Gemini price, $0.369 for 111 calls, about $0.0033 a page. "The truth set"
below is the owner's truth pages (100 drawn in `ocr-truth.md`, 67 of them original photographs; 96 scored by every
reader). The suite rule of 2026-10-20 applies to every test here: a model or variant run on the 895-page public set
is also run on the 96 truth pages with the same settings in the same item, and the truth pages come first. Open
readers run free on Sherlock or FarmShare with the throughput already measured; Apple Vision and the small Qwen
models run on the Mac.

1. **Dewarp or not, on the truth set.** Profiles: all. Variants per page: raw (as now), Apple quad plus perspective,
   UVDoc after the Apple crop, DocRes dewarp. Readers: Gemini 3.8 Flash (paid), Qwen3.6 27B and PP-OCRv6 (cluster),
   Apple Vision (Mac). Score NES against truth, added-words rate (6.4), and an edge-loss count (truth words whose
   Vision box on the raw image falls outside the dewarped frame). Also report the grid export and the round trip of
   20 line boxes through the backward map (pixel error), which answers F-screen test 8 at no extra cost. Free
   route: dewarpers on the Mac, open readers on the cluster. Paid: 3 extra variants x 100 pages at $0.0033,
   about $1.00.
2. **Content-removing enhancement as OCR input.** Profiles: laptop first (Apple Vision, PP-OCRv6, Qwen3-VL 8B), then
   cheap API. Variants: DocRes appearance, DocRes deshadow, GCDRNet, SBB binarisation, classical shading division
   (the contrast-only control). Same scoring as test 1 plus restoration-only words. Expectation from PreP-OCR: gains
   for Vision and PP-OCRv6, little for Gemini. Free route as above; paid: 5 variants x 100 pages, about $1.65, so
   this and test 1 are two items under the $3 rule, or test 2 runs Gemini on the 50 pages where Vision gained most.
3. **The marks set and mark detection.** Profiles: all (it is the evidence rule). Build the 150-page labelled set
   (6.5). Test a YOLO11m fine-tuned on AnnoPage's two classes plus SignverOD (cluster, free; AnnoPage is 5 GB) and a
   VLM asked for boxes (Gemini 3.8 Flash, Qwen3.6 27B); score recall and precision at IoU 0.5 per class, and the
   overlap-with-print case separately. Paid: 150 pages x 1 call, about $0.50. Then transcribe detected handwritten
   marks with the handwriting pick and score against the mark transcriptions.
4. **Mark survival under each method.** Profile: all. On the marks set, run every method from tests 1 and 2 and
   apply the mark-region check (6.4): ink loss inside each mark box. This is the test that decides which methods may
   touch the reading copy, and the expectation is that only the geometry-only and classical shading arms pass. Free.
5. **Reference-free dewarp trigger.** Profile: laptop. On the truth set, compute a text-line curvature proxy from
   Apple Vision's line quads (mean deviation of baseline from straight, per page) on the raw image, and correlate
   with the NES gain from test 1. If curvature predicts gain, the app dewarps only pages above a threshold, and the
   reading-copy option becomes "straighten when curved". Free, uses test 1's outputs.
6. **Resolution and dewarping together.** Profile: laptop and cheap API. On the 20 ladder pages, dewarp before
   downscaling to the quarter rung and re-read with Qwen3.6 27B and Gemini Flash-Lite, to see whether straight lines
   recover any of the 25-40 point quarter-rung loss (the kind-classifier note shows the fall is page by page). Free
   on the cluster; paid about $0.15.
7. **Hallucination probe with a diffusion restorer.** Profile: research. Run PreP-OCR's ResShift and NAF-DPM twice
   (two seeds) on the 30 worst-NES truth pages, read with Qwen3.6 27B, and measure the reseeding-instability rate
   and restoration-only words. This calibrates the reference-free thresholds in 6.4 on a method expected to invent.
   Free on the cluster.
8. **Rényi demo probe.** Optional, low priority since the weights cannot be used: upload five marked pages from the
   public archival corpus to the public Space (no login needed) and record what it erases. Free. It only confirms
   section 6.6's classification.

Benchmarks to run alongside, once: UVDoc's 50-page benchmark through our UVDoc and DocRes installs, scored with the
repo's AD and LD scripts (MATLAB engine needed, which may push this to the cluster), to confirm our installs
reproduce the published 0.785 / 0.119 before trusting them on our pages.

## 9. Open questions

1. The full eScriptorium figures (which binarisers, what CER) remain unread; the abstract's conclusion is enough for
   ranking but not for choosing a binariser. A browser session on HAL would settle it.
2. The DocEng photographed-binarisation data terms: the host's certificate has expired and the ACM pages are paywalled.
3. Whether DvD runs on MPS, and how long 3 steps take at 2400 px on a 32 GB Mac. Research only, given AGPL.
4. Tobacco800's licence, which decides whether the tech4humans detector's training data is clean for us even if we
   retrain under a permissive licence.
5. The UVDoc benchmark data's licence (code MIT, data unstated) and DIR300's terms.
6. Whether the 895-page public set's pages are photographs or scans per stratum, which decides whether tests 1 and 2
   extend to the non-Latin and early-hand strata; under the both-sets rule, any variant run there also runs on the
   96 truth pages.
7. Whether Apple's `DetectDocumentSegmentationRequest` mask can serve as UVDoc's tight crop on pages that fill the
   frame with neighbours visible, or whether the mask fails on cluttered box photographs; untested.
8. Whether Gemini 3.8 Flash and Qwen3.6 27B give usable mark boxes at all (the F screen found Qwen2.5-VL word boxes
   misaligned on indented lines); test 3 answers it.
9. Whether any dewarper is safe on handwritten pages, where text-line cues the models learned from print are weaker;
   the 12 handwritten truth pages are too few, so the public handwriting strata would be needed.
