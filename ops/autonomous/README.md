# Autonomous autonomous run — the durable self-resume system

A reusable way to run **unattended, multi-hour maintenance** on this repo that survives usage cutoffs,
context compaction, and session restarts. Standing principles: memory `autonomous-plan-cron-resume`,
`autonomous-jobs-queue`, `no-force-override-destructive-git`; root `CLAUDE.md` §"How we work".

## ⚠️ The Daemon Report has two halves, and they are opposites

The `## Daemon Report` section of the plan (called **Morning Review** until 2026-08-05 — renamed because it
happens at any hour; the scripts still match both spellings) is **written by the daemon and spoken to the
owner.** Confusing the two halves is the single most repeated mistake against this system:

| | Who | What they do |
|---|---|---|
| **Write half** | An unattended session that hits something needing a human | **Appends** an entry and moves on. Never waits. |
| **Read half** | An interactive session, when the owner **asks** for the report | **Walks him through each open decision, one at a time, waiting for each answer.** Writes nothing. |

The read half is specified in root [`CLAUDE.md`](../../CLAUDE.md) → *"THE DAEMON REPORT IS A WALKTHROUGH,
NOT A DOCUMENT"*. If you are about to answer a request for the report by writing a plan entry or by posting
a tidy summary of everything that happened, **you are doing the write half at the wrong moment** — stop and
read that section.

## The three layers

- **L0 — durable plan (the foundation).** `.maintenance/AUTONOMOUS_PLAN.md` (gitignored, on-disk) is the
  single source of truth: PRIME DIRECTIVES + RESUME PROTOCOL + a checkboxed WORK QUEUE + Session Log +
  Daemon Report. Every increment is committed+pushed, so any fresh session recovers full state from the
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

> **Renamed 2026-08-06 (owner):** this script was `arm.sh` and its verb was `arm`; it is now
> **`daemon.sh`** with **`start`**. A bare `./ops/autonomous/daemon.sh` still means `start`, but the old
> `arm` verb is rejected rather than silently aliased — two spellings for one command is how docs drift.

**One command (preferred): `./ops/autonomous/daemon.sh start`** — checks every prerequisite (claude CLI outside
`~/Desktop`, daemon + resume prompt present, an L0 plan whose `RUN STATUS` is `IN_PROGRESS` with unchecked
`[ ]` items), installs the latest committed copies to the runtime location, refuses to double-launch, warns
with the exact fix if the plan is stale-`COMPLETE`, launches, and confirms the first cycle started. By
**default (2026-07-17)** it launches under **launchd KeepAlive** (crash-restart — see below), the right
posture for a long unattended run. `daemon.sh nohup` is the opt-in detached mode; `daemon.sh status` (read-only)
and `daemon.sh stop` round it out. `./ops/autonomous/daemon.sh --dry-run [nohup]` previews the resolved launch
mode without touching anything. The manual steps below are what it automates.

The committed copies here are the source of truth; install to the runtime location:

```bash
REPO="$(pwd)"     # this checkout — the daemon and the prompt both need it as a literal path
cp ops/autonomous/archive-suite-autonomous.sh ~/.local/bin/ && chmod +x ~/.local/bin/archive-suite-autonomous.sh
# The committed prompt carries a __REPO__ placeholder instead of one machine's absolute path, so it is
# RENDERED rather than copied. `daemon.sh` does this for you; by hand it is a sed.
sed "s|__REPO__|$REPO|g" ops/autonomous/resume-prompt.txt > ~/.local/state/archive-autonomous/resume-prompt.txt
```

Running the daemon by hand needs `AUTONOMOUS_REPO` set too — it is installed outside any checkout, so it
cannot find the repo itself and **refuses to start** rather than guessing:
`AUTONOMOUS_REPO="$REPO" ~/.local/bin/archive-suite-autonomous.sh`. Under launchd, `daemon.sh` renders it
into the plist's `EnvironmentVariables`.

**Default — crash-restart under launchd (`./ops/autonomous/daemon.sh start`; WS1, default since 2026-07-17).** The
daemon runs under a launchd LaunchAgent with **`KeepAlive=true`**, so a **crash / OOM / stray kill
auto-restarts** it — motivated by a real 2026-07-17 death where the daemon was TERMed mid-session and nothing
brought it back. The model is simple: **the only thing that stops it is a `launchctl bootout`**, which every
intentional stop performs (`daemon.sh stop`, park, plan-COMPLETE); any other death leaves the job registered, so
launchd relaunches (throttled to 60s). Proven on-machine by `tests/prove-keepalive.sh`; the dispatch (that
bare `arm` selects this) by `tests/prove-daemon-dispatch.sh`.
- **Survives a daemon crash — and, while the job is installed, a logout/reboot too.** ⚠️ This bullet said the
  opposite until 2026-08-16 (`W32.plist-relogin`), and the inference was backwards: "a LaunchAgent only loads
  at GUI login" is exactly *why* it comes back — it loads at the NEXT login. `launchctl bootout` unloads the
  job from the current `gui/$UID` domain and writes no persistent disable, so with the plist still in
  `~/Library/LaunchAgents` (`RunAtLoad=true`) the daemon restarted itself at the next login. Observed:
  hard power-off 2026-08-05 15:25 (no `daemon down` line), boot 21:56:53, `daemon up (pid 1701)` 22:00:20,
  no human involved. **`stop`, a park and a plan-COMPLETE now delete the plist**, so an intentional stop
  outlives the login session and starting the daemon stays the owner's decision alone. `start` reinstalls it.
- May log `Operation not permitted` until `/bin/bash` has **Full Disk Access** (System Settings → Privacy).

**Opt-in — detached nohup (`./ops/autonomous/daemon.sh nohup`).** macOS has **no `setsid`**, so a subshell +
`nohup` detaches the loop so it survives the launching command returning (equivalent to
`( nohup ~/.local/bin/archive-suite-autonomous.sh >…/nohup.out 2>&1 & )`). It runs while this login session is
alive and inherits its `~/Desktop`/screen (TCC) grant. (That host-screen grant used to matter for GUI-verify;
it no longer does — GUI runs off-screen in the Tart VM regardless of supervisor, `ops/gui/README.md` §3.)
Downside: **no crash-restart** (a crash just stops it). If the launching terminal
closes, the daemon stops — fine by design: all state is durable in the plan + `git`, so a stop loses nothing
and the next `daemon.sh start` continues the queue. **We deliberately do NOT chase reboot/close durability.**

## Stop / status

```bash
tail -f ~/.local/state/archive-autonomous/daemon.log            # cadence + rc of each resume
tail -f ~/.local/state/archive-autonomous/last-session.log      # the most recent resume's transcript
./ops/autonomous/daemon.sh stop                                    # STOP either mode (boots out the launchd job, THEN kills)
```
`daemon.sh stop` is the right stopper in both modes: under `keepalive` a bare `pkill` would just be relaunched by
launchd, so `stop` boots out the job first. (`daemon.sh status --details` shows which mode is in force, under
*restart on crash*.)
`./daemon.sh status` opens with a plain-language **state line** — *Working now* / *Working on W…* / *Paused — it hit the usage cap*
/ *Waiting to retry — runnable work remains* / *Running, but no eligible work is queued* / *Stopped itself* / *Set to run, but not running right now* /
*Not running* — so a parked run is never mistaken for a crash, and a throttled one is never mistaken for an
empty queue. The daemon self-terminates when the plan's `RUN STATUS:` line
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
+ a notification). Park deliberately leaves `RUN STATUS: IN_PROGRESS`, so a plain restart resumes with no edit.
`IDLE_STOP` is **72 h** (not 6 h) so a long usage-cap outage doesn't self-park a healthy multi-day run: a
consecutive run of usage fast-fails all count as unbroken no-progress, and a *weekly* cap can exceed the
~5 h rolling window, so a 6 h idle clock would park a run that is merely *waiting for the window to reopen*.

**Progress is *derived*, never self-reported.** A cycle counts as progress iff a **work fingerprint** moved —
`sha256(git HEAD + plan '^RUN STATUS:' line + plan '## WORK QUEUE' section)`. The model
can't forget to set a flag, and a session that *believes* it worked can't lie past an unchanged fingerprint.
Exit code does **not** gate it: a session that ships a commit then gets killed (budget/watchdog) still moved
the fingerprint and resets the backoff; a usage fast-fail can't move it and falls through to no-progress.
- **Excluded on purpose:** the plan's `## Session Log` / `## Daemon Report` / `## E2E findings`. A no-op
  session still appends its reasoning there, so hashing that churn would reset the backoff every cycle and
  silently restore the old spin. `SUITE_TODO.md` is tracked, so it rides in `git HEAD`.
- **Accelerator, not gate.** It is tempting to *skip* firing while the fingerprint is unchanged. That was
  **rejected on evidence:** on 2026-07-16 a 09:34 session concluded "nothing actionable", then at 10:40 —
  identical HEAD and queue — a session found real work and shipped the code-signing fix
  (`496d202`). Sessions are **nondeterministic**, so "same inputs ⇒ same conclusion" is false; the fingerprint
  only *accelerates* retries (an unchanged one → keep backing off; a changed one → retry now, via an
  interruptible `backoff_sleep` that wakes early the instant the owner arms an item).
- **Idle clock shares the daemon's lifetime.** `idle.since` is cleared at every startup (and on park), so a
  stale stamp from a prior run can't make a fresh daemon park on cycle 1 — an owner restart always buys a full
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
`idle.since`, for the same reason (a restart must never park on cycle 1 off a stale count). The park message
lists the recent commits so you can see which item is stuck.

**Periodic health gate (WS7, 2026-07-17).** Per-change review catches per-change bugs; a *compounding*
regression can still hide across dozens of unreviewed commits. So every `AUTONOMOUS_GATE_EVERY` commits
(default 30) the daemon runs `ops/autonomous/health-gate.sh` and **parks + alerts on a CODE RED — but
SELF-REPAIRS a DOCUMENT-only RED** (2026-08-10, owner: *"We don't want it to park when it hits the budget cap.
We want it to fix itself"*). A document RED (`context-budget`/`tracker-sync`/`coherence`) means a file grew, not
that anything broke, and the daemon already runs the compactor every cycle — so on a doc-only RED it runs
`compact-plan.sh`, re-runs the gate once, and parks **only if it is still red** (the park note then says repair
was already attempted, so you are not sent to hand-run a tool the daemon just ran). ⛔ A **code** RED, or any
**mixed** RED, is never self-repaired — that is exactly what parking is for. `AUTONOMOUS_GATE_SELFHEAL=0` disables it.

**⚠️ That self-repair only ever covered ONE of the nine budgeted documents — fixed 2026-08-12 by the DOC
PRE-GATE (WS13).** Its precondition was *"a compactor exists"*, not *"the compactor owns the failing file"*, and
`compact-plan.sh` rewrites `.maintenance/AUTONOMOUS_PLAN.md` and nothing else. So for the other eight documents
the sequence was fixed in advance: run a compactor that cannot touch the file → re-gate → still RED → park. It
fired twice for real — 2026-08-06 (`execution-plans/despotlight.md` at 110%) and **2026-08-12 01:25** (the
umbrella `CLAUDE.md`, 1,682 B over) — and the second burned **61 minutes across three full build+test gate
runs**, VM UITest lane included, to rediscover a `wc -c` result. `doc_pregate()` now runs the pure-shell budget
check **before the gate is ever launched** (milliseconds) and dispatches on the FILE:

| over-budget document | remedy | cost |
|---|---|---|
| `.maintenance/AUTONOMOUS_PLAN.md` | `compact-plan.sh`, in-cycle | free, no session, genuinely self-healing |
| anything else (prose guides, `SUITE_TODO.md`, an execution plan, this prompt) | hand it to the next **session** as its one bounded item, via `$STATE/doc-budget-fix` (STEP 1.5 of `resume-prompt.txt`) | one session; **no park** |

It writes that request file rather than appending to the WORK QUEUE deliberately: queue entries are compared
against `SUITE_TODO.md` by `check-tracker-sync.sh` on every gate, so auto-appending one would manufacture the
exact drift that guard exists to catch. When a document is over, the gate is **deferred** for that cycle (it
would RED on the very file being fixed, and the older self-heal above would then park for it); the cadence is
commit-based, so the gate is still due next cycle. **Park is still the backstop, just not the first move:**
after `AUTONOMOUS_DOCFIX_MAX` (default 3) attempts fail to bring the docs under, it parks with a
note saying both remedies were already tried — which, after three sessions, usually means the *budget* is wrong
rather than the document. **An attempt is counted by HEAD MOVING, not per cycle** (owner, 2026-08-12: *"this is
a laptop and I'm moving around throughout the day opening and closing the machine"*). A lid close kills the
in-flight session; counting cycles would let three such interruptions park the run over a trim no session ever
got a fair run at — the false-park class `GATE_MAX_TIMEOUTS` and `MAX_NOCOMPLETE` are both shaped to avoid. A
session that commits nothing costs nothing; and if HEAD never moves there is no new code to gate either, so
deferring the gate indefinitely is harmless. A `NEAR` file (≥`ACT_PCT`, default 93%) gets the same trim **pre-emptively**, so the
OVER state is not reached at all. `AUTONOMOUS_DOC_PREGATE=0` disables the whole layer.
Contract proof: `tests/prove-context-budget.sh` (a gate step) + `tests/prove-daemon.sh` §28a–g.

The gate is deterministic (build/test), so the **daemon runs it directly** — no session, no LLM. Default checks are **free**: build all
three apps + a headless Processor launch of that just-built artifact + Reader/Notes **unit** suites + the
write-surface lint and hermetic script gates + a coherence check (clean tree);
`AUTONOMOUS_GATE_OCR=1` adds the paid Processor OCR smoke. The Processor launch runs the synthetic recovery
driver with no key, network, OCR, or GUI; it is specifically what catches an app that builds but aborts before
`main`, and it never reuses a stale `build/DD` binary.
- **Unit tests via `-only-testing:<UnitBundle>`, not the whole scheme** — load-bearing: the schemes also hold
  UITest bundles, and running a UITest pops the macOS "Enable UI Automation" prompt, which would **hang the
  gate** (it runs synchronously in the daemon loop) and wake you. (`./test-smoke.sh reader|notes` run the full
  scheme, so the gate does *not* use them.)
- **Pixel-level "did it render" checks run in the gate too** — `DocumentRenderGuardTests` (`RenderProbe`) is a
  plain unit test inside `ArchiveReaderTests`: it renders a PDF page / view to a bitmap and asserts non-blank,
  with no "Enable UI Automation" prompt. So render regressions (blank PDF pane, blank thumbnail) are caught
  headlessly; only *interaction / whole-window* checks still need GUI-on. → `ops/gui/README.md`.
- **Five Tier-2 script gates that nothing was running** (`W26.lint-fu`, 2026-08-07). Wave 26 shipped a
  harness for each of its guarantees and wired **none** of them to a caller — the write-surface lint's own
  header even claimed "also invoked by the autonomous build", measured false on 2026-08-05. A guarantee that
  reads as enforced and isn't is the vacuous-pass failure one level up, so all five run here now:
  `write-surface-lint` + `write-surface-lint-proof` (the Core Directive's automated half, and the proof it
  can still fail), `tag-vocabulary` (the Processor's tag-write hook + `$HOME`-walk prohibition),
  `finder-tags` (the E2E oracle reads xattrs, not Spotlight) and `fixture-scripts` (the Reader fixture
  builders need no Spotlight, plus the `rm -rf` guard on their new destination overrides). Together ~105 s,
  no key/network/GUI/app build, `mktemp` scratch only, and placed **before** the ~15–20 min VM lane so a RED
  surfaces early. All five were run green on a clean tree before wiring — a gate must not start RED.
  - `fixture-scripts` is the one **skippable** member: it needs `/opt/homebrew/bin/tag` and the
    **gitignored** `Test files/Brown Gemini` corpus, which exists only in the checkout the owner put it in.
    It exits **3 + `SKIPPED:`** for a missing prerequisite (never for a failed check), so a machine without
    them gets `⊘ … NOT VERIFIED: fixture-scripts` rather than a false park. Same contract as `gui-vm`.
- **GUI UITests in a headless VM (`AUTONOMOUS_GUI_VM`, ON by default since 2026-07-28; `=0` to disable).** That
  last gap — real *interaction / whole-window* UITests — now runs in the gate WITHOUT a screen:
  `ops/autonomous/gui-vm-gate.sh` runs **every app's** UITest bundle inside the Tart VM (`ops/gui/README.md` §3)
  — Reader and Notes since 2026-07-30 (`AUTONOMOUS_GUI_VM_APPS` selects a subset) — off the owner's display and
  with no "Enable UI Automation" host prompt. **Fail-open** (Tier-2 posture): a missing VM / boot failure /
  guest-agent timeout **skips** (never parks — so it's inert on a machine with no VM built); it REDs only on a
  *reproducible* UITest failure (keyed on the `** TEST FAILED **` marker, with its own retry-once). It adds
  ~15–20 min (VM boot + build + UITests), which is why `GATE_MAXRUN` is now **50 min** (below) — at 30 a slow
  cold run could blow the cap and false-park. The VM's TCC grants live on its disk (re-apply if it is rebuilt).
  - **Skip ≠ pass** (fixed 2026-07-30 after the gate reported a GREEN GUI lane that had run zero tests): the
    script exits **3 for SKIPPED**, distinct from 0/1, and `health-gate.sh` runs it through `step_skippable`,
    which prints `⊘ gui-vm SKIPPED — <reason>` and appends `— but NOT VERIFIED: gui-vm` to the summary line.
    A gate that claims coverage it doesn't have is worse than no gate; don't collapse this back to two states.
  - **The guest-agent wait is load-bearing.** `tart ip --wait` returns on *networking*, but `tart exec` needs
    the Tart Guest Agent's vsock socket, which comes up later — exec'ing immediately failed every command in
    the run (that was the zero-test "green"). The gate polls `tart exec true` until it answers
    (`AUTONOMOUS_GUI_VM_AGENTWAIT`, 240s).
  - **The guest's display is raised too** (`tart_ensure_display`, default 1920×1200). `--no-graphics` attaches
    no display, so the guest boots at **1024×768** whatever the VM's configured `Display` says — too small for
    the Notes browser, whose window then clipped ~92 pt off each side and failed 4 UITests as "not hittable"
    (W21.vmgui-c). A failure to raise it WARNs with the consequence named; it never parks the run.
  - **Warn tier** (`AUTONOMOUS_GUI_VM_WARN_APPS`) — **empty by default since 2026-08-01**: Reader is 15/15 and
    Notes 12/12 in the VM, so a UITest failure in either REDs the gate. The tier exists for an app with
    *tracked* known-failing UITests: it still RUNS and reports every gate but WARNs instead of REDding, buying
    visibility without parking a multi-day run. Empty it again as soon as that suite is green — a permanent
    warn tier is a disabled test.
  - **Per-attempt result bundles + logs.** `xcodebuild` refuses to overwrite an existing `-resultBundlePath`,
    so a fixed path made every *retry* fail before running a test — laundering a real RED into a skip. Each
    attempt gets its own bundle and its own `gui-vm-<app>-attempt<n>.log`, so the retry can't destroy attempt
    1's evidence either. Both were found by running the gate for real on 2026-07-30.
- **The host screen is off-limits to a session, mechanically.** The daemon exports `ARCHIVE_UNATTENDED=1`, and
  `.claude/hooks/no-host-gui.sh` (PreToolUse/Bash) hard-DENIES host UITest runs, `launch.sh`/`gui-drive*`/
  `capture-window.sh`/`cliclick`/`osascript`, a windowed Android emulator, and the iOS Simulator — each denial
  naming the VM route instead. Interactive owner sessions are unaffected. Regression harness:
  `ops/autonomous/tests/prove-no-host-gui.sh`.
  **A hook matches the command STRING, so a wrapper script defeats it** — proven on 2026-07-30 when a
  session ran `./ArchiveNotes/test-smoke.sh`, whose own whole-scheme `xcodebuild test` drove
  ArchiveNotesUITests on the owner's display while the hook saw a string with no `xcodebuild` in it. Two
  layers behind it now: (a) both `test-smoke.sh` scripts run **only the unit bundle** when
  `ARCHIVE_UNATTENDED=1`, pointing at the VM for the UITests — the documented command is now *correct*, not
  merely blocked; (b) **`ops/autonomous/bin/` — one PATH shim per screen-reaching binary** (`xcodebuild`,
  `open`, `osascript`, `cliclick`, `emulator`, all symlinks to `_gui-shim`), prepended for the child, so the
  exec is caught no matter how many scripts deep it happens. Shimming `xcodebuild` alone was the first cut
  and left the same hole for every other mechanism — the Processor's smoke test reaches the screen with
  `open` + `osascript`, not xcodebuild.
  Two more places this had to generalize: the **health gate** runs in the daemon LOOP, where no PreToolUse
  hook applies and the session's env is out of scope, so it now exports `ARCHIVE_UNATTENDED=1` itself
  (without which `AUTONOMOUS_GATE_OCR=1` opens the Processor on the owner's screen); and the **Processor
  smoke** skips its host launch step when unattended, as Reader's and Notes' already do.
  Covered by `ops/autonomous/tests/prove-vm-lane.sh`, which also carries a FORWARD tripwire: any app whose
  `project.yml` declares an app-hosted unit-test bundle must adopt `ArchiveTestHost` and ship
  `TestHostWindowSuppressionTests`. Window suppression is per-app opt-in, so that assertion is what makes it
  cover the Processor the day it gains a test target (W21.vmgui-d). The other half of that guarantee is in the apps themselves: the
  unit bundles are app-hosted, so `xcodebuild test -only-testing:<App>Tests` launches the real `.app` — it now
  draws nothing under a test host (ArchiveCore `ArchiveTestHost` + `TestHostWindowSuppressionTests`).
- **Retry-once before parking** (`AUTONOMOUS_GATE_*`): a RED result is re-run once — a real regression is
  deterministic and fails again (→ park), but a flaky XCTest / transient `xcodebuild` blip passes the retry
  (→ green, no park). This is what keeps a routine flake from false-parking a multi-day run.
- **Wall-clock capped** (`AUTONOMOUS_GATE_MAXRUN`, 50 min — raised from 30 to absorb the on-by-default GUI-VM
  step; set back to 1800 with `AUTONOMOUS_GUI_VM=0`): a hung gate is killed and **skipped** (fail-open) —
  a single hang is inconclusive, not a regression. But `AUTONOMOUS_GATE_MAX_TIMEOUTS` (2) consecutive hangs
  **escalate to a park + alert** (a persistent hang — a stuck prompt, or a cap below true build time — needs
  you), so a hang can't silently tax every cycle forever.
- The last-GREEN sha (`$STATE/last-gate`) **persists across restarts** (the cadence tracks code churn, not
  daemon lifetime); a missing/invalid sha fails **open** (gate due now).
- Owner prereq for the unit-test steps: `DevToolsSecurity -enable` (one-time; already enabled here) so
  `xcodebuild test` doesn't prompt for the debugger. Run `ops/autonomous/health-gate.sh` yourself once to
  confirm it's green + prompt-free before arming a long run.

**STATUS — the check-in surface (rewritten 2026-07-31 for readability).** `status-digest.sh` is **the one
status renderer**; `daemon.sh status` is a thin forwarder that adds no formatting of its own. The default view is
written for the owner at a glance, not for an engineer reading logs, and answers only five questions:

> **is it running? · what has it done? · how much is left? · is the code healthy? · does it need me?**

```
Archive Suite — overnight worker   Fri 31 Jul, 09:03

  ○  Not running
     Nothing is working on the project right now. Start it: ./ops/autonomous/daemon.sh start

  Done       69 changes in the last 24 hours · latest 15 minutes ago
             "feat(ops): daemon runs at effort=xhigh, and each session now…"
  Left       51 tasks to do · 152 finished
  Health     Build and tests passed, 13 changes ago

  Needs you  Nothing right now.
```

The state line is the point of the whole thing, because each state implies a **different owner action**, and
two of them were historically reported as each other:
*Working now* · *Working on W…* · *Paused — it hit the usage cap* (wait; it retries itself) · *Waiting to retry —
runnable work remains* (wait; the last daemon-log verdict says why) · *Running, but no eligible work is queued*
(unblock it) · *Stopped itself* = parked (decide something) · *Set to run, but not running right
now* (crash-looping) · *Not running*.

`daemon.sh status --details` adds the diagnostics that used to clutter the default view — current commit, plan
line, restart-on-crash mode, disk, spare worktrees, keychain state, GUI lane, whether paced reviews are on,
and the last log lines. Nothing was deleted, only demoted; anything genuinely *wrong* still surfaces under
**Needs you** with no flag.

When a live unattended session has a checkpoint ahead of the primary checkout in its separate worktree, the state line names that
work item and the checkpoint age instead of letting a stale `idle.since` stamp call it idle. This deliberately
does **not** use `engine.lock`: its mtime is a heartbeat lease, not a task duration. Before status attributes a
pause to the HOLD QUEUE, it also asks `next-queue-item.sh`; any runnable item suppresses that unrelated owner
ask and the state instead preserves the daemon log's backoff reason.

Before this rewrite, `daemon.sh status` printed six sections of its own and *then* pasted the digest underneath,
so the run state and plan line each appeared twice in two different wordings — and the `GUI` and `keychain`
sections were fixed text that had stopped telling anyone anything. One renderer, one wording.

The daemon rewrites `$STATE/STATUS.md` from the same renderer every cycle + on park (colour is suppressed off
a terminal, so the file stays clean text). Read-only, non-fatal, degrades gracefully — it exits 0 and still
prints a report with no repo, plan or state at all, because it is what you run when something is already
broken. Covered by `ops/autonomous/tests/prove-status.sh` (47 checks: every state, the jargon budget, and the
no-ANSI-in-a-file rule). Check in with:
`cat ~/.local/state/archive-autonomous/STATUS.md` (or `./ops/autonomous/daemon.sh status`).

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
Then launch the app once (`./launch.sh processor`) and click **Always Allow** for each provider item it prompts
for; Settings reads credentials eagerly, so a fully unseeded machine can show about six prompts. This confirms
the app still has access under the new partition list. **Re-run after rotating/re-adding any API key** (a
re-created item gets a fresh, empty partition list). `daemon.sh status --details` shows whether the fix is
applied, and if it is *not*, the default view says so under **Needs you** without the flag. Before a start,
`daemon.sh` also warns if a provider key exists but was added after the marker's recorded account list.
(Owner chose this over env-key injection to keep keys in the Keychain — no plaintext key file.)

## Reading `daemon.log` when the run is down (exit reasons, added 2026-07-29)

Every **trappable** exit now logs one line saying why, so an ordinary shutdown is distinguishable from a
crash at a glance:

```
=== daemon down (pid N) — reason: … | status=0 | uptime=1234s | session-in-flight=YES (engine.lock present …) ===
```

| what you see | what it means |
|---|---|
| `reason: SIGTERM — launchd bootout/stop, logout, shutdown, or the laptop lid closing` | An orderly system stop. **This is the normal case on a personal laptop** — closing the lid ends the login session and launchd TERMs the job. Not a defect. Just `./ops/autonomous/daemon.sh` again. |
| `reason: fell out of the main loop (rc 9 …)` | The daemon's own decision: `RUN STATUS: COMPLETE`, or it parked (idle past `IDLE_STOP`, attempt cap, disk guard, or a reproducible RED health gate — which is **not necessarily a code regression**: the gate's `context-budget` step REDs when an orientation DOCUMENT is over its size budget while every build and suite is green, and the park note now names the failing step and says which kind it is). Check for `~/Desktop/ARCHIVE-SUITE-RUN-PARKED.txt`. |
| `reason: SIGINT` / `SIGHUP` | Ctrl-C, or the controlling terminal/login session went away. |
| a `daemon up` line with **no** matching `daemon down` | A **hard kill** — SIGKILL, OOM, or power loss. These cannot be trapped, so the *absence* of a line is itself the signature. On this laptop that is almost always the lid closing or the battery dying, not a bug. |

`session-in-flight=YES` means a resume session was running when the daemon went down, so
`$STATE/engine.lock` is probably stale; the next daemon takes it over after `AUTONOMOUS_STALE` (25 min), or
you can delete the lock to skip the wait. Proven by `ops/autonomous/tests/prove-exit-logging.sh` (12
assertions, incl. that a SIGKILL logs nothing and that the WS6 taskport security reminder still fires from
the EXIT trap).

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
ops/autonomous/tests/prove-vm-lane.sh          # the VM lane: per-app table, VM lock, corpus resolution, the
                                               # exit-code -> owner-text mapping (the silent-green regression,
                                               # twice), the xcodebuild PATH shim, smoke-script self-guards.
ops/autonomous/tests/prove-no-host-gui.sh      # the host-GUI firewall (.claude/hooks/no-host-gui.sh): all four
                                               # blocked lanes deny, their legitimate neighbours (VM lane,
                                               # unit-only tests, `emulator -no-window`, read-only simctl) still
                                               # allow, and an INTERACTIVE session keeps full host GUI ($0, <1s).
ops/autonomous/tests/prove-tracker-sync.sh     # the tracker-sync guard: drift is loud (both directions, the
                                               # real W21.vmgui-path shape) and legitimate asymmetry is silent
                                               # (one-file-only items, HOLD QUEUE, fences, quotes) ($0, <1s).
ops/autonomous/tests/prove-todo-stubs.sh       # the ticked-stub lint: a COLUMN-0 `[x]` in SUITE_TODO is loud
                                               # (with the double-count distinction), an INDENTED ticked
                                               # sub-step and fenced/quoted examples stay silent ($0, <1s).
```

### Which of these actually run, and the assertion that keeps it that way (W26.fixwarn-fu1, 2026-08-10)

**15 of the 17 `tests/prove-*.sh` harnesses are `health-gate.sh` steps**, so they run on every gate rather
than when someone remembers. That took five hand-sweeps, and each one found the previous had missed some:
`f64649b` wired four, `W26.fixwarn` a fifth, and counting them to justify the word "fifth" turned up **seven**
more that nothing ran — `prove-compact.sh` had been RED *and* unwatched for weeks, `prove-status.sh` sat at
34/2. Three of the seven even had a reference that a `grep -l` would have scored as wired, and all three were
prose. **An unrun test is worse than no test:** it reads as coverage in review and asserts nothing at runtime.

**Two are deliberately NOT gate steps**, named on health-gate.sh's machine-read `# GATE-UNWATCHED-BY-DESIGN:`
line with the reasons in the prose above it:
- `prove-daemon.sh` — **runtime.** ~10 min of real daemon loops, in a gate that already runs ~22 min against
  `GATE_MAXRUN=50 min`. Run it by hand for daemon-behaviour changes.
- `prove-keepalive.sh` — **side effects outside its own sandbox.** It is fast (7 s) and green, so runtime is
  not the objection: it drives real launchd, so its verdict depends on state outside its sandbox (the exact
  way `prove-status.sh` sat at 34/2 — it was reading the owner's real `~/Desktop` park note), and its cleanup
  is an `EXIT` trap while the watchdog backstop is a detached `kill -KILL`, so a killed gate would leave a
  `KeepAlive=true` job loaded in `gui/$UID` relaunching itself forever, one `$$`-unique phantom per killed run.

**`prove-gate-report.sh` asserts the property** (§5): every `tests/prove-*.sh` is either invoked by a
`step`/`step_skippable` in `health-gate.sh` **or** named on that line — and the list may not lie, so an entry
that is stale, or that is in fact wired, REDs too. A comment mentioning a harness does not count as wiring.
It lives there because it must live in a step that is *independently* wired: an assertion inside the harness
it is asserting about stops running the moment that step is dropped, which is the failure being closed.
So **no new proof harness can land unwatched** — and adding a name to the exclusion line is not a snooze button.

### Tracker sync — `check-tracker-sync.sh` (WARN-only in the gate)

The same item is tracked twice: the plan's WORK QUEUE (gitignored, what `next-queue-item.sh` offers) and
`SUITE_TODO.md` (committed, the tracker of record). Nothing enforced that they agree, and on **2026-08-01**
they didn't — `W21.vmgui-path` shipped on 07-31 and was ticked in `SUITE_TODO` but left `[ ]` in the plan, so
the resolver was offering finished work as the next task. A human caught it. **The harm from duplicated state
is that drift is silent**, so `health-gate.sh` now runs `check-tracker-sync.sh` on every gate.

- **WARN-only, never RED** — same reasoning as the coherence check beside it: a doc mismatch must not park a
  run whose builds and suites are green.
- **Compares only items in BOTH files.** One-file-only items are not drift (the plan mirrors a subset by
  design; `SUITE_TODO` carries a long tail the daemon never sees), and HOLD QUEUE items are out of scope
  because they aren't offered as work. A guard that cries wolf gets ignored — the failure it exists to prevent.
- **Parsing deliberately mirrors `next-queue-item.sh`** — same bullet forms, code-fence and blockquote
  skipping, first-occurrence-wins. If the checker and the resolver disagreed about what an item is, the check
  would report phantom drift. Portable POSIX awk only (macOS `/usr/bin/awk` has no 3-arg `match()`).
- Run it directly anytime: `ops/autonomous/check-tracker-sync.sh` (read-only; `0` in sync, `1` drift,
  `2` bad input; `TRACKER_SYNC_QUIET=1` silences the success line but never a divergence).
- It doubles as the **equivalence check for the tracker consolidation** — "do both sources report the same
  item state?" is exactly the assertion a strangler migration needs while both lists still exist.

### Final handoff — `check-handoff.sh` (direct, before declaring a batch done)

`check-handoff.sh` is the final, stricter check for the external-agent handoff in root `AGENTS.md`; unlike the
WARN-only tracker check, a failure means the batch is **not** handed off. It does not edit a working tree or the
plan, but it fetches remote refs so it can verify publication.

- When run from a worktree, it reads `SUITE_TODO.md` from **that checkout** but the ignored plan from the
  **primary checkout**. That catches an uncommitted follow-up that was filed in the worktree but never mirrored
  into the primary plan — the moment the old primary-only comparison falsely called clean.
- It expects at least one parsable open item by default. A blank or malformed tracker therefore fails rather
  than yielding an empty-set success. Only an intentional final closure may use `HANDOFF_EXPECT_OPEN=0`.
- A fresh `origin/main` comparison is required by default. `HANDOFF_OFFLINE=1` is the explicit, visibly warned
  exception for an intentional offline handoff; it does not pretend publication was checked.
- An exemption consumes one matching item only. A second open bullet with the same first word is left loud;
  it must receive a real, mirrorable tag instead of silently inheriting the first item's exception.
- Any open checkbox bullet whose title does not begin with an alphanumeric tag prints `UNPARSEABLE ITEM` and
  fails the handoff. It cannot be queued, mirrored, blocked-on resolved, or archived safely; name it before
  continuing. Historical done entries are not daemon candidates and are intentionally outside this open-item rule.
- Run it from the checkout being handed off: `./ops/autonomous/check-handoff.sh`. It exits `0` only when clean,
  `1` for a failed handoff, and `2` for invalid input or override values.
- The health gate calls the explicit `HANDOFF_MODE=visibility` subset instead of the full check. It fails if an
  open `SUITE_TODO.md` item lacks a primary-plan mirror, but deliberately does not fetch or reject a live
  worktree mid-session. The full default remains the only check that authorizes a final handoff.

### Ticked stubs — `check-todo-stubs.sh` (WARN-only in the gate, W26.donecount 2026-08-10)

`SUITE_TODO.md` holds **OPEN items only**; shipping MOVES the whole entry to `SUITE_TODO_DONE.md`. A `[x]` left
behind reads as done in *both* files, and `status-digest.sh` sums ticked bullets across the two with no dedup —
so it is counted **twice, permanently**. The owner caught it from the outside: the digest went "237 finished" →
"246 finished" overnight when 8 items had closed. Two stubs were double-counted; 244 was the true figure.

- **Column 0 only, and that is what makes it usable.** An *indented* `- [x]` is a legitimate finished sub-step
  inside an entry that is itself still `[ ]` (there are such lines today). A ticked bullet at column 0 in that
  file is always the defect — exact, not heuristic, so it can be a gate check without becoming noise.
- **Deliberately a SEPARATE script from `check-tracker-sync.sh`.** It was tried there and reverted the same
  session: that script's job is comparing `[x]` state *between* the plan and SUITE_TODO, so it must treat a
  `[x]` there as valid input. Asserting the opposite in the same file is self-contradictory, and it broke 5 of
  its fixtures — one of which exists to prove a deliberately-unmirrored HOLD QUEUE item is ignored. Two
  assertions about one file belong in two scripts.
- Skips code fences and blockquotes like its siblings, or it would report the fenced *example* of the bug that
  `W26.donecount`'s own entry contains.
- **WARN-only** (`|| true`), beside `coherence` and `tracker-sync` — ⛔ never a hard step, or a docs-hygiene nit
  parks an overnight run. Its proof `tests/prove-todo-stubs.sh` (17/0) *is* a hard step.
- Run it directly: `ops/autonomous/check-todo-stubs.sh` (read-only; `0` clean, `1` stubs found, `2` bad input;
  `TODO_STUBS_QUIET=1` silences the success line but never a finding). It distinguishes a **confirmed
  double-count** (the tag is also done in the archive) from a merely misplaced tick — different fixes.

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
    "quiet". Token-delta streaming keeps a long high-effort generation growing the log, so it isn't mistaken for
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

**⏸ Paced reviews are currently OFF (owner directive, 2026-07-29).** `next-review-unit.sh` carries a **master
switch** (`REVIEW_ENABLED_DEFAULT=0`, overridable per-run with `AUTONOMOUS_REVIEW_ENABLED=1`) that makes it
always report `none due` / exit 3 — the path STEP 2.0 of the resume prompt already handles, so sessions simply
go on to pick a normal queue item. **Nothing was removed:** the unit table, risk-ordered never-reviewed-first
ranking, cooldown, fail-open stale-sha handling, `--status` and `--record` are all intact and still proven by
`tests/prove-review-cadence.sh` (17 assertions, which forces the switch on for the machinery cases and has a
dedicated case [10] for the switch itself). **Why:** the owner-commissioned Codex full-suite review of
2026-07-29 filed 24 confirmed findings as `SUITE_TODO.md` **Wave 23** (5 HIGH / 15 MED / 4 LOW) — the
bottleneck is fixing those, not finding more. **To re-enable:** flip `REVIEW_ENABLED_DEFAULT=1`, then
re-install from the **primary checkout** (`git merge --ff-only origin/main` there first — `daemon.sh` installs
from `$REPO`'s working tree, not `origin/main`) and restart it.

**Needs-owner HOLD QUEUE (WS10, 2026-07-17; NARROWED BY THE OWNER 2026-08-13).** The daemon **never
auto-executes**: **Tier-3 releases** (DMG / `gh release` / version tags), anything that **writes the REAL
corpus** (`~/Desktop/Google Drive/Archival Photos/`), and **work only the owner can perform or judge** (a key,
an account, a device, subjective taste).
⚠️ **REMOVED from this list on 2026-08-13 — do NOT put them back:** `SPEC` / `tag-format` changes, HIGH review
findings on irreversible paths, and money. **TIER-2 IS THE GATE** for those now — see `AGENTS.md` §*Gating
baseline*. This paragraph is the reference definition other docs cite as "WS10", so it being a superset of the
real gate is how sessions came to park work the owner had released. The resume prompt (STEP 2) skips the plan's `## HOLD QUEUE` /
`[hold]` / `needs: owner` items and surfaces them to Daemon Report + `STATUS.md`. A defense-in-depth backstop
reinforces the soft rule: the daemon's `--disallowedTools` blocks the **direct** invocation of `hdiutil` and
`gh release` (the two release steps) — catching a casual/accidental attempt. It's not a hard boundary (a child
process like `bash release/build-suite-dmg.sh` could still reach `hdiutil`), so the prompt rule — *leave
release work for the owner* — is the primary control.

## Model & effort — one fixed choice, plus per-task subagent sizing (2026-07-31)

Every resume session launches as **`--model opus --fallback-model sonnet --effort xhigh`**
(`EFFORT` = `AUTONOMOUS_EFFORT`, default `xhigh`; the CLI accepts `low|medium|high|xhigh|max`).

**Why the session's own model/effort is FIXED, not chosen per queue item.** Both flags are resolved when the
process launches — *before* the session picks its item, which happens inside the session at resume-prompt
STEP 2 (`next-queue-item.sh`). A session cannot change its own model or effort mid-flight, so "let the daemon
match the model to the task" would mean moving item selection out of the session and into this script — a
Tier-2 change to the daemon, and one that risks divergence, since the resume prompt layers hold-queue and
already-done skips *on top* of `next-queue-item.sh` (the daemon's guess at "the next item" wouldn't always be
the item the session picks). The queue is also the wrong place to economize: Wave 23 is bug work in
file-writing tag paths, the tag/PDF SPEC, actor isolation and shared `ArchiveCore`, where the **Tier-2 gate**
decides what's enough — not a cost heuristic. `sonnet` stays what it already was: the *overload* fallback, the
one model switch worth automating.

**Why `xhigh` and not `max`.** `xhigh` is the documented sweet spot for coding/agentic work and Claude Code's
own default; `max` tends to overthink for diminishing returns *and* reaches the usage cap sooner. On this
laptop the cost of `max` was therefore paid in **completed items per usage window**, not collected in quality.
(`xhigh` was also missing from this file's and the script's old `low|medium|high|max` lists — it postdates
them.) Raise it back for a single hard run with `AUTONOMOUS_EFFORT=max`.

**Where per-task tuning DOES live: subagents.** The session chooses each subagent's effort/model itself, per
task, and the resume prompt's closing *EFFICIENCY + SUBAGENT SIZING* block directs it to optimize for the best
outcome rather than the cheapest run (`--max-budget-usd` already bounds cost). The exact levers, because the
two tools differ: `Workflow`'s `agent()` takes `{effort, model}` per call and is the **only** seam that sets
subagent *effort*; the `Agent` tool takes a `model` override but **no** effort param. Spend up (`xhigh`/`max`)
on judgment under irreversibility — the Tier-2 adversarial review, `Capture/`·`Net/`, file-writing tag/output,
finalize/manifest, the SPEC, shared-Core, refute-verify, and any agent whose wrong answer nothing downstream
would catch. Spend down (`low`/`medium`, smaller model) on mechanical self-checking work — locating call sites,
enumerating conventions, summarizing a log, drafting an edit the session reads before committing. Ties go to
the expensive case. A queue item's `[XS · LOW]` tag sizes the *change*, not the risk of getting its
verification wrong.

## Reuse for another project (the daemon is a template)

`archive-suite-autonomous.sh` is a reusable template — its top has a **PROJECT CONFIG** block. To stand up an
autonomous run for a different repo:

1. **Copy the script**, edit the 5 CONFIG lines (or set the `AUTONOMOUS_*` env vars): `LABEL` (a unique slug —
   it names the state dir + the launchd job `com.<LABEL>.autonomous`), `REPO`, `PLAN`, `STATE`, `CLAUDE`.
   Keep the script + the `claude` binary **outside `~/Desktop`/`~/Documents`/`~/Downloads`** (TCC).
2. **Write the L0 plan** (`$PLAN`, gitignored) from the template shape: PRIME DIRECTIVES → RESUME PROTOCOL →
   a checkboxed WORK QUEUE → Session Log → Daemon Report, and a **plain** status line
   `RUN STATUS: IN_PROGRESS`.
3. **Write the L2 resume prompt** (`$STATE/resume-prompt.txt`) — recover state → pick first `[ ]` → own
   worktree → verify → commit+push+tick → stop. Reuse this repo's `resume-prompt.txt` as the skeleton;
   adjust the repo path + any per-item notes.
4. **Tune** `AUTONOMOUS_INTERVAL` / `STALE` / `MAXRUN` / `BUDGET` / `EFFORT` and the `ALLOW`/`DENY` tool lists
   for the project's risk surface (keep the destructive denylist; deny always wins over allow). `EFFORT`
   defaults to **`xhigh`** — see *Model & effort* below for why that, and why the model is fixed.
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

The daemon (`archive-suite-autonomous.sh`), `daemon.sh`, the resume prompt, and this setup are
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
  the daemon itself — minor, and `daemon.sh stop` covers it by pkill-matching the subshells.)

## Plan compaction — keep the durable plan small (`compact-plan.sh`)

Every fresh session reads the whole plan to orient, so any section that grows unbounded silently inflates the
per-session startup cost. `compact-plan.sh` runs **between cycles** (lock released, no session active — it can
never race a session's append) and trims **three** growing sections back, archiving the overflow to recoverable
files (the plan is gitignored, so `.bak` + the archives are the recovery points, not git). It is also invoked a
second way since 2026-08-10: `health_gate()` runs it to **self-repair a document-only gate RED** before parking
(→ *Periodic health gate*, above), which is safe for the same reason — the gate too runs only when no engine
is active:

- **Pass 1 — `## Session Log`** (**newest-first** — sessions prepend): keep the newest `KEEP=6`, archive the
  older tail to `AUTONOMOUS_SESSION_LOG_ARCHIVE.md` (trigger: >`TRIGGER=10` entries **or** region >`SL_MAX_BYTES=30000`).
- **Pass 2 — `## Daemon Report`** (WS8, 2026-07-17; **newest-first**): keep the newest `DR_KEEP=8` inline,
  archive the older tail to `AUTONOMOUS_DAEMON_REPORT_ARCHIVE.md` (trigger: >`DR_TRIGGER=12` **or**
  >`DR_MAX_BYTES=30000`).
- **Pass 3 — `## WORK QUEUE`** (2026-08-04): archive **completed `[x]`** items (the queue's job is the ORDER;
  a done item adds nothing to it) to `AUTONOMOUS_WORK_QUEUE_ARCHIVE.md` once the region exceeds
  `WQ_MAX_BYTES=70000`.
  ⚠️ **That trigger was 120000 until 2026-08-10, which this pass could never reach** — `context-budget.sh` caps
  the *whole plan* at 180,000 B and the non-queue sections run ~94 KB, so the plan REDs the gate at a queue size
  around 86 KB, far below a 120 KB trigger. Pass 3 therefore no-op'd every cycle from the day it landed (its
  archive file had never been created), the plan drifted to 195,708 B / 108% of budget, and the gate parked the
  run instead — with the fix sitting one unreachable threshold away. Measured at 70000, on a queue region of
  101,990 B: with the tracker gap still open, 35 lines archived / 39,198 B reclaimed / plan → 156,510 B, floor
  62,792 B. **After the gap was closed the same session** (73 shipped items whose done-state existed only in the
  gitignored plan were backfilled into `SUITE_TODO_DONE.md`): **249 lines archived, 68,157 B reclaimed, plan
  195,708 → 127,551 B — 71% of budget — floor 33,833 B.** The lesson is in the gap between those two runs:
  **Pass 3's reach is bounded by what the trackers can vouch for, not by this threshold**, so a tracker gap
  silently halves compaction. Not set lower than the settled floor, or it re-fires forever archiving nothing.
  ⚠️ **Only items whose tag is independently recorded `[x]` in `SUITE_TODO.md` or
  `SUITE_TODO_DONE.md` are eligible** — `next-queue-item.sh` reads a *missing* tag as NOT done, so stripping a
  plan-only `[x]` would block any future dependent forever. Resolvability is preserved **by construction**, and
  Pass 3 deliberately leaves plan-only entries behind (those are a tracker gap to fix, not a compaction target).

### 2026-08-04 — this compactor silently no-op'd for weeks. Read this before editing it.

Owner: *"token use is the real bottleneck for development, not build speed."* The plan had reached **462 KB /
~117k tokens** of per-session orientation cost while `compact-plan.sh` printed "no-op" every cycle. Four bugs:

1. **Format drift disabled Pass 1.** Sessions write Session Log entries as bare date-led lines
   (`2026-08-04 W3.cap-r3-fu9 \`sha\` — result`), not the `- ` bullets Pass 1 counted. 14 of 44 entries were
   visible; the other 1,059 lines sat *before* the first `- ` as untouchable "preamble".
2. **Pass 1 ran backwards.** The section is newest-first, but Pass 1 dropped "the FIRST `$CUT` (oldest)". The
   header text said *"append"*, which is how the mismatch survived. Fixing (1) alone would have archived the
   **32 newest** entries.
3. **Pass 1 tore multi-line entries** — it moved only `/^- /` lines, orphaning continuations.
4. **Pass 2 was broken the same way as (1)**: it wanted a bare column-0 `**[`, but the real section uses
   `### <date>` H3 headers and `- **[…]` bullets → `MN=0` in an 81 KB section.

**The lesson, encoded in the script:** a count-based trigger is a *proxy*; bytes are the cost. Both passes now
also fire on a **byte budget**, and each prints a loud `⚠⚠ ALARM` when a region is over budget but ~no entries
were detected — because a silent "nothing to cut" is precisely what hid all four bugs. **Never re-collapse an
alarm into a quiet no-op**, and if you change an entry-header rule, re-check it against the *authored* format.

**Enforcement lives outside this script too:** `context-budget.sh` (run by the health gate, free) fails the
gate when any orientation document exceeds its budget — so if a detector ever breaks again, the resulting
growth REDs the gate instead of quietly costing tokens. When it fails, **fix the document, not the budget.**
Since 2026-08-10 the daemon attempts that fix *itself* first (compact → re-gate → park only if still red), so a
budget RED reaching the owner now means compaction ran and was **insufficient** — a real document edit is owed,
not a re-run of the compactor. ⚠️ 2026-08-10 also showed the limit of that enforcement: it can only RED the
gate, and REDing the gate merely *stops* the run — for however long the document stays over — while the pass
that would have fixed it sat behind an unreachable trigger. **Enforcement is not repair.**

All three passes are **safe by construction**: region-bounded (Pass 3 owns the WORK QUEUE's completed items;
DIRECTIVES / RESUME / HOLD QUEUE / RUN STATUS are never touched by any pass), they build the result in a temp
file and **validate every live anchor survives + the pre-region is
byte-identical before replacing**, keep a `.bak`, bail leaving the plan untouched on any anomaly, and are
idempotent (no-op under trigger). Each pass is wrapped in a subshell so an early no-op `exit` cannot skip the
passes after it. All three run *after* the work fingerprint is sampled, and the Daemon Report / Session Log
sections are excluded from it, so a rotation is **never** miscounted as the run advancing. Proven by
`tests/prove-compact.sh` (72/0). ⚠️ The self-repair path calls this script at a DIFFERENT point in the cycle —
from `health_gate()` — so if you add a pass, check it is safe there too: the gate runs with no engine active
(same guarantee), but it does **not** re-sample the fingerprint afterwards.

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
