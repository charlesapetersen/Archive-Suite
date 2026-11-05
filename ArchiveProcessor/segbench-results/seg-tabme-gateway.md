# W46.seg-tabme-paid — Gemini on TABME++, with and without the page images

The paid half of W46.seg-tabme (`seg-tabme.md`). There the 27B teacher read TABME++'s clean scans 3.0-5.2 points of
boundary F1 better without its page images, the opposite of the owner's photographed boxes. This asks the cloud
route the same question: does the image help Gemini on clean scans with commercial OCR, where A04 says it does not?

Source: `seg-tabme-gateway.json`, written by `scripts/segbench/seg_tabme_gateway.py score`. Gemini 3.7 Flash through
the Stanford AI API gateway, the cloud route's request (g1, temperature 0, reasoning low, JSON mode), K = 7 windows
stepping 3 pages, once with the 1,000 px page images and the OCR text and once with the text alone
(seg_window_gateway's text-only rewrite). 338 calls, all parsed first time, **$2.59** (the gateway's own figure equals
the token estimate on every call) of the item's $4.00 cap.

**What was filed and what ran.** The item named Gemini 3.8 Flash for the image arm and Gemini 3.1 Flash-Lite for
A04's text-only K = 7 setting on the whole stream. The gateway serves neither (its `/v1/models`, 2026-11-05: Gemini
2.5 Flash, Flash-Lite and Pro, and 3.7 Flash), and a direct Gemini key needs the owner's word under the personal-key
rule. So the image question ran on 3.7 Flash, the gateway's Gemini that the bench's other cloud arms use, and the
exact A04 cell is filed behind `W46.nice-to-have` as `W46.seg-tabme-a04` (below, finding 3, for why it can wait).

## Results (the stream's first 504 pages: 203 whole documents, 503 decisions)

| Route | Boundary F1 (95% interval) | Pages in exact document | Doc F1 | False splits | False merges |
|---|---|---|---|---|---|
| Gemini 3.7 Flash, images and text | 0.882 (0.834-0.927) | 64.5% | 0.757 | 54 | 0 |
| Gemini 3.7 Flash, text only | 0.898 (0.852-0.940) | 65.3% | 0.779 | 46 | 0 |
| Trained 2B, images and text | 0.846 (0.786-0.906) | 58.5% | 0.717 | 72 | 1 |
| Trained 4B, images and text | 0.854 (0.785-0.916) | 63.3% | 0.740 | 68 | 1 |
| 27B teacher, images and text | 0.815 (0.736-0.890) | 57.3% | 0.691 | 90 | 1 |
| 27B teacher, text only | 0.848 (0.778-0.914) | 64.1% | 0.739 | 71 | 1 |
| Every page a new document | 0.573 | 25.0% | 0.356 | 301 | 0 |

The open models' rows are W46.seg-tabme's Sherlock answers over the whole stream, cut to the same 203 documents (the
same windows, so each document is judged with the same neighbours). Paired over the same bootstrap draws (2,000 over
truth documents, seed 46), boundary F1 points: Gemini text less Gemini images **+0.4 to +3.0**; 2B less Gemini
images -7.6 to 0.0; 4B less Gemini images -7.4 to +0.9; teacher text less Gemini text -10.7 to -0.3; teacher images
less Gemini images -12.3 to -1.9.

## What it shows

1. **The image does not help Gemini on these scans either; if anything it costs a little.** The two arms differ on
   10 of the 503 gap decisions, and the text-only arm is right on 9 of them, all false splits the image arm added.
   That is the direction of A04 and of the teacher here, and the opposite sign from the owner's development boxes,
   where text alone cost Gemini 3.7 2.7 points (a tie; `seg-window-gateway.md`). One run per arm and no rerun floor
   for Gemini on this set, so it is a lean in A04's direction, not a measured loss.
2. **Gemini leads the open models here.** 0.882 against the 2B's
   0.846 with the same input (paired -7.6 to 0.0, at the edge of a tie) and 6.7 and 5.0 points over the teacher with and
   without images. Gemini makes the same kind of error as the others: every one is a false split, and no arm merges.
3. **Against A04.** On these documents the teacher's text arm scores 0.848 and Gemini 3.7's 0.898; over the whole
   stream the teacher's scored 0.809. If Gemini keeps a like lead over the whole stream it would sit near A04's
   0.863 for Gemini 3.1 Flash-Lite, so nothing here says our page order or harness departs from A04's. That is an
   inference across a subset, not a measurement; the exact cell (3.1 Flash-Lite, the whole stream, about $1.1 on a
   direct key) would settle it, and it changes no decision now, so it waits behind `W46.nice-to-have`.
4. **For the cloud route (`W46.review-phase4`).** Keep images in the cloud route's windows: they cost little on clean
   scans and the owner's own material leans the other way. A text-only cloud tier remains the lead
   `seg-window-gateway.md` named for clean, typed collections, now with a second collection behind it.

## Measurement card

- **Truth.** TABME++'s own document ids (`bevaya/TABMEpp` at revision 46747c21), from the Truth Tobacco Industry
  Documents' cataloguing; not audited by us, not checked by the owner. No drafter or relative of a scored route made
  it.
- **Selection.** The first whole documents of W46.seg-tabme's stream reaching 500 pages (504 pages, 203 documents), in
  the dataset's own shard order: chosen by nothing any route answered and fixed before any call. It is not a random
  sample and leans to short documents: 62.1% single-page documents and 2.48 pages a document, against 54.3% and 2.79
  over the whole stream, which is why every arm scores higher here than over the whole stream (the 2B 0.846 against
  0.814).
- **Comparison.** The two Gemini arms share the request word for word except the images and the one paragraph about
  them, the same windows and the same settings. The open models' rows are a different prompt (o1, the local route's)
  and other serving, scored on the same documents and gaps; they place Gemini and are not an A/B of prompts. OCR is
  the dataset's Microsoft OCR for every arm. Gemini named 2-3 pages box or folder photos; as in W46.seg-tabme, those
  calls are reported and not scored (the truth's labels, which have no photos, are used).
- **Noise.** One run per arm. The intervals are document-bootstrap intervals without rerun noise; the image-against-
  text difference rests on 10 decisions, so it is a lean. The Gemini-over-open-models gaps of 3-7 points are larger
  than the 1.6-point open-model rerun floor measured on Lincoln, but Gemini's own rerun floor here is unmeasured.
- **Scope.** Gemini 3.7 Flash, not 3.8 Flash (the bench's direct-key cloud figures) nor A04's 3.1 Flash-Lite; one
  genre of clean business scans with one catalogue's document rule. It does not say how the image helps on
  photographed, handwritten or mixed boxes (`seg-window-gateway.md` does, for the owner's development boxes).
