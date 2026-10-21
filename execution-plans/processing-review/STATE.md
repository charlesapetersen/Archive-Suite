# Processing review — state

Plan: `00-plan.md`. Gate: `W46.review-done` in the HOLD QUEUE of `.maintenance/AUTONOMOUS_PLAN.md`.

## Resume

Read `00-plan.md`, then this table. Take the first phase step not done. Strand notes go beside this file as
`<letter>-<name>.md`. Update this file at the end of every step.

## Phase 0

- [x] 2026-10-20 — every processing item behind `W46.review-done`; Processor UI items freed from `W42.int-done`.
  Plan backup: `.maintenance/AUTONOMOUS_PLAN.md.pre-regate-20261020T*`.
- [x] 2026-10-20 — scored the collected FarmShare open-model outputs: six models from the open sweep, Ling 3
  Flash VL (1860274), stock PP-OCRv6 (1860044) and the three Qwen 27B/35B comparison rows, all 895 pages:
  `ArchiveProcessor/segbench-results/bench-corpus/open-sweep-20261019.md`; ArchiveOCRBench Part 7. A review
  baseline; nothing adopted.
- [x] Nemotron job 1860275: TIMEOUT at 20:54 on 2026-10-20 with 839 of 895 pages read (631 ok, 207 cap, 1
  malformed); 56 unread. Not scored. Owner: dropped, no third submission.
- [ ] Run the models scored on the 895 but not yet on the owner's 96 pages (owner, 2026-10-20, both sets every
  time; jobs 1861696-1861703, same settings as the open sweep). **Seven scored 2026-10-21** (jobs
  1861696-1861702, collected after the login was reopened): NES on the 96, failures as 0, Qwen3-VL 8B 92.52,
  Qwen3.5 4B 90.95, GLM-OCR 90.90, LightOnOCR-3 4B 89.38 (Mac 8-bit 89.13), LightOnOCR-3 0.8B 88.00,
  PaddleOCR-VL 1.5 83.78 (11 caps), PP-OCRv6 76.85. `ArchiveProcessor/segbench-results/farmshare/truth96-20261020.md`;
  ArchiveOCRBench Part 4. A review baseline; nothing adopted. **Ling 3 Flash VL (1861703) still pending** (needs a
  four-GPU node); collect and score it per `execution-plans/truth96-farmshare-20261020.md`, then tick this.
- [ ] Add a Sherlock profile to `scripts/segbench/institutional-compute/` once the account exists (strand J
  gathers its partitions, GPU types and limits first).

## Phase 1 strands

| strand | screen | deep read | checked | note |
|---|---|---|---|---|
| A segmentation | done, `screens/A-screen.md` | done 2026-10-20 (Fable), `A-segmentation.md` | Lincoln figures checked against lincoln-scores.json | done |
| B dating | done, `screens/B-screen.md` | done 2026-10-20 (Fable), `B-dating.md` | enclosure split rerun: 33/75/21 of 131 and model figures reproduce (`scripts/segbench/enclosure_split.py`) | done |
| C OCR and HTR | done, `screens/C-screen.md` | done 2026-10-20 (Fable), `C-ocr.md` | Kiessling Latin 8.70/13.07 and Polay WERs checked in the PDF texts | done |
| D enhancement and marks | done, `screens/D-screen.md` | done 2026-10-20 (Fable), `D-enhancement.md` | UVDoc MIT licence checked | done |
| E layout | done, `screens/E-screen.md` | done 2026-10-20 (Fable), `E-layout.md` | NewsBench figures match our farmshare/news results | done |
| F text placement | done, `screens/F-screen.md` | done 2026-10-20 (Fable), `F-placement.md` | lab figure checked: vision-ocr HW-BUILD-2026-10-15.tsv (placed 0.654; 96 to 367 missed per 1,000) | done |
| G entities | done, `screens/G-screen.md` | done 2026-10-21 (Fable), `G-entities.md` | probe rerun: fill rates, agreement and cue figures reproduce; the 81/9/10 provenance split does not (strict match 74.0%), marked [?] | done |
| H whole-corpus and user training | done, `screens/H-screen.md` | done 2026-10-21 (Fable), `H-corpus.md` | | done |
| K kind identification and mixed pages | self-screened (29 candidates) | done 2026-10-21 (Fable), `K-kinds.md` | readers' own kind labels rechecked from ocr-pages.csv (Qwen3-VL 235B 94/96, Sonnet 92/96, Gemini 3.8 Flash 87/94) | done |
| L phone capture | self-screened (39 candidates) | done 2026-10-21 (Fable), `L-capture.md` | capture split rerun (`scripts/segbench/capture_attrs.py pages.tsv ocr-pages.csv`); companions' default camera settings checked in code | done |
| I model inventory | done, `I-inventory.md` | n/a | | done |
| J compute and prices | done, `J-compute.md` | n/a | | done |

## Usage

Before the screens (2026-10-20 ~21:00): weekly all-models 3%, weekly Fable 0%. After Phase 0, ten screens and inventories (Sonnet) and strand A's Fable read: weekly
all-models 6%, weekly Fable 3%. One Fable deep read is therefore about 3% of the Fable window.
After strands B (running), C and D: weekly all-models 12%, Fable 15%; the 5-hour window 65%. A read costs
4-5% of the Fable week, so G, H and K wait for the 5-hour reset (07:40 UTC). At 21:52 local the 5-hour window was 93%, Fable week 23%.

The owner's Gemini report is assessed in `screens/gemini-report-2026-10-20.md` (HR-DocStream does not exist).

## Phase 2

- [x] 2026-10-21 — gap audit drafted (Fable) and checked: `10-gap-audit.md`, 40 ranked items, seven owner decisions.
- [x] Owner's decisions on section 6 (2026-10-21):
  1. Paid arms released, Stanford AI API gateway first (about $32 there, about $2 personal); up to the gateway's
     $50 a month, not spent for its own sake. Owner to request Gemini 3.7 Flash, Claude 5 Sonnet, GPT 5.6 Luna and
     GLM 5.3 Flash on the gateway; until then gateway arms wait.
  2. Labelling: the owner takes the judgement sets (short passes about 3.5 h, the two new boxes about 2 h, about 40
     marks pages about 6-7 h); placement boxes, capture tags and the rest are drafted by models and audited.
  3. Request Reading the Archive's gated gold: yes (owner's request via the Zenodo record).
  4. Sherlock: the owner has already asked the sponsor.
  5. Lock two more segmentation boxes, one clippings-heavy and one handwritten; the owner names them.
  6. W46.seg-window-modality's full 551-page Gemini sweep approved (about $8 list, $4 batch).
  7. Plan-route cap: superseded by the gateway-first rule; gateway use up to $50 a month.
- [x] File the Phase 3 items with plan-edit.sh (each behind its prerequisites; gateway arms behind the model-access gate).
  Phase 3 filed 2026-10-21, 74 items and 11 owner gates: three cluster-infrastructure items first, then the audit's 40
  in rank order, with gateway arms split into `-paid` items, owner passes split into sheet, gate and score, and the
  Sherlock-scale parts split out. List in `SUITE_TODO.md` §"Document processing review — W46". Plan backup:
  `.maintenance/AUTONOMOUS_PLAN.md.pre-phase3-20261021T081333`.
- Engine paused for Archive Suite by the owner during Phase 2 (2026-10-21; `manager.py resume "Archive Suite"`).

## Owner answers, 2026-10-21 (after Phase 3 was filed)

- macOS 27: the owner can upgrade this Mac; not done. W46.macos27-ok stays open until the owner upgrades for other
  reasons or asks for it; W46.r1-foundation is a low-ranked free-voter test and does not justify an OS upgrade alone.
- 32 GB Mac: available only if really necessary. W46.kit-mac-lora runs the 18 GB arm first; the 32 GB arm is asked
  for only if the 18 GB arm cannot fit the training at all.
- Ling 3 Flash VL's 96-page job (1861703) was still PENDING (Resources) at 08:40 on 2026-10-21.
- p009 (owner): a photograph of a typed DEC document dated 23 July 1993 with a large yellow sticky note on top;
  handwriting on the note and on the page. The next photo (Computer History Museum/DEC Records 00097) shows the page
  without the note. Its truth text was drafted from 00096 alone, so text under the note is missing or guessed;
  W46.fix-ocr-truth-bias re-checks it. New review case M in 00-plan.md.
- Handwritten locked box (owner): the Rawls papers, `05 Final Tagging/5 Priority 5/Rawls papers`, 1,764 ABBYY PDFs
  tagged only with 17 box (red) and 37 folder (purple) labels, which may be incomplete; no document tags. Proposed
  slice: images 00057-00252 (196 pages, three folders after the box label at 00056), boundaries drafted by a model and
  ruled by the owner. More owner time than an already-tagged box (about 2-3 h rather than 1 h).
- Clippings locked box: Deaver is a development box and cannot be the locked test. Candidates ranked by share of
  clipping-tagged pages were shown to the owner; the owner picks one.
