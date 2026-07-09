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

## Reuse for another project (the daemon is a template)

`archive-suite-overnight.sh` is a reusable template — its top has a **PROJECT CONFIG** block. To stand up an
overnight run for a different repo:

1. **Copy the script**, edit the 5 CONFIG lines (or set the `OVERNIGHT_*` env vars): `LABEL` (a unique slug —
   it names the state dir + the launchd job `com.<LABEL>.overnight`), `REPO`, `PLAN`, `STATE`, `CLAUDE`.
   Keep the script + the `claude` binary **outside `~/Desktop`/`~/Documents`/`~/Downloads`** (TCC).
2. **Write the L0 plan** (`$PLAN`, gitignored) from the template shape: PRIME DIRECTIVES → RESUME PROTOCOL →
   a checkboxed WORK QUEUE → Session Log → Morning Review, and a **plain** status line
   `RUN STATUS: IN_PROGRESS`.
3. **Write the L2 resume prompt** (`$STATE/resume-prompt.txt`) — recover state → pick first `[ ]` → own
   worktree → verify → commit+push+tick → stop. Reuse this repo's `resume-prompt.txt` as the skeleton;
   adjust the repo path + any per-item notes.
4. **Tune** `OVERNIGHT_INTERVAL` / `STALE` / `MAXRUN` / `BUDGET` and the `ALLOW`/`DENY` tool lists for the
   project's risk surface (keep the destructive denylist; deny always wins over allow).
5. **Start** it detached (primary) or arm the per-project `.plist` (`Label` = `com.<LABEL>.overnight`).

## Lessons learned (gotchas that cost real time — read before reusing)

- **TCC / protected dirs.** A launchd-context bash **cannot exec a script under `~/Desktop`** — it dies with
  `Operation not permitted` and silently no-ops every cycle. Put the script + `claude` in `~/.local/bin`. The
  script may still need to *read/write* the repo under `~/Desktop`: a **detached daemon** started from an
  interactive session inherits that session's TCC grant (works while the parent lives, may lapse after it
  exits); a **launchd** job may need **Full Disk Access granted to `/bin/bash`** (System Settings → Privacy).
  Detached-from-a-live-session is the low-friction primary; launchd is the reboot-durable upgrade.
- **Never bypass permissions.** `--permission-mode default` + a scoped `--allowedTools` and a destructive
  `--disallowedTools` denylist is the approved posture; `--dangerously-skip-permissions` is refused by the
  owner and blocked by the auto-mode classifier. **Deny wins over allow**, and Bash pattern matching is
  coarse (prefix-based) — it guards against *mistakes*, not a hostile actor. Keep the item-per-session prompt
  as the real behavioral guardrail.
- **Can't pre-stage live secrets.** The safety classifier **blocks materializing a live credential to a file**
  the owner didn't explicitly ask for. Don't try to cache API keys; have the task read the app's own secret
  store (Keychain) at run time, or ask the owner to place the key file themselves.
- **Completion sentinel must be greppable.** The daemon stops on `grep '^RUN STATUS: COMPLETE'`. Write the
  plan's status as a **plain** line (`RUN STATUS: IN_PROGRESS`), never markdown-decorated (`**RUN STATUS:**`)
  — otherwise the daemon can never detect COMPLETE and never unloads.
- **Respect the repo's Stop/commit hooks.** This repo has a doc-sync Stop hook that blocks a turn if code
  shipped without touching a tracker. The resume prompt tells each session to flip a `SUITE_TODO.md` checkbox
  in the same commit (or `touch .claude/.docsync-ok` for infra-only). Port the equivalent for a new repo.
- **One bounded item per fresh session, commit+push each.** A single long session is the *worst* case for
  context and dies whole on a usage cutoff. Fresh resumes off the durable plan are the best case — and they're
  what make a mid-run usage cutoff a no-op (the next cycle just continues).
- **Build ALL durable infra before doing any work.** Plan + daemon + prompt on disk first, so an early cutoff
  loses nothing. Then dry-run the daemon's guard predicates (COMPLETE check, lock staleness) before arming.
- **Coordinate against overlap.** A stale-lock (mtime) guard + a per-child heartbeat stops cycles/sessions
  from running two engines at once; worktree-first isolation + `git pull --rebase` before push stop parallel
  sessions from clobbering files or racing the push.
