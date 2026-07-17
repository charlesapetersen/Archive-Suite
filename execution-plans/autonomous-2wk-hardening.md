# Execution plan — Autonomous 2-week unattended hardening (pre-flight)

**Goal.** Make a **~2-week unattended daemon run** feasible: survive that long without silently dying,
wedging, filling the disk, drifting, or leaving the owner unreachable — and let the owner check in and be
alerted without reading 15 files. This is the **pre-flight checklist for a long run**, authored 2026-07-16
after a full review of the daemon setup.

**Who executes this.** Supervised / **interactive** sessions — NOT the unattended daemon. Every item here is
a **Tier-2** change to the autonomous infrastructure itself (`ops/autonomous/*`, resume prompt, plan format),
so per the change-discipline each gets an **adversarial review + a prove-the-mechanism harness** (run the real
daemon against a stub `claude` in a sandboxed `HOME`/`STATE`/`REPO`, the pattern used for the idle-backoff
change) **before install**. The daemon rewriting its own guardrails while running unattended is precisely the
failure mode to avoid — do this work first, then arm the long run.

**Already in place (foundation — not repeated here):** self-resume off the durable L0 plan; idle backoff +
auto-park when nothing is actionable (2026-07-16, `ffd2165`); the two health watchdogs (wall-clock + event
heartbeat/liveness); merged-and-clean worktree GC; `compact-plan.sh` (Session-Log trimming); the doc-sync
backstop; per-change Tier-2 review.

**Owner inputs to collect before/while building:**
- **Push endpoint + token** for remote alerts (Pushover / ntfy / email-webhook) → into `$STATE/env` (WS6).
- **Liveness posture decision** (WS1): launchd KeepAlive for crash-restart? keep-logged-in + defer-OS-updates
  for the 2 weeks? (Auto-login for reboot-survival is **not recommended** — security tradeoff, and defeated by
  FileVault anyway; plan is "don't reboot".)
- **Confirm the 2-week checklist itself** is authored and dependency-ordered (WS9 consumes this).

---

## Survival — would sink the run (do first)

### WS1 — Durability & crash-restart posture
- **launchd KeepAlive** (`com.archivesuite.autonomous.plist`, already in `ops/autonomous/`, currently NOT
  installed): install so a *crash* of the daemon bash process (OOM/bug/stray kill) auto-restarts it — the one
  real gap vs the current `nohup` loop (which is already reparented to `init`, so it survives its launching
  terminal closing, but a crash ends the run silently). Park must still stop cleanly under KeepAlive
  (`launchctl bootout` on park unloads the job so KeepAlive won't relaunch — verify).
- **Keychain-under-launchd check (blocker for WS6/health too):** a launchd-loaded agent has a different
  keychain context than a terminal launch — re-verify the `security find-generic-password` reads in
  `test-smoke.sh`/E2E succeed non-interactively under launchd (they were just granted for the GUI-session
  context). If not, fold in the env-key path (below).
- **Keep-alive checklist** (doc, in README): stay logged in; defer macOS updates for the window; plugged in;
  `caffeinate` already asserted by the daemon. Honest note that unattended **reboot** survival is not
  achievable with FileVault / without auto-login — so the posture is "don't reboot."
- *Verify:* kill the daemon pid → KeepAlive restarts it; park → stays down; a login-cycle test if feasible.

### WS2 — Disk-space guard
- In the daemon loop, before launching a session, `df` the repo volume; if free space < threshold (e.g. 10 GB
  or 5%), **park + alert** instead of building (a full disk fails every build → silent cascading failure).
- Also prune `build/DD` for worktrees already removed, and cap `last-session.log` retention (already 2).
- *Verify:* stub a low-free-space reading → daemon parks+alerts, does not launch a session.

### WS3 — Dirty / abandoned worktree reclamation
- Extend `housekeeping()` to reclaim worktrees left by watchdog-killed sessions (currently only merged+clean
  are GC'd; dirty ones accumulate — ~6 strays already). **Safety-critical, mirrors the existing housekeeping
  review:** only touch a `wt/*` worktree that is (a) not the active session's, (b) idle beyond an age
  threshold, (c) whose branch tip is pushed/merged; **stash or copy any uncommitted delta to a recovery area
  before removal — NEVER lose unpushed work** (default to leaving it if in doubt).
- *Verify:* adversarial review of the data-loss surface + a harness with dirty/active/merged fixtures.

### WS4 — Per-item attempt cap
- Track sessions spent per item-tag (a counter file, or derived from Session Log). After N (default 3)
  sessions on the same tag with **no FINAL commit**, mark the item `[blocked: mis-sized]`, skip it, alert —
  so a hard/mis-sized item can't burn days of budget while committing empty "progress" checkpoints (the
  backoff can't catch this: checkpoints move the fingerprint).
- *Verify:* stub a never-completing item → capped + flagged + skipped after N.

---

## Observability & safety-net — makes "unattended" actually safe

### WS5 — `STATUS.md` digest (the check-in surface)
- A generator the daemon runs each cycle (like `compact-plan`) writing a one-screen `STATUS.md`: run state
  (productive / backing-off / parked), backlog depth (done / in-flight / blocked), commits/day + last commit,
  disk free, last health-gate result (WS7), worktree count, and the current **owner-needed** items. Turns a
  15-command check-in into a 5-second read.
- *Verify:* generated file matches reality across a few daemon states.

### WS6 — Remote alerting
- The daemon (bash — the tool deny-list constrains only `claude -p` sessions, not the loop itself, so it can
  `curl`) sends a push on: **park**, a **newly-flagged blocker/needs-owner**, a **failed health gate**, or the
  **taskport-still-open** security exit. Endpoint/token from `$STATE/env` (owner input). No-op if unset.
- *Verify:* fire each trigger against a test endpoint; confirm no secret is logged.

### WS7 — Periodic health / regression gate
- Every N commits or N hours, run a full gate: clean build of all 3 apps (no new warnings) + `./test-smoke.sh
  all` + Reader/Notes unit suites + a tracker-coherence check (no `[x]` item lacking its completing commit; no
  orphaned `execution-plans/`). On **red → park + alert** with the failing output. Catches a compounding
  regression that per-change review misses over 50+ unreviewed commits.
- *Verify:* seed a failing test → gate goes red → parks+alerts; green → advances the cadence marker.

### WS11 — Recurring paced whole-project code review *(owner-requested 2026-07-16)*
WS7 catches *regressions* (red build/test); it cannot catch **design/quality drift** accumulating across 50+
commits that nobody reviews for two weeks. So the run must also **re-review the codebase on a cadence**.
- **Method — the paced one, non-negotiable:** `REVIEW.md`'s lean review — **ONE unit per session** (~6 finders
  + refute-by-default verify, ~20 agents). **Never a whole-project fan-out in one session** — that blows a
  usage window (the lesson `REVIEW.md` exists to record). The 10 canonical units + their paths live in
  `REVIEW.md`; unit 7 (iOS companion) stays **skipped** per the ON-HOLD scope.
- **Cadence:** one review unit per N hours / every Nth session (tunable, e.g. ~1–2/day) so review **interleaves
  with feature work instead of starving it**. Same cadence-marker mechanism as WS7.
- **Cycling + delta-aware priority (the real change):** today's `.maintenance/REVIEW_PROGRESS.md` is a
  **one-pass** sweep — units get marked done and the sweep ends. Make it **recur**: record each unit's
  **last-reviewed sha**, and each tick pick the unit with the most changes since that sha
  (`git log <last-sha>..HEAD -- <unit paths>`); if nothing changed anywhere, re-review the **oldest**. Over two
  weeks, reviewing *what actually changed* is what matters — not round-robin over untouched code.
- **Findings → action, not prose:** confirmed (refute-verified) findings are appended as **fix items** to the
  work queue + `KNOWN_ISSUES.md` (the existing `W3.f1–f6` pattern); refuted ones are dropped. The unit's report
  persists under `.maintenance/review/`.
- **Guardrail:** a review session is **read-only** — it files findings, it does **not** freelance fixes. Fixes
  are separate queued items, so a review can't ship an unreviewed risky change. High-severity findings on
  irreversible paths route to the WS10 hold queue.
- **Interaction with WS4:** review units are inherently multi-pass; the attempt cap must not mis-flag them as
  mis-sized (the resume prompt already treats "multi-pass loop" as do-ONE-pass-then-stop).
- *Verify:* seed a change in one unit's paths → that unit is picked next; a unit with no changes is
  deprioritized; a confirmed finding lands as a queued fix item; progress/sha markers advance.

---

## Coherence & scope over 14 days

### WS8 — Morning Review triage / rotation
- Extend `compact-plan.sh` to also bound the `## Morning Review` section (already **1,655 lines**; read every
  startup, so it inflates per-session cost and becomes an unreadable wall unattended): keep a small
  **OPEN / needs-owner** head inline, archive resolved/stale notes to the archive file. Same careful
  region-bounded editing as the Session-Log path.
- *Verify:* resolved notes archived, open ones retained, plan shrinks, no cross-section corruption.

### WS9 — `blocked-on` dependency gating
- Add an optional `(blocked-on: <tag>)` to the plan item format; resume-prompt STEP 2 skips an item whose
  prerequisite tag isn't `[x]` yet and picks the next **unblocked** one — so accumulating dependent work is
  done in order instead of stalling or running out of sequence. Protocol change (resume-prompt + plan format);
  no daemon-code change, but treat as Tier-2 (it changes work selection).
- *Verify:* a plan with a blocked chain → sessions pick only unblocked items, in dependency order.

### WS10 — needs-owner hold queue
- A dedicated plan section for **irreversible / highest-blast-radius** work — Tier-3 releases, SPEC /
  `tag-format` changes, anything **corpus-writing**, DMG/publish. Resume-prompt: **never auto-execute** from
  the hold queue; only surface it to Morning Review / `STATUS.md`. Keeps the riskiest work human-gated for the
  whole unattended window (the corpus-safety directive matters most when no one is watching).
- *Verify:* an item in the hold section is never picked by STEP 2; it appears in the digest.

### WS12 — Keychain partition-list fix *(added 2026-07-17 — the owner was woken twice by this)*
The daemon's Tier-1 gate `test-smoke.sh` reads the Gemini key via `security find-generic-password -w`, so the
requester is **/usr/bin/security**, not the app — the stable-signing fix (`496d202`) can't touch it. And
"Always Allow" never stuck because it edits the item's **ACL**, while a CLI tool's prompt-free access is
gated by the newer **partition list**. Fix: `ops/autonomous/fix-keychain-access.sh` adds `apple:,apple-tool:`
to each key item's partition list so `/usr/bin/security` reads without prompting.
- **Owner-run, one-time** (needs the login password → cannot live in the unattended daemon). Re-run after
  rotating a key (a re-created item gets a fresh, empty partition list). `arm.sh status` prints a reminder.
- Owner chose this over env-key injection (2026-07-17) to **keep keys in the Keychain** — no plaintext file.
- *Verify (manual):* run it → a daemon test-smoke cycle no longer prompts; then launch the app once to
  confirm the app still reads its key under the new partition list.

---

## Ordering
Survival (WS1–WS4) → observability/safety-net (WS5–WS7, WS11) → coherence/scope (WS8–WS10). **WS6 comes first
in practice** — WS2/WS4/WS7/WS11 all end in "park **+ alert**", which is meaningless while the only alert is a
local notification an away-owner never sees. WS5 surfaces WS7/WS11 results but both ship incrementally. Each
lands as its own reviewed+proven commit; the long run is armed only after all are in and a dry-run cycle looks
clean.

## Progress
- [x] **WS6** alert core + **WS2** disk guard — shipped 2026-07-16 (harness-proven, reviewed).
- [x] **WS12** keychain partition-list fix — shipped 2026-07-17 (owner-run helper; **owner runs it once**).
- [x] **WS4** attempt cap — shipped 2026-07-17 (parks after `MAX_NOCOMPLETE` committed-but-no-completion
      sessions; completion signal = top-level `[x]` across BOTH trackers; harness-proven, reviewed).
- [x] **WS1** crash-restart posture — shipped 2026-07-17. `arm.sh keepalive` runs the daemon under launchd
      `KeepAlive=true` (a crash/kill auto-restarts; every intentional stop boots out); motivated by the
      2026-07-17 death (daemon TERMed mid-session, nothing restarted it). Proven by `tests/prove-keepalive.sh`
      (throwaway LaunchAgent: RunAtLoad→start, kill-9→relaunch, bootout→stays dead). Reboot-survival out of
      scope; GUI-verify still best under plain `arm` (nohup, TCC-inherited).
- [x] **WS11** recurring paced review — shipped 2026-07-17. `next-review-unit.sh` (cadence-gated unit picker;
      per-unit last-reviewed shas in a gitignored TSV) + resume-prompt STEP 2.0 (read-only `lean-review` on the
      due unit → findings become queued fixes / hold-queue, then `--record`, all via a worktree + push).
      REVIEW.md's one-unit-per-session method — never a whole-project fan-out. Its review found **3 HIGHs**,
      all fixed + regression-tested: **two-tier pick** (never-reviewed units win in risk/table order, so a
      low-churn high-risk unit like Net isn't starved), **fail-open on a stale/invalid sha** (treat as
      never-reviewed, never a silent-0 stall), and **STEP 2.0 routes through a worktree + push** (no
      commit-in-primary). Proven by `tests/prove-review-cadence.sh` (12 assertions incl. those 3).
- [x] **WS10** needs-owner hold queue — shipped 2026-07-17. Resume-prompt STEP 2 never auto-picks a
      `## HOLD QUEUE` / `[hold]` / `needs: owner` item (Tier-3 releases, SPEC/tag-format changes, corpus-writing,
      HIGH-on-irreversible findings from WS11) — surfaces them to Morning Review/STATUS instead. Defense-in-
      depth backstop: the deny-list blocks the DIRECT invocation of `hdiutil` + `gh release` (catches a casual
      attempt; not a hard boundary — a child script could still reach hdiutil), so the prompt rule (leave
      release work for the owner) is the primary control. Also added a daemon **source-guard** (dogfood fix:
      sourcing it to inspect $DENY previously ran the loop + spent budget).
- [x] **WS7** periodic health gate — shipped 2026-07-17. `health-gate.sh` (build all 3 apps + Reader/Notes
      UNIT suites + coherence — FREE; paid OCR opt-in via `AUTONOMOUS_GATE_OCR=1`) + the daemon runs it
      DIRECTLY (deterministic, no session) every `AUTONOMOUS_GATE_EVERY` commits, PARKS + alerts on RED. Unit
      tests are `-only-testing:<UnitBundle>` (NOT the whole scheme) — load-bearing: running a UITest pops the
      UI-automation prompt, which would hang the synchronous gate + wake the owner (found by dogfooding). The
      gate is wall-clock-capped (`GATE_MAXRUN`); a hang → kill + SKIP (never false-park). last-gate sha
      persists across restarts; bad/missing sha fails OPEN. Its review found no data-loss/hang but a
      MED-leaning-HIGH + 3 more, all fixed: **retry-once before parking** (a flaky test / transient xcodebuild
      blip no longer false-parks — only a reproducible 2nd failure parks); **persistent-timeout escalation**
      (a single hang skips, but N consecutive hangs park + alert instead of silently taxing every cycle;
      +wait-reap the killed gate); **`arm.sh stop` now kills an in-flight gate** (was orphaning the xcodebuild
      tree); **DeepLink env-test skipped** (would have RED'd every gate — KNOWN_ISSUES entry) + coherence made
      warn-only. Proven: `prove-daemon.sh` (68 assertions) + a real `health-gate.sh` run (green + prompt-free).
- [x] **WS5** STATUS digest — shipped 2026-07-17. `status-digest.sh` prints a one-screen check-in (run state,
      PLAN, HEAD/commits-24h, backlog, gate result, review coverage, disk, worktrees, **NEEDS-YOU**); the
      daemon rewrites `$STATE/STATUS.md` each cycle + on park, and `arm.sh status` runs it. Read-only,
      degrades gracefully, non-fatal write. Proven: `prove-daemon.sh` (71) + a real run against this repo
      (correctly flagged the pending keychain fix + Morning-Review entries).
- [ ] WS8 Morning-Review rotation · WS9 dep gating.

## Out of scope (owner calls, 2026-07-16)
- **Reboot-survival / auto-login** — declined; posture is "don't reboot" (WS1).
- **Cumulative cost ceiling** — declined; per-session `--max-budget-usd` stays the only budget guard.
