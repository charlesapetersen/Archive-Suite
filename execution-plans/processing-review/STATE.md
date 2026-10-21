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
- [ ] Nemotron job 1860275: still RUNNING at 20:55 on 2026-10-20, ending at its 7 h limit. When it ends, count the
  clean readings (`execution-plans/general-model-sweep-20261019.md`, "Checking Nemotron"). A partial cache is not
  scored; a third submission is the owner's call.
- [ ] Add a Sherlock profile to `scripts/segbench/institutional-compute/` once the account exists (strand J
  gathers its partitions, GPU types and limits first).

## Phase 1 strands

| strand | screen | deep read | checked | note |
|---|---|---|---|---|
| A segmentation | done 2026-10-20, `screens/A-screen.md` | started (Fable) | | |
| B dating | done 2026-10-20, `screens/B-screen.md` |  | | |
| C OCR and HTR | done 2026-10-20, `screens/C-screen.md` |  | | |
| D enhancement and marks | done 2026-10-20, `screens/D-screen.md` |  | | |
| E layout | | | | |
| F text placement | | | | |
| G entities | | | | |
| H whole-corpus and user training | | | | |
| I model inventory | | | | |
| J compute and prices | | | | |

## Usage

Before the screens (2026-10-20 ~21:00): weekly all-models 3%, weekly Fable 0%. The four Sonnet screens and
strand A's Fable read are measured against that.
