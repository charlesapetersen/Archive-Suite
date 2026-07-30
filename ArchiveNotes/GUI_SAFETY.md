# Archive Notes — GUI & test file-safety protocol

**Prime Directive #1 — file safety > everything.** No test (unit, GUI, or the E2E scenario) may ever
write to the owner's real Notes store, a real Reader corpus, or clobber a real security-scoped bookmark.
This file is the authoritative protocol; it is cross-referenced from `test-smoke.sh` and the app
`CLAUDE.md`. Rationale recorded in memory **`archive-test-run-safety`**; the live-root incident that
hardened rule 3 is memory **`never-mutate-live-app-root`**.

## The one write surface

`NotesTagProjector` is the **only** place Notes writes file-level metadata, and it writes **only** Finder
tags on a note's own `.md` file under `<store>/items/<uuid>/` (component-boundary guarded; no
move/rename/delete/content-write, never the corpus). Every tag write exercised anywhere in the test
suite therefore routes through the projector against **scratch copies only**.

## Rules

1. **Scratch before any tag-write check.** Build a scratch store (and, for reveal checks, an embedded
   scratch Reader corpus of *copies*) before driving anything that writes a tag. The canonical builder is
   [`scripts/make-notes-fixture.sh`](scripts/make-notes-fixture.sh) → `~/Library/Application
   Support/ArchiveNotes/AN-GUI-Fixture` (a **sibling** of the real `…/ArchiveNotes/Store`, never it). The
   real corpus is only ever a **read-only `ditto` source**.
2. **Confirm the granted root is scratch before ANY write.** A read-only visual check (does the panel
   collapse, does the list render) is always safe; a **write** check (inline subject edit, replicate,
   delete-last-instance) runs **only** when the active store is a confirmed scratch copy.
3. **Never drive the store picker.** Driving *File ▸ Choose Store Folder…* would persist a bookmark over
   the owner's real `notesStoreRootBookmark`. GUI runs point the app at scratch via the **volatile**
   `-ANUITestStorePath` launch argument (`RootFolderStore.adoptTestStore`, DEBUG-only), which sets the
   store root **in memory only** and **never** writes a bookmark. `NotesStoreLocatorOverrideTests` keeps
   the bookmark-untouched invariant green.
4. **The harness only READS tags to assert.** `gui-drive-notes.sh` uses `tag -l` (read) to verify a
   write landed; it never writes tags itself — writes go through the app's projector.

## Mechanical enforcement (belt-and-suspenders)

A **DEBUG-only `precondition`** in `NotesTagProjector.project(...)` aborts any projector tag write whose
target is **not** under a known scratch prefix (`NotesTagProjector.isScratchPath`: the system temp dir /
`mktemp`, `/tmp`, `/private/var/folders/…`, or an `AN-GUI-Fixture` store) **when running under a unit-test
harness or with the `-ANUITestStorePath` override active** (`inTestOrGUIDriveContext`). It is **off** in
the ordinary DEBUG app and **compiled out of Release entirely**, so real tag writes to the real store are
never affected — but a test or GUI drive that ever aims a write outside scratch fails loudly instead of
touching real data. Covered by `NotesTagProjectorSafetyTests` (W8-S2).

## The durable-link E2E (W8-S9)

Two complementary, GUI-free proofs of the D5 durable-provenance promise (a link survives a computer
move: same root GUID, new absolute path, one re-grant — never a silent wrong file):

- **`DurableLinkE2ETests`** (unit gate) — exercises `ReaderLinkResolver`/`ReaderRootStore` directly over
  scratch corpora under the system temp dir; snapshot/restores the one persisted default
  (`readerRootBookmarks`) so it leaves host defaults byte-identical.
- **[`scripts/e2e-durable-links.sh`](scripts/e2e-durable-links.sh)** — a build-free filesystem proof over
  the shipped fixture builder: structural resolve → `ditto` computer-move (GUID identical at a new path)
  → unknown-GUID negative → guarded teardown. `rm -rf` refuses any path that is not the exact scratch
  fixture or a `mktemp` copy.

## Where these run (2026-07-30)

`ArchiveNotesUITests` runs **off-screen in the headless Tart VM**, not on the owner's display —
`ops/gui/vm-gui-runner.sh` interactively, and `ops/autonomous/gui-vm-gate.sh` in the periodic health gate
(Notes joined the Reader lane on 2026-07-30). The scratch fixture is built **inside the VM** on demand by
`scripts/make-notes-fixture.sh`, so none of the rules above are relaxed: it is still a sibling of the real
store, still never the corpus.

The **unit** suite (`ArchiveNotesTests`) is app-hosted — it launches `ArchiveNotes.app` — but the app renders
nothing when it is only a unit-test host (ArchiveCore `ArchiveTestHost`, pinned by
`TestHostWindowSuppressionTests`). That is a *screen*-safety guarantee, not a file-safety one; every rule above
still applies unchanged.

## Permissions caveat (do not false-pass)

`cliclick` pointer input silently no-ops unless the **controlling process holds macOS Accessibility
permission** (and Screen Recording for window capture). An unattended run without these must **skip** the
cliclick-only checks and flag them, never report them as passed. XCUITest additionally needs the
`taskport` debugger right password-free to run unattended (see the run's plan). This is now moot for
unattended runs in practice — they cannot reach the host cliclick path at all
(`.claude/hooks/no-host-gui.sh`), and VNC-injected input in the VM bypasses guest TCC entirely.
