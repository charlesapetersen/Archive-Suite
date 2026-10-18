# The broader OCR truth set (W43.corpus-build, W43.corpus-build-more)

Plan: `execution-plans/benchmark-corpus/00-plan.md` (Part 1 is the owner's decision of 2026-10-16). Code:
`ArchiveProcessor/scripts/segbench/corpus/` (`sample.py` draws, checks, freezes and keeps; `routes.py` runs and
scores the reference routes). Scores only: no page image or text is published, whatever its licence.

## What is frozen

895 pages in all fifteen strata, drawn with the original fixed seed (`SEED` in `sample.py`), with a quarter cap
per collection unless a thin stratum requires an exception (`over_cap`). The original 440 pages were frozen on
2026-10-17; the 455-page extension is frozen on 2026-10-18, before any paid reading. Every field of the original
440 manifest rows is unchanged. The kept copies, checked against the manifest's checksums, are in
`~/Library/Application Support/ArchiveSuiteRehearsal/bench-corpus-frozen/`; whether CrashPlan backs that folder
up has not been checked. Images and truth are kept privately; this repository publishes provenance and scores only.

| stratum | pages | sources |
|---|---:|---|
| L1 English handwritten letters and diaries | 80 | Library of Congress By the People |
| L2 English manuscripts, 1700-1850 | 80 | By the People Washington Papers 60, Bentham 20 |
| L3 typescripts and telegrams | 80 | By the People 78, TAPUS French typescripts 2 |
| L4 ledgers, forms and tables | 80 | Smithsonian Freedmen's Bureau, four register projects |
| L5 Dutch and Romance archival hands | 80 | HTR-United Castilian 51, iForal 26, VOC 3 |
| L6 German Kurrent | 80 | 19th-c. Kurrent (Zenodo 17252677) 60, READ 2017 20 |
| L7 charters before 1600 | 80 | Königsfelden |
| L8 early print, incl. Fraktur | 80 | OCR-D `gt_structure_text` |
| L9 newspapers | 15 | NewsBench |
| N1 Arabic manuscripts | 40 | Muharaf, public part |
| N2 Cyrillic | 40 | Digital Peter, full handwritten pages |
| N3 Greek minuscule | 40 | EPARCHOS (30 over the quarter cap: one collection dominates) |
| N4 Hebrew book hands | 40 | BiblIA |
| N5 Chinese print | 40 | OmniDocBench, simplified and traditional Chinese |
| N6 Devanagari print | 40 | heiDATA Naval Kishore Press, full-page ALTO/PAGE pairs |

Original 440-page sanity pass: Apple Vision read the 320 Latin pages; the 46 under half their stratum's median were opened against
their truth, with the shortest truth in each stratum and one page each of N1, N3 and N4. Two were dropped and
replaced (`drops.jsonl`). The hand check also found BiblIA's columns in the wrong order (fixed before the freeze).
The extension adds L1-L4, L9, N2, N5 and N6. L9 is short by 65: BLN600 remains behind Sheffield's bot challenge, and SBB was excluded as a whole after the image/truth audit below.
MTHv2 remains unavailable on the allowed hosts, so N5 has no historical MTHv2 component. PHaEDRA's old export
has no verified full-resolution image mapping on the allowed hosts, so L4 uses the four Freedmen's Bureau
registers only. No substitute source was added.

Checks for the extension (2026-10-18): Smithsonian editorial margin/table labels and malformed
closing tags are removed while the visible words stay. Vision sanity refuses failed OCR jobs or missing output;
an existing empty output remains a legitimate blank reading. By the People kind exclusions and OmniDocBench figure-text omissions
are recorded in `drops.jsonl` and replaced further down the same seeded order; pages are never dropped merely
because Vision reads them poorly. OmniDocBench's invisible Markdown heading markers are removed. Its photo
figures may remain where they omit no visible lettering.

The final extension sanity pass read **655 Latin pages** in all (320 original plus 335 added). The 26
flags in the added strata were visually compared with their truth and retained: difficult hands, layout
and genuine historical endorsements, rather than mismatched transcription. Non-Latin pairs were checked
visually, and N5 figure-bearing pages and their replacements were checked for omitted text. The provenance
record is `sanity-review.json`; there are 133 recorded exclusions and 42 quarter-cap exceptions overall.

**SBB source exclusion.** The [Zenodo record](https://zenodo.org/records/2583866) calls `gt_page.zip` OCR/OLR
ground truth, distinct from `ocr_full.zip`. Visual comparison nevertheless found systematic incorrect words
in legible scan text (00675574, 00675515, 00675581 and 00675590); the PAGE metadata names FineReader Engine 10.
That is evidence that its text is unreliable for this whole-page OCR comparison, regardless of its intended
use. All 41 initially eligible SBB pages are excluded, including those Vision read well. `src_sbb.candidates`
contributes no pages; the parser remains for reproducing the finding. This corrects the initial assumption
that its text was a keyed transcription. No SBB page was frozen or scored by a hosted route.

## Added pages and deferred readings

The original reference run remains bound to `manifest-reference-440.jsonl`, an exact snapshot, rather than
silently reusing its ledger with a larger input set. The table below still reports **only those 440 pages**.
The **455 added pages have no hosted reference scores**: the owner's 2026-10-17 paid-run hold defers both
routes to W43.sweep. The register is `execution-plans/paid-runs-deferred.md`. At the original run's measured
$0.0066 per page for both routes, the extension alone is about **$3.00**, an estimate, not a new charge.
Zero dollars were spent adding the extension; the earlier $3.06 booking and $2.04 remaining cap are unchanged.

To run an extension later, set **both** `BENCH_CORPUS_RUN` (a new run directory) and `BENCH_CORPUS_MANIFEST`
(the extended manifest). `routes.py` refuses setting only one. Keep the original paid run and its readings
separate. W43.sweep prices all deferred runs and obtains the owner's approval first.

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
