# W46.fix-seg-boxes — draft truth for three new locked segmentation boxes

Written by `seg_boxes.py draft` (numbers only: no names, text or images). The boxes were named by the
owner on 2026-10-21 (`execution-plans/processing-review/STATE.md`); on 2026-10-29 the owner replaced
Rawls papers 00057-00252 with the Young, Sasha letters (W46.seg-boxes-hand), since Rawls' segmentation
principles were unclear, and had the Illustrated Review re-ruled on the article-within-issue rule
(W46.seg-boxes-sir-article). Drafts, keys and the blind ruling
sheets are in `~/Library/Caches/ArchiveSuiteRehearsal/seg-boxes/<box>/`, outside git. No bench or paid model calls:
the teacher's P(new) is the W41.seg-label-clean run's (`label-clean.md`); the Illustrated Review's
draft is a page-by-page reading made in the coding session (below).

| box | draft from | photos | gaps | New | Cont | Box | Folder | gaps for the owner | photos in label-clean's train split |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Young, Sasha letters 00001-00180 | label tags only | 180 | 179 | 1 | — | 1 | 0 | 178 | 0 |
| Stanford Illustrated Review | article reading | 147 | 146 | 82 | 65 | 0 | 0 | 134 | 147 |
| SC0122 News Service | tags + teacher | 200 | 199 | 66 | 131 | 1 | 2 | 37 | 200 |

The letters carry no document tags, so their New column counts only the first page after a label
photo; every gap between two page photos goes to the owner. The box is in no label-clean split (its
folder is not in the corpus-pairs windows), so every model scored on it is held out.

## Stanford Illustrated Review on the article-within-issue rule

Owner, 2026-10-29: an article inside an issue is its own document and inherits the issue's date and
journal title from its cover or contents page; the full-magazine rule of 2026-10-05 is only the
fallback where splitting an issue by article is too difficult. The box's tags and the label-clean
teacher were both made before that rule, so neither drafts it. The draft is a reading of every page
(issue, page kind, whether an article or front matter begins), made by four Claude readers in the
coding session over the upright thumbnails and merged by hand; it is not a bench arm and decides
nothing the owner rules, since every gap except a repeat goes to the owner blind. It is kept in the cache
as `seg-boxes/sir/reading.json`.

- 43 issues across the 147 photos (4 dated only by inference
  from their contents, 0 photos of no readable issue);
  31 issues have a cover or contents photo in the box, and
  29 photos have none before them (the sheet says so for those cases).
- 12 gaps are a byte-identical repeat photo (the same JPEG twice, and their corpus PDFs
  match it equally) and are drafted Cont without asking; the other 134 gaps go to the owner.
- Against the old tags: 52 photos tagged as continuing are drafted as starts,
  8 tagged as starts are drafted as continuing.
- Fallback needed in the draft: 1926-01 (6 photos).
  - 1926-01: its articles interleave across photos 108-111 (108's article goes on at 110, 109's at the foot of 111, and 111 starts another), so no run of photos in capture order is one article; the issue's run is one document.
- The sheet offers a fallback answer on every case, and `fold` lists the issues where it was used.

Stale against the new rule, left for `W46.seg-magazine-rule-redo`: the method prompts (`method_gemini.py`
and `method_whole.py` rule 10), `make-truth-pack.py`, this script's sheet text for the other boxes
(SC0122 already answered on it; the Young, Sasha sheet is out to the owner with it, and holds no
magazines), the truth sets with magazine cases (Stanton case 38), and every score built on them.

In the SC0122 box a gap goes to the owner when the teacher's P(new) is on the other side of 0.5 from
the tag (the agree rule's dropped gaps):

- SC0122 News Service: tag cont / teacher new: 36, tag new / teacher cont: 1; gaps the teacher never judged: 0.

**Both tagged boxes are in label-clean's train split**, so the Mac students trained on its windows
(the W41.seg-finetune 2B and 4B, on the Mac since W41.seg-mac-model) have seen these boxes with the tag or teacher labels; a student's
score on them is not a held-out figure. The owner kept both (`W46.seg-boxes-overlap-ok`, 2026-10-29): a
student's score on them is reported as trained-on, and both go into corpus_pairs EXCLUDE for any retrain.
