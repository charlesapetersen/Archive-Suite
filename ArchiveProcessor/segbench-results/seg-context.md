# W46.seg-context — what a COLLECTION FACTS block buys the window prompt

Every segmentation window was sent twice to the same model: once as the bench has always sent it (base), and once
with one COLLECTION FACTS block above the OCR section (block). The block states, for the whole box, the catalogue
line and item count (CREST, Lincoln) or what the box and folder label photos' OCR reads (Stanton, RG165); the span of
years in the box's OCR; the share of pages with little OCR text; and a document-length prior (pages per catalogue
item, or the owner's three development boxes' document lengths). Nothing in it comes from the box's own boundaries.
Models: the Qwen3.5 27B teacher (FP8) and the trained Qwen3.5 2B student (`fs-seg-2b`, merged at full precision),
both on vLLM 0.31.0 on one Sherlock L40S, the card FarmShare used. 255 windows x 2 arms x 2 models = 1,020 requests,
all answered, none failed. Teacher 44 minutes, student 4. Scores: `seg-context.json`
(`seg_context.py score`). Owner boxes use truth photos, public boxes the model's own, as `public_segmentation.py`
does.

## Results

| Model | Box | Pages exact, base → block | Boundary F1 | False splits | False merges | Votes the block flips | Votes a rerun flips |
|---|---|---|---|---|---|---|---|
| 27B teacher | CREST (128 pp) | 95.3% → 95.3% | 96.8 → 96.8 | 2 → 2 | 0 → 0 | 2 / 254 | 0 / 254 |
| 27B teacher | Lincoln (261 pp) | 34.9% → 37.9% | 79.2 → 79.0 | 42 → 38 | 0 → 3 | **22 / 520** | 6 / 520 |
| 27B teacher | Stanton (250 pp) | 81.9% → 79.8% | 91.4 → 91.0 | 19 → 20 | 1 → 1 | 5 / 498 | 2 / 498 |
| 27B teacher | RG165 (113 pp) | 86.2% → 86.2% | 91.7 → 91.7 | 3 → 3 | 1 → 1 | 0 / 224 | 1 / 224 |
| 2B student | CREST | 82.0% → 91.4% | 91.8 → 93.3 | 3 → 2 | 2 → 2 | 1 / 254 | 1 / 254 |
| 2B student | Lincoln | 32.2% → 35.6% | 76.5 → 77.2 | 46 → 44 | 2 → 2 | **9 / 520** | 3 / 520 |
| 2B student | Stanton | 74.1% → 74.1% | 90.0 → 88.8 | 19 → 22 | 4 → 4 | 3 / 498 | 3 / 498 |
| 2B student | RG165 | 94.3% → 94.3% | 95.7 → 95.7 | 1 → 1 | 1 → 1 | 0 / 224 | 2 / 224 |

**Votes a rerun flips** is the noise floor: the base request here is byte-identical to the one FarmShare answered
on 2026-10-18 (asserted at pack time), so every changed gap decision between the two is what a rerun alone
changes (another vLLM build, the weights at `main`: teacher snapshot `97f5941b`, student base `15852e8c`). A
window votes on each gap it covers, so one changed decision can move a box's pages-exact by several points: the
student's CREST gain of 9.4 points is one vote, the same as its rerun noise.

## What it says

- **Only Lincoln moves beyond noise**, for both models: 22 flipped votes against 6 for the teacher, 9 against 3 for
  the student. The flips are the intended ones (fewer false splits on long manuscripts, 42 → 38 and 46 → 44), but
  the teacher pays for them in merges (0 → 3), so boundary F1 is flat and pages exact gains 3 points. The block
  does not cure Lincoln's over-splitting: both models still predict about 120 documents where the truth has 81,
  although the block says the catalogue lists 72 items.
- **Lincoln's block is the strong one, and the owner never has it.** "The catalogue lists 72 items" is close to a
  count of the answer (the truth was built from the same catalogue items), and still bought 3 points.
- **On the owner's boxes the block does nothing measurable.** Stanton and RG165 flip within their rerun noise for
  both models (5 against 2, 3 against 3, 0 and 0). Stanton's teacher drop of 2.1 points and student F1 drop of 1.2
  are a vote or two each, so the block is not shown to hurt either, but nothing says it helps.
- **CREST, where the models are already right, is undisturbed**: the teacher is unchanged; the student's one flip is
  rerun-sized.

## Recommendation

- **Leave the app's window prompt as it is** (`WindowPrompts.swift`, every profile). The block's one gain is on a
  catalogued public box with a near-answer item count, and the owner's boxes, where the app runs, show no effect.
  The CHR prediction (under a point on the owner's boxes) holds.
- **`W46.seg-context-paid` (Gemini with and without the block) goes behind `W46.nice-to-have`.** Gemini follows
  instructions better than these two, so the block might do more for it, but on the owner's boxes the room is small
  and the question no longer decides a default. `W46.seg-context-more` (the block in the 2B's training rows; the
  tagging prompt) was already filed there.
- **A user with a real catalogue** (an item count per box) is the case where a length prior might pay; that is a
  feature idea, not a default, and would want its own test with a per-folder count rather than a per-box one.

## Caveats

- One run per arm. A rerun flips 0 to 6 votes per box, so differences of a vote or two are not findings.
- CREST's era reads 1978–2008 (release stamps outnumber document dates); RG165's "folder label" photos are mostly
  document text. Both are what an app would compute, and were left as they are.
- The student's first resubmission (job 50137565) refused to start because the pack check found the fixed
  `merge-job.sh` differing from its frozen hash; the owner's session resubmitted it as 50149167, which passed the
  check, after the merge (50137555) had succeeded. The scorer matches every answer to the pack's requests by cache
  key and the Mac copy's check passes (855 files), so the requests, images and blocks scored are the frozen ones.
