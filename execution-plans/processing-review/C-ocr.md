# Strand C deep read: OCR and handwritten text recognition

Date 2026-10-20. Deep read for the processing review (`execution-plans/processing-review/00-plan.md`, Phase 1). The
screen is `C-screen.md`; `H-screen.md` supplied three adaptation papers. Tags: [M] measured in the source at the
location given; [I] my inference from measured figures; [?] not verified (vendor page, secondary source, or a part
of a source I could not read). Figures from our own measurements cite the file in `segbench-results/` or
`ArchiveOCRBench/`.

Full reads (nine, two by PDF text extraction): Kiessling, *A Free Lunch? Adapting PP-OCRv6 for Historical Text
Recognition* (arXiv 2609.20064v1, 14 pages); Semnani et al., *CHURRO* (arXiv 2509.19768, main text and appendices
A.2, B.2, B.3, D.5, E); Clifford, Polay, Jack, Humphries and Leddy, *Reading the Archive by Machine* (Working Papers
in Critical Search 004, whole page, and its Zenodo record); the HIPE-OCRepair 2026 competition paper (arXiv
2607.08143); *When Do VLMs Help Arabic Manuscript OCR?* (arXiv 2608.22366); NewsBench (README, `docs/methodology.md`,
`scoresheet.md`, `MEMO.md`); HunyuanOCR-1.5 (arXiv 2607.04884, first 200k characters); Polay, *Loud Yet Invisible*
(MA thesis, University of Saskatchewan, 144 pages, chapter 1 in full, chapters 2 and 3 where they bear on OCR);
Kanerva et al., *No Free Lunches* (arXiv 2502.01205v1). Skims with figures taken: in-context HTR (2609.37195),
pooled training (2610.11818), image-grounded correction of city directories (2504.00414), the Russian Civil-font
framework (2510.06743), ConfBench (2608.01792, abstract), *Reading or Guessing?* (2605.27750, abstract), the Churro
model and dataset cards and repository, the kraken PP-OCRv6 Zenodo record (21788410), the Dharma degeneration post,
the LlamaIndex failure-modes post, mlx-swift-lm PR 454 and xberg PR 1700.

Swaps against the screen. In: the Polay thesis (promoted from SKIM to a full read, because its 100-page gold is the
"Jacob" set in *Reading the Archive* and it answers the owner's question directly); *No Free Lunches* (promoted,
because it is the only source with an alignment guard measured in figures); 2504.00414 (promoted from SKIM, because
it is the one measured case where image-grounded correction of a specialist's output beat both the specialist and
the VLM alone). Out: HunyuanOCR-1.5 kept but demoted (its anti-loop reward is described without a single rate or
threshold); the Churro leaderboard page (its table does not render to a fetch; the figures below come from
`PRIOR-ART-2026-10-15-handwriting.md`, which read `benchmark_results.json`); hmBERT (confirmed not a post-corrector,
and in the thesis it is the worst NER baseline, so there is nothing to build on).

What is new since the two prior-art notes (`vision-ocr/PRIOR-ART-2026-10-07.md`, `-10-15-handwriting.md`): those
notes carried the Churro leaderboard, socOCRbench, NewsBench's headline rows, the first *Reading the Archive*
figures (BLN600 and multi-column F1), the region-first finding for newspapers, LightOnOCR-3, the kraken PP-OCRv6
model card and the specialist-versus-chat-model comparisons. New here: the Kiessling paper's actual tables (few-shot
curve, the Medusa comparison, throughput); CHURRO's training-source list set against our fifteen strata, including
two overlaps the specialists note missed; the fact that CHURRO-DS's truths were cleaned with Gemini 2.5 Pro; CHURRO's
20,000-token cap and its unmitigated loops; *Reading the Archive*'s handwriting tables, its gold-free failure check
and its gated-gold release; the HIPE-OCRepair and *No Free Lunches* figures on over-correction and the alignment
guard; the Arabic corrector's per-dataset split; the thesis's pipeline and its gold; NewsBench's full 61-row
scoresheet; the loop-fix evidence (n-gram blocking, DPO, a port bug, penalties); ConfBench on confidence aggregation;
the in-context and pooled-training figures.

## 1. Question

For each document kind (typed, printed, handwritten, forms and ledgers, clippings, newspapers, non-Latin scripts,
early modern hands) and each user profile (laptop only; cheap APIs; premium APIs and subscriptions; a cluster; any
of these plus a coding agent), should the Processor read a page in one shot with a vision-language model, or stage
the work (layout, line detection, a specialist recogniser, post-correction), and what does the field know about the
failures we measured: repetition loops on 76-350 of 895 pages for every open model, a truth set drafted by two of the
models under test, and the absence of any confidence signal for routing a page to a second reader?

## 2. What the field does now

Three practices coexist and the evidence sorts them by material, not by fashion.

**One-shot document VLMs on print.** Open document models (Chandra 2, olmOCR 2, Infinity Parser 2, GLM-OCR,
LightOnOCR-3, dots.mocr, PaddleOCR-VL, MinerU) and the frontier APIs read clean and early modern print at 0.5-3%
character error, and the differences among the top four are within a point [M, *Reading the Archive* BLN600 and
Jacob tables; thesis Figure 1.4]. On these pages the choice is cost and speed. The Saskatchewan group ran its
17,774-page production corpus through olmOCR 2 for that reason, not accuracy [M, thesis lines 2375-2381 of the
extracted text, chapter 1 conclusion].

**Layout first on dense and multi-column pages.** Every source that measured it finds that a layout stage decides
the result on newspapers: NewsBench's whole-page Gemini 3.5 Flash Lite scores 0.823 and the same model on
DocLayout-YOLO regions 0.961; GLM-OCR on regions 0.973 [M, `scoresheet.md`]. *Reading the Archive* finds the same on
its eight full pages (Infinity Parser 2 F1 90.2, Chandra 2 83.2, Gemini 82.0, olmOCR 2 44.9, GLM-OCR 44.7) and
attributes the two failures to column collapse and dropped columns [M, full-pages table]. The one nuance is that
"whole page" is not one thing: MinerU, which runs its own layout stage inside, scores 0.970 whole-page on NewsBench
[M], so the finding is "a layout stage, inside or outside the reader", not "an external detector".

**Specialists for hands, with adaptation.** The historical-HTR community (kraken, PyLaia, Transkribus, eScriptorium)
still trains compact CTC line recognisers per corpus. Kiessling's paper is the current statement of that case: a
16M-parameter recogniser, pretrained on 6.2 million heterogeneous lines, then fine-tuned on the target corpus, beats
a Qwen3.5-9B line recogniser tuned for the same material on five of seven medieval test sets, cannot loop, and runs
about 45 times faster [M, Tables 1, 4, §4.5]. On English hands the picture is reversed when the comparator is a
frontier API: Gemini 3.5 Flash reads early-19th-century Lower Canada hands at 1.52% CER against the best open
document model's 2.72% and GLM-OCR's 7.98% [M, *Reading the Archive* HHTR table], and Gemini 3 Pro at 0.91% [M].

**Post-correction is a narrow instrument.** Text-only LLM correction gains most at 2-6% input CER, barely at 0.4%,
and one competition system made French worse than no correction [M, HIPE-OCRepair Tables 5-7]. Open 8-70B models
help English and hurt Finnish, and a Llama model's raw output is worse than the input until trailing explanations are
trimmed by alignment [M, *No Free Lunches* Tables 2-3]. Image-grounded correction (reader sees the page and the noisy
text) is the version that has beaten both the specialist and the VLM alone, on 30 pages of Fraktur directories
[M, 2504.00414 Table 2]; on 18th-century Russian print the same design did not beat direct OCR for strong models and
text-only correction lowered accuracy [M, 2510.06743 §post-correction].

**Loops are treated as an engineering layer, not a model property to fix.** The field's working answers are a
detector on the output (gzip ratio, n-gram share, length against a page budget) with a retry or a human route
[M, *Reading the Archive* failure-check section; LlamaIndex post], n-gram blocking at decode time (fixed 51 of 56
Qwen loops on one Arabic set [M, 2608.22366 §failure modes]), a training reward of zero for over-length or
tail-repetitive rollouts [M, HunyuanOCR-1.5 §5.3.4, no rates given], and DPO with looping outputs as the rejected
side (37-87% relative reduction across five model families, from a 1.6-2.4% baseline on modern documents [M, Dharma
post]). Two engineering teams tried generic penalties and did not adopt them: one found a frequency penalty made two
of three pages worse on DeepSeek-OCR [M, xberg PR 1700], the other argues any penalty is unsafe when the source is
legitimately repetitive [M, LlamaIndex post]. One loop report turned out to be a port bug (dropped M-RoPE state in
mlx-swift-lm, fixed in PR 419) and does not touch the Python mlx-vlm we run [M, PR 454].

**Confidence for routing has no OCR-specific paper.** The nearest is ConfBench, on key-field extraction: first-token
log-probability beats mean and margin aggregation, OCR-plus-image input gives better-calibrated confidence than image
alone, calibration varies from near-perfect to severely overconfident across models, and thresholds need per-model
recalibration while rankings do not [M, abstract]. Kiessling adds a warning from the specialist side: a CTC
recogniser's mean character confidence conflates domain familiarity with annotation quality, rejecting 17% of
correctly transcribed historical lines at confidences of 0.55-0.68 [M, §3.2, Figure 1]. Our own measurement that
two cheap readers' disagreement separates poor readings at AUC 0.89-0.97 while the reader's own kind label does not
(0.57-0.70) is, as far as this reading found, the only page-routing result for transcription anywhere
[M, `ArchiveOCRBench/difficulty.md` §5].

## 3. Claims table

| # | Source | Claim | Figure | Conditions | Tag | Location |
|---|---|---|---|---|---|---|
| 1 | Kiessling 2609.20064 | Adapted PP-OCRv6 medium beats the kraken CRNN on a 33-language held-out test | macro CER 7.15 vs 12.41; small 9.80; tiny 15.24 | line crops, 96 px lines, pretraining 6.2M lines + 1M synthetic; test not document-disjoint | M | Table 1, §3.3 |
| 2 | Kiessling | Fine-tuned PP-OCRv6 medium beats Medusa (Qwen3.5-9B line recogniser) on medieval Latin-script sets | CER French 3.36 vs 3.74, Latin 8.70 vs 13.07, Spanish 7.99 vs 11.19, CoMMA Latin 11.30 vs 16.08, French 21.36 vs 28.24; Medusa wins Occitan 5.70 vs 6.62 and Czech 15.73 vs 18.05 | after fine-tuning on all of CATMuS; Medusa run through its own DocWorkflow pipeline; its reported 8.03/5.24/10.8 could not be reproduced | M | Table 4 and footnote a |
| 3 | Kiessling | Few-shot adaptation to one manuscript | kraken CRNN improves from 20 lines on all four pages; PP-OCRv6 is worse after 20, improves after 40 on one and 80 on two, not within 80 on the fourth; PP-OCRv6 CER below CRNN from 40 lines on; SD under 0.8 pp | same-page evaluation, 300 optimiser steps, 20-240 lines | M | §4.3, Figure 3 |
| 4 | Kiessling | Arabic-script transfer reproduces the ranking | zero-shot macro CER medium 17.99 vs CRNN 27.03; fine-tuned 18.82 vs 24.52 | MAKHZAN; test not document-disjoint | M | Table 5 |
| 5 | Kiessling | Throughput | small about 610 lines/s vs CRNN 640 at batch 32; tiny about 1,400; medium about 260; medium about 45x faster than Medusa | NVIDIA A40 | M | §4.5, Figure 4 |
| 6 | Kiessling | CTC confidence is not a reliability signal across domains | confidence filter rejects 17% of French/Latin/Spanish lines; correct lines at 0.55-0.68 | pretraining corpus | M | §3.2, Figure 1 |
| 7 | CHURRO 2509.19768 | Churro-3B beats Gemini 2.5 Pro on CHURRO-DS test | printed 82.3 vs 80.9; handwritten 70.1 vs 63.6 (normalised Levenshtein similarity); base Qwen2.5-VL-3B 67.8/42.9 | 1,170 test pages, 30 per language cluster per type; split by random page sampling, not by corpus | M | Table 1, §3.3 |
| 8 | CHURRO | The test truths were cleaned with the model it is compared against | Gemini 2.5 Pro suggested corrections, authors reviewed; another VLM restored spacing and diacritics with under 5% character edits; reading order from heuristics or a VLM, spot-checked over 98% | all of CHURRO-DS | M | §3.2 |
| 9 | CHURRO | Training recipe | Qwen2.5-VL-3B, 5 epochs, 32 H100, about 25 h, lr 5e-5, batch 128, images at most 5,120 patches of 28 px, max output 20,000 tokens, greedy | | M | Appendix B.2 |
| 10 | CHURRO | Degeneration is acknowledged, not measured or mitigated | two examples; no rate; no penalty or retry | | M | Appendix D.5 |
| 11 | CHURRO Appendix E, HF cards | Training sources overlapping our strata | Königsfelden (L7), iForal, Castilian, VOC notarial (L5), OCR-D (L8), Muharaf (N1), EPARCHOS (N3), BiblIA (N4), Bentham HTRtS 2015 (20 of L2's 80), READ 2017 Escher (20 of L6's 80); not present: By the People, Freedmen's Bureau, Digital Peter, Naval Kishore, OmniDocBench, NewsBench, the Kurrent set Zenodo 17252677 | | M | Appendix E (three parts) |
| 12 | Churro HF model card, dataset card, GitHub README | Licences | weights "qwen-research"; dataset "research purposes only"; code Apache 2.0 | | M | the three pages |
| 13 | Churro leaderboard (`benchmark_results.json`) | Churro still leads open models on CHURRO-DS handwriting | Churro 70.1; Gemini 3.1 Pro 68.3; Gemini 3 Pro 66.7; dots.mocr 55.0; Qwen3-VL-8B 48.5; Qwen3.5-9B 42.4; English handwritten Churro 84.0 vs Gemini 3.1 Pro 86.3 | authors' own benchmark | ? (from PRIOR-ART-2026-10-15, which read the JSON; the HTML table does not fetch) | leaderboard |
| 14 | Reading the Archive | Clean 19th-century print: all modern tools tie | semantic CER Gemini 3.5 Flash 0.57, Chandra 2 0.58, Infinity Parser 2 0.61, GLM-OCR 0.67, olmOCR 2 1.93, Tesseract 5.71 | BLN600, 600 cropped excerpts; semantic CER lowercases and strips punctuation; corpus-pooled | M | BLN600 table |
| 15 | Reading the Archive | Early modern print 1612-1807 | Gemini 2.15 (n=96 after 3 RECITATION refusals and 1 MAX_TOKENS), Chandra 2 2.58 (2.33 with a no-modernise prompt), Infinity 2.59, olmOCR 2 4.27, GLM-OCR 10.03, Tesseract 20.90; olmOCR modernises spelling 1.24% vs Gemini 0.36% | Jacob set, 100 pages, gold = Transkribus PAGE-XML corrected by hand | M | Jacob table |
| 16 | Reading the Archive | Multi-column full pages | chunk-aware F1 Infinity 90.2, Chandra 83.2, Gemini 82.0, olmOCR 44.9 (coverage 51%), GLM-OCR 44.7 (52%) | 8 pages 1878-1921 | M | full-pages table |
| 17 | Reading the Archive | Handwriting, early 19th c. | CER Gemini 3.5 Flash 1.52, Infinity 2.72, Chandra 2 3.89, olmOCR 2 5.34, GLM-OCR 7.98; Gemini 3 Pro 0.91 | HHTR, 50 legible Lower Canada administrative documents | M | HHTR table |
| 18 | Reading the Archive | Handwriting, 1860s-1907 | CER Infinity 7.0, Gemini 7.1, Chandra 9.3, olmOCR 10.3, GLM-OCR 18.1 | 4 documents | M | Manuscripts table |
| 19 | Reading the Archive | Article location inside issues | olmOCR 0/40, Chandra 29/40, Infinity 35/40 | Sask articles | M | §Sask summary |
| 20 | Reading the Archive | Speed and cost of open tools | olmOCR 2 about 0.7 s/page, Chandra 2 about 8 s, Infinity about 7 s (17 min load); about $0.50, $5, $7 per 1,000 pages at $2-3 per H100-hour | one H100, vLLM | M | §5 |
| 21 | Reading the Archive | Gold-free failure check | gzip ratio (prose about 2x), lexical repetition, top-n-gram share, length against page budget; labels clean/loop/runaway/empty/no-output; one 300-word letter produced 9,024 words at 8.2x gzip from Infinity | thresholds not stated | M | failure-check section |
| 22 | Reading the Archive, Zenodo 21297825 | Release | public artifact CC BY 4.0 (scoring harness, demonstration subset, setup recipes; the zip is 1.0 MB); core gold private, by request | | M | Zenodo record, §7-8 |
| 23 | Polay thesis | Transformer document models beat traditional OCR and Transkribus on early modern print | mean WER Chandra-1 0.045, Chandra-2 0.051, olmOCR-1 0.062, olmOCR-2 0.064, Transkribus 0.164; BLEU Chandra-2 0.934, Gemini 2.5 Pro 0.650; hallucination rate Chandra-2 0.73%, olmOCR-2 0.87%; EasyOCR word accuracy 36% | 100 EEBO and Internet Archive pages 1614-1810, over 40,000 words; gold = Transkribus first pass, single-pass expert correction; outputs manually standardised line by line | M | chapter 1, Findings (lines 2073-2151 of the extraction) |
| 24 | Polay thesis | The production pipeline used olmOCR 2 off the shelf, no fine-tuning, no post-correction | Chandra-1 about 20 min/page on an RTX 5070 Ti vs olmOCR 2 24 s/page; 50,000 documents in under 48 h on the NIBI cluster; 17,774 transcriptions released | | M | lines 2153-2179, 2375-2381, footnote 36 |
| 25 | Polay thesis | hmBERT is not in the OCR stage | hmBERT is the worst NER baseline (sF1 0.156); MacBERTh third on partial F1 (0.600); the NER model is a Qwen3-4B LoRA on 345 hand-labelled documents (sF1 0.775, pF1 0.823 vs Gemini 3 Pro 0.665/0.705) | | M | chapter 2, lines 2787-2843, 2935-2947, 3140-3160 |
| 26 | HIPE-OCRepair 2607.08143 | Text-only correction gains fall with input noise | best cMER: dta19 level 0 0.0040 to 0.0029; level 1 0.0240 to 0.0054; level 2 0.0546 to 0.0082; icdar2017 en 0.0260 to 0.0044; one team worse than baseline on French (0.0185 vs 0.0176) | EN/FR/DE newspapers and Fraktur books; metric cMER = (S+D+I)/(H+S+D+I), case- and punctuation-insensitive | M | Tables 2, 5-7 |
| 27 | HIPE-OCRepair | What the winner did | Mistral Small 3 24B with 80B tokens of continued pretraining on pre-1900 BnF text, LoRA on about 10,000 pairs, a judge-and-retry loop (flag rate 42% to 6%), routing of over-15%-CER cases to a larger model; another team used a length-ratio guard 0.35x-2.8x with fallback to the OCR | | M | §5.2 |
| 28 | No Free Lunches 2502.01205 | Open LLMs help English, hurt Finnish | relative CER improvement Llama-3.1-70B +38.7 EN / -47.0 FI; Gemma-2-27B +35.6 / -19.1; Mixtral-8x7B -14.9 / -76.5; GPT-4o +58.1 / +11.9 | ECCO-TCP input CER 0.07; NLF Fraktur input CER 0.09; 200 segments each; Q4 Ollama | M | Table 2 |
| 29 | No Free Lunches | Alignment trimming rescues over-generation | Llama-3-8B -74.1 to +7.3; Llama-3.1-70B -53.6 to +38.7; GPT-4o 53.7 to 58.1 | character-level local alignment, keep span between first and last aligned characters | M | §4.3, Table 3 |
| 30 | No Free Lunches | Segment length | 50-100 words clearly worse; gains level off at 200-300 | 53 dev pages | M | §6, Figure 4 |
| 31 | Arabic 2608.22366 | An OCR-conditioned corrector helps when the OCR prior is readable and hurts when it is not | CER Muharaf 69.2 to 60.6; SARD 4.7 to 2.6; KITAB 40.2 to 32.7; QNL books 33.1 to 15.5; RASAM 2 72.2 to 75.8; KHATT Qwen alone 40.9, corrector 42.1; student essays corpus CER Qwen 199.0, corrector 228.6 | Tesseract 5 then Qwen2.5-VL-7B or Fanar-2 with image and text; local inference only | M | Tables 5-11, 15, 17 |
| 32 | Arabic | Per-sample the aggregate hides a split | corrector improves more than 1% on 36.4% of Muharaf lines and worsens 44.2% | | M | §sample-level |
| 33 | Arabic | n-gram blocking fixes most loops | 28% of Qwen outputs repetitive on essays; no_repeat_ngram_size=4 fixed 51/56 Qwen and 50/55 Fanar failures; corpus CER 199.0 to 66.6 | | M | §failure modes, Figure 7 |
| 34 | Arabic | Token budget | SARD CER 36.3 at 512 tokens, 3.8 at 2,048 | | M | Table 15 |
| 35 | 2504.00414 | Image-grounded correction of a specialist's output beat both | CER Transkribus Print M1 3.67; Gemini 2.0 Flash image-only 1.27; Gemini with image and Print M1 text 0.84; GPT-4o 6.31 to 1.00 | 30 pages of Fraktur city directories 1754-1870 | M | Table 2 |
| 36 | 2510.06743 | Strong models do not gain from image-plus-text correction; text-only lowers accuracy; GPT-4o inserts archaic characters | Gemini 2.5 Pro full-page CER 3.36; fine-tuned TrOCR 1.83 as an upper bound; archaic insertions in 59% of GPT-4o files | 1,029 pages Russian Civil font 1752-1801 | M | results and post-correction sections |
| 37 | 2510.06743 | A ground-truth protocol without model bias | layout and lines by fine-tuned detectors, TrOCR first pass fine-tuned on 495 pages, one expert corrects every line, a second audits 500 lines: 98.6% line exact match, 99.93% character accuracy; stratified sampling; contamination-aware sourcing | | M | material section |
| 38 | In-context HTR 2609.37195 | Same-collection example lines cut CER without training | IAM average 17.68 to 5.36 at 16 examples (zero-shot average driven by Kimi-VL at 48.66; Qwen3-VL about 7-8 to 4.14); Washington 14.98 to 7.55; ICFHR2016 378 to 77.5 (fails) | four open VLMs, line crops, random examples, 30 draws; no fine-tune baseline; no cost figures | M | Tables 3-6 |
| 39 | Pooled training 2610.11818 | Pooling three collections hurt two of three VLMs | Qwen2.5-VL-7B CER single to pooled 5.8 to 7.1, 0.5 to 1.6, 7.6 to 24.9; Phi-3.5 17.9 to 19.7, 0.3 to 0.5, 6.3 to 7.4; Gemma-3-4B improved 10.4 to 8.7, 0.9 to 0.3, 14.6 to 9.1 | QLoRA on a 32 GB V100; 743 training pages; one collection's gold is a Gemini draft verified by hand | M | Table 9 |
| 40 | HunyuanOCR-1.5 2607.04884 | Loops trained against | reward zero for rollouts over a per-task length bound or with a repeated unit at the tail; `max_unit`, `min_repeats` and the bounds not stated; no before/after rate | 1B model | M (design), ? (effect) | §5.3.4 |
| 41 | HunyuanOCR-1.5 | A hallucination probe | CHAOS-Bench: one character altered in 2-3 words per page; recall of the altered words 14.15 vs 3.02-6.33 for five other document models | academic pages | M | §6.2, Table 11 |
| 42 | Dharma post | DPO against degeneration | Qwen2.5-VL-7B baseline 2.42% of requests hit the cap with a repeating tail; Nanonets-OCR2 3B 1.61% to 0.20%; 37-87% relative across five families | modern documents; blog, not reviewed | ? | post |
| 43 | mlx-swift-lm PR 454 | A port bug caused GLM-OCR loops on large images | prefill M-RoPE delta not carried into generation; closed as fixed in PR 419; Python mlx-vlm not affected | Swift port | M | PR page |
| 44 | xberg PR 1700 | Penalties are not a general fix | frequency penalty on DeepSeek-OCR made 2 of 3 pages worse (one page 5,637 to 23,590 characters) | candle runtime, F32, A100 | M | PR page |
| 45 | ConfBench 2608.01792 | How to aggregate log-probabilities | first-token beats mean and margin; OCR+image input better calibrated than image alone; per-model recalibration needed for thresholds | key-field extraction, not transcription; 7 models | M (abstract) | abstract |
| 46 | NewsBench | Region-first lifts every reader on dense newspapers | Gemini 3.5 Flash Lite none 0.823, DocLayout 0.961; GLM-OCR DocLayout 0.973, PaddleX 0.940; Tesseract none 0.678, DocLayout 0.922; MinerU whole-page 0.970; AS-YOLO regions 0.62-0.82; gpt-5.6-luna none 0.504, DocLayout 0.978; qwen3.8-flash none 0.343, DocLayout 0.125; human volunteer 0.997 | 15 By the People pages, 1,892-8,966 words each; overall = 1-CER, lowercased alphanumeric, hyphens joined | M | `scoresheet.md`, `docs/methodology.md` |
| 47 | NewsBench | How its gold was fixed | 269 volunteer errors corrected to a diplomatic standard; candidates from agreement among eight OCR systems, each confirmed against the scan; each system's score rose about 0.003; ranking unchanged | | M | `docs/methodology.md` |
| 48 | kraken PP-OCRv6 Zenodo 21788410 | The pretrained medium model | 15.92M parameters, 128 px lines, Apache-2.0, kraken 7.1 or later; micro CER 3.91, macro 4.93 on a random 5% in-domain split; English 5.90, Arabic 9.38, Hebrew 5.06, Ancient Greek 7.21, Russian 12.34; training inventory lists EPARCHOS, Muharaf, Königsfelden, OCR-D, iForal, VOC, IAM, JosephHookerHTR, Revolutionary City; not Bentham, READ 2017, By the People, Digital Peter, BiblIA, Naval Kishore | | M | record page |

## 4. Code, weights, data and licences

| Item | Code | Weights | Data | Licence | Mac-runnable | Cluster needs |
|---|---|---|---|---|---|---|
| kraken PP-OCRv6 tiny/small/medium | kraken 7.1+ (Apache) | Zenodo 21788403/05/10, 64 MB medium | inventory on the record | Apache-2.0 [M] | yes, CPU; specialists.md measured about 9 s/page for reading and 30 s/page for blla segmentation on one core | none; an A40 did 260-1,400 lines/s |
| Churro-3B | github stanford-oval/Churro, Apache 2.0 | HF `stanford-oval/churro-3B` | CHURRO-DS 139 GB, 99,491 rows | weights Qwen research licence; dataset research use only [M] | the lab converted it to MLX 8-bit (PRIOR-ART-10-07); 5.8 GB peak | ran on one L40S (specialists.md) |
| Reading the Archive harness and demonstration set | GitHub (linked from the paper) | n/a | 1.0 MB zip; core gold by request | CC BY 4.0 [M] | yes | none |
| NewsBench | github nealcaren/newsbench, MIT | n/a | 15 scored LoC pages, gold CC0 | MIT code, public-domain data [M] | yes | none |
| HIPE-OCRepair data and scorer | github hipe-eval, scorer on PyPI | n/a | text pairs, about 995k tokens | dta19 CC BY-SA 4.0; icdar2017 and impresso-snippets CC BY-NC-SA 4.0; overproof research only [M] | yes | none |
| Chandra 2 | datalab-to/chandra, Apache | weights modified OpenRAIL-M, free under $5M revenue | | restricted redistribution [?, screen row 33] | GGUF exists (PRIOR-ART-10-07) | about 8 s/page on an H100 [M] |
| Infinity Parser 2 | not located | about 35B MoE [M, Reading the Archive] | | unknown | no | Sherlock-class; 17 min load, 7 s/page on an H100 |
| olmOCR 2 | allenai/olmocr | 7B | olmOCR-Bench ODC-BY | open [?] | heavy for 18 GB | 0.7 s/page on an H100 |
| LightOnOCR-3 4B/0.8B | HF lightonai | Apache-2.0 [checked in PRIOR-ART-10-15] | | Apache-2.0 | yes, measured 23.8 s/page at 8-bit (`ocr-mac-local-hw.md`) | 0.85 GPU-h per 1,000 pages (open sweep) |
| HunyuanOCR-1.5 | github Tencent-Hunyuan | "will release" | | paper CC BY-NC-SA; model licence unseen [?] | unknown | 1B |
| Polay pipeline | Zenodo 20421805 (code), 20420918 (17,774 transcriptions), 20420895 (NER LoRA) | olmOCR 2 off the shelf | 100-page gold not separately listed; it is the gated Jacob set [I] | not read [?] | n/a | n/a |

## 5. Comparison with what we measured

**Clean print and typescript.** The field's tie among top readers on clean print is what we see: on the 96 the paid
leaders sit within two points (Claude Sonnet 5.5 96.47, Gemini 3.1 Pro 94.85, Qwen3.6-27B 94.28 NES
[M, `ocr-panel-cloud.md`]); on the 895's typescripts (L3) every open route scores 89.7-96.0 and on early print (L8)
76.3-88.3 [M, `open-sweep-20261019.md`]. Nothing in the literature changes the recommendation for typed and printed
20th-century pages: pick on price and failure rate. The difference between our material and the field's is capture:
phone photographs rather than scans. No source read here measures that; our ladder is the only evidence (half-size
images read as well as originals, quarter-size lose 20-25 points, page by page not uniformly
[M, `ocr-panel-local.md`, `kind-classifier.md` §3]).

**Newspapers and dense layouts.** NewsBench's L9 pages are inside our 895, so the comparison is direct once the
metrics are aligned (its overall is 1-CER on lowercased alphanumerics with hyphens joined; ours is NES with case and
punctuation kept). Our whole-page rows on L9: Qwen3.6-27B 93.6, Qwen3.5-27B 95.8, LightOnOCR-3 4B 92.5, GLM-OCR 29.2,
PaddleOCR-VL 0.0, PP-OCRv6 23.6 with every page answered but columns interleaved [M, open sweep stratum table and
PP-OCRv6 review]. NewsBench has GLM-OCR at 0.973 on DocLayout-YOLO regions and PaddleOCR-VL (the `ll-doclayout-pvl`
row) at 0.973 [M]. The 27B Qwen models read these pages whole at 93-96, which NewsBench's whole-page rows for
smaller general models (0.34-0.54) do not; so the gain from a layout stage is largest for the small OCR-specialist
models that loop or collapse columns, and smaller for a 27B general model that already holds the page. This is
consistent with *Reading the Archive*'s finding that GLM-OCR and olmOCR fail on columns while the larger
layout-aware models do not. Our owner corpus has 13 clippings and 12 tables in the 96 and about 2,187 clippings and
456 tables among 21,105 documents [M, `ocr-truth.md`]; nothing has been measured region-first on any of them.

**Hands.** On English hands the field's frontier result (Gemini 3.5 Flash 1.52% CER on HHTR, Gemini 3 Pro 0.91%) is
in line with our 96, where Gemini 3.8 Flash reads the 16 handwritten pages at 95.97 NES against Claude's 92.43 and
Qwen3.6-27B's 92.15 [M, `difficulty.md` §2 by-kind table]. On the 895's L1-L2 (By the People letters and 1700-1850
manuscripts) the best open routes reach 86-88 and 73-77 NES [M, open sweep]; no hosted route has read those strata
(paid-run hold). The specialist case is strongest exactly where we measured it: kraken script models beat Qwen3-VL
235B by 11.5-37 points on L5, L6, N3, N4 and tie Gemini on L6 and L5, while no open page model does
[M, `specialists.md`]. Kiessling's result says the same for medieval Latin against a tuned 9B VLM. What we have not
measured is the pretrained PP-OCRv6 on the strata it was not trained on (L1-L4, our handwritten 16-19 pages), which is
the only fair test of it as a laptop route; the stock PaddleOCR PP-OCRv6 pipeline we ran on FarmShare is the
Chinese-and-Latin print model, not Kiessling's historical one, and its 46.0 on L1 says nothing about his
[M, open sweep "Pipeline" definition].

**Loops.** Our caps are loops (zlib ratio under 0.12 on 206 of GLM-OCR's 215, 227 of Qwen3-VL 8B's 236, 316 of
PaddleOCR-VL's 350 [M, open sweep failures table]), they come from bf16 vLLM on an L40S, so they are the models' and
not a Mac port's, and they fall on the hard hands and non-Latin scripts (25 of 40 Hebrew pages for Qwen3-VL 235B
[M, bench-corpus README]). The field's figures for the same models on modern material are 1.6-2.4% [?, Dharma]; ours
are 8-39% of pages because the material is harder, and a loop is therefore also a difficulty signal. The app's local
route already does what the literature recommends (a 4,096-token cap, a repetition check every 250 streamed
characters, one retry with a 1.05 penalty [M, `ArchiveProcessor/CLAUDE.md`]); the two things not tried are n-gram
blocking at decode time, which fixed 51 of 56 loops in the Arabic study, and a non-autoregressive fallback (a CTC
line recogniser cannot loop; stock PP-OCRv6 answered 893 of 895).

**Truth bias.** Our 96's truth was drafted by Claude Opus 5.5 and Gemini 3.8 Flash; 33 pages agreed word for word and
the owner adjudicated 416 spans covering 3% of the words, so 97% of the words stand on the two drafters' agreement
[M, `ocr-truth.md`]. CHURRO-DS has the same structure one level up: its truths were cleaned with Gemini 2.5 Pro's
suggestions, and Churro's headline is a 1.4-point lead over Gemini 2.5 Pro on that set [M, §3.2, Table 1]. The
field's unbiased designs are a specialist or a tool not under test as the scaffold, full manual correction, and an
independent audit of a sample (2510.06743: 500 lines, 98.6% exact), or a gated gold (*Reading the Archive*). The
thesis's gold is a Transkribus draft corrected once by one person, and its author's argument that "any mistake in the
gold standard will reflect evenly across all systems" [M, lines 1318-1320] is not true for the drafting tool, which
is one reason Transkribus's 0.164 WER there should be read with care. On the 440 pages whose truths predate all
these models, Gemini 3.8 Flash leads Qwen3-VL 235B by 18.7 NES points with a paired interval of 16.1-21.5, where on
the 96 the gap is 0.5 [M, bench-corpus README; `ocr-panel-cloud.md`]; that is material, not bias, but it shows the
96 cannot separate readers and the 440 can.

**Post-correction.** Our good routes already read the 96 at NES 93-97, which in CER terms is the regime where
HIPE-OCRepair found the smallest gains and the risk of degradation; the 895's hard strata are at NES 40-70, where
the Arabic study found a corrector hurts because the prior is not recoverable. The band where the field's evidence
says correction pays (readable but noisy, roughly NES 70-90) holds our hard third of the 96 (mean 82.74 across routes
[M, `difficulty.md` §2]) and the 895's L1, L2, L4 and L6 for the better open routes. The field's safe design is
image-grounded correction with an alignment guard and an abstention check on clean input; text-only correction is
the design that fails.

**Confidence.** Our disagreement signal (AUC 0.89-0.97) and length-against-Vision (0.78-0.89) are stronger than
anything the literature reports for a single reader, and we have no log-probability measurement because the APIs we
used return none [M, `difficulty.md` §5]. The local routes (vLLM on FarmShare, mlx-vlm on the Mac) can return
log-probabilities at no cost, and ConfBench's finding that first-token aggregation and OCR-plus-image input calibrate
best gives the test design.

**Where a public benchmark makes ours less necessary, and what to borrow.**

- NewsBench is already our L9. Borrow its region-first configurations (DocLayout-YOLO, PP-DocLayout) and its
  order-robust scorer (`bowF1`, `chrF`, `gap`) and run them on our own L9 outputs, then on the owner's clippings and
  tables. Contamination: the pages are public LoC scans with public volunteer transcriptions; CHURRO-DS includes
  American Stories (Chronicling America) but not By the People [M, Appendix E]; no model card read here lists
  NewsBench itself.
- *Reading the Archive*'s HHTR (50 early-19th-century English hands) and Jacob (100 early modern English print)
  are the closest public-ish analogues to our L1-L2 and to an English early-print stratum we lack, with frontier and
  open figures already paid for. The gold is gated, which keeps contamination low; request it. Borrow the semantic
  CER, the modernisation-versus-fabrication split of hallucinations, and the gold-free failure check.
- CHURRO-DS: do not borrow its scores (Gemini-cleaned truths, research-only licence); do check page-level overlap
  between its 1,170 test pages and our 895 by image hash, because eight of our fifteen strata draw from its source
  corpora and the specialists note's "known source overlap" column for Churro should add READ 2017 (L6) and Bentham
  (L2) [I from claim 11].
- HIPE-OCRepair: borrow the cMER scorer and its level-0 data as the abstention test for any corrector before it
  touches our pages.
- socOCRbench: nothing to borrow beyond the NES definition we already use; its truth method is undisclosed.
- CHAOS-Bench's perturbed-word probe (HunyuanOCR-1.5) is a free idea for our marks-and-evidence rule: alter one
  character in a few words on a typed page image and count how many readers copy what is there against how many
  "correct" it.
- 2510.06743's archaic-insertion rate and historical-character preservation rate transfer to our L2 and L8 as a
  long-s and Fraktur-ligature preservation check, computable from existing outputs.

## 6. Strand-specific questions

**One-shot VLM against staged pipelines, by kind and profile.**

- Typed and printed 20th-century pages (the bulk of the owner corpus): one shot, every profile. The field and our
  panels agree the top readers tie; a layout stage adds nothing measurable on single-column pages and a specialist
  line recogniser is close but below (stock PP-OCRv6 89.7 on L3 against 93-96 [M]).
- Newspapers, clippings with columns, ledgers and tables: a layout stage first, for every profile that uses a model
  under about 10B or an OCR-specialist model (GLM-OCR, PaddleOCR-VL, LightOnOCR, olmOCR 2); for 27B-class general
  models and the frontier APIs the whole page already works on L9 (93-96) and the gain is unmeasured. Ledgers (L4)
  are the open question: every open route is at 52-70 there and PaddleOCR-VL at 28 [M].
- English hands (L1, L2, the owner's handwritten pages): one shot with Gemini 3.8 Flash for the API profiles (95.97
  on our 16; 1.52% CER on HHTR for Gemini 3.5 Flash); for the laptop profile the measured best is LightOnOCR-3 4B
  8-bit at 89.67 on the 16 [M, `ocr-mac-local-hw.md`], and the untested candidate is the pretrained kraken
  PP-OCRv6 medium on Vision or blla lines.
- Non-Latin scripts and early modern Latin hands (L5-L7, N1-N4): a script specialist on lines for the laptop and
  cluster profiles (kraken models beat the open page models by 11-37 points [M, `specialists.md`]), Gemini for the
  API profiles; Cyrillic (N2, at most 21 NES for any open route) has no answer yet.
- Cluster profile: the layout stage and the specialist stage are both cheap there (DocLayout-YOLO at 28 ms per page
  on an A100 per the Docling report in H-screen; PP-OCRv6 at 0.10 GPU-hours per 1,000 pages [M, open sweep]), so a
  staged route costs almost nothing beside the VLM pass.

**Is the 96's truth biased toward Claude and Gemini?** It is biased by construction and the size of the bias is
unmeasured. The drafters hold the top two or three rows, but Qwen3.6-27B is within 0.6 of Gemini 3.1 Pro on
completed pages (95.27 against 96.86 [M]), so the bias cannot be large on typed pages. The field builds unbiased
truth with a scaffold that is not under test plus full manual correction plus an audited sample (claim 37), or
gates the gold (claim 22). The free test is in §7 item 3: score each route separately on the unreviewed agreed words
and the adjudicated words; a drafter's lead that lives in the agreed words is bias.

**Loops and caps.** The fixes with figures are n-gram blocking (claim 33), a detector plus retry at a different
temperature or a different model (claims 21, LlamaIndex), a token cap scaled to the page (claim 34 shows the cap
itself can cause the failure when too low), and DPO at training time (claim 42). Penalties are not a general fix
(claims 44, LlamaIndex) and the app's 1.05 retry penalty is at the mild end. The structural fix is a non-looping
fallback: a loop is a cap, a cap is a failure, and failures escalate; the cheapest escalation for Latin pages is a
CTC recogniser, which answered 893 of 895. For the Hebrew pages no open fallback exists; Gemini does not loop there.

**Confidence for routing.** Measured: disagreement between two cheap readers (AUC 0.89-0.97), length against Apple
Vision (0.78-0.89), failure itself (robust +0.8-2.8 NES on unseen pages at every budget up to $5 per 1,000
[M, `difficulty.md` §4]). Unmeasured and free on local routes: first-token and low-token-probability shares (claim
45). Not promising: the model's own kind label (0.57-0.70), Vision's handwriting call as a route (no consistent gain),
and CTC confidence across domains (claim 6).

**Post-correction's over-correction risk.** Real and measured: a system worse than no correction on French at 1.8%
input CER (claim 26), all open models worse on Finnish (claim 28), a corrector worsening 44% of lines while improving
the aggregate (claim 32), GPT-4o inserting archaic characters in 59% of files (claim 36). The guards with figures are
alignment trimming (claim 29), a length-ratio accept window (claim 27), a judge-and-retry loop (claim 27), and the
image in the prompt (claim 35 against claim 36, which disagree, so it is a test for us). The rule the evidence
supports: correct only pages routed into the readable-but-noisy band, with the image, with alignment trimming, and
prove on the easy third that the stage changes nothing.

**Public benchmarks to borrow.** NewsBench (configurations and scorer; it is already our L9), *Reading the Archive*
(HHTR and Jacob gold by request; scorer; failure check), HIPE-OCRepair (scorer and level-0 abstention data), the
CHAOS-Bench probe as an idea, 2510.06743's preservation rates as a check. Not CHURRO-DS scores; do check its
page-level overlap. Not socOCRbench.

**A user-trained recogniser as a kit for this stage.** For a line recogniser the evidence is favourable and
specific: pretrained PP-OCRv6 improves on its base from 40-80 corrected lines of one hand and the kraken CRNN from 20
(claim 3), with low variance across draws; Transkribus's rule of thumb is about 10,000 words per hand [?, vendor,
H-screen]. For a VLM the evidence is unfavourable at small data: pooling three small collections hurt Qwen2.5-VL-7B
on all three (claim 39); a 12-page fine-tune of one writer lost 8 points against its base in our own run
(`specialists.md`, kurrent_v3); the NARA fine-tune of LightOnOCR-3 4B scored below the stock model
(PRIOR-ART-10-15). In-context lines are the zero-training alternative for the API profiles (claim 38), measured only
on line crops. So the kit that the evidence supports now is: a kraken PP-OCRv6 fine-tune on the user's corrected
lines for the laptop profile, and corrected lines in the prompt for the API profiles; a VLM LoRA on the user's pages
is a research item, not a kit.

**The Saskatchewan thesis.** Polay built no transcription model. Chapter 1 benchmarks off-the-shelf document VLMs
(olmOCR 1 and 2, DeepSeek-OCR, Chandra 1 and 2, MinerU 2.6.2) and Gemini 2.5 Pro against Tesseract, Tesseract-Legacy,
EasyOCR, kraken and Transkribus on 100 EEBO and Internet Archive pages of 1614-1810, with a gold he drafted in
Transkribus and corrected once by hand; Chandra 1 and 2 are most accurate (WER 0.045 and 0.051), olmOCR 2 is close
(0.064) and fifty times faster, and olmOCR 2 transcribed the 17,774-page production corpus on a consumer RTX 5070 Ti
and then the NIBI cluster (claims 23-24). There is no fine-tuning, no post-correction, and no historical language
model in the OCR stage; hmBERT appears only as the worst NER baseline and MacBERTh as a mid-table one (claim 25).
The "error rate below 10%" in the abstract is WER; the chapter's figures are 4.5-6.4% for the top four, and the
"six-fold" comparison is against Tesseract-Legacy, whose figure is in a chart I could not extract [?]. The thesis's
gold is the Jacob set that *Reading the Archive* later scored with Gemini 3.5 Flash, Infinity Parser 2 and GLM-OCR
[I: same author, 100 pages, Transkribus PAGE-XML, 1612/1614-1807/1810]. What transfers to us is small: a confirmation
that off-the-shelf document VLMs read early modern print at 2-5% error on scans, a hallucination-rate definition
(error words that are dictionary words, 0.73% for Chandra 2), and the observation that BLEU and content-word accuracy
predict downstream NER F1 (correlation 0.965 and 0.946 [M, lines 2290-2295]).

## 7. Tests to run on our material, ranked

Each test runs on both the 895 and the 96 with the same settings, per the owner's rule of 2026-10-20 (`Archive
Suite/CLAUDE.md`, "Both OCR sets, every time"). Costs are at the prices we measured: Gemini 3.8 Flash $0.0042 a page
on the 440 ($0.010 on Hebrew), Qwen3-VL 235B $0.0024, Gemini 3.1 Pro $0.0219 on the 96 [M, bench-corpus README,
`ocr-panel-cloud.md`].

1. **Loop recovery on the capped pages.** Profiles: laptop, cluster, cheap API with open models. Take every route's
   capped pages in the open sweep (76-350 per route) and rerun each with four treatments: n-gram blocking
   (`no_repeat_ngram_size` 4), a half-resolution retry (our ladder says half-size reads as well as full), a second
   open reader (LightOnOCR-3 4B for Qwen caps and the reverse), and kraken PP-OCRv6 medium on blla lines for the
   Latin strata. Score NES recovered and GPU-hours saved; repeat on the 96's three MLX loops. Free on FarmShare or
   Sherlock. Expected size: the small models' answered NES is 10-13 points above their overall NES, so this is the
   largest open-route gain on the table.
2. **Region-first against whole-page on dense pages.** Profiles: all. DocLayout-YOLO and PP-DocLayoutV3 regions
   read by GLM-OCR, PaddleOCR-VL 1.5, LightOnOCR-3 4B and Qwen3.6-27B on L9 (15), L4 (80), the owner's 13 clippings
   and 12 tables; whole-page rows already exist. Score with our NES and NewsBench's `overall`, `bowF1` and `gap` so
   the two benchmarks line up. Free on cluster or Mac. Paid arm: Gemini 3.8 Flash on regions of L9 and the 25 owner
   pages, under $0.50.
3. **Truth-bias audit of the 96, no calls.** Split each page's words into unreviewed-agreed and owner-adjudicated
   spans from the review sheet; recompute every route's word accuracy on each; a drafter's lead concentrated in the
   agreed spans is bias. Then a blind re-adjudication by the owner of 20 random pages where Qwen3.6-27B differs from
   the agreed text (about 30 minutes, an owner review session, so judge the timing first). If the bias is material,
   draft a fresh 50-page set with a scaffold not under test (kraken PP-OCRv6 lines or Apple Vision) and full owner
   correction, per claim 37.
4. **Pretrained PP-OCRv6 as the laptop handwriting route, then the few-shot kit.** Profiles: laptop, coding agent.
   kraken PP-OCRv6 medium on blla lines and on Vision line boxes over L1-L3 (not in its training) and the owner's
   handwritten pages, against LightOnOCR-3 4B and Qwen3.5-9B 4-bit on the Mac; then fine-tune on 40, 80, 160 and
   240 owner-corrected lines of one hand and re-measure on that hand's other pages. Free, CPU. Decides whether the
   kit is a line recogniser.
5. **CHURRO-DS overlap and Churro on the clean strata.** Hash the 1,170 CHURRO-DS test images against our 895 (the
   test split alone is a small download); run Churro-3B on L1-L4, L9, N2, N5, N6 on FarmShare, with the specialists
   note's overlap column corrected for L2 and L6. Free. Churro is the only open model with a published handwriting
   lead over a Gemini, and L1-L2 are English hands it was not trained on.
6. **Image-grounded post-correction in the band only.** Profiles: cheap API, cluster. Pages whose cheap reading
   scored NES 70-90 (the 96's hard third; L1, L2, L4, L6 for the open routes); corrector = Qwen3.6-27B with image and
   text, Gemini 3.8 Flash the same, text-only as control; alignment trimming from claim 29; HIPE's cMER beside NES;
   added-words rate; the abstention check on the easy third, which must change nothing. Free with open models;
   Gemini on about 150 pages, under $1.
7. **Log-probability confidence from a local route.** Profiles: laptop, cluster. Rerun LightOnOCR-3 4B or
   Qwen3.6-35B-A3B on the 895 and the 96 with log-probabilities on; compute first-token, mean, minimum-k and
   low-probability-token share per page; AUC against NES under 70 and against failure; compare with the disagreement
   and length signals already measured; fit isotonic calibration on the 440 and test on the 455. Free.
8. **Borrow Reading the Archive.** Request the gated HHTR and Jacob gold; run our routes through its scorer and run
   Chandra 2 and Infinity Parser 2 on our L1, L2 and L9 (Infinity needs Sherlock-class memory). Free except any API
   arm. Gives an English-hands comparison independent of our truth and the only measured Infinity figures.
9. **In-context lines for the owner's hands.** Profiles: cheap and premium API, subscription. Eight and sixteen
   corrected lines from the same hand in the prompt of Gemini 3.8 Flash and Qwen3.6-27B on the 16-19 handwritten
   pages of the 96 and 40 pages of L1. The paper's gain is on line crops; ours is page-level and unmeasured. Gemini on
   about 60 pages times three conditions, under $1; Qwen free on cluster.
10. **Preservation and perturbation checks from existing outputs.** Long-s and Fraktur-ligature preservation on L2
    and L8 per route (claim 36's method); CHAOS-style altered-word recall on 20 typed owner pages. Free; the second
    needs about 20 new readings per route.

## 8. Open questions

- Phone capture: no source read here measures photographed paper against scans; Real5-OmniDocBench (screen row 23)
  was not read and may hold the only public distortion set. Strand D's territory, flagged here because every
  comparison above assumes the capture matters less than the material.
- The Medusa system report (hal-05600991) was not read; Kiessling could not reproduce its reported CERs with its
  own pipeline (claim 2 footnote), so the "VLM tuned for the task" comparator is weaker than the abstract suggests.
- HunyuanOCR-1.5's repetition thresholds and the effect of its anti-loop reward are not in the paper; whether the
  1.5 weights are released is unconfirmed.
- Whether Infinity Parser 2 has a source, licence and a runnable size for Sherlock is unknown; it is the best open
  tool on columns and hands in *Reading the Archive* and absent from every other benchmark.
- Whether CHURRO-DS's test pages coincide with ours page for page (test 5).
- Whether the thesis's 100-page gold is exactly the Jacob set, and whether its Tesseract-Legacy figure supports
  "six-fold" (both in charts the extraction did not capture).
- Ledgers and forms (L4) and Cyrillic (N2) have no good open route and no measured staged route; nothing read here
  addresses either.
