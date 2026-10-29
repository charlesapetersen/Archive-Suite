# Archive Suite — Umbrella Project Guide

Three native macOS apps in one monorepo: **Archive Processor** (capture · OCR · tag),
**Archive Reader** (find · read · triage), and **Archive Notes** (provenance‑first note‑taking from
archival sources). This file is the *umbrella* guide — repo‑wide conventions, the shared contract, and
the release process. **Each app's own `CLAUDE.md` stays authoritative for that app**; read it before
working inside a subdirectory:

- [`ArchiveProcessor/CLAUDE.md`](ArchiveProcessor/CLAUDE.md) — the Processor + its iOS/Android capture companions.
- [`ArchiveReader/CLAUDE.md`](ArchiveReader/CLAUDE.md) — the Reader (incl. its bulletproof file‑safety Core Directive).
- [`ArchiveNotes/CLAUDE.md`](ArchiveNotes/CLAUDE.md) — Notes (provenance‑first notes + extracts from archival PDFs).

## 🛑 THE DAEMON REPORT IS A WALKTHROUGH, NOT A DOCUMENT — read this before answering any request for it

**Trigger phrases:** "daemon report", "the report", "morning review" (the old name), "anything for me?",
"anything I need to decide?", "what needs my eye?", "walk me through it". Any of these means **run the
walkthrough below.** This section exists because sessions kept getting it wrong in the same two ways, and
the owner had to correct it every time.

**What the owner wants, exactly:** to be **walked through each open decision, ONE AT A TIME, waiting for his
answer before moving to the next.** It is a conversation he steers. That is the whole deliverable.

**❌ Do NOT do any of these — each one has actually happened and is a failure, not a variation:**
- ❌ **Do not write a new entry into the plan.** Being asked for the report is not a cue to author one.
  Nothing is added to any doc *during* the walkthrough.
- ❌ **Do not let the account of the work replace the decisions.** The full account of the work comes first
  (`~/Claude/CLAUDE.md` step 3, owner 2026-10-15: detailed, read from the commit bodies), then the decisions
  one at a time. A recap with no decisions walked is not a report.
- ❌ **Do not batch the decisions** into one message with a numbered list and a single "what do you think?".
  One decision per message. Stop. Wait.
- ❌ **Do not re-raise settled items.** Anything under a `### ✅ … walkthrough` heading, or in
  `SUITE_TODO.md` → *"⛔ DECLINED — settled, do NOT re-raise"*, is closed. Reopening it wastes his time.
- ❌ **Do not present non-decisions as decisions.** "Worth your eye, nothing blocking" is a *mention*, not a
  step. Fold those into one short block at the end, after the real decisions are done.

**The procedure:**
1. Start from the Agent Manager's walkthrough: run
   `/usr/bin/python3 "/Users/cp1/Claude/Agent Manager/manager.py" walkthrough`. It lists every project's open
   questions and the work since the last walkthrough; this project's unwalked Daemon Report entries arrive in it
   through the holds hook. For the detail of each entry, read `## Daemon Report` in
   `.maintenance/AUTONOMOUS_PLAN.md` (newest-first). It is the **input** to the walkthrough, never the output. Stop
   at the newest `### ✅ … walkthrough` heading — everything below it is already settled. The full cross-project
   procedure (a full account of the work first, read from the commit bodies, usage as a share of the weekly window, `walkthrough --mark`
   when the owner opts in to recording) is in `~/Claude/CLAUDE.md`, section "The walkthrough".
2. Add anything from the current session that genuinely needs his call.
3. Say up front how many open decisions there are ("three, walking them one at a time").
4. For **each**, in its own message: what was decided/asked before, what changed since, what is actually at
   stake, then the question with concrete options — and a recommendation when you have one. **Then stop and
   wait.** Use `AskUserQuestion` so the options are pickable.
5. After the last one: a compact table of his calls, plus the "worth knowing, no decision" leftovers.
6. **Only then** ask whether to record the outcomes in the plan. Recording is a separate, opt-in step.
   An answered owner gate is recorded in the plan with
   `ops/autonomous/plan-edit.sh .maintenance/AUTONOMOUS_PLAN.md approve <GATE> '<the answer>'`; ticking the gate
   is what unblocks the work. Editing only `SUITE_TODO.md` leaves the gate open and the item waiting, and the
   holds hook then marks the gate `HALF-RECORDED` (W41.seg-cheap-more, 2026-10-13). Close the walked entries with
   a `### ✅ <date> — walkthrough done (owner): …` heading above them (`plan-edit.sh PLAN report '<heading>'`).

**Naming:** the section was `## Morning Review` until 2026-08-05, renamed because it happens at any hour.
Scripts still match both spellings; new writing says **Daemon Report**.

**The daemon side is the opposite and stays unchanged:** an unattended session that hits something needing a
human **appends** to that section and moves on (`ops/autonomous/resume-prompt.txt`). Appending is what the
daemon does *between* walkthroughs. It is never what you do *during* one.

## How we work — the loop for every change

The whole per-change checklist in one place, so no rule hides inside a longer section. Every change, in order:

1. **Isolate** — work in your own git worktree, never the primary checkout (→ *Worktree-first*, below).
2. **Build-verify** — clean build, **no new warnings**; run the touched app's smoke test — but note the
   smoke script runs the app's WHOLE scheme, and the scheme contains the UITest bundle, so on the host it
   drives the real app on screen. `test-smoke.sh` therefore restricts itself to the unit bundle whenever
   `ARCHIVE_UNATTENDED=1`, and the UITests run off-screen in the VM instead (`ops/gui/vm-gui-runner.sh
   <reader|notes|processor> xcuitest`). The periodic gate rotates one of all three apps per invocation, so
   its 20-minute per-app cap stays inside the 50-minute whole-gate budget. Note the unit bundles are app-**hosted** — `xcodebuild test -only-testing:<App>Tests`
   launches the real `.app` — but it renders nothing under each app's local `ArchiveTestHost`, so a
   green unit run is never evidence that anything *drew*.
   **Anything visual → [`AGENTS.md`](AGENTS.md) §*GUI verification*, which is CANONICAL for it** — the triage
   table (read-the-code vs headless render guard vs off-screen Tart VM vs genuinely-owner-only), the TCC
   state, and every layer that blocks the host screen. Deliberately not restated here: it was maintained in
   both files, which is how the copies drift. Two consequences bear on this step — a **view / PDF-render**
   change needs a headless render guard (`RenderProbe` / `DocumentRenderGuardTests`), because XCUITest sees
   the accessibility tree and not pixels; and **the owner's screen is theirs**, so an unattended session may
   not draw on it at all (`.claude/hooks/no-host-gui.sh` enforces it mechanically).
3. **Review by risk** — Tier-2 (adversarial review + a functional test) for anything with **no undo**:
   `Capture/`·`Net/`, file-writing tag/output, manifest/finalize, actor isolation, or the tag/PDF SPEC.
   Full tiers + the phone↔Mac E2E gate: each app's `CLAUDE.md` → *Verification & review policy*. For a
   **full-codebase review**, use the paced method in [`REVIEW.md`](REVIEW.md) — one subsystem per session,
   lean fan-out, refute-verify; **never** one giant fan-out (it blows a usage window). Use the `/code-review`
   skill for the working diff.
   ⏸ **Paced *whole-project* reviews are PAUSED for the daemon (owner, 2026-07-29; re-confirmed 2026-08-01).**
   The original wording said "while it drains the `SUITE_TODO.md` **Wave 23** bug queue" — **that condition has
   now been MET** (Wave 23 is 34 done / 8 open, and all 8 remaining are `-fu` follow-ups rather than original
   findings). The owner was shown exactly that on 2026-08-01 and **chose to keep the pause anyway**, including
   declining a narrowly-scoped Notes-only review. **So do not lift the pause on the grounds that Wave 23 is
   drained** — that argument has already been made to him and turned down. See [`REVIEW.md`](REVIEW.md).
   **This does NOT relax this step:** the
   per-change Tier-2 gate (adversarial self-review + a functional test on anything with no undo) is
   unchanged and still mandatory. What's paused is *proactively hunting for new findings*, not reviewing
   your own change.
4. **Docs move with the code — in the SAME commit** (→ *Docs & backlog convention*, below): flip the
   shipped `SUITE_TODO.md` checkbox, update `KNOWN_ISSUES.md`, delete a shipped `execution-plans/` plan.
   `SUITE_TODO.md` is the tracker of record; an unattended run reconciles it **before it ends**.
5. **Push often, release rarely** — a clean build + self-review is enough to push; a DMG/release is the
   sparse, Tier-3-gated milestone.
6. **Clean up** — remove your worktree once the work is pushed.

The sections below are the depth behind these steps. **The owner should never have to catch a skipped one**
(a doc-sync backstop hook enforces step 4 — see `.claude/hooks/`).

**Unattended / autonomous runs** follow the same loop, one bounded item per fresh session, off a durable plan
that survives usage cutoffs — see [`ops/autonomous/README.md`](ops/autonomous/README.md) (L0 durable plan → L1
self-resume daemon → L2 resume prompt), with the paced review in [`REVIEW.md`](REVIEW.md). Never run such a
session with `--dangerously-skip-permissions`; use `--permission-mode default` + a scoped allow/deny list.

## Worktree-first — mandatory before any edit (every agent & instance)

**Before you edit, build, or commit anything in this repo, be in your own dedicated git worktree — never
work directly in this primary checkout.** This is *unconditional*: do it even if you believe you are the
only instance running. You cannot know that another instance or subagent won't start in parallel, and
**the owner does not track worktrees** — so the only coordination-free way to stop parallel instances from
clobbering each other's uncommitted edits and racing the build cache is that *nobody* works in the primary
checkout. (A pure read-only / question-answering session that changes nothing is the only exception — don't
spin up a worktree just to answer a question.)

**Make this your first step — it's idempotent, so it's safe to run at the start of every session:**
```bash
# Run from the checkout you were launched in. Creates a worktree ONLY if you're not already in one.
if [ "$(git rev-parse --git-dir)" = "$(git rev-parse --git-common-dir)" ]; then
  stamp="$(date +%Y%m%d-%H%M%S)-$$"
  worktree_root="/Users/cp1/Claude/.worktrees/archive-suite"
  mkdir -p "$worktree_root"
  git worktree add "$worktree_root/suite-wt-$stamp" -b "wt/<task-slug>-$stamp"
  cd "$worktree_root/suite-wt-$stamp"
else
  echo "Already isolated in $(git rev-parse --show-toplevel) — keep working here."
fi
```
Then do **all** edits, builds, and commits from that worktree (use its absolute paths for Read/Edit/Write),
and run `xcodegen generate` there before building (the `.xcodeproj` is gitignored). Push as normal — every
worktree shares one `origin/main`. **When your task is pushed, remove your own worktree** so they don't pile
up for the owner: from the primary checkout, `git worktree remove "/absolute/path/to/your/worktree"` (`./build` is gitignored,
so it won't block); `git worktree list` / `git worktree prune` clear strays.

Engine sessions use this dedicated parent, not loose folders in `~/Claude`. Register the worktree in
`$AGENT_WORKER_STATE/worktree` immediately. If a session is interrupted, the engine preserves its inactive
checkout intact in `~/.local/state/archive-autonomous/retired-worktrees/`, including ignored results, Git
administration and staged changes, and removes its worktree registration. A retry receives pointers for
its own item. Codex retries start inside the previous checkout or a restored copy, including uncommitted and
staged changes (`AGENT_RESUME_WORKTREE`); continue there and reconcile newer main changes before shipping.
Failed restoration stops the launch instead of silently starting over. These recovery copies are ordinary
directories and must not be edited or deleted by a session. Active or claimed worktrees are left alone.

**Subagents that write files** must be isolated the same way — pass `isolation: "worktree"` to the Agent
tool (or `{isolation: 'worktree'}` on a `Workflow` `agent()` call) so each gets its own scratch worktree
instead of racing in yours.

Ownership lanes, per-app build commands, and shared hotspots: [`AGENTS.md`](AGENTS.md).

## Repo map

```
Archive-Suite/
├── SPEC/tag-format.md      # THE shared tag/PDF contract — single source of truth for all apps
├── OWNER_AUTHORIZATIONS.md # what the owner has cleared on gated paths, + each grant's ⛔ constraints
├── packages/ArchiveCore/   # shared Swift package (tags, PDF, durable links, suite marker)
├── release/                # suite-level release tooling (combined DMG)
├── launch.sh               # dispatcher → ./launch.sh reader|processor|notes
├── ArchiveProcessor/       # outer = relocated app repo
│   ├── macOS/              #   XcodeGen project dir: project.yml (authoritative), Sources/, generated .xcodeproj (gitignored)
│   ├── ArchiveCapture/     #   Android capture companion
│   └── ArchiveCaptureiOS/  #   iOS capture companion
├── ArchiveReader/          # outer = relocated app repo
│   └── macOS/              #   XcodeGen project dir: project.yml, Sources/, Tests/, generated .xcodeproj (gitignored)
├── ArchiveNotes/           # provenance-first note-taking app
│   └── macOS/              #   XcodeGen project dir: project.yml, Sources/, Tests/, generated .xcodeproj (gitignored)
└── ArchiveOCRBench/        # the bench's measured OCR, segmentation and handwriting results as one page; kept current (below)
```

The inner XcodeGen project dirs are named `macOS/` (de-nested from the old `App/App/` layout that
was a byproduct of the repo merge). Each app's `launch.sh`/`bootstrap.sh` use paths relative to
themselves.

## The shared contract is the risk

The two apps are coupled by exactly one thing: the **Finder‑tag vocabulary + 2‑page PDF format** the
Processor writes and the Reader reads. A silent divergence there could corrupt or mis‑read
irreplaceable data. That contract lives, authoritatively, in [`SPEC/tag-format.md`](SPEC/tag-format.md)
— **any change to how tags/dates/priority/color/classification are written or parsed must update both
apps and that spec together**, and is Tier‑2 (adversarial review + tests on scratch copies, never the
real corpus).

## There is no production material yet — what that relaxes, and what it does not

**Owner directive, 2026-08-01.** No app in this suite has produced data he intends to keep, and **the entire corpus
predates these apps**. So stop designing for continuity: **no migration paths** (change a schema, don't version it),
**no backward‑compatible parsing** (a link/tag/PDF format may change shape outright), **no inert‑legacy
carve‑outs** (rules that exist to avoid disturbing already‑written app output are moot); settings and structure are free to change. Prefer
the right end state to the compatible one, and say in the commit that no migration was written *because there is
nothing to migrate*.

**What is UNCHANGED — the directive is about app *output*, not about inputs or money.** Each owner decision below is
stated as a rule; its full wording, history and the cases behind it are in [`REFERENCE.md`](REFERENCE.md)
§"No production material — the full record".
- ⛔ **The real corpus stays sacred.** `~/Desktop/Google Drive/Archival Photos/` (~102k PDFs) is irreplaceable. The
  Reader's Core Directive and scratch‑copy‑only testing are untouched.
- ✅ **Money paths NO LONGER need a per-item owner grant (owner, 2026-08-13).** The *authorization gate* is removed (a money-touching item no
  longer waits on a named entry in `OWNER_AUTHORIZATIONS.md`); the cost discipline in each app's guide stands (cheapest capable model, smallest input set that proves the behaviour, say what a big run
  costs). Not-permission, but not a blank cheque. §*Gating baseline* in [`AGENTS.md`](AGENTS.md).
- ⛔ **But $7 is the ceiling without asking (owner, 2026-10-11; raised from $3 on 2026-10-28)** of real money for one piece of
  work (an item across all its sessions). Subscription usage is not money. Over $7, an unattended session asks in the
  Daemon Report and moves on. Authority: `~/Claude/CLAUDE.md`, "Spending money".
- ✅ **The W46 processing review's paid arms are released (owner, 2026-10-21).** The paid-benchmarking hold below
  no longer covers the review's items (`execution-plans/processing-review/10-gap-audit.md` §5). Route order: the **Stanford AI API
  gateway** first (`https://aiapi-prod.stanford.edu/v1`, the Processor's gateway key in Keychain, account `Gateway`),
  ahead of the Claude and ChatGPT plan routes and ahead of personal keys. It is real money on a Stanford PTA: up to its
  $50 a month may go to the review, none for its own sake. Personal keys only for what the gateway cannot serve (Azure, Textract, Document AI checks;
  one Gemini 3.7-against-3.8 Flash check on the 96). The
  $7-per-item rule still applies, except W46.seg-window-modality's full 551-page sweep (approved at about $8 list /
  $4 batch). Newer gateway models need the owner to request access.
- ✅ **Benchmark uploads are authorized (owner, 2026-10-25).** The frozen 96 owner benchmark pages and 12 public pages,
  with their region and tile crops, may go to `https://aiapi-prod.stanford.edu/v1/chat/completions` (Processor Gateway
  key, Gemini 3.7 Flash); adjudicated truth text is not sent. Comparable benchmark image uploads and experiment work
  through the approved gateway proceed without another upload-permission question. Spending limits, corpus safety
  rules and the Sherlock handoff remain.
- ⛔ **Plan routes wait for the gateway (owner, 2026-10-21).** No bench or experiment arm runs a model through the
  Claude or ChatGPT plan (`claude -p`, `codex exec`, the app's Local Agent backend) until `W46.gateway-models-ok` is
  ticked; that arm then runs through the gateway, in the item's `-paid` half. Held: `W46.seg-lincoln-cloud` and
  `W46.seg-lincoln-cloud-codex` outright; the plan-route arms of `W46.ocr-regions`, `W46.date-traceable`,
  `W46.marks-detect`, `W46.ent-robust`, `W46.ent-score` and the `claude -p` voter in `W46.kit-gate` are skipped, and
  the rest of each item goes ahead (the Claude c1
  windows of 14:31 stay as results). Coding sessions (the engine running on the plan) are not arms.
- ⛔ **Cluster work runs on Sherlock; the engine prepares it, the owner's session submits it (owner, 2026-10-22).**
  Sherlock suits this project better than FarmShare, even when it is slower. FarmShare only with the owner's
  explicit approval for that run; other FarmShare mentions are history, not a route.
  **No engine session contacts Sherlock**: no SSH, scp, rsync or DTN, not even a read-only check (Sherlock's
  `/etc/agents` rules forbid agent sessions that a supervisor starts or feeds while nobody is there, even over SSH;
  `cluster-reach.py` never preflights it; `.claude/hooks/no-sherlock.sh` refuses it under `ARCHIVE_UNATTENDED=1`). The engine does the
  Mac-side work of an open `(cluster: sherlock)` item (pack, scorer, job and submit scripts against
  `ArchiveProcessor/scripts/segbench/sherlock/` — sh.env, the container wrappers, `stage-job.sh` for copies and
  downloads; `restart-20261022.sh` is the pattern — dry-run on the Mac), then hands over: submit command, job count and
  what to collect in `execution-plans/items/<TAG>.md`, the batch manifest in
  `ArchiveProcessor/scripts/segbench/sherlock/packs/`, `ops/autonomous/plan-edit.sh .maintenance/AUTONOMOUS_PLAN.md
  hold TAG 'ready to submit: <command>'`, and a Daemon Report line (no decision). The owner's session submits
  held items in batches (`execution-plans/sherlock-access.md` §"Batches"; `cluster-reach.py mark TAG submitted`),
  collects the results into `$GROUP_HOME` or the Mac, runs `mark TAG finished` and `plan-edit.sh … release TAG
  'results in <path>'`; the engine scores. FarmShare's data is on Sherlock, so a pack may already exist there: the engine never checks, it names the
  possible pack in the hand-over and the owner's session looks before one is rebuilt. File a new
  cluster item with `(cluster: sherlock)` alone. Rules for a Sherlock session:
  [`execution-plans/sherlock-access.md`](execution-plans/sherlock-access.md).
- ⛔ **Every Sherlock job is reviewed for size and necessity before it is submitted (owner, 2026-10-22).** The
  preparing session writes, in `execution-plans/items/<TAG>.md` before its hand-over: (1) the question and the route,
  default or recommendation the answer could change; (2) why results in hand do not settle it; (3) the job count and
  a GPU-hour estimate from a pilot, and why a smaller sample, split or reader set would not do (a public set's training
  split, a whole mirror or a full grid is the ceiling, not the plan); (4) the verdict, useful now or nice-to-have. The owner's session reads it before
  submitting. Focus on what is really useful now: a nice-to-have item, Sherlock or not, goes behind
  `W46.nice-to-have` (`(blocked-on: W46.nice-to-have)`; `SUITE_TODO.md` §"Nice-to-have, end of project"), which the
  owner opens once the useful work is done. W46.ocr-new-open-sherlock stays useful now: many users of the kit will
  have a cluster like Sherlock, so a cluster-only reader is a real route for them.
- ⏸ **Paid hosted benchmarking is on hold (owner, 2026-10-17).** Open-weight models first; paid hosted bench runs wait
  for `W43.sweep` at the end of the queue, behind a full price estimate. A session that defers a paid run adds a line to
  [`execution-plans/paid-runs-deferred.md`](execution-plans/paid-runs-deferred.md) in the same commit, so none is lost.
- ⛔ **Tier‑2 review, scratch‑only tests and no‑force git discipline all stand.** "No production data" means **no
  compatibility burden** — not less care, and it skips no gate.

⏸ **Related: the DEVONthink import is ON HOLD** (owner, 2026-08-01) until Notes' basic structure is settled, and **its
plans are retained in full** (an explicit exception to "delete a shipped plan"). See `SUITE_TODO.md` §"Archive Notes —
DEVONthink import". Restructuring Notes is free *now* and stops being free once 7.5 GB lands in it.

## Conventions

- **Build:** XcodeGen. `project.yml` is authoritative; the `.xcodeproj` is generated and **gitignored**
  — always `xcodegen generate` (or run the app's `bootstrap.sh`) after cloning/pulling. `brew install xcodegen`, Xcode 16, macOS 14+, Swift 6.
- **Run:** `./launch.sh reader|processor` from the root (build‑if‑stale, then launch), or `cd <app> && ./launch.sh`.
- **Per‑worktree DerivedData** (`-derivedDataPath ./build/DD`) so concurrent agents/worktrees don't collide. `build/` is gitignored.
- **Three apps, three bundle IDs** (`com.archiveprocessor.app`, `com.archivereader.app`, `com.archivenotes.app`) — never merged.
- **Signing: a local self‑signed cert, `CODE_SIGN_IDENTITY: "Archive Suite Dev"`** — **not** ad‑hoc (`"-"`) since 2026‑08‑07, still not notarized (ad‑hoc pinned the designated requirement to the **cdhash**, so every rebuild looked like a new program and macOS forgot every TCC grant). Create the identity once per machine with **[`ops/setup-signing-cert.sh`](ops/setup-signing-cert.sh)**, which carries the full rationale and the traps; key at `~/.local/share/archive-suite-signing/` — **back it up** (losing it ⇒ new cert ⇒ re‑grant every prompt). iOS stays ad‑hoc (a macOS cert is invalid there), and so does **every build inside the Tart GUI‑VM** — no keychain in the guest, so `gui-vm-gate.sh`/`vm-gui-runner.sh` pass `CODE_SIGN_IDENTITY=-`; ⛔ don't provision the cert into the VM (W28.cert‑fu1).
  ⚠️ **A self‑signed cert has no Team ID**, so `ENABLE_HARDENED_RUNTIME: YES` + **library validation** refuses Xcode 16's `<App>.debug.dylib` (*no team ≠ same team*) — the app dies at launch with SIGABRT, taking every app‑hosted test with it. Reader/Notes therefore use **Debug‑only** `com.apple.security.cs.disable-library-validation` + `com.apple.security.get-task-allow` entitlements for their app-hosted tests. Processor instead sets `ENABLE_DEBUG_DYLIB: NO` (Debug) and `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` (Release), keeping strict library validation — why: [`ArchiveProcessor/CLAUDE.md`](ArchiveProcessor/CLAUDE.md) §*Releasing*, W28.cert-fu2. **⛔ Release must contain neither debug entitlement.**
  Full record — why ad‑hoc failed, W7.1, W28.cert‑fu1: `SUITE_TODO_DONE.md` §*Signing + TCC consent*.
- **Never** hand‑edit a `.pbxproj` (edit `project.yml` + regenerate). **Never** write to a real corpus during dev/test — copy to the scratchpad first (Reader's Core Directive).

## Docs & backlog convention

**Definition of done — the docs move with the code, in the *same commit* (never a follow-up).** A change is
not done until the trackers match reality:
- flip the shipped item's `SUITE_TODO.md` checkbox to `[x]` (cite the commit) and add/close any
  `KNOWN_ISSUES.md` entry — **in the same commit as the code**, not "later";
- delete a shipped `execution-plans/` plan.

`SUITE_TODO.md` is the **tracker of record.** An unattended/autonomous run must **reconcile it before it
ends**; a private plan/progress file (e.g. an overnight plan) never stands in for it — sync the real
tracker, not just your scratch notes. **The owner should never have to catch a stale checkbox** — doc-sync
is part of the change, full stop.

Three tiers, so nothing sprawls or goes stale:
- **Near-term work → `SUITE_TODO.md`** (root) — the single live to-do queue, **OPEN items only**; it also **indexes the active execution plans** (below).
- **Completed work → `SUITE_TODO_DONE.md`** (root) — when an item ships, **move its whole entry there**, **appended at the END** (header line names its section as `· §<section>`, last line `  <!-- /<TAG> -->`), instead of ticking it in place (2026-08-01: 47 open items were buried among 160 done ones in one 3,580-line file). Doc-sync is unchanged — the move still happens in the same commit as the code. Kept rather than deleted because the entries cite the commits that shipped them and often carry *why* a later change may or may not revisit that code. **Append-only, with `merge=union` in `.gitattributes`** (`W35.done-union`, 2026-10-08) so two workers finishing at once never conflict — safe only because no existing line is ever edited; the unique last line stops union fusing two entries that end alike. ⚠️ `next-queue-item.sh` and `check-tracker-sync.sh` both read it; don't rename it without them.
- **Long-term ideas → each app's `POTENTIAL_FEATURES.md`** — the durable wishlist tier.
- **In-flight progress notes → `execution-plans/items/<TAG>.md`** — checkpoint notes, session notes and saved-draft branches for one open item, written by its claimant; the `SUITE_TODO.md` entry carries only a pointer line, never the notes (they made that shared file a rebase-conflict hotspot). Deleted when the item ships, useful lines folded into its `SUITE_TODO_DONE.md` entry. Detail: `ops/autonomous/README.md` §L2.
- **Short-term execution plans → `execution-plans/`** (root) — one detailed plan per in-flight feature, tracked from `SUITE_TODO.md`; **delete a plan once its feature ships** (git keeps the history). Don't let shipped plans linger.

Reference/authoritative material lives in each app's `CLAUDE.md` (with an **Implementation Map**), `README.md`, `AGENTS.md`, `KNOWN_ISSUES.md`, and test procedures; canonical cross-app contracts live in `SPEC/` (`tag-format.md`, `relay-object-format.md`). **Owner grants on gated paths live in [`OWNER_AUTHORIZATIONS.md`](OWNER_AUTHORIZATIONS.md)** — committed on purpose (moved out of the gitignored maintenance plan 2026-08-01) because a grant plus its ⛔ constraints is durable policy that needs history and recoverability; entries there are a permanent record, marked discharged when the item ships rather than deleted. Don't keep a doc "just because" — fold durable bits into these and drop the rest. Untracked scratch docs that are done/superseded (e.g. completed-run review reports) are archived under the gitignored **`old/`** folder (see `old/README.md`) rather than deleted — recoverable, out of the way.

**Owner review sessions.** Owner, 2026-10-15: before any session the owner runs by hand (a guided session, an acceptance pass, a review
sheet), judge whether it is the right time, by reading the open work rather than checking that the blockers are
ticked. It is not time while a known defect would get in the way, or while queued work is about to change what
the review looks at. If it is not time, name what it waits for, block the item on that, and report it (no
decision). Authority: `~/Claude/CLAUDE.md`, "Owner review sessions"; this project's detail is `execution-plans/verification-phase/01-daemon-plan.md` §G "Is it time?".

**Owner check sheets point at the text (owner, 2026-10-21).** A sheet that asks the owner to judge text against a
page image (OCR truth checks, blind re-adjudications, transcription disputes) draws a rough box on the image around
each place, from the word or line coordinates of whichever route has them. A place with no coordinates gets a
fallback that still narrows the search (the line, or how far through the page it falls), and the sheet says so.
A box never reveals which reading is the current truth. The pattern is W46's blind sheet
(`ArchiveProcessor/scripts/segbench/ocr_truth_bias.py`, commit 938bdccf).

**ArchiveOCRBench stays current (owner, 2026-10-15).** `ArchiveOCRBench/` is the readable record of what the
bench has measured. A change that commits a measured OCR or segmentation result updates it in the same commit.
That covers a new or rerun panel, a new route or model, a measured price, speed or memory figure, a segmentation
approach scored on the locked boxes, and results such as the Mac-local and FarmShare runs. Point `build.py` at the
result file, or put hand-entered figures in `ArchiveOCRBench/data/` with their source, extending `build.py` and the
page where a new kind of result needs it; then run `python3 ArchiveOCRBench/build.py` and commit the built files.
An estimate goes in only labelled as one, as Sonnet's API price is. Figures from the Vision OCR lab, a separate
repository, go in by hand with its file and commit when an item or the owner points at them
(`data/vision-ocr-handwriting.json` is the pattern). The published copy of the page is republished only by an
interactive session; an unattended one says in its commit body that the published copy is now behind. How to rebuild and read it: [`ArchiveOCRBench/README.md`](ArchiveOCRBench/README.md). Every measured route goes on every chart its data supports (owner, 2026-10-21;
the README's "Completeness rule"), kept light rather than perfect.

**Both OCR sets, every time (owner, 2026-10-20).** A model tested on the 895-page public set is also run on the
owner's 96 truth pages, with the same settings, in the same item. The 96 are the owner's own material and are what
the bench page's first charts show, so a model scored only on the public set is missing from the comparison that
matters most. A run that cannot do both says why in its commit body and files the missing half.

## Working directive — token-efficient feature-add & maintenance

Treat context/token cost as a real budget alongside speed and correctness. Applies to every change in
this repo:

- **Right-size agents.** Delegate broad searches / multi‑file sweeps / independent authoring to
  subagents so the main thread keeps the *conclusion*, not file dumps. Don't spawn an agent (or re‑run
  a search you already delegated) for a single known‑location lookup. **Big `Workflow` fan‑outs are the
  biggest token sink** — scope them tightly, size the fleet to the remaining budget, and prefer
  accumulating heavy multi‑agent jobs (adversarial reviews, wide audits) to run **autonomous/unattended**
  rather than firing them inline while interactive.
- **Read narrowly.** Scoped reads, `grep`/Explore to locate, `git log -- <path>` scoped to a subdir.
  Don't load whole files, or the *other* app, when a change touches one.
- **Structure shrinks context.** Per‑app guides with a tight **Implementation Map**, small files, ownership
  lanes (`AGENTS.md`) and one shared spec: a change loads *one app + one spec*. No duplicated prose across docs.
- **Batch & cache.** Independent tool calls together; surgical `Edit`s over full rewrites.
- **Guardrail:** efficiency never overrides correctness or the Reader Prime Directive (file safety).
  When they conflict, quality wins — but take the cheapest path that fully meets the bar.

## Releasing (the combined DMG)

- **Versioning (D3):** the **Suite** has its own release line, tagged **`suite-vMAJOR.MINOR.PATCH`**
  (starting `suite-v1.0.0`). Each app keeps its own independent internal version. *Note:* the bare
  `vX.Y.Z` tags in this repo are **Archive Processor's historical app tags** (v1.0.0–v3.8.2), carried
  in with its history — that's why Suite releases are `suite-`‑prefixed (a bare `v1.0.0` already exists).
- **Build + DMG:** `release/build-suite-dmg.sh <ver>` — Release‑builds all three macOS apps, stages
  all `.app`s + one `Applications` symlink + the "drag here" background, and produces
  `/tmp/ArchiveSuite-<ver>.dmg`. The `.dmg` is a build artifact — **never commit it**.
- **Publish:** `/opt/homebrew/bin/gh release create suite-v<ver> /tmp/ArchiveSuite-<ver>.dmg --repo charlesapetersen/Archive-Suite --title "Archive Suite <ver>" --notes "…"`.
  ⚠️ Use the **full path** `/opt/homebrew/bin/gh` — a shadowing Python tool named `gh` is first on PATH and fails.
- Cut DMG/GitHub releases sparingly; push commits frequently.

The two repos were merged into this monorepo and Archive Suite v1.0.0 shipped (see `git log` for the
record). De‑nesting shipped (`7706368`); `packages/ArchiveCore` shipped in the W0 refactor
(`49c0162`–`b90800f`).

## ⚠️ The history was rewritten when this repo went public (2026‑08‑12) — every SHA before then changed

All 1,017 earlier commits were rewritten with `git-filter-repo` (`W29.pub1`–`pub3`). **A commit hash cited in an
older doc will not resolve**: it is historically accurate and deliberately left alone, so don't "fix" it and don't
treat a failed `git show <old-sha>` as corruption; find the commit by its message or `git log -S`. `git log`
blames one identity for everything: the rewrite merged two spellings of one author, it did not squash history. Any old clone or
worktree is on an unrelated history: re‑clone rather than merge.

The pre‑rewrite history is a local bundle **outside the repo**:
`~/Claude/Long term storage/Preserved Bundles/archive-suite-full-backup-2026-08-11.bundle` (**quote the path** — it has
spaces; older docs quote its pre-2026-08-13 path in `~/Claude/`). **⛔ Never push it, commit it, or merge from it**: it is the un‑scrubbed history and is treated as
credential‑bearing: it held an OAuth client secret (since deactivated), and the next thing to land in a planning
doc might not be dead. `.gitignore` refuses `*.bundle` only inside this checkout; its real protection is living
outside it. It is a read‑only archive, not a remote. What changed in the rewrite, the bundle's reference facts
and how to read it: [`REFERENCE.md`](REFERENCE.md) §"The history rewrite — the full record".
