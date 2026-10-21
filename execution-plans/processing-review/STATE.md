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
  time): GLM-OCR, LightOnOCR-3 0.8B and 4B at bf16 (the 4B has only a Mac 8-bit run, 89.13), PaddleOCR-VL 1.5,
  Qwen3.5 4B, Ling 3 Flash VL and stock PP-OCRv6, on FarmShare, same settings as the open sweep.
  Status: submitted 2026-10-20, jobs 1861696–1861703 (one afterany chain, Qwen3-VL 8B added at 1861701, Ling
  last); collect and score per `execution-plans/truth96-farmshare-20261020.md`.
- [ ] Add a Sherlock profile to `scripts/segbench/institutional-compute/` once the account exists (strand J
  gathers its partitions, GPU types and limits first).

## Phase 1 strands

| strand | screen | deep read | checked | note |
|---|---|---|---|---|
| A segmentation | done, `screens/A-screen.md` | done 2026-10-20 (Fable), `A-segmentation.md` | Lincoln figures checked against lincoln-scores.json | done |
| B dating | done, `screens/B-screen.md` | done 2026-10-20 (Fable), `B-dating.md` | enclosure split rerun: 33/75/21 of 131 and model figures reproduce (`scripts/segbench/enclosure_split.py`) | done |
| C OCR and HTR | done, `screens/C-screen.md` | done 2026-10-20 (Fable), `C-ocr.md` | Kiessling Latin 8.70/13.07 and Polay WERs checked in the PDF texts | done |
| D enhancement and marks | done, `screens/D-screen.md` | done 2026-10-20 (Fable), `D-enhancement.md` | UVDoc MIT licence checked | done |
| E layout | done, `screens/E-screen.md` | started (Fable) | | |
| F text placement | done, `screens/F-screen.md` | started (Fable) | | |
| G entities | done, `screens/G-screen.md` | | | |
| H whole-corpus and user training | done, `screens/H-screen.md` | | | |
| I model inventory | done, `I-inventory.md` | n/a | | done |
| J compute and prices | done, `J-compute.md` | n/a | | done |

## Usage

Before the screens (2026-10-20 ~21:00): weekly all-models 3%, weekly Fable 0%. After Phase 0, ten screens and inventories (Sonnet) and strand A's Fable read: weekly
all-models 6%, weekly Fable 3%. One Fable deep read is therefore about 3% of the Fable window.
After strands B (running), C and D: weekly all-models 12%, Fable 15%; the 5-hour window 65%. A read costs
4-5% of the Fable week, so G and H wait for the 5-hour reset (07:40 UTC).

The owner's Gemini report is assessed in `screens/gemini-report-2026-10-20.md` (HR-DocStream does not exist).
