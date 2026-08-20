# Archive Suite — working to-do queue

The **near-term** to-do queue for both apps (see root `CLAUDE.md` §Docs & backlog convention). Long-term
ideas live in each app's `POTENTIAL_FEATURES.md`; detailed in-flight plans live in `execution-plans/`
(indexed below, deleted when shipped). Full-codebase review: the paced method in `REVIEW.md`. Unattended /
autonomous runs: `ops/autonomous/README.md` (durable plan → self-resume daemon), which drains this queue one
bounded item per fresh session.

**This file holds only OPEN items.** Completed work moves to [`SUITE_TODO_DONE.md`](SUITE_TODO_DONE.md) —
2026-08-01, when 47 open items were buried among 160 done ones in a single 3,580-line file. When you finish an
item, **move its whole entry there** (under its section heading) rather than ticking it in place; the
completion note and its commit still belong in the same commit as the code, exactly as before.
⚠️ Two scripts read the archive and will mis-report if it is renamed or moved without them:
`ops/autonomous/next-queue-item.sh` (a `(blocked-on: …)` prerequisite archived there must still resolve as
done, or its dependents block forever) and `ops/autonomous/check-tracker-sync.sh` (which treats live + archive
as one logical tracker — comparing only this file made the drift it exists to catch invisible).
Paths repo-root-relative; Reader source = `ArchiveReader/macOS/Sources/ArchiveReader/`,
Processor source = `ArchiveProcessor/macOS/Sources/ArchiveProcessor/`.

Legend — effort S/M/L · risk low/med/high · **needs:** none | gui (drive app at runtime) | owner
(account/manual) | corpus-write (safety-sensitive).

## ⭐ PRIORITY ORDER lives in the plan, not in this file's section order (reset 2026-08-16)

**The section order below carries NO priority meaning.** Work order is the `### TIER 0…6` blocks under
`## WORK QUEUE` in `.maintenance/AUTONOMOUS_PLAN.md`, which is also what `next-queue-item.sh` reads
top-to-bottom. This file stays the tracker of record for *detail*; the plan holds the *order*. One place
each, so they cannot drift.

**Why it was reset (owner, 2026-08-16).** Three superseded schemes had stacked up here and every one of them
had decayed: the `P0`/`P1`/`P2` buckets (2026-07-09), the `⭐ TOP PRIORITY — pre-flight for a 2-week
unattended run` banner (2026-07-16), and `Wave 23 — TOP OF THE DRAIN` (2026-07-29). Nine headings held zero
items and zero prose; the ⭐ banner was empty while pointing at nothing; Wave 23's "drains first" outlived its
own condition, which this repo's `CLAUDE.md` records as MET on 2026-08-01. Meanwhile the plan's queue had the
**newest and highest-consequence items last**, because they were appended: a session would have worked six LOW
Wave-23 follow-ups before reaching `W30.dr-walkthrough-anchor`, the one open item that can permanently lose a
decision the owner is owed. The dead headings are deleted; the ones that still carry a completion record are
left alone.

**The premise it was set on:** no app in the Suite is in use until all of this work is done, and all four
eventual uses are in scope (bulk OCR · Notes + Zotero · Reader triage · phone capture). So no use case ranks
the work; irreversibility, honest gates and verification leverage do. The reasoning is written out in full at
the head of the plan's `## WORK QUEUE` — read it there before re-ordering anything.

## Processor build/test gate follow-up (found 2026-08-12)

- [ ] **`W28.cert-fu3` — the default daemon gate cannot detect a signed Processor build that aborts before
  `main` [XS–S · LOW · blind gate] (blocked-on: W21.recovery-timeout).** The gate's free Processor lane ends
  after `xcodebuild`; that command was green throughout W28.cert-fu2 even though the product could not launch.
  The recovery driver is a scratch-only, no-OCR launch probe, but its current fixed 60-second deadline has an
  independently queued headroom defect. After W21.recovery-timeout ships, give the default gate a bounded
  Processor launch step using the just-built gate artifact (not stale `build/DD`), and prove it catches a
  pre-`main` abort without enabling the paid OCR lane or reaching the host GUI. | ops/autonomous/health-gate.sh + ArchiveProcessor/scripts/test-recovery.sh | S | risk low

- [ ] **`W21.e2e-fu2` — the test-only LAN READY line still publishes the six-character Drive-relay token
  after W16.lan2 split the LAN credential [XS · MED · lying test seam] — Tier-2.**
  `CaptureSession.serverDidStart` writes `token` under `LIVECAPTURE_AUTOSTART`, but `CaptureServer` now
  authenticates the 32-character `lanToken`; the E2E therefore reaches the Mac and receives HTTP 401 before
  any upload. W21.e2e-fu1 works around the stale seam in its script by reading the persisted LAN token.
  Correct the source READY line to publish `lanToken`, keep the file-relay READY line on `token`, and add a
  regression proof that distinguishes the two credentials. **Tier-2** because the seam lives in `Capture/` —
  adversarial review + a functional test, scratch only. (This carried a **HOLD** for a per-item authorization
  until 2026-08-13, when that requirement was lifted; the grant recorded in `OWNER_AUTHORIZATIONS.md` still
  binds its constraints: the file-relay READY line stays on `token`.) | ArchiveProcessor/macOS/Sources/ArchiveProcessor/Capture/CaptureSession.swift + recovery driver | XS | risk med | Tier-2

## Autonomous daemon — handoff integrity (2026-08-13)

- [ ] **`W21.seed-fu` — the Keychain partition fix does not cover `DriveClientSecret`, and "Always Allow" is
  per-ITEM, so a later-added credential silently re-prompts [S · MED · ops].** Filed 2026-08-13 from working
  `W21.seed`. Two facts learned by doing it, neither of which was written down:
  **(a) It is not one click.** The item said "click Always Allow on the login-Keychain prompt" (singular). The
  owner got one prompt at launch and then **five more just to open Settings** — the ACL is per keychain ITEM and
  `SettingsView` eagerly reads every provider credential. So the cost of an unseeded machine is ~6 modal prompts,
  and an UNATTENDED session that opens Settings would hang on the first one rather than fail loudly.
  **(b) ~~`fix-keychain-access.sh` omits `DriveClientSecret`~~ — WITHDRAWN 2026-08-13, the omission is CORRECT
  and deliberate.** Filed in error and corrected within the hour, before any code changed. The comment
  immediately above `CANDIDATES` (`:23-24`) states the reasoning: *"Non-provider items (Drive secrets, gateway
  config) are left alone: the CLI never reads them, so touching their partition lists would risk an app
  re-prompt for no gain."* The partition-list fix exists so **scripts** reading a key through `/usr/bin/security`
  do not prompt; `DriveClientSecret` is read by the **app**, which created the item and therefore already owns
  it. Adding it would have risked causing the very re-prompt the finding claimed to prevent. **Do not "fix"
  this.** Recorded rather than deleted because the wrong version of this finding is plausible enough to be
  re-derived by the next reader of that `CANDIDATES` line.
  **(c) The one real residue:** the script's own `:72` comment says the marker is recorded *"so daemon.sh can
  warn if a NEW key (e.g. an OpenAI key added later) is"* added — and no such warning exists. The marker reads
  `2026-07-17 | Gemini Anthropic Mistral` while `CANDIDATES` lists five, so a provider key added since is
  invisible. Have `daemon.sh` compare the marker against the provider accounts actually present and warn on a
  new one. Also correct the `W21.seed` wording wherever it survives, so the next machine is told to expect ~6
  prompts, one per credential, not one.
  | ops/autonomous/fix-keychain-access.sh, daemon.sh | S | med | none

- [ ] **`W31.handoff-fp` — three ways `check-handoff.sh` can still report CLEAN while something is wrong
  [S–M · MED · ops].** Filed 2026-08-13 from the adversarial review of the script itself. The CRITICAL it also
  found (a no-upstream worktree's unpushed commits reading as "clean") is FIXED in `e056eef`; these three are
  real, understood, and deliberately NOT fixed yet because each needs a design call rather than a patch:
  **(a) Step 3 reads the PRIMARY checkout's `SUITE_TODO.md` and plan, but the Usage line invites you to run the
  script from a worktree.** So the exact failure step 3 exists for — filing a `-fu` and not mirroring it — passes
  green when the filing is still uncommitted in your own worktree, which is when you would run it. Fixing it is
  not just swapping the path: the plan is gitignored and lives ONLY in the primary, so the two halves of the
  comparison legitimately come from different trees. Probably: read `SUITE_TODO` from `$TREE` and the plan from
  the primary, and say so in the output.
  **(b) Step 3 prints its green line when ZERO SUITE_TODO items parse.** An empty or unparseable tracker yields
  an empty "missing" set, which reads as success. Needs a floor ("expected >= N open items") — and reaching an
  overall CLEAN that way needs a second fault, since `check-tracker-sync.sh` missing is only a `warn`.
  **(c) A failed `git fetch` and a missing `origin/main` are warnings only,** so step 2's single assertion — the
  primary is level with the remote — can go unmade while the run still reports CLEAN. Offline is a legitimate
  state, so the call is whether "handed off" should be *possible* offline. Suggest: FAIL, with an explicit
  `HANDOFF_OFFLINE=1` escape.
  Also worth doing while in there: the exemption key is an item's first WORD (`Import`), so a second bullet
  starting with the same word would be silently swallowed — first-occurrence-wins. | ops/autonomous/check-handoff.sh | S–M | med | none

- [ ] **`W31.handoff-fp2` — an item whose first character is not alphanumeric is invisible to BOTH tracker
  guards, and neither can report it [XS–S · MED · ops].** Found 2026-08-16 by the priority reset, which is
  also how it was proved: `check-handoff.sh` printed *"every open SUITE_TODO item has a checkbox line in the
  plan"* while `**(later)** behavior/data follow-ons` (now `W33.storage`) had **no line in the plan at all**.
  Mechanism: both `check-handoff.sh:134` and the identical grammar in `check-tracker-sync.sh` strip bold and a
  leading backtick, then require `^[A-Za-z0-9][A-Za-z0-9._-]*`. A leading `(` — or any other punctuation —
  makes `match()` fail, so `emit()` prints nothing and the item never enters either side of the comparison.
  This is **not** the same as the three paths in `W31.handoff-fp`: those are checks that pass on a bad state;
  this is an item that cannot be seen at all, which is strictly worse, because the "missing" set it should
  land in is computed by set difference and an absent element can never appear in one.
  **Fix:** emit a distinct `⚠️ UNPARSEABLE ITEM` line (with the offending text) rather than silently skipping,
  in both scripts, and count it as a `fail` in `check-handoff.sh`. That is better than widening the grammar to
  accept punctuation — a bullet with no tag cannot be mirrored, `blocked-on`-resolved or archived either, so
  the right outcome is to be told to give it a tag. Add the case to `prove-tracker-sync.sh` and to
  `prove-handoff.sh` when `W31.handoff-gate` creates it. ⚠️ Do NOT close `W31.handoff-fp` (b) — its
  "expected >= N open items" floor is the backstop that would have caught the aggregate drift; this is the
  per-item cause. | ops/autonomous/check-handoff.sh, check-tracker-sync.sh | XS–S | med | none

- [ ] **`W31.handoff-gate` — make the handoff gate a *gate*: wire `check-handoff.sh` into `health-gate.sh`,
  and stop new items being filed without a plan mirror [S–M · MED · ops].** Filed 2026-08-13 by the
  pre-restart readiness audit. `ops/autonomous/check-handoff.sh` **exists and passes** as of that date, but
  nothing runs it automatically, so it only helps an agent who remembers to type it — the same weakness as
  the prose checklist it replaced.
  **Root cause it exists to close, and the attribution matters:** the audit found **27 open `SUITE_TODO`
  items with no checkbox line anywhere in `.maintenance/AUTONOMOUS_PLAN.md`** — unreachable by
  `next-queue-item.sh`, and invisible to `check-tracker-sync.sh` too, because that guard compares the items
  the two files SHARE and so cannot see one that is missing from a file entirely. `git log -S<tag> --
  SUITE_TODO.md` on all 27 put **every one in a commit in this project's own convention** (`fix(notes):
  W23.m14 — …`, `fix(ops): two status lines that lied`, `docs(trackers): …`) — three from `c0be2cc` alone,
  two from `763eade`. So this is **not** an external-agent problem: it is what happens when a session closes
  a parent item, files the `-fu` it just found, and does not mirror it. All 27 were routed on 2026-08-13
  (15 daemon-buildable → `## WORK QUEUE` with the Wave-23 block first, 8 owner-gated → `## HOLD QUEUE`,
  4 umbrella items → the queue tail), and the held-back count corrected 5 → 13.
  **Two halves.** (a) Add a `handoff` step to `health-gate.sh` calling `check-handoff.sh` — ⚠️ **Tier-2 per
  the autonomous-setup change discipline** (adversarial review + prove-the-mechanism before install), plus a
  `prove-handoff.sh` in `ops/autonomous/tests/` alongside the other 15 proofs; mind the spaced-path hazard
  (the gate only ever runs at `…/Archive Suite`, so quote every expansion — `W26.gatepath`). Note the check
  FAILS on an uncommitted worktree, which is correct for a handoff but wrong for a mid-session gate, so it
  needs a mode flag or the gate must call only the tracker-visibility half. (b) Consider making
  `check-tracker-sync.sh` itself assert set-EQUALITY rather than agreement-on-the-intersection, which would
  have caught all 27 at the first health gate after each was filed. | ops/autonomous/ | S–M | med | none

## Autonomous daemon — document budgets (owner, 2026-08-12)

## Reader test hardening (owner-reviewed 2026-07-18)

- [ ] **`W29.t2-fu1` — let `SnapshotTests` run in the GUI VM.** It skips there today because the reference
  can only be recorded on the host: the guest mounts the repo read-only and the test host is sandboxed, so
  a recording write fails outright (`W29.t2`). The fix is the trick `vm-gui-runner.sh`'s `collect_shots`
  already uses for screenshots — have the test record into the guest's own tmp, print
  `[shot] <name>: wrote <path>`, and let the (unsandboxed) `tart exec` copy it back to `__Snapshots__/`.
  Then the VM becomes the reference machine and the skip inverts to the host. Worth doing only if
  reference-image coverage in automation is wanted; `RenderProbe`/`DocumentRenderGuardTests` already give
  automation reference-free pixel guards. | Reader | M | risk low | **needs:** none

## 🎯 Project focus & ON-HOLD areas (owner, 2026-07-09)

**Focus now:** the **wired (USB) + wireless (LAN/Wi-Fi) phone↔Mac transmission** path and the **Android**
companion — plus the core Mac pipeline (OCR/tag/PDF/finalize) and the Reader, which continue as normal.

**ON HOLD — maintain-only** (mirror shared-contract changes so they don't rot, but **no new feature
development, and NOT a code-review or bug-fix target**; keep them compiling — **except the iOS companion,
now fully PARKED, see below**):
- **iOS companion** — `ArchiveProcessor/ArchiveCaptureiOS/`. **PARKED 2026-07-18 — stronger than
  maintain-only: its full-app build is now OUT of the verify loop** (iOS simulator runtime removed to
  reclaim ~18 GB — see `ArchiveCaptureiOS/PARKED.md`). Source retained and still gets shared-contract
  edits; parity is auto-checked via `scripts/test-relay-golden.sh` (host `swiftc`, no runtime needed), so
  it can't rot. Reviving = reinstall a simulator runtime + restore its build line (steps in PARKED.md).
- **Cloud (Google Drive) relay transport** — Mac `Net/{DriveObjectStore,DriveClient,DriveAuth}.swift` + the
  `FileRelayReceiver`/`RelayObjectStore` cloud path (incl. the offline `FileRelay` stand-in); both companions'
  `DriveRelayTransport`/`DriveAuth`/`DriveClient`. The `RelayObjectFormat` wire contract stays frozen — only
  mirror it if a focused change forces it.

*Maintain-only* means: if a protocol/SPEC change on the focus path (LAN/USB, Android) requires it, mirror the
minimum into iOS/cloud so they still build — but don't invest effort or reviews there. **Code reviews + fixes
concentrate on:** LAN transport (`Net/CaptureServer.swift`, `CaptureReceiver`, non-Drive `Net/`), USB
(`Net/USBBridge.swift`), the **Android** app (`ArchiveCapture/`), and the Mac pipeline + Reader.

## Active execution plans (`execution-plans/`)
- `devonthink-import.md` — **PLANNING (Archive Notes; HIGH-risk, Tier-2 + reconciliation gate)**: import the
  owner's personal **DEVONthink 3** database (`~/Desktop/Scholarship/1000 Research Database.dtBase2`, ~7.5 GB,
  internal "Meritocracy Project", ~40k rtf/rtfd/txt notes+excerpts; + `Photo Database.dtBase2` for cross-DB photo
  links) into Archive Notes, losslessly. 3-stage offline pipeline (JXA extract →
  frozen JSON manifest → pure transform → materialize a **fresh** store) + a stop-on-flag verification gate.
  Owner decisions locked (2026-07-17): text notes+excerpts incl. embedded images; archival `file://` →
  durable `archivereader://` Reader links; **primary + additional dates**; pointer-notes → a **Related-notes**
  section. Net-new Notes work: multi-date model (per-date timeline index rows) + Related-notes. Correctness
  core = replicants (shared `uuid` → memberships) vs near-duplicates (different `uuid` → date consolidation),
  and the link-conversion contract (nothing survives as `file://`/`zotero://`/`x-devonthink-item://`; only
  internet URLs stay `://`). See §9 open decisions + §8 owner prerequisites (a Reader root over Archival Photos).
- ~~`despotlight.md`~~ — **SHIPPED (Reader + Processor, Wave 26); plan deleted 2026-08-12 (`W26.plandelete`)**
  per the "delete a shipped plan" convention — `git log -p -- execution-plans/despotlight.md` for the text.
  Removed **all** reliance on Spotlight (`NSMetadataQuery`/`kMDItem*`/`mdfind`) per the owner directive
  2026-08-04 (*"Spotlight is fundamentally unreliable on macOS"*), after a live incident where a dead
  Data-volume Spotlight index made the Reader report *"No Read/Unread-tagged PDFs were found"* over 1,849
  correctly-tagged files. What shipped: an owned read-only `CorpusWalker` in ArchiveCore as the Reader's
  Release discovery path (replacing ~80 lines of `PendingWrite` Spotlight-lag masking, with honest `.failed`
  vs `.emptyButReadable` states); `CorpusWatcher` (FSEvents — **verified** to report xattr-only tag writes) +
  a `LibraryIndex` SQLite warm start; and the Processor's tag vocabulary, the fixture scripts' `mdimport`/
  `mdfind` polling, and the docs. Measured read-only on the real corpus: **123,028 files / 102,478 PDFs walked
  in 10.15 s single-threaded**, which is why it was safe. The plan's **declined designs** survive in
  `SUITE_TODO_DONE.md` §"Wave 26 — DECLINED DESIGNS"; the completion audit is `./ops/despotlight-audit.sh`.
  The final follow-up, `W26.oracle-fu1`, shipped 2026-08-19; the completion record is under **Wave 26** in
  `SUITE_TODO_DONE.md`.
- `archive-notes/09-gap-closure.md` — **IN PROGRESS (Archive Notes post-ship reconciliation; W9; mixed Tier-1/Tier-2)**:
  closes the plan-vs-build + spec-vs-build deltas found after W0–W8 shipped (docs/tracker sync, wire built-but-dead
  features, re-arm safety-net lint/smoke tooling, secondary UI polish), then a **Phase-E verification review** that
  gates flipping the **W9** checkbox + deleting the plan. Phase A docs A1/A2/A3/A8 shipped `56360f7` (2026-07-18);
  `00-overview.md` remains the retained interface contract alongside it. See **W9 (gap-closure)** in the Archive
  Notes section below.
- ~~`autonomous-2wk-hardening.md`~~ — **SHIPPED 2026-07-16/17** (all 12 workstreams; see the DONE rollup above
  + `ops/autonomous/README.md` for the mechanisms, and `ops/autonomous/tests/prove-*.sh` for the proofs). Plan
  deleted per the "delete a shipped plan" convention — git history keeps the detailed Progress log.
- ~~`openai-chatgpt-provider.md`~~ — **SHIPPED (Processor, W13.oai-1/2/3)**: OpenAI/ChatGPT as a first-class
  provider — (1) native `LLMProvider.openai` (model list + param-family adapter + onboarding/validation/cost,
  routed through the reused `OpenAICompatibleClient`) and (2) a one-click **OpenAI gateway preset**. All
  daemon-buildable sub-tasks landed (build-verified, additive + opt-in, default provider unchanged); the
  live-key OCR smoke + OpenAI Batch API (Phase 4) remain the **keyed/owner tail** (see the keyed-tail note in
  Wave 13 + Daemon Report). **Plan deleted on ship** (git history keeps it).
- ~~`local-agent-cli-provider.md`~~ — **SHIPPED (Processor, W13.cli-1…4)**: drive OCR/tagging through a locally
  installed, subscription-authenticated CLI (**Claude Code + Gemini CLI + OpenAI Codex CLI**, first-class) with no
  API key — additive `localAgent` config sibling to the gateway (`localAgent > gateway > direct` selection),
  validator + guided wizard + subscription cost pane + full pipeline wiring, all gated unattended at $0 via a
  committed fake-CLI harness. **Plan deleted on ship** (git history keeps it); the real-CLI live smoke +
  gemini/codex install remain the keyed/owner tail (see **Provider expansion (Wave 13)** + Daemon Report).
- ~~`archive-notes/` (00a, 01–08)~~ — **SHIPPED** (NEW APP: Archive Notes, W0–W8). The per-wave plans were
  **deleted on ship** (git history keeps them). `execution-plans/archive-notes/00-overview.md` is **RETAINED** as
  the authoritative interface contract (§2 locked decisions, §5 front-matter schema, **§16 Interface Contract**
  cited by `ArchiveNotes/CLAUDE.md`). Cleanup item: fold §16 into `ArchiveNotes/CLAUDE.md` or promote to `SPEC/`,
  then delete — see **Suite doc hygiene** below.
- ~~`index-parallelization.md`~~ — **SHIPPED** (parallel+batched index build + bm25 ranked search +
  search-during-index refresh). Plan deleted.
- ~~`index-pruning.md`~~ — **SHIPPED** (gated content-index pruning). Plan deleted.
- ~~`decades-date-facet.md`~~ — **SHIPPED** (decade date facet). Plan deleted.
- ~~`reader-smart-folders-scoped.md`~~ — **SHIPPED** (smart folders as scoped root). Plan deleted.
- ~~`reader-gui-test-harness.md`~~ — **SHIPPED** (W7.1–W7.5). XCUITest target, accessibilityIdentifiers,
  DEBUG-gated fixture-root override, `make-gui-fixture.sh`, initial test suite (navigation, tag cloud,
  viewer, preview, filter, sort, degrade). Plan deleted.

## Owner-reported bugs (2026-08-02) — follow-ons

- [ ] **W25.retry-backend — in gateway / Local Agent mode the retry sheets are decorative, and Live Capture's
  retry silently bills a metered API [M · MONEY].** Found 2026-08-03 by the
  adversarial review of W25.modelsync-fu; **pre-existing mechanism**, filed rather than fixed because the
  right behaviour is an owner call. (a) Process Files: `retryOne` + the modal loop pass the run's
  `gateway`/`localAgent`, and `performOCRCall`'s precedence is localAgent → gateway → provider, so the
  sheet's provider/model are **never read** — in gateway mode it estimates and announces a model it never
  calls, and re-runs the *same* gateway model that just failed. (b) Live Capture: `retryFailed` nils out
  `gateway`/`localAgent` whenever an override is present, forcing the **direct metered API** — on a Local
  Agent ($0/page) session a 6-page segment retry becomes 6 billed calls, and W25.modelsync-fu made that
  branch *dearer* by seeding the session's selected model instead of the family's cheapest. (c) A
  gateway-only operator can't retry at all: both sheets load the provider-named Keychain account, never
  `"Gateway"`, and Retry is `.disabled(apiKey.isEmpty)`.
  ✅ **DECIDED (owner, 2026-08-13): a retry REPRODUCES the run's backend, and the provider/model picker is
  DROPPED.** It was a false affordance — in gateway mode it announced a model it never called — so this removes
  a lie rather than a feature, and the safe default is that a retry costs what the run cost. A labelled escape
  hatch to the direct API, and offering both, were each OFFERED AND NOT TAKEN. Part **(c)** — a gateway-only
  operator cannot retry at all, because both sheets load the provider-named Keychain account and never
  `"Gateway"` — is a straight bug and ships with it. Full write-up:
  `ArchiveProcessor/KNOWN_ISSUES.md` → *W25.retry-backend*.
- [ ] **W25.retry-estimate — the retry cost quotes omit rotation and image scale [XS–S · LOW].** Same review.
  Both retry estimates call `CostEstimator.estimate` without `rotationMode:`/`imageScale:` (defaulting `.off`
  / `1.0`) while `retryOne` runs `detectRotation` with the run's real rotation mode, so an LLM rotation mode
  makes extra paid calls per file that the quoted figure does not include. Pass the run's values from
  `activeRunConfig` (now the retry sheets' seed anyway).

## Wave 26 — de-Spotlight the suite (owner directive 2026-08-04) — plan DELETED (`W26.plandelete`)

**Owner directive, 2026-08-04:** *"Spotlight is fundamentally unreliable on macOS."* Remove **all** reliance
on Spotlight (`NSMetadataQuery` / `kMDItem*` / `mdfind`) across the suite. **The plan
`execution-plans/despotlight.md` was deleted 2026-08-12** now that the wave has shipped — recover it with
`git log -p -- execution-plans/despotlight.md`. Its still-live content was folded out first: the **declined
designs** (its §9) are in `SUITE_TODO_DONE.md` §"Wave 26 — DECLINED DESIGNS", and the one open item below
carries its own full spec. The completion audit it prescribed is runnable: `./ops/despotlight-audit.sh`.

**The incident.** The owner pointed the Reader at `~/Desktop/Glazer Gemini 2.5 LLM` — 1,849 PDFs, **every
one correctly tagged** — and got *"No Read/Unread-tagged PDFs were found in this folder."* The macOS
Spotlight index for the whole Data volume was dead (`mdfind -onlyin` returned 0 for that folder, for
`$HOME`, for `/Applications` **and** for the real corpus; four `mdbulkimport` helpers wedged 15 days at 0%
CPU). Two failures: Spotlight went blind, and **the app blamed the files** —
`NavigationWindowView.swift:174-176` asserts a fact about the corpus when the truth is "this app cannot
see it." The Reader has **no Release filesystem fallback at all**; the one that exists
(`ArchiveLibrary.loadFixtureSynchronously`, which already mirrors the production predicate) is `#if DEBUG`
and "compiled out of Release entirely."

**Why this is safe (measured 2026-08-04, read-only, real corpus):** a full recursive walk reading
tags+label+type+mtime for **123,028 files / 102,478 PDFs / 535 dirs / depth 7** took **10.15 s
single-threaded** (82 µs/file; ~0.4 s for 150k with a parallel `resourceValues` pass). `ArchiveLibrary`'s
"no per-file disk I/O (the fast path at 150k)" justification for Spotlight **is already void** —
`ContentIndexer.startIndexing` already opens and extracts text from *every PDF* in the corpus. Also
settled: `~/Desktop/Google Drive/` is **not** Drive-synced (residual name; plain local disk, files fully
materialised) so there is **no** placeholder/egress/sync hazard to defend against, and FSEvents **does**
report xattr-only tag writes (`ItemXattrMod`), so live updates need no polling.

⚠️ **Priority note for the owner:** inserted here *after* the Wave 23 drain (which your 2026-07-29 routing
put first) and *ahead of* the older W16/W3.cap/W17–W22 backlog. `W26.walk1`+`W26.walk2` are the two items
that stop the incident recurring — **say the word and they go to the top of the queue.**

🔴 **THE FIX HAS TWO WAYS OF REPRODUCING THE BUG — and the first is ALSO A LIVE TAG-DESTROYING BUG in the
audited write path, unrelated to Spotlight. See `W26.deny`; it goes first.**

**(a) The read coercion — CORRECTED 2026-08-04 by a second, careful measurement (the first was wrong).** The
trap is far narrower than first written, and the difference decides where the fix goes. With a **fresh `URL`**
per probe, corroborated by `access`/`getxattr`+`errno`: parent-directory denial (`chmod 000`) **THROWS**
`NSCocoaErrorDomain/257`; an **ACL** denying `read`/`readattr`/`readextattr` **THROWS 257**; a parent at
`0o111` (traverse-only) **reads fine** — all three already honest. **The single leak is a file that is itself
unreadable with a traversable parent: the call does NOT throw and yields `tagNames == nil`,** which
`TagReading.swift:34`'s `values.tagNames ?? []` reports as *"confirmed no tags"* about a file carrying
`["Unread", …]`. **Probe ONLY on the `tagNames == nil` branch** — a blanket pre-check is wasted work at 150k
(this plan's earlier, wrong prescription), and a new `TagReadResult.denied` case has the largest blast radius
(all three designs declined it; the reasoning is now in `SUITE_TODO_DONE.md` §"Wave 26 — DECLINED DESIGNS",
folded out of the deleted plan's §9). 🔴 **AND THE PROBE MUST BE `getxattr`, NOT `access(R_OK)` —
verified 2026-08-04.** An ACE denying **only** `readextattr` (narrower than the ACL case above, which also
denies `read`/`readattr` and therefore throws) gives: `resourceValues` no-throw with `tagNames=nil`,
**`access(R_OK) == 0`** — so `access` **fails to detect it** and would coerce a tagged file to "no tags"
exactly as before — while `getxattr` returns `-1/EACCES(13)`. `access(R_OK)` tests the **file data**, not its
extended attributes. Use
`getxattr(path, "com.apple.metadata:_kMDItemUserTags", nil, 0, 0, XATTR_NOFOLLOW)` and return `.failure` on
`-1` with **any errno other than `ENOATTR`(93)**; `ENOATTR` or a returned size of 0 is the only honest
"verified no tags". ⚠️ **Why the first measurement was wrong — it will bite the tests too:**
it reused one `URL` object across probes and `URL.resourceValues` **caches on the backing `NSURL`**, so the
answer came from cache. **Construct a fresh `URL` per probe (or use `stat`/`getxattr`), or a test passes while
asserting nothing.**

**(b) `FileManager.enumerator(at:includingPropertiesForKeys:options:)` — the overload with no `errorHandler:`
— silently skips unreadable directories**, and that is the overload the working DEBUG fixture loader uses
(`ArchiveLibrary.swift:97-99`), so copying it verbatim inherits the flaw. Confirmed: without the handler it
listed a sealed dir but never descended; **with** it, code 257 fired. **Required:** three distinct outcomes
per file (*has tags* / *verified none* / *could not read*), the `errorHandler:` variant, and a surfaced count
of everything skipped. **Every layer must be able to say "I don't know" separately from "there is nothing" —
Spotlight could not, which is why the app lied.**

✅ **W26.deny — SHIPPED 2026-08-05 (`2956f3c` → `ad86cce`); full entry in `SUITE_TODO_DONE.md`.**

✅ **W26.notsup — SHIPPED 2026-08-05 (this commit); full entry in `SUITE_TODO_DONE.md`.**

✅ **W26.lint-fu — SHIPPED 2026-08-07 (`5210c12` → this commit); full entry in `SUITE_TODO_DONE.md`.**

🔴 **AND IT HANGS ON CLOUD STORAGE.** Reproduced against a real `~/Library/CloudStorage/GoogleDrive-…` dir
(Drive.app installed, not signed in): same silent-empty from the no-`errorHandler` enumerator, and
`getattrlistbulk` fails **`errno 60` (Operation timed out) after 0.54 s**. Mitigation is proven and is one
call — `setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)`
returns 0 and converts the stall into an immediate clean error. ⚠️ **The policy is PER-THREAD and Swift's
cooperative pool reuses threads, so setting it inside `Task.detached` neither guarantees coverage nor avoids
leaking it into unrelated work — the scan MUST run on a dedicated `Thread` that sets it first.** Hard
requirement on W26.walk1. (The owner's corpus is local and needs none of this; the *walker* is general and a
root can be pointed anywhere. Open for the owner: `IOPOL_SCOPE_PROCESS` would also stop
`PDFTextExtractor`/`ContentIndexer` silently downloading dataless files — broader, flagged, not decided.)

⚠️ **An adversarial stress pass (file-safety + daemon-shippability lenses) raised 26 defects against the first
draft of this wave. All are recorded in the plan's §7a against the item that must close each. READ §7a BEFORE
STARTING ANY ITEM** — several take the form *"the obvious implementation reintroduces the bug this wave exists
to fix."* The four that most change the work: (1) the code being promoted **silently drops** unreadable files
at `ArchiveLibrary.swift:102,104` (`guard case .success … else { continue }`), which would defeat `W26.deny`
one item later; (2) deleting `PendingWrite` removes the only **write-vs-walk ordering** guard — the plan's
"it converges" justification confused convergence with sequencing; (3) `renameTag`'s ADD is **unconditional**,
so a persisted index turns seconds of staleness into days and can add a subject tag to files that no longer
carry the old one; (4) the wave's **headline regression test passes vacuously** unless it asserts
`ARUITestRootPath` is absent. §7a also records one **rejected** review suggestion (`W26.retire`) — do **not**
delete any W26 entry.

✅ **W26.walk1 — SHIPPED 2026-08-05 (`b3efb16` → `025d126` → this commit); full entry in
`SUITE_TODO_DONE.md`.** Four things later items in this wave need from it.
**(1) The engine is `CorpusWalker` (ArchiveCore `Corpus/CorpusWalker.swift`), and it is SYNCHRONOUS.**
`scan(root:predicate:options:isCancelled:onBatch:) -> CorpusScanResult`, plus
`scanOnDedicatedThread`/`scanDetached` for off-main callers. The sync-vs-async decision plan §5.6 said to
make first is made: `DocumentPageLinkTests`/`RootMarkerStateTests` keep working unchanged, and the
thread-scoped dataless I/O policy is only sound with no `await` in the pass. Off-main means a real `Thread`,
never `Task.detached` — the cooperative pool reuses threads (policy leak) and a ~10 s blocking walk starves it.
**(2) `CorpusScanResult` already models "I could not look."** `entries` · `unreadable` · `directoryErrors` ·
`filesSeen` · `vanishedMidScan` · `rootUnreadable` · `cancelled`, and **`isClean`** — the single gate to
consult before treating an absence as real (plan §5.13 tier 1). `W26.walk2`'s `DiscoveryStatus` should MAP
this, not re-derive it. Plan §7a.3 (a `.failure` must be counted, never `continue`d), §4a.2 (the
`errorHandler:` variant) and §7a.12 (`ENOENT` is churn, not a denial, and does not spoil cleanliness) are
closed inside it.
**(3) The write-surface lint now bans the `errorHandler:`-less `FileManager.enumerator` overload**
(rule 3, multi-line aware — plan §7a.8, reassigned here by `W26.lint`), with an allowance pinned to
`ArchiveLibrary.swift:97`. ⚠️ **`W26.walk2` MUST delete that allowance when it deletes the call** — the
lint's STALE-allowance guard hard-fails otherwise, and there is a self-test case that simulates exactly
that deletion. Run `./ArchiveReader/scripts/lint-write-surface.sh` before committing — the health gate runs
it too since `W26.lint-fu` (2026-08-07), but that is a backstop every 30 commits, not a substitute.
**(4) Reader discovery has tests for the first time ever** — `ArchiveReaderTests/LibraryDiscoveryTests.swift`
(the `grep 'ArchiveLibrary('` → zero-hits gap is closed). Two of its three cases COMPARE the walker against
the shipped DEBUG fixture loader, so they **stop compiling when `W26.walk2` deletes
`loadFixtureSynchronously` — delete them then; that is intended.** ⚠️ They deliberately SET
`-ARUITestRootPath` because the loader is the baseline being compared; `W26.walk2`'s headline regression test
must do the OPPOSITE and assert the key is ABSENT (plan §7a.9). Do not copy their setup.

✅ **W26.walk2 — SHIPPED; full entry in `SUITE_TODO_DONE.md`.**

✅ **W26.notesabsence — SHIPPED 2026-08-07 (`5c46d2a` → this commit); full entry in `SUITE_TODO_DONE.md`.**

✅ **W26.notesabsence-fu1 — SHIPPED 2026-08-07 (`6226e7d` → this commit); full entry in
`SUITE_TODO_DONE.md`.** A symlinked Reader root can be granted in Notes, and a refused grant is no longer a
marker that implies success. `ReaderRootStore.grantRoot` adopts `CorpusWalker.canonicalRoot(url)` — so the
bookmark is minted for the openable target — and returns `ReaderRootGrant` (`.granted(marker)` /
`.refused(_)`) with four distinct refusals, each carrying the `message` the popover shows;
`LinkResolution.grantRefused` carries it out through `grantAndResolve`, where a marker-less pick used to come
back `.notFound` — a claim the archive had been searched, about a folder that was never opened. The store also
takes an **injected `UserDefaults`** now (the Reader's precedent), because `grantRoot` writes
`readerRootBookmarks` and the suite exercising it had no snapshot at all. **What is proven and what is not:**
every assertion is at the store/resolver level in the Notes test host — the panel-pick path is *not* covered,
because Notes has no folder chooser at all (`fu2` below). The adversarial pass found that the branch the item
is NAMED for had no test and a mutation restoring the bug stayed green, which is why `mintBookmark` is an
injectable seam; it also filed **`fu3`** (a `persistAll` that deletes bookmarks it merely failed to re-mint).
`fu3` shipped first, as intended — it was harmless only while nothing could grant a root, and `fu2` is the
item that hands the user one to lose. **Both have since shipped — see `fu2` and `fu3` below.**

✅ **W26.notesabsence-fu3 — SHIPPED 2026-08-07 (`af01cb7` → this commit); full entry in
`SUITE_TODO_DONE.md`.** One mechanism behind all three defects: `ReaderRootStore` conflated *"I have a URL
for this root"* with *"I hold a scope for it"*, and paid for it in persisted state. `root(for:)` — a **read**
— wrote `UserDefaults`: a scope that would not start was read as a dead bookmark, and `persistAll()` then
rebuilt the *whole* `readerRootBookmarks` dictionary by re-minting every surviving root **with no scope
started**, the one condition under which minting reliably fails. `persistAll` is **deleted**, not narrowed —
the shape of the bug is a lookup that rewrites the store. 🔺 **The item's own prescription was improved on and
that is the durable part:** it asked that the *other* roots be spared and the failed one's entry removed; the
failed one's bookmark now stays **too**, because a refused start is not proof of staleness (an unmounted
volume refuses one and remounts later) and Notes has no folder chooser at all (`fu2`), so forgetting a grant
here is unrecoverable by the user — the same answer the Reader documented in
`RootFolderStore.reResolveSavedRoot`. Mutant **M2 is the item's literal fix**, and a named test kills it.
Both nits closed: `activeScopes` now records `started`, so `stopAccessing` stops only what this store started
and **keeps** the never-started entry (dropping it sent the next lookup down the path that wiped the store —
losing a session's roots by closing a popover was two lines apart); and the dead
`ReaderLinkResolver.stopAccessing` is replaced by `releaseRootScope()`, wired to the popover's `dismiss()`.
A third imbalance, found in the same lines and fixed there: re-granting a GUID at the *same* path started a
second scope nothing could ever stop. 763 + 189 Notes tests, Release clean, 0 new source warnings, lint 14/14,
**10 mutants each caught by a named test**.

✅ **W26.notesabsence-fu2 — SHIPPED 2026-08-07 (this commit); full entry in `SUITE_TODO_DONE.md`.**

✅ **W26.docs — SHIPPED 2026-08-07 (this commit); full entry in `SUITE_TODO_DONE.md`.**

✅ **W26.docs-fu1 — SHIPPED 2026-08-09 (this commit); full entry in `SUITE_TODO_DONE.md`.** One of the two
deferred checks PASSED on pixels and the other is BROKEN → `W26.previewzoom` below.

✅ **W26.previewzoom — SHIPPED 2026-08-10 (this commit); full entry in `SUITE_TODO_DONE.md`.** The one-token
fix the item prescribed was only half of it — the converse the item told the next session to check is what
caught the other half. Filed in passing: `W26.previewzoom-fu1` below.

✅ **W26.previewzoom-fu1 — SHIPPED 2026-08-10 (this commit); full entry in `SUITE_TODO_DONE.md`.** Option (b)
of the two the item offered: a `DocumentViewerModel.supportsFind` the preview model sets false, gating the
three Find commands (and the model's own find entry points, so a second publisher cannot reach around them).
Option (a) — render a find bar in the sheet — was considered and **not** taken: a feature, not a fix, and Esc
/ focus semantics inside a modal sheet is the ground `W26.previewzoom` spent its whole budget on. It stays
available if the owner wants it; `supportsFind` is the one line it flips.
✅ **W26.fixwarn — SHIPPED 2026-08-10 (`4dc64ff` → this commit); full entry in `SUITE_TODO_DONE.md`.** The
item's own prescription (capture the guest's real exit status) was the right one — and it was needed in
**both** entry points, not just the runner the item names, so the verdict now comes from one shared
`tart_build_fixture` in `tart-lib.sh`. UNKNOWN is a third tier on purpose. `prove-vm-lane.sh` §11 pins all
three classifications against a stubbed `tart`, and that harness is now a health-gate step, so it is
watched rather than merely present. Filed in passing: `W26.fixwarn-fu1` below.
✅ **W26.fixwarn-fu1 — SHIPPED 2026-08-10 (`877c695` → this commit); full entry in `SUITE_TODO_DONE.md`.**
Part 1 was triage, not blanket wiring: six of the seven became gate steps (+58 s), each baselined green on
pristine main first and re-run in the gate's own env, and `prove-exit-logging` — one of the two the item
guessed was too invasive — turned out hermetic. `prove-keepalive` is the one exclusion, and not for runtime:
it drives real launchd, so its verdict depends on state outside its sandbox and a SIGKILLed gate would leave
a self-relaunching phantom job in `gui/$UID`. Part 2 closes the class: `prove-gate-report.sh` §5 asserts every
`prove-*.sh` is a gate step or on health-gate.sh's machine-read `# GATE-UNWATCHED-BY-DESIGN:` line, mutation-
proven 8/8 (including that the list cannot lie by going stale or naming a harness that IS wired).
✅ **W26.plandelete — SHIPPED 2026-08-12 (this commit); full entry in `SUITE_TODO_DONE.md`.** The last
blocker (`W26.docs-spec`) closed 2026-08-11. The `git rm` was the trivial half: the item's real content was
proving the plan's own gate — *"the plan is still the only place an open item's context lives"* — was clear.
It was not clear by default. §9's **declined designs** were forward-looking, not a record of shipped work, and
this file cited them live; they are folded into `SUITE_TODO_DONE.md` §"Wave 26 — DECLINED DESIGNS". All 9
surviving code/doc citations were confirmed self-sufficient before deleting.


## Known-issues work — Wave 23 (Codex full-suite review; owner-commissioned 2026-07-29)

⚠️ **This section carried "TOP OF THE DRAIN" until the 2026-08-16 priority reset — it no longer drains
first, and that is not a demotion of the review.** All 34 original findings shipped; the 7 left are `-fu`
follow-ups, every one of them LOW. The root `CLAUDE.md` already records the "drain Wave 23 first" condition as
MET on 2026-08-01. Two of the seven were promoted out of the LOW tail on their own merits — `W26.oracle-fu1`
to TIER 0 (a tag oracle that reports PASS for tags it could not read devalues every Tier-2 tag assertion made
since) and `W23.m14-fu` to TIER 5 (on first Reader use against an unmounted external volume it reports the
owner's irreplaceable corpus as missing files). The rest sit in TIER 6: real, cheap, and nothing depends on
them. ⛔ Do NOT restore a "drains first" marker here without a fresh owner decision — the argument that Wave 23
is drained has already been made to him and he kept the review pause anyway.

**Source.** An owner-commissioned static full-suite review by Codex, 2026-07-29, against remote `main`
`bfcb38e`. Read-only: nothing was fixed, built, or run. Scope = Processor (macOS + Android; iOS only for severe
parity), Reader, Notes, `packages/ArchiveCore`, suite scripts/release tooling. 24 findings survived its own
refute pass: **5 HIGH · 15 MEDIUM · 4 LOW**. The report itself is archived (gitignored) at
`old/Codex_Review_July_29.md`; **every finding is transcribed below in full, so this queue is self-sufficient —
you do not need the report.**

**Owner routing decisions (2026-07-29).** (a) **W23 drains FIRST**, ahead of the remaining W16/W3.cap/W17–W22
work — these are confirmed bugs, several with silent data loss. (b) All **5 HIGH findings are daemon-AUTHORIZED
per item** via named entries in [`OWNER_AUTHORIZATIONS.md`](OWNER_AUTHORIZATIONS.md), rather than parked in the hold queue —
they are the most valuable findings and the authorization text carries each one's hard constraints. The normal
Tier-2 gate is unchanged, and **scratch-copy-only** still binds absolutely (Reader Core Directive).

**⚠️ LINE NUMBERS ARE STALE — RE-LOCATE BY SYMBOL, NOT LINE.** The review baseline `bfcb38e` is five commits
behind current `main` (`62a10d1`), and W16.cfg1/cfg2/cfg3/cfg5 **substantially rewrote**
`OCR/OCRProcessor+{OCR,Pipeline}.swift`, `OCR/OCRProcessor.swift`, `Capture/SessionProcessingConfig.swift` and
`Views/ToolsView.swift`. Cites in those files have drifted by tens of lines. Every item below names the
**function/symbol**; find that, and treat the line number as a hint only. Re-confirm each premise before fixing
it (Tier-2 requires this anyway).

**Independently re-verified while queueing (2026-07-29, against `62a10d1`)** — so these three are not
taken on trust: **W23.h1** (confirmed, and *worse* than reported — see the item), **W23.h5** (confirmed
verbatim), **W23.m5** (confirmed; 9 `_ = try? MacOSTagger.applyTags` sites, not 3). The other 21 carry Codex's
refute-verified confidence and must be re-confirmed by the fixing session.

**Codex deduped against** `SUITE_TODO.md`, all three `KNOWN_ISSUES.md`/`CLAUDE.md`/`AGENTS.md`, the Notes
`00-overview.md` + `09-gap-closure.md` plans, `devonthink-import.md`, and the gitignored maintenance material.
It deliberately did **not** re-report: W3.cap-r1…r6, W3.net-r1, W16/W17/W19/W20/W21/W22, the owner-closed
immutable-staging-generation proposal, Notes W9 gap-closure, DEVONthink import, the fixed ArchiveCore
lost-update/duplicate-tag work, known Notes asset-write failures, or the parked iOS backlog. It also explicitly
**refuted and dropped** five candidates: the non-ASCII/APFS filename-cap claim, Processor receiver
stale-callback ordering, ArchiveCore partial Finder-tag mutation (already documented), and Reader header
stripping / case-only tag convergence / smart-folder flattening (all intentional, tested behaviour). Do **not**
re-promote those.

**iOS parity is PARKED** (§Project focus): where a finding has an iOS twin (`W23.m1`), fix **Android only** and
record the iOS parity as parked — do not revive the iOS build to chase it.

**Prior-art audit — CLOSED 2026-07-29. Do not go re-mining the archive.** A removed Codex worktree (work dated
2026-07-17, preserved as branch `wt/codex-processor-bugfixes-20260712` + patches in
`old/codex-processor-fixes-20260717/`, ~2,900 uncommitted lines over 8 unpushed commits, **76 commits behind
`main`**) was audited against every W23 defect symbol. **This is the complete list of overlaps — the rest is
superseded** (its run-config work was re-implemented on `main` as `W16.cfg1`–`cfg5`):
- **`W23.h5` — prior art EXISTS** (`PDFGenerator.generateRequiringEmbeddedImage()` + `PDFError.imageEmbeddingFailed`). See the item.
- **`W23.m7` — prior art EXISTS** (`3ea3221`: checked `writeManifest()` + memory rollback). See the item.
- **`W23.h1` — NONE.** Only the `pruneEmptySessions(under: root)` *call site* moved; the function's
  delete-unknown-content logic is untouched. The most severe finding has no head start.
- **`W23.m5` — NONE, and worse than none:** its new call sites are themselves written
  `_ = try? MacOSTagger.applyTags(…)`, i.e. they *repeat* the swallowing bug. Don't copy that code.
- Everything else queued in W23 (all Notes, Reader, ArchiveCore and Android items): **no overlap at all** — that
  branch is Processor-macOS only.
In both "EXISTS" cases: **re-derive against current `main`, never cherry-pick.** Neither was ever build-verified
in this repo, and both predate the W16.cfg* rewrite of the same files.

### HIGH — all five daemon-AUTHORIZED per item ([`OWNER_AUTHORIZATIONS.md`](OWNER_AUTHORIZATIONS.md)); Tier-2, scratch copies only

### MEDIUM

- [ ] **W23.m14-fu — a Reader root on an *unmounted* volume reports its files as missing from the archive
  [XS · LOW · misleading absence].** Residual noticed while shipping W23.m14 (2026-07-30); **not** a re-open —
  m14's contract for a root directory that is *gone* is deliberate and load-bearing for the W8-S9
  computer-move promise. The gap is narrower: `scanForBasename` cannot tell "this root was deleted" from
  "this root's volume is unplugged", and both take the `.exhausted` branch, so the popover says *"Source file
  not found in the archive"* about files that are merely offline. **Re-confirm the premise first** — it turns
  on whether `ReaderRootStore.loadSaved` / `root(for:)` hand back a URL at all for an unmounted volume
  (`URL(resolvingBookmarkData:)` may throw, in which case the resolver already says `needsRootGrant` and there
  is nothing to fix). If it is reachable: distinguish the two with a volume-reachability check and report the
  offline case as its own outcome, not as absence. Notes `Links/{ReaderLinkResolver,ReaderRootStore}`,
  `Views/ReaderPreviewPopover`. | files: ArchiveNotes/macOS/Sources/ArchiveNotes/Links/ReaderLinkResolver.swift | XS | low | none

- [ ] **W23.m15-fu — ghost memberships already on disk are never swept, only out-voted [XS–S · LOW ·
  stale data].** Residual of W23.m15, filed 2026-07-31. **Not** a re-open: no new ghost can be created
  (the store guard and the FK both refuse one), and a ghost naming a *system* folder is revived by the
  by-id restore, which is the common case by far. The gap is the leftover naming a **user** folder that
  is genuinely gone — only reachable via the pre-fix race between a folder delete and a concurrent
  replicate. Those rows survive the FK migration on purpose (SQLite checks foreign keys as rows are
  written, so pre-existing violations are tolerated, and dropping them would delete durable organization
  data), and the DB load path deliberately does not purge them either. They are invisible, but they do
  inflate `membershipCount(item:)`, which makes the §3.6 last-instance guard treat such a note as filed
  elsewhere: deleting its last *real* folder then won't offer to trash it, and the note ends up
  reachable only under All Notes with nothing said. Conservative — it never deletes a note it shouldn't
  — but silent. **Fix:** a one-shot sweep at load (`PRAGMA foreign_key_check` / an anti-join against
  `folders`) that reports what it found rather than deleting quietly, run once and stamped so it isn't a
  per-launch cost. Deliberately out of scope with it: `template_assignments.folder_id` stays
  unconstrained (a stale assignment is inert and `clearDanglingAssignments` already tidies it, so a
  second table rebuild would risk durable data for nothing).
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/Index/{OrganizationStore,NotesIndex}.swift | XS–S | low | none

### LOW

### Follow-ups discovered while fixing Wave 23

- [ ] **W23.m9-fu3 — the index-failure UI in Reader and Notes has never been rendered; give the GUI fixture
  a corrupt index so it can be [S].** Owner decision, 2026-07-31 Daemon Report. W23.m9 shipped two warning
  surfaces — Reader's amber status-bar line (`ar.status.indexFailure`) and Notes' reused sidebar banner —
  each shown only when the search index cannot be opened or was not fully written. **Neither has ever been
  drawn by anything.** This is NOT a skipped VM run: no fixture produces a corrupt index, so there is no path
  to the state to drive. The state machine behind them is covered by 23 headless tests; only the drawing is
  unproven. **Do:** teach the GUI fixture builders (`ArchiveReader/scripts/make-gui-fixture.sh` and `ArchiveNotes/scripts/make-notes-fixture.sh` — they live under each app's `scripts/`, NOT under `ops/gui/`, which the first draft of this line implied)
  an opt-in mode that overwrites the scratch fixture's `content-index-v2.sqlite3` / `notes-index-v1.sqlite3`
  with a kilobyte of junk, then add a UITest per app asserting the warning appears — **and, more importantly,
  that the next attempt recovers on its own once the bad file is replaced**, which is the actual point of the
  fix. Safe by construction: both files are rebuildable caches inside a scratch fixture, never the owner's
  real store. Closes the two macOS surfaces; the Processor's equivalent red row (W23.m7) stays blocked on
  `W21.vmgui-d`, and the Android ones are declined below.
  | files: ops/gui/*, ArchiveReader UITests, ArchiveNotes UITests | Tier-1 | S

- [ ] **W23.m4-fu — a page-specific reveal opens a NEW window per page instead of navigating an open one
  [S · LOW · UX] — ⛔ DO NOT IMPLEMENT UNPROMPTED: the owner chose to KEEP the current behaviour.**
  ⚠️ **This item is filed as the REVERSAL of a decision, not as work.** It is contingent on a judgement only the
  owner can make — *"implement it only if window sprawl becomes a real annoyance"* <!-- policy-ok: this IS the gated item, parked in the plan's HOLD QUEUE as owner judgement --> — so a session must NOT pick
  it up on its own. It sat in the actionable WORK QUEUE until 2026-08-13, when a walk of the first five queue
  items caught that `next-queue-item.sh` was offering it as `ok`: the metadata tail carried no owner marker, so
  the daemon would have implemented a change the owner had explicitly declined. Parked in the plan's HOLD QUEUE
  as owner-judgement (gating category 2). Residual of W23.m4, filed 2026-07-31 from the Daemon Report. Since m4, the cited page is
  part of the document window's `openWindow(id:value:)` value, so SwiftUI value identity gives two links to
  *different* pages of the same document two windows (same page → one). **Owner reviewed and chose to keep
  the current behaviour** — one view per citation is what you want when comparing two passages — so this is
  filed as the reversal, not as a bug: implement it only if window sprawl becomes a real annoyance when <!-- policy-ok: gated, see the ⛔ header of this item -->
  clicking through a note that cites many pages of one document. **Do (if picked up):** look up an already-open
  window for that document in a window registry and navigate it to the cited page rather than opening a
  second one; keep an explicit "open in new window" affordance so the compare-two-passages workflow survives.
  Needs the registry, so it is its own item and not a tweak.
  | files: ArchiveReader/macOS/Sources/ArchiveReader/ (document window open path) | Tier-1 | S | **owner judgement**

- [ ] **W23.l4-fu — no UITest drives the Notes metadata strip, so the date warning row is unverified
  pixels [XS–S].** Owner decision, 2026-07-31 Daemon Report: close this with a **test**, not a recurring
  manual check. W23.l4's logic is fully pinned by `DateFieldEntryTests`, but nothing in any UITest touches
  the Date row, so the inline warning (`an.detail.date.dayWarning`) and the dead Set button have never been
  seen by a harness — the standing ask was a 10-second owner eyeball, which does not scale to the next
  change that touches date entry. **Do:** add a Notes UITest that selects a note, types `31` into Day,
  chooses **February** from the month menu, and asserts (a) the day is dropped, (b)
  `an.detail.date.dayWarning` exists and reads *"February <year> has 28 days — the day is ignored."*, and
  (c) the note is saved at month precision; plus the negative case (a real month-end such as `2026-01-31`
  commits at day precision with no warning). Run it off-screen via `ops/gui/vm-gui-runner.sh notes` — the
  Notes VM lane is green, and the known-failure list to compare against is G3/G6/G8/G11 (see
  `ArchiveNotes/KNOWN_ISSUES.md`), plus the G1 `⌘N` delivery flake first seen 2026-07-31.
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/Views/NoteMetadataInspector.swift (identifiers only),
  ArchiveNotes/macOS/Tests/ArchiveNotesUITests/ | Tier-1 | XS–S

- [ ] **W23.h2-fu — concurrent edits can leave the Notes FTS index row transiently stale [S · LOW].**
  Found 2026-07-30 while fixing W23.h2 (adversarial self-review of the fix, not a new review). The `.md` on
  disk is now always correct — `NoteStore.withItem` is atomic — but `NotesModel.mutateItem` does its
  `index.upsertBatch` **after** the transaction returns, and two concurrent `mutateItem`s can commit their disk
  transactions in one order and their index upserts in the **other**. The row for that item then lacks the
  second edit until the next edit or an index rebuild, so the list/FTS can show a stale field while disk is
  right. **Not data loss** (the index is a documented rebuilt-from-disk projection) — hence LOW, not a
  re-open of W23.h2. **Fix options:** carry `ItemTransaction.ref.mtime` into the upsert and have
  `NotesIndex.upsertBatch` skip a row whose stored mtime is newer (a compare-and-set on the projection), or
  fold the upsert into a per-item serialized step so index writes inherit the transaction order. Prefer the
  mtime guard — it also hardens the indexer against W23.m9's failure modes. Test: two concurrent
  `mutateItem`s on one item, then assert the index row matches disk without a rebuild.
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/{Core/NotesModel,Index/NotesIndex}.swift | S | low | W23.h2

- [ ] **W23.l3-fu — Notes has its own root-marker writer, and it is uncoordinated [XS–S · LOW · SHARED CORE
  DRIFT].** Found 2026-07-30 while fixing W23.m6/W23.l3 (audit of the sibling call sites, not a new review).
  `ArchiveNotes/.../Store/RootMarkerStore.ensureMarker` duplicates `RootMarker.ensure` instead of calling it.
  It does **not** share the m6 defects — it throws `corruptRootMarker` when an existing file won't read or
  decode, and propagates its write failure, so it never returns an unpersisted GUID — but it uses plain
  `FileManager`/`Data.write` with **no `NSFileCoordinator`**, so the W23.l3 check-then-write race applies to it
  and it is invisible to the coordination `RootMarker.ensure` now takes (a Notes first-time create can race a
  Reader/Notes one at the same root). Only reachable when two processes first-touch the same root, hence LOW.
  **Fix:** delete `writeFresh` and call `RootMarker.ensure(at:kind:name:)`, mapping `.malformed`/`.unreadable`/
  `.readOnly` onto the existing `MarkerError` surface (`NoteStore.corruptRootMarker` already exists) — the
  duplicate also means the m6 hardening must otherwise be maintained twice. Shared-Core rule: build+test all
  three apps.
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/Store/RootMarkerStore.swift | XS–S | low | W23.m6

## Provider expansion — Wave 13 (Processor; daemon-buildable) — queued 2026-07-16
The two proposed provider plans, now **elaborated with a "Daemon build plan"** each so a fresh autonomous session
can build them: each sub-task below is **unattended, $0, no key, no GUI** (build clean + fake-CLI/unit tests +
self-review), with the live-key verification split out to a **keyed/owner tail** (below) that is flagged to
Daemon Report, NOT skipped. Do top-to-bottom, one bounded sub-task per session. **OpenAI first (Tier-1, smaller,
reuses the existing OpenAI-format client), then CLI (Tier-2).** New provider changes stay **additive + opt-in** —
never flip the default provider until the keyed live test passes. Legend as above.
*(Both of those plans have since shipped; a third group — **Apple Vision**, owner-queued 2026-08-07 — was
appended at the end of this wave and is the only one with no keyed tail at all.)*

**OpenAI / ChatGPT provider** (plan `openai-chatgpt-provider.md` shipped + deleted W13.oai-1/2/3; Tier-1;
SHARED HOTSPOT = the persisted `LLMProvider` enum, append-only):
**Local Agent CLI provider** (plan `execution-plans/local-agent-cli-provider.md` SHIPPED + deleted at W13.cli-4;
Tier-2; fake-CLI harness made the whole gate unattended-satisfiable at $0 — the daemon-buildable code half
W13.cli-1…4 is COMPLETE; only the keyed/owner tail below remains):
**Keyed / owner tail (NOT daemon-buildable — do not attempt unattended):**
> The *visual* half of these (does the wizard / Settings row / cost pane look right) is now dischargeable in a
> GUI-on / Daemon-Report session via the live sighted loop (`ops/gui/capture-window.sh` + `cliclick` → read the
> shot); only the *live-key / account* halves stay genuinely owner-gated. Don't park a pure visual check on the
> owner as "GUI blocked."
- **⏸️ ON HOLD (owner 2026-07-16) — OpenAI live 2-image OCR smoke** through gateway + native `.openai` (needs an
  OpenAI key). Come back to it. _(Model-ID + pricing `// VERIFY` placeholders are RESOLVED — `openaiModels` is now
  the current GPT-5 generation (gpt-5-nano/-mini/5.4-mini/5.4/5.5) priced per the owner-provided SoCOCRbench
  source; the live-key smoke remains the final ID confirmation, but nothing is blocked on it: the provider is
  additive + opt-in.)_
- [ ] **W13.cli Phase 0 — install `gemini` + `codex` CLIs and confirm entitlements (owner).** Was buried in a
  prose note with no checkbox, so nothing ever tracked it (owner asked for it to be a real item, 2026-07-16).
  ⏸ **PARKED by the owner 2026-08-13** — *"Park the gemini and codex CLI for now."* Neither CLI is installed on
  the machine (`command -v gemini` / `codex` → nothing; `claude` is at `~/.local/bin/claude`). **Nothing is
  blocked by this**: the fake-CLI harness already covers the whole Local Agent code path at $0, `claude` is
  Phase-0-validated, and the only thing waiting is the final "shipped" stamp on `W13.cli-1…4` plus the
  `gemini`/`codex` invocation details, which stay `VERIFY` placeholders. Do NOT install them, do not chase the
  entitlement spike, and do not re-raise this — un-park it only if the owner asks.
  Install both CLIs, sign in with the enterprise/Edu accounts, and confirm each is entitled to run OCR. Gates the
  real-CLI live OCR smoke for W13.cli-1…4 (the `claude` path additionally can't run inside a Claude Code session —
  nested-session guard). The fake-CLI harness already covers the code path at $0, so this gates only final
  "shipped". | S | low | owner
- Later phases (not now): OpenAI Batch API (Phase 4) + CLI persistent-`stream-json` perf (Phase 4). Land the
  build-verified code first; these gate final "shipped".

**Apple Vision (on-device) OCR backend** — owner-queued 2026-08-07. The FOURTH backend beside direct API /
gateway / Local Agent CLI, and the only one that is **free, offline, key-free and unmetered**: macOS's own
Vision text recognition, either in-process (`VNRecognizeTextRequest`) or via the installed **`mac-ocr`** CLI
(`/opt/homebrew/bin/mac-ocr`). ⚠️ **Prior art to read FIRST: `~/Claude/vision-reader-gui`** — a shipped
SwiftUI front end for exactly this CLI. Take its *recognition* plumbing (`Sources/Runner.swift`: binary
discovery for a Finder-launched app with a bare `PATH`, memoised `locateTool`, per-file invocation for real
progress, the argument list Vision actually accepts; `README.md`: measured throughput ≈3× at the
performance-core count, `--fast` ≈2.6× faster for ~1.7% CER, `--pdf-dpi` barely matters on clean scans).
**Do NOT take its output half** — that app writes a searchable-PDF text layer (`SearchableWriter`/`JBIG2`);
this app's output format is unchanged, the 2-page image+text PDF of `SPEC/tag-format.md`.
- [ ] **W13.vision-1 — Apple Vision as a first-class OCR backend [M · low · Tier-1 · daemon-buildable, $0,
  no key, no GUI].** Vision transcribes only — it cannot classify, segment, date or tag — so this is a
  **transcription backend, not a provider swap**, and the pieces it doesn't cover already exist:
  `OCRPrompt.buildClassificationOnly(text:…)` (the text-only classification path built for
  already-OCR'd PDFs) and `Tagging/TagGenerator.swift` (tags from OCR text, no image). Rotation is
  already local — `RotationDetector.detectCorrection` is Vision, and `performOCRCall` runs it concurrently
  with the transcription regardless of backend, so `RotationMode.localVision` needs nothing new.
  **Wiring:** a `VisionClient` beside `LocalAgentClient` with the same `ocr(imageURL:previousText:…)
  -> OCRResult` shape, returning `text` + `rotationDegrees` and a **nil `classification`** (which the
  format already tolerates — SPEC: *"Classification may be ABSENT"*). Then one arm in
  `OCRProcessor+OCR.swift:1487-1511`'s backend precedence (currently `localAgent > gateway > direct`) and
  one case in the Settings **OCR backend** picker (`Views/SettingsView.swift:321-340`, the XOR Binding over
  `useGateway`/`useLocalAgent` — add the third flag there, not downstream). Like the gateway and the CLI it
  **skips batch and LLM-rotation**. Concurrency is CPU-bound, not rate-limited: size it off the
  performance-core count per vision-reader-gui's measurements, and keep it OUT of `NetworkSession`'s
  in-flight limiter.
  **Decide in the item, don't pre-empt here — in-process Vision vs shelling to `mac-ocr`.** In-process wins
  on no external dependency, no PATH discovery, no subprocess, and `Vision` is already linked
  (`RotationDetector.swift`). The CLI wins on already being written and measured, on PDF page rendering +
  `--format jsonl` streaming, and on per-observation confidence/bbox JSON. Whichever is chosen, the
  **language / `--fast` / min-confidence / custom-vocabulary knobs are the user-visible surface** —
  the app already has a custom tag vocabulary that could seed `--custom-words`.
  **Cost + labelling (small but don't skip them):** `Models/CostEstimator.swift` must report **$0**, and
  the pinned cost pane needs its third case beside the CLI's *"Included in your subscription"* (say
  *"Free — runs on this Mac"*). The page-2 header writes `<Provider> · <Model> · <date>` from
  `model.provider.rawValue` (`OCR/PDFGenerator.swift:233-241`) — `<Provider>` is **free-form** to the
  Reader, so `Apple Vision · macOS Vision · …` needs no Reader parse change, only the parenthetical
  example list in `SPEC/tag-format.md:145`. ⚠️ `LLMProvider` is a **persisted, String-backed SHARED
  HOTSPOT** — appending a case is safe, renaming/reordering is not; and if Vision is modelled as a
  backend flag rather than an `LLMProvider` case, the header still needs a real string.
  **Gate:** build clean + `./test-smoke.sh processor` + a $0 headless driver over 2 synthetic PNGs
  (the Vision path needs no key, so unlike every other backend its functional test is fully unattended —
  no fake-CLI harness required). | files: ArchiveProcessor/macOS/Sources/ArchiveProcessor/OCR/{VisionClient(new),OCRProcessor+OCR}.swift, Models/{CostEstimator,DefaultsKeys,ProviderModels}.swift, Views/SettingsView.swift, SPEC/tag-format.md | M | low | none
- [ ] **W13.vision-2 — the hybrid: Vision transcribes, an LLM only classifies/tags [S–M · low · Tier-1]
  (blocked-on: W13.vision-1).** The point of the backend: pay for judgement, not for transcription. Route
  Vision's text into the existing text-only paths (`OCRPrompt.buildClassificationOnly`, `TagGenerator`,
  `LLMTextClient`) so a run does N free image calls + N cheap **text** calls instead of N image calls —
  and make "no LLM at all" (transcribe-only, `TaggingMode.none`/`.copySource`) a supported combination,
  which is the fully-offline, fully-free mode. Worth an accuracy note in the same item: Vision is strong on
  clean typescript and weak on handwriting and heavy skew, where the VLMs are the opposite — so this is an
  **added backend, never a new default**. | files: ArchiveProcessor/macOS/Sources/ArchiveProcessor/OCR/{OCRProcessor+OCR,OCRProcessor+Pipeline}.swift, Tagging/TagGenerator.swift | S–M | low | none

## Known-issues work — Wave 14 (cross-app; owner-requested 2026-07-16)
Actionable open items pulled from the three `KNOWN_ISSUES.md` + the Processor streaming-residuals review, ordered
by value. **Android straggler is first (HIGH).** Each notes what's daemon-buildable vs. the keyed/GUI verify tail.
Legend as above.
**Parked — explicitly NOT a Wave-14 work item:** Processor cloud/relay **post-finalize reclassify → duplicate
output** (A11, MED, Drive-milestone) lives entirely in the **Google-Drive relay path**, which is **ON HOLD /
maintain-only** (see §Project focus). Leave parked until the Drive milestone is un-held; do not build it unattended.

## Known-issues work — Wave 15 (shared tag writer; owner-reviewed 2026-07-18)
Promoted from `ArchiveProcessor/KNOWN_ISSUES.md` → "lossless Finder-tag undo must preserve duplicate
occurrences" [MED · shared contract], **bundled with** `ArchiveNotes/KNOWN_ISSUES.md` → the W8-S2 latent
concurrent-write race. Both land on the same `ArchiveCore.CoordinatedTagWriter` choke-point, so the shared
serialization/reconcile layer gets built once instead of paying the shared-Core Tier-2 tax twice.

**Owner review 2026-07-18 settled three questions — do not re-litigate:**
1. **Scope** = bundle the two items (this wave).
2. **Restore semantics** = **occurrence-only**: undo restores the correct *count* of each token; position/order
   is **not** guaranteed (macOS reorders on write and the SPEC already compares as a multiset, so exact-order
   restoration is unobservable and buys nothing).
3. **No persisted undo ledger** — undo stays in-memory/session-scoped, so `TagDelta` needs **no**
   `Codable`/versioning. The CLAUDE.md §12 audit ledger stays unbuilt; it is a separate future item.

**Verified during the review (established facts, don't re-derive):** macOS **does** persist duplicate tag
strings — a scratch probe round-tripped `["A","A","B"]` through both `setResourceValue(.tagNamesKey)` and raw
`setxattr`, so this is a real on-disk state, not theoretical. Forward writes are **already** duplicate-lossless
(untouched tokens kept verbatim + multiset verify) and **color-label undo is already exact**
(`.restoreLabel(Int?)` is a single `Int?` — no multiplicity problem, out of scope). Only the **inverse/undo**
loses occurrences, and closing it needs **both** fixes below: the inverse is computed by `Set` subtraction
(`TagWrite.swift:191-196`) **and** the apply path refuses to re-add an already-present token
(`TagWriter.swift:52`) — fixing either one alone still loses the duplicate.

All five are **Tier-2** (shared audited tag writer) and must **build + test all three apps** (Reader +
Processor + Notes) per the shared-Core rule. All are daemon-buildable ($0, no key, no GUI, no hardware) and
verified on **scratch copies only — never the corpus**. Legend as above.
**Explicitly NOT in Wave 15:** the persisted/versioned undo **audit ledger** (Reader `CLAUDE.md` Safety
Protocol §12 — documented but never built; undo is an in-memory `NavigationModel.undoStack` today). Owner
decision 2026-07-18: undo stays in-memory. A durable ledger is a separate future item and must not be
coupled to this bug.

## Known-issues work — Wave 16 (Processor: LAN credential · run config · paid-batch; owner-reviewed 2026-07-18)
Promoted from three deferred `ArchiveProcessor/KNOWN_ISSUES.md` entries after a code-grounded review. **Two of
the three entries were materially over-stated** — the review's main output was deflation plus a few genuinely
unmet slices. Severities corrected in KNOWN_ISSUES; the scope decisions below are the owner's and are final.

### #6 LAN channel — crypto redesign CLOSED (accepted risk); credential hardening promoted
**Owner decision 2026-07-18: do NOT build the TLS/AEAD redesign.** Rationale, recorded so it isn't reopened:
the payload is photographs of **public archival records the owner intends to publish**, so confidentiality is
near-worthless; the integrity loss is bounded by the Recovery Core Directive (idempotent `(group,seq)`,
originals retained in the visible backup folder, deletions via Trash not `rm`); and it needs a targeted
adversary co-located in the same reading room. Encrypting the transport would change the wire contract on
**all three platforms**, needs a physical iPhone + the `ap_test36` emulator E2E gate, and buys little. **Closed
permanently — do not re-promote LANSEC-5/6/7 (secure transport, companion mirroring, packet-capture harness).**

**But two things ARE promoted**, because they are cheap, Mac-only, and need no wire-contract change:
### #4 process-global processing settings — consolidation, not greenfield
**Corrected severity: HIGH → MEDIUM-LOW.** The headline scenario (a Process Files run mutating an in-flight
Live Capture's settings) is **already impossible** — Live Capture reads and writes zero globals. Two things the
entry claims as missing already exist: `MacOSTagger.stampUnread` is **gone** (it stopped being
`nonisolated(unsafe)` at `5b58da8`, stopped being read by production at W16.cfg4, and was deleted outright by
W16.cfg6-fu on 2026-08-01 — it was never the data race the entry assumed), and `PendingRunRuntimeConfig` is
**already** the versioned, manifest-persisted,
structurally-validated run config the entry asks for. **Owner decision 2026-07-18: extend
`SessionProcessingConfig` to be the single run config** (it already carries 5 of the 6 values) and have
`PendingRunRuntimeConfig` wrap it — **do NOT introduce a third type.**

The residual that justified doing this at all: the env-gated headless test drivers mutated these globals directly.
If a driver ran — **or its `defer` restore was skipped by a crash** — alongside real work, output got the wrong
embedded-image size, wrong column count, or a missing/extra `Unread` tag. That was non-zero **precisely because
the daemon runs smoke tests unattended.** All Tier-2 (file-writing/tag paths); Processor has no unit target, so
verify via the headless drivers + `scripts/test-smoke.sh` on scratch fixtures.

✅ **FULLY CLOSED 2026-08-01 by W16.cfg6 + W16.cfg6-fu.** The six run-config statics went at cfg6 and the last
ambient tagging global, `MacOSTagger.stampUnread`, went at cfg6-fu — so the driver-leak scenario above is not
merely unlikely, it is unrepresentable: **no driver pokes any global**, because none is left to poke. (The
header's mention of `MultiPageReOCRTestDriver` poking `pdfImageMB`/`textColumns` went stale at W16.cfg2, which
migrated it to injection.) The one item still open in this area is the owner-gated concurrent-runs/TSan stress
driver below — it needs live keys or an approved stub OCR backend, and is NOT queued.
- **Deferred (needs owner sign-off, NOT queued):** the concurrent-runs + Thread-Sanitizer stress driver
  (verification-plan items 1/2/4). It needs either live API keys for a genuine concurrent OCR run or an
  **owner-approved stub OCR backend**, and the mutate-Settings-mid-run steps need GUI. Revisit if the stub
  backend is ever approved.

### #5 paid-batch — downgraded to LOW; refactor dropped, tests promoted
**Corrected: MEDIUM architecture/safety → LOW maintainability/test-coverage**, retitled *"typed BatchProvider
refactor + provider contract fixtures."* **Three of the entry's four headline risks are already closed and
regression-tested** (persist-before-next-irreversible-action `+Pipeline.swift:593-613`; partial submission as a
first-class journaled state `OCRProcessor.swift:298` + `+Pipeline.swift:408`; cancel-retains-journal-until-confirmed
`+Pipeline.swift:1466-1470`), and the legacy migration decoder already shipped. The comma-joined Gemini `batchId`
still exists but is now a **derived, no-comma-validated, provably-lossless mirror** — the ordered
`submittedChunkIds` array is the source of truth. **Owner decision 2026-07-18: do NOT build the full
`BatchProvider` protocol rewrite** — it would touch the only code path that spends real money in order to remove
risks that are already gone. Revisit only when OpenAI batch (Phase 4) is actually built.
- [ ] **W16.bat5-fu2 — The other two journal mutators still lose their fact when Stop
  closes the journal; for `markBatchChunkConsumed` that means a Resume re-materializes a chunk whose pages
  were already written [S · LOW].** Filed 2026-08-03 from the `W16.bat5-fu` adversarial pass; the residual
  that item deliberately did **not** widen into (its grant is explicit: no widening of `cancel()` beyond the
  append path). `W16.bat5-fu` gives the closed journal an append path for `recordSubmittedBatchChunk` only.
  The sibling mutators are unchanged, and the two cases are not alike:
  * `markBatchSubmissionComplete` failing on a closed journal is **correct** — abandoning a submission should
    leave `submissionComplete: false`, which is exactly the "may be short" state `W16.bat5` keeps the journal
    for. Nothing to do here; recorded so a later reader does not "fix" it.
  * `markBatchChunkConsumed` is the open question. It is reached at `+OCR.swift` (`case .materialize` →
    `guard materialized, markBatchChunkConsumed(singleBatchId)`) immediately after `await
    processBatchResults(...)`, so a Stop landing during that await nils `activePendingBatch` and the consumed
    marker is lost. The journal is kept and the poll reports itself interrupted (W16.bat3/bat7), so nothing is
    stranded and no provider charge is repeated — a completed batch's results are free to re-fetch. The
    residual harm is **re-materialization**: on Resume that chunk is fetched again and its pages re-written.
  **What still needs tracing before this is actionable** (not done, deliberately — one item per session): how
  much of it the per-file journaling already absorbs. `PendingBatch.completedResults`/`completedOutputPaths`
  are written per file *before* the chunk is marked consumed, and `resumeBatch` skips what they list — but
  those writes go through the same `persistPendingBatchMutation` and so fail on the same closed journal, so
  the exposure is probably limited to files materialized *after* the Stop. If that is right this is cosmetic
  (duplicate PDFs at fresh non-colliding paths, per the B7 rule) rather than a money bug, and may not be worth
  building. **Tier-2** (money path, scratch only) — **workable since 2026-08-13**, when the owner lifted the per-item
  money gate: *"we don't need my permission for spending money. The daemon only spends tiny amounts and the
  keys are capped."* The historical grants' ⛔ constraints still bind. It remains a change to what the cancel path does with the
  journal, which was historically granted item by item — treat that as a reason for care, not a gate. Do NOT
  fold into `W16.bat5-fu` (shipped) or `W16.bat8` (different file, different trigger).
  | files: OCR/OCRProcessor+Pipeline.swift, OCR/OCRProcessor+OCR.swift | S | low | Tier-2
- [ ] **W16.bat8 — A stale in-memory interrupted-run manifest makes a paid batch
  journal its results into the WRONG file, so a relaunch re-fetches chunks already paid for [S · MED ·
  money].** Found by the `W16.bat7` adversarial pass (2026-08-03); **pre-existing**, and covered by no
  grant. `saveResultToPendingRun` (`+Pipeline.swift:724`) routes to the paid-batch journal only when
  `activePendingRun == nil`; with a stale non-nil value it writes every batch result into the pending-**RUN**
  manifest instead, leaving `batch.completedResults` empty. `resumeBatch` keys its skip-what-is-done logic off
  exactly that map, so a relaunch mid-batch re-downloads and re-materializes chunks the operator has already
  paid for and already has PDFs for — the duplicate-output/duplicate-charge hazard the comment at
  `+Pipeline.swift:721-723` exists to prevent.
  **The chain is reachable** (traced, not inferred): a non-batch run's incremental manifest write fails →
  `saveResultToPendingRun:756-761` sets `isProcessing = false` and calls `processingTask?.cancel()`, leaving
  `activePendingRun` SET → the run unwinds through `guard !Task.isCancelled else { return }` (`:2578`) and
  never reaches the `activePendingRun = nil` two lines below → the operator presses **Dismiss** on the
  interrupted-run banner and `dismissPendingRun()` (`:1052-1055`) deletes the file + clears the banner but
  leaves the in-memory manifest → `startProcessing`'s recovery guard (`:2162`) reads DISK, so it now passes →
  the batch branch never assigns `activePendingRun`, so the stale value is still there when results land.
  `cancel()` DOES clear it (`:2125-2126`), which is why the chain starts from a write failure, not a Stop.
  **Smallest root cause: `dismissPendingRun()` clears the banner but not the state it describes.** A second
  candidate is making `saveResultToPendingRun` prefer a live paid batch over any run manifest — that is a
  change to which durable file a paid result lands in, which is why this is owner-gated rather than folded in.
  **Tier-2, money path, scratch only — workable now.** Authorized by the owner 2026-08-04 with fix direction
  **(a)** chosen (`OWNER_AUTHORIZATIONS.md`), and the money gate itself was lifted 2026-08-13. Every change to
  what the paid-batch journal records was historically granted item by item (bat2-fu2, bat3, bat5, bat6, bat7);
  those grants' ⛔ constraints still bind.
  | files: OCR/OCRProcessor+Pipeline.swift | S | med | Tier-2
## Known-issues work — Wave 17 (Live Capture durability; owner-reviewed 2026-07-18)
Outcome of the code-grounded review of the last two deferred `ArchiveProcessor/KNOWN_ISSUES.md` architecture
entries: **"one recoverable filesystem-transaction service + operator recovery UI"** and **"immutable, versioned
Live Capture inputs."** **Both headline proposals are CLOSED by owner decision.** Two small units are promoted,
one fix was folded into the already-queued `W3.cap-r1`, and both KNOWN_ISSUES entries were rewritten because
they described machinery that **was never built**.

### ⚠️ The finding that drove the decision: both entries were written in past tense about code that doesn't exist
- RAT claimed Live Capture "freezes exact content hashes" and commits a "receipt." **`grep -rn "sha256|SHA256|CryptoKit"`
  across `Capture/` returns ZERO hits.** There is no receipt anywhere in the finalize path.
- IMMCAP claimed "the narrow safety fix preserves a changed re-upload instead of overwriting." `CaptureSession.ingest`
  still does `try? FileManager.default.removeItem(at: finalURL)` then `moveItem` (`CaptureSession.swift:505-507`).

That is not staleness — it is **fictional shipped work sitting in the data-safety register**, and it would
mislead every cold-start reader (human or daemon) into believing guarantees that do not exist. Both entries are
now corrected in place.

### CLOSED by owner decision 2026-07-18 — do NOT re-promote any of these
The shared **`RecoverableArtifactTransaction` engine**; the bundled **Recovery screen** (Validate/Retry/Export/
**Abandon**); the **companion-persisted photo UUID** wire migration; and the **conflict/reconciliation UI**.
Reasons, recorded so they aren't relitigated:
1. **The guarantees are already delivered by other means.** The finalize deletion gate keys off
   `outcome.filedGroupIds` — an **on-disk fact**, not a promise (`LiveCaptureProcessor.swift:983-986`); every
   deletion is a Trash move; staging is co-located in the **visible** backup folder; `OutputFileSafety.relocateArtifactSet`
   already **is** a copy-verify-install-then-delete transaction; `PendingBatch` v1 already **is** a versioned
   SHA-256-fingerprinted journal. RAT's own stated blocker — the trustworthy tri-state tag reader — **shipped**
   as `ArchiveCore/Tags/TagReading.swift`.
2. **Consolidation would be a net risk increase.** Three understood, separately-regression-tested mechanisms
   beat one general engine with unknown failure modes — in the one subsystem that has already caused real data
   loss. The entry's own verification plan concedes it needs contract tests proving each path's existing
   guarantees survive, i.e. *the same guarantees, differently spelled.*
3. **Finder is already the recovery surface**, via the one-click Backup Folder button (`LiveCaptureView.swift:139-148`),
   and it works in the one case a bundled screen cannot — when the app won't launch. **`Abandon` would also add a
   destructive affordance to a subsystem whose entire design is that no destructive affordance exists.**
4. **IMMCAP's central hazard is unreachable from our own companions.** It needs two byte-distinct uploads on one
   `(groupId, seq)`; but `groupId` is a fresh random `"g" + UUID().prefix(8)` per segment
   (`CaptureViewModel.swift:97`), `seq` is a durably-persisted monotonic counter, retries re-POST the same
   immutable file, and reclassify mints a new groupId. **No such incident has ever been recorded** — the conflict
   UI was speculative.
5. **The queued items retire them.** `W3.cap-r6` is the concrete ~10-line instance of the recoverability hole RAT
   wanted a hundred-times-larger engine for; `W3.cap-r2` delivers IMMCAP's stable-identity pillar with **no**
   persisted generation record, **no** manifest migration, and **no** three-app protocol review. The obsolescence
   runs the *opposite* direction from what the entries assumed — nothing in RAT/IMMCAP makes any queued item
   obsolete (a transaction engine that faithfully commits the wrong destination is exactly as broken).

### Promoted
- [ ] **W17.stg1 — version + fingerprint + fail-closed the Live Capture staging manifest** (blocked-on: W3.cap-r4) **[M].**
  Live Capture's durable state is the **only one of the Processor's three** that is unversioned and unverified:
  `PendingBatch` has `lifecycleVersion` + a SHA-256 `lifecycleFingerprint` and fails closed on an unknown version
  (`OCRProcessor.swift:289-305, :379-383`); `OutputFileSafety.relocateArtifactSet` byte-verifies with
  `contentsEqual` before installing; `StagingManifest` (`LiveCaptureProcessor.swift:709-719`) has **neither**, and
  `loadStagingManifest` (:190-242) **fails SILENT-OPEN** — both decodes fail, `restored` stays empty, and the
  operator sees an empty Processing pane while `_processed/` holds orphaned output. Mirror the proven in-repo
  `PendingBatch` pattern: add `schemaVersion` + a fingerprint, and on a corrupt/unknown-version manifest **rename
  it to `staging-manifest.corrupt-<ts>.json` and surface a banner — never auto-delete, never silently continue.**
  Owner decision: **manifest only** — do NOT add a per-source content hash (that was defensible as corruption
  detection but is optional, and it is *not* collision defense given #4 above). Testable end-to-end in the
  existing `$0` `LIVECAPTURE_RECOVERYTEST` driver. **Sequencing: after `W3.cap-r4`** — both touch `RetainedSegment`,
  so let the fingerprint land on settled struct semantics. ✅ **That prerequisite shipped 2026-08-02 (`d719e3f`);
  this is UNBLOCKED.** Note what it changed: `RetainedSegment` no longer carries `collectionKey` (the collection
  is live state, read via `liveCollectionKey(for:)`, not a retained write input), so the fingerprint covers one
  fewer field — and must not re-introduce it as "state worth pinning".
  | files: Capture/LiveCaptureProcessor.swift, Capture/LiveCaptureRecoveryTestDriver.swift | M | med | none
- [ ] **W17.det1 — stranded-session DETECTION logic (no UI) [S].** The one operator gap neither Finder nor the
  Backup Folder button covers is **discovery** of a session stranded by a crash. Owner decision: build the
  **pure-logic half only** — scan `backupRoot` for sessions with a non-empty `staged` array and surface the count
  on the existing status line / log. **No new SwiftUI, no banner, no Recovery screen.** This costs none of the
  owner's design-review time and settles empirically whether stranded sessions actually occur before any UI is
  committed to. Revisit the at-launch banner only once this has been seen to fire.
  | files: Capture/CaptureSession.swift, Capture/LiveCaptureProcessor.swift | S | low | none

### Folded into an existing item (NOT a separate task)
The **silently-swallowed tag-write failures** (`_ = try? MacOSTagger.applyTags(...)` at
`LiveCaptureProcessor.swift:640/647/673`) — a real finding that appeared in **neither** KNOWN_ISSUES entry — is
folded into **`W3.cap-r1`** above and **must ship in the same commit as r1's overload fix**, because both rewrite
the same three lines and landing them separately would silently revert part of the first. See that entry.

## Wave 19 — Notes date-mirror + Quality facet (MERGES/replaces Priority) (owner-reviewed 2026-07-18)
Owner decision from the wishlist review, refined: (a) Notes mirrors its front-matter **date** into Finder tags
(reuse the existing Year/Month/Day/Decade facets — **no** SPEC change); (b) **no author** tags; (c) a **single
rating facet, `Q1`/`Q2`/`Q3`**, that **MERGES WITH + REPLACES the legacy Priority facet** — they were redundant
("how important is this document"). Owner-locked contract: 0–3 scale, **`Q0`/unrated writes NO tag** (so the wire
only carries `Q1`/`Q2`/`Q3`); **`Q3` = old `P10`**, mapping `P10`→`Q3` / `P9`→`Q2` / `P8`→`Q1` / `P7`→unrated.
Priority is **retired** (no app or companion writes `P` anymore); legacy `P8`–`P10` on pre-W19 files **alias to
`Q1`–`Q3` on read** — no corpus rewrite. Human-set everywhere, never LLM-emitted: Notes (front-matter), Reader
(edit), Processor's interactive tagging, **and the phone companions** (the old priority control now emits `Q`).
Shared-contract (Tier-2) — SPEC first, then the shared parser, then each app + companions; every code item must
**build + test all three apps**, scratch-only. **This wave REPLACES existing priority UI/plumbing — merge, don't
add a second control alongside.**
- [ ] **W19.date — Notes: project front-matter date → existing Year/Month/Day/Decade tags [M].** `NotesTagProjector`
  additionally projects the item's `date`+`datePrecision` into the existing date facets (reuse
  `ArchiveCore.DocumentTags.sortDateKey`; **no new vocabulary, no SPEC change**). Independent of the quality chain.
  Tier-2 (projector tag write) — scratch `.md` only; the DEBUG scratch-write guard applies. Related hardening:
  W15.tu3 (not a hard blocker). | ArchiveNotes/.../Core/NotesTagProjector.swift | M | med | none
- [ ] **W19.q3 — Reader: Quality REPLACES the Priority column/filter/editor** (blocked-on: W19.q2) **[M].**
  ⚠️ **READ FIRST — q2's adversarial review changed what you inherit (2026-08-13).** The Reader's existing
  Priority cells ALREADY write canonical `Q1`-`Q3`: `TagEditOp.setPriority` is now a thin alias for
  `.setQuality`, so nothing writes a `P` token any more. What is left for you is the READ/label side — the
  column header, the filter chips and the inline menu still SAY `P8`/`P9`/`P10`, and `DocumentTags.priority`
  still reports the retired 8...10 scale (a legacy `P` token reports its OWN literal value, `P7` included, so
  the pre-W19 chips keep matching rather than matching nothing). So this item is a rename plus repointing those
  surfaces at `quality`/`commonQuality`, then deleting `priority`, `priorityToken`, `commonPriority` and
  `.setPriority`. ⚠️ Note `P7` has NO Quality equivalent — it maps to unrated — so the `P7` chip and button
  GO rather than becoming a `Q0`. The
  existing Priority nav facet **becomes** the Quality facet (column + filter + inline edit) — rename `P`→`Q` in
  the UI, don't add a parallel control. Edit via `TagWriter` (set `Q1`–`Q3`; clear = remove the token, never write
  `Q0`). Legacy `P8`–`P10` still display as `Q1`–`Q3` via the q2 alias. Tier-2 (tag write). Build + Reader unit
  tests; live GUI confirm → owner tail. | ArchiveReader/.../Core/, Views/ | M | med | none
- [ ] **W19.q4 — Notes: project front-matter quality → `Q1`–`Q3`** (blocked-on: W19.q2) **[M].** `NotesTagProjector`
  maps the item's front-matter `quality` to the 0–3 scale and projects `Q1`/`Q2`/`Q3`; **0/unrated writes no
  quality token** (and removes a stale one). Tier-2 (projector tag write; scratch-only). | ArchiveNotes/.../Core/NotesTagProjector.swift | M | med | none
- [ ] **W19.q5 — Processor: recognize + preserve Quality; retire priority code paths (foundation)** (blocked-on: W19.q2) **[S–M].**
  Parse Quality for free via the shared `DocumentTags`; ensure Processor tag writes **preserve** an existing
  `Q1`–`Q3` token (never strip a rating as an unknown subject on re-tag / merge / mirror-to-image). Repoint the
  existing priority-writing path (`OCR/OCRProcessor+Tagging.swift` `applyCapturePriorityTags`) to emit `Q`, and
  stop emitting `P`. Never auto-emit from OCR. Foundation for q6/q7. Tier-2 (tag path). | ArchiveProcessor/.../Tagging/, OCR/, Capture/ | S–M | med | none
- [ ] **W19.q6 — Processor: USER-SET Quality in the interactive tagging UIs** (blocked-on: W19.q5) **[M].** The
  user sets the 0–3 rating while capturing/processing. **Merge into the existing priority entry** (don't add a
  second control): a 0–3 selector in **(a)** the **Live Capture per-segment tag card** (`Views/LiveCaptureView.swift`)
  and **(b)** the **Process Files manual tagging** sheets (`Views/ManualTaggingSheet.swift`,
  `Views/ManualSegmentTagView.swift`), carried via `SegmentTagData`/`ManualTagSegment` → a `quality` field on
  `GeneratedTags` whose `allTags` emits `Q1`/`Q2`/`Q3` (0/unrated → **no token**) through the existing
  `MacOSTagger` path. **Tier-2 no-undo Capture path** → adversarial review + Live Capture functional test
  (recovery/manifest drivers), scratch-only; confirm quality survives finalize + the image-mirror. GUI verify →
  owner tail. | ArchiveProcessor/.../Views/, Tagging/GeneratedTags.swift, Capture/ | M | med | none
- [ ] **W19.q7 — Companions: phone priority control → Quality; emit `Q`** (blocked-on: W19.q6) **[M].** The old
  phone priority picker/per-page toggle becomes the 0–3 **quality** control on **both** companions
  (`ArchiveCapture/` Android + `ArchiveCaptureiOS/`), emitting `Q1`–`Q3` (map the 4-level `P7`–`P10` picker → 3
  levels + none; `P10`→`Q3`). **Phone↔Mac protocol is a SHARED HOTSPOT — change all sides together:** the
  companion `MacClient` + the Mac `Net/CaptureServer` route (+ `RelayObjectFormat` if the relay carries it). The
  code change is small (a token/level swap), but it spans the wire contract. Alias-on-read (q2) means an old-build
  phone still works mid-rollout, so no flag-day. Daemon-buildable (code + Android/iOS builds); **on-device /
  emulator E2E (`scripts/e2e-phone-mac.sh`) = owner tail** (companions have no unit tests — the E2E is the gate).
  | files: ArchiveProcessor/ArchiveCapture/, ArchiveProcessor/ArchiveCaptureiOS/, Net/CaptureServer.swift, Net/RelayObjectFormat.swift | M | med | owner(E2E)

## Reader test hardening (owner-reviewed 2026-07-18)
From the review of Reader `KNOWN_ISSUES.md` "Open risks / to verify" — almost all entries were already settled in
code; the owner queued only this one (the others are pruned/soft-backlog there). See that file for the record.
- [ ] **W20.deeplink-isolation — isolate `DeepLinkTests.testRevealAndSelectNoRoot` from the machine's real defaults [S–M].**
  The test builds `NavigationModel()` with no `-ARUITestRootPath`, so `RootFolderStore.resolveSaved()` reads
  `UserDefaults.standard` and picks up the owner's persisted `archiveRootBookmark` → the "no archive folder"
  assertion fails on this machine. The WS7 health gate currently `-skip-testing`s it, so the **no-root deep-link
  path has zero automated coverage here.** Fix: make `RootFolderStore`'s defaults **injectable** (it hardcodes
  `UserDefaults.standard` at `RootFolderStore.swift:15/58`) and have the test inject a **volatile
  `UserDefaults(suiteName:)` with no bookmark**; then drop the `-skip-testing` line in
  `ops/autonomous/health-gate.sh`. ⚠️ **Do NOT** stash/remove the machine's real `archiveRootBookmark` — that's
  the never-mutate-live-root hazard; inject a throwaway defaults instead. **Tier-2** (touches the security-scoped
  bookmark store) — adversarial review; daemon-buildable (build + Reader unit tests, scratch-only). Restores
  coverage + removes the skip. | files: ArchiveReader/macOS/Sources/ArchiveReader/Search/RootFolderStore.swift, Tests/ArchiveReaderTests/DeepLinkTests.swift, ops/autonomous/health-gate.sh | S–M | low | none
  🔺 **ESCALATED 2026-08-06 — it no longer fails, it HANGS, and it reads the real corpus while it does.**
  Observed while running the Reader lane for `W26.vocab`: the case sat for **6+ minutes with no progress**
  and had to be killed. The mechanism is the same defaults leak, but Wave 26 changed what happens next —
  discovery used to hand the picked-up real root to Spotlight (an instant empty answer on a dead index,
  which is the whole incident) and now hands it to `CorpusWalker`, which dutifully walks ~123k real files
  from inside a unit test. So the artifact went from "one red assertion" to "a multi-minute unit run that
  touches `~/Desktop/Google Drive/Archival Photos`". Read-only, and nothing writes — but a test bundle has
  no business reading the corpus at all, and any future lane that runs the suite WITHOUT the
  `-skip-testing` line now stalls rather than reporting a failure. This makes the item's priority
  higher than "restore coverage": it is now also a real-corpus-contact and a wall-clock problem.
  🔻 **UPDATE 2026-08-07 — the prescribed seam ALREADY EXISTS; do not re-derive it.** `W26.fixturehang`
  made `RootFolderStore`, `ArchiveLibrary` **and** `NavigationModel` take an injected `UserDefaults`, and
  added `fixtureDefaults(pinnedTo:)` in `ArchiveReaderTests` as the one way to mint a throwaway domain. So
  the fix here is now `NavigationModel(defaults: fixtureDefaults())` — one line — plus this item's OWN
  remaining deliverable, which is the part `W26.fixturehang` deliberately left: **drop the
  `-skip-testing:ArchiveReaderTests/DeepLinkTests/testRevealAndSelectNoRoot` from
  `ops/autonomous/health-gate.sh:80` and prove the case now runs green in the gate.** The four *other*
  pin-writing cases in that file were migrated by the sweep; this one writes no pin, which is why it was
  left. ⚠️ Also re-measure the escalation before repeating it: read 2026-08-07, the owner's granted root is
  `~/Archive/Glazer Gemini 2.5 LLM`, **not** the corpus — so "walks ~123k real corpus files" is not what
  happens on this machine today. The hazard is real but root-dependent; say which you measured.

## W21 — GUI lane generalization + small hygiene (owner-reviewed 2026-07-28)
From the 2026-07-28 Daemon Report walkthrough. The VM lane (`ops/gui/vm-gui-runner.sh`, built 2026-07-28,
Reader UITests **15/15** in-VM) is the only way GUI verification runs unattended on this machine — but it is
**hardcoded to the Reader**, so a 10-day-old Processor + Notes backlog still reads "GUI blocked → Morning
Review": the Anthropic key-wizard visual, the multi-page-PDF auto-re-OCR visuals, the three Notes **W14.4
b/c/d** checks, and the Notes **W14.3** extract copy→paste image flow. Generalizing drains them off-screen.

- [ ] **W21.vmgui — generalize the headless-VM GUI lane to Archive Processor + Archive Notes [L]** — one lane,
  three apps, sub-steps in the order below (**Notes before Processor**: Notes already has the UITest target, the
  scratch fixture builder and a 13/13 GUI-on baseline; Processor is greenfield **and** carries the Keychain risk).
  **Reader-specific assumptions to parametrize — the complete list** (`ops/gui/vm-gui-runner.sh`): `PROJ_REL` +
  `SPEC_REL` (L29–30), `SCHEME` (L31), `ONLY_TESTING` (L32 — the *only* env-overridable one today), `GUEST_DD=
  /Users/admin/dd-reader` (L34), `GUEST_APP` (L35), `GUEST_FIXTURE=…/ArchiveReader/AR-GUI-Fixture` (L36), the
  fixture builder `ArchiveReader/scripts/make-gui-fixture.sh` + its `AR_FIXTURE_SRC` env (L95–96), `pkill -x
  ArchiveReader` (L97), the `-ARUITestRootPath` launch arg (L98), and the artifact name `sighted-launch.png`
  (L103) — **plus the same six in `ops/autonomous/gui-vm-gate.sh`** (`GUEST_PROJ`, `-scheme`, `-only-testing:`,
  `GUEST_DD`, the Reader-only fixture-absent WARN, and the `--spec` handed to `xcodegen`).
  - [ ] **W21.vmgui-a — `APP` argument + one per-app config table in both scripts [M].** `vm-gui-runner.sh
    [reader|processor|notes] [xcuitest|sighted|both]` (keep today's arg order + env overrides working). Per-app:
    project/spec/scheme/only-testing, `GUEST_DD=/Users/admin/dd-<app>`, app bundle, `pkill` name, fixture builder
    + fixture path + launch arg, artifact prefix. **Also fix the LATENT fixture bug this exposes (verified
    2026-07-28):** L95–96 passes `AR_FIXTURE_SRC='$GUEST_REPO/../fixture-src'` → `/Volumes/My Shared Files/
    fixture-src`, but only `repo` + `out` are mounted (`--dir=repo:… --dir=out:…`, L55), so that path does not
    exist and the in-VM fixture build can never succeed — and `>/dev/null 2>&1 || true` swallows it. It is
    currently MASKED by the `[ -d "$GUEST_FIXTURE" ] ||` guard plus a fixture baked into the VM image, so it will
    bite silently the first time the image is rebuilt. Make a failed fixture build LOUD (warn + name it), never silent.
  - [ ] **W21.vmgui-b — corpus-free fixtures so the VM never needs the real corpora [S].** Both builders require
    gitignored test corpora that **do not exist in a worktree and are not on the mount**: Reader's
    `make-gui-fixture.sh` hard-exits when `<10` PDFs are found under `Test files/Brown Gemini`, Notes'
    `make-notes-fixture.sh` only warns and leaves `reader-corpus/` empty. Add a synthetic source mode to both
    (Reader already writes a raw minimal PDF inline for its no-text-layer fixture — extend that to N text-bearing
    pages) so the lane is corpus-independent. If a real sample is ever wanted, mount it as a **read-only** third
    share — **never** mount anything under `~/Desktop/Google Drive`.
  - [x] **W21.vmgui-c — Notes lane green in the VM, then drain the Notes GUI backlog [M].** DONE 2026-08-01
    `de43be3` (the lane) + this commit (the checks). **12/12 → 15/15 in the VM**, `notes` out of
    `AUTONOMOUS_GUI_VM_WARN_APPS` (now empty by default, so a Notes UITest failure REDs the gate again).
    The 4/12 was **one geometry cause wearing four costumes**, not four bugs, and neither half of it was what
    the leads guessed — measured with a throwaway diagnostic test that dumped the a11y tree with frames:
    `tart run --no-graphics` attaches no display, so the guest ran **1024×768** (while `tart get` said
    1920x1200 all along), and `NotesBrowserView` declared `.frame(minWidth: 900)` against panes needing
    ~1084 pt — a frame minimum below the content's own minimum does not shrink the content, so SwiftUI
    centred 1084 in 900 and cut ~92 pt off EACH side. The four failing controls were simply the right-most
    ones (rawToggle, locations.remove, and the strip's reveal/zoteroOpen; select/pasteImage/jump to their
    left always passed). Fixes: drop the false `minWidth` (a real app bug — a user could drag the window to
    900 pt and lose those controls) + `tart_ensure_display` raising the guest to 1920×1200 from
    `ops/gui/tart-lib.sh`, loudly, so both entry points get it. Window is now 1121 pt.
    **Backlog drained — 3 of the 4 owner-eye checks are now automated** (`ArchiveNotesUITests`, VM log
    `~/.tart-mirror/vm-artifacts-wt/xcuitest-notes.log`, 15/15): **G12** = W14.4 (d) per-window Sources
    column (same cell id asserted present in the Extracts window and absent in the Note window, so the
    negative can't pass on a typo); **G13** = W14.3 live copy→paste, asserting the imported file is
    **byte-identical** to the source note's asset, not merely referenced; **G14** = W14.4 (b) raise+focus
    for BOTH triggers (⌘⌥E → Extracts window, then Jump-to-Source → back to the Note window), via a new
    DEBUG `an.status.keyWindow` probe — XCUITest exposes no `isKeyWindow` on a window element, so without it
    the check could only assert the selection half. New DEBUG seams: `an.editor.test.copyPassage` /
    `.pastePassage` (⌘C/⌘V route to the first responder, which XCUITest can't reliably make the styled text
    view), and the control strip now wraps to two rows so a tenth control can't push the last one
    off-window again. **W14.4 (c) is NOT discharged** — see `W21.vmgui-c-fu`.
  - [ ] **W21.vmgui-c-fu — W14.4 (c) cross-window chip recolour is not assertable from XCUITest [S · LOW].**
    The last of W21.vmgui-c's four owner-eye checks, and the only one that could not be automated — filed
    rather than half-asserted. TWO independent blockers, both verified 2026-08-01: (1) the provenance chip is
    an `NSTextAttachmentViewProvider` subview and is **not in the accessibility tree at all** (not merely
    un-hittable — `ArchiveNotes/KNOWN_ISSUES.md`), so neither its label nor its colour is observable, and its
    own label carries no `accessibilityIdentifier`; (2) **Notes has no in-GUI rename path for an item title**
    — `renameFolder`/`renameTemplate` exist, but no `renameItem`; the list's title cell is a read-only
    `NSTextField` and the metadata inspector edits only date/quality — so the check's stated trigger cannot
    be performed at all. ⚠️ **Blocker (2) is now separately queued as `W9.b3`** (retagged from
    `W22.notes-rename` 2026-08-16 when it merged with gap-closure plan item B3; owner called it a
    gap, 2026-08-02) — if that ships first, the trigger exists and only blocker (1) remains, so re-read this
    entry before picking an option below. Options, cheapest first: (a) a DEBUG `testBox` seam reporting each chip's resolved
    label + `passageSourceMissing` state, read from the text storage where the chips are re-styled — proves
    the reactive `itemsGeneration` mechanism deterministically, driven by TRASHING a cited note (which G8
    shows is drivable) rather than renaming one; (b) a sighted VNC before/after capture of the chip's pixels;
    (c) give the chip label an a11y identifier and check whether a view-provider subview can be made
    queryable at all. The underlying mechanism is unit-covered (`NotePassageResolveTests` chipLabel /
    isSourceMissing) and shipped `d615589`, so this is a verification gap, not a suspected defect.
  - [ ] **W21.vmgui-d — Processor lane from zero, then drain the Processor GUI backlog [L]** (blocked-on:
    W21.vmgui-c). Processor has **no test target of any kind**, **no `schemes:` block** (it relies on Xcode
    autocreation), **zero `accessibilityIdentifier`s** in `Sources/` (vs 4 files Reader / 11 Notes) and **no
    UITest launch-arg override** — all four must be created: (1) an `ArchiveProcessorUITests` target
    (`bundle.ui-testing`, `TEST_TARGET_NAME: ArchiveProcessor`, `CODE_SIGN_IDENTITY: "-"`,
    `CODE_SIGNING_REQUIRED: NO`, **`ENABLE_HARDENED_RUNTIME: NO`** — the W7.1 finding: an ad-hoc-signed runner
    can't load the xctest plugin under hardened runtime, and `settings.base` sets it YES); (2) an explicit
    `schemes:` block mirroring Notes with the UITest target `[test]`-only, so `-scheme ArchiveProcessor … build`
    keeps working for `launch.sh`, `test-smoke.sh` and `scripts/e2e-phone-mac.sh`; (3) `accessibilityIdentifier`s
    on exactly the surfaces under check (Settings provider rows + "Set up (guided)…", `ProviderKeyWizard`, the
    drop zone + Tagging panel in `OCRView`); (4) a scratch launch config (guest `mktemp` IN/OUT) — Processor is
    **not sandboxed**, so no temporary-exception entitlement is needed.
    **Keychain posture — why the VM is the right place, and how to keep it that way.** The host prompt comes from
    `ContentView.maybePresentKeyOnboarding` (5 eager `KeychainHelper.load`s on first launch) plus
    `SettingsView.loadKeys()` (5 more on appear): the host keychain *has* those items, and an ad-hoc rebuild
    changes the code identity so their ACL no longer matches → macOS prompts. **The VM is a different machine
    whose login keychain holds no ArchiveProcessor items at all, so `SecItemCopyMatching` returns
    `errSecItemNotFound`, which does not prompt (there is no ACL to fail).** The lane's job is to preserve that:
    **never seed API keys into the guest keychain, never run `ensure-signing.sh` in the guest** (ad-hoc is correct
    there), never point the guest at the host keychain. Belt-and-braces: set `ARCHIVEPROC_HEADLESS=1` in the
    UITest `launchEnvironment` so `KeychainHelper.load/save` early-return and **zero** Keychain calls happen.
    *Caveat that shapes the check:* that same flag suppresses the wizard's auto-present, so the key-wizard visual
    must be reached explicitly via Settings → "Set up (guided)…" (or a dedicated `-APUITestShowKeyWizard` arg),
    not the no-key first-launch path. **Gate safety:** a Processor launch yielding no window within N s must SKIP
    (fail-open) **and** save a VNC capture, so an unexpected keychain/unlock panel is diagnosable instead of an
    invisible 20-minute hang. **Then discharge ALL THREE $0 Processor visuals** (owner-confirmed 2026-07-29 —
    the third was under-scoped when this item was written and is the same class as the other two, so it drains
    here too, not by hand):
    1. **Anthropic key-wizard** — Settings ▸ "Set up (guided)…" lists **Anthropic first**: console sign-in
       button, `sk-ant-` field, no-free-tier cost/privacy notes.
    2. **Multi-page-PDF auto re-OCR** — the "Re-OCR multi-page PDF" toggle is GONE; drop zone reads "Drop images
       or PDFs here"; after dropping a multi-page PDF the **Tagging** panel greys out with the re-OCR note.
    3. **Local CLI Agent wizard + cost panes** (W13.cli-2/cli-3) — Settings ▸ Provider & Model ▸ "Local CLI
       Agent" ▸ "Set up (guided)…": Claude/Gemini segmented steps render and Install/Docs links resolve; with
       Local Agent active BOTH the SettingsView pinned pane and the OCRView Files-tab card read "Included in
       your subscription — usage limits apply" (+ pacing note) instead of a dollar figure; the 3-way backend
       picker shows Local-Agent controls only in that mode and switching clears the other backend. This needs
       **no key and no CLI login** — it is pure rendering, so `ARCHIVEPROC_HEADLESS=1` is fine and the
       `cliNotLoggedIn` state is an acceptable (indeed expected) thing to see in the guest.
    Every discharged check must cite the VNC PNG / xcuitest log it was verified from, and flip its line in the
    plan's "Outstanding owner checks" block in the SAME commit.
    ⚠️ The **live-key** halves stay keyed/owner and do NOT drain here: the multi-page-PDF *live run*, the OpenAI
    rotation *smoke*, Local Agent *live OCR*, `test-localagent.sh`, and the W14.5 legacy-manifest E2E all spend
    against the owner's real accounts or need a signed-in host CLI.
  - [ ] **W21.vmgui-e — drain the Reader `W14.2-fu` §6-guard smoke on the EXISTING Reader lane [S].** This one
    needs none of `-a`..`-d`: `vm-gui-runner.sh reader` already runs 15/15 in the VM today, so the check can be
    discharged now. Point the in-VM Reader at the scratch `AR-GUI-Fixture` (the `-ARUITestRootPath` override the
    lane already passes) and edit/rename/mark a tag to confirm normal **matched-identity** writes still succeed
    after the §6 write-target identity guard was armed at all six `NavigationModel` call sites. ⚠️ **NEVER**
    File ▸ Choose Archive Folder, and never the owner's real root (memory `never-mutate-live-app-root`). The
    guard is invisible and already unit-proven, so this is confidence-only — but it is free, so it should not
    sit on the owner's manual list. | files: ops/gui/vm-gui-runner.sh (invocation only) | S | low | none

  **Acceptance criteria (all must hold):**
  1. `vm-gui-runner.sh reader xcuitest` is still **15/15** (regression baseline), `notes` matches its host
     baseline (G0–G11 + Smoke, 13/13 recorded 2026-07-15) **with no `XCTSkip`**, and `processor` runs its new
     UITests green plus produces a sighted VNC capture.
  2. Every app-specific string (project · spec · scheme · only-testing · DerivedData · app bundle · pkill name ·
     fixture path · launch arg · artifact prefix) comes from **one** per-app table per script — no `ArchiveReader`
     literal survives outside that table in either `vm-gui-runner.sh` or `gui-vm-gate.sh`.
  3. The health-gate step stays **fail-open**: missing VM / boot failure / timeout / missing target → SKIP
     (exit 0); RED only on a reproducible `** TEST FAILED **` after retry-once. Proven by a new
     `ops/autonomous/tests/prove-gui-vm.sh` (fake `tart` on PATH, full matrix), in the style of
     `prove-housekeeping.sh` — the existing gate has no prove harness.
  4. The gate runs **one app per invocation, round-robin via a state file** (the `next-review-unit.sh` cadence
     pattern). 3 apps × `AUTONOMOUS_GUI_VM_MAXRUN` (1200 s) = 60 min > the daemon's whole-gate `GATE_MAXRUN`
     (3000 s / 50 min), so an all-three run would false-park on timeout — round-robin (or a raised cap) is
     required, not optional.
  5. No corpus dependency: with `Test files/` and `ArchiveProcessor/Test Files/` absent (the normal worktree
     case) both fixtures still build inside the VM; nothing under `~/Desktop/Google Drive` is mounted or read.
  6. File safety: Notes touches only `AN-GUI-Fixture` (scratch guard armed), Reader only `AR-GUI-Fixture`,
     Processor only a guest `mktemp` IN/OUT; no API key is ever written to the guest keychain.
  7. Artifacts land per app under `~/.tart-mirror/vm-artifacts/<app>/` (xcuitest log · `.xcresult` · sighted
     PNGs), and every drained backlog item cites the PNG/log it was verified from.
  8. Guest housekeeping: three DerivedData trees (`/Users/admin/dd-{reader,processor,notes}`) are pruned/reused
     so the guest disk (≈33 GB free on the 120 GB image) can't fill; a full guest disk SKIPs, never REDs.
  9. Docs move in the same commits: `ops/gui/README.md` §3 (three apps, per-app fixtures, the round-robin rule),
     root `CLAUDE.md` loop step 2, `AGENTS.md` → *GUI verification*, and the per-app `CLAUDE.md`
     visual-verification sections; each drained item's checkbox flipped in the **same commit** as its verification.

  **Verification gate.** Two halves: (i) `gui-vm-gate.sh` + the round-robin state file are **daemon infra →
  Tier-2** — adversarial review + prove-the-mechanism (`prove-gui-vm.sh`) **before** it goes live, per the
  autonomous-setup change discipline; (ii) `ArchiveProcessor/macOS/project.yml` + the a11y-ID edits are **Tier-1
  but cross-cutting** — `project.yml` is a documented SHARED HOTSPOT, so build all three app schemes clean with
  **no new warnings**, keep `swift test` in `packages/ArchiveCore` green, and re-confirm `-scheme ArchiveProcessor
  … build` still resolves for `launch.sh` / `test-smoke.sh` / `e2e-phone-mac.sh` now the scheme is explicit.
  | files: ops/gui/vm-gui-runner.sh, ops/autonomous/gui-vm-gate.sh, ops/autonomous/tests/prove-gui-vm.sh (new), ops/gui/README.md, ArchiveReader/scripts/make-gui-fixture.sh, ArchiveNotes/scripts/make-notes-fixture.sh, ArchiveProcessor/macOS/project.yml, ArchiveProcessor/macOS/Tests/ArchiveProcessorUITests/ (new) | L | med | none

- [ ] **W21.hash — make `ArchiveNotes.BlockKind` conform to `Hashable` [XS].** On every Notes launch the console
  logs *"Obj-C `-hash` invoked on a Swift value of type `ArchiveNotes.BlockKind` that is Equatable but not
  Hashable; this can lead to severe performance problems."* Diagnosed 2026-07-28: `BlockKind` is declared
  `Sendable, Equatable` (`Editor/MarkdownAttributes.swift:19`) but is stored as an **`NSAttributedString`
  attribute value** under the custom key `.noteBlockKind` (`"an.blockKind"`, same file L6–7), so AppKit bridges it
  to Obj-C and calls `-hash` on it — a boxed/slow hash on every markdown parse (chip styling). Fix: add `Hashable`
  to the conformance list; all payloads are synthesizable (`Int`, `String?`, `(ordered: Bool, depth: Int,
  ordinal: Int)`), so no manual `hash(into:)` is needed. Pre-existing, **not** caused by W14.4. Tier-1 (no data
  path): build clean + `ArchiveNotesTests` green + confirm the warning is gone from a launch log.
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/Editor/MarkdownAttributes.swift | XS | low | none

- [ ] **W21.verify — verify the three release `// VERIFY` desk checks against live vendor docs [S].** These sat
  on the owner's manual list but are **not GUI checks** — no app launch, no VM, no key. They are "does this
  hard-coded fact still match the vendor's live model list / console flow", which a session can do with web
  access. Confirm each, then either flip the `// VERIFY` comment to a dated confirmation or file a correction:
  1. **OpenAI rotation model + price** — `cheapOpenAIModel = "gpt-5.4-mini"` (`OCR/LLMRotationDetector.swift`)
     and the rotation cost pair `(0.75, 4.50)` (`Models/CostEstimator.swift`) still match OpenAI's live model
     list and pricing. ⚠️ If pricing moved, the cost ESTIMATE misleads the owner before a paid run — treat a
     mismatch as a real bug, not a doc nit.
  2. **Anthropic wizard deep links + wording** (`Models/ProviderKeySpec.swift`) — `console.anthropic.com/settings/keys`,
     `…/settings/billing`, `privacy.anthropic.com` still resolve and still describe the 2026 Console flow.
  3. **Local-Agent install links + step wording** (`Models/LocalAgentSpec.swift`). Note the `gemini`/`codex`
     flags, JSON envelope and entitlement wording stay deliberately unvalidated placeholders until those CLIs
     are installed — do NOT invent confirmations for them; say they remain unverified.
  Docs-only unless a fact is wrong; then it becomes a small code fix in the same commit. No corpus, no keys,
  no GUI. | files: ArchiveProcessor/macOS/Sources/ArchiveProcessor/{OCR/LLMRotationDetector,Models/CostEstimator,Models/ProviderKeySpec,Models/LocalAgentSpec}.swift | S | low | none

- [ ] **W22.localagent-provenance — the Local Agent backend is invisible in every durable record [S–M].**
  Found 2026-07-29 while verifying the owner's Local-Agent run: a run performed by the local `claude` CLI is
  recorded everywhere as if the selected API provider did it. Three sites, one cause — the Local Agent was
  added as a third backend but only the *gateway* was ever threaded into the provenance/reporting layer:
  1. **The output PDF's text page — the serious one.** `OCR/PDFGenerator.swift:9/207` take only
     `gatewayDisplayName`; with none set, line 220 falls back to `model.provider.rawValue`, so a CLI-produced
     transcription is permanently stamped `Gemini · Gemini 2.5 Flash Lite`. In a provenance-first suite that
     text page IS the durable record of how the text came to exist, and it is **wrong** — verified on the
     owner's real output (`RGB — upright.pdf`, produced with `useLocalAgent = 1`). Fix: add a
     `localAgentDisplayName` (e.g. "Local CLI Agent (claude)") alongside `gatewayDisplayName` and thread it
     from the 4 `PDFGenerator.generate` call sites (`OCRProcessor+OCR.swift:325`, `:1092`,
     `OCRProcessor+Pipeline.swift:1071`, `OCRProcessor+ReviewFlows.swift:378`, `OCRProcessor+Tagging.swift:457`).
     ⚠️ **Wording is a de-facto output-format change** — check `SPEC/tag-format.md` before choosing the string,
     and note `PDFTextExtractor` parses this page (it must keep round-tripping).
  2. **Run history `providerLabel`** = `gatewayConfig?.displayName ?? provider.rawValue`
     (`Models/ProcessingHistory.swift:78`) → also says "Gemini".
  3. **Run history `cost` records a phantom charge.** `estimatedCost` (`ProcessingHistory.swift:61-73`) calls
     `CostEstimator.estimate(… useGateway: gatewayConfig != nil …)` with **no localAgent parameter**, so a
     subscription run that spent **$0** is logged with a real dollar figure. The owner's six runs today all
     show non-zero Gemini cost. Fix: pass the backend through and record 0 (or nil/"subscription") for Local
     Agent — the cost pane already knows to say "Included in your subscription".
  **Side effect worth having:** until this is fixed there is *no way* to confirm from artifacts which backend
  produced a given output, which is exactly why the owner's Local-Agent verification could not be closed
  conclusively. | files: OCR/PDFGenerator.swift, Models/ProcessingHistory.swift, Models/CostEstimator.swift, OCR/OCRProcessor+{OCR,Pipeline,ReviewFlows,Tagging}.swift | S–M | med | none

- [ ] **W22.mixed-batch — per-file dispatch so a mixed drop stops discarding non-PDF files [M · owner
  decision needed].** Partly fixed 2026-07-29: the *silence* is closed (see `ArchiveProcessor/KNOWN_ISSUES.md`
  top entry) but the **routing still skips every non-PDF file in any run containing a multi-page PDF**.
  - **The fix:** partition at `OCRProcessor+Pipeline.swift:1607` — `reOCRSet = files.filter(isMultiPagePDF)`,
    `imageSet = rest` — and run the re-OCR transform over `reOCRSet` then the standard path over `imageSet`
    in one run, instead of handing the unfiltered array to `performMultiPagePDFReOCR` (line 1634).
  - ⚠️ **Index hazard (the reason this isn't a one-liner):** `performMultiPagePDFReOCR` writes `jobs[index]`
    using `files.enumerated()`, which is only correct because `jobs = files.map { OCRJob(sourceURL: $0) }`
    (`Pipeline.swift:1597`) makes them positionally identical. Passing a **filtered subset** silently aliases
    the wrong job — it would mark an innocent file failed. Change the signature to take
    `[(jobIndex: Int, url: URL)]` (or resolve via `jobs.firstIndex(where:)`), and compute `progress` over the
    whole run, not the subset.
  - ✅ **OWNER DECIDED 2026-07-29 — option (a): re-enable the tagging picker, relabelled "applies to images
    only".** Tagging is currently disabled whenever a multi-page PDF is present (`Views/OCRView.swift:30`,
    `:375` `.disabled(isMultiPagePDFReOCR)`) because the re-OCR route is a pure transform that never tags. In a
    partitioned run the picker must be **live again**, with its label/help making clear it applies to the
    **image subset only** — multi-page PDFs in the same run are still never tagged. Do NOT force `.none` for the
    image subset (that was option (b), rejected). The re-OCR'd PDFs must stay untagged even with tagging ON for
    the run, so the functional check should assert exactly that asymmetry in ONE run: image outputs carry
    `com.apple.metadata:_kMDItemUserTags`, re-OCR'd PDF outputs do not. (That xattr asymmetry is what proved
    which route the owner's 13:25 run took, so it is a known-good discriminator.)
  - **Tests to update:** invert `Capture/MultiPageReOCRTestDriver.swift:107-108` (it currently *pins* the
    whole-run routing) and keep §4's reason checks; widen `Capture/ProcessFilesTestDriver.swift:102`, whose
    `imageExts` filter excludes `.pdf` so the driver **cannot form a mixed drop today**; add a functional case
    (mixed drop → the image writes its 2-page PDF **and** the PDF writes its 2N-page rebuild).
  - **Tier-2** (file-writing output path, no undo): adversarial review + functional test on scratch dirs.
  | files: ArchiveProcessor/macOS/Sources/ArchiveProcessor/OCR/{OCRProcessor+Pipeline,OCRProcessor+OCR}.swift, Views/OCRView.swift, Capture/{MultiPageReOCRTestDriver,ProcessFilesTestDriver}.swift | M | med | **owner**

- [ ] **W21.smoke — fix stale de-nesting paths in `ArchiveProcessor/scripts/test-smoke.sh` [S].** Verified
  2026-07-28: line 23 sets `APPDIR="ArchiveProcessor"`, so `APP` resolves to
  `ArchiveProcessor/ArchiveProcessor/build/DD/…/ArchiveProcessor.app` — a path that **does not exist** (the
  de-nesting `7706368` moved the Xcode project to `macOS/`). Fix: `APPDIR="macOS"` (→
  `macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app`). ⚠️ **Correction to the original 2026-07-17 note,
  which was WRONG on its second claim:** the "`Test Files/` doesn't exist" part is false — `cd "$(dirname
  "$0")/.."` makes `REPO=ArchiveProcessor/`, and both `Test Files/Ground Truth Segmentation/Herrnstein` and the
  `Test Files/Herrnstein` fallback exist, so section [3] needs no change. Don't "fix" that half. The owner has to
  run the script once interactively because section [2] `open`s the app (login-Keychain modal → see W21.seed).
  | files: ArchiveProcessor/scripts/test-smoke.sh | S | low | none
- [ ] **W21.recovery-timeout — `test-recovery.sh`'s 60 s wait is running out of headroom [S · LOW · ops].**
  Filed 2026-08-03 from `W3.cap-r3-fu2`. The script polls 60× 1 s for the driver's report and then declares a
  timeout; the green suite now takes **~28 s** and has grown 89 → 113 → 127 → 133 checks in four sessions,
  several of the newer sections holding a real 10 s settle. Nothing is wrong today, but the margin is halved
  and the failure mode is bad: a spurious timeout looks exactly like a real hang, and either way it prints no
  verdict at all (that ambiguity is exactly what left `fu2`'s M4 mutant undiagnosed).
  🔺 **NO LONGER HYPOTHETICAL — measured 2026-08-04 by `W3.cap-r3-fu11`, and it cost that item a round.** Its
  mutant pass observed the ALL-PASS suite at **15 s** (163 checks) but **81 s and 79 s on two of the five
  mutants** (M1 and M3): a Clear that gets through strands the regeneration, and every downstream settle then
  runs to its timeout. So a REAL regression of a data-safety guard does not print `FAIL: …` — it blows the
  60 s wait and prints "Recovery data-safety test timed out", which reads as a hang. Worse, the first mutant
  pass read that missing report as **0 RED**, i.e. as the guard being untested, which is the exact wrong
  conclusion. The pattern generalises: the failing case is systematically SLOWER than the passing one, so the
  wait is calibrated against precisely the wrong run.
  🔺 **A SECOND, INDEPENDENT WAY IT BLOWS — measured 2026-08-04 by `W3.cap-r3-fu9`: parasitic CPU load.** The
  same green suite (170 checks) ran **73 s → timeout** and then **19 s → ALL PASS** on the same commit, minutes
  apart; the only difference was 8 orphaned busy-loop shells from an earlier session's load test eating ~1.3
  cores (killed in between — see that session's Daemon Report note). So the wait is calibrated not just against
  the wrong RUN but against the wrong MACHINE STATE, and an iteration-counted `Task.sleep` settle stretches ~6×
  under load, which no amount of check-level care fixes (that item's own new section had to switch its negative
  wait to a wall-clock DEADLINE for the same reason). It also cost a debugging round: the first failing run
  looked like a logic bug in the new section. **Whatever the fix, make the timeout message name what it
  measured** (elapsed, checks completed, last check seen) so the next reader is not left choosing between
  "hang", "slow machine" and "real FAIL". Fix is cheap — raise
  the wait (180 s), or better, poll for process EXIT as well as the report file so a genuine crash/hang is
  distinguished from "not finished yet" in the message. Same shape in the sibling drivers
  (`test-manifest-persistence.sh`, `test-merge-safety.sh`, `test-batch-resume.sh`), so fix the pattern once
  and apply it. | files: ArchiveProcessor/scripts/test-*.sh | S | low | none
- [ ] **W21.warn — 2 pre-existing non-Sendable `DispatchWorkItem` warnings in `Net/CaptureServer.swift` [S · LOW].**
  `TimeoutHandle(DispatchWorkItem { [weak self, weak conn] … })` at `CaptureServer.swift:151` captures a
  non-`Sendable` `DispatchWorkItem` in a `@Sendable` context; surfaces only on a full clean build. ⚠️ The file
  imports **only `Foundation` + `Network`** (verified 2026-07-28), and Foundation re-exports Dispatch, so the
  originally-suggested `@preconcurrency import Dispatch` may be a no-op — **reproduce the warnings on a fresh
  clean build FIRST** and only then choose the fix. `Net/` is a Tier-2 no-undo path, so treat any behavioural
  change as Tier-2 even though this is nominally a warning cleanup. | files: ArchiveProcessor/macOS/Sources/ArchiveProcessor/Net/CaptureServer.swift | S | low | none
- [ ] **W21.status-idle — `daemon.sh status` reports "nothing it can do" while a session is actively mid-item,
  and blames the HOLD QUEUE for it [S · LOW · ops].** Filed 2026-08-02 from the daemon-report walkthrough,
  where the headline read *"◐ Running, but not finding anything it can do (2 hours)"* and *"Needs you: 2
  task(s) are held back for you to decide"* — while a session launched at 08:18 had already committed
  `d67b9cb` (`W3.cap-r5` checkpoint 1/2) in its worktree and was mid-`Edit` on the trackers. It shipped
  minutes later as `1f43498`. **Both halves of the headline were wrong**, in two independent ways:
  (1) *liveness* — the idle clock is driven by `idle.since` + the pushed tip on `main`, so a session that is
  running and has committed only to its own worktree reads as zero progress; nothing consults `engine.lock`,
  the running `claude` process, or `git log main..HEAD` in the live `suite-wt-*`. (2) *attribution* — the
  "Needs you" line pins the idleness on the HOLD QUEUE without asking the resolver, but
  `next-queue-item.sh` was returning `W3.cap-r5`/`r4`/`r3` and ~20 more as `ok`; the held items were gating
  nothing. The real cause was six consecutive USAGE-LIMIT fast-fails (rc=1 after 6–8s, backing off
  180s→1800s), which `daemon.log` names correctly and the headline discards.
  **Fix direction:** before printing the idle headline, check for a live session (lock + worktree commits
  ahead of `main`) and say *"working on `<item>` since `<t>`"* instead; and gate the "Needs you → held back"
  attribution on `next-queue-item.sh` actually returning no `ok` item, otherwise report the backoff reason
  from `daemon.log`. ⚠️ This is **the mirror image of the known "status says *productive* while every session
  exits rc=1" bug** — same root shape (the headline summarizes state it does not measure), so fix both
  directions or the next one lands as a new surprise. **Tier-2 per the autonomous-setup change discipline**
  (adversarial review + prove-the-mechanism before install), and remember `daemon.sh` installs from the PRIMARY
  checkout's working tree — a fix landed via worktree+push is not live until the primary is fast-forwarded
  and the owner restarts it. Read-only reporting change; no daemon behaviour change.
  | files: ops/autonomous/daemon.sh | S | low | none
- [ ] **W23.notes-uitest-warn — 22 pre-existing actor-isolation warnings in `NotesGUITests.swift` [S · LOW].**
  Filed 2026-07-31 from the W23.m9-fu2 session. A **clean** build of the Notes scheme emits 22 Swift 6
  warnings from `Tests/ArchiveNotesUITests/NotesGUITests.swift:55-77` — "main actor-isolated property `app`
  can not be referenced from a nonisolated context", and the same for `launch()`/`activate()`/`terminate()`/
  `waitForExistence` and the static `fixturePath`. The `setUp`/`tearDown` overrides are nonisolated while
  every `XCUIApplication` member they touch is `@MainActor`. **Why it matters beyond tidiness:** they are
  invisible on an incremental build and appear only on a fresh one (a new worktree's DerivedData), so a
  session that greps its build log for `warning:` sees a wall of 22 and cannot tell a NEW warning from this
  backdrop — which is exactly what the repo's "no new warnings" gate depends on being able to do. Fix is
  annotation-only: `@MainActor override func setUpWithError()` / `tearDownWithError()` (or hoist the
  `XCUIApplication` handling into the `@MainActor` test methods). Not new — the file has been untouched since
  `73e91338` (W8-S8b) — and it does NOT need the VM or a GUI run: `xcodebuild build-for-testing` on the Notes
  scheme reproduces and verifies it. Daemon-buildable, $0. | files: ArchiveNotes/macOS/Tests/ArchiveNotesUITests/NotesGUITests.swift | S | low | none

- [ ] **`W9.b3` — Archive Notes cannot retitle or re-tag a note from the UI at all [S–M · Tier-2].**
  **⚠️ Retagged from `W22.notes-rename` on 2026-08-16 and MERGED with gap-closure plan item B3 — they were the
  same work filed twice, once from the owner's 2026-08-02 walkthrough and once from the 2026-07-16
  plan-vs-build review. This entry is now canonical for both;** the W9 decomposition block above cross-refers
  here rather than repeating it. **From plan B3, in addition to the rename below:** add `setTags(_:to:)`
  alongside `setTitle`, both routed through the audited `mutateItem` path, and a **tag editor** in the metadata
  inspector — `setTags` must write front-matter **and** run `NotesTagProjector` so Finder tags stay in sync,
  which is what makes the whole item Tier-2 rather than Tier-1. Extend `NotesTagProjectorSafetyTests`.
  ⚠️ **Ordering with `R13d REVERSED`:** R13d ships first (TIER 4 vs this item's TIER 5) and *removes* the
  `ArchiveSuite` marker outright, so the marker half of the post-rename assertion below will be moot by the
  time this runs — assert on the projected **subjects** only, and do not re-add a marker check.
  Owner decision
  2026-08-02 (daemon-report walkthrough): **this is a GAP, not a design choice.** He was offered the
  "titles are derived from the archival source, so renaming is intentionally not offered" reading and
  rejected it. Verified 2026-08-01 (by `W21.vmgui-c`) and re-verified 2026-08-02: `NotesModel` has
  `renameTemplate` (`:519`) and `renameFolder` (`:872`), and `OrganizationStore` has another `renameFolder`
  (`:257`) — **there is no rename for a note.** The list's title cell is a read-only `NSTextField` and the
  metadata inspector edits only date and quality, so the only way to retitle a note today is to open the file
  and edit its front matter by hand.
  **Scope chosen by the owner: the full affordance, not the inspector-only variant** — add `renameNote` to
  `NotesModel` plus an inline-edit affordance on the list cell, mirroring how folders and templates already
  rename (so it is an existing interaction pattern, not a new one), rather than only adding a title field to
  the metadata inspector.
  ✅ **DECIDED by the owner 2026-08-02: renaming a note renames the file on disk too**, not just the
  front-matter title. ⚠️ **This is ALREADY the store's behaviour — do not design it, and do not add a second
  rename path.** `NoteStore.saveEntry` (`Store/NoteStore.swift:242-255`) treats the filename as *"a projection
  of the title"* and `moveItem`s `<Title>.md` whenever the title changes, behind a component-boundary
  `precondition` that both URLs stay inside the entry dir and an intra-dir `disambiguate` on collision. It is
  covered today (`NoteStoreTests` rename case; `TemplateTests` rename-on-save). **So the owner's decision costs
  nothing and adds no new risk** — a `renameNote` routed through the existing `mutateItem` path inherits it
  automatically, exactly as `setDate`/`setQuality` do.
  ⚠️ **The first version of this entry was WRONG about the risk, and the correction shrinks the item.** It
  claimed the on-disk-rename question "diverges on durable links". It does not. A note's durable identity is
  its **UUID folder** — the layout is `<root>/items/<uuid>/<Title>.md` — and the UUID never changes on rename,
  so note-passage `SourceAnchor` provenance resolves by id, not by filename. **No link breaks. Do not budget a
  link-migration step; there is nothing to migrate.** What is left is the model method + the UI affordance,
  which is why this is nearer **S–M** than the **M** first filed.
  **What genuinely remains to be checked inside the item** (one assertion, not a redesign): the store does
  `moveItem` and *then* an atomic overwrite (`Data.write(options: [.atomic])`, `:259`), while
  `NotesTagProjector` writes the managed Finder tags onto that same `.md`. Assert the projected subjects **and**
  the `ArchiveSuite` marker are still on the file after a rename. ⚠️ If they are NOT, that is a **pre-existing
  defect on every `mutateItem` path** (`setDate`/`setQuality`/`setBody` all do the same atomic overwrite) —
  **file it separately; do NOT absorb it into this item or let it grow the diff.**
  **Free to get right now and stops being free later:** per the 2026-08-01 STANDING PREMISE, Notes holds only
  test material, so no migration is owed; and the DEVONthink import is ON HOLD precisely so Notes' structure
  can settle before 7.5 GB lands in it.
  **Also unblocks `W21.vmgui-c-fu`'s second blocker** — W14.4 (c)'s stated trigger is renaming a note, which
  is why that check is currently untestable rather than merely un-hittable. It does NOT unblock the first
  blocker (the chip is an `NSTextAttachmentViewProvider` subview outside the accessibility tree), so
  `W21.vmgui-c-fu` still needs one of its own three options; note the cross-reference in both.
  **Tier-2** — it writes to the note's durable identity and the rename has no undo (the store's own
  `moveItem`, not a Trash round-trip). Scratch copies only, never a real store. GUI confirm goes through the
  Notes VM lane (green 15/15 as of `7d6bb40`), not the host screen.
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/Core/NotesModel.swift, Views/NotesTableView.swift | S–M | med | none

## Archive Notes — DEVONthink import (owner, 2026-07-17)

> ## ⏸ ON HOLD — owner directive, 2026-08-01. PLANS RETAINED IN FULL.
> *"Retain all work plans related to devonthink import but put that work on hold. We don't want to do that
> until we're happy with the basic structure of Notes as an app."*
>
> - **Do not start, advance, or scope this**, and **never mirror it into `.maintenance/AUTONOMOUS_PLAN.md`'s
>   WORK QUEUE** — as of 2026-08-01 "devonthink" appears zero times in that file, which is deliberate, so
>   `next-queue-item.sh` can never offer it. Do not put it in the plan's HOLD QUEUE either: it is not awaiting
>   an owner *gate*, it is out of scope until a qualitative bar is met.
> - **`execution-plans/devonthink-import.md` is RETAINED** — an **explicit exception** to this file's own
>   "delete a shipped `execution-plans/` plan" convention (see §Docs & backlog convention in `CLAUDE.md`). Do
>   not delete it, do not move it to `old/`, do not summarise-and-delete. The planning work keeps its value.
> - **The gate is the owner's alone and is qualitative** — "when we're happy with the basic structure of Notes
>   as an app." Never infer it has been met from a green suite, a drained queue, or a passing review.
> - **Why the ordering matters:** Notes currently holds only test material, so restructuring it is free *right
>   now* — and stops being free the moment 7.5 GB of real research lands in it. Importing into a shape that
>   later changes means doing the import twice.

- [ ] **Import the personal DEVONthink database into Archive Notes** ⏸ **ON HOLD (owner, 2026-08-01 — see the
  block above; plans retained, do not progress)** — plan
  `execution-plans/devonthink-import.md` (PLANNING). Losslessly migrate the owner's ~7.5 GB DEVONthink 3
  "Meritocracy Project" DB (`~/Desktop/Scholarship/1000 Research Database.dtBase2`; ~40k notes+excerpts) into
  Archive Notes: 3-stage offline pipeline (JXA extract →
  frozen JSON manifest → pure transform → materialize a **fresh** store) + a stop-on-flag reconciliation
  gate. Delivers net-new Notes features (multi-date primary+additional with per-date timeline rows;
  Related-notes section) and a deletable import toolchain. **Owner prerequisites (§8):** a Reader root over
  `~/Desktop/Google Drive/Archival Photos/`, a copy of the `.dtBase2`, a fresh output store; resolve §9 open
  decisions. Next step = **DTI-0 spike & ground-truth** on a DB copy. | HIGH risk · Tier-2 · **needs:** owner
  + corpus-safety
- [ ] **W24.jpeg1 — Reader/Notes: PDF + JPEG dual image reference** (blocked-on: W26.walk2, W26.verify)
  (owner, 2026-07-17; **design decided + premise corrected by a full corpus audit 2026-07-29**; tagged
  `W24.jpeg1` on 2026-08-06 by `W26.reinfect` — it had no tag, so `W26.reinfect` and the despotlight plan both
  had to cite it by a line number that had already gone stale by 336 lines).
  Let a Reader image entity — and thus the durable link surfaced in Notes —
  reference **both** an archival PDF and its JPEG partner (opens the PDF by default; user can switch to the
  higher-detail JPEG when the PDF lost resolution). Supports the DEVONthink import
  (`execution-plans/devonthink-import.md` §4a) but is a standalone Reader feature.

  ⚠️ **The original premise was WRONG and is retained here only as a warning.** It claimed "naming/paths mirror
  1:1 … so the partner is derivable by filename." A read-only audit of all **102,516** PDFs (manifest +
  per-collection rollup: see the 2026-07-29 corpus-audit report) found:
  - **relocated 82,147 (80.1%)** — partner exists but under a *differently named* collection folder;
    **mirrored only 10,765 (10.5%)**; **none 9,529 (9.3%)**; **ambiguous 75 (0.07%)**.
  - So **90.7% of PDFs do have a partner, but pure path derivation finds 1 in 10.** Leaf *stems* mirror; the
    *collection folders* do not (24 exact-name matches, 23 main-only, 17 JPEGS-only), and the divergence recurs
    at sub-collection level (`Cambridge/Young, Michael` ↔ `.../Michael Young Archive`).
  - The JPEGS tree is not purely JPEG (**4 image extensions** jpg/jpeg/JPG/HEIC with case variance, plus 443 pdf,
    8 mp3, 6 rtf), and the MAIN tree already holds ~18k images of its own.
  - **The corpus cannot be normalised by renaming** (owner asked; audit says no): JPEGS `Stanford University
    Archives` is the dominant partner for BOTH PDF `Stanford University Archives` AND `… — Tech` (**41,585 PDFs,
    41% of the corpus**) — a many-to-one that no 1:1 rename can express; same for Harvard. The 7 genuinely safe
    renames would fix only ~10% of the relocated cases. **DECIDED by the owner 2026-07-29: leave the corpus
    alone — no renames, ever, for this feature.** Do not re-propose corpus normalisation as a way to simplify
    this work: it was measured, it does not work, and the index below resolves 100% of partners without touching
    a single irreplaceable file. Full evidence: `~/Desktop/CORPUS-AUDIT-REPORT.md`.

  **Decided design (owner, 2026-07-28/29):**
  1. **Root:** raise Reader's granted root to the common parent so both trees sit under one root GUID.
     *(Owner's choice; note it widens Reader's WRITE surface over sibling folders — keep tag writes scoped.)*
  2. **Detection: a WALK-BUILT stem index over the JPEGS subtree. Not Spotlight.** *(Rewritten 2026-08-06 by
     `W26.reinfect`. The original clause read "index the JPEGS tree (**a second `NSMetadataQuery`**)" and, being
     open and owner-approved, was the one place in the backlog that could have re-introduced Spotlight into the
     codebase Wave 26 exists to clear. **The requirement is unchanged; only the mechanism is.**)* An index is
     still **REQUIRED, not an optimisation** — 80.1% of partners sit under a differently-named collection
     folder, which no path rule can resolve. Resolve in this order: exact mirrored subpath → indexed stem within
     collection context → **refuse and show no partner when ambiguous** (75 files); never guess, since a wrong
     partner shows the historian a different archive's scan.
     - **Mechanism:** `ArchiveCore.CorpusWalker` over the JPEGS subtree, building `stem → [path]` plus collection
       context. A partner lookup needs no tags, so `scanFingerprints` (every readable regular file, one
       following `stat(2)` each, **no per-file tag read**) is the cheaper entry point; use
       `scan(predicate: { _ in true })` only if the partner index ever turns out to need tag data.
     - **Measured 2026-08-06, read-only:** `Archival Photos JPEGS` holds **163,106 files** and enumerates in
       **4.8 s** (`find -type f`, one run); the main tree is 123,302 files / ~10 s. The "Spotlight avoids per-file
       I/O at this scale" argument is void here for exactly the reason it was void for Reader discovery.
     - **It is a second SUBTREE, not a second root.** Design decision #1 raises the granted root to the common
       parent `~/Desktop/Google Drive/`, and `Archival Photos JPEGS` is a **sibling of** `Archival Photos` under
       it — so the JPEGS tree is already inside the one security scope, already inside what `CorpusWatcher`
       watches, already inside what `LibraryIndex` keys on. Do **not** add a second granted root or bookmark.
       ⚠️ It also means the raise roughly **doubles every cold walk** (123,302 + 163,106 ≈ 286k files) — which is
       why this item is now `(blocked-on: W26.verify)` and not merely on a walker existing.
     - **Absence must stay distinguishable from failure.** `CorpusScanResult` separates *verified none* from
       *could not read* (`unreadable` / `directoryErrors` / `rootUnreadable` / `isClean`). "No partner" **hides
       the switch** (see the tail of this item), so the switch may only be hidden on a **clean** pass; an
       incomplete or denied JPEGS walk means *partner unknown* and must never render as "this PDF has no JPEG".
       This is `W26.deny`'s distinction applied to a second consumer — the same class of bug, one subsystem over.
     - **Storage is an open sub-decision — settle it before writing code.** Either a stem table inside the
       existing `LibraryIndex` SQLite DB (which already carries untracked rows — `entry.tracked` +
       `entry_root_tracked` — keyed by root marker GUID + byte-exact path, and already has the warm-start and
       revalidation machinery this index would otherwise duplicate), or a separate disposable index. Reusing
       `LibraryIndex` inherits its byte-exact path contract and therefore `W26.symroot`'s open question; a
       separate index duplicates fingerprinting and revalidation.
  3. **Durable link:** encode the PDF path **and** the resolved JPEG path explicitly — the partner is not
     re-derivable, so a citation must pin what was actually cited. ⚠️ This changes `DurableLink`
     (`packages/ArchiveCore/Sources/ArchiveCore/Links/DurableLink.swift`) — a shared ArchiveCore type + cross-app
     URL contract → **Tier-2** (de-gated 2026-08-13), and it must rebuild all three app test bundles.
     Old links without the JPEG field must keep parsing (additive/optional).
  4. **Switch UI:** View-menu item + keyboard shortcut, **no** toolbar button; the choice is **sticky per
     document** (needs a small persisted per-file preference store).
  Also handle: PDFs with no partner (9.3%) → hide the switch entirely; case-insensitive extension matching.
  **Verify:** headless render guards (`RenderProbe`/`DocumentRenderGuardTests`) that both the PDF page and the
  JPEG partner render non-blank; VM GUI lane (`W21.vmgui`) for the in-viewer switch.

  **The blocking edge (added 2026-08-06 by `W26.reinfect`), and why it is not `W26.walk1`.** `W26.reinfect`
  specified `(blocked-on: W26.walk1)` — "a walker must exist first". That is satisfied but too weak: this item
  does not merely call the walker, it **raises Reader's granted root over a second 163k-file subtree**. So the
  real prerequisites are **`W26.walk2`** (Reader discovery is filesystem-owned — raising the root while
  discovery was Spotlight-only would have put ~286k files at the mercy of the same dead index that caused the
  2026-08-04 incident) and **`W26.verify`** (the 100k+ scale lane has **never been run**; it is the measurement
  that says whether doubling the walk is affordable, and it carries `W26.idx`'s unrun warm-start lanes too).
  `walk1`, `walk2` **and `W26.verify` have all shipped** (`W26.verify` is `[x]` in `SUITE_TODO_DONE.md`; do not
  confuse it with `W26.verify-fu1`/`-fu2`, which are separate items — that misreading happened on 2026-08-13).
  **So nothing blocks this any more.**
  ⚠️ **The paragraph that used to sit here said this item was deliberately kept OUT of the plan's WORK QUEUE
  because `DurableLink`/SPEC made it owner-gated. That is obsolete:** SPEC and cross-app-contract edits were
  de-gated on 2026-08-13 (TIER-2 IS THE GATE — `AGENTS.md` §*Gating baseline*), so the item is now mirrored
  into the WORK QUEUE and is legitimately pickable. It is still **Tier-2** and still rebuilds all three app
  test bundles; that is a bar to clear, not a gate to wait behind.
  | Reader + Notes + ArchiveCore (durable-link/image entity) | M–L | med | Tier-2 (DurableLink/SPEC)

## Owner GUI-pass follow-ups — 2026-07-16 (from the interactive Reader + Processor GUI review)
Surfaced during the owner's live GUI pass. Each is scoped + daemon-buildable unless flagged owner-decision/Tier-2. Legend as above.
### Owner dispositions — Daemon-Report sweep, 2026-07-16
Owner went through the owner-only queue. Recorded here so none of it gets re-surfaced as an open ask:
- **Environment: TCC grants (Accessibility / Screen Recording / Automation) are SET, verified live.** Sessions can
  drive + screenshot the GUI themselves — see `AGENTS.md` → *GUI verification*. The Processor's Keychain
  "Always Allow" is **seeded**, so its GUI launches unattended. ⚠️ **THIS SENTENCE WAS WRONG, and stayed wrong
  for a month — corrected 2026-08-13.** `W21.seed` was worked that day and the login-Keychain prompt **did**
  appear, so the Processor was never actually seeded when this was written. It is seeded NOW. Left in place
  rather than rewritten because it is a dated record of what was believed. **Stop deferring visual checks to the owner as
  "GUI blocked"** — that claim was stale and cost the owner a lot of pointless eyeballing.
- [ ] **R13d REVERSED — remove `ArchiveSuite` stamping from Notes; drop the exclusion feature entirely
  (owner decision 2026-07-16: "Forget about excluding other tagged files. Notes should no longer tag things as
  ArchiveSuite").** The marker was only ever written, never consumed (no Reader filtering / Processor stamping /
  back-fill), so the whole feature goes rather than getting finished. Scope:
  - Stop stamping: drop `suiteMarker` from the managed vocabulary (`ArchiveNotes/Core/NotesTagVocabulary.swift:11`
    → `ArchiveSuiteMarker.tagName`) so `NotesTagProjector` neither adds **nor removes** it; the marker-filter in
    `Core/ItemSummaryDisplay.swift:39-43` then becomes dead and can go too.
  - **⚠️ Decide the projector semantics deliberately — this is the Tier-2 trap.** `NotesTagProjector` *manages*
    its token set: if the marker stays "managed" but merely "not desired", the next projection **strips
    `ArchiveSuite` from the owner's existing note files** (a real tag WRITE). Removing it from the managed set
    instead leaves existing stamps in place, inert. ✅ **THE OWNER ASKED, 2026-08-13: STRIP.** He was put the
    question directly (his grant said to ask once it became cheap) and chose the clean end state, so the
    deliverable is that the marker keeps its managed status long enough to **REMOVE existing `ArchiveSuite`
    stamps**, and then the surface goes. ⚠️ This is a real tag WRITE → Tier-2, scratch copies only, never a real
    store, with a functional proof that a stripped note keeps every OTHER tag it had. The former default —
    *leave existing stamps alone* — is **REVERSED**; do not implement it. Rationale and the amended grant:
    `OWNER_AUTHORIZATIONS.md` §`R13d`.
  - Retire the now-unused marker surface: `packages/ArchiveCore/Sources/ArchiveCore/ArchiveSuiteMarker.swift`
    (check `Links/RootMarker.swift` — the root marker is a *separate* durable-link concern and must survive).
  - **SPEC** (`SPEC/tag-format.md:71`, the "Suite marker" row) — the tag/PDF contract is the **highest-risk shared
    surface**: update it in the SAME commit as the code. This also **inverts W9 Phase A's "finish the SPEC
    `ArchiveSuite` marker section"** — that sub-task is now "remove it".
  - Drop the `(later)` behavior/data follow-on's marker half (Reader hides `ArchiveSuite` / corpus back-fill /
    Processor stamping) — see that item below.
  **Tier-2** (tag-write path + the shared SPEC): adversarial review + a scratch-copy functional test; NEVER the
  real corpus. | files: ArchiveNotes Core/{NotesTagVocabulary,NotesTagProjector,ItemSummaryDisplay}.swift,
  packages/ArchiveCore/ArchiveSuiteMarker.swift, SPEC/tag-format.md | M | med | none

## Archive Notes — NEW APP (SHIPPED W0–W8, 2026-07; `execution-plans/archive-notes/00-overview.md` retained)
Owner-specced third Suite app; foundational decisions locked (D1–D10, `00-overview.md §2`). **All waves shipped;
the per-wave plans (`00a`, `01`–`08`) were deleted on ship** (git history + the W0–W8 `[x]` records below are the
account); only `00-overview.md` is retained as the authoritative interface contract. DevonThink informs **only**
the 3-pane browsing shell — everything else (note appearance, link/provenance UI, replication semantics) is
purpose-built for the historian's provenance-first workflow. **Owner decision points (early):** (a) **R13d** —
the `ArchiveSuite` *exclusion* effect is deferred to the later behavior/data follow-on (see `00 §2` call-out).
**Confirmed (owner):** the FULL **ArchiveCore extraction + Reader/Processor migration is W0 — done FIRST** (`00a`),
before any Notes-specific work.
### W9 gap-closure — DECOMPOSED 2026-08-16 (was one checkbox hiding Phases A–E)

⚠️ **`W9` as a single item is GONE.** It was one `- [ ]` standing for a 390-line, five-phase plan, and the
daemon could not have done it: `resume-prompt.txt:9` calls an item that needs more than ~2 sessions mis-sized,
`09-gap-closure.md` contains **zero checkboxes**, and `ARCHIVE_NOTES_PROGRESS.md` — the mechanism that made
Wave 11's multi-phase build drainable one sub-task per session — was **retired 2026-08-01** with no
replacement. So a session could do a whole phase, commit real work, and have nothing to flip; six of those and
`MAX_NOCOMPLETE=6` parks the entire run (`archive-suite-autonomous.sh:134`). Its queue mirror also cited
`execution-plans/09-gap-closure.md`, which does not exist — the file is at
`execution-plans/archive-notes/09-gap-closure.md`.

**Progress now lives in these tags, not in the plan file.** ⛔ Do **not** add checkboxes to
`09-gap-closure.md` and do not resurrect a progress file — the 2026-08-01 tracker consolidation retired that
pattern deliberately (`execution-plans/tracker-consolidation.md` finding F2). The plan stays the *detail*;
these items are the *state*. Each maps 1:1 to a plan sub-item ID, so `W9.b4` is plan item **B4**, verbatim.

**Phase A is done except one item, and one is now moot.** A1, A2, A3, A5, A6, A7, A8, A9 and A11 all shipped
2026-07-18. **A4 is NOT recreated here**: `R13d REVERSED` says in its own scope that it *"inverts W9 Phase A's
'finish the SPEC `ArchiveSuite` marker section'* — that sub-task is now 'remove it'". Writing the SPEC section
A4 asks for would be work `R13d` then deletes. ⛔ Do not file A4 again. **D5** also shipped (W14.4b,
live-verified 2026-07-17).

**Two CANDIDATE findings come first.** The 2026-07-18 GUI sweep was cut short by a usage limit and left two
unconfirmed findings. `W9.cand1` is potentially **HIGH** and gates the value of all of Phase B — confirm it
before building anything else in Notes.

- [ ] **`W9.cand1` — CONFIRM FIRST: can a note be created from the GUI at all? [S · potentially HIGH · gui].**
  Plan addendum 2026-07-18. With the app on the scratch fixture, **⌘N created no note** (item count unchanged
  on disk across two attempts) and the toolbar **"New" pencil created nothing**; there is **no `File` menu** at
  all, so ⌘N appears unbound. Benign explanations that must be ruled out first: the New menu may need a real
  folder selected (the sweep was on the "All Notes" pseudo-row), a new empty note may live in memory/index
  until first edit, or the click may have missed the split-button. **If creation is genuinely unreachable this
  is HIGH — a note app you cannot add a note to** — and combined with `W9.b3` (no in-app retitle) notes could
  be neither created nor renamed. Drive it on the Notes VM lane, scratch fixture only. Outcome is either a
  HIGH bug item or a downgrade to a UX note. | ArchiveNotes GUI | S | low | **needs:** gui

- [ ] **`W9.a10` — prove the doc-sync hook fires for `packages/` [XS–S · Tier-2 autonomous-setup].** Plan A10.
  The W0 plan asked to prove the doc-sync backstop catches a `packages/ArchiveCore` code change with no doc
  touch; it was never proved. ⚠️ Tier-2 per the autonomous-setup change discipline — prove the mechanism on a
  planted change before trusting it. | .claude/hooks/docsync-*.sh | XS–S | low | none

**Phase C — safety-net & regression tooling.** These re-arm guards, so they sort with the gate work rather
than with Notes features.

- [ ] **`W9.c1` — the gate never runs ArchiveCore's 100 tests [S].** Plan C1. They run only via a manual
  `swift test`. Add an `archivecore` case to the root `test-smoke.sh` and include it in `all`, ahead of the apps
  that depend on it. | test-smoke.sh | S | low | none
- [ ] **`W9.c2` — Processor has no write-surface lint [S · Tier-2].** Plan C2. Reader has one; Processor does
  not. Ban `setResourceValue(s)`/`setxattr` across `ArchiveProcessor/macOS/Sources`, allow-list
  `PDFDocument.write` in `PDFGenerator.swift`/`mergeDocumentPDFs`. Must trip on a planted violation, not just
  pass clean. **Tier-2** — it guards the irreplaceable-data write path. | ArchiveProcessor/scripts/ | S | med | none
- [ ] **`W9.c3` — the write-surface lint never scans ArchiveCore or Notes, and Core imports AppKit [S–M ·
  Tier-2].** Plan C3. The Reader lint scans only Reader and has no `import SwiftUI|AppKit` guard, which is why
  `packages/ArchiveCore/.../Thumbnails/PDFThumbnailer.swift:4` imports AppKit into the UI-free Core uncaught.
  Scan `Sources/ArchiveCore` (write API only in `TagWrite.swift`, no UI imports) and add a Notes scan. Then
  decide `PDFThumbnailer` deliberately: move it behind a Core-safe boundary / into an app target, or carve a
  documented exception. | ArchiveReader/scripts/lint-write-surface.sh | S–M | med | none
- [ ] **`W9.c4` — the Notes smoke gate builds and drives the GUI target [XS].** Plan C4.
  `ArchiveNotes/test-smoke.sh` runs `xcodebuild test -scheme ArchiveNotes` with no
  `-only-testing:ArchiveNotesTests`, so the "free" gate builds the UITest bundle and drives it when the fixture
  is present. Add the restriction; keep the GUI target opt-in. | ArchiveNotes/test-smoke.sh | XS | low | none

The remaining two Phase C items are heavier than C1–C4 and sit in **TIER 5**, not with the gate work:

- [ ] **`W9.c5` — the tag-projector concurrent lost-update race [LOW–MED · Tier-2]** (blocked-on: W9.b3).
  Plan C5, documented in `KNOWN_ISSUES.md` (`08` S2). Two concurrent projections of the same file can drop a
  subject. **Not currently triggerable** — the projector is never driven concurrently — which is exactly why it
  is gated on `W9.b3`: that item adds `setTags`, the first feature that could enqueue concurrent projections
  for one item. Serialize per-item projection (item-keyed actor/queue) so the read-modify-write is atomic, and
  restore the plan's `concurrentProjectionsNeverCorrupt` "loses nothing" assertion. Scratch store only.
  **Done:** the `KNOWN_ISSUES.md` entry is closed. | ArchiveNotes Core/NotesTagProjector.swift | S–M | med | none
- [ ] **`W9.c6` — nothing proves the spec's 100k-note / 2M-word scale target [M · Tier-2].** Plan C6
  (spec-vs-build). The original spec said *"operate at the scale of 100,000 notes and 2 million words without
  being slow. Build for scale from the beginning."* The architecture **is** built for it (FTS5 + bm25, WAL +
  `synchronous=NORMAL` + `busy_timeout`, DB-backed org-graph, virtualized `NSTableView`, 150 ms-debounced +
  generation-coalesced search, incremental off-main indexing with mtime-skip) — but the only perf test,
  `EditorPerfTests`, stresses a single ~50k-word *document*, not a 100k-note *corpus*. Generate a **scratch**
  store (mktemp/`TESTOUT` — ⛔ never the real Notes store, per the Reader Prime Directive and the
  never-mutate-live-app-root rule) of ~100k UUID-folder notes totalling ~2M words, then assert bounded
  wall-times for (a) a full `buildIndexFromDisk` incremental build, (b) an FTS search round-trip, (c)
  `allSummaries()` + one `NotesNavigationModel.recompute()`/sort. Env-gate it so ordinary `swift test` is not
  slowed, and assert the scratch-path guard holds. **Conditional follow-up:** if `recompute()`'s in-memory
  `NotesFilter.matches` scan + sort exceeds a frame budget at 100k on `@MainActor`, move it off-main (return a
  `Sendable [UUID]`) — the one scale claim the current in-memory-filter design leaves unproven. |
  ArchiveNotes/macOS/Tests/ + ArchiveNotes/scripts/ | M | med | none

**Phase B — wire the built-but-dead features.** The high-value core: library code that shipped without a UI
entry point. Mostly **Tier-2** (they write note front-matter or project Finder tags).

- [ ] **`W9.b1` — Zotero auto-fill is unreachable from the UI [M · Tier-2].** Plan B1. `ZoteroAutoFillModel`
  exists and nothing can invoke it. Add `Note ▸ Auto-fill from Zotero` resolving the focused `ZoteroRef` →
  `client.fetchCSL` → `AutoFillPlan` → confirmation sheet (fill-empty policy) → save via the audited store
  path; route citation through `fetchCitation(styleID:)` so `zoteroCSLStyleID` takes effect. Verify with a stub
  transport as in `ZoteroLocalServerTests`; Zotero-down must degrade gracefully. | ArchiveNotes Zotero/ +
  ArchiveNotesCommands.swift | M | med | none
- [ ] **`W9.b2` — note-level Zotero chips are never rendered, and there is no attach-at-note-level path [M ·
  Tier-2].** Plan B2. Render `ZoteroChipView` for `selectedItem.zotero` in the inspector; add an attach path
  populating `item.zotero` via `mutateItem`; feed the clipboard-detect dedup the note's existing links (fixes
  the empty-`attachedLinks` banner). Meets S4 "chips clickable at note **and** block level". | ArchiveNotes
  Zotero/ + NoteMetadataInspector.swift | M | med | none
  - ⚠️ **`W9.b3` (plan B3 — note retitle + tag editing) is NOT listed here.** Its checkbox is the retagged
    former `W22.notes-rename` entry further down this file, which already carries the owner's 2026-08-02
    decisions (full affordance not inspector-only; renaming renames the file on disk), the correction that
    shrank it to S–M, and the one assertion that genuinely remains. Plan B3's extra scope (`setTags` + the
    inspector tag editor + projector sync) was folded into it. One checkbox, not two — do not re-file it here.
- [ ] **`W9.b4` — page thumbnails never render end-to-end [M · Tier-2].** Plan B4. Reader passes
  `thumbnailer:nil`. ⚠️ **Verify with a headless render guard** (`RenderProbe`/`DocumentRenderGuardTests` over
  Notes' in-app `PDFThumbnailer`) — XCUITest reads the accessibility tree, not pixels, so a blank thumbnail
  would pass a UITest. | ArchiveNotes + ArchiveCore Thumbnails/ | M | med | none
- [ ] **`W9.b5` — `archivenotes://open` is never consumed [S].** Plan B5. The scheme is registered; nothing
  selects/raises the note. | ArchiveNotes | S | low | none
- [ ] **`W9.b6` — the extract command path does not embed image bytes [S–M · Tier-2].** Plan B6. | ArchiveNotes
  Editor/ | S–M | med | none
- [ ] **`W9.b7` — guided root re-grant is not wired [S].** Plan B7. | ArchiveNotes | S | low | none
- [ ] **`W9.b8` — no manual author editing, for notes or extracts [S–M · Tier-2].** Plan B8 (spec-vs-build,
  2026-07-17 addendum — spec intent that never entered a wave plan). Writes front-matter. | ArchiveNotes | S–M
  | med | none
- [ ] **`W9.b9` — no outbound "Copy Link to Note/Extract" [S–M].** Plan B9 (spec-vs-build). This is the
  **originator of the Scrivener round-trip** — without it the durable-link story only works inbound. |
  ArchiveNotes | S–M | low | none

**Phase D — secondary UI affordances & polish.** All LOW–MED, Tier-1 unless noted, each independently
shippable. **D5 is already shipped** (W14.4b) and is not listed.

- [ ] **`W9.d1` — folder move/reorder & drag-to-reparent UI [M].** Plan D1. Wire `.onMove` + folder-onto-folder
  drop → `model.moveFolder` (the cycle-guard already exists). | Views/NotesFolderTreeView.swift | M | low | none
- [ ] **`W9.d2` — the item-row context menu is a stub [S].** Plan D2. Open / Reveal in Finder / New from
  Template / Set Quality ▸ / Delete…. | Views/NotesContextMenu.swift | S | low | none
- [ ] **`W9.d3` — template body editing is not routed in-app [M].** Plan D3. | Views/TemplatesManagerView.swift
  | M | low | none
- [ ] **`W9.d4` — no quality quick-edit [S].** Plan D4. Inline borderless quality `Menu` (None + 5–1) in the
  list/detail cell plus a context-menu "Set Quality ▸". ⚠️ Coordinate with `W19.q3`/`W19.q4`, which redefine
  Quality across the Suite — do this AFTER them or build it against the post-W19 vocabulary. |
  Views/QualityControl.swift, NotesTableView.swift | S | low | none
- [ ] **`W9.d6` — the `roundup` date field has no UI and is always false: add it or remove it [S–M].** Plan D6.
  It persists and round-trips. Either add the "round to year / circa" affordance or delete the field and its
  codec handling. A decision, then a small change. | NoteMetadataInspector.swift, Store/Item.swift,
  FrontMatterCodec.swift | S–M | low | none
- [ ] **`W9.d7` — a raw→styled parse failure degrades silently [S].** Plan D7. Detect a genuine failure in
  `switchMode` and surface the non-destructive banner. | Editor/MarkdownEditorView.swift | S | low | none
- [ ] **`W9.d8` — no empty-state UI [S].** Plan D8. Empty note list / empty folder. | Views/NotesBrowserView.swift
  | S | low | none
- [ ] **`W9.d9` — smart folders have no live match-count badge [S].** Plan D9. | Core/NotesFolderNode.swift | S
  | low | none
- [ ] **`W9.d10` — the extract inspector has no provenance summary [S].** Plan D10. Distinct source notes +
  counts (the aggregate column already exists). | NoteMetadataInspector.swift | S | low | none
- [ ] **`W9.d11` — large-paste parse runs on the main actor despite the header claim [S–M · perf].** Plan D11.
  `MarkdownBridge` is `@MainActor` and `insertLargeTextAsync` parses inside `MainActor.run`. Either produce a
  Sendable AST off-main as designed, **or** drop the "pure nonisolated" header claim and the stale comment —
  the doc lying is the part that must not survive. | Editor/MarkdownBridge.swift | S–M | low | none
- [ ] **`W9.d12` — the small-correctness batch (~11 items) [M].** Plan D12, kept as one item because every
  member is XS: block-header chip thumbnail render · ordered-list renumber-from-first · focus-on-appear token ·
  drop-cursor + AppKit drop reliability · `NSFileCoordinator` around Trash delete · extract paste degradation
  string · `e2e-durable-links.sh` step-5 negative parity · delete vestigial `NoteBody`/`NoteBlock` ·
  `nestedListMixed` + debounce/snapshot tests · retire-or-extract `SearchGeneration` · filename↔front-matter
  divergence log line · **provenance-chip initial visibility** (the compact editor can render scrolled past
  block 0, hiding the chip that is the whole point of an extract, until a manual scroll-to-top). ⚠️ If a
  session cannot land the whole bag, split it rather than leaving it unflippable. | ArchiveNotes | M | low | none
- [ ] **`W9.cand2` — CONFIRM: a freshly pasted note-passage provenance block renders as raw HTML comment
  [S].** Plan addendum 2026-07-18, CANDIDATE. After a W14.3 copy-passage→paste-into-extract, the chip showed as
  the literal `<!-- block: note-passage … -->` in the **styled** editor and persisted across reselect/reload,
  while pre-existing chips render correctly — so it may be specific to the freshly pasted block not being
  re-styled. Bytes import correctly (W14.3), so this is rendering, not data. Confirm on a clean paste; if real,
  either the paste path must re-run chip styling or the pasted block's on-disk form differs from what
  `MarkdownBridge` chip-parses. Folds into `W9.d12` if confirmed trivial. | Editor/ | S | low | **needs:** gui

**Phase E — verification review. Do LAST; it gates deleting the plan.** This phase exists because the W0–W8
checkboxes overstated completion once already; do not repeat that on the fixes. Use the paced method in
`REVIEW.md`, one subsystem per session, never a giant fan-out.

- [ ] **`W9.e1` — re-run the plan-vs-build gap analysis over every A–D item [M]** (blocked-on: W9.b1, W9.b2,
  W9.b3, W9.b4, W9.b5, W9.b6, W9.b7, W9.b8, W9.b9). Plan E1. | ArchiveNotes | M | low | none
- [ ] **`W9.e2` — drive the wired features at runtime; finish the sweep that was cut short [M · gui]**
  (blocked-on: W9.e1). Plan E2 — and the 2026-07-18 addendum's own unfinished business: note delete +
  delete-last-instance guard, tag editing, quality quick-edit, manual author, keyword FTS + quality/tag/date
  filters, folder create/rename/delete + move/reorder + replicate, templates, context menu, Zotero
  attach/auto-fill, source-block paste, Copy Link, deep-link, smart folders, empty state. Headless render
  guards for pixel truth; the Notes VM lane for the rest. | ops/gui/ + ArchiveNotes | M | low | **needs:** gui
- [ ] **`W9.e3` — prove the safety net actually bites on a planted violation [S]** (blocked-on: W9.c2, W9.c3).
  Plan E3. A lint that has never failed is not a guard — same class as `W26.oracle-fu1`. | scripts/ | S | low | none
- [ ] **`W9.e4` — prove docs/tracker match reality, then DELETE `09-gap-closure.md` [S]** (blocked-on: W9.e1,
  W9.e2, W9.e3). Plan E4. Verify Phase A landed, then retire the plan per the delete-a-shipped-plan
  convention. **This is the item that closes gap-closure.** | execution-plans/archive-notes/ | S | low | none

- [ ] **W33.storage — unified suite storage path** [needs scoping · Tier-2, separately gated]. Behaviour/data
  follow-on; W0 already unified the *code*. **Given a real tag 2026-08-16** — it was filed as `**(later)**`,
  and the tag grammar shared by `check-handoff.sh:134` and `check-tracker-sync.sh` matches
  `^[A-Za-z0-9][A-Za-z0-9._-]*` after stripping bold, so a leading `(` made `match()` fail and the item was
  dropped from BOTH guards before either could compare it. It was the 28th item invisible to the daemon and
  neither guard could ever have said so — see `W31.handoff-fp2`. **Scope it before working it:** its only
  surviving sub-bullet is DROPPED (below), so what "unified storage path" now means is undecided.
  - ~~Reader parses/**hides** `ArchiveSuite` in-UI; corpus **back-fill** + Processor **stamping**~~ — **DROPPED
    (owner 2026-07-16).** The whole `ArchiveSuite` marker/exclusion feature is reversed: Notes stops stamping it
    (see the "R13d REVERSED" item above) and nothing will consume it, so there is nothing to hide, back-fill, or
    stamp. This also removes the only reason for a corpus-wide tag back-fill — the Suite's single
    highest-risk operation. Do not re-propose it.

## ✅ Document-viewer bugs (owner-reported 2026-07-06) — RESOLVED & owner-verified
All fixed and confirmed by the owner (round-3 commit `d4eedba`): open-maximized + remember-size with no
flash; text selection after cycling (fresh `PDFView` per page); zoom persistence across cycling *and* as
default incl. trackpad-pinch (`PDFViewScaleChanged` capture); top-anchored zoom; splitter persistence.
Files: `DocumentWindowView`/`DocumentViewerModel`/`PDFPaneView`/`AppSettings`/`ArchiveReaderApp`.

## P2 — Reader features (no network; local build/test)
**→ Reader P2 is COMPLETE** (non-standard-PDF cluster · tag near-duplicate finder · document-viewer bugs · dup-filename; side-by-side dropped).

## Owner-requested batch (2026-07-09) — Processor output + Reader UX/viewer
Captured verbatim from the owner; file hints are from the Reader/Processor Implementation Maps (verify
at implementation). Not yet scoped into execution plans — the **decades** item likely warrants one
(cross-app + SPEC). Legend as above (S/M/L · risk · needs).

### Archive Processor
- [ ] **De-dup sweep from the 2026-07-04 maintainability audit — REMAINDER ONLY** _(promoted 2026-07-15;
  re-scoped 2026-07-16 after finding suite-v1.2.0 already did most of it)_. **`f1d2263` (suite-v1.2.0) ALREADY
  SHIPPED 5 of the listed consolidations — do NOT redo:** `highestLeadingNumber` (→ `Capture/CollectionNumbering.swift`),
  `monthTag`/`englishMonthNames` (→ `GeneratedTags`), `acceptedImageExtensions` (→ `ImageEncoding`),
  `GatewayConfig.fromDefaults()`, `liveProcessingMode` **enum**. **GENUINE REMAINDER (~6, verified still duplicated
  in-tree 2026-07-16):** a shared transient-status friendly-message helper (4 OCR clients); a segment-JSON schema
  builder (2 sites); `OCRResult.with(...)` copy helpers; `LLMRotationDetector.rotate` → `ImageEncoding.rotate`
  (`LLMRotationDetector.swift:150` still a private copy — its own comment says "mirrors ImageEncoding.rotate");
  `ThinkingLevel.budgetTokens` + the Anthropic max_tokens bump (4 clients — `thinkingBudget` is 1024/4000,
  512/2000, and two `budget` vars, i.e. budgets differ **by call type**, so KEEP that difference — this one is
  request-body-affecting if mis-merged); Gemini `cancelBatch` via the shared URL builder.
  ⚠️ **VERIFICATION CONSTRAINT:** the Processor has **no unit-test target** and its only functional test needs an
  OCR API key (deleted W4.0.a) — so "prove equivalence" here = build-green + byte-identical diff inspection; the
  `budgetTokens` sub-item (request-body-affecting) should be done in a keyed/owner session, not guessed unattended.
  **Tier-1** (touches no write path). | files: OCR/*, Capture/LiveCaptureProcessor.swift, Views/* | M | low | none
  — **W12-dedup progress 2026-07-16 — 5 of 6 shipped** (byte-identical, build-clean, no new warnings):
  (1) `LLMRotationDetector.rotate` → shared `ImageEncoding.rotate` `af8cf66`; (2) shared
  `OCRErrorMessages.transientStatusMessage(_:)` across all 4 clients' `parseErrorResponse` + (3) Gemini
  `cancelBatch` via `makeBatchURL` `6c52dd4`; (4) `OCRResult.with(classification:rotationDegrees:)` copy helper —
  7 review/retry re-creations, preserves errorCode (the W9.1 footgun) `94d4ef6`; (5) **segment-JSON sidecar
  builder** — Tier-2 (file-WRITE format): new pure `OCR/SegmentJSONBuilder.swift` (`cf4f509`) that both
  `OCRProcessor.writeSegmentJSON` + `LiveCaptureProcessor.writeSegmentJSON` now delegate to — disk-write surface
  (sidecar-URL + atomic write) left unchanged; the OCRProcessor-only `box_label`/`folder_label` divergence is a
  `formatOverride:` param via `SegmentJSONBuilder.labelFormatOverride`. Proven byte-identical to BOTH originals
  by a $0 key-free 12-case / 30-assert driver (`SEGMENT_JSON_TEST=1` + `scripts/test-segment-json.sh`,
  `6d9a877`; call sites wired in the flip commit) — ALL PASS. **⏸️ 1 REMAINING is OWNER/KEYED — Wave-12 SKIP
  (do NOT attempt unattended):** (6) **`ThinkingLevel.budgetTokens`** — request-body-affecting (512/2000 vs
  1024/4000 differ by call type) → keyed/owner session per the VERIFICATION CONSTRAINT above (Processor has no
  unit target + its only functional test needs the deleted OCR key). See Daemon Report.
### Capture companions (Android + iOS) — owner decisions 2026-07-15
### Archive Reader — layout & panels
### Archive Reader — tag cloud & filters
### Archive Reader — dates & decades (CROSS-APP + shared SPEC)
### Archive Reader — search
### Archive Reader — sort & smart folders
### Archive Reader — viewer & preview
## Deferred from the 2026-07-09/10 autonomous run → queued for next autonomous run
Correctness bugs from that run's review shipped (`848c9d2`, `f866a0f`, `14118c0`); the items below were
consciously deferred (perf-only / LOW / GUI infra / new idea). All armed in `.maintenance/AUTONOMOUS_PLAN.md`
as **Waves 7–10** for the next daemon run (relaunch the daemon to start it — `ops/autonomous/README.md`).
## P2 — Processor (KI#3 done; rest bucketed by how it can be verified)
**Done:**
**Heads-down doable now (macOS, build-verifiable, NOT phone-gated):**
**Live-session / phone-gated (drive Live Capture — ideally a paired phone — to verify; do interactively, like the viewer bugs):**
> **✅ INTEGRATED 2026-07-07.** The standalone clone's `feat/live-capture-cloud-transport` work — a full
> **Drive-relay cloud-transport** system (D1–D8: `DriveClient`/`DriveObjectStore`/`DriveAuth`/
> `DriveRelayTransport` for Mac+iOS+Android, `FileRelay`, phone queue-depth + Finish drain-gate;
> LIVE-validated, already adversarially reviewed) — was ported into the monorepo under `ArchiveProcessor/`
> as **27 commits (history preserved)** via `git am --directory`, merged to `main`, and pushed. Both apps
> build; offline invariant tests pass (RELAY GOLDEN ✅, FileRelay 8/8). The standalone clone was then
> **retired**: its 6.3 GB `Test Files` corpus moved into `ArchiveProcessor/Test Files/` (gitignored), the
> folder deleted, and the stale `com.archivereader.autobuild` launchd relic removed. This **supersedes** the
> "connectivity UX" item above (cloud/USB transport is the new direction). The architecture now lives in
> `ArchiveProcessor/CLAUDE.md` §Function 3; the relay contract in `SPEC/relay-object-format.md`; the
> on-device walkthrough in `ArchiveProcessor/LIVE_CAPTURE_ANDROID_TEST.md`.

## Excluded (not "now": need cost / owner accounts)
- Processor Tier-1 `test-smoke.sh` / Tier-2 `test-tier2.sh` (real OCR → keys + API cost); Reader cloud-drive support; Reader creation-date-mirror (would write metadata onto the real corpus).
- ~~Processor App-Store / Play submission (Phase 4)~~ — **DROPPED (owner 2026-07-16: "we're not doing this any
  time soon").** Off the list entirely; don't re-surface it as an owner action item.
  - [x] **G5 — cheap Tier-1 smoke gate shipped (2026-07-07).** New Suite-root `./test-smoke.sh processor|reader|all` (mirrors `launch.sh`) → `ArchiveReader/test-smoke.sh` (build + full unit suite, **135 tests, free**) + `ArchiveProcessor/test-smoke.sh` (headless **2-image** OCR via `ProcessFilesTestDriver`, `gemini-2.5-flash-lite`, ~a few cents, `mktemp` scratch-isolated, key never printed). Distinct from the cost-heavy `scripts/test-smoke.sh` (raw per-provider calls) + `scripts/test-tier2.sh` (multi-case pipeline) above. Both verified PASS. ✅

## Processor/Capture — WS11 paced re-review findings (2026-07-18, autonomous)
Lean-review re-pass of `ArchiveProcessor/macOS/Sources/ArchiveProcessor/Capture/` (18 commits since the
2026-07-08 original review). 6 finder-level findings, **4 MED / 2 LOW, no HIGH** → none routed to the owner
HOLD queue. Every fix is **Tier-2** (Capture/ no-undo path): a fix session must adversarially re-confirm +
run a scratch-copy functional test before shipping. ⚠️ The Opus-max **refute-verify was budget-truncated**
(verifiers stopped to protect the session usage window — see memory `workflow-pacing-usage-window`); these are
finder-level candidates (only #1's premise manually confirmed). Report: `.maintenance/review/Processor-Capture.md`.

> **SHIP ORDER (set by the 2026-07-18 Live-Capture architecture review — see Wave 17 below).** Recommended:
> ~~r6~~ → ~~r2~~ → ~~r5~~ → ~~r4~~ → **r3** (`r1` shipped earlier). `r6` — the subsystem's one genuine
> recoverability hole, a straggler's processed output discarded — **shipped 2026-08-02 `905722d`**; `r2` —
> the duplicate paid OCR on a phone retry — **shipped 2026-08-02 `96f223b`**; `r5` — the in-flight document
> no Box could re-pin — **shipped 2026-08-02 `d67b9cb`**; `r4` — the correction the rotation review reverted
> — **shipped 2026-08-02 `d719e3f`**. All four entries are in `SUITE_TODO_DONE.md`, and between them they
> retire most of the two now-closed deferred architecture entries. **The collection-correction path is closed
> end to end**: `r5` fixed the record being written, `r4` the record already written — by DELETING the
> retained second copy of the key rather than syncing it, so there is one reader and nothing left to drift.
> That also **unblocks `W17.stg1`**, which touches the same `RetainedSegment` (its `(blocked-on: W3.cap-r4)`
> now resolves). `r3` — the page deleted mid-OCR whose paid call kept running — **shipped 2026-08-03
> `5c3938e`/`c510af2`/`1ddc083`/`72b2e1c`**, so **ALL SIX WS11 Capture findings are now closed**, and two of
> its three residuals with them — **`-fu1`, the started-once guard that outlived its call, shipped 2026-08-03
> `1a84d1c`/`54981e0`**, and **`-fu2`, the retry that dropped a page's call without cancelling it, shipped
> 2026-08-03 `3fdeb00`/`71cc4e6`** (both entries in `SUITE_TODO_DONE.md`). Between them the invariant is now
> whole: **no `pageTasks` entry leaves the map with a RUNNING call behind it**, on every path that frees one
> (`finalizeSegment`'s own clear drops without cancelling, correctly — it runs after every one of those pages
> was awaited). Still open: **`-fu3`** and **`-fu4`**, both behaviour decisions rather than bug fixes, plus
> **`-fu8`** (the resume path's third label, which `-fu6`'s pass found) and **one of the three `-fu7`
> produced**: **`-fu9`** (a SUSPECTED sheet suppression). The other two are closed — **`-fu10`** (does the
> finishing throbber's scrim block input? — decided: it is MEANT to, `0ee6179`) and **`-fu11` — Clear, ungated
> in the same window and more destructive than the retry — shipped 2026-08-04 `fb833ea`/`c903bb8`** (entry in
> `SUITE_TODO_DONE.md`): the button's two calls are now one `clearSession()` behind one `guard !isFinalizing`,
> with `clearSessionState` made `private` so that is the only door. **With it the `staged`-implies-`finalized`
> enumeration at `applyRotationReviewAndFinalize` is CLOSED** — all three entrants refuse, where the argument
> previously rested on MainActor synchronicity alone. **`-fu7` — the
> retry that was still live while the rotation review regenerated — shipped 2026-08-04
> `765897b`/`68160b0`** (entry in `SUITE_TODO_DONE.md`): `retryFailed` refuses while `isFinalizing`, and the
> bulk button + the per-item menu stop offering what it would refuse. The refusal is deliberately narrow (that
> window only, not the two sheet states), and mutant P5 — widening it to `requestFinish`'s triple — is RED, so
> the *scope* is tested and not merely preferred. ⚠️ **Read fu7 with `-fu10` beside it.** Its independent
> adversarial pass established that the throbber fu7 cited as evidence the panel was CLICKABLE is a
> hit-testable full-bleed scrim, so the two view-layer gates are most likely defence-in-depth over a hazard the
> scrim already blocks, and the guard's live production value is the deferred model-sheet Apply (whose
> reachability rides on `-fu9`). The guard is right either way and cost nothing; what fu10 decides is whether
> this closed a live money leak or documented an unreachable one. Two of fu7's three edits are unmeasured above
> the pure-function line (mutants P6/P7, both 0 RED — a SwiftUI modifier is invisible to a headless driver);
> **one VM-lane session can close fu9, fu10 and both of those at once.**
> **`-fu5` — the unenforced
> `failedGroupIds ⊆ finalizedGroups` invariant several of these latency arguments lean on — shipped 2026-08-03
> `2d15fae`/`f091ea2`** (entry in `SUITE_TODO_DONE.md`): `finalizedGroups` now has exactly two exits —
> `releaseFinalizedGroup` per group and `releaseAllFinalizedGroups` for Clear — and both clear
> `failedGroupIds` with it, so the subset rests on that rather than on memory. That made the *sets*
> consistent; the stale **label** on a regenerated record was `-fu6`, and **`-fu6` shipped 2026-08-04
> `61fc680`/`b2ff7d1`** (entry in `SUITE_TODO_DONE.md`): the A1 taxonomy is now one extracted
> `labelStagedRecord`, and BOTH writers of a staged record go through it, so a wholesale replace cannot keep
> the old label in either direction. ⚠️ It also **re-measured a fu5 mutant**: M1 (the finalize call site back
> to a bare `finalizedGroups.remove`) now reads 0 RED, because fu6 removed the reachability it needed — read
> as "fu5's defect can no longer be constructed", not "fu5 was unnecessary"; the pairing's live coverage is
> fu5's M2 in Test 17. Between them a regenerated segment's label/record and set/set consistency is whole,
> except on the resume path (`-fu8`). All in PRE-EXISTING code rather than in any of the fixes.
- [ ] **W3.cap-r3-fu10-fu1 [LOW · completeness] (blocked-on: W21.vmgui-d)** `LiveCaptureView` overlay — the
  finishing window is now modal to the POINTER only. `W3.cap-r3-fu10` decided the panel should be frozen while
  the regeneration runs and expressed that with `.frame`+`.contentShape`, but a hit-test scrim is neither a
  focus ring nor an AX barrier: with macOS "Keyboard navigation" on (off by default) ⇥+Space still reaches a
  control behind the overlay, and with no `.accessibilityAddTraits(.isModal)` a VoiceOver client can activate
  what the pointer cannot. So the decision is expressed at partial strength, and every future affordance added
  to this panel inherits the same silent hole. The one-liners that would close it (`.isModal` on the overlay,
  or `.disabled(liveProc.isFinishingScrimUp)` on the panel content) would
  retire fu7's unkillable P6/P7 mutants — but `.isModal` can hide from XCUITest the very buttons
  `W21.vmgui-d`'s own hit-test assertion needs to find, which is why this waits for the lane rather than
  guessing. ⚠️ **Updated 2026-08-04:** an earlier version also said these one-liners "would make
  `W3.cap-r3-fu11` moot". They would not, and fu11 has since **SHIPPED** (`fb833ea`/`c903bb8`) with a
  model-layer `guard !isFinalizing` in `clearSession()` — because a view-layer barrier, `.isModal` included,
  cannot make the Clear button's two halves refuse ATOMICALLY, which is the property that item turned on. So
  this item's value is unchanged and is now purely what its title says: making the window modal to focus and
  AX for **future** affordances, and killing fu7's P6/P7 + fu11's M5 as measurements. Filed
  2026-08-04 by `W3.cap-r3-fu10`'s adversarial pass. | Capture/Views | Tier-2
- [ ] **W3.cap-r3-fu12-fu1 [LOW · behaviour decision]** `LiveCaptureView.clearButton` — **in the emptied-pane
  ✅ **DECIDED by the owner 2026-08-13: PUT THE COUNT IN THE LABEL, AND CONFIRM.** The button reads what it
  does — "Discard 3 processed documents" — and asks before doing it. Both halves of the finding are in scope:
  it stops reading as harmless beside "Cancel finish" (documented as costing nothing), and abandoning paid work
  stops being one unconfirmed click. **Also preserve `finalizeSummary`, or state explicitly in the confirmation
  that the record of what the finish did not file goes with it** — that record was the second half of the
  complaint and must not be dropped silently. Confirmation-only and hide-when-empty were both offered and not
  taken (the latter partly reverses `W3.cap-r3-fu12`, which drew that header cluster precisely so stranded
  staged work stayed reachable). Tier-2 (Capture), scratch only.
  arm, Clear is an unlabelled, uncounted, unconfirmed "abandon paid work" button, and it wipes the one record
  of what a partly-failed finish did not file.** `W3.cap-r3-fu12` put it beside "Cancel finish" — which is
  documented as costing nothing — in a pane whose body reads "Waiting for photos…". It now carries a `.help`
  saying what is dropped and what survives, but the *label* still says "Clear", not "Discard 3 processed
  documents", and there is no confirmation; the one honest meaning of "Clear" in the photos-present arm
  ("throw away the photos you can see") is exactly the meaning that is absent once `photos` is already empty.
  Worst in the case fu12's own comment cites as a win: after a PARTIAL finalize, `finalizeSummary` is the only
  on-screen record of which segments did not file, and `clearSessionState` wipes it along with the roster
  (`clearFinalizeSummary()`). Decide: a count in the label, a confirmation, preserving `finalizeSummary` across
  a Clear, or that the `.help` is enough. ⚠️ A headless driver can speak to none of the first three (no label,
  no confirmation, no tooltip); summary-preservation is the only testable piece. Found 2026-08-04 by
  `W3.cap-r3-fu12`'s adversarial pass. | Capture/Views | Tier-2
- [ ] **W3.cap-r3-fu12-fu2 [LOW]** `LiveCaptureProcessor.finishSession` page seeding — **with "Review rotation"
  ON, a Finish from a ✕-emptied pane shows a review of pages that cannot load and then discards every
  correction silently.** `finishSession` seeds `rotationReviewPages` from `retained.values`, whose `sourceURL`s
  the ✕ has sent to the Trash; the operator corrects rotations, taps Apply, and
  `applyRotationReviewAndFinalize`'s `segsToRegen` filter (`allSatisfy { fm.fileExists(atPath:) }`) drops every
  segment, so `guard !segsToRegen.isEmpty` falls through to `beginFinalize()` and the PDFs file unrotated with
  no message. **Pre-existing** — and note that filter's own comment justifies itself with "e.g. the operator
  hit Clear before Finish", which is UNREACHABLE, since Clear also empties `staged`; the ✕-emptied pane is the
  reachable instance. `W3.cap-r3-fu12` promoted it from a two-step recovery to one tap by giving that state a
  Finish button. Mitigating: `reviewRotation` defaults **off** (`SettingsView.swift:66`,
  `ProcessingProfileStore.swift:99`), so it is opt-in. Likely fix is one line at the seeding site — filter
  `pages` to sources that still exist, letting the EXISTING `guard !pages.isEmpty else { beginFinalize() }`
  skip the bogus review entirely — but that is the finalize path and wants its own Tier-2 gate rather than
  riding along. Found 2026-08-04 by `W3.cap-r3-fu12`'s adversarial pass. | Capture | Tier-2
- [ ] **W3.cap-r3-fu3 [LOW]** `CaptureSession.swift:592` — `removePhoto` has no `isFinalized` guard, unlike
  ✅ **DECIDED by the owner 2026-08-13: REFUSE THE DELETE, and say why.** Give `removePhoto` the same
  `isFinalized` guard `removePhotoIfSafe` already carries two lines below it, and tell the operator the segment
  is already staged so retry/re-stage is the route. Rationale on record: it is consistent with the sibling
  function, adds no machinery, and never silently degrades a document — the operator learns immediately instead
  of finding a placeholder page later. **Exclude-and-re-stage was OFFERED AND NOT TAKEN** (it re-does work
  already paid for on a live-processing session, and makes ✕ far heavier than it looks), as was the
  refuse-plus-explicit-re-stage-affordance variant. So the intended behaviour is now settled — do NOT
  re-litigate it; implement the guard. Tier-2 (Capture), scratch only.
  `removePhotoIfSafe:606`. An operator ✕ on a page whose segment is already staged (or mid-finalize) trashes
  the source anyway, so `PDFGenerator.generate` can't embed it and writes a visible PLACEHOLDER image page
  (`.placeholder` → `.succeededPlaceholderImage` + the finish warning; the source is retained by W23.h5 and
  the file is recoverable from the Trash). Degraded-but-warned rather than lossy, which is why it is LOW —
  but it is also the opposite of what the operator asked for: they wanted the page GONE and the staged
  document now carries a placeholder page for it. Decide the intended behaviour (refuse the delete for a
  staged segment, as `removePhotoIfSafe` does, vs. exclude the page and re-stage) rather than leaving it
  incidental. Pre-existing. | Capture | Tier-2
- [ ] **W3.cap-r3-fu4 [LOW · behaviour decision]** `LiveCaptureProcessor.swift:1215` — after Finish the app
  ✅ **DECIDED by the owner 2026-08-13: REMEMBER FILED GROUPS; refuse the join and message the operator.**
  Add a durable "filed this session" set so a late page for an already-filed group gets the same honest "kept in
  the Backup Folder, start a NEW segment" message it would have received two seconds earlier, instead of
  silently opening a second one-page document. **Keeping `finalizedGroups` populated was OFFERED AND NOT
  TAKEN**, on the ground the item itself records: `isFinalized` also gates `CaptureSession.removePhotoIfSafe`,
  which would then refuse to remove pages of a group whose sources are already retired — so the durable set is
  the cleaner of the two and does not inherit that side effect. Accepting the second document with a warning was
  also offered and not taken. Tier-2 (Capture), scratch only.
  forgets that a groupId was ever filed, so a late re-upload silently opens a SECOND document for it instead
  of being told it cannot join. `finalize` drops each filed group from `finalizedGroups`, which is the only
  record that it finalized — so the "a late page arrived … kept in the Backup Folder, start a NEW segment"
  message the app shows for that same re-upload two seconds EARLIER (while the segment is staged) stops
  applying the moment the batch files, and the page is treated as belonging to a brand-new group. Post-`fu1`
  it at least buys its OCR and the second document carries text (pre-`fu1` that document was filed with none,
  which is why `fu1` ranked above this); either way the operator ends up with an extra one-page document they
  did not ask for, and no message. Found by `fu1`'s adversarial pass, which deliberately left it: closing it
  needs a durable "filed this session" set, or keeping `finalizedGroups` populated and fixing what else reads
  it (`isFinalized` gates `CaptureSession.removePhotoIfSafe`, which would then refuse to remove pages of a
  group whose sources are already retired). That is a behaviour decision like `-fu3`'s, not a bug fix. ⚠️ Do
  NOT "fix" it by re-arming a started-once guard over a page with no call — that is exactly the `fu1` bug.
  Pre-existing. | Capture | Tier-2

## Processor/Net — WS11 paced re-review findings (2026-07-18, autonomous)
Lean **delta** re-review of the **LAN/USB surface** of `ArchiveProcessor/macOS/Sources/ArchiveProcessor/Net/`
(owner carve-out, REVIEW.md L63–67: review CaptureServer/CaptureReceiver/CaptureValidation/USBBridge/
RelayObjectFormat + FileRelayReceiver's LAN path; **skip the cloud/Drive relay**). The 2026-07-09 findings
(W3.n1–n5) all hold, and the two deltas since — `53d04cc` (bound LAN request memory) + `1f58575` (persist
completion before ack) — are **clean** (serial-queue discipline intact, `close()` double-close-safe,
auth-before-disclosure, acks gated on durable returns). **1 finding, LOW, no HIGH/MED** → nothing routed to
the owner HOLD queue. Report: `.maintenance/review/Processor-Net.md`. ⚠️ The `lean-review` Opus/max fan-out
was budget-stopped before it emitted a single finding (~$4.5/min while still only reading — same failure as
the Capture re-pass); this unit was verified **INLINE** by the main-loop model. See the report.
- [ ] **W3.net-r1 [LOW · defense-in-depth]** `Net/CaptureValidation.swift:9-12` — the shared `isSafeGroupId("")`
  returns true (empty string passes the charset check vacuously; count 0 ≤ 128; no `..`), yet the "one shared
  predicate so the receivers can't drift" is relied on inconsistently: both LAN routes guard `!groupId.isEmpty`
  separately (`CaptureServer.swift:409/446`) while `FileRelayReceiver`'s photo branch (`FileRelayReceiver.swift:141`)
  does not → an empty `"group"` field in a same-token/same-epoch relay sidecar passes `safe` and reaches
  `CaptureSession.ingest(groupId:"")` (stages as `00005-.jpg`). **Not reachable via the phones** (they never emit
  an empty group) and benign if reached (filename suffix, not a path component → no traversal; `(group,seq)`
  keying stays idempotent), so LOW/hardening — but the shared predicate should reject empty to match its own
  docstring. Fix: add `!s.isEmpty` to `isSafeGroupId` (keep both receivers' explicit guards too). | Net | Tier-2

## Owner ideas — deferred, NOT for the daemon queue (do not start unprompted)
Design-level ideas the owner wants recorded but explicitly de-prioritised. An autonomous session must
**skip** these: they need the owner's scoping before any code is written.

### ⛔ DECLINED — settled, do NOT re-raise in Daemon Report
- **Auditing the daemon runs that started themselves at login (`W32.plist-relogin`) — DECLINED by the owner
  2026-08-16.** Until `9b05a62` every `stop`/park/COMPLETE only `launchctl bootout`ed the job and left the
  LaunchAgent plist installed with `RunAtLoad=true`, so the next GUI login restarted the daemon with no human
  — observed in `daemon.log` on 2026-08-05 (power-off 15:25, boot 21:56:53, `daemon up (pid 1701)` 22:00:20).
  That violated the standing rule that **only the owner starts the daemon**, and the runs it produced spent
  budget and pushed to `main` unasked. He was offered a read-only log audit (every `daemon up` with no
  preceding human start, what those sessions committed, rough cost) and the same audit plus an
  owner-start-token file the daemon would refuse to run without; **both declined.** His reasoning: the fix has
  landed — all three stop paths remove the plist, `start` reinstalls it, and the plist is gone from
  `~/Library/LaunchAgents/` — so the exposure is closed going forward, and the commits those sessions produced
  went through the ordinary gates and stand as ordinary work. ⛔ **Do not re-open the audit, and do not file a
  start-token guard.** A later session reading that same `daemon.log` evidence will find exactly what prompted
  the offer; it has been made and turned down. Full fix record: `SUITE_TODO_DONE.md`
  §*"Autonomous daemon — full review, Wave 32"* (`W32.plist-relogin`).

- **Changing the Tier-2 mutation-proof discipline so a proof can't touch the owner's real defaults domain —
  DECLINED by the owner 2026-08-10.** Context: closing `W26.fixturehang` required planting each hunk's old
  behaviour back to prove a test went red, and those runs by construction write the real
  `com.archivereader.app` domain — which left his `ar.viewState` and `ar.excludedFolders` polluted, and the
  session then *deleted* the four keys because the originals were unrecoverable. He was walked through three
  alternatives and **turned all three down**: a throwaway defaults domain even when the mutation is *about*
  the real one (weakens the proof), snapshot-and-restore around such a run (itself a write, and the read path
  hangs under TCC), and park-and-ask-first (stalls the daemon). **So: keep the discipline exactly as it is
  and accept the occasional settings reset.** His reasoning, which is the part worth not relitigating: the
  *shipped* code no longer touches his domain at all, so this can only recur when a proof deliberately
  re-plants the old bug, and every alternative dilutes the one gate that caught a vacuous guard. ⛔ Do not
  re-open this as a Daemon Report entry, and do not "improve" it in passing while working a nearby item.
  Full incident record: `SUITE_TODO_DONE.md` §Wave 26 (`W26.fixturehang`).

- **An `androidTest` source set + Compose UI-test lane for ArchiveCapture — DECLINED by the owner
  2026-07-31.** ArchiveCapture has no instrumented-test lane, so every Compose line ships visually
  unverified, and a session has now written this up **three times** (W23.h4's `AlertDialog`, W23.m1, and
  W23.m8's two status rows) as "if you ever want this closed…". The owner considered it in the Morning
  Review walkthrough and chose not to spend the build-config change on it. **So: ship Compose changes with
  headless JVM coverage of the logic — which is what `./gradlew --offline testDebugUnitTest` already gives —
  state plainly in the commit that the pixels are unverified, and do NOT open a new Daemon Report entry
  about the missing lane.** One line in the Session Log is enough. Revisit only if the owner asks.

- [ ] **W24.cal1 — dates: store ISO 8601 always; make the *display* calendar a per-item, opt-in toggle.**
  Owner direction (2026-07-31 Daemon Report, in response to the W23.l4 `Calendar` deviation). Two halves:
  (a) the **stored** value is always proleptic-ISO-8601 — that is what `Store/GregorianDay.swift` already
  does, and it must stay the canonical on-disk form, so this item does not change storage; (b) the
  **rendering** calendar becomes a user choice **per note and per document**, defaulting **off** in
  Settings — with it enabled (a medievalist's mode), each item offers a choice of calendar systems
  (Julian, Julian-with-1752-English-cutover, French Republican, Hebrew, Islamic, …) for display and for
  the date-entry validator's "N days in that month" rule. Supersedes the narrower fix of hard-coding the
  Anglo-American 1752 cutover: `GregorianDay` fixes the switchover at **1582**, so a genuine English or
  colonial `1700-02-29` is rejected today — under this design that becomes a *display/validation profile*
  rather than a global constant. Not urgent: the working corpus begins 1789, after every candidate
  cutover, so nothing is currently mis-handled. Notes `Store/GregorianDay.swift`, `Views/DateFieldEntry.swift`,
  Settings; Reader display parity to be scoped with it. | Notes | Tier-2 | L | **deferred — owner-scoped**
