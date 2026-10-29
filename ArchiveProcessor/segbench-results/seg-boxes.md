# W46.fix-seg-boxes — draft truth for three new locked segmentation boxes

Written by `seg_boxes.py draft` (numbers only: no names, text or images). The boxes were named by the
owner on 2026-10-21 (`execution-plans/processing-review/STATE.md`). Drafts, keys and the blind ruling
sheets are in `~/Library/Caches/ArchiveSuiteRehearsal/seg-boxes/<box>/`, outside git. No model calls:
the teacher's P(new) is the W41.seg-label-clean run's (`label-clean.md`).

| box | draft from | photos | gaps | New | Cont | Box | Folder | gaps for the owner | photos in label-clean's train split |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Rawls papers 00057-00252 | label tags only | 196 | 195 | 3 | — | 0 | 3 | 190 | 0 |
| Stanford Illustrated Review | tags + teacher | 147 | 146 | 38 | 109 | 0 | 0 | 46 | 147 |
| SC0122 News Service | tags + teacher | 200 | 199 | 66 | 131 | 1 | 2 | 37 | 200 |

Rawls carries no document tags, so its New column counts only the first page after a label photo;
every gap between two page photos goes to the owner. In the two tagged boxes a gap goes to the owner
when the teacher's P(new) is on the other side of 0.5 from the tag (the agree rule's dropped gaps):

- Stanford Illustrated Review: tag cont / teacher new: 41, tag new / teacher cont: 5; gaps the teacher never judged: 0.
- SC0122 News Service: tag cont / teacher new: 36, tag new / teacher cont: 1; gaps the teacher never judged: 0.

**Both tagged boxes are in label-clean's train split**, so the Mac students trained on its windows
(the W41.seg-finetune 2B and 4B, on the Mac since W41.seg-mac-model) have seen these boxes with the tag or teacher labels; a student's
score on them is not a held-out figure. The owner's call on it is `W46.seg-boxes-overlap-ok`.
