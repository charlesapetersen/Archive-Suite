# Archive Suite — Agent / Concurrent-Development Guide

Umbrella conventions for working in this monorepo (solo or with multiple agents in parallel). Each app
also has its own `AGENTS.md` with app‑specific lanes — read it before working inside a subdir:
[`ArchiveProcessor/AGENTS.md`](ArchiveProcessor/AGENTS.md) · [`ArchiveReader/AGENTS.md`](ArchiveReader/AGENTS.md) · [`ArchiveNotes/AGENTS.md`](ArchiveNotes/AGENTS.md).

## Ground rules

- **Worktree-first — mandatory, not optional.** Before *any* edit/build/commit, be in your own git
  worktree; never work in the primary checkout, even if you think you're the only instance running. Run the
  idempotent first-step check in [`CLAUDE.md`](CLAUDE.md) → **"Worktree-first"** (it creates
  `../suite-wt-<stamp>` only if you're not already isolated, so it's safe to run every session). Per‑worktree
  DerivedData (`-derivedDataPath ./build/DD`, already the default in each `launch.sh`) keeps parallel builds
  from colliding. **Remove your worktree once your work is pushed** so they don't pile up for the owner.
  **Only ever touch worktrees you created** — another agent's uncommitted WIP is not yours to clean up.
  *Superseded 2026-07-29:* the long-standing "never touch the Codex worktree
  `~/Documents/GPT/archive-suite-processor-fixes`" instruction is **retired** — the owner asked for it to be
  removed and it is gone (its work was preserved first; see §"Working the to-do list as an external agent" →
  *Preserved work*). Don't go looking for it. The standing rule is unchanged and matters more than the
  exception: if you find a stray worktree carrying uncommitted work, **preserve it before removing anything**,
  and **never `--force` past a git refusal**.
- **After any pull/switch, `xcodegen generate`** (or the app's `bootstrap.sh`) — the `.xcodeproj` is gitignored.
- **Stay in your lane.** A change scoped to one app touches only that subdir. Loading the *other* app is
  almost always unnecessary (see the token‑efficiency directive in [`CLAUDE.md`](CLAUDE.md)).
- **Never** write to a real corpus during dev/test (copy to scratchpad); **never** add a tag‑write call
  outside Reader's audited `TagWriter`, or any move/rename/delete/content‑write call anywhere.
- **Done = code + docs in the *same commit*.** Ship a `SUITE_TODO.md` item → flip its checkbox (cite the
  commit); fix/find a bug → update `KNOWN_ISSUES.md`; ship an `execution-plans/` plan → delete it.
  `SUITE_TODO.md` is the tracker of record — an unattended run reconciles it *before ending*, never leaning
  on a private plan file. The owner shouldn't have to catch a stale tracker. (Full rule:
  [`CLAUDE.md`](CLAUDE.md) → "Docs & backlog convention.")

## Working the to-do list as an external agent (Codex et al.) — finish the handoff

The owner sometimes turns the autonomous daemon **off** and hands a batch of `SUITE_TODO.md` items to an
external agent (Codex) instead. If that's you: the coding conventions above all apply unchanged, **and** there
is a handoff you must complete, because this repo has state the daemon depends on that a normal
`commit && push` does not touch. Every item below is a real problem that actually happened on the 2026-07-29
handoff and had to be repaired by hand afterwards. **None of it is optional, and none of it is inferable from
the tracked files alone.**

**1. `git push` is not "done". Advance the PRIMARY checkout too.**
You will be working in your own worktree (correctly). But the daemon reads `.maintenance/AUTONOMOUS_PLAN.md`
**from the primary checkout** and measures code-review deltas against **the primary checkout's `HEAD`**. Pushing
leaves `origin/main` ahead of it. So after your final push:
```bash
cd "/Users/<user>/Claude/Archive Suite" && git merge --ff-only origin/main
```
*(2026-07-29: `origin/main` was at `62a10d1` while the primary checkout still sat at `cb948c6`. Also note
`ops/autonomous/arm.sh` installs the daemon scripts from **that working tree**, not from `origin/main` — so a
lagging primary checkout silently re-installs stale daemon scripts when the owner re-arms.)*

**2. Tick the daemon's plan, not just `SUITE_TODO.md`.**
`.maintenance/` is **gitignored**, so it is invisible to a normal diff and easy to miss — but
`ops/autonomous/next-queue-item.sh` walks the **plan's** `## WORK QUEUE`, and applies "a `[ ]` anywhere wins".
For every item you finish, set its plan checkbox to `[x]` + the sha as well. Consequences of skipping it:
- the daemon **re-does finished work** (it happened three times: `W15.tu1`, `W15.tu4`, `W16.lan2`), and
- every downstream `(blocked-on: <that tag>)` item is **falsely reported blocked**, stalling the whole chain.

**3. A new wave in `SUITE_TODO.md` is INVISIBLE to the daemon until it's mirrored into the plan's queue.**
Adding items to `SUITE_TODO.md` alone does **not** put them in the daemon's queue — it walks the plan. Wave 22
sat unreachable this way and would have been skipped entirely, with no error. Mirror new items into the plan's
`## WORK QUEUE` as one-liners ("full spec in `SUITE_TODO.md` §… — read that first"), keeping the **tags
byte-identical** so `blocked-on` resolves.

**4. HIGH-severity findings on irreversible paths are owner-gated by default.**
Anything touching `Capture/`·`Net/`, finalize/manifest, file-writing tag/output, or `SPEC/tag-format.md` needs a
per-item entry in the plan's `## OWNER AUTHORIZATIONS` before the daemon may execute it. The category is
**never** authorized wholesale. If you file such a finding, say so explicitly and leave it for the owner.

**5. Filing a review: queue it, don't just write a report.**
A review report on its own is not tracked work. Turn each confirmed finding into a `[ ]` item in
`SUITE_TODO.md` (steps 3 and 4 then apply), and archive the report itself under the gitignored `old/` with a
note saying it was transcribed. Include the **baseline sha** you reviewed — line numbers go stale fast, so also
name the **function/symbol** for every cite. *(The 2026-07-29 report's line numbers were already wrong on
arrival: `W16.cfg*` had rewritten the same files.)*

**6. Checkpoint, and don't leave a divergent worktree behind.**
If you may run out of credits/context mid-task, **commit and push at each green checkpoint** — only the final
commit flips a checkbox. Then **remove your worktree**. A worktree left with uncommitted work is very close to
lost work: the one removed on 2026-07-29 held **~2,900 uncommitted lines on top of 8 unpushed commits**, sat
untouched for 12 days, and had fallen **76 commits** behind `main`.

**Preserved work (for reference, not for merging).** That worktree's content was preserved before removal, and
one piece is **live prior art**: a `PDFGenerator.generateRequiringEmbeddedImage()` + `PDFError
.imageEmbeddingFailed` pair that keeps the deliberate placeholder page for Process Files while making the Live
Capture path *throw*, so finalize can't retire a raw source against a placeholder-only PDF. That is the fix now
queued as **`W23.h5`**. Two copies, both outside `main`:
- branch **`wt/codex-processor-bugfixes-20260712`** (9 commits, work dated 2026-07-17), and
- a patch series in gitignored **`old/codex-processor-fixes-20260717/`**.

Re-derive against current `main` — do not merge it. Everything else in it is probably superseded (the
run-config work was re-implemented as `W16.cfg1`–`cfg5`), but "probably" is why it was kept.

**Quickest check that your handoff is complete:** run `ops/autonomous/next-queue-item.sh` and confirm the first
`ok` line is the item you *intend* the daemon to do next, and that no item you just finished still appears.

## Ownership lanes (safe to run in parallel)

| Lane | Territory |
|------|-----------|
| **reader** | `ArchiveReader/` — views, navigation, tag editing (via `TagWriter`), content index |
| **processor-macOS** | `ArchiveProcessor/macOS/` — OCR pipeline, tagging, review flows, capture server |
| **processor-iOS** | `ArchiveProcessor/ArchiveCaptureiOS/` — iPhone capture companion. **PARKED 2026-07-18** — source retained, full-app build out of the verify loop; see `ArchiveCaptureiOS/PARKED.md` |
| **processor-android** | `ArchiveProcessor/ArchiveCapture/` — Android capture companion |
| **notes** | `ArchiveNotes/` — note/extract store, editor, index, cross-app linking, Zotero |
| **suite** | root docs, `SPEC/`, `release/`, `launch.sh` dispatcher |

## Shared hotspots — coordinate before editing

- **`SPEC/tag-format.md`** — the tag/PDF contract. A change here means the Processor *writer* and Reader
  *reader/editor* both change, together, in one reviewed unit. Highest‑risk shared surface.
- **`packages/ArchiveCore/`** — the shared read-side contract (tags, PDF, durable links, suite marker).
  Cross-app surface: changes here affect Reader, Processor, and Notes.
- **Each app's `project.yml`** — the XcodeGen source of truth (schemes, targets, entitlements).
- **`release/build-suite-dmg.sh`** — the single build/packaging path.
- **Processor's phone↔Mac Live‑Capture protocol** and its append‑only `ProviderModels` enums — see
  `ArchiveProcessor/AGENTS.md`.

## Verification

Build‑verify the app(s) you touched before merging to `main`:
`cd <app>/macOS && xcodegen generate && xcodebuild -scheme <App> -configuration Debug -derivedDataPath ./build/DD build`.
Run the app's tests where present (Reader has an XCTest bundle + `scripts/lint-write-surface.sh`;
Processor has `scripts/test-smoke.sh` / `test-tier2.sh`, plus `scripts/e2e-phone-mac.sh` — the full
phone↔Mac round-trip E2E on the emulator, the functional test for `Capture/`/`Net/` changes). Tag‑write
changes are Tier‑2 (adversarial review + tests on scratch copies).

### GUI verification — you can drive it yourself; don't punt it to the owner

**All the TCC grants are in place (verified 2026-07-16): Screen Recording, Accessibility, and Automation** —
plus `cliclick` at `/opt/homebrew/bin/cliclick`, and the Processor's Keychain **"Always Allow" is seeded** so
its GUI launches unattended. Quick self-check: `screencapture -x /tmp/x.png` writes a non-empty file, and
`osascript -e 'tell application "System Events" to return name of first process whose frontmost is true'`
returns the frontmost app.

So **a session can launch, drive, and screenshot any of the three apps itself.** Triage a GUI check before
asking the owner for anything:

| What you're verifying | How |
|---|---|
| A control **exists / is wired** ("is the toggle there?", "is it bound to the right key?") | **Read the code** — a grep. Never an owner question. |
| Something **actually rendered** (a PDF/scan drew, a thumbnail isn't blank, a view isn't the wrong colour) — the truth the accessibility tree is blind to | **Render to pixels headlessly** (no launch, no TCC): `RenderProbe`/`DocumentRenderGuardTests` in the Reader unit bundle — `assertRendersNonBlank` etc. Rendered PNGs are logged `ARTIFACT <name>: <path>` — **`Read` them**. See `ops/gui/README.md`. |
| It **renders / behaves** (layout, interaction, a bug repro) | **Off-screen in the Tart VM** — `ops/gui/vm-gui-runner.sh xcuitest\|sighted\|both` (XCUITest + a VNC pixel grab; artifacts in `~/.tart-mirror/vm-artifacts/` → **read the shot**). See `ops/gui/README.md` §3. The host loop (`./launch.sh` + `cliclick` + `ops/gui/capture-window.sh`) does the same job but **takes over the physical screen** — interactive sessions only, with the owner's agreement. |
| **Subjective taste** (does this look right?), an **API key**, or an **account/device** action | Genuinely owner-only — ask. |

**Unattended sessions: the host screen is off-limits, mechanically.** Whenever `ARCHIVE_UNATTENDED=1` (the
daemon always sets it), `.claude/hooks/no-host-gui.sh` hard-DENIES host UITest runs, `launch.sh`/`gui-drive*`/
`capture-window.sh`/`cliclick`/`osascript`, a windowed Android emulator (use `-no-window`), and the iOS
Simulator — always naming the VM route to take instead. Don't engineer around a denial: take the VM lane, or
leave the item for the owner. Interactive sessions are unaffected. **A hook only sees the command string, so
a wrapper script slips past it** — that is how `./ArchiveNotes/test-smoke.sh` put ArchiveNotesUITests on the
owner's screen on 2026-07-30. Two more layers close it: the smoke scripts restrict themselves to the unit
bundle when unattended, and **`ops/autonomous/bin/` holds a PATH shim per screen-reaching binary** —
`xcodebuild`, `open`, `osascript`, `cliclick`, `emulator` — which the daemon prepends, so the exec is caught
at any nesting depth. Each refuses only the argv forms that draw (a whole-scheme `xcodebuild test`,
`open -a`/`open *.app`, an AppleScript that drives an app, any `cliclick`, a windowed `emulator`) and passes
everything else straight through. The **health gate** sets `ARCHIVE_UNATTENDED=1` itself, because it runs in
the daemon loop where no PreToolUse hook applies. Related: the unit suites are app-hosted
(they launch the real `.app`) but draw nothing since 2026-07-30 — ArchiveCore `ArchiveTestHost`.

Rules while driving: point the app at a **scratch copy, never the real corpus** (choosing a folder clobbers the
owner's root bookmark — see the Reader Core Directive), and quit the app when done
(`osascript -e 'quit app "ArchiveReader"'`). If a check truly can't be driven, say *why* — don't assert "GUI
blocked" as a blanket reason; that claim was stale for a long time and cost the owner a lot of pointless
eyeballing.
