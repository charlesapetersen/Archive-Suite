# Autonomous autonomous run — the durable self-resume system

A reusable way to run **unattended, multi-hour maintenance** on this repo that survives usage cutoffs,
context compaction, and session restarts. Standing principles: memory `autonomous-plan-cron-resume`,
`autonomous-jobs-queue`, `no-force-override-destructive-git`; root `CLAUDE.md` §"How we work".

## The three layers

- **L0 — durable plan (the foundation).** `.maintenance/AUTONOMOUS_PLAN.md` (gitignored, on-disk) is the
  single source of truth: PRIME DIRECTIVES + RESUME PROTOCOL + a checkboxed WORK QUEUE + Session Log +
  Morning Review. Every increment is committed+pushed, so any fresh session recovers full state from the
  plan + `git log` + `SUITE_TODO.md`. **This is what makes the run resilient to losing context/usage.**
- **L1 — self-resume daemon (`archive-suite-autonomous.sh`).** A loop that every ~90 s fires ONE fresh
  headless `claude -p` to advance the plan by one bounded item, then the session commits+pushes+stops. A
  usage-exhausted window just fails fast; the next cycle retries when the cap resets (~5h). Safety:
  `--permission-mode default` (**never** bypass), a scoped `--allowedTools` + a destructive
  `--disallowedTools` denylist, `--max-budget-usd`, a **health watchdog** that kills a wedged/runaway session
  early (see "Health watchdog" below) behind a 3 h wall-clock backstop, and a stale-lock guard so cycles never
  overlap. The script lives in `~/.local/bin` (outside the TCC-protected `~/Desktop`).
- **L2 — the resume prompt (`resume-prompt.txt`).** The exact instructions each fresh session follows
  (recover state → pick the first `[ ]` item → own worktree → verify → **checkpoint-commit+push as it goes** →
  finish+tick → stop). **Checkpointing bounds redo:** an interrupted session (usage cutoff / watchdog) loses
  only the work since its last push, and the next session **continues** from the committed checkpoints
  (detected via `git log` + the plan's Session Log) rather than restarting the whole item. Only the *final*
  commit flips the `SUITE_TODO` checkbox; interim checkpoints are plain mid-feature commits.

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
launchctl bootout gui/$(id -u)/com.archivesuite.autonomous      # stop the LaunchAgent (also auto at COMPLETE/park)
```
`./arm.sh status` shows a **run state** line — *productive* / *backing off (idle Ns)* / *PARKED* / *stopped* —
so a parked run is never mistaken for a crash. The daemon self-terminates when the plan's `RUN STATUS:` line
reads `COMPLETE`, **or** when it parks (see below).

## Idle backoff + auto-park (added 2026-07-16)

**The problem it fixes.** The loop used to fire every `INTERVAL` (90 s) unconditionally and only ever stop on
`RUN STATUS: COMPLETE` — which a session sets *only* after finishing the **last** `[ ]` item. So a run whose
queue was non-empty but every remaining item was **blocked** (owner-gated / GUI-gated / deliberately skipped)
had no terminal state and spun forever. Two real waste modes, both observed 2026-07-16:
- **A — usage window exhausted:** `claude` fast-fails `rc=1` in ~3 s → ~40 pointless spawns/hour for hours.
- **B — nothing actionable:** a *full* session (reads a ~250 KB plan + `SUITE_TODO` + `git log`, up to
  `--max-budget-usd`) burns real tokens to re-reach "nothing to do", every 90 s.

**The mechanism.** Any cycle that **advances nothing** doubles the gap (`INTERVAL` → `MAXBACKOFF`, default
30 min); any progress resets it to `INTERVAL`; `IDLE_STOP` (default 6 h) of *unbroken* no-progress **parks**
the run — a clean stop with a loud, owner-visible signal (`daemon.log` + `~/Desktop/ARCHIVE-SUITE-RUN-PARKED.txt`
+ a notification). Park deliberately leaves `RUN STATUS: IN_PROGRESS`, so a plain re-arm resumes with no edit.

**Progress is *derived*, never self-reported.** A cycle counts as progress iff a **work fingerprint** moved —
`sha256(git HEAD + plan '^RUN STATUS:' line + plan '## WORK QUEUE' section + the gui-mode file)`. The model
can't forget to set a flag, and a session that *believes* it worked can't lie past an unchanged fingerprint.
Exit code does **not** gate it: a session that ships a commit then gets killed (budget/watchdog) still moved
the fingerprint and resets the backoff; a usage fast-fail can't move it and falls through to no-progress.
- **Excluded on purpose:** the plan's `## Session Log` / `## Morning Review` / `## E2E findings`. A no-op
  session still appends its reasoning there, so hashing that churn would reset the backoff every cycle and
  silently restore the old spin. `SUITE_TODO.md` is tracked, so it rides in `git HEAD`.
- **Accelerator, not gate.** It is tempting to *skip* firing while the fingerprint is unchanged. That was
  **rejected on evidence:** on 2026-07-16 a 09:34 session concluded "nothing actionable", then at 10:40 —
  identical HEAD, queue, and gui-mode — a session found real work and shipped the code-signing fix
  (`496d202`). Sessions are **nondeterministic**, so "same inputs ⇒ same conclusion" is false; the fingerprint
  only *accelerates* retries (an unchanged one → keep backing off; a changed one → retry now, via an
  interruptible `backoff_sleep` that wakes early the instant the owner arms an item or flips gui-mode).
- **Idle clock shares the daemon's lifetime.** `idle.since` is cleared at every startup (and on park), so a
  stale stamp from a prior run can't make a fresh daemon park on cycle 1 — an owner re-arm always buys a full
  `IDLE_STOP` window. *(Confirmed-HIGH finding from the change's own adversarial review.)*

Knobs (env-overridable): `AUTONOMOUS_MAXBACKOFF`, `AUTONOMOUS_IDLE_STOP` (0 disables the auto-park). Built
Tier-2: proven by `ops/autonomous/tests/prove-daemon.sh` (below) + an adversarial review.

## Remote alerting + disk guard (added 2026-07-16 — WS6/WS2 of the 2-week hardening)

**Remote alerting (WS6).** Every "park + alert" path also POSTs to an endpoint you configure, because a
Desktop file + a local notification are useless to an owner who is away — exactly when an unattended run
needs them. Fires on: **park** (idle or low-disk) and the **taskport-still-open** security exit.

```bash
# ~/.local/state/archive-autonomous/alert.env   (zero-setup option: a private ntfy topic)
ALERT_URL="https://ntfy.sh/<your-long-random-topic>"
# ALERT_AUTH="Bearer <token>"      # optional; sent as an Authorization header
```
Unconfigured ⇒ silent no-op. Any webhook accepting a POST body works; `--max-time` bounds it so a dead
network can never hang the loop, and a failed alert is logged but never fatal.

> **Put it in `alert.env`, NOT `$STATE/env`** — load-bearing, not style. `$STATE/env` is the **child's**
> environment (the daemon re-sources it under `set -a` to hand `PATH`/`OCR_KEY` to `claude -p`), so anything
> there is inherited by **every session** — an LLM agent with `Bash`+`WebFetch` whose `curl`/`wget` deny-list
> exists precisely so it *cannot* phone out. `alert.env` is sourced once at startup **without** `set -a`, so
> the credential stays a non-exported, daemon-only shell var. A misplaced `ALERT_*` in `$STATE/env` is
> additionally stripped of its export attribute before the child spawns (defence in depth) — but alerts raised
> before the first session (e.g. a low-disk park) still wouldn't fire, so use `alert.env`.

**Disk guard (WS2).** A full disk fails *every* build, so an unguarded long run just burns sessions failing to
compile and never says why. Before launching, the daemon checks free space on `$REPO`'s volume; below
`AUTONOMOUS_MINFREE_MB` (default **10 GB**) it first runs housekeeping to reclaim (spent worktrees + their
`build/DD` are usually where the gigabytes went), re-checks, and only then **parks + alerts**. An unreadable
`df` reading **fails open** — a broken check must never stop a healthy run. The check sits *after* the
"another engine active" skip on purpose: housekeeping's safety argument assumes no session is live, and
`git worktree remove` does **not** refuse a worktree whose only content is gitignored (i.e. `build/DD`) —
so GCing a live engine's worktree mid-build is otherwise real.

## Regression suite — `ops/autonomous/tests/prove-daemon.sh`

Runs the **real** daemon against a stub `claude` in a sandboxed `HOME`/`STATE`/`REPO`, with every
host-touching command (`security`/`osascript`/`launchctl`/`caffeinate`/`curl`/`df`) stubbed — it cannot reach
your Desktop, the real repo, launchd, or the network. **41 assertions**: both idle waste modes, backoff
doubling + cap, progress-reset, queue-edit early-wake, the stale-`idle.since` cycle-1-park regression,
rc≠0-with-commit, the `COMPLETE` path, the disk guard (park / fail-open / self-heal / engine-busy
reentrancy), and alerting (no-op-when-unset, argv word-splitting, and that the alert credential never reaches
the session env). **Run it before installing ANY daemon change** — every `ops/autonomous/*` edit is Tier-2:

```bash
ops/autonomous/tests/prove-daemon.sh          # ~3 min, $0, no network
```

## Health watchdog (Layers 1+2) — added 2026-07-12

Each session runs with `--output-format stream-json --verbose --include-partial-messages`, so
`last-session.log` grows in real time with a JSON event per message/tool **and** per token-delta during
generation. Concurrent watchdogs monitor the `claude` pid; every kill routes through `_terminate_tree`
(snapshots the descendant set, TERMs the whole tree, then a detached KILL backstop 8 s later — so a runaway
build child is never orphaned):

- **Watchdog A — outer wall-clock backstop (`MAXRUN`, default 3 h).** Polls `kill -0 cpid` and self-exits when
  the session ends, so it never fires against a stale/reused pid if the daemon dies uncleanly. Last resort.
- **Watchdog C — health (the primary killer).** Two combined signals, so no single false-positive kills a
  healthy session:
  - **L1 event heartbeat:** the log's non-`rate_limit_event` bytes stop growing for `HB_STALL` (10 min) →
    "quiet". Token-delta streaming keeps a long effort=max generation growing the log, so it isn't mistaken for
    a hang; a rate-limit *wait* (only `rate_limit_event` lines) reads as quiet.
  - **L2 liveness:** when quiet, spare the session if an active `claude` **descendant** exists (a running
    subagent/Workflow child, whose work doesn't stream into the parent log) OR the tree is CPU-busy (a long
    build/test). An idle tree with no subagent for `HB_IDLE_N` (3) consecutive polls → **wedged** → kill; a
    CPU-busy tree with no subagent and no events for `HB_HARD` (40 min) → **runaway build/loop** → kill.
- **No separate usage-limit watchdog.** CLI 2.1.207 fast-fails an exhausted limit itself (rc=1 in ~2 s,
  observed), and a rate-limit wait is caught by L1. The old `"You've hit your limit"` grep was removed — it
  can't see stream-json's structured event and would false-kill a session that merely *reads* a file
  containing the phrase (this daemon being one).

Knobs (env-overridable): `AUTONOMOUS_HB_POLL` / `HB_STALL` / `HB_HARD` / `HB_CPU` / `HB_IDLE_N`, and
`AUTONOMOUS_MAXRUN`. **Accepted gap:** a CPU-busy *chatty* loop (log keeps growing) is bounded by
`--max-budget-usd` + `MAXRUN`, not the watchdog. This replaced the old pure 75-min wall-clock guillotine, which
killed healthy long sessions (Notes waves ran 30–78 min). Built Tier-2: a 10-case stub matrix
(`hung/healthy/busy-child/rate-limit-spin/subagent-alive/stale-pid-guard/clean-exit`) + two independent
adversarial reviews (kill-safety + detection-quality). **Requires CLI ≥ 2.1.207** (verified stream-json
flushes per-event to the log; earlier text mode buffered to the end).

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

- **Adversarial self-review before install/arm.** Ask the failure-mode questions explicitly. (The original
  idle-output watchdog false-killed healthy sessions because plain-text `claude -p` buffers output to the end —
  one question would have caught it: *"Does `claude -p` write to the log incrementally?"* It does **not** in
  text mode, which is exactly why the 2026-07-12 health watchdog switched to `--output-format stream-json`,
  whose events DO flush per-event. See "Health watchdog" above.)
- **Prove the mechanism, don't assume it.** Dry-run the changed logic (simulate the loop; confirm the daemon
  arms + finds its PLAN/STATE) before trusting it on a live run.
- **Parity for renames/moves:** re-grep for stragglers AND confirm the daemon still arms, finds its plan, and
  launches a session.
- Never install a daemon change straight onto a running run without the above.

## Housekeeping — automatic worktree/branch GC (added 2026-07-11)

Each session mints a `wt/<slug>-<stamp>` worktree + branch. Clean ones the session self-removes (resume
prompt STEP 5), but dirty/interrupted ones — and **all** the merged branch refs — used to pile up (91 stray
`wt/*` branches accrued before the first sweep). The daemon now GCs its own leftovers itself: `housekeeping()`
runs in the loop **between sessions**, with a deliberately **split scope** (because sessions don't reliably
follow the `wt/autonomous-$stamp` template — they improvise slugs like `wt/notes-w3s1-…`):

- **Phase 1 — worktree removal, narrow (`wt/autonomous*`):** removes a worktree whose branch is an **ancestor
  of `origin/main`** with a **plain `git worktree remove`, never `--force`**. Kept narrow so it can't reclaim
  a clean *interactive* worktree out from under you.
- **Phase 2 — branch deletion, broad (all merged `wt/*`):** deletes every `wt/*` branch that is an ancestor
  of `origin/main`, whatever the slug. Safe regardless of scope: `git branch -D` **refuses a branch checked
  out in any worktree** (an active worktree — yours, or the running session's — is protected), and the merged
  gate means `-D` drops nothing reachable. This is what actually kills the pile-up (branches were 91 of it).

**Why no `--force` (Tier-2 adversarial review, 2026-07-11).** A 3-lens review of the first draft (which *did*
use `--force`) found a **high-severity** hole: the `wt/autonomous*` glob also matches a *maintainer's* worktree
if they slug daemon-maintenance work `autonomous-…`, and `--force` would then delete their **uncommitted** work
(the ancestor gate is satisfied by any freshly-branched worktree). Same class of bug for a watchdog-killed
session's unpushed edits, and for a live build/bg grandchild still writing a merged worktree (`merged ≠ idle`).
Dropping `--force` makes git itself refuse any dirty/in-use worktree, so housekeeping is **structurally unable
to destroy unpushed or in-progress work** — it skips those and logs `left N merged-but-dirty/in-use
worktree(s) for manual review`. Proven on a 13-assertion scratch matrix (incl. a dirty `wt/autonomous-hkfix`
human worktree → kept, work intact). Purely local (no `git fetch`; the session's push already advanced the
shared `origin/main` ref) so it can't hang the loop; never touches the primary checkout.

- **Interactive coexistence:** Phase 1 only removes *worktrees* on a `wt/autonomous*` branch, so a worktree
  you slug anything else is never removed. Phase 2 may delete your merged `wt/*` *branch ref* once its worktree
  is gone (no data loss — it's on `origin/main`), but never while you have it checked out. Net: your active
  work is always safe; only fully-pushed leftovers get reclaimed.
- **Follow-up now resolved (2026-07-12):** the watchdogs previously killed only claude's pid, so a killed
  session could orphan a runaway build child. The health-watchdog change routes every kill through
  `_terminate_tree`, which TERM+KILLs claude's whole descendant tree (snapshotted up-front, with a detached
  KILL backstop). (The parent's `trap 'exit 0' TERM INT` still doesn't reap the backgrounded child on a TERM to
  the daemon itself — minor, and `arm.sh stop` covers it by pkill-matching the subshells.)
