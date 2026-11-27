# Gemini Orchestrator Playbook — Archive Suite

Owner-authorized 2026-11-27 (Google AI Ultra plan). Use this playbook in an interactive Antigravity `/goal` session
so Gemini contributes to Archive Suite continuously and safely alongside the Agent Manager engine (Claude + Codex)
without manual steering.

## 0. Standing rules (read first, never violate)

1. Read `~/Claude/CLAUDE.md`, `Archive Suite/CLAUDE.md`, and the touched app's `CLAUDE.md` before editing code.
2. **Worktree-first:** Never edit, build, or commit in the primary checkout (`/Users/cp1/Claude/Archive Suite`). Create a
   fresh worktree in `/Users/cp1/Claude/.worktrees/archive-suite/suite-wt-gemini-<slug>-<stamp>` from `origin/main`,
   run `xcodegen generate` there when touching an app, and remove your worktree after pushing.
3. **Never touch an engine-claimed item:** Before picking any item, inspect `~/.local/state/archive-autonomous/claims/`
   and `manager.py status`. Skip every item currently claimed by a running Claude or Codex worker.
4. **Never spend >$7 real money** without asking; never touch the real corpus (`~/Desktop/Google Drive/Archival Photos/`).
5. **No production material (owner, 2026-08-01):** No migration paths or backward-compatible parsing; state
   `No migration written: nothing to migrate.` in the commit body.
6. **Same-commit doc sync:** Move shipped entries from `SUITE_TODO.md` to the END of `SUITE_TODO_DONE.md`
   (append-only, `· §<section>`, closing `<!-- /<TAG> -->`), update `verification/SUSPECTS.md` and `KNOWN_ISSUES.md`
   in the same commit.
7. **Publish via standing helper:** From the root of the clean linked worktree (after `git fetch origin && git rebase origin/main`
   and unsetting any `GIT_*` overrides), run `/Users/cp1/.local/libexec/agent-workflow publish-main` as a standalone
   command (runs the mandatory secrets scan and fast-forward pushes to `main`). Never bypass hooks or force-push.
8. **Mark complete in the live plan:** After `publish-main` succeeds, run:
   `bash "/Users/cp1/Claude/Archive Suite/ops/autonomous/plan-edit.sh" "/Users/cp1/Claude/Archive Suite/.maintenance/AUTONOMOUS_PLAN.md" complete <TAG> <SHA> "<summary>"`.
9. **Owner gates & holds:** Never guess on an open owner gate (`*-owner-ok`) or `(needs: owner)` hold. If a task hits
   an owner-only decision, leave the gate open, write a clear Daemon Report entry (`plan-edit.sh ... report "..."`), and
   move on to the next safe item.

## 1. Loop: observe → select → execute → publish → repeat

At the start of every cycle:

```bash
/usr/bin/python3 "/Users/cp1/Claude/Agent Manager/manager.py" status
ls -la ~/.local/state/archive-autonomous/claims/ ~/.local/state/archive-autonomous/heavy/
bash "/Users/cp1/Claude/Archive Suite/ops/agent/queue.sh"
```

### Mode A — Engine actively running Swift/VM work (`mac-heavy-lock` busy or Claude/Codex workers active)

Do **not** compete with the engine for `mac-heavy-lock` (Xcode builds or Tart VM tests). Pick only **`light`-only**
items (`uses` is `["light"]` alone — no `build`, `vm`, `machine`, or `paid`, and no open owner hold or active claim).

Priority order in Mode A (owner-approved 2026-11-27 to pull `light`-only 1.1/2.0 items while 1.0 Swift is busy):
1. **1.0 `light`-only items** (e.g. `W49.plan-e2e-archive`, ops/doc/script hygiene).
2. **1.1 `light`-only bench & `ArchiveOCRBench` items** (behind `W46.nice-to-have`, pure Python/HTML/data — e.g.
   `W46.ocr-churro-overlap`, `W49.bench-more-kinds`, `W49.bench-news-chart`, `W49.bench-seg-check-chart`).
3. **2.0 `light`-only research/design/tooling items** (behind `W50.v2-release`, pure docs/Python — e.g.
   `W49.personal-repository-migration-kit`, `W49.proc-footnote-links` research, `W46.truth-96-human-keyed` tooling).

*Note on 1.1/2.0 `light`-only items:* When completing a `light`-only item that was gated behind `W46.nice-to-have` or
`W50.v2-release`, record the owner's 2026-11-27 authorization in the commit message and DONE entry. Never pull `paid`,
`build`, `vm`, or `machine` items out of 1.1/2.0 without explicit approval.

### Mode B — Engine idle or Claude/Codex capped (`mac-heavy-lock` free)

When Claude and Codex are at their weekly stop (or no worker is running on `Archive Suite`), work straight down the
**1.0 queue** in priority order:

1. **Codex-pinned independent suspect verifications** (`agent: codex`, e.g. `W49.proc-s054-verify`, `S-059`–`S-066`,
   `W49.reader-catalogue-field-status`, `W49.notes-s055-verify`) — Gemini is an independent provider from Claude, so
   verifying and fixing these satisfies phase rule 5a. **Batch 2–4 small suspects in the same app into one worktree and
   one build/test cycle** to avoid redundant Xcode builds.
2. **Tier P / `W40.g3` blockers** (everything blocking the Processor guided walkthrough).
3. **Regular 1.0 `ok` items** top-to-bottom (`queue.sh` order), preferring items whose verification does not require
   a live owner session or paid API key.

## 2. Verification bar per batch

- **Swift changes (`build`):** Clean Debug build in the worktree (`-derivedDataPath ./build/DD`), zero new warnings,
  relevant headless test scripts (`scripts/test-*.sh` or `swift test` / unit bundle) passing `ALL PASS`. For Tier-2
  changes (file-writing, tag/PDF SPEC, actor isolation, `Capture/`/`Net/`), run a focused adversarial self-review or
  subagent review before committing.
- **Python / bench / ops changes (`light`):** Run the relevant unit/proof scripts (`test_*.py`, `build.py --check`,
  `prove-*.sh`) and confirm `$0` spend.
- **Keep `~/Claude` tidy:** Remove every finished worktree and do not leave stray temp files in the repo.

## 3. When to stop and report

Stop the `/goal` loop and present a concise summary to the owner when:
- No safe unblocked items remain in either Mode A (if busy) or Mode B (if idle);
- A host/build/test failure blocks further progress; or
- A cluster pack is ready for owner submission on Colab (`ArchiveProcessor/scripts/segbench/colab/`) or Sherlock.
