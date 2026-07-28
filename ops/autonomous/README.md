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
with the exact fix if the plan is stale-`COMPLETE`, launches, and confirms the first cycle started. By
**default (2026-07-17)** it launches under **launchd KeepAlive** (crash-restart — see below), the right
posture for a long unattended run. `arm.sh nohup` is the opt-in detached mode; `arm.sh status` (read-only)
and `arm.sh stop` round it out. `./ops/autonomous/arm.sh --dry-run [nohup]` previews the resolved launch
mode without touching anything. The manual steps below are what it automates.

The committed copies here are the source of truth; install to the runtime location:

```bash
cp ops/autonomous/archive-suite-autonomous.sh ~/.local/bin/ && chmod +x ~/.local/bin/archive-suite-autonomous.sh
cp ops/autonomous/resume-prompt.txt ~/.local/state/archive-autonomous/
```

**Default — crash-restart under launchd (`./ops/autonomous/arm.sh`; WS1, default since 2026-07-17).** The
daemon runs under a launchd LaunchAgent with **`KeepAlive=true`**, so a **crash / OOM / stray kill
auto-restarts** it — motivated by a real 2026-07-17 death where the daemon was TERMed mid-session and nothing
brought it back. The model is simple: **the only thing that stops it is a `launchctl bootout`**, which every
intentional stop performs (`arm.sh stop`, park, plan-COMPLETE); any other death leaves the job registered, so
launchd relaunches (throttled to 60s). Proven on-machine by `tests/prove-keepalive.sh`; the dispatch (that
bare `arm` selects this) by `tests/prove-arm-dispatch.sh`.
- **Survives a daemon crash, NOT a logout/reboot** — a LaunchAgent only loads at GUI login (reboot-survival is
  deliberately out of scope; it'd need auto-login, defeated by FileVault anyway — see "don't reboot" below).
- May log `Operation not permitted` until `/bin/bash` has **Full Disk Access** (System Settings → Privacy).

**Opt-in — detached nohup (`./ops/autonomous/arm.sh nohup`).** macOS has **no `setsid`**, so a subshell +
`nohup` detaches the loop so it survives the launching command returning (equivalent to
`( nohup ~/.local/bin/archive-suite-autonomous.sh >…/nohup.out 2>&1 & )`). It runs while this login session is
alive and inherits its `~/Desktop`/screen (TCC) grant — so it is the better choice **when you need GUI-verify
(`arm.sh gui on`)**: the daemon inherits the launching terminal's Accessibility/Screen-Recording grant, which
a LaunchAgent may not. Downside: **no crash-restart** (a crash just stops it). If the launching terminal
closes, the daemon stops — fine by design: all state is durable in the plan + `git`, so a stop loses nothing
and the next `arm.sh` continues the queue. **We deliberately do NOT chase reboot/close durability.**

## Stop / status

```bash
tail -f ~/.local/state/archive-autonomous/daemon.log            # cadence + rc of each resume
tail -f ~/.local/state/archive-autonomous/last-session.log      # the most recent resume's transcript
./ops/autonomous/arm.sh stop                                    # STOP either mode (boots out the launchd job, THEN kills)
```
`arm.sh stop` is the right stopper in both modes: under `keepalive` a bare `pkill` would just be relaunched by
launchd, so `stop` boots out the job first. (`arm.sh status` shows the **supervisor**: launchd KeepAlive vs
nohup.)
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
30 min); any progress resets it to `INTERVAL`; `IDLE_STOP` (default **72 h**) of *unbroken* no-progress **parks**
the run — a clean stop with a loud, owner-visible signal (`daemon.log` + `~/Desktop/ARCHIVE-SUITE-RUN-PARKED.txt`
+ a notification). Park deliberately leaves `RUN STATUS: IN_PROGRESS`, so a plain re-arm resumes with no edit.
`IDLE_STOP` is **72 h** (not 6 h) so a long usage-cap outage doesn't self-park a healthy multi-day run: a
consecutive run of usage fast-fails all count as unbroken no-progress, and a *weekly* cap can exceed the
~5 h rolling window, so a 6 h idle clock would park a run that is merely *waiting for the window to reopen*.

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

**Attempt cap (WS4, 2026-07-17) — the one waste the backoff can't catch.** Backoff keys off the fingerprint
*moving*; a mis-sized or stuck item that commits a **checkpoint** each session keeps it moving, so it reads
as progress and loops for days burning budget. So a second guard counts **consecutive sessions that committed
work but completed no queue item**, and parks + alerts at `AUTONOMOUS_MAX_NOCOMPLETE` (default 6; 0 disables).
"An item completed" = the count of **top-level `[x]` checkbox items** in the plan's `## WORK QUEUE` went up
(prose mentions of `[x]` are excluded so a session can't fake a completion by writing about one); completing
any item resets the streak. The counter (`$STATE/nocomplete.count`) is cleared at startup alongside
`idle.since`, for the same reason (a re-arm must never park on cycle 1 off a stale count). The park message
lists the recent commits so you can see which item is stuck.

**Periodic health gate (WS7, 2026-07-17).** Per-change review catches per-change bugs; a *compounding*
regression can still hide across dozens of unreviewed commits. So every `AUTONOMOUS_GATE_EVERY` commits
(default 30) the daemon runs `ops/autonomous/health-gate.sh` and **parks + alerts on RED**. It's deterministic
(build/test), so the **daemon runs it directly** — no session, no LLM. Default checks are **free**: build all
three apps + Reader/Notes **unit** suites + a coherence check (clean tree); `AUTONOMOUS_GATE_OCR=1` adds the
paid Processor OCR smoke.
- **Unit tests via `-only-testing:<UnitBundle>`, not the whole scheme** — load-bearing: the schemes also hold
  UITest bundles, and running a UITest pops the macOS "Enable UI Automation" prompt, which would **hang the
  gate** (it runs synchronously in the daemon loop) and wake you. (`./test-smoke.sh reader|notes` run the full
  scheme, so the gate does *not* use them.)
- **Pixel-level "did it render" checks run in the gate too** — `DocumentRenderGuardTests` (`RenderProbe`) is a
  plain unit test inside `ArchiveReaderTests`: it renders a PDF page / view to a bitmap and asserts non-blank,
  with no "Enable UI Automation" prompt. So render regressions (blank PDF pane, blank thumbnail) are caught
  headlessly; only *interaction / whole-window* checks still need GUI-on. → `ops/gui/README.md`.
- **Opt-in GUI UITests in a headless VM (`AUTONOMOUS_GUI_VM=1`, OFF by default).** That last gap — real
  *interaction / whole-window* UITests — can now run in the gate WITHOUT a screen: `ops/autonomous/gui-vm-gate.sh`
  runs `ArchiveReaderUITests` inside the Tart VM (`ops/gui/README.md` §3), off the owner's display and with no
  "Enable UI Automation" host prompt. **Fail-open** (Tier-2 posture): a missing VM / boot failure / timeout
  **skips** (never parks); it REDs only on a *reproducible* UITest failure (keyed on the `** TEST FAILED **`
  marker, with its own retry-once). Leave it off until you've built the VM and run `gui-vm-gate.sh` once by hand;
  the VM's TCC grants live on its disk (re-apply if the VM is rebuilt).
- **Retry-once before parking** (`AUTONOMOUS_GATE_*`): a RED result is re-run once — a real regression is
  deterministic and fails again (→ park), but a flaky XCTest / transient `xcodebuild` blip passes the retry
  (→ green, no park). This is what keeps a routine flake from false-parking a multi-day run.
- **Wall-clock capped** (`AUTONOMOUS_GATE_MAXRUN`, 30 min): a hung gate is killed and **skipped** (fail-open) —
  a single hang is inconclusive, not a regression. But `AUTONOMOUS_GATE_MAX_TIMEOUTS` (2) consecutive hangs
  **escalate to a park + alert** (a persistent hang — a stuck prompt, or a cap below true build time — needs
  you), so a hang can't silently tax every cycle forever.
- The last-GREEN sha (`$STATE/last-gate`) **persists across restarts** (the cadence tracks code churn, not
  daemon lifetime); a missing/invalid sha fails **open** (gate due now).
- Owner prereq for the unit-test steps: `DevToolsSecurity -enable` (one-time; already enabled here) so
  `xcodebuild test` doesn't prompt for the debugger. Run `ops/autonomous/health-gate.sh` yourself once to
  confirm it's green + prompt-free before arming a long run.

**STATUS digest (WS5, 2026-07-17) — the check-in surface.** `ops/autonomous/status-digest.sh` prints a
one-screen summary — run state, PLAN status, HEAD + commits/24h, backlog (SUITE_TODO / WORK QUEUE / hold),
last health-gate, review coverage, disk, worktrees, and a **NEEDS YOU** section (park, taskport-still-open,
keychain-not-fixed, hold-queue items, Morning-Review head). The daemon rewrites `$STATE/STATUS.md` from it
every cycle + on park, and `arm.sh status` runs it. Read-only, non-fatal, degrades gracefully. Check in with:
`cat ~/.local/state/archive-autonomous/STATUS.md` (or `./ops/autonomous/status-digest.sh`).

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

## Keychain: stop the "security wants to use your keychain login" prompt (WS12, 2026-07-17)

The Tier-1 gate `ArchiveProcessor/test-smoke.sh` reads the Gemini OCR key with `security find-generic-password
-w` — so the requester is **/usr/bin/security**, not the app. The stable-signing fix
(`processor-keychain-stable-signing`) is about the *app's* code identity and does nothing for the CLI. And
clicking **"Always Allow"** never fixes it: that edits the item's legacy **ACL**, whereas a command-line
tool's prompt-free access is gated by the newer **partition list**. So `security` re-prompts on every
productive session and wakes you.

**Fix — run once (needs your login password, so it can't be in the daemon):**
```bash
./ops/autonomous/fix-keychain-access.sh    # adds apple:,apple-tool: to each key item's partition list
```
Then launch the app once (`./launch.sh processor`) and click **Always Allow** if *it* prompts, to confirm the
app still has access under the new partition list. **Re-run after rotating/re-adding any API key** (a
re-created item gets a fresh, empty partition list). `arm.sh status` shows whether the fix is applied.
(Owner chose this over env-key injection to keep keys in the Keychain — no plaintext key file.)

## Regression suite — `ops/autonomous/tests/prove-daemon.sh`

Runs the **real** daemon against a stub `claude` in a sandboxed `HOME`/`STATE`/`REPO`, with every
host-touching command (`security`/`osascript`/`launchctl`/`caffeinate`/`curl`/`df`) stubbed — it cannot reach
your Desktop, the real repo, launchd, or the network. **72 assertions**: both idle waste modes, backoff
doubling + cap, progress-reset, queue-edit early-wake, the stale-`idle.since` cycle-1-park regression,
rc≠0-with-commit, the `COMPLETE` path, the disk guard (park / fail-open / self-heal / engine-busy
reentrancy), alerting (no-op-when-unset, argv word-splitting, and that the alert credential never reaches the
session env), the WS4 attempt cap (park-at-cap / completion-reset / stale-count-cleared-at-startup), and the
WS7 health gate (green-records-non-terminal / reproducible-red-parks-after-a-retry / flaky-red-recovers /
single-hang-skips / persistent-hangs-escalate-to-park / not-due / bad-sha-fails-open — with a STUB gate; the
real `health-gate.sh` is proven by running it), and WS5 (the daemon writes STATUS.md each cycle + on park).
**Run it before installing ANY daemon change** — every `ops/autonomous/*` edit is Tier-2:

```bash
ops/autonomous/tests/prove-daemon.sh          # ~3 min, $0, no network — the daemon-loop logic (51 assertions)
ops/autonomous/tests/prove-keepalive.sh        # WS1 launchd half: a THROWAWAY LaunchAgent proves KeepAlive
                                               # restarts on kill-9 + bootout stays dead (can't run under the
                                               # bash-only harness). Run interactively; auto-cleans.
ops/autonomous/tests/prove-review-cadence.sh   # WS11 review picker: delta-aware unit choice, cooldown,
                                               # record-resets, never-reviewed coverage, iOS skipped ($0).
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

**Needs-owner HOLD QUEUE (WS10, 2026-07-17).** The daemon **never auto-executes** irreversible / highest-
blast-radius work: **Tier-3 releases** (DMG / `gh release` / version tags), **SPEC / `tag-format` changes**
(the cross-app data contract), anything that **writes the real corpus**, and any **HIGH review finding on an
irreversible path** (routed here by WS11). The resume prompt (STEP 2) skips the plan's `## HOLD QUEUE` /
`[hold]` / `needs: owner` items and surfaces them to Morning Review + `STATUS.md`. A defense-in-depth backstop
reinforces the soft rule: the daemon's `--disallowedTools` blocks the **direct** invocation of `hdiutil` and
`gh release` (the two release steps) — catching a casual/accidental attempt. It's not a hard boundary (a child
process like `bash release/build-suite-dmg.sh` could still reach `hdiutil`), so the prompt rule — *leave
release work for the owner* — is the primary control.

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
runs in the loop **between sessions**. Both phases cover **all `wt/*` slugs** — sessions don't reliably follow
the `wt/autonomous-$stamp` template (they improvise slugs like `wt/notes-w3s1-…`), so a namespace narrower than
`wt/*` would strand the improvised-slug worktrees' `build/DD` and let it pile up unbounded over a multi-day run:

- **Phase 1 — worktree removal (all `wt/*`):** removes a worktree whose branch is an **ancestor of
  `origin/main`** (provably pushed) with a **plain `git worktree remove`, never `--force`**. The two gates
  together mean a worktree is reclaimed only when it is **both fully pushed AND clean** — i.e. genuinely
  finished. Any in-progress worktree is skipped: an *unpushed* one fails the ancestor gate; a *dirty* one
  (uncommitted or untracked-non-ignored content) is refused by the plain remove.
- **Phase 2 — branch deletion (all merged `wt/*`):** deletes every `wt/*` branch that is an ancestor of
  `origin/main`, whatever the slug. `git branch -D` **refuses a branch checked out in any worktree** (an
  active worktree — yours, or the running session's — is protected), and the merged gate means `-D` drops
  nothing reachable. This is what actually killed the original pile-up (branches were 91 of it).

**Why widened to all `wt/*` (2026-07-20).** Phase 1 was originally narrowed to `wt/autonomous*` to avoid
reclaiming a clean *interactive* worktree out from under the owner. But the disk-guard self-heal calls this
same `housekeeping()`, so a scope narrower than the slugs sessions actually create couldn't reclaim what it
leaked — improvised-slug `build/DD` (≈1 GB each) accrued with no GC, the exact failure a multi-day run must
avoid. Widening is safe because the **merged gate + plain remove** (below) already guarantee only a
fully-pushed, fully-clean worktree is removed. The one behavioural cost: a *fully-pushed, fully-clean*
interactive worktree the owner kept around (e.g. just to rebuild in) can now be GC'd between sessions — but
that is **zero data loss** (its branch ref survives; `git worktree add` + rebuild restores it), only a
convenience they'd re-create. Regression-guarded by `ops/autonomous/tests/prove-housekeeping.sh` (runs the
real `housekeeping()` against a 7-case worktree matrix).

**Why no `--force` (Tier-2 adversarial review, 2026-07-11).** A 3-lens review of the first draft (which *did*
use `--force`) found a **high-severity** hole: `--force` would delete a matched worktree's **uncommitted** work
(the ancestor gate is satisfied by any freshly-branched worktree). Same class of bug for a watchdog-killed
session's unpushed edits, and for a live build/bg grandchild still writing a merged worktree (`merged ≠ idle`).
Dropping `--force` makes git itself refuse any dirty/in-use worktree, so housekeeping is **structurally unable
to destroy unpushed or in-progress work** — it skips those and logs `left N merged-but-dirty/in-use
worktree(s) for manual review`. Purely local (no `git fetch`; the session's push already advanced the
shared `origin/main` ref) so it can't hang the loop; never touches the primary checkout.

- **Interactive coexistence:** your in-progress work is always safe — a worktree with any uncommitted or
  untracked-non-ignored content, or with unpushed commits, is skipped by one of the two gates. Only a
  *fully-pushed, fully-clean* leftover worktree (any slug) is reclaimed; its branch ref then goes in Phase 2
  once the worktree is gone (no data loss — it's on `origin/main`), but never while it is checked out.
- **Follow-up now resolved (2026-07-12):** the watchdogs previously killed only claude's pid, so a killed
  session could orphan a runaway build child. The health-watchdog change routes every kill through
  `_terminate_tree`, which TERM+KILLs claude's whole descendant tree (snapshotted up-front, with a detached
  KILL backstop). (The parent's `trap 'exit 0' TERM INT` still doesn't reap the backgrounded child on a TERM to
  the daemon itself — minor, and `arm.sh stop` covers it by pkill-matching the subshells.)

## Plan compaction — keep the durable plan small (`compact-plan.sh`)

Every fresh session reads the whole plan to orient, so any section that grows unbounded silently inflates the
per-session startup cost. `compact-plan.sh` runs **between cycles** (lock released, no session active — it can
never race a session's append) and trims two growing sections back, archiving the overflow to recoverable
files (the plan is gitignored, so `.bak` + the archives are the recovery points, not git):

- **Pass 1 — `## Session Log`** (chronological, oldest-first): keep the last `KEEP=12` entries, archive older
  ones to `AUTONOMOUS_SESSION_LOG_ARCHIVE.md` (trigger: >40 entries).
- **Pass 2 — `## Morning Review`** (WS8, 2026-07-17; **newest-first** — each session prepends a `**[date]`
  entry at the top): keep the newest `MR_KEEP=15` entries inline, archive the older tail to
  `AUTONOMOUS_MORNING_REVIEW_ARCHIVE.md` (trigger: >25 entries). Halved a real 3,136-line plan to 1,473.

Both passes are **safe by construction**: region-bounded (never touch DIRECTIVES / RESUME / WORK QUEUE / RUN
STATUS), they build the result in a temp file and **validate every live anchor survives + the pre-region is
byte-identical before replacing**, keep a `.bak`, bail leaving the plan untouched on any anomaly, and are
idempotent (no-op under trigger). Pass 1 is wrapped in a subshell so its no-op `exit` can't skip Pass 2. Both
run *after* the work fingerprint is sampled and the Morning Review / Session Log sections are excluded from it,
so a rotation is **never** miscounted as the run advancing. Proven by `tests/prove-compact.sh`.

## Dependency gating — `(blocked-on: …)` (`next-queue-item.sh`, WS9)

Accumulating dependent work must run in ORDER. A WORK QUEUE item can name a prerequisite in its line:

```
- [ ] **W15.b — wire the pane** (blocked-on: W15.a) — needs the model type W15.a adds first.
- [ ] **W15.c — polish** (blocked-on: W15.a, W15.b) — after both.
```

`ops/autonomous/next-queue-item.sh` resolves this DETERMINISTICALLY (same philosophy as the idle-backoff
fingerprint — don't trust the model to grep): it prints each `[ ]` WORK QUEUE item in priority order as
`ok<TAB><tag><TAB>text` or `blocked:<unmet-tags><TAB><tag><TAB>text`, deciding each `(blocked-on: T…)` against
checkbox state across the plan **and** `SUITE_TODO.md`. A prerequisite `T` is satisfied iff some checkbox line
whose leading tag is `T` is `[x]` and none is `[ ]`; a **missing** `T` counts as unmet (blocked + visible), so
a typo can't cause an out-of-order run. Exit codes: `0` = ≥1 actionable item, `4` = items exist but ALL are
dependency-blocked, `3` = empty queue. Resume-prompt **STEP 2** runs it and picks the first `ok` item that
isn't also GUI-/hold-gated; when everything actionable is blocked the run simply parks (the idle backoff
handles a fully-blocked queue as a clean terminal state — no daemon change needed). A tag is an item's leading
token after its checkbox (`W15.a`, `W3.f1`, `W13.oai-1`); keep prerequisite tags distinctive. Proven by
`tests/prove-dep-gating.sh` (chains, satisfied/missing/circular prerequisites, multi-prereq, cross-tracker,
tag-parse).
