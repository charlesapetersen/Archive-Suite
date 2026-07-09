# Autonomous overnight run — the durable self-resume system

A reusable way to run **unattended, multi-hour maintenance** on this repo that survives usage cutoffs,
context compaction, and session restarts. Standing principles: memory `autonomous-plan-cron-resume`,
`overnight-jobs-queue`, `no-force-override-destructive-git`; root `CLAUDE.md` §"How we work".

## The three layers

- **L0 — durable plan (the foundation).** `.maintenance/OVERNIGHT_PLAN.md` (gitignored, on-disk) is the
  single source of truth: PRIME DIRECTIVES + RESUME PROTOCOL + a checkboxed WORK QUEUE + Session Log +
  Morning Review. Every increment is committed+pushed, so any fresh session recovers full state from the
  plan + `git log` + `SUITE_TODO.md`. **This is what makes the run resilient to losing context/usage.**
- **L1 — self-resume daemon (`archive-suite-overnight.sh`).** A loop that every ~20 min fires ONE fresh
  headless `claude -p` to advance the plan by one bounded item, then the session commits+pushes+stops. A
  usage-exhausted window just fails fast; the next cycle retries when the cap resets (~5h). Safety:
  `--permission-mode default` (**never** bypass), a scoped `--allowedTools` + a destructive
  `--disallowedTools` denylist, `--max-budget-usd`, a wall-clock `timeout`, and a stale-lock guard so cycles
  never overlap. The script lives in `~/.local/bin` (outside the TCC-protected `~/Desktop`).
- **L2 — the resume prompt (`resume-prompt.txt`).** The exact instructions each fresh session follows
  (recover state → pick the first `[ ]` item → own worktree → verify → commit+push+tick → stop).

## Install / run

The committed copies here are the source of truth; install to the runtime location:

```bash
cp ops/overnight/archive-suite-overnight.sh ~/.local/bin/ && chmod +x ~/.local/bin/archive-suite-overnight.sh
cp ops/overnight/resume-prompt.txt ~/.local/state/archive-overnight/
```

**Primary (no launchctl, no owner needed) — a detached loop that inherits the current TCC context:**
```bash
setsid nohup ~/.local/bin/archive-suite-overnight.sh >/dev/null 2>&1 &
```

**Reboot-durable option (owner-armed, once):** the detached daemon may lose `~/Desktop` access when its
parent terminal exits (macOS TCC). To survive a reboot / terminal close, arm the LaunchAgent — and if it
logs `Operation not permitted`, grant **Full Disk Access** to `/bin/bash` (System Settings → Privacy):
```bash
cp ops/overnight/com.archivesuite.overnight.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.archivesuite.overnight.plist
```

## Stop / status

```bash
tail -f ~/.local/state/archive-overnight/daemon.log            # cadence + rc of each resume
tail -f ~/.local/state/archive-overnight/last-session.log      # the most recent resume's transcript
pkill -f archive-suite-overnight.sh                            # stop the detached daemon
launchctl bootout gui/$(id -u)/com.archivesuite.overnight      # stop the LaunchAgent (also auto at COMPLETE)
```
The daemon self-terminates when the plan's `RUN STATUS:` line reads `COMPLETE`.

## Guardrails (never overridden)

File-safety > everything (never a real corpus); worktree-first in your OWN worktree; never `--force` past a
git/tool refusal; Tier-2 (adversarial review + functional test) for no-undo changes; docs move with the code
in the same commit. See the plan's PRIME DIRECTIVES for the full list.

For the paced **code-review** portion, see `REVIEW.md` (root) — one subsystem unit per session, lean
fan-out, refute-verify; never the retired 15-finder monolith.
