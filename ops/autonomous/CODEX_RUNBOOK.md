# Working the queue with Codex (or any agent other than the daemon)

This is the loop for an external agent that drains the daemon's work queue while the daemon is stopped. It
uses the same queue, the same trackers and the same rules as the daemon, so either one can pick up where the
other stopped. The rules themselves live in [`AGENTS.md`](../../AGENTS.md) and [`CLAUDE.md`](../../CLAUDE.md);
this file only puts them in order.

## Starting prompt for the owner

Paste this into Codex, opened on `~/Claude/Archive Suite`:

> Work the Archive Suite queue by following `ops/autonomous/CODEX_RUNBOOK.md` exactly. The daemon is stopped.
> Keep going item after item without checking in; stop only for the reasons the runbook lists.

After that, "Continue" is enough to resume after an interruption.

## Before the first item

1. Confirm the daemon is stopped: `./ops/autonomous/daemon.sh status` must say "Not running". If it is
   running, stop here and tell the owner. Two workers on one queue take the same item. Only the owner starts
   the daemon; do not start or stop it yourself.
2. Run `./ops/autonomous/check-handoff.sh` from the primary checkout. It must end `HANDOFF: CLEAN`. If it does
   not, fix what it names before taking new work; a leftover from the last session comes first.
3. Set up the shell the way the daemon does, so nothing you run can draw on the owner's screen. Claude's hooks
   do not run under Codex, so these two lines are the only guard you have:
   ```bash
   export ARCHIVE_UNATTENDED=1
   export PATH="$PWD/ops/autonomous/bin:$PATH"   # run from the checkout you are working in
   ```
   GUI checks go to the off-screen VM: `ops/gui/vm-gui-runner.sh <reader|notes|processor> xcuitest`.

## The loop, once per item

1. **Pick.** Run `./ops/autonomous/next-queue-item.sh` and take the first line that starts with `ok`. Do not
   choose by interest or size; the order is the priority. Items in the plan's `## HOLD QUEUE` never appear here
   and are not yours.
2. **Read.** `grep -n '<TAG>' SUITE_TODO.md` and read the item's whole entry. Then read the touched app's
   `CLAUDE.md` and `AGENTS.md`. If the tag appears in `OWNER_AUTHORIZATIONS.md`, its ⛔ constraints bind you.
   Run `git log --oneline --grep='<TAG>'`: if a final commit already exists, the item is done and only the
   trackers are behind. Reconcile them and pick again.
3. **Isolate.** From the primary checkout:
   ```bash
   stamp="$(date +%Y%m%d-%H%M%S)"
   git worktree add "../suite-wt-<slug>-$stamp" -b "codex/<slug>-$stamp"
   ```
   Work only in that worktree. Run `xcodegen generate` in each app you build.
4. **Do and verify.** Clean build with no new warnings, then the touched app's smoke test
   (`./test-smoke.sh archivecore|reader|notes`; the `processor` smoke spends a few cents). Tier-2 work
   (Capture/Net, file-writing tag output, finalize/manifest, actor isolation, the tag/PDF SPEC, shared
   ArchiveCore) also needs an independent adversarial review of the diff and a functional test on scratch
   copies. Never touch the real corpus at `~/Desktop/Google Drive/Archival Photos/`.
5. **Checkpoint.** On a long item, commit and push at every green point, with `(checkpoint n/N)` in the
   subject. Only the final commit moves the tracker entry. Uncommitted work is the one thing that has actually
   been lost in this repo.
6. **Ship.** The final commit contains the code and the tracker change together:
   - move the item's whole entry from `SUITE_TODO.md` to `SUITE_TODO_DONE.md`, under the matching heading,
     as `- [x] **<TAG> — <title>** … SHIPPED <date> (this commit)`. Write the tag bare. A tag wrapped in
     backticks (`` **`W9.b5`** ``) cannot be parsed by the tracker scripts;
   - update `KNOWN_ISSUES.md` and delete a shipped `execution-plans/` plan where that applies;
   - write the subject as `<type>(<scope>): <TAG> — <summary>`. The tag must be in the subject, because
     that is how the next session finds prior work on an item. Add a body saying what was verified and a
     trailer naming the agent and model, for example `Agent: Codex (<model>)`.

   Then `git pull --rebase origin main` and `git push origin HEAD:main`.
7. **Record.** Immediately after the push, and not before it, tick the item in the primary checkout's
   `.maintenance/AUTONOMOUS_PLAN.md` (`[x]`, the sha and a one-line result) and append a line to its
   Session Log. The plan is gitignored, so this edit is invisible to git and the easiest step to forget. The
   daemon reads only the plan to choose work: an unticked item is done twice.
8. **Hand off.** Advance the primary checkout, check, and clean up:
   ```bash
   primary="$(dirname "$(git rev-parse --git-common-dir)")"
   git -C "$primary" merge --ff-only origin/main
   "$primary/ops/autonomous/check-handoff.sh"
   git -C "$primary" worktree remove "../suite-wt-<slug>-$stamp"
   git -C "$primary" branch -d "codex/<slug>-$stamp"
   ```
   Then go back to step 1 without asking.

## Filing new work

A follow-up you discover gets a `[ ]` entry in `SUITE_TODO.md` **and** a one-line mirror in the plan's
`## WORK QUEUE`, in the same commit, with the tag byte-identical in both. An item that is not in the plan does
not exist for the daemon. If the follow-up must wait for another item, write `(blocked-on: <TAG>)` on it;
the resolver reads that tag and cannot read prose.

## When to stop

Stop and report to the owner only when:

- `next-queue-item.sh` prints no `ok` line;
- git refuses an operation (never `--force`, `reset --hard` or `branch -D` past a refusal; the files may be
  another session's work);
- the daemon turns out to be running;
- the item needs something only the owner can supply: a write to the real corpus, a release (DMG,
  `gh release`, version tag), a key, an account, a device, or a matter of taste.

For that last case, append a short entry to the plan's `## Daemon Report` saying what is needed, leave the
item `[ ]`, and continue with the next `ok` item. Stop only when nothing actionable is left. A genuine "X or
Y?" behaviour question is handled the same way.

Being low on context or budget is not a stop reason in itself: push a checkpoint, record the remaining steps in
the plan's Session Log, and end there. The next session continues from the checkpoint.

## Why each step exists

Every step above repairs something that actually went wrong. The long history is in `AGENTS.md` and
`SUITE_TODO_DONE.md`; the short version:

- **Primary checkout lagging** (2026-07-29): the daemon reads the plan from the primary checkout and installs
  its own scripts from that working tree, so a stale primary re-installs stale daemon scripts.
- **Plan not ticked**: the daemon redid finished work three times (`W15.tu1`, `W15.tu4`, `W16.lan2`), and
  every item blocked on an unticked tag read as blocked.
- **Items filed without a plan mirror** (2026-08-13): 27 open items were invisible to the daemon. The daemon
  and interactive sessions filed most of them, so this rule applies to everyone.
- **Uncommitted work** (2026-07-29, 2026-08-13): a removed worktree held about 2,900 uncommitted lines; later
  `W19.q2` sat as 107 lines of passing work with no commit and collided with the daemon.
- **External tools**: Codex's own sandbox supplies `rg`, but the daemon's PATH does not include it. A shell
  script you add must work under `/opt/homebrew/bin` and the system tools alone.
