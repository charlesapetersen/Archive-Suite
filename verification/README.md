# verification/ — feature ledgers, evidence and suspects

The working record of the W40 verification phase (`execution-plans/verification-phase/01-daemon-plan.md`). A
feature ledger lists every feature the Suite's plans and guides say exists, and records whether that promise has
been shown to hold. **The ledger, not a `SUITE_TODO.md` checkbox, is the measure of done** (phase rule 2).

```
verification/
├── README.md            this file — the format every ledger, evidence file and suspect follows
├── reader.md            Reader ledger                      (W40.b1)
├── notes.md             Notes ledger                       (W40.b2)
├── processor.md         Processor ledger                   (W40.b3)
├── capture.md           capture companions, Android + iOS  (W40.i2, extended by W40.b4)
├── SUSPECTS.md          suspected bugs not yet reproduced
├── evidence/<app>/      kept run artifacts that ledger rows cite
└── sessions/            the owner's guided-session packs and returned forms (W40.g*)
```

`<app>` is one of `reader`, `notes`, `processor`, `capture`, `core` (ArchiveCore and the cross-app contract).

## Statuses

Every row has exactly one status. A new row is always `unproven`.

- **`unproven`** — promised, not yet shown either way. The starting state.
- **`works`** — all three of *Reached by*, *Real-path test* and *Runtime evidence* are filled in, and the evidence
  shows the promise holding. Missing any one of the three, the row stays `unproven`, however convincing the code.
- **`broken`** — reproduced failure (phase rule 5): a failing test or a scripted run with its artifact. The row
  names the `W40.fix-<slug>` item and its severity (`S1`–`S4`, rule 8).
- **`unreachable`** — the code may exist, but no path a user can take reaches it (dead view, no menu item, no
  caller). Goes to the Daemon Report as a decision: wire it or drop it. The daemon never decides this.
- **`fixed-pending-recheck`** — a fix or wiring commit landed. The session that made it may move the row this far
  and **no further** (rule 6). A later, separate item (`W40.h2`, or the next run of the journey) moves it to
  `works` or back to `broken`.
- **`dropped`** — the owner withdrew the promise. **Owner only**: cite the Daemon Report decision and its date,
  and correct the guide that made the promise in the same commit.
- **`unverifiable-here`** — cannot be proven on this machine without something only the owner has. Say exactly
  what: a physical phone, an account, a key, a device, a judgement of taste. Never a substitute for `unproven`
  when the work is merely hard.

A row with no promise behind it does not belong here. If the code does something no plan or guide promised, it is
either dead code (`W40.e5`) or a doc gap (`W40.b5`), not a ledger row.

## A row

One `###` section per feature, in the order the app's guide presents them. Bullets, not table columns, so a row
stays readable at any width. Field order is fixed so rows can be compared by eye:

```markdown
### R-07 · Mark Read & Next

- **Promise:** marks the selected PDF read and selects the next unread one in the list.
- **Promised in:** `ArchiveReader/CLAUDE.md` §Triage; `ArchiveReader/SMOKE_TEST.md` step 6.
- **Reached by:** toolbar button and ⌘↩ → `Views/ReaderToolbar.swift:88` → `NavigationModel.markReadAndNext()`
  (`Views/NavigationModel.swift:214`).
- **Real-path test:** `ArchiveReaderUITests/TriageUITests.testMarkReadAndNext` — or `none`.
- **Runtime evidence:** 2026-10-12 · `abc1234` · [`evidence/reader/W40.d8-triage.md`](evidence/reader/W40.d8-triage.md) — or `none`.
- **Status:** `unproven`
- **History:**
  - 2026-10-09 W40.b1 — row written, `unproven`.
- **Notes:** anything a later session needs; a suspect id or fix tag; why a promise-test changed.
```

The example is illustrative; its paths and numbers are not real.

- **ID.** `R-` Reader, `N-` Notes, `P-` Processor, `C-` capture, then a two-digit number. Never reused or
  renumbered — fixes, suspects, evidence and Daemon Report entries cite rows by id. A row that is split keeps its
  id on the first part; the new part takes the next free number. Gaps are fine.
- **Promise** — what a user was told, in their terms, one or two sentences. Written from the source *before* the
  implementation is opened (rule 3). If the sources disagree with each other, quote both and say so in Notes.
- **Promised in** — every place that makes the promise: guide section, README, SMOKE_TEST step, SPEC section,
  `SUITE_TODO_DONE.md` entry by tag. These are what `W40.b5` corrects if the promise turns out false.
- **Reached by** — the user's action, then `file:line` of the entry point and the first call into the feature.
  `none found` (with what was searched) makes the row `unreachable`.
- **Real-path test** — a test that goes through the code a user's action goes through, not a stub, a seam the app
  never takes, or a mock of the thing being promised. Name it as `<Bundle>/<Class>.<method>`. A test that passes
  on a reverted implementation is not one (`W40.a4`). This test is a **promise-test** (rule 4): a fix may change
  what it expects only if the commit message says why and History records it.
- **Runtime evidence** — `date · commit · artifact link`. A run of the real app (or its real headless driver) on
  rehearsal material, kept under `evidence/`. "The tests pass" is not runtime evidence for a user-facing feature.
  Several runs: newest first, keep the older ones.
- **Status** — one of the seven above, in backticks.
- **History** — append-only, oldest first: `date tag — what changed`. Every status change gets a line naming the
  item that made it, so rule 6 can be checked by reading the row.
- **Notes** — optional.

A ledger file opens with a short header: the app, the sources the rows were written from, the commit those
sources were read at, and a count by status (`unproven 31 · works 2 · unreachable 2`), kept current by whoever
changes a status.

## Evidence

Phase rule 1: **evidence or it did not happen.** A `works` or `broken` status cites a file kept here.

- **Where:** `verification/evidence/<app>/<TAG>-<slug>.<ext>` — the item that produced it, then what it is
  (`W40.d6-usb-transport.md`, `W40.d6-usb-probe-REPORT.txt`). One item may leave several files.
- **What the file opens with:** date, the commit it ran at, build configuration, environment (host headless, Tart
  VM, Android emulator name and `-no-window`), the rehearsal set and its `MANIFEST.txt`, and the exact command.
  Then the promise being tested, then the result, then the raw output or an excerpt of it.
- **Excerpts, not dumps.** Keep the lines that show the result and enough around them to trust them. A large raw
  log or screenshot set stays in `~/Library/Caches/ArchiveSuiteRehearsal/` or `/tmp`; the evidence file says where
  it was and its size and SHA-256, so it can be recognised if found again. Commit a screenshot only when the
  picture is the evidence, and keep it small.
- **Nothing from the real corpus** (`~/Desktop/Google Drive/Archival Photos/`) in a committed file: no page
  images, no OCR text, no file names beyond the minimum a measurement needs. The `W40.c2` before/after listing is
  the one exception, and it holds sizes, mtimes and tag bytes, not content.
- **No secrets.** API keys, OAuth tokens and pairing tokens are redacted before commit (`sk-…REDACTED`).
- **Never edited after the fact.** A re-run is a new file, or a new dated section appended to the old one. A
  wrong evidence file is corrected by a new one that says what the old one got wrong.
- A file that cannot yet point at a ledger (because the ledger does not exist yet) lists the rows it would
  support, as `W40.d6-usb-transport.md` does; the ledger's author takes them in.

## SUSPECTS.md

Rule 5: a bug enters the work queue only with a reproduction. Anything weaker lands in `SUSPECTS.md` — an
AI finder's report, an owner note that could not be reproduced yet, a doc claim that looks wrong, a hunch from a
journey. Suspects never become queue items directly.

One `###` section per suspect, newest at the bottom:

```markdown
### S-012 · Notes may overwrite a note edited outside the app while it is open

- **Raised:** 2026-10-15 · W40.d9 · journey observation (or: owner session N-1, sanitizer report, Periphery, …).
- **Suspected behaviour:** what would go wrong, for whom, and how badly if true.
- **Where:** `file:line`, ledger row (`N-14`), or both.
- **Would confirm it:** the test or scripted run that would reproduce it, concretely enough to run.
- **Would clear it:** what result would show it is not real.
- **Status:** `open`
- **History:**
  - 2026-10-15 W40.d9 — raised.
```

- **IDs** `S-001` upward, never reused.
- **Statuses:** `open` · `reproduced` (name the `W40.fix-<slug>` item filed from it and the artifact) ·
  `cleared` (name the run that showed it is not real, and keep the entry) · `superseded` (name the suspect or fix
  that covers it).
- Anyone may add a suspect. Moving one to `reproduced` or `cleared` needs the run, linked; reasoning about the code
  alone does not move it either way.
- An `open` suspect on an irreversible path (tag writes, finalize/Trash, note save, Reader undo) is worth a
  journey's time before anything cosmetic; say so in its *Suspected behaviour*.

## Who writes what

- **Ledger rows** are written by the `W40.b*` items; statuses move by journeys (`W40.d*`), bug-finders
  (`W40.e*`), suspicion items (`W40.f*`), fixes (`W40.fix-*`, only as far as `fixed-pending-recheck`) and the
  re-check (`W40.h2`). `dropped` is the owner's.
- Every change to a ledger, evidence file or suspect is committed with the item that made it, like any tracker
  edit (umbrella `CLAUDE.md` §*Docs & backlog convention*).
