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
  removed and it is gone (its work was preserved first; see §"Working the to-do list as an external agent",
  rule 6). Don't go looking for it. The standing rule is unchanged and matters more than the
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

The owner sometimes stops the daemon and has an external agent (Codex) work the queue instead. **If that is
you, follow [`ops/autonomous/CODEX_RUNBOOK.md`](ops/autonomous/CODEX_RUNBOOK.md)**: it is the whole loop in
order (pick, isolate, verify, ship, record, hand off, next), with a starting prompt for the owner. The
conventions above apply unchanged. The daemon also depends on state that a normal `commit && push` does not
touch, so these rules are not optional. Each one repairs something that actually went wrong:

1. **`git push` is not "done". Advance the PRIMARY checkout too** (`git -C "$primary" merge --ff-only
   origin/main`, with `primary="$(dirname "$(git rev-parse --git-common-dir)")"`; never a bare `cd "$REPO"`,
   which is a silent no-op when the variable is unset). The daemon reads the plan from the primary checkout and
   `daemon.sh` installs its scripts from that working tree, so a lagging primary re-installs stale scripts.
2. **Tick the daemon's plan, not just `SUITE_TODO.md`.** `.maintenance/` is gitignored, and
   `next-queue-item.sh` walks the plan's `## WORK QUEUE` with "a `[ ]` anywhere wins". Unticked, the daemon
   redoes finished work (`W15.tu1`, `W15.tu4`, `W16.lan2`) and every dependent reads as blocked.
3. **An item in `SUITE_TODO.md` is invisible to the daemon until it is mirrored into the plan's queue**, as a
   one-liner with the tag byte-identical. On 2026-08-13, 27 open items had no plan line, and attribution put
   every one in a commit in this project's own convention, not an external agent's. The omission happens at
   filing time, so **whenever you FILE an item, mirror it in the same commit**, whoever you are.
4. **Irreversible-path findings are gated by TIER-2, not by an owner signature** (lifted 2026-08-13; see
   §*Gating baseline*). Do not re-impose the old per-item rule. Existing grants in
   [`OWNER_AUTHORIZATIONS.md`](OWNER_AUTHORIZATIONS.md) stay a record and their ⛔ constraints still bind.
5. **A review is queued, not just reported.** Each confirmed finding becomes a `[ ]` item (rule 3 applies);
   cite the baseline sha and the function/symbol, since line numbers go stale; archive the report under `old/`.
6. **Checkpoint-commit at every green point, and remove your worktree.** Uncommitted work is the one thing
   actually lost here: a worktree removed on 2026-07-29 held ~2,900 uncommitted lines, and on 2026-08-13
   `W19.q2` sat as 107 passing, uncommitted lines that collided with the daemon. (That 2026-07-29 work is kept
   on branch `wt/codex-processor-bugfixes-20260712` and in `old/codex-processor-fixes-20260717/`; its live
   piece shipped as `W23.h5`. Do not merge it.)
7. **`ops/autonomous/check-handoff.sh` is the definition of "handed off".** It checks rules 1–3 and 6 and
   prints what the daemon would take next; it is also wired into `health-gate.sh` (`W31.handoff-gate`).

## Gating baseline — TIER-2 IS THE GATE (owner, 2026-08-13)

**Default: if Tier-2 is satisfied, the daemon may execute it. No owner signature.** Tier-2 itself is unchanged
and still mandatory — adversarial self-review + a functional test, scratch copies, never the real corpus (root
[`CLAUDE.md`](CLAUDE.md) → *How we work* step 3). What changed is that Tier-2 is now the WHOLE gate for the
irreversible-code categories, not Tier-2 *plus* a named entry in `OWNER_AUTHORIZATIONS.md`.

**Still owner-gated — these three, and nothing else:**
1. ⛔ **A write to the REAL corpus** — `~/Desktop/Google Drive/Archival Photos/` (~102k PDFs, irreplaceable,
   predates the apps). Reader's Core Directive and scratch-copy-only testing stand exactly as before.
2. ⛔ **Work only the owner can perform or judge** — a key, an account, a device, a console paste, taste.
3. ⛔ **Tier-3 releases** — a DMG, `gh release`, or a version tag. **Never part of the 2026-08-13 narrowing**;
   it is the one category that reaches outside this machine, and `--disallowedTools` blocks `hdiutil` and
   `gh release` at the tool layer as defence in depth.

**NO LONGER a gate — do NOT re-impose it from an older doc:** `Capture/`·`Net/`, finalize/manifest,
file-writing tag/output, **money**, and `SPEC/tag-format.md`. The per-item rule was written 2026-07-07 on the
premise that these paths write irreplaceable data; the 2026-08-01 STANDING PREMISE voided it (no app here has
produced data the owner keeps, and the corpus these paths do not write is the only irreplaceable thing), and
the signature bought nothing Tier-2 did not — which is why five items sat parked for weeks. His words: on
money, *"the daemon only spends tiny amounts and the keys are capped"*; on the SPEC, *"nothing real has been
created by these apps yet."* **Cost discipline is NOT lifted:** cheapest capable model, smallest input set,
state the cost of a big run. No permission, no blank cheque.

**A POLICY change is itself Tier-2, and its blast radius is PROSE.** On 2026-08-13 the change was made in four
files and the old rule was restated in **ten more** — including the plan's general decision rule,
`ops/autonomous/README.md`'s reference definition of WS10, and an item spec that still instructed the opposite
of what the owner had just decided. All ten passed every existing check, because those read checkbox and byte
state and **none reads prose**. So after changing policy, sweep for RESTATEMENTS, not just the defining file —
especially `.maintenance/AUTONOMOUS_PLAN.md` and `ops/autonomous/resume-prompt.txt`, which no commit hook can
see — then run **`ops/autonomous/check-policy-coherence.sh`** and add a rule for what you changed.
⚠️ **This very section was DELETED by accident on 2026-08-13** while trimming this file under its byte budget,
leaving four dangling pointers to it and no policy anywhere; the coherence checker passed, because it looked
only for forbidden phrases and not for the policy's PRESENCE. It now asserts this heading exists. When you trim
a doc, diff what left — a byte count falling is not evidence of compression.

**A genuine behaviour question is still a question.** Where an item says "decide X versus Y" and there is no
correct answer, bring it to the owner as a *question* at Daemon Report — file it and move on; do not park the
item as owner-gated.

**The structural mechanism is unchanged:** what physically keeps the daemon off an item is its absence from the
plan's `## WORK QUEUE` (`ops/autonomous/next-queue-item.sh` walks only that).

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
| It **renders / behaves** (layout, interaction, a bug repro) | **Off-screen in the Tart VM** — `ops/gui/vm-gui-runner.sh reader\|notes\|processor xcuitest\|sighted\|both` (XCUITest + a VNC pixel grab; artifacts in `~/.tart-mirror/vm-artifacts/<app>/` → **read the shot**). See `ops/gui/README.md` §3. The host loop (`./launch.sh` + `cliclick` + `ops/gui/capture-window.sh`) does the same job but **takes over the physical screen** — interactive sessions only, with the owner's agreement. |
| **Subjective taste** (does this look right?), an **API key**, or an **account/device** action | Genuinely owner-only — ask. |

**Unattended sessions: the host screen is off-limits, mechanically.** Whenever `ARCHIVE_UNATTENDED=1` (the
daemon always sets it), `.claude/hooks/no-host-gui.sh` hard-DENIES host UITest runs, `launch.sh`/`gui-drive*`/
`capture-window.sh`/`cliclick`/`osascript`, a windowed Android emulator (use `-no-window`), and the iOS
Simulator — always naming the VM route to take instead. Don't engineer around a denial: take the VM lane, or
leave the item for the owner. Interactive sessions are unaffected. **A hook only sees the command string, so
a wrapper script slips past it** — that is how `./ArchiveNotes/test-smoke.sh` put ArchiveNotesUITests on the
owner's screen on 2026-07-30. Two more layers close it: smoke scripts select the unit bundle when unattended
(and Notes now does so on every invocation), and **`ops/autonomous/bin/` holds a PATH shim per screen-reaching binary** —
`xcodebuild`, `open`, `osascript`, `cliclick`, `emulator` — which the daemon prepends, so the exec is caught
at any nesting depth. Each refuses only the argv forms that draw (a whole-scheme `xcodebuild test`,
`open -a`/`open *.app`, an AppleScript that drives an app, any `cliclick`, a windowed `emulator`) and passes
everything else straight through. The **health gate** sets `ARCHIVE_UNATTENDED=1` itself, because it runs in
the daemon loop where no PreToolUse hook applies. Related: the unit suites are app-hosted
(they launch the real `.app`) but draw nothing since 2026-07-30 — each app's local `ArchiveTestHost`.

Rules while driving: point the app at a **scratch copy, never the real corpus** (choosing a folder clobbers the
owner's root bookmark — see the Reader Core Directive), and quit the app when done
(`osascript -e 'quit app "ArchiveReader"'`). If a check truly can't be driven, say *why* — don't assert "GUI
blocked" as a blanket reason; that claim was stale for a long time and cost the owner a lot of pointless
eyeballing.
