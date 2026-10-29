# Archive Suite — reference detail for the root guide

Reference detail moved out of `CLAUDE.md` by W40.docs-startup-size (2026-10-29), so that every session does not load
it. `CLAUDE.md` holds the rules and is authoritative where the two differ; this file keeps the full wording, history
and cases behind them. Read it on demand.

## No production material — the full record

The section as it stood in `CLAUDE.md` before the trim, verbatim.

### There is no production material yet — what that relaxes, and what it does not

**Owner directive, 2026-08-01.** No app in this suite has produced data he intends to keep: Notes holds only
test material, the Processor has produced no files, and **the entire corpus predates these apps**. Nothing
depends on the apps' current settings, structure or outputs.

**So stop designing for continuity.** These are *not* constraints here:
- **No migration paths** — legacy on‑disk formats (old staging manifests, old `PendingRun` shapes, old note
  front‑matter) need no reader. Change a schema; don't version it.
- **No backward‑compatible parsing** — a link/tag/PDF format may change shape outright.
- **No inert‑legacy carve‑outs** — rules that exist to avoid disturbing already‑written app output are moot.
- **Settings and structure are free to change.** Prefer the right end state to the compatible one, and say in
  the commit that no migration was written *because there is nothing to migrate*.

**What is UNCHANGED — the directive is about app *output*, not about inputs or money:**
- ⛔ **The real corpus stays sacred.** `~/Desktop/Google Drive/Archival Photos/` (~102k PDFs) is irreplaceable
  and predates the apps — which is exactly *why* it isn't app output. The Reader's Core Directive and
  scratch‑copy‑only testing are untouched.
- ✅ **Money paths NO LONGER need a per-item owner grant (owner, 2026-08-13).** *"We don't need my permission
  for spending money. The daemon only spends tiny amounts and the keys are capped."* This reverses the bullet
  that stood here — kept below, struck through, because it was emphatic and a later reader will otherwise
  assume this file drifted. What is **removed** is the *authorization gate*: a money-touching item no longer
  waits on a named entry in `OWNER_AUTHORIZATIONS.md`. What **stands** is the cost discipline in each app's
  guide — cheapest capable model, smallest input set that proves the behaviour, and say what a run will cost
  before a big one. Not-permission, but not a blank cheque either. See §*Gating baseline* in
  [`AGENTS.md`](AGENTS.md).
- ⛔ **But $7 is the ceiling without asking (owner, 2026-10-11; raised from $3 on 2026-10-28).** Never spend more than $7 of real money on one
  piece of work (an item across all its sessions) without asking him first. Subscription usage is not money. Over
  $7, an unattended session asks in the Daemon Report and moves on. The rule's authority is `~/Claude/CLAUDE.md`,
  section "Spending money".
- ✅ **The W46 processing review's paid arms are released (owner, 2026-10-21).** The hold below no longer covers the
  review's items (`execution-plans/processing-review/10-gap-audit.md` §5). Route order: the **Stanford AI API gateway**
  first (`https://aiapi-prod.stanford.edu/v1`, the Processor's gateway key in Keychain, account `Gateway`), ahead of the
  Claude and ChatGPT plan routes and ahead of personal keys. The gateway is real money on a Stanford PTA, not the
  owner's: up to its $50 a month may go to the review, but none is spent for its own sake. Personal keys only for what
  the gateway cannot serve (Azure, Textract, Document AI checks; one Gemini 3.7-against-3.8 Flash check on the 96).
  The $7-per-item rule still applies to each item, except W46.seg-window-modality's full 551-page sweep, approved at
  about $8 list / $4 batch. Newer gateway models need the owner to request access; on 2026-10-21 the key had only
  older ones (Gemini 2.0 Flash/2.5 Pro, Claude 4.5 Sonnet/Opus 4.6, GPT-5/5.2), not Gemini 3.7 Flash, Claude 5
  Sonnet, GPT 5.6 Luna or GLM 5.3 Flash.
- ✅ **Benchmark uploads are authorized (owner, 2026-10-25).** The owner approved sending the frozen 96 owner
  benchmark pages and 12 public pages, including their region and tile crops, to
  `https://aiapi-prod.stanford.edu/v1/chat/completions` using the Processor Gateway key and Gemini 3.7 Flash,
  starting with the eight-page cost pilot; adjudicated truth text is not sent. His standing direction was:
  "Approve this upload and this work generally. There's no need to check in with me for this kind of thing."
  Comparable benchmark image uploads and experiment work through the approved gateway proceed without another
  upload-permission question. The existing spending limits, corpus safety rules and Sherlock handoff remain.
- ⛔ **Plan routes wait for the gateway (owner, 2026-10-21).** No bench or experiment arm runs a model through the
  Claude or ChatGPT plan (`claude -p`, `codex exec`, the app's Local Agent backend) until `W46.gateway-models-ok` is
  ticked; that model's arm then runs through the gateway, in the item's `-paid` half. The Phase 3 queue was filed
  with $0 plan-route arms in its free halves; those arms are held, and the rest of each item (open models, cached
  replies, scorers) goes ahead. Held 2026-10-21: `W46.seg-lincoln-cloud` and `W46.seg-lincoln-cloud-codex` wait on
  the gate outright (their Claude c1 windows of 14:31 stay as results; the live c2 runs were stopped); the plan-route
  arms of `W46.ocr-regions`, `W46.date-traceable`, `W46.marks-detect`, `W46.ent-robust`, `W46.ent-score` and the
  `claude -p` voter in `W46.kit-gate` are skipped. Coding sessions themselves (the engine running on the plan) are not
  arms and are unaffected.
- ⛔ **Cluster work runs on Sherlock; the engine prepares it, the owner's session submits it (owner, 2026-10-22).**
  Sherlock suits this project better than FarmShare, even when it is slower. FarmShare is used only with the owner's
  explicit approval, given for that run; any other mention of FarmShare in this file, the queue or a plan is history,
  not a route. Sherlock's `/etc/agents` rules forbid agent sessions that a supervisor starts or feeds while nobody is
  there, even over SSH, so **no engine session contacts Sherlock**: no SSH, scp, rsync or DTN, not even a read-only
  check (`cluster-reach.py` never preflights it). The engine does an open `(cluster: sherlock)` item's Mac-side work:
  the pack, the scorer, and job and submit scripts against `ArchiveProcessor/scripts/segbench/sherlock/` (sh.env, the
  container wrappers, `stage-job.sh` for copies and downloads; `restart-20261022.sh` is the pattern), dry-run on the Mac.
  It then stops and hands over: the exact submit command, the job count and what to collect go in
  `execution-plans/items/<TAG>.md`, its batch manifest in `ArchiveProcessor/scripts/segbench/sherlock/packs/`, `ops/autonomous/plan-edit.sh .maintenance/AUTONOMOUS_PLAN.md hold TAG 'ready to
  submit: <command>'` takes the item off the queue, and a Daemon Report line (no decision) names it. An owner-started
  session submits held items in batches (execution-plans/sherlock-access.md §"Batches"; runs `ops/autonomous/cluster-reach.py mark TAG submitted`), later collects the
  results into `$GROUP_HOME` or the Mac, then runs `mark TAG finished` and `plan-edit.sh … release TAG 'results in
  <path>'`, and the engine scores them; the queue never offers a Sherlock item marked `submitted`. Under
  `ARCHIVE_UNATTENDED=1`, `.claude/hooks/no-sherlock.sh` refuses any command naming Sherlock's hosts or its socket. Rules for a Sherlock session:
  [`execution-plans/sherlock-access.md`](execution-plans/sherlock-access.md). The 32 FarmShare jobs pending that morning
  were cancelled (ids in `~/cancelled-20261022.txt` on FarmShare) and rerun on Sherlock from their staged packs; FarmShare's
  data is on Sherlock, so a session looks for a pack there before rebuilding one. A new cluster item is filed with
  `(cluster: sherlock)` alone.
- ⛔ **Every Sherlock job is reviewed for size and necessity before it is submitted (owner, 2026-10-22).** The
  preparing session writes a review in `execution-plans/items/<TAG>.md` before its hand-over, and the owner's session
  reads it before submitting: (1) the question the run answers and the app route, default or recommendation the
  answer could change; (2) why the results already in hand do not settle it; (3) the job count and a GPU-hour estimate
  from a pilot, and why a smaller sample, split or reader set would not answer the question (a public set's training
  split, a whole mirror or a full grid is the ceiling, not the plan); (4) the verdict, useful now or nice-to-have.
  Focus on what is really useful now: a nice-to-have item, Sherlock or not, goes behind `W46.nice-to-have` in
  `SUITE_TODO.md` §"Nice-to-have, end of project" (`(blocked-on: W46.nice-to-have)` in the plan), which the owner
  opens once the useful work is done. Cases: W46.seg-openpss was filed as the whole 141,668-page mirror and
  W46.capture-ladder-sherlock as a 360-GPU-hour grid; both were cut down, then deferred with W46.seg-tabme and
  W46.ocr-new-open-gold. W46.ocr-new-open-sherlock stays useful now: many users of the kit will have a cluster like
  Sherlock, so a cluster-only reader is a real route for them.
- ⏸ **Paid hosted benchmarking is on hold (owner, 2026-10-17).** Open-weight models on FarmShare first; paid hosted
  bench runs wait for `W43.sweep` at the end of the queue, behind a full price estimate. A session that wants a paid
  run and defers it adds a line to [`execution-plans/paid-runs-deferred.md`](execution-plans/paid-runs-deferred.md)
  in the same commit, so none is lost.
- ~~⛔ **Money paths are unchanged.** Stranding a live paid batch costs real money regardless of whether any
  output matters (the W16 `bat3`/`bat5`/`bat2-fu2` work is framed around money, not data).~~ *(superseded
  2026-08-13, above.)*
- ⛔ **Tier‑2 review, scratch‑only tests and no‑force git discipline all stand.** "No production data" means
  **no compatibility burden** — it does not mean less care, and it does not skip a gate.

⏸ **Related: the DEVONthink import is ON HOLD** (owner, 2026-08-01) until Notes' basic structure is settled —
and **its plans are retained in full**, an explicit exception to the "delete a shipped plan" rule below. See
`SUITE_TODO.md` §"Archive Notes — DEVONthink import". Restructuring Notes is free *now* and stops being free
once 7.5 GB lands in it.

## The history rewrite — the full record

The section as it stood in `CLAUDE.md` before the trim, verbatim.

### ⚠️ The history was rewritten when this repo went public (2026‑08‑12) — every SHA before then changed

**Nothing in `git log` older than the publication commit has the hash it originally had.** The repo was
private until 2026‑08‑12; making it public meant rewriting all 1,017 commits with `git-filter-repo`
(`W29.pub1`–`pub3` in [`SUITE_TODO_DONE.md`](SUITE_TODO_DONE.md)). Four things changed across the whole
history: author/committer identity → a GitHub noreply address; hardcoded home paths, the old account name
and the GCP project number → placeholders; five committed `.dmg` build artifacts → removed; and two
superseded planning docs deleted outright. Two commits that held nothing but a `.dmg` disappeared with it.

**Consequences to expect, none of them bugs:**

- **A commit hash cited in an older doc will not resolve.** `SUITE_TODO_DONE.md`, `KNOWN_ISSUES.md` and the
  per‑app guides quote pre‑rewrite SHAs in their hundreds — `7706368`, `49c0162`–`b90800f` in the paragraph
  directly above, and so on. They are *historically accurate* and deliberately left alone; they simply name
  objects that no longer exist under those names. Don't "fix" them, and don't treat a failed
  `git show <old-sha>` as repo corruption. Find the commit by its message or by `git log -S` instead.
- **`git log` blames one identity for everything.** The rewrite collapsed two spellings of the same author
  into one; it does not mean the history was squashed.
- **Any old clone or worktree is on an unrelated history.** `git pull` into one will not fast‑forward.
  Re‑clone rather than trying to merge.

#### The pre‑rewrite history is preserved — as a local bundle, never in this repo

The original history is kept as a git bundle **outside the repo, untracked and unpublished**:

```
~/Claude/Long term storage/Preserved Bundles/archive-suite-full-backup-2026-08-11.bundle
```

Moved there 2026-08-13 from `~/Claude/`, the path older docs quote. **The path contains spaces — quote it in
every command.** Verify: `git bundle verify "<path>"` from inside a repo; read: `git clone --bare "<path>"
/tmp/as-original`. Its SHA-256, size and contents: `SUITE_TODO_DONE.md` §"Pre-rewrite bundle — reference facts".

**⛔ Never push it, commit it, or merge from it.** It is the *un‑scrubbed* history, so it still carries the
personal email addresses, home‑directory paths, the old account name, the GCP project number, and — the
reason this warning is emphatic — an **OAuth client secret** in a since‑deleted execution plan. The owner
**deactivated** that credential on 2026‑08‑12 and replaced it on 2026‑08‑13 (`W29.drive-secret`), so the
one in the bundle is dead. The bundle is nonetheless why this file says "treat it as credential‑bearing" rather
than "it's just old commits": the next thing to land in a planning doc might not be dead. `.gitignore`
refuses `*.bundle` so a stray copy inside the checkout cannot be committed by accident, but that guard only
covers this directory — the file's real protection is living outside it.

Use it to answer "what did this look like before?" — resolving an old SHA a doc cites, or recovering a
removed `.dmg`. It is a read‑only archive, not a remote.
