# The broader OCR truth set — reachable strata (W43.corpus-build)

Plan: `execution-plans/benchmark-corpus/00-plan.md` (Part 1 is the owner's decision of 2026-10-16). Code:
`ArchiveProcessor/scripts/segbench/corpus/` (`sample.py` draws, checks, freezes and keeps; `routes.py` runs and
scores the reference routes). Scores only: no page image or text is published, whatever its licence.

## What is frozen

440 pages in the seven strata every allowed host reaches, drawn with a fixed seed (`SEED` in `sample.py`), no
collection more than a quarter of its stratum unless the stratum has too few (`over_cap`, 37 pages), and frozen in
`manifest.jsonl` before any paid model read them (2026-10-17). The kept copies, checked against the manifest's
checksums, are in `~/Library/Application Support/ArchiveSuiteRehearsal/bench-corpus-frozen/` (2.0 GB; whether
CrashPlan backs that folder up has not been checked).

| stratum | pages | sources |
|---|---:|---|
| L5 Dutch and Romance archival hands | 80 | HTR-United Castilian 51, iForal 26, VOC 3 |
| L6 German Kurrent | 80 | 19th-c. Kurrent (Zenodo 17252677) 60, READ 2017 20 |
| L7 charters before 1600 | 80 | Königsfelden |
| L8 early print, incl. Fraktur | 80 | OCR-D `gt_structure_text` |
| N1 Arabic manuscripts | 40 | Muharaf, public part |
| N3 Greek minuscule | 40 | EPARCHOS (30 over the quarter cap: one collection dominates) |
| N4 Hebrew book hands | 40 | BiblIA |

Sanity pass: Apple Vision read the 320 Latin pages; the 46 under half their stratum's median were opened against
their truth, with the shortest truth in each stratum and one page each of N1, N3 and N4. Two were dropped and
replaced (`drops.jsonl`). The hand check also found BiblIA's columns in the wrong order (fixed before the freeze).
L1-L4, N2, N5, N6 and the short L2, L3 and L9 are `W43.corpus-build-more`.

## The reference routes (2026-10-17)

The 96's prompt, 2400 px inputs and scorer, through the panel's write-ahead ledger. NES %, failures scored 0;
"answered" leaves failures out; the second score maps historical letter forms (L5-L8) or drops diacritics (N1,
N3, N4).

| stratum | Gemini 3.8 Flash | answered | 2nd | Qwen3-VL 235B | answered | 2nd | Apple Vision |
|---|---:|---:|---:|---:|---:|---:|---:|
| L5 | 63.2 | 64.0 | 65.6 | 54.1 | 62.7 | 55.7 | 38.4 |
| L6 | 72.9 | 85.7 | 73.7 | 47.7 | 57.0 | 48.2 | 22.4 |
| L7 | 58.0 | 59.4 | 60.0 | 42.5 | 51.6 | 43.7 | 16.3 |
| L8 | 87.8 | 90.0 | 90.7 | 86.7 | 87.8 | 89.6 | 72.8 |
| N1 | 74.7 | 80.7 | 75.8 | 44.8 | 56.0 | 49.5 | – |
| N3 | 88.8 | 91.1 | 90.3 | 47.9 | 51.8 | 54.2 | – |
| N4 | 46.1 | 46.1 | 67.8 | 12.3 | 32.8 | 14.8 | – |
| all | 70.3 (419/440) | 73.8 | | 51.6 (365/440) | 62.1 | | 37.5 (Latin, 320) |

**It separates readers.** Gemini minus Qwen, paired page by page (`routes-paired.json`): 18.7 NES points over
all 440 pages (95% interval 16.1 to 21.5, permutation p 0.0005); clear in six strata, from L5's 9.1 (4.9 to 13.6)
to N3's 40.9; not in L8, early print, where both read well (1.1, interval -2.7 to 4.5, p 0.62). The 96 could not
separate readers 1 NES apart; how small a gap this set resolves is for `W43.sweep`, with more routes.

**Cost.** $3.06 booked, an upper bound: seven calls a tool timeout or a stop cut off are booked at the key's
day-billing ceiling ($0.020 each). Gemini $0.0042 a page (1,443 prompt and 886 completion tokens on average; the
Hebrew pages about $0.010, three times the rest), Qwen $0.0024 (3,600 and 1,944). The plan had assumed $0.0047 a
page for the two together; the measured figure is $0.0066, and the plan's 50% headroom for other scripts was too
little for Hebrew.

**Failures.** Gemini's 21 were provider errors (HTTP 500 mid-reply, not billed); the panel's rule scores them 0
and they were not re-asked. Qwen's 75 ran to the 8,192-token limit, mostly repeating one line: 25 of the 40 Hebrew
pages, and 11-14 in each of L5, L6 and L7.

**Caveats.** Each source keeps its own transcription conventions, so a stratum is comparable across routes, not
with the 96 or with another stratum. N4 understates every route: its truth is the main text only (the prompt asks
for everything, masorah included) and almost all of it carries no vowel points, which Gemini writes; its
second score is the fairer one. Apple Vision runs the app's settings (English, language correction on), so it
reads only the Latin strata, and reads old hands poorly.

Files: `manifest.jsonl` (the frozen pages), `drops.jsonl`, `routes.csv` (by route and stratum),
`routes-pages.csv` (by route and page, public page ids, no text), `routes-paired.json`.

Script specialists (W43.script-specialists): open line models built for these hands, read on the Mac with
kraken, in [`specialists.md`](specialists.md) (`specialists.csv`, `specialists-pages.csv`).
