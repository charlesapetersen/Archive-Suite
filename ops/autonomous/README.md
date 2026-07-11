# Autonomous autonomous run — the durable self-resume system

A reusable way to run **unattended, multi-hour maintenance** on this repo that survives usage cutoffs,
context compaction, and session restarts. Standing principles: memory `autonomous-plan-cron-resume`,
`autonomous-jobs-queue`, `no-force-override-destructive-git`; root `CLAUDE.md` §"How we work".

## The three layers

- **L0 — durable plan (the foundation).** `.maintenance/AUTONOMOUS_PLAN.md` (gitignored, on-disk) is the
  single source of truth: PRIME DIRECTIVES + RESUME PROTOCOL + a checkboxed WORK QUEUE + Session Log +
  Morning Review. Every increment is committed+pushed, so any fresh session recovers full state from the
  plan + `git log` + `SUITE_TODO.md`. **This is what makes the run resilient to losing context/usage.**
- **L1 — self-resume daemon (`archive-suite-autonomous.sh`).** A loop that every ~20 min fires ONE fresh
  headless `claude -p` to advance the plan by one bounded item, then the session commits+pushes+stops. A
  usage-exhausted window just fails fast; the next cycle retries when the cap resets (~5h). Safety:
  `--permission-mode default` (**never** bypass), a scoped `--allowedTools` + a destructive
  `--disallowedTools` denylist, `--max-budget-usd`, a wall-clock `timeout`, and a stale-lock guard so cycles
  never overlap. The script lives in `~/.local/bin` (outside the TCC-protected `~/Desktop`).
- **L2 — the resume prompt (`resume-prompt.txt`).** The exact instructions each fresh session follows
  (recover state → pick the first `[ ]` item → own worktree → verify → commit+push+tick → stop).

## Install / run

**One command (preferred): `./ops/autonomous/arm.sh`** — checks every prerequisite (claude CLI outside
`~/Desktop`, daemon + resume prompt present, an L0 plan whose `RUN STATUS` is `IN_PROGRESS` with unchecked
`[ ]` items), installs the latest committed copies to the runtime location, refuses to double-launch, warns
with the exact fix if the plan is stale-`COMPLETE`, launches detached, and confirms the first cycle started.
Also `arm.sh status` (read-only) and `arm.sh stop`. The manual steps below are what it automates.

The committed copies here are the source of truth; install to the runtime location:

```bash
cp ops/autonomous/archive-suite-autonomous.sh ~/.local/bin/ && chmod +x ~/.local/bin/archive-suite-autonomous.sh
cp ops/autonomous/resume-prompt.txt ~/.local/state/archive-autonomous/
```

**How we run it — the standard, accepted setup: a detached loop under the launching session's TCC/screen
grant.** macOS has **no `setsid`**, so use a subshell + `nohup` to detach it so it survives the launching
command returning:
```bash
( nohup ~/.local/bin/archive-suite-autonomous.sh >~/.local/state/archive-autonomous/nohup.out 2>&1 & )
```
It runs while this login session is alive and inherits its `~/Desktop`/screen (TCC) grant — which is all we
need. **If the terminal/session that launched it closes, the daemon stops — and that is fine, by design:**
just start it again from your next session. All state is durable in the plan + `git`, so a stop loses nothing
and the next start continues the queue. **We deliberately do NOT chase reboot/close durability** — the
detached, session-scoped run is the normal behavior, not a stopgap.

**Optional — reboot-durable (rarely needed, NOT the default).** Only if you specifically want the run to
survive a reboot or the launching session closing, arm the LaunchAgent (may log `Operation not permitted`
until you grant **Full Disk Access** to `/bin/bash` in System Settings → Privacy). Normal use does not need it:
```bash
cp ops/autonomous/com.archivesuite.autonomous.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.archivesuite.autonomous.plist
```

## Stop / status

```bash
tail -f ~/.local/state/archive-autonomous/daemon.log            # cadence + rc of each resume
tail -f ~/.local/state/archive-autonomous/last-session.log      # the most recent resume's transcript
pkill -f archive-suite-autonomous.sh                            # stop the detached daemon
launchctl bootout gui/$(id -u)/com.archivesuite.autonomous      # stop the LaunchAgent (also auto at COMPLETE)
```
The daemon self-terminates when the plan's `RUN STATUS:` line reads `COMPLETE`.

## Guardrails (never overridden)

File-safety > everything (never a real corpus); worktree-first in your OWN worktree; never `--force` past a
git/tool refusal; Tier-2 (adversarial review + functional test) for no-undo changes; docs move with the code
in the same commit. See the plan's PRIME DIRECTIVES for the full list.

For the paced **code-review** portion, see `REVIEW.md` (root) — one subsystem unit per session, lean
fan-out, refute-verify; never the retired 15-finder monolith.

## Reuse for another project (the daemon is a template)

`archive-suite-autonomous.sh` is a reusable template — its top has a **PROJECT CONFIG** block. To stand up an
autonomous run for a different repo:

1. **Copy the script**, edit the 5 CONFIG lines (or set the `AUTONOMOUS_*` env vars): `LABEL` (a unique slug —
   it names the state dir + the launchd job `com.<LABEL>.autonomous`), `REPO`, `PLAN`, `STATE`, `CLAUDE`.
   Keep the script + the `claude` binary **outside `~/Desktop`/`~/Documents`/`~/Downloads`** (TCC).
2. **Write the L0 plan** (`$PLAN`, gitignored) from the template shape: PRIME DIRECTIVES → RESUME PROTOCOL →
   a checkboxed WORK QUEUE → Session Log → Morning Review, and a **plain** status line
   `RUN STATUS: IN_PROGRESS`.
3. **Write the L2 resume prompt** (`$STATE/resume-prompt.txt`) — recover state → pick first `[ ]` → own
   worktree → verify → commit+push+tick → stop. Reuse this repo's `resume-prompt.txt` as the skeleton;
   adjust the repo path + any per-item notes.
4. **Tune** `AUTONOMOUS_INTERVAL` / `STALE` / `MAXRUN` / `BUDGET` / `EFFORT` and the `ALLOW`/`DENY` tool lists
   for the project's risk surface (keep the destructive denylist; deny always wins over allow). `EFFORT`
   defaults to **`max`** — every resume session runs Opus at max reasoning effort (highest quality; higher
   token burn, so it reaches usage caps sooner and rides them out by retrying). Lower it (`high`/`medium`) if
   you want cheaper, faster cycles.
5. **Start** it detached (the standard way — `( nohup … & )`, under the launching session's grant); the
   per-project `.plist` (`Label` = `com.<LABEL>.autonomous`) is an optional reboot-durable extra, not required.

## Lessons learned (gotchas that cost real time — read before reusing)

- **TCC / protected dirs.** A launchd-context bash **cannot exec a script under `~/Desktop`** — it dies with
  `Operation not permitted` and silently no-ops every cycle. Put the script + `claude` in `~/.local/bin`. The
  script reads/writes the repo under `~/Desktop`: a **detached daemon started from an interactive session
  inherits that session's TCC grant, and that is the standard, accepted way to run it.** If that session
  closes, the run simply stops until you restart it next session (durable state ⇒ no loss) — we accept this
  and do **not** need more durability. launchd reboot-durability is an optional extra (and may need **Full
  Disk Access granted to `/bin/bash`**), not something normal use requires.
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

## Changing this setup — review discipline (added 2026-07-11)

The daemon (`archive-suite-autonomous.sh`), `arm.sh`, the resume prompt, and this setup are
**Tier-2-equivalent infrastructure**: they drive autonomous, self-pushing work next to the file-safety
blast radius. Treat every change to them like a Tier-2 code change:

- **Adversarial self-review before install/arm.** Ask the failure-mode questions explicitly. (The idle-output
  watchdog bug that false-killed healthy sessions would have been caught by one question: *"Does `claude -p`
  actually write to `last-session.log` incrementally?"* — it does not; it emits output only at the end.)
- **Prove the mechanism, don't assume it.** Dry-run the changed logic (simulate the loop; confirm the daemon
  arms + finds its PLAN/STATE) before trusting it on a live run.
- **Parity for renames/moves:** re-grep for stragglers AND confirm the daemon still arms, finds its plan, and
  launches a session.
- Never install a daemon change straight onto a running run without the above.
