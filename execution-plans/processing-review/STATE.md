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
- [ ] Add a Sherlock profile to `scripts/segbench/institutional-compute/` once the account exists (strand J
  gathers its partitions, GPU types and limits first).

## Phase 1 strands

| strand | screen | deep read | checked | note |
|---|---|---|---|---|
| A segmentation | done, `screens/A-screen.md` | done 2026-10-20 (Fable), `A-segmentation.md` | Lincoln figures checked against lincoln-scores.json | done |
| B dating | done 2026-10-20, `screens/B-screen.md` | started (Fable) | | |
| C OCR and HTR | done 2026-10-20, `screens/C-screen.md` | started (Fable) | | |
| D enhancement and marks | done 2026-10-20, `screens/D-screen.md` | started (Fable) | | |
| E layout | done, `screens/E-screen.md` | | | |
| F text placement | done, `screens/F-screen.md` | | | |
| G entities | done, `screens/G-screen.md` | | | |
| H whole-corpus and user training | done, `screens/H-screen.md` | | | |
| I model inventory | done, `I-inventory.md` | n/a | | done |
| J compute and prices | done, `J-compute.md` | n/a | | done |

## Usage

Before the screens (2026-10-20 ~21:00): weekly all-models 3%, weekly Fable 0%. After Phase 0, ten screens and inventories (Sonnet) and strand A's Fable read: weekly
all-models 6%, weekly Fable 3%. One Fable deep read is therefore about 3% of the Fable window.

The owner's Gemini report is assessed in `screens/gemini-report-2026-10-20.md` (HR-DocStream does not exist).
