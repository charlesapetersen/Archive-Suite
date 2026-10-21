# Strand H deep read: whole-corpus processing and user-side adaptation

Date 2026-10-21. Deep read for the processing review (`execution-plans/processing-review/00-plan.md`, Phase 1). The
screen is `H-screen.md`. This note builds on the four strand notes in the same folder and does not repeat their
reads: Kiessling's PP-OCRv6 paper, CHURRO, the in-context HTR paper and the pooled-training paper are read in
`C-ocr.md`; TABME++ and the window-size paper in `A-segmentation.md`; the neighbour-dating split in `B-dating.md`;
the Harvard-Boston newspaper pipeline in `E-layout.md`. Where this note needs one of their figures it cites the
note and the claim number. Tags: [M] measured in the source at the location given; [I] my inference from measured
figures; [?] not verified (abstract, press report, vendor page, search snippet, or a source I could not open).
Our own figures cite the file under `ArchiveProcessor/segbench-results/`, `ArchiveOCRBench/`, or the kit folder
`ArchiveProcessor/scripts/segbench/institutional-compute/`.

Full reads (nine, three from PDF text extracted with pdftotext into `rawH/`): UCCI (arXiv 2605.18796, HTML);
olmOCR (2502.18443, HTML); FrugalGPT (2305.05176, PDF); the Tsakalis MPhil dissertation on active learning for
Bentham HTR (PDF, 1,609 lines of text); Kiessling and Clérice, *Does Context Matter? Enhancing HTR with Metadata in
Historical Manuscripts* (CHR 2024, CEUR Vol-3834 paper 30, PDF); the Socface project paper (2404.18706, HTML);
mlx-vlm's training guide (`docs/training.md`) together with the trainer source of the mlx-vlm 0.7.4 installed in
the Vision OCR lab's venv (`trainer/lora.py`, `lora_layers.py`, `adapter_utils.py`, `sft_trainer.py`, `utils.py`,
`lora.py`); Apple's Foundation Models adapter toolkit page, the WWDC26 session "What's new in the Foundation Models
framework" (transcript), and the Core AI and Foundation Models documentation index JSON; the Hugging Face
`huggingface-llm-trainer` SKILL.md and its launch blog. Skims with figures taken: the Library of Congress OCR
reprocessing blog, the NDNP-Open-OCR README and the Library's September 2025 slide deck (PDF); Muehlberger et al.,
*Transkribus as a case study* (J. Documentation 2019, first 100,000 characters); Hodel et al., *General Models for
HTR: German Kurrent* (JOHD 2021); the Transkribus help page on CER and learning curves; Chagué's McCATMuS training
post; the CATMuS Medieval Zenodo record and the Medievalists report on CoMMA; the mlx-swift-lm LoRA reference and
its issue 561; kraken issue 358 and the kraken 5.2 ketos page; mlx-tune's README; the UCCI repository; the
abstracts of MMLongBench-Doc, CLOCR-C, few-shot writer adaptation (2603.29450), olmOCR 2 and the switchable-adapters
chapter.

Swaps against the screen. In: the CHR 2024 metadata paper (not in the screen; it is the only measured result on
conditioning a recogniser with collection-level metadata, which is this strand's first question); the Tsakalis
dissertation (promoted from SKIM to a full read; the only HTR active-learning learning curve found); Apple's adapter
toolkit and Core AI (not in the screen; they decide the R1 adaptation route); Socface (not in the screen; the one
end-to-end archival system with per-field published figures); FrugalGPT (promoted, because UCCI is defined against
it). Out or demoted: the HF skills blog (read, but it trains only on Hugging Face Jobs, which need a paid plan, and
has no held-out step, so it is a pattern and not a kit we can reuse); the switchable-adapters chapter (paywalled;
abstract only, tagged [?]); Transkribus's learning-curve help page (it carries no data volumes at all; the volumes
the screen attributed to it are in the 2019 journal article). Two corrections to the screen: its row 38 says the
Transkribus help page gives "about 5,000 words print, at least 10,000 words per hand"; the help page gives no
volumes, and the 2019 article gives 5,000 words (25 pages) for print and 15,000 words (75 pages) per hand. Its
row 45 presents the HF skill as a general training kit; the skill is HF-Jobs-only and says Jobs "require paid plan".

## 1. Question

The Processor works page by page and window by window, with one shipped set of models and prompts. The strand asks
what the field knows about four things that reach across a whole corpus and across users. First, whether context
beyond the page or the seven-page window (neighbouring pages, folder order, box and folder labels, finding aids,
earlier boxes of the same collection) improves segmentation, dating or reading, and what has been measured. Second,
how a user's corrections can adapt each stage, how few corrections each stage needs to move, and whether active
selection of what to show the user buys anything over the review screens we have. Third, whether a coding-agent
training kit is a sensible product: which stages it should cover (recogniser fine-tune, segmentation threshold
refit, small-VLM LoRA), the steps a coding agent must follow, the held-out check before a user's model is used,
training on a Mac against Sherlock, and how a trained model plugs into the Processor (MLX adapters, ONNX, Core ML,
a model manifest). Fourth, how to route pages across the eight compute routes at a cost target with a calibrated
confidence, and what the field's end-to-end archival systems (Transkribus, eScriptorium and kraken, Arkindex and
Socface, the Library of Congress and the Harvard-Boston pipelines) have published as evaluations.

## 2. What the field does now

**Adaptation is routine for line recognisers and rare for VLMs, and the data volumes are published only for the
first.** The historical-HTR platforms train a model per collection and have said for years how much a user must
transcribe: Transkribus's 2019 journal article gives 5,000 words (about 25 pages) for print and 15,000 words (about
75 pages) for one hand, lists a dozen projects with their ground-truth volumes and CERs (7,000 words to 2.75 million
words; CER 2% to 24%), and says that above 10% CER an automatic transcription "become[s] less useful" as a research
resource while keyword spotting still works to 30% [M, Muehlberger et al. 2019]. Hodel et al. measured what a
general model buys: trained on 5.1 million tokens of German Kurrent from hundreds of hands, it reads known hands at
CER 6.53% and unseen hands at a mean of 3.43% (median 2.76%, worst 9.13%) across 2,426 test lines from 22 packages,
against 2.5-8% for document-specific models, and they call training on tiny samples of a single hand "relatively
ineffective" [M, JOHD 2021 Tables 1-3, §1.2, §2.3]. Kiessling's few-shot figures for a pretrained recogniser (the
kraken CRNN improves from 20 corrected lines, PP-OCRv6 from 40 to 80) are the modern statement of the same practice
[M, `C-ocr.md` claim 3]. For VLMs the published adaptation results are small-data failures or large-data successes:
pooling three collections hurt two of three VLMs [M, `C-ocr.md` claim 39]; the NARA fine-tune of LightOnOCR-3 4B
on 38,756 pages scored below the stock model [M, `I-inventory.md`]; our own 12-page kraken fine-tune lost 8 points
against its base [M, `bench-corpus/specialists.md`]; CHURRO and olmOCR adapt at 99,491 and 266,135 pages. No
published learning curve exists for a VLM on a new collection. Two zero-training routes exist for the API profiles:
in-context lines (IAM average CER 17.7% to 5.4% at 16 lines; `C-ocr.md` claim 38) and, for small recognisers, an
8M-parameter model that adapts to a writer from a few example lines with no gradient update (IAM 3.92%, RIMES 2.34%
CER [M, 2603.29450 abstract]).

**Active learning for HTR has one measured curve and it is modest.** The Tsakalis dissertation runs uncertainty
sampling (N-best list entropy) and global entropy reduction on the Bentham collection (433 pages, 11,537 lines;
9,198 training lines; a Kaldi-style GMM/LSTM recogniser) in batches of 920 lines from a 10% seed. Uncertainty
sampling reaches 29% WER with 29% fewer lines than random selection, and cuts WER by 4.4 points at a fixed budget of
50% of the data; the gain is in the early rounds (before about 40% of the data), the two active methods are nearly
the same, a batch of 30% of the pool hurts because the seed model's entropies are poor, and the selected lines carry
more words, so the saving in annotation cost is less than the saving in lines [M, §5.1-5.4, Figures 5.1-5.8]. The
speech-recognition precedents it cites report "minor improvements" at a batch of 4,000 and better results at 400
[M, §3, citing Hakkani-Tür et al.]. No active-learning result exists for page-stream segmentation, dating or VLM
transcription; `A-segmentation.md` searched for it and found none.

**Collection-level context has been measured once for recognition, and the measurement is favourable but narrow.**
Kiessling and Clérice add century, script and language tokens from CATMuS's line metadata to a Conformer
recogniser. All three tokens together lift character accuracy from 90.32 to 91.14 (micro) and 92.07 to 92.86
(macro), with the lowest variance across manuscripts, a median gain of 0.64 points and over 2 points on the hardest
manuscript; any single token alone is worse than the baseline (century 87.53), and the model keeps its gain with the
tokens zeroed (91.13), so it has learned the features rather than leaning on the label; an auxiliary-loss variant
failed to converge in half its configurations [M, Table 4, Table 5, Table 7, §6]. The paper cites two earlier
results: a metadata vector concatenated to a CNN-LSTM encoder cutting CER by 10% on accident statements, and a
meta-learning writer adaptation 5-7 points above naive fine-tuning [?, second-hand from §2]. For documents rather
than lines, the multi-page benchmarks say long visual context is weak: on MMLongBench-Doc (130 PDFs, 49.4 pages
each, 33.2% cross-page questions) twelve of fourteen vision-language models score below their text-fed LLM
counterparts and GPT-4o leads at F1 42.7 [M, abstract]. For page streams the measured context is the adjacent pair
and a window of 5-10 pages, with weaker models degrading as the window grows [M, `A-segmentation.md` claims A04];
for post-correction the useful context is 200-300 words of preceding text, and book-level correction is "planned"
[M, `C-ocr.md` claims 30, 2502.01205 §6]; the context CLOCR-C uses is socio-cultural (a description of the source in
the prompt), not neighbouring text [M, abstract]. Socface is the one archival system that uses the neighbouring page
as structure: its household grouping reads across two pages and gets 76% of households right [M, §5.2]. Nothing
published uses a finding aid, a box label or an earlier box to condition page-level processing; the screen searched
and this read searched again.

**Cascades are standard and the calibration literature now gives a recipe.** FrugalGPT's cascade is a list of three
APIs, a DistilBERT regression scorer over query and answer, and a threshold per stage learned on a labelled training
split; it saves 98.3%, 73.3% and 59.2% of the cost of the best single model at its accuracy on HEADLINES (10,000
examples), OVERRULING (2,400) and COQA (7,982), and the authors say it "need[s] some labeled examples" from "the same
or similar distribution as the test examples" [M, §3, Tables 2-3, §5]. UCCI replaces the learned scorer with the
small model's own token margin, calibrated by isotonic regression on a 22,500-query calibration split (ECE 0.12 to
0.03), and picks the routing threshold by minimising measured cost subject to an F1 target on a 15,000-query
validation split; at F1 0.91 it costs 2.08 against 3.02 for the large model alone (a 31% cut, CI 27-35%), beating a
conformal threshold (2.18), a FrugalGPT-style validation-tuned threshold (2.24) and an entropy threshold (2.31); the
saving grows with the cost ratio (37% at 5x, 42% at 10x); the theory assumes the large model's accuracy does not
depend on which queries are escalated, which held here (0.928 on escalated against 0.932 overall) but "can break";
calibration is static; code is MIT with numpy as its only dependency [M, §4-6, Tables 1-3, repository README]. Both
are text tasks; neither is OCR. Our own measurement that two cheap readers' disagreement separates poor pages at AUC
0.89-0.97 and that escalating on failure gains 0.8-2.8 NES on unseen pages [M, `difficulty.md` §4-5] is the only
page-routing evidence for transcription this read found.

**Teacher-student document models measure agreement with the teacher, not inheritance of its errors.** olmOCR
labelled 266,135 pages with GPT-4o, fully fine-tuned Qwen2-VL-7B (LoRA gave higher validation loss), and reports
page-weighted word alignment with the teacher of 0.875 at temperature 0.1 against GPT-4o's self-alignment of 0.954
and 0.859 at temperature 0.8, which it raised to reduce repetition loops; it reports no analysis of what the student
does where the teacher is wrong [M, §3.1-3.2, §4.2, Table 4]. olmOCR 2 moves to reinforcement learning with binary
unit-test rewards on synthetic documents with known HTML, which turns a correction into a checkable test rather
than a target string [M, abstract]. CHURRO's truths were cleaned with the model it is compared against [M,
`C-ocr.md` claim 8]. Our students are the same shape: trained on the teacher's replies where teacher and owner tags
agree, 97.6% agreement on held-out gaps, and about ten points behind Gemini on boxes nobody trained on [M,
`seg-students.md`].

**Coding-agent training kits exist as patterns, not as products for a Mac.** Hugging Face's `huggingface-llm-trainer`
skill makes the agent validate the dataset on CPU before any GPU time ("ALWAYS validate unknown datasets before GPU
training"), pick hardware by model size (under 1B on a T4, LoRA above 7B), set a timeout, include Trackio monitoring,
push to the Hub ("If the model isn't pushed to Hub, ALL TRAINING IS LOST"), and optionally convert to GGUF; it has no
mandatory cost approval and no held-out evaluation step, runs only on HF Jobs, which "require paid plan", and hands
VLMs to Unsloth [M, SKILL.md; blog]. mlx-vlm ships agent skills for Claude Code and Codex, but for inference,
conversion, benchmarking and model porting, not training [M, README `skills/`]. Apple's adapter toolkit is the one
first-party training kit on a Mac: LoRA adapters of about 160 MB for the on-device model, trained on "Mac with Apple
silicon and at least 32GB memory, or Linux GPU machines", 100 to 1,000 samples "to teach the model basic tasks",
5,000 or more for complex ones, one adapter per system-model version, an entitlement to ship, and text only; and
"Version 26.0.0 is the last release of this toolkit and is not compatible with macOS, iOS, iPadOS, or visionOS 27
and later" [M, toolkit page]. The macOS 27 session adds image input to the on-device model, an 8,192-token context
in the sample, and open-source `CoreAILanguageModel` and `MLXLanguageModel` backends for the framework's
`LanguageModel` protocol, and does not mention adapters [M, WWDC26 session 241 transcript]; the Foundation Models
documentation index carries no adapter topic and the former adapter article returns 404 [M, docs JSON, 2026-10-21].
Core AI (introduced 27.0) is the framework for a developer's own models (`AIModelAsset`, device specialization,
caching) and its documentation names no adapter mechanism [M, docs JSON].

**On-device fine-tuning tooling on a Mac is real and unmeasured for our sizes.** mlx-vlm 0.7.4 (the lab's install)
trains SFT and ORPO with LoRA or DoRA on `nn.Linear` and `nn.QuantizedLinear` layers, so a quantised base is a
supported QLoRA case; LoRA targets are every linear layer of the language model except the vision tower, projector
and `lm_head`; defaults are rank 8, alpha 16, dropout 0, learning rate 2e-5, batch 4, 1,000 iterations, max sequence
2,048, with `--grad-checkpoint`, `--train-vision`, `--full-finetune`, `--image-resize-shape`, `--epochs`,
`--steps-per-eval` and `--adapter-path` flags; the wired-memory limit is set to Metal's recommended working set and
peak memory is reported per step; the only models refused are `gemma3n` and `qwen3_omni`; `load(model,
adapter_path=)` applies an adapter at inference and the server takes `--adapter-path`; the GitHub guide (0.7.9) adds
DPO and GRPO, `--quantization-bits 4|8`, `--train-type lora|dora|full`, and says nothing about memory, speed,
hardware or fusing [M, local source; `docs/training.md`]. mlx-tune (Apache-2.0, 1.4k stars, v0.6.0) wraps the same
trainer in an Unsloth-style API, lists Qwen3.5 and OCR models, saves adapters or merged weights, warns that merging
into a 4-bit base can lose a weak LoRA delta, and gives no memory or speed figures [M, README]. mlx-swift-lm loads
`adapter_config.json` plus `adapters.safetensors` with `LoRAContainer.from(directory:)`, applies, fuses, unloads and
hot-swaps adapters, and had a GPU fault on Qwen3.5 linear-attention adapters fixed by PR 564 on 2026-08-24 [M,
reference doc; issue 561]. kraken's ketos documents `--device cpu|cuda` only [M, 5.2 docs]; its MPS issue has been
open since 2022 (CTC loss had no MPS kernel), and the last substantive comment (2026-09-04) says "torch 2.14 fully
supports kraken with MPS", with no speed figure [M, issue 358].

**End-to-end institutional systems publish throughput and field accuracy more often than CER on held-out pages.**
Socface classifies census pages with YOLOv8x-cls (list F1 0.99), reads whole tables with DAN (test CER 14.47%, WER
27.05%, entity F1 0.85; birth date 0.98, surname 0.84, occupation 0.81, observation 0.16), groups households at 76%,
and processed 450,000 images in under eight days on V100s at 12.5 s per image for recognition, from 100 annotated
pages across 11 pilot archives plus 33,815 annotated rows; it reports no test on an unseen archive [M, 2404.18706
§4-6]. The Library of Congress reprocesses NDNP newspaper OCR with Tesseract plus post-processing, from version 1.1
in two passes (American Stories YOLOv8 segments read by Tesseract, then whole-page Tesseract to fill gaps; pass one
covers "90+%"), had about 85,000 pages online in January 2025 and over 170,000 by April, plans 300,000 pages of
1900-1910 in 2025-2026, and publishes no CER: its "Tracking Improvements" slide counts unique words per batch, down
12-72% after reprocessing [M, slides pp. 27-33; blog; README]. The Harvard-Boston pipeline read 1.47 million scans as
83 million crops with dots.mocr and measured reading order (tau 0.959) on 723 annotated scans [M, `E-layout.md`
claim 27]. The eScriptorium and kraken community publishes its generic models with training inventories and
sometimes a split-dependent accuracy: McCATMuS (106k training lines) reaches 78.06% character accuracy on an
out-of-domain fixed split and 85.24% on a random split's test set, 63.02% on 20th-century handwriting, against
Manu McFrench's 91.17% whose training data overlaps the test set [M, Chagué]; the CATMuS Medieval record (113,228
lines, CC BY 4.0) reports no accuracy at all [M, Zenodo 10066219]; CoMMA transcribed 32,763 manuscripts in four
months and reports a 9.7% error rate from three lines checked in each of 670 manuscripts [?, press report].
Transkribus reports 17,000 users, 130 models trained a month, and training times of "several hours [to] several
days" [M, Muehlberger 2019].

## 3. Claims table

| # | Source | Claim | Figure | Conditions | Tag | Location |
|---|---|---|---|---|---|---|
| 1 | UCCI 2605.18796 | Isotonic calibration of token margin fixes a miscalibrated small model | ECE 0.12 to 0.03 (CI 0.02-0.04) | 4B and 12B instruction-tuned models, 75,000 labelled photo-search queries, 6 entity types; calibration 22,500, validation 15,000, test 37,500 | M | §6.1-6.2, Figure 1 |
| 2 | UCCI | Cost-optimal threshold under an accuracy constraint | at F1 0.91 cost 2.08 vs 3.02 large-only (31%, CI 27-35%); conformal 2.18, FrugalGPT-style 2.24, entropy 2.31 | cost = H100 latency ratio 3.02 | M | Table 2, Figure 2 |
| 3 | UCCI | Saving grows with the cost ratio | 31% at 3.02, 37% at 5, 42% at 10 | same | M | Table 3 |
| 4 | UCCI | The escalation-invariance assumption held here | large F1 0.928 on escalated vs 0.932 overall | same | M | §6.3 |
| 5 | UCCI | Limits and release | single domain; static calibration; isotonic vs temperature scaling ECE 0.03 vs 0.08; code MIT, numpy-only; data not released | | M | §7, App. B.4, repository |
| 6 | FrugalGPT 2305.05176 | Cascade design | 3 APIs; DistilBERT regression scorer g(q,a); per-stage thresholds (0.96, 0.37 on HEADLINES) learned on a training split | 12 APIs from 5 providers, March 2023 prices | M | §3, Figure 3 |
| 7 | FrugalGPT | Cost to match the best single model | HEADLINES 33.1 to 0.6 (98.3%); OVERRULING 9.7 to 2.6 (73.3%); COQA 72.5 to 29.6 (59.2%) | datasets of 10,000 / 2,400 / 7,982 | M | Tables 2-3 |
| 8 | FrugalGPT | Needs labels from the test distribution | "we need some labeled examples ... from the same or similar distribution" | | M | §5 |
| 9 | olmOCR 2502.18443 | Teacher and scale | GPT-4o (2024-08-06); 266,135 pages from 105,504 documents | | M | §3.1, Table 1 |
| 10 | olmOCR | Student recipe | Qwen2-VL-7B, full fine-tune (LoRA gave higher validation loss), lr 1e-6, 10,000 steps about 1.2 epochs, 8 H100; images 1,024 px | | M | §3.2 |
| 11 | olmOCR | Alignment with the teacher, not with truth | 0.875 at τ 0.1 (GPT-4o self 0.954, GPT-4o mini 0.833), 0.859 at τ 0.8 | Hirschberg word alignment, page-weighted | M | §5.1, Tables 4-5 |
| 12 | olmOCR | Loops handled by temperature and retries | τ raised 0.1 to 0.8 to cut repetitions; failed pages retried N times then plain-text fallback | | M | §4.2 |
| 13 | olmOCR | Cost | under $190 per million pages on L40S or H100 (5,200 pages per dollar, 20% retries assumed); GPT-4o $12,480, batch $6,240 | hourly rates L40S $0.79, H100 $2.69 | M | §4, Table 3 |
| 14 | olmOCR 2 2510.19817 | Corrections as verifiable rewards | RLVR with binary unit tests on synthetic documents with known HTML; 7B; "permissive open licenses" | | M | abstract |
| 15 | Tsakalis dissertation | Uncertainty sampling saves lines | 29% WER reached with 29% fewer lines than random; 4.4 pp WER cut at 50% of the data | Bentham 433 pages, 11,537 lines, 9,198 train; batches of 920 from a 10% seed; N-best entropy, N=1,000; GMM/LSTM recogniser; WER | M | §5.1-5.2, Figures 5.1-5.2 |
| 16 | Tsakalis | Where the gain is | early rounds (before about 40% of the data); 60% of active-selected data covers 90% of the vocabulary vs 71% random; a 30% batch hurts; GER about equal to uncertainty sampling | | M | §5.2-5.4, Figures 5.4-5.8 |
| 17 | Tsakalis | Pipeline cost | LSTM training on the full set 440 min on a GTX 980; decoding 2,000 lines 102 min | | M | Table 2.1 |
| 18 | Kiessling & Clérice CHR 2024 | Metadata tokens lift a recogniser and cut its variance | kraken 86.56 / 88.75; Conformer 90.32 / 92.07; Conformer + century, script, language tokens 91.14 / 92.86 (micro / macro char. accuracy); median +0.64 pp; hardest manuscript +2 pp | CATMuS Medieval 1.0.1 and 1.5.0 test | M | Table 4, Table 5, §6 |
| 19 | same | Single tokens hurt; zeroed tokens keep the gain | century alone 87.53; language 88.37; script 87.73; all tokens zeroed 91.13 | | M | Table 4, Table 7 |
| 20 | same | Auxiliary-loss variant is unstable | 6 of 12 configurations under 15% accuracy | | M | §6 |
| 21 | same | Unknown-feature robustness | Navarrese and Venetian manuscripts stable or better; BnF esp. 65: 93.60 to 94.08 | | M | Table 6 |
| 22 | same | Code | Apache-2.0, github mittagessen/conformer_ocr | | M | footnote 5 |
| 23 | same (citing prior work) | Metadata vector into a CNN-LSTM encoder cut CER 10%; meta-learning writer adaptation +5-7 pp over naive fine-tuning | | accident statements; k-shot writer adaptation | ? | §2 |
| 24 | MMLongBench-Doc 2407.01523 | Long visual context is weak | 130 PDFs, 49.4 pages, 1,062 questions, 33.2% cross-page; 12 of 14 LVLMs below their OCR-text LLM counterparts; GPT-4o F1 42.7 | | M | abstract |
| 25 | CLOCR-C 2408.17428 | "Context" there is a source description, not neighbouring text | top model over 60% CER reduction on NCSE; 91 articles released | | M | abstract |
| 26 | 2603.29450 | Writer adaptation from a few lines with no gradient update | 8M-parameter CNN-Transformer; IAM 3.92%, RIMES 2.34% CER | modern hands | M | abstract |
| 27 | Socface 2404.18706 | Pipeline figures | list-page F1 0.99; DAN whole-page CER 8.94 train / 14.30 val / 14.47 test, WER 27.05 test; entity F1 0.85 (birth_date 0.98, firstname 0.94, surname 0.84, occupation 0.81, observation 0.16); households 76% | 100 annotated pages from 11 archives; 33,815 rows; 532 pages for grouping; 1,285 for classification | M | §4.2, §5 |
| 28 | Socface | Scale and speed | 450,000 images in under 8 days; 1.6 s preprocessing, 12.5 s recognition (V100), 7.2 s post-processing per image; 30 million images estimated; no unseen-archive test | | M | §1, §6 |
| 29 | LoC slides (Sept 2025) and blog (Apr 2025) | Two-pass Tesseract pipeline, no CER published | pass 1 American Stories YOLOv8 segments to Tesseract, "90+% document coverage"; pass 2 whole-page Tesseract; about 85,000 pages online Jan 2025, over 170,000 by April; 300,000 pages 1900-1910 planned; unique-word counts down 12-72% per batch | | M | slides pp. 27-33; blog |
| 30 | NDNP-Open-OCR README | Release | CC0; CLI; AWS Batch/Lambda/S3; local run "too slow for full production"; `--segmentation` enables the American Stories model, falls back to Tesseract layout | | M | README |
| 31 | Muehlberger et al. 2019 | Data volumes per model | print 5,000 words (about 25 pages); one hand 15,000 words (about 75 pages); more for several hands | | M | J. Documentation, "How much training data" |
| 32 | same | Project CERs against volumes | Belgrade 7,000 words about 2% (seen material); Barlach 42,000 words about 9%; Greifswald 410,000 words 5%; Georgian Papers 365,000 words 16%; Passau 400,000 words, 40 scribes, 17-19%; Zurich 2.75M words about 6% same hand, 570,000-word subset 18%; Göttingen incunable 35,000 words 5%; print 1-2% | | M | same |
| 33 | same | Thresholds and scale | best hands under 5% CER; over 10% "less useful" as a research resource; keyword spotting usable to 30%; 17,000 users; 130 models a month; 30 pages in 28 min; training "several hours [to] several days" | | M | same |
| 34 | Transkribus help page | Rules of thumb only | 10% or below "very efficient"; print 0.5-2% good; hands 2-8% depending on one or several hands; no data volumes | | M | help page |
| 35 | Hodel et al. JOHD 2021 | General model vs document models | general 5.1M tokens, hundreds of hands: CER 6.53% known hands; unseen hands mean 3.43%, median 2.76%, worst 9.13% (HTR+); PyLaia 18.77% mean; Transkribus German Kurrent 5.90% mean; document-specific 2.5-8%; tiny single-hand samples "relatively ineffective" | 2,426 test lines from 22 packages | M | Tables 1-3, §1.2, §2.3 |
| 36 | Chagué, McCATMuS | Generic kraken model, split-dependent | 106k + 5.8k lines; fixed out-of-domain split 78.06% test; random split 92.8% val, 85.24% test; handwritten 78.72, print 96.37, typewritten 90.93; 20th-c. handwritten 63.02; Manu McFrench 91.17 with test overlap | kraken 4.3.13, default architecture | M | post 022 |
| 37 | CATMuS Medieval Zenodo 10066219 | Generic model release without figures | 113,228 lines, 3.36M characters, 1,602 files; CC BY 4.0; no accuracy stated | | M | record |
| 38 | Medievalists.net on CoMMA | Scale and a sampled error rate | 32,763 manuscripts in four months; 9.7% error on three lines in each of 670 manuscripts | press report; paper forthcoming | ? | article |
| 39 | HF `huggingface-llm-trainer` SKILL.md | Agent procedure | validate dataset on CPU first; hardware by size (under 1B T4; LoRA above 7B); set timeout; Trackio; push to Hub; GGUF optional; no held-out evaluation; HF Jobs "require paid plan"; VLMs via Unsloth | | M | SKILL.md; blog ($0.30 demo; $15-40 for 3-7B) |
| 40 | Apple adapter toolkit | A Mac training kit that ended | 160 MB adapters; Mac 32 GB or Linux GPU; 100-1,000 samples basic, 5,000+ complex; one adapter per system-model version; entitlement to ship; text only; "Version 26.0.0 is the last release ... not compatible with ... 27 and later" | | M | toolkit page |
| 41 | WWDC26 session 241 | On-device model gains vision; no adapters mentioned | `Attachment(UIImage(...))` in a prompt; any image size, more tokens for larger; `contextSize` 8192 in the sample; `CoreAILanguageModel` and `MLXLanguageModel` open-sourced for the `LanguageModel` protocol | | M | transcript |
| 42 | Apple docs JSON | Core AI is for a developer's own models | introduced 27.0 on every platform; `AIModelAsset`, `AIModel`, specialization, caching; no adapter topic; Foundation Models index has no adapter topic, adapter article 404 | 2026-10-21 | M | `coreai.json`, `fm_root.json` |
| 43 | mlx-vlm 0.7.4 (local source) | LoRA trainer facts | LoRA/DoRA on Linear and QuantizedLinear (quantised base supported); targets all language-model linears except vision tower, projector, lm_head; defaults rank 8, alpha 16, dropout 0, lr 2e-5, batch 4, iters 1,000, max seq 2,048; `--grad-checkpoint`, `--train-vision`, `--full-finetune`, `--image-resize-shape`; unsupported only gemma3n, qwen3_omni; `load(adapter_path=)`; server `--adapter-path`; peak memory logged | | M | `trainer/*.py`, `lora.py`, `utils.py` |
| 44 | mlx-vlm `docs/training.md` (0.7.9) | Guide gives no memory, speed or hardware figures | SFT/ORPO/DPO/GRPO; `--train-type lora|dora|full`; `--quantization-bits 4|8`; resume loses optimizer state; no fuse instructions | | M | training guide |
| 45 | mlx-tune README | Mac VLM/OCR fine-tuning wrapper | Apache-2.0; v0.6.0; 1.4k stars; Qwen3.5 listed; `save_pretrained_merged` dequantises then fuses; `merged_4bit` can lose a weak delta; no figures | | M | README |
| 46 | mlx-swift-lm | Adapter API and a fixed bug | `LoRAContainer.from(directory:)`, `load(into:)`, `fuse(with:)`, `unload(from:)`; `adapter_config.json` + `adapters.safetensors`; Qwen3.5 linear_attn adapter GPU fault fixed in PR 564, closed 2026-08-24 | 3.31.3 | M | reference doc; issue 561 |
| 47 | kraken docs and issue 358 | Devices | ketos `--device` cpu or cuda in the docs; MPS blocked by missing CTC kernel until 2026; "torch 2.14 fully supports kraken with MPS" (2026-09-04); no speed figure; issue still open | | M | 5.2 ketos page; issue thread |
| 48 | Switchable adapters (Springer chapter) | One base, one LoRA per transcription style | base pre-trained on CATMuS Medieval + TRIDIS with a MUFI penalty; per-style LoRA adapters beat a single adapter; MiniCPM-Llama3-V-2.5, Phi-3.5 Vision, Qwen2-VL vs kraken v5 and TrOCR; no figures seen | paywalled | ? | abstract via search |
| 49 | Ours, `seg-students.md` | Student training and transfer | 5,885 agreed windows, rank 16, one epoch, one L40S; pilot (a quarter) 97.1%, full 97.6% (4B), 96.0% (2B) on 5,668 held-out gaps; test boxes 79.1% / 78.8% vs teacher 83.0%, Gemini 88.8%; confidences flag nothing useful (about 80 checks per 100 pages to 98%) | | M | tables |
| 50 | Ours, `seg-students.md` §On the Mac | The shipped 2B | 8-bit: 90.3% dev pooled, 18 s a window, 4.4 GB peak, 2.5 GB; 4-bit loses 2-5 points; 4B buys nothing | M3 Pro 18 GB, mlx-vlm 0.7.4 | M | table |
| 51 | Ours, `date-model.md` | Text-only LoRA, cost and result | 7,428 examples, 928 updates, 2B 1,624 s on one L40S; 4B job 65 min; Mac 8-bit 1.39 s a document, 3.78 GB peak; corpus year 66.8% vs Gemini 79.6%; unprinted years 41.2% vs 63.4%; 0 of 50 `Date Uncertain` | | M | note |
| 52 | Ours, `label-clean.md` | Teacher labels against tags | agree keeps 77.7% of gaps and 5,889 whole windows; teacher calls 27.6% of tag continuations starts vs 7.9% owner-found wrong; noise among kept 1.8% (agree) vs 5.0% (start-trust) on the 69-gap sample; fresh 80-gap owner checkpack pending | | M | tables |
| 53 | Ours, `difficulty.md` | Routing signals and cascades | disagreement AUC 0.89-0.97; length vs Vision 0.78-0.89; own kind label 0.57-0.70; escalate-on-failure +0.8-2.8 NES on unseen pages at every budget to $5; disagreement check inconsistent on unseen pages; real-corpus failure 0.4-1.2% by kind; no route returns a confidence | 96 pages, 29 routes | M | §1, §4-5 |
| 54 | Ours, `specialists.md`; `I-inventory.md` | Small-data VLM and recogniser fine-tunes that lost | kurrent_v3 (12 pages on german_handwriting) -8 points vs base; NARA LightOnOCR-3 4B fine-tune CER 0.2312 vs stock 0.2057 on 762 held-out pages | | M | notes |
| 55 | Ours, kit README | What the kit is today | Slurm only; profiles with partition, QOS, GPU memory, modules, scratch; `setup.sh` validates against live Slurm; truth check before bulk; `train_seg.py data|train|merge` and `train.sbatch` submitted by hand; host RAM default 48 x GPUs + 32 GB | | M | README |

## 4. Code, weights, data and licences

| Item | What exists | Licence | Mac-runnable | Cluster needs | Notes |
|---|---|---|---|---|---|
| UCCI reference implementation | `ucci` Python package (numpy only), CLI, isotonic calibration, cost-constrained threshold, CoNLL-2003 replication; 8 commits, 2 stars | MIT | Yes | None | The calibration arithmetic is small enough to re-implement in the bench; the package is a check. |
| FrugalGPT | No code or scorer released in the paper | — | — | — | The scorer is a DistilBERT regressor; ours would be the disagreement signal or a calibrated margin. |
| olmOCR / olmOCR 2 | Code, weights, data (allenai/olmocr); 7B | paper says released; licence not named in the text; olmOCR-Bench ODC-BY per C | 7B is heavy for 18 GB (4.6 / 8.8 GB at 4/8-bit [I]) | L40S: 0.7 s a page (C claim 20) | The alignment metric (Hirschberg word alignment) is a two-line scorer worth adding to the bench. |
| Tsakalis code | None released | — | — | — | Method is generic: entropy over N-best or over a model's P(new); DTW distances optional. |
| Kiessling & Clérice conformer_ocr | GitHub mittagessen/conformer_ocr | Apache-2.0 | Training needs a GPU; inference CPU plausible | one GPU | The metadata-token trick transfers to our prompt (as text) at no code cost. |
| mlx-vlm trainer | `python -m mlx_vlm.lora` (0.7.4) / `mlx_vlm.train` (0.7.9); `load(adapter_path=)`; server `--adapter-path` | MIT | Yes; memory and time for our window sizes unmeasured | None | Our 2B 8-bit seg model was converted with 0.7.4 and is served by `mlx_vlm.server`. |
| mlx-tune | Python API over mlx-vlm/mlx-lm; `load_adapter`, merged export | Apache-2.0 | Yes | None | Adds nothing the trainer lacks except an evaluate() with cer/wer/exact_match for OCR. |
| mlx-swift-lm LoRA | `LoRAContainer`, QLoRA layers, fuse, unload | MIT (Apple) | Yes | None | In-process adapter loading for a future Swift route; VLM coverage not stated in the reference doc. |
| kraken + ketos | training, fine-tuning (`--load`, `--resize union`), `ketos test` | Apache-2.0 | CPU yes; MPS per the issue thread with torch 2.14, unmeasured | A40 did 260-1,400 lines/s (C claim 5) | PP-OCRv6 medium weights Apache-2.0 (C claim 48). |
| Apple adapter toolkit 26.0.0 | LoRA training for the macOS 26 on-device model | Apple terms; model assets only for adapter training; entitlement to ship | Mac 32 GB | — | Ended; incompatible with macOS 27. No image input in the 26 model. |
| Apple Foundation Models (macOS 27) | on-device model with image attachments; `MLXLanguageModel`, `CoreAILanguageModel` backends | Apple frameworks | Yes, macOS 27 Macs with Apple Intelligence | — | No adapters; a candidate zero-cost first reader or voter, unmeasured. |
| Apple Core AI (27.0) | custom model runtime (`AIModelAsset`), specialization, caching | Apple frameworks | Yes | — | No adapter mechanism documented; conversion tooling for our MLX models not read. |
| HF skills (`huggingface-llm-trainer`) | SKILL.md and scripts for HF Jobs | Apache-2.0 | No (HF Jobs only; paid plan) | — | A procedure to copy, not a tool to ship. |
| Socface / Arkindex / Callico / DAN | Arkindex partly open; Callico open (2405.01071); DAN open | mixed; not re-read | — | V100/A100 for DAN | Field-level evaluation design worth copying for dates and names. |
| NDNP-Open-OCR | pipeline (Tesseract + American Stories YOLOv8 + post-processing) | CC0 | Docker; "too slow" locally | AWS Batch | The two-pass gap-filling design is the useful idea. |
| CATMuS Medieval, McCATMuS models | kraken models, training inventories | CC BY 4.0 | CPU | — | McCATMuS is already in our specialists run (below Qwen everywhere). |
| Ours | `train_seg.py` (data/train/merge), `train.sbatch`, `setup-train.sh`, `cluster_seg.py`, profiles, `test_institutional_compute.py`; the 2B seg and date LoRAs merged and converted; `LocalSegmenter` with its options.json row | ours | 2B 8-bit runs on 16 GB | one L40S for a LoRA pass | Training is "manually submitted"; no held-out gate, no adapter path, no Mac training path yet. |

## 5. Comparison with what we measured

What transfers.

1. The shape of the adaptation evidence. The field adapts line recognisers from tens of lines and VLMs from tens
of thousands of pages, with nothing measured between; our own runs sit at the same two ends (kraken fine-tune on 12
pages lost, NARA's 38,756-page VLM fine-tune lost, our 5,885-window and 7,428-example LoRAs worked) and confirm the
gap. Nobody has the VLM learning curve the kit needs; it is ours to measure (test 2).

2. Teacher-student agreement is the published measure and it hides the inheritance. olmOCR's 0.875 alignment with
GPT-4o is our 97.6% agreement on held-out gaps, and in both cases the number against a human truth is lower (our
students 79% on the test boxes, the teacher itself 83%). The field's missing analysis, what the student does where
the teacher is wrong, is cheap for us because label-clean already has the owner's 69 adjudicated gaps and a fresh
80-gap checkpack (test 4).

3. Calibration. UCCI's procedure (fit isotonic regression on a calibration split, choose the threshold by cost at a
target, test on a held-out split) is exactly what `difficulty.md` §4 does by hand with its split-half check, and it
explains why our hand-set 0.85 and 0.995 levels behave as they do: the 2B's and the teacher's raw confidences are
not rankings of error ("flag all" at every bar, `seg-teacher.md`), which isotonic regression cannot fix, while
disagreement is a ranking (AUC 0.89-0.97) that a cost-chosen threshold can use. UCCI's assumption that the large
model's accuracy is invariant to escalation is testable on our cached readings, and our "page mix" column already
measures the analogous bias for first readers.

4. Metadata as context. Kiessling and Clérice's result is small (0.8 points, lower variance, larger on hard
manuscripts) and it says the right form: all the tokens together, none alone. Our segmentation prompt already
carries the owner's domain cues; what it does not carry is the collection's own facts (era, kind mix, folder title
from the label photo), which a window could receive as text at no training cost (test 5).

5. Active learning's size. Tsakalis's 29% saving in lines at a fixed WER, concentrated in the early rounds, is the
scale to expect from choosing which gaps or lines the owner sees; it is of the same order as the difference between
our review loads (Claude 10.2 checks per 100 pages against the students' 79), so the choice of what to show matters
more than the choice of selection rule, and two-model disagreement is already a selection rule with a measured AUC.

What does not transfer.

1. The material and the unit. Every adaptation figure above is on scanned lines of a single collection; ours are
phone photographs of mixed boxes, scored per page in an exact document or per page in NES. The Transkribus volumes
(15,000 words per hand) are for a CTC recogniser on lines; they say nothing about how many reviewed gaps move a
segmenter or how many corrected pages move a VLM reader.

2. The cascades. FrugalGPT and UCCI route short text queries where the small model's output is a label and the
large model's is the same label; our stages return a page of text or a set of boundaries, the "cost" is money per
page on one route and minutes per page on another, and the escalated page is often a failure (a loop) rather than
a low-margin answer. The field's recipe transfers; its numbers do not.

3. The institutional evaluations. Socface's per-field F1 and the LoC's unique-word counts measure what those
institutions needed (names and dates in a table; a cleaner index) and were computed on their own annotated samples.
None is a page-level CER on held-out archival photographs, and none can anchor our bench. What transfers is the
reporting form: a per-field table for dating and entities (B-dating's A-D classes and `Sent With` precision are the
same idea), and the honesty of Socface's "no unseen-archive test", which is the case our Lincoln figures already
expose.

4. Apple's adapter route. It was the one first-party, 32-GB-Mac training kit, and it is gone with macOS 27; the
on-device model's new image input arrives without adaptation. R1 therefore has no user-trained model at all.

Where a public benchmark makes ours less necessary, and what to borrow. Nothing here replaces our locked boxes or
the 96 and 895. Borrow: the olmOCR alignment scorer (Hirschberg word alignment, page-weighted) as the bench's
student-teacher agreement figure; UCCI's calibration-validation-test split and its cost-at-target table as the
report format for every cascade and for the review-level choice; Tsakalis's two curves (error against lines and
against words, with the saved share and the fixed-budget gain marked) as the format for the corrections curve;
Socface's per-field F1 table as the dating and entities report; the LoC two-pass gap-filling idea for region-first
reading (E's tests) where a detector misses text; CATMuS's metadata-token form for the prompt. Do not borrow:
Transkribus's rules of thumb as targets for a VLM; CoMMA's 9.7% (three lines per manuscript, press report);
McCATMuS's split-dependent accuracies.

## 6. Strand-specific questions

### 6.1 Collection-level context: what is measured and what it is worth

Measured, across the strands. Adjacent-pair and window context for segmentation: large gain over single pages
(boundary F1 0.67-0.75 to 0.84-0.88), then a plateau or decline beyond 5-10 pages for all but the strongest model,
and a whole-folder call that beat 10-page pieces for one strong model (`A-segmentation.md` claims A04; SUMMARY). The
adjacent document for dating: Gemini gives the previous document's year on 82% of strict enclosure cases and falls
to 52% exact where no printed same-year document sits within three positions; folders span many years, so the
carrier is the neighbour, not the folder (`B-dating.md`, this strand's own run). Preceding text for correction:
200-300 words, then no gain (`C-ocr.md` claim 30). Collection metadata for recognition: +0.8 points and lower
variance with century, script and language tokens together, worse with any one alone (claims 18-19). Cross-page
structure: Socface's household grouping at 76% (claim 27). Long visual context: weak on MMLongBench-Doc (claim 24).
Not measured anywhere: finding aids, box or folder labels, or earlier boxes as conditioning for page-level work;
clustering over a whole stream did not beat a start-of-document classifier in the one paper that tried it, which
`A-segmentation.md` could not open (its A12).

What this says for the Processor. The evidence supports three cheap forms of collection context and warns against
one expensive one. Cheap: (a) collection facts as text in every window and tagging call (the box and folder label
photographs' OCR, the collection's era from the dates already extracted, its kind mix from the Vision kind sorter,
the owner's catalogue line if there is one), in the all-tokens form the CHR paper found safe; (b) the adjacent
dated document as the date carrier, which B's tests already own; (c) corpus-level consistency checks after the fact
(the same letterhead or hand across a box, a boundary prior from the collection's document-length distribution,
which A's Lincoln reading says the students lack). Expensive and unsupported: a long-context pass over a whole folder
of images, which every multi-page benchmark finds worse than text-fed pipelines and which A04 shows degrading weaker
models. The one measurement to add is test 5: the same windows with and without collection facts, on the boxes
whose facts the students never saw (CREST, Lincoln), because the CHR result's size (under a point in the mean, two
points on hard material) is exactly the size that will be invisible on the development boxes and visible on
Lincoln.

### 6.2 Active learning and correction-driven adaptation: how few corrections each stage needs

What the stages need, by the evidence so far.

- Segmentation. Threshold, boundary-rate prior, window size and (for doc-split-v1) CRF and calibration refit:
tens of labelled gaps, by the UCCI arithmetic (isotonic regression needs a few hundred points to be smooth, but a
single threshold at a target can be chosen from fewer) [I]. A LoRA pass: our quarter-data pilot reached 97.1% with
about 1,470 windows (claim 49), and the field has no smaller number; `A-segmentation.md` test 4 proposes the curve
at 25-200 labelled gaps. The review screen already produces the right label (keep, split, join per gap), and two-
model disagreement is the selection rule with a measured AUC; the students' own confidence is not.
- OCR. A pretrained CTC recogniser: 20-80 corrected lines of one hand (`C-ocr.md` claim 3), low variance across
draws; the vendor's 15,000 words per hand is for training a model from the platform's base, not for adapting a
pretrained one, and Hodel's result says a general model already reads unseen hands at a median 2.76% CER. In-context
lines for API readers: 8-16 lines, measured on crops only. A VLM LoRA: no small-data success anywhere; a research
item.
- Dating. Conformal calibration: at least 15 owner-dated documents per stratum (`B-dating.md`, B47); a relation
classifier: the 33 strict and 29 chained cases are the whole truth set so far; a LoRA: 7,428 examples moved the
format and the public set, not the owner's unprinted years (claim 51), so more of the same data will not help and
the failure is knowledge, not volume.
- Layout and reading order: 20-50 corrected PAGE-XML pages for kraken `rotrain` or an Orli fine-tune (`E-layout.md`
test 9), unmeasured.

What active selection adds. One measured HTR curve (claim 15): a 29% saving in lines at a fixed error, early rounds
only, small batches, with a seed model good enough to rank. Translated to the Processor: the review screen should
show the gaps or pages a second cheap voter disputes (AUC 0.89-0.97 for pages; the Dean box showed the two cloud
models erring alike, so the second voter must be a different family or a local student), in small batches per box,
and refit the cheap layer after each box; it should not ask for a LoRA until a few hundred reviewed gaps or 40-80
corrected lines of one hand exist, and then only with a held-out check. The corrections-to-points curve by stage is
test 2.

Correction-driven adaptation's hidden cost is label noise. Our teacher calls 27.6% of tag continuations starts
where the owner found 7.9% wrong, and the agree rule keeps labels at 1.8% noise against start-trust's 5.0% (claim
52); Hodel's "diverse editorial principles ... create systematic errors" is the same problem in HTR [?, snippet of
the generic-models paper]. A kit that trains on a user's corrections inherits the user's consistency, and the
held-out check must be scored against corrections the model never saw.

### 6.3 The coding-agent training kit

Which stages it should cover, in order of evidence.

1. Segmentation threshold and prior refit, and doc-split-v1 CRF and calibration refit, from the user's reviewed
gaps. Cheapest, runs on the Mac, needs tens of labels, and the field's one cross-collection result says the
calibration layer is what shifts between corpora. Not yet built.
2. A kraken PP-OCRv6 (or script-model) fine-tune on 40-240 corrected lines of one hand, for the laptop profile's
handwriting route. Evidence specific and favourable (C). Runs on a CPU; on MPS unmeasured. Needs blla or Vision
line boxes and a line-correction screen the Processor does not have.
3. A segmentation LoRA on the user's own tagged corpus (the owner's case: per-document folders give the labels)
or on several hundred reviewed gaps, trained on a cluster, served on the Mac as a private voter beside the cloud.
Built as `train_seg.py`; it is the stage with the most measured evidence (claims 49-50) and the clearest limit
(79% on unseen boxes, 35-47% on Lincoln).
4. A dating LoRA: only as a format-and-public-set model; it did not learn the owner's inference (claim 51).
5. A VLM OCR LoRA: not in the kit until a small-data success exists.

The steps a coding agent must follow (the HF skill's discipline plus what it lacks, in our kit's terms).

1. Inventory the user's material and labels without moving it: count pages, folders with per-document structure,
reviewed gaps, corrected lines; refuse to proceed if a stage has fewer labels than its floor above.
2. Build the dataset with `train_seg.py data` (or its line-level equivalent) and validate it on the Mac before any
GPU time: schema, image paths, label balance, the no-text share, duplicates against the held-out set; hold out whole
collections or boxes, never a random page split (the McCATMuS random-split test fell seven points on out-of-domain
documents, claim 36).
3. State the cost and time before submitting: $0 on a cluster, the queue and wall time from the profile; a Mac run's
estimated hours from a 20-window pilot (`--max-windows`), which the trainer logs per step.
4. Submit with the profile's caps (`setup.sh`, `train.sbatch`), a pilot first, `--save-every` so a wall-time kill
leaves an adapter.
5. Score the adapter on the held-out collections and on a public anchor box with the same bench scorer the shipped
model used, and compare three numbers: the base model, the shipped model, and the user's model.
6. Accept only if the user's model beats the base on the user's held-out material by more than the bootstrap
interval and does not fall below the shipped model on the public anchor by more than a stated margin; otherwise
report and stop.
7. Package: keep the adapter (`adapter_config.json`, `adapters.safetensors`) beside the shipped 8-bit base, or merge
and quantise; record a manifest (below); never overwrite the shipped build.
8. Report in the app's words: the three scores, the review load per 100 pages at the app's bar, the Mac figures
(peak memory, seconds a window), and what was not tested.

The held-out check before a user's model is used. Today the kit scores students through `cluster_seg.py import`
and `method_openrouter.py report` by hand; the gate above does not exist. Its design follows from what we measured:
the in-domain held-out figure (97.6%) is not predictive of a new box (79%), so the gate needs two parts, the user's
own held-out boxes (what the model is for) and a locked public box (what it must not break), with the review load at
the 98% bar as the headline because that is what the user will do with the model. How many held-out gaps give a
stable estimate is unmeasured; test 6 bootstraps it.

Training on a Mac against Sherlock. Measured: the 2B date LoRA took 27 minutes on one L40S for 7,428 text rows; the
seg students trained in one job each on one L40S (wall time not recorded in the files read); the 2B 8-bit infers a
seven-page window in 18 s with a 4.4 GB peak on the M3 Pro (claims 50-51). Unmeasured: any training step on a Mac
for our window sizes. The arithmetic says [I]: a training step is a forward and backward pass over about 9,600
prompt tokens and seven 1,024-px images (the teacher's window size, `seg-teacher.md`), roughly three times the
inference cost, so about a minute a window on the M3 Pro, about three hours for a 200-window refit and about half a
day for 800, with memory dominated by activations and gradient checkpointing needed on 18 GB; a 32 GB Mac is the
realistic floor for the seg LoRA, as Apple also set for its 3B adapter kit. A text-only dating LoRA would be minutes
to an hour on any Mac [I]. kraken on a Mac CPU is known to work (the lab read 320 pages at 9 s a page); its
fine-tune on 40-240 lines is minutes of CPU at Kiessling's 300 steps [I from C claim 3]. On Sherlock the same LoRA
is a single-GPU job well inside the 2-day cap; the kit's Slurm profile works unchanged, with vLLM undocumented there
and Ollama documented (`J-compute.md`), so the kit's serving module must be containerised (Apptainer) or replaced by
a plain transformers scorer for the held-out check. The split the evidence supports: refits and recogniser fine-
tunes on the Mac; VLM LoRAs on the cluster; adapters, not merged weights, come back to the Mac.

How a trained model plugs into the Processor. Today: `LocalSegmenter` names one build (`seg-qwen3.5-2b-8bit`),
downloads one merged 8-bit repository (about 2.5 GB) through `mlx_vlm.server`, probes and warms the server before
the first window, and reads its figures from the options.json row, whose `Mac` block carries `download_gb`,
`peak_memory_gb`, `seconds_per_page` and `measured_on`; `WindowVoter.catalog` refuses a voter the app does not know
or whose prompt id differs; `LocalModelRoute` reaches LM Studio, Ollama or `mlx_vlm.server` for OCR with a 4,096-token
cap, a repetition check and one retry. That is a model manifest in embryo. For a user's model the routes are:

- MLX adapter beside the shipped base: supported by mlx-vlm (`load(adapter_path=)`, server `--adapter-path`),
by mlx-swift-lm in-process (`LoRAContainer`, hot-swappable), and by the trainer's quantised-base LoRA, so an adapter
trained against the 8-bit build on a GPU or a Mac should load on the Mac without a merge; whether it does so without
a quality loss is test 1. One adapter per server process in mlx-vlm; per-kind adapters (the switchable-adapters
pattern) would need a server per adapter or the Swift route. Adapter size for rank 8-16 on a 2B is tens of MB [I].
- Merged and re-quantised weights: what we ship now; a 2.5 GB download per model, and mlx-tune's warning that a
merge into a 4-bit base can lose a weak delta applies to 4-bit only.
- ONNX: the right container for doc-split-v1 (already ONNX, Apache-2.0) and for PP-OCRv6 detectors and recognisers
(ONNX variants exist, `I-inventory.md`); kraken models stay kraken files on CPU.
- Core ML: no adapter mechanism; a merged small model could be converted, but no route here needs it. Core AI
(macOS 27): custom-model runtime, no adapter topic in its documentation; `MLXLanguageModel` lets an MLX model back a
`LanguageModelSession`, which is the Swift integration path to watch.
- The manifest the kit should write and the app should read: base build id and hash; adapter hash and rank or
merged-weight hash; prompt id; training-data digest and label rule; held-out scores with intervals on the user's
collections and on the public anchor; review load at the 98% bar; Mac figures measured by the kit's own warm-up run;
the kit version. The app refuses a model whose manifest fails the prompt-id check or lacks the anchor score, as it
refuses an unknown voter today.

### 6.4 Cost-aware cascades and confidence routing across routes

What we have is already the field's recipe without its calibration step: a cheap first reader, escalation on
failure (robust, +0.8-2.8 NES on unseen pages), an optional disagreement check (strong signal, inconsistent gain on
unseen pages at 96 pages), a per-run breaker, and a kind router (`difficulty.md` §4-6; `OCRCascade`). The field adds
three things. First, calibrate whatever signal is used (UCCI: isotonic regression on a calibration split) and choose
the threshold by cost at an accuracy target on a validation split, then report cost at target on a test split; our
split-half column is the honest version of this and should become the standard table for every cascade and for the
segmentation review level. Second, use a signal that ranks: token margin ranks for UCCI's models; our students' and
teacher's self-confidence does not rank at all (every fitted level is "flag all"), while disagreement does; the
local routes can also return log-probabilities for free, which ConfBench says aggregate best as first-token or
low-probability share (C claim 45), so test 3 fits isotonic regression to both. Third, check the invariance
assumption: UCCI's theory needs the escalation route to be as accurate on escalated pages as on all pages, which our
"page mix" measure already estimates for first readers and can estimate for second readers from the cached panel.

Across routes the cascade's cost is in different units: money per page on R3-R4 and R6, window share on R5, minutes
per page on R1-R2 (40 s a page for the 8B on the M3 Pro) and GPU-hours and queue time on R7. A cost-aware router
therefore needs the user's profile to set the exchange rate: a laptop-only user pays in time and escalates to a
second Mac model (the free frontier in `difficulty.md` §4, 93.4 NES); a cheap-API user escalates failures and
disputed pages to Gemini 3.8 Flash at under $1.50 per 1,000 pages (the measured $1.25-1.39 cascades); a cluster user
pays nothing per page and routes on quality alone, with the staged region-first route for dense pages (E); a premium
user is told that one strong reader still wins at $25 (claim 53). The threshold is per profile and per collection,
refit from the collection's own first hundred pages, which is UCCI's static-calibration limit turned into a
procedure.

### 6.5 End-to-end archival systems' published evaluations

Transkribus publishes CER on held-out pages per model and project-level volumes (claims 31-34), never a cross-
collection protocol; its figures are the user's own ground truth measured by the platform. eScriptorium and kraken
publish training inventories and, for the generic models, split-dependent accuracies with known test overlap (claims
36-38); the CoMMA scale figure comes with a three-line sample per manuscript. Arkindex's public evaluation is
Socface (claims 27-28): a page classifier, a whole-table recogniser with CER 14.5% and entity F1 0.85, household
grouping at 76%, throughput, and no unseen-archive test. The Library of Congress publishes scale, design and a proxy
(unique-word reduction) and no accuracy (claims 29-30); the Harvard-Boston pipeline publishes order accuracy on 723
scans and names loops and hallucinations without a rate (E claim 27). None of these systems publishes what our bench
publishes: a locked, owner-adjudicated page set with every route scored on it, difficulty-adjusted accuracy and
failure counted apart, and cascades simulated with a split-half check. The institutional lesson is about design,
not numbers: every system that scaled chose a cheap specialist or a staged pipeline over a one-shot large model
(Tesseract with a layout model, DAN, dots.mocr on crops, kraken), measured on its own sample, and left adaptation to
the next collection as future work.

## 7. Tests to run on our material, ranked

Every OCR test runs on the 895 public pages and the owner's 96 with the same settings (owner, 2026-10-20);
segmentation tests run on the locked boxes and the two public boxes (CREST, Lincoln); dating on the 300 owner
documents and the public 300. Prices are the measured ones: Gemini 3.8 Flash $3.22 per 1,000 OCR pages
(`difficulty.md`), $3.61 per 1,000 segmentation pages at list and $1.81 in batch (`A-segmentation.md`), $4.07 per
1,000 text-only dating calls (`B-dating.md`). Mac, FarmShare and Sherlock routes are free in money.

1. **Mac LoRA feasibility and the adapter plug-in.** Profiles: coding agent, laptop. On the 18 GB M3 Pro (and a 32 GB
Mac if one is available), `mlx_vlm.lora`/`train` with LoRA rank 8 and 16 on the shipped Qwen3.5-2B 8-bit base,
`--grad-checkpoint`, on 20, 200 and 800 seg windows of the agree set: peak memory, seconds a step, hours an epoch;
then load the adapter with `--adapter-path` on the same base and score the development boxes against the merged
FarmShare 2B (90.3%); repeat for a text-only dating LoRA on 1,000 rows. Also load the FarmShare-trained adapter (not
the merge) on the Mac base and compare. Settles whether the kit can train on a Mac at all, at what memory tier, and
whether adapters replace 2.5 GB merged downloads. Free. Expected: the text LoRA fits and finishes in minutes; the
window LoRA needs 32 GB or a smaller image size [I].

2. **The corrections-to-points curve, by stage.** Profiles: all; it decides what the review screens' corrections are
worth and what the kit may promise. Segmentation: on Lincoln and Stanton at 0, 25, 50, 100, 200 labelled gaps,
threshold and prior refit; doc-split-v1 CRF and calibration refit; few-shot examples in the window prompt; a LoRA
continuation of the 2B with replay (shares `A-segmentation.md` test 4). OCR: kraken PP-OCRv6 medium on 20, 40, 80,
160, 240 corrected lines of one owner hand, measured on that hand's other pages (shares `C-ocr.md` test 4), and 8
and 16 in-context lines for the API readers. Dating: conformal coverage at 15, 30, 60 owner-dated documents per
class (shares `B-dating.md` test 4). Report each in Tsakalis's two-curve form (points against labels; the saved
share at the app's bar). Open models free on the cluster; the Gemini arms about $1 per box per setting, so two or
three settings in batch stay under $3 per stage.

3. **Calibrated confidence from local routes, UCCI style.** Profiles: laptop, cluster, cheap API. Rerun LightOnOCR-3
4B and Qwen3.5-9B on the 895 and 96 with log-probabilities on (vLLM on FarmShare; mlx-vlm on the Mac); compute
first-token, mean, minimum-k and low-probability share per page; fit isotonic regression against NES under 90 on the
440, choose the threshold by cost at a NES target on the 96, test on the 455; report cost at target beside the
disagreement and length signals and beside escalate-on-failure; check UCCI's invariance assumption on the escalation
route's escalated pages. Repeat for the seg 2B's P(new) on the development boxes against the test boxes (expected:
no ranking to calibrate; the result closes that question). Free.

4. **Teacher-inheritance audit.** Profiles: coding agent, cluster. On the test boxes and the label-clean checkpack
(80 fresh gaps, owner-scored), split each student's errors into gaps where the teacher erred the same way and gaps
where it did not; compute olmOCR's word-alignment analogue (gap agreement) beside accuracy against the owner. On the
dating model, the same for the 131 unprinted years against Gemini's answers. No calls; cached answers; an owner
review of the 80 gaps when the review-timing rule allows. Decides whether a second, different-family teacher or
owner-only labels are needed for the kit's label step.

5. **Collection facts as context.** Profiles: all. The window prompt and the tagging prompt with and without a
collection block (box and folder label OCR, era from extracted dates, kind mix from the Vision sorter, document-
length prior), in the all-facts form; the 2B student, the 27B teacher and Gemini 3.8 Flash on CREST and Lincoln
(facts the students never saw) and on the test boxes; boundary F1 and pages exact; a 2B LoRA variant with the block
in its training rows as a second arm. Free for open models; Gemini on 389 + 363 pages about $2.70 at list, $1.40 in
batch. Expected from the CHR result: under a point on the owner's boxes, more on Lincoln, and a loss if any single
fact is sent alone.

6. **The held-out gate.** Profiles: coding agent. Build `train_seg.py check` (or a kit script): score base, shipped
and candidate models on the user's held-out collections and on a locked public box with the bench scorer; bootstrap
the pages-exact and review-load figures over 100, 300 and 1,000 held-out gaps to find the smallest held-out set
whose interval separates a 3-point difference; write the manifest in §6.3; have `LocalSegmenter` refuse a model
without an anchor score. Free; a measurement of interval width plus engineering.

7. **kraken on Apple Silicon: CPU against MPS.** Profiles: laptop, coding agent. `ketos train -d mps` and `-d cpu`
with kraken 7.1 and torch 2.14 on the 40-240 line sets of test 2: minutes per run, identical CER or not, memory.
Also blla segmentation time on MPS. Free. Decides whether the recogniser fine-tune is a minutes-long Mac step.

8. **Which gaps and pages to show: selection rules for the review screen.** Profiles: all. From cached answers on
the test boxes and Lincoln: random, the 2B's low confidence, two-model disagreement (2B against Gemini; 2B against
doc-split-v1), Vision kind change, teacher-student disagreement; accuracy after checking at 10, 25, 50 checks per 100
pages. For pages: the same for disagreement and length against the per-page NES on the 96 and 895. Free. Expected:
disagreement near the top for pages (AUC 0.89-0.97 already), and the size of the gain in Tsakalis's range.

9. **The on-device Foundation Model as a free first voter (macOS 27).** Profiles: laptop (R1). On a macOS 27 Mac
with Apple Intelligence, the on-device model with image attachments on the 96 and on 100 pages of the 895, and as a
text-only segmentation voter on one development box: NES, failures, seconds a page, tokens per image at our
resolutions; its disagreement with Apple Vision as a routing signal. Free; needs a macOS 27 machine, which the lab
does not have today (unverified).

10. **Transkribus and Arkindex as R6 comparators.** Profiles: commercial services. Transkribus's public Text Titan
or the closest print model on 25 handwritten pages of the 96 and 40 of L1, scored with our NES; Arkindex only if a
trial exists. Credits or per-page fees unknown [?]; low priority, only if the owner wants R6 populated with our own
figures. Note that the Jha benchmark already scores Text Titan on order (E claim 15).

## 8. Open questions

1. Can a 2B LoRA over seven 1,024-px images train on an 18 GB Mac at all, and in what time? Nothing published;
test 1.
2. How many reviewed gaps or corrected lines move each stage by a point? No published VLM curve; test 2.
3. Does the students' P(new) or a local reader's log-probability rank its errors once calibrated, or is disagreement
the only ranking signal we have? Test 3.
4. How much of the students' error is the teacher's? Test 4 and the pending 80-gap owner check.
5. What does a finding aid or a label photo buy? No measurement anywhere; test 5 is the first.
6. Does Core AI accept adapters, and will the Foundation Models framework get adapters back on macOS 27? Nothing in
the documentation read; the toolkit is ended.
7. Does Sherlock run vLLM in Apptainer on the H100 and L40S nodes, and does a compute node reach Hugging Face?
Asked of support in `J-compute.md`; the kit's held-out gate needs a scorer that runs there.
8. Is the switchable-adapters chapter's result (per-style adapters beat one adapter) quantitatively meaningful? The
full text is paywalled; its abstract agrees with our per-kind-adapter idea and that is all it says.
9. Where do a user's corrections live, and in what form, so that a later kit run can use them? The review screens
produce keep/split/join and date edits in the run records; line corrections for OCR have no screen.

## 9. Route table

Both-sets rule: every test named here runs on the 895 and the 96 for OCR, the locked and public boxes for
segmentation, and the owner's 300 and the public 300 for dating.

| Route | Best candidate(s) for adaptation, context and routing | Evidence | Licence on this route | Settling test |
|---|---|---|---|---|
| R1 Mac built-in (Vision, Core ML, Foundation Models, Core AI) | No user-trained model: Apple's adapter toolkit ended at 26.0.0 and is incompatible with macOS 27; the macOS 27 on-device model gains image input and could be a free first reader or voter in a cascade; Core AI runs custom models with no adapter mechanism; `MLXLanguageModel` backs the framework with an MLX model. Apple Vision remains the free disagreement partner (AUC 0.95 as the best partner for one route; its word count against a reader's gives AUC 0.78-0.89 for every cheap reader) | claims 40-42, 53 | Apple frameworks; entitlement was needed to ship adapters | test 9; none for adaptation (search: toolkit page, WWDC26 session, docs JSON) |
| R2 Mac open weights (MLX, llama.cpp, ONNX) | 16 GB: the shipped 2B 8-bit seg model as a private voter; doc-split-v1 (ONNX) with CRF and calibration refit; kraken PP-OCRv6 fine-tune on 40-240 lines, CPU, MPS unmeasured; text-only dating LoRA locally. 32 GB+: a seg LoRA on the Mac in mlx-vlm (quantised-base LoRA supported), adapters loaded by `--adapter-path`; mlx-swift-lm `LoRAContainer` for an in-process route; per-kind adapters only with one server each | claims 43-47, 49-51; C claim 3; A doc-split-v1 | mlx-vlm MIT; mlx-tune Apache-2.0; kraken Apache-2.0; Qwen3.5 Apache-2.0; doc-split-v1 Apache-2.0 | tests 1, 2, 7, 8 |
| R3 cheap API (OpenRouter) | No training; adaptation by in-context lines (8-16) and few-shot gap examples; first stage of the measured cascades (Qwen3.8 Flash at $0.60, Qwen3.6 35B-A3B at $0.60 per 1,000 pages); calibration needs log-probabilities, which the pinned endpoints are not known to return [?] | claim 53; C claim 38 | Apache-2.0 weights; provider terms per pinned endpoint | test 3 (API arm only if log-probabilities are returned); test 2's in-context arm |
| R4 premium API (Gemini, Claude, OpenAI, Mistral; batch) | The escalation stage and the disagreement partner; the teacher for labelling where the owner has no tags (olmOCR used GPT-4o; we used the 27B); no fine-tuning route checked for our tasks [?] | claims 9-13, 53; `seg-students.md` | provider terms; Gemini 3.8 Flash price doubles 1 Jan 2027 (`J-compute.md`) | test 5's Gemini arm ($1.40 batch); test 2's Gemini arms (under $3 per stage) |
| R5 subscriptions via a local agent CLI | The coding agent itself: Claude Code or Codex runs the kit (the HF skill's discipline; mlx-vlm ships Claude Code and Codex skills for inference and conversion, none for training); `claude -p` as a segmentation voter with the plan meter | claim 39; mlx-vlm README `skills/`; `PlanUsage` | plan terms; no key; no money | a dry run of the kit end to end through Claude Code on the owner's tagged corpus with FarmShare as the cluster (free), reporting window share |
| R6 commercial document services (Document AI, Azure, Textract, Extend, Transkribus, Arkindex) | Transkribus: model training built in, 15,000 words per hand, CER 2-8% on hands, held-out pages scored by the platform; Arkindex: Socface's DAN pipeline (CER 14.5%, entity F1 0.85) for tables; the cloud vendors' custom extraction training was not researched for our tasks [?] | claims 27-28, 31-35 | per-page fees, credits; data leaves the Mac | test 10, low priority |
| R7 cluster (Sherlock design target, FarmShare fallback) | The kit's LoRA passes (one L40S; 2B text LoRA 27 min); teacher labelling with vLLM (16,443 windows in four L40S shards); the held-out gate's scorer; UCCI calibration from vLLM log-probabilities; Socface-style per-field evaluation of dates and entities. Sherlock: 2-day cap, Ollama documented, vLLM undocumented, Apptainer available | claims 49-52, 55; `J-compute.md` | Apache-2.0 models; research-only data acceptable in a user's own kit; Sherlock needs a faculty sponsor | tests 2, 3, 4, 6; the Sherlock support questions in `J-compute.md` |
| R8 hybrids (cascades, stage splits) | Train on the cluster, adapt and serve on the Mac (adapters, not merges); label with the teacher on the cluster, correct on the Mac review screen, refit thresholds and priors on the Mac after each box, LoRA on the cluster when a few hundred corrections exist; cascade with a calibrated, cost-chosen threshold per profile and per collection; disagreement, not self-confidence, chooses what the user sees; collection facts as text in every call | claims 1-5, 15-19, 53 | mixed by stage; the paid stage inherits R3 or R4 terms | tests 3, 5, 6, 8 together define the design; test 1 decides whether the Mac can do more than refits |
