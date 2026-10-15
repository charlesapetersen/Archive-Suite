# Rehearsal material — what each set is, how to rebuild it, how it reaches the VM

Phase plan §C (`execution-plans/verification-phase/01-daemon-plan.md`): every rehearsal set lives under
`~/Library/Caches/ArchiveSuiteRehearsal/`, outside `~/Claude`. Each can be rebuilt by a script in this repo and
is never committed, and each carries a `MANIFEST.txt` saying what it is and how it was made. The cache folder also
holds the working files of the segmentation and OCR tools (`segbench/`, `seg-truth/`, `ocr-*`, `corpus-survey/`).
Those belong to the W36/W41 items, not to the journeys, and nothing below changes them.

| Set | Built by | For |
|---|---|---|
| `processor-set/` | `python3 ArchiveProcessor/scripts/make-processor-rehearsal.py` | `W40.d1` bulk OCR, `W40.d5` live capture |
| `notes-store/` | `python3 ArchiveNotes/scripts/make-notes-rehearsal.py` | `W40.d9` writing session, `W40.d10` integrations |
| `reader-sample/` | `ArchiveReader/scripts/rehearsal-sample.py make` (`W40.c2`; see its `MANIFEST.txt`) | `W40.d7` at size, `W40.d8` triage writes |

## Processor — `Test Files/` and the ground-truth box

`ArchiveProcessor/Test Files/` is gitignored and exists only in the primary checkout (the script finds it from a
worktree through `git rev-parse --git-common-dir`). It holds 1,079 photos (1.6 GB) in twelve collections. Only five
of them have a segmentation truth CSV: one row per photo, labelled `Box` (box-label photo), `Folder` (folder-label
photo), `New` (first page of a document) or `Cont` (a continuation page). `CATALOGUE.tsv` in the set lists all
twelve. As of 2026-10-14:

| Collection | Photos | Truth rows | Labels | Notes |
|---|---|---|---|---|
| Ground Truth Segmentation/RG 165 — War Department | 113 | 113 | Box 16 · Folder 10 · New 33 · Cont 54 | Pixel 9 live capture |
| Ground Truth Segmentation/Deaver | 149 | 149 | Box 3 · Folder 5 · New 89 · Cont 52 | the CSV runs to row 251; 102 trailing rows unlabelled |
| Ground Truth Segmentation/Herrnstein | 200 | 200 | Box 4 · Folder 15 · New 108 · Cont 73 | |
| Ground Truth Segmentation/Dean | 202 | 202 | Box 1 · Folder 5 · New 121 · Cont 75 | |
| Ground Truth Segmentation/Stanton | 250 | 250 | Box 2 · Folder 5 · New 112 · Cont 131 | one unlabelled row |
| Collection Segmentation | 35 | 35 | collection names, not segmentation | 216 trailing rows unlabelled |
| six loose collections (Dean Papers, Deaver and Hannaford, Herrnstein, Surrey, Collection Segmentation Test 2, DeaverLLM) | 0–30 each | — | — | DeaverLLM holds 40 OCR'd PDFs and no photos |

**The pick for `W40.d1`: RG 165 — War Department.** It has the fewest photos (113), so the paid OCR pass costs the
least, and every photo is labelled. It also has by far the most box and folder photos (26), the case where
document splitting most often goes wrong, and it is the only box shot by live capture, which `W40.d5` also uses. One
caution: RG 165 and Stanton are the segmentation bench's held-out **test** collections
(`execution-plans/segmentation/00-plan.md`). `W40.d1` may score the shipped method on RG 165, as the bench's own
final run does, but **nothing may be tuned on it**. A journey that needs to tune or iterate uses Dean (202 photos,
development set) instead.

The script copies the box's 113 photos and its `Ground Truth.csv` to `processor-set/RG 165 — War Department/`
with `ditto`. It lists the size, mtime and sha256 of every source file before and after the copy, and the copy's
own, then proves the source untouched and the copy faithful (`*.before.tsv`, `*.after.tsv`, `*.copy.tsv`, and the
verdict in `MANIFEST.txt`). It is a copy because the Processor moves finished originals to the Trash: **no
journey may point the app at `Test Files/`.** `--collection <leaf name>` copies a different collection.

## Notes — a store larger and messier than `AN-GUI-Fixture`

`make-notes-fixture.sh` builds four tidy notes that the UI tests assert on, and that stays as it is. The rehearsal
store is generated, deterministic for a given `--seed`, and uses synthetic text only. With the defaults it holds
400 items (331 notes, 69 extracts) and these:

- every block kind (1,348 blocks), including dangling reader links (a moved file, an unknown root, a page past
  the end), missing thumbnails, note-passage links to a note that does not exist, and unclosed block headers;
- every date shape: decade, year, month and day, uncertain dates, `sent_with`, and a `display_calendar`;
- tags in clashing cases and spellings, Unicode and emoji titles, a 230-character title, titles with `/`, `:`,
  leading or trailing dots, an empty title, YAML-literal titles (`yes`, `null`), duplicate titles, CRLF, lone-CR and mixed line endings,
  a 1.2 MB note, and unknown front-matter keys;
- 18 normal folders nested five deep, with repeated names, plus 6 smart folders (tag any/all, quality, date
  range, roundup, search, and one that matches nothing). 93 items are replicated into 2–5 folders and 56 are in
  none. There are 3 ghost memberships and 2 templates with folder assignments;
- Finder-tag projections that are out of step on purpose: a missing subject, a stale subject, an unrelated
  colour tag;
- an embedded scratch Reader root (`reader-corpus/`, 41 generated text PDFs in nested, Unicode-named folders),
  which the reader links point into;
- **17 hazards**, listed in `hazards.tsv` with the behaviour each one should get: no front matter, unterminated
  front matter, no `id`, an id that differs from its folder, two `.md` files in one folder, `schema: 2`, Latin-1
  bytes, an empty folder, a folder whose name is not a UUID, an upper-case folder name, `.DS_Store` litter,
  the ghost memberships, and the line-ending and very-large notes. `--no-hazards` leaves out the damaged items.
  A journey that meets a hazard has not found a bug unless the app departs from its row.

The store folder is called `AN-GUI-Fixture`, inside `notes-store/`, on purpose. The DEBUG projector's scratch
guard (`NotesTagProjector.isScratchPath`) and the VM UI-test sandbox exception both match that path component.
Its root marker has a different guid and name (`AN-Rehearsal-Store`), so `NotesModel.isGeneratedNotesFixture`
never mistakes it for the generated fixture.

**Checked with the app's own code** (2026-10-14,
[`evidence/notes/W40.c1-rehearsal-store-load.md`](evidence/notes/W40.c1-rehearsal-store-load.md)):
`NoteStore` loads every ordinary item, the only failures are the five hazards built to fail, and
`organization.json` decodes whole. That run found a reproduced bug: a note with an unclosed block header gains a
`<!-- block: freeform -->` line on every save (`W40.fix-notes-unclosed-header`).

## Reader — a sample of the real corpus

`ArchiveReader/scripts/rehearsal-sample.py make` copies 5,000 PDFs, spread across the corpus's 270 first-two-level
folder groups by proportional share with a fixed seed, plus each one's JPEGS-tree partners by Reader's own rule and
the main-tree images beside it: 8,743 files, 9 GiB. It reads the corpus only. Every sampled file is listed (size,
mtime, ctime, inode, tag xattr, all xattrs) before and after the copy, and the two listings must be identical;
`rehearsal-sample.py verify` re-checks them at any time. The copies are APFS clones (`cp -c -p`; `ditto` does not
clone), so they take almost no disk, and a write to them never reaches the corpus. Grant Reader the
`reader-sample/` folder itself: it holds `Archival Photos/` and `Archival Photos JPEGS/` as the real parent does.
Evidence: [`evidence/reader/W40.c2-sample.md`](evidence/reader/W40.c2-sample.md).

## How a set reaches the Tart VM

`ops/gui/vm-gui-runner.sh` boots the VM with the whole cache folder shared **read-only**:

```
--dir=rehearsal:$HOME/Library/Caches/ArchiveSuiteRehearsal:ro   →   /Volumes/My Shared Files/rehearsal/
```

(`REHEARSAL_DIR` overrides the host path. The share is left out when the folder does not exist.) Proved on
2026-10-14 with a boot that mounted only `repo` and `rehearsal`:

- a write onto the share is refused: `touch: …/rehearsal/x: Operation not permitted`;
- `ditto` of the Notes store onto the guest disk took 3.0 s for 1,156 files, the same count as the host;
- Finder-tag xattrs survive both the share and the `ditto`: the same `_kMDItemUserTags` bytes on the host,
  over the share, and on the guest copy;
- `ditto` of the RG 165 box took 1.2 s: 114 files, and the guest `Ground Truth.csv` sha256 matches the host
  (`02125e7a…`);
- the guest had 23 GiB free, which matters for the 9 GiB Reader sample.

**Copy onto the guest disk, then work there.** The share is read-only, so the app could not write to it anyway,
and a journey that writes needs its own copy. Per set:

- **Notes** (`W40.d9`/`d10`): after the runner has built the normal fixture, replace it in the guest and launch
  against it. The next ordinary run rebuilds the fixture, because `ensure_fixture` rebuilds it every time:
  ```
  F="$HOME/Library/Application Support/ArchiveNotes/AN-GUI-Fixture"
  rm -rf "$F" "$F.pristine"
  ditto "/Volumes/My Shared Files/rehearsal/notes-store/AN-GUI-Fixture" "$F" && ditto "$F" "$F.pristine"
  # then: ArchiveNotes.app … -ANUITestStorePath "$F"
  ```
  That path is the one the UI-test runner's sandbox may write, and the app resets its UI-test index on each
  launch, so `organization.json` is what loads. Do not run `NotesGUITests` against it: those tests assert on the
  four generated fixture notes. A journey uses its own test class or `ONLY_TESTING`.
- **Processor** (`W40.d1`/`d5`): `ditto` the box from the share to a guest scratch folder and give the app that
  folder. Finished originals go to the guest's Trash, never the host's.
- **Reader** (`W40.d7`/`d8`): `d7` only reads, so it may read the sample over the share. `d8` writes tags, so it
  copies the folders it needs onto the guest disk first (23 GiB free; the whole sample is 9 GiB, 8,743 files).

On the host, the Notes store can be read by the app-hosted unit bundle (the Debug entitlements allow `/Users/`),
which is how it was checked. Nothing may launch an app on the host screen to use it (`.claude/hooks/no-host-gui.sh`).
