# W35 — several sessions at once, sized to use the whole usage window

Owner, 2026-10-05: "We are currently now often not reaching the full usage window in Claude. The point of running
multiple sessions would be to actually use the full usage window." Make it the daemon's next item. Replaces the
single `W35.lanes` item of 2026-10-04 with the sub-items below.

## Why one session at a time leaves the window unused

A session spends most of its wall time in builds, test suites and the GUI VM, not in model calls. The five-hour
window meters model use, so one session at a time cannot spend it, and whatever is unspent at the reset is lost.
Vision OCR's daemon uses the same Claude account, so the Claude window is shared by both projects; the Codex window
is Archive Suite's.

## What others do (research, 2026-10-05)

- **Parallel sessions in worktrees are the standard practice.** Claude Code has had built-in worktree support since
  v2.1.49 (February 2026), and its documentation lists subagents, agent view, agent teams and workflows as ways to
  run work in parallel, noting that "running several sessions or subagents at once multiplies token usage"
  ([docs](https://code.claude.com/docs/en/agents)). Practitioners put the useful ceiling at 2–4 parallel sessions
  before review becomes the bottleneck ([guide](https://www.developersdigest.tech/blog/git-worktrees-claude-code-parallel-agents-guide)).
- **Claiming work with lock files.** Anthropic's 16-agent C-compiler experiment had each agent claim a task by
  writing a file to `current_tasks/`, with git refusing a second claim of the same file; the agent pulled, merged
  and pushed, then removed the lock ([Anthropic](https://www.anthropic.com/engineering/building-c-compiler)).
  Claude Code's agent teams use a shared task list on the same principle.
- **Size the number of sessions from the usage reading, not a fixed number.** The crew project proposes replacing a
  fixed `max_parallel_issues` with a slot count that adapts to the real usage, because a fixed number "can either
  leave part of the limit unused or cause sessions to hit the limit and fail mid-run"
  ([crew #45](https://github.com/thatsnotmynameio/crew/issues/45)). The orc project's rule is the clearest seen
  ([orc #127](https://github.com/hathbanger/orc/issues/127)): a lane is "tight" when any window's used fraction
  exceeds its elapsed fraction plus a margin (0.15), or passes 0.85; "exhausted" above 0.97 or when rejected.
  Several projects read the same signal this daemon already reads: Claude's stream-json `rate_limit_event`
  (`unifiedWindows.five_hour/seven_day.{utilization,resetsAt}`) and Codex's rollout `rate_limits`.
- **One pause per provider, not one for everything.** crewd found that "a Claude five-hour limit must not stop the
  Grok worker": workers per provider, each with its own concurrency and its own rate-limit pause, overflowing to
  whichever has a free slot ([crewd #119](https://github.com/StGerman/crewd/issues/119)).
- **Stagger the starts.** Starting about 10 Claude Code sessions at once right after a reset got the later ones
  "Server is temporarily limiting requests (not your usage limit)"; the workaround was to stagger starts and back off
  ([claude-code #53922](https://github.com/anthropics/claude-code/issues/53922), closed by Anthropic as not planned).
- **Policy.** Claude Code run headless on one's own machine is Anthropic's own product, and its consumer terms
  exempt it from the ban on automated access; subscription limits assume "ordinary, individual usage". A plan
  announced for 2026-06-15 to meter `claude -p` and the Agent SDK separately was paused that day, not cancelled
  ([summary](https://autonomee.ai/blog/claude-code-terms-of-service-explained/),
  [pause](https://www.digitalapplied.com/blog/anthropic-claude-credit-overhaul-june-15-2026)). So: read usage only
  from the CLI's own events (never from claude.ai's internal endpoints, as some tools do), keep the session count
  modest, and design so the daemon falls back to one session if headless use is ever metered.

## The design

1. **Workers.** One supervisor runs up to N workers, each a session in its own worktree, each with its own engine
   lock and session log under the state dir (`worker-1/`, `worker-2/`…). Workers belong to a LANE: a subscription
   (`claude`, `codex`) with its own slot limit and its own usage pause.
2. **Claims.** Before a session starts, the supervisor (not the session) picks the item and claims it: an atomic
   `mkdir $STATE/claims/<TAG>` holding the worker id and start time. `next-queue-item.sh` skips claimed tags; a claim
   is released when the session ends and is stale after the same time an engine lock is. The session is TOLD its
   item in the prompt, so two sessions cannot pick the same one. Two items that would touch the same files can be
   kept apart with a `(lane: <area>)` tag on the plan line; same-area items never run together.
3. **Shared files.** Plan edits by a session go through one short locked helper (`plan-edit.sh`), so two sessions
   ticking items cannot interleave. `compact-plan.sh`, `tidy.sh` and housekeeping run only when no worker has a
   session in flight, and housekeeping never removes a worktree a live claim names.
4. **Heavy work one at a time.** A machine-wide `heavy.lock` taken by `test-smoke.sh`, `vm-gui-runner.sh`, the
   health gate and `xcodebuild`-running scripts, so two workers never build or boot the VM at once. A session waiting
   on it is not idle, and the health gate runs only when no worker holds it. Vision OCR's suite and bake-off already
   have their own locks; the bake-off yield (`yield-check.sh`) stays.
5. **Pace-aware slots.** Every 90 s, for each lane, from the newest reading (Claude `rate_limit_event`, Codex rollout
   `rate_limits`, account-wide): elapsed = share of the five-hour window gone; used = utilization. Add a worker when
   used < elapsed − 0.10 and used < 0.80 and a slot is free; start no new worker when used > elapsed + 0.15 or used >
   0.85; pause the lane when used > 0.97 or rejected, until the reset. The weekly window gates the same way, against
   its own elapsed share, so the week is not spent in two days. Starts are staggered by at least 60 s.
6. **Priority.** Vision OCR keeps priority on the Claude window: Archive Suite adds a Claude worker only when the
   Claude lane is under pace counting Vision OCR's use, which the account-wide reading already includes. Limits to
   begin with: Claude lane at most 2 Archive Suite workers, Codex lane at most 2.
7. **Fallback.** One worker per lane is the old behaviour and stays the default until `W35.live` has measured the
   new one; `AUTONOMOUS_MAX_WORKERS=1` restores it at any time.

## Items (each with a prove-harness in the gate, as W34's)

- `W35.claims` — SHIPPED 2026-10-05 (this commit). Supervisor reservation + assigned prompt,
  worker artifact directories, birth-identity/token protected claims, lane-aware resolver, locked plan-edit
  complete/block/log/report/append and idle upkeep. Contract and usage: `ops/autonomous/README.md`
  §Item claims and shared plan edits. Scratch concurrency/crash and real-dispatch proof in the gate.
- `W35.heavy` — SHIPPED 2026-10-06 (this commit). Machine-wide, nested-call-safe kernel lock
  around build/test/gate/VM entries; live registered sessions remain protected after supervisor death.
  Fresh, birth/ancestry-validated waiters count as watchdog work; gate timing starts after acquisition.
  GUI/sandbox refusals precede waiting; all VM entries take heavy ownership before the VM lock.
  Older unattended supervisors retain their prior path until the next owner restart. Contract and
  scratch functional proof: `ops/autonomous/README.md` §Heavy work across workers and `tests/prove-heavy.sh`.
- `W35.workers` — SHIPPED 2026-10-06 (this commit). Opt-in bounded Claude/Codex lanes,
  per-worker artifacts/counters and per-lane usage pauses; 60-second CLI start barrier, protected-orphan
  and pending-start capacity, idle-only global upkeep and repair draining. Explicit owner generations
  reset prior-layout counters/markers; crash relaunch preserves terminal reasons and ambiguous claims.
  Every worker appears in status. Owner-enabled source refresh drains before exiting for KeepAlive,
  including helper-only commits; automatic refresh retains the run generation. Contract: `ops/autonomous/README.md` §Several workers and subscription
  lanes; functional proof: `tests/prove-worker-supervisor.sh` in the health gate.
- `W35.pace` — SHIPPED 2026-10-06 (this commit). `usage-pace.py` sizes each lane from its newest current
  reading (highest across sources) with §5's bands plus "steady keeps the count" hysteresis; never below one
  worker, so §5's 0.97 pause stays the existing 95%/cutoff pause; the weekly window only holds back (tight),
  never blocks grow. Vision OCR's log is a Claude source. Contract: `ops/autonomous/README.md`
  §Pace-aware slots; proof: `tests/prove-usage-pace.sh` in the health gate.
- `W35.live` [S] — the first real run with 2 workers, measured: window used at each reset before and after, items
  finished per day, collisions (duplicate items, merge conflicts, heavy-lock waits). The owner decides whether to
  keep it, and whether to raise the limits.
  Tooling landed 2026-10-06: `ops/autonomous/measure-workers.py` (README §Measuring a multi-worker run), heavy
  waits in `$STATE/heavy/waits.log`. Waiting on the owner to start `daemon.sh start --workers 2`
  (`W35.live-owner-ok`), then on the owner's decision after about a day of readings.
