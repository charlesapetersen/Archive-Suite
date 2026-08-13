# Archive Suite — Agent / Concurrent-Development Guide

Umbrella conventions for working in this monorepo (solo or with multiple agents in parallel). Each app
also has its own `AGENTS.md` with app‑specific lanes — read it before working inside a subdir:
[`ArchiveProcessor/AGENTS.md`](ArchiveProcessor/AGENTS.md) · [`ArchiveReader/AGENTS.md`](ArchiveReader/AGENTS.md) · [`ArchiveNotes/AGENTS.md`](ArchiveNotes/AGENTS.md).

> 🛑 **If the owner asks for the "daemon report" (or "the report", or the old name "morning review"), that
> is a WALKTHROUGH — one decision at a time, waiting for each answer, writing nothing.** It is not a summary
> and not a plan entry. Read [`CLAUDE.md`](CLAUDE.md) → *"THE DAEMON REPORT IS A WALKTHROUGH, NOT A
> DOCUMENT"* before replying. Appending to that section is the *unattended* daemon's job, never yours.

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
# Resolve the PRIMARY checkout from wherever you are — a worktree's common dir points at it. Do NOT write
# a bare `cd "$REPO"`: with REPO unset that is `cd ""`, which bash and zsh treat as a silent no-op (rc 0),
# so the merge would "succeed" in your worktree and leave the primary checkout exactly as stale as before.
primary="$(dirname "$(git rev-parse --git-common-dir)")"
git -C "$primary" merge --ff-only origin/main
```
*(2026-07-29: `origin/main` was at `62a10d1` while the primary checkout still sat at `cb948c6`. Also note
`ops/autonomous/daemon.sh` installs the daemon scripts from **that working tree**, not from `origin/main` — so a
lagging primary checkout silently re-installs stale daemon scripts when the owner restarts it.)*

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

**4. Irreversible-path findings are gated by TIER-2, not by an owner signature — see §*Gating baseline*.**
The old rule here required a per-item entry in [`OWNER_AUTHORIZATIONS.md`](OWNER_AUTHORIZATIONS.md) for
anything touching `Capture/`·`Net/`, finalize/manifest, file-writing tag/output or `SPEC/tag-format.md`. **That
requirement was lifted by the owner on 2026-08-13.** Do not re-impose it, and do not leave such an item for
the owner on those grounds. The full replacement policy, and the two things that ARE still owner-gated, are in
§*Gating baseline* below. Existing grants in `OWNER_AUTHORIZATIONS.md` remain a permanent record and their ⛔
constraints still bind the items they name.

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

**7. Run the gate, don't re-read the list — `ops/autonomous/check-handoff.sh`.**
Items 1–6 are a prose checklist, and a prose checklist is not a gate. One command now checks all of it,
read-only, in a couple of seconds: uncommitted/unpushed work in any worktree, primary-vs-`origin/main`, a
dirty primary tree, **every open `SUITE_TODO` item being visible in the plan**, both tracker guards, and it
prints what the daemon would pick up next for you to eyeball. **A clean run is the definition of "handed
off".** It is not yet a `health-gate.sh` step — that is `W31.handoff-gate`.

**⚠️ The mirroring failure is NOT an external-agent problem — read this before blaming the handoff.** Item 3
was written after the 2026-07-29 Codex handoff, and it is easy to conclude that mirroring is a thing *Codex*
forgets. On 2026-08-13 a pre-restart audit found **27 open `SUITE_TODO` items with no checkbox line anywhere
in the plan** — invisible to `next-queue-item.sh`, skipped in silence. Attributing all 27
(`git log -S<tag> -- SUITE_TODO.md`) put **every one of them in a commit written in this project's own
convention** — `fix(notes): W23.m14 — …`, `fix(ops): two status lines that lied`, `docs(trackers): …`. Three
came from one commit (`c0be2cc`), two more from another (`763eade`). The pattern is a session closing a
parent item, filing the `-fu` follow-up it *just discovered* into `SUITE_TODO`, and never mirroring it. So:
**whenever you FILE a new item, mirror it in the same commit — daemon, interactive session, or external
agent alike.** Filing is exactly when the omission happens, because the item you just wrote feels handled.

**What the 2026-08-13 Codex cycle actually got wrong, for calibration:** one thing, and it was not the
trackers. It left `W19.q2` as **107 lines of green, passing, uncommitted work with zero commits** in
`suite-wt-20260813-011700-w19q2` — item 6's checkpoint rule, unfollowed. A *stray* worktree is tolerable and
the owner has said so (housekeeping GCs a clean merged one by itself); an **uncommitted** one is one power
cut from lost work, and it also collides with the daemon, which would have picked the very same `W19.q2` off
the queue and re-implemented it from scratch. Its trackers were untouched and correctly so — the item was
not done. Checkpoint-commit at every green point; that is the whole lesson from that cycle.

## Gating baseline — TIER-2 IS THE GATE (owner, 2026-08-13)

**Default: if Tier-2 is satisfied, the daemon may execute it. No owner signature.** Tier-2 is unchanged and
still mandatory — adversarial self-review plus a functional test, on scratch copies, never the real corpus
(root [`CLAUDE.md`](CLAUDE.md) → *How we work* step 3). What changed is that Tier-2 is now the WHOLE gate for
the irreversible-code categories, rather than Tier-2 *plus* a named entry in `OWNER_AUTHORIZATIONS.md`.

**Only two things are still owner-gated:**

1. ⛔ **A write to the REAL corpus** — `~/Desktop/Google Drive/Archival Photos/` (~102k PDFs, irreplaceable,
   predates the apps). Untouched by this change and not negotiable. Reader's Core Directive and
   scratch-copy-only testing stand exactly as before.
2. ⛔ **Work only the owner can perform or judge** — an API key, an account, a physical device, a GUI paste in
   a console he owns, or a matter of subjective taste. Not a safety gate; simply nobody else can do it.

**What is NO LONGER a gate, and why — so nobody re-imposes it from an older doc:**

- **`Capture/`·`Net/`, finalize/manifest, file-writing tag/output.** The per-item rule was written 2026-07-07,
  the day after a live-capture finalize deleted a run's originals, on the premise that these paths write
  irreplaceable data. The 2026-08-01 STANDING PREMISE voided that premise: no app in this suite has produced
  data the owner intends to keep, and the corpus these paths do NOT write to is the only irreplaceable thing.
  The authorization also bought no safety that Tier-2 wasn't already buying — it certified only that the owner
  had personally read the item, which is why five items sat parked for weeks while the actual safety mechanism
  was never the bottleneck.
- **Money.** Owner, 2026-08-13: *"We don't need my permission for spending money. The daemon only spends tiny
  amounts and the keys are capped."* This reverses an emphatic earlier ⛔ in root `CLAUDE.md`, which is kept
  struck-through there rather than deleted. **The cost discipline is NOT lifted:** cheapest capable model,
  smallest input set that proves the behaviour, and state the cost before a large run. No permission, no blank
  cheque.
- **`SPEC/tag-format.md`.** Owner, 2026-08-13: *"nothing real has been created by these apps yet."* A SPEC
  change is still the highest-risk shared surface in the repo and still lands with every affected app in ONE
  reviewed unit — that is Tier-2's job, and Tier-2 already required exactly that.

**A genuine behaviour question is still a question.** Where an item says "decide X versus Y" and there is no
correct answer (`W3.cap-r3-fu3`, `-fu4`, `-fu12-fu1`), bring it to the owner — but as a *question*, at Daemon
Report, not as a safety gate. Filing it and moving on is right; parking the whole item as owner-gated is not.

**The structural mechanism is unchanged:** what physically keeps the daemon off an item is its absence from
the plan's `## WORK QUEUE` region (`ops/autonomous/next-queue-item.sh` walks only that). The HOLD QUEUE is
therefore now reserved for the two categories above and for open behaviour questions.

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
⚠️ **`ArchiveReader/scripts/lint-write-surface.sh` also covers `packages/ArchiveCore` now** (W26.lint), so run
it for **any** ArchiveCore change, not just a Reader one. Run it *yourself* rather than waiting for the gate:
`W26.lint-fu` (`f64649b`) made it a `health-gate.sh` step, but that is a backstop every
`AUTONOMOUS_GATE_EVERY` commits, not a per-change check.

⚠️ **Quote every path expansion in a gate script — a worktree hides the bug the gate will hit.** A worktree
is `…/suite-wt-<stamp>` (no space); the primary checkout is `…/Archive Suite` (**a space**), and
`health-gate.sh` derives its `ROOT` from its own location, so **the gate only ever runs at the spaced path**.
An unquoted `$(find …)` or `$VAR` therefore passes every worktree it was developed in and fails *100% of the
time* in the gate. Collect file lists into arrays (`find -print0` + `while read -r -d ''`), quote everything
else. This is not hypothetical: it is exactly how the `tag-vocabulary` step parked the run on 2026-08-08
having never once passed — `W26.gatepath` in `SUITE_TODO_DONE.md`. To verify a gate script the way the gate
will run it, make your worktree path contain a space.

### GUI verification — you can drive it yourself; don't punt it to the owner

**All the TCC grants are in place (verified 2026-07-16): Screen Recording, Accessibility, and Automation** —
plus `cliclick` at `/opt/homebrew/bin/cliclick`, and the Processor's Keychain **"Always Allow" is seeded as of 2026-08-13** (`W21.seed`; it was asserted here from 2026-07-16 but was NOT actually true until then — and it takes ~6 prompts, one per credential, not one) so
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
