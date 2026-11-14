# Archive Suite — working to-do queue

The **near-term** to-do queue for both apps (see root `CLAUDE.md` §Docs & backlog convention). Long-term
ideas live in each app's `POTENTIAL_FEATURES.md`; detailed in-flight plans live in `execution-plans/`
(indexed below, deleted when shipped). Full-codebase review: the paced method in `REVIEW.md`. Unattended /
autonomous runs: `ops/autonomous/README.md` (durable plan → self-resume daemon), which drains this queue one
bounded item per fresh session.

**This file holds only OPEN items.** Completed work moves to [`SUITE_TODO_DONE.md`](SUITE_TODO_DONE.md) —
2026-08-01, when 47 open items were buried among 160 done ones in a single 3,580-line file. When you finish an
item, **move its whole entry there** rather than ticking it in place; the completion note and its commit still
belong in the same commit as the code, exactly as before. **That file is append-only (since 2026-10-08,
`W35.done-union`):** add the entry at its END, naming its section on the header line (`· §<section>`) and closing
with its own `  <!-- /<TAG> -->` line, and never edit an entry already there — `.gitattributes` gives it
`merge=union`, which is safe only for appends. The rule and the reason are in that file's header.
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


## Autonomous daemon — handoff integrity (2026-08-13)


## Autonomous daemon — document budgets (owner, 2026-08-12)

## 🎯 Project focus & ON-HOLD areas (owner, 2026-07-09)

**Focus now:** the **wired (USB) + wireless (LAN/Wi-Fi) phone↔Mac transmission** path and the **Android**
companion — plus the core Mac pipeline (OCR/tag/PDF/finalize) and the Reader, which continue as normal.

**ON HOLD — maintain-only** (mirror shared-contract changes so they don't rot, but **no new feature
development, and NOT a code-review or bug-fix target**; keep them compiling):
- **iOS companion** — `ArchiveProcessor/ArchiveCaptureiOS/`. Parked 2026-07-18, **revived by W40.i1
  (2026-10-21)**: it builds again and the health gate builds it (`ios-build`, generic simulator destination,
  no simulator runtime needed). Its revival work is W40.i2-i5 (parity with Android, the E2E, the borrowed
  phone); until those land, the maintain-only rule above still applies to it.
- **Cloud (Google Drive) relay transport** — Mac `Net/{DriveObjectStore,DriveClient,DriveAuth}.swift` + the
  `FileRelayReceiver`/`RelayObjectStore` cloud path (incl. the offline `FileRelay` stand-in); both companions'
  `DriveRelayTransport`/`DriveAuth`/`DriveClient`. The `RelayObjectFormat` wire contract stays frozen — only
  mirror it if a focused change forces it.

*Maintain-only* means: if a protocol/SPEC change on the focus path (LAN/USB, Android) requires it, mirror the
minimum into iOS/cloud so they still build — but don't invest effort or reviews there. **Code reviews + fixes
concentrate on:** LAN transport (`Net/CaptureServer.swift`, `CaptureReceiver`, non-Drive `Net/`), USB
(`Net/USBBridge.swift`), the **Android** app (`ArchiveCapture/`), and the Mac pipeline + Reader.

## Active execution plans (`execution-plans/`)
- `items/<TAG>.md` — per-item progress notes (checkpoints, session notes, saved-draft branches), one file per
  open item, deleted when it ships; the item's entry here carries only a `Notes:` pointer (W35.item-notes).
- `parallel-workers/` — **PLANNED 2026-10-05 (W35, the daemon)**: several sessions at once, sized from the usage
  readings so the five-hour windows are used; claims, a heavy-work lock, per-lane workers, pace rule. `00-plan.md`.
- `benchmark-corpus/` — **PLANNED 2026-10-16 (W43, Archive Processor's OCR bench)**: a broader truth set — fifteen
  strata of public page-level ground truth (Latin-script hands, print and newspapers from 1500 to 1950, plus Arabic,
  Cyrillic, Greek, Hebrew, Chinese and Devanagari) on top of the frozen 96, sized from the panel's variance, with
  sources, licences, scorer changes and cost. `00-plan.md`; waits on `W43.corpus-plan-owner-ok`.
- `processing-review/` — **REVIEW DONE 2026-11-06 (W46, Archive Processor; planned 2026-10-20)**: segmentation, dating, OCR,
  enhancement, layout, text placement, marks, entities, kinds, capture and the training kit reviewed against the
  literature and the current models, measured in Phase 3 (74 items plus the measurement audit's), and decided in Phase
  4 as the rules the settings layer applies: `13-stage-rules/` (one note per stage, the table schema, the owner's calls,
  the solver's test cases). `00-plan.md`; `STATE.md`. Kept until the settings build ships, as its source; delete then.
- `integration/` — **APPROVED 2026-10-14 (W42.int, the suite)**: Vision OCR's engine inside Archive Processor. Stages 1-3,
  5 and 7 filed 2026-11-06 in §"Vision OCR's engine"; stages 4 and 6 replaced by §"The settings layer — W46.settings".
- `reader-owner-notes-2026-11-10.md` — **FILED 2026-11-10 (Archive Reader, with Processor and suite items)**: the owner's fifteen points from using the Reader on the full corpus, read and measured, their shared causes, and which item answers which; items in §"Archive Reader at corpus size, and the owner's notes of 2026-11-10".
- `containers/` — **APPROVED 2026-10-21 (W47, all three apps)**: repository, collection, accession, series, box and
  folder for every item, from label photos or a labelled folder tree, edited in the Reader. `00-plan.md`; items in
  §"Archival containers — W47".
- `segmentation/` — **PLANNED 2026-10-05 (W36, Archive Processor)**: a bake-off of automatic segmentation methods
  (frontier models over page windows, a second model as voter, on-device feature and vision models, agreement plus
  review) on the owner's ground truth, the owner's decision, then a build only if usable. `00-plan.md`; the first early read (W36.seg-window) is `03-early-read.md`.
- `verification-phase/` — **APPROVED 2026-10-04 (W40, all three apps + both companions)**: the phase after the
  build queue — honest gates, the iPhone companion revived, feature ledgers that replace checkboxes as the
  measure of done, end-to-end rehearsals on copies of real material, tool-based bug finders, the owner's guided
  sessions, then a release candidate. `00-owner-plan.md` (owner-facing) + `01-daemon-plan.md` (daemon detail).
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
- ~~`archive-notes/09-gap-closure.md`~~ — **SHIPPED 2026-10-11, plan deleted (W9.e4)** (Archive Notes post-ship
  reconciliation, Phases A–E). Its deferrals and deviations moved to `archive-notes/00-overview.md` §17, which
  remains the retained interface contract; completion records are under §W9 in `SUITE_TODO_DONE.md`.
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

## Wave 26 — de-Spotlight the suite (owner directive 2026-08-04) — plan DELETED (`W26.plandelete`)

Every Wave 26 item has shipped. The wave's background (the 2026-08-04 incident, the measurements behind the
design, the `getxattr`-not-`access` probe rule, the cloud-storage `setiopolicy_np` per-thread requirement, the
§7a stress-pass notes and the per-item ship notes) moved verbatim on 2026-10-21 (`doc-fix`) to
`SUITE_TODO_DONE.md` §"Wave 26 — background, moved from SUITE_TODO.md". Still open there for the owner, not
decided: whether `IOPOL_SCOPE_PROCESS` should also stop `PDFTextExtractor`/`ContentIndexer` downloading
dataless files.

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

**iOS parity** (§Project focus): where a finding has an iOS twin (`W23.m1`), fix **Android only** and
record the iOS twin; `W40.i2` collects those twins into the parity comparison.

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

### LOW

### Follow-ups discovered while fixing Wave 23

- [ ] **W23.m4-fu — a page-specific reveal opens a NEW window per page instead of navigating an open one (lane: reader) (uses: build)
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
- [ ] **W13.cli Phase 0 — install `gemini` + `codex` CLIs and confirm entitlements (owner).** (lane: ops) (uses: light) Was buried in a
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

### Folded into an existing item (NOT a separate task)
The **silently-swallowed tag-write failures** (`_ = try? MacOSTagger.applyTags(...)` at
`LiveCaptureProcessor.swift:640/647/673`) — a real finding that appeared in **neither** KNOWN_ISSUES entry — is
folded into **`W3.cap-r1`** above and **must ship in the same commit as r1's overload fix**, because both rewrite
the same three lines and landing them separately would silently revert part of the first. See that entry.

## Wave 19 — Notes date-mirror + Quality facet (MERGES/replaces Priority) (owner-reviewed 2026-07-18)
Owner decision from the wishlist review, refined: (a) Notes mirrors its front-matter **date** into Finder tags
(reuse the existing Year/Month/Day/Decade facets — **no** SPEC change); (b) **no author** tags; (c) a **single
rating facet, `Q1`/`Q2`/`Q3`**, that **MERGES WITH + REPLACES the Priority facet** — they were redundant
("how important is this document"). Owner-locked contract: 0–3 scale, **Unrated writes NO tag** (so the wire
only carries `Q1`/`Q2`/`Q3`); `Q3` is highest. Priority is **retired** from public app surfaces and the
phone↔Mac protocol: both companions and the Mac exchange only Q tokens, omitting the field for Unrated.
There is no P alias, migration, or backward-compatibility path. Human-set everywhere, never LLM-emitted:
Notes (front-matter), Reader (edit), Processor's interactive tagging, and the phone companions.
Shared-contract (Tier-2) — SPEC first, then the shared parser, then each app + companions; every code item must
**build + test all three apps**, scratch-only. **This wave REPLACES existing priority UI/plumbing — merge, don't
add a second control alongside.**

## W21 — GUI lane generalization + small hygiene (owner-reviewed 2026-07-28)
**Complete.** W21.vmgui-a…d (one per-app VM table, corpus-free fixtures, Notes and Processor lanes; the gate
rotates one app per run) are in [`SUITE_TODO_DONE.md`](SUITE_TODO_DONE.md).

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

- [ ] **Import the personal DEVONthink database into Archive Notes** (lane: notes) (uses: build) ⏸ **ON HOLD (owner, 2026-08-01 — see the
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
## Archive Notes — NEW APP (SHIPPED W0–W8, 2026-07; `execution-plans/archive-notes/00-overview.md` retained)
Owner-specced third Suite app; foundational decisions locked (D1–D10, `00-overview.md §2`). **All waves shipped;
the per-wave plans (`00a`, `01`–`08`) were deleted on ship** (git history + the W0–W8 `[x]` records below are the
account); only `00-overview.md` is retained as the authoritative interface contract. DevonThink informs **only**
the 3-pane browsing shell — everything else (note appearance, link/provenance UI, replication semantics) is
purpose-built for the historian's provenance-first workflow. **R13d removed the former `ArchiveSuite`
marker/exclusion feature; no later convergence work remains for it.** **Confirmed (owner):** the FULL
**ArchiveCore extraction + Reader/Processor migration is W0 — done FIRST** (`00a`), before any Notes-specific work.
### W9 gap-closure — CLOSED 2026-10-11 (W9.e4)

Every Phase A–E item has shipped and `execution-plans/archive-notes/09-gap-closure.md` is deleted; the
completion records are under §W9 in `SUITE_TODO_DONE.md`, and the plan's out-of-scope and deviation lists now
live in `execution-plans/archive-notes/00-overview.md` §17. ⛔ Do not re-file A4 (R13d removed the
`ArchiveSuite` marker on purpose). New Notes gaps are filed as their own items, not under W9.

## Document processing review — W46 (owner, 2026-10-20)

The owner paused processing work for a review of the whole approach: `execution-plans/processing-review/00-plan.md`.
The plan's HOLD QUEUE gate `W46.review-done` now holds every segmentation, OCR, dating, layout, text-layer, model and
sweep item: W41.seg-label-clean-fu1, W41.app-local-seg-publish, W43.seg-date-public, W44.reocr-plan, -spec,
-processor and -reader, W43.sweep, W43.farmshare-ocr-more, W43.open-sweep-more, W43.general-sweep-farmshare,
W43.inkling-farmshare, W43.ppocrv6-farmshare, W43.app-guide-refresh, W42.c41-newspaper-scans, W40.d1, W40.d3 and
W40.d4. The Vision OCR integration (W42.int-s1 to s7, not yet filed) also waits on it. The gate replaces the earlier
parking behind W43.sweep-owner-ok, which would have released all of them with the paid sweep. The Processor UI and
bug items (W40.a5, i1-i3, i5, b3, b4, d2, d5, e8, e12, g3) no longer wait on W42.int-done, so the engine can run
them; d2 and g3 still wait on d1. The review files its own work queue in its Phase 4, then the gate is approved.

**Phase 3, the experiments, filed 2026-10-21 (owner: "File Phase 3 items").** 74 items in the audit's rank order
(`execution-plans/processing-review/10-gap-audit.md` §5), after three cluster-infrastructure items that come first.
None waits on `W46.review-done`, which is approved only in Phase 4. Where an item has free arms and a gateway arm,
it is split: `<id>` runs the free arms (open models, the Claude and ChatGPT plan routes) and `<id>-paid` runs the
Stanford gateway arm after it, behind `W46.gateway-models-ok`; each paid item keeps the $3 rule except
`W46.seg-window-modality-paid` (owner-approved, cap $8.00). An owner judgement pass is split the same way: the item
that builds the sheet, a HOLD QUEUE gate that waits on it (so it is not asked before the sheet exists, and the
preparing session judges the timing), then a `-score` or `-lock` item. A `(cluster: farmshare|sherlock)` marker
names an item that needs a cluster; it is not a uses value, because `worker-state.py` and the Agent Manager refuse
unknown ones. Every cluster item waits on `W46.cluster-waves`. Owner gates in the plan's HOLD QUEUE:
`W46.gateway-models-ok`, `W46.sherlock-ok`, `W46.box-ok`, `W46.truth-bias-owner-ok`, `W46.date-cases-owner-ok`,
`W46.mixed-def-owner-ok`, `W46.seg-boxes-named-ok`, `W46.seg-boxes-owner-ok`, `W46.seg-boxes-overlap-ok`, `W46.fix-marks-set-draft-owner-ok`, `W46.marks-core-owner-ok`,
`W46.rta-gold-ok`, `W46.macos27-ok`, `W46.date-audit-owner-ok`, `W46.seg-truth-owner-ok`, `W46.ocr-hands-owner-ok`,
`W46.place-lines-owner-ok` (the last three filed by the 2026-10-30 measurement audit, `execution-plans/processing-review/11-measurement-audit.md`),
`W46.date-undated-owner-ok` (filed by the standing measurement review's first note, `execution-plans/processing-review/measure-reviews/2026-10-31.md`),
`W46.pairs-redecide-owner-ok` (the solver's tie rule for readers, filed by pass 13, `execution-plans/processing-review/measure-reviews/2026-11-11-2.md`; answered 2026-11-11: floor only).

- [ ] **`W46.measure-review` — the standing measurement review: read the new results, refute-check, rework the queue, re-arm [M · standing]** (lane: segbench) (uses: light) (effort: xhigh) (blocked-on: W46.measure-review-due) — Owner, 2026-10-30: after W47.item-fields-truth scored the app against a weak model-built truth, a standing review on the strongest model; owner, 2026-11-04: on Opus at xhigh (`(effort: xhigh)`), no longer Fable at max. Standing, never ticked. ops/agent/measure-review.py (the upkeep hook) ticks W46.measure-review-due in ## RECURRING after 12 items finish with a result, not counting the review's own corrections (owner, 2026-11-11; it was 8 items from 2026-11-04, and 8 result commits or a week with one before that); the session follows ops/autonomous/README.md §"The measurement review" (status and cards, the six flaw classes, an independent refute-check, a dated note under execution-plans/processing-review/measure-reviews/, the queue reworked through plan-edit.sh with SUITE_TODO in step, owner sheets as gates, retirements and nice-to-have moves asked in the Daemon Report), then measure-review.py done <sha> and plan-edit.sh rearm W46.measure-review-due. Why: execution-plans/processing-review/11-measurement-audit.md.
  Latest pass: 2026-11-13 pass 14, `execution-plans/processing-review/measure-reviews/2026-11-13.md`, reviewed through 2ce8916a. The dewarp guard and the guarded copy for selection, the owner's rotation turns, the voter on g2 as a measurement, the reverted prompt, the like-for-like seconds, the text-only tier's pre-fixed call, the dating route's counts, the hand route's cost, the entity feature's figures, the 8B checkpoint and pass 13's six items stand on their main figures; the session recomputed each headline it relies on from the committed JSON. No independent hunt or refuter ran: three subagent launches ended on an authentication error (HTTP 403) before reading a file, so the next pass holds P14-1 to the refute test. Major: profile case D5's pick (gemini3.8-flash over the Claude plan, 88.8 against 85.5, 0.1 past the 3.2 floor) rests on one offset-0 run whose source calls the gain run variation (the same model's g1 spanned 83.0-85.2 at offsets), against a Claude prompt with no article rule, over a floor built from one rerun range where the reading floor is twice. Minor: the entity card misnames the truth's drafters; the curved-select headline is the figure after a rule added on seeing the first run; the one-way flag's 5.6% is on the run that suggested it, 3 of 5 judged by the model's own image pass; the 895 picks ignore the hosted floor (no pick changes); the cadence counted four built-table touches as results (fixed, 10 of 12 under the filter) and `cards` listed SUMMARY.md (skipped); the magazine figure ranking is the adoption set's. Two items queued (W46.seg-g2-offsets, about $2.60 on the gateway; W46.p14-wording, $0); a condition on W46.date-route. The standing item stays open.


**Phase 4 done, 2026-11-06 (owner-started Fable session; `execution-plans/processing-review/13-stage-rules/`).** Reconciled with the settings design: its output is
the rule table, one short rule note per stage and the solver's profile test cases, not per-profile decision notes (the
plan's §"Phase 4", rewritten). Twelve notes drafted and verified against every measurement-review pass; the owner's
eleven calls in `14-owner-calls.md` §1 (the settings document beside the output; a "stays on the Mac" switch and no
quality floor; a skipped interview is free on this Mac; Vision for typed and printed pages with the handwriting download
offered; the cascade a route like any other; straighten on, no dewarp or shading; the cluster kit with the continuation
and the handwriting fine-tune ship; no $2.60 personal-key run; second-role dates in the sidecar and the evidence form;
the provisional name rules move to the entity feature; entities on cloud routes always and on the Mac when names rank,
no export yet); the session's picks in §2. `W46.review-done` approved the same day. Filed: the settings build (its own
section above W47), the integration stages (§"Vision OCR's engine"), the app changes and useful-now measurements below,
and the nice-to-have items (§"Nice-to-have, end of project"). Not filed, with the reason: plan-route bench arms
(`seg-locked-plans`, `ocr-plan-chatgpt`; barred by the plan-routes rule, root CLAUDE.md 2026-10-21 and 2026-10-30), a
clippings box (SC0122 is the review's clippings box), the encoding test (already run, `enh-dewarp.md`), the entity
export (POTENTIAL_FEATURES until a user asks). The 16 items the gate held are kept as they stand; `W43.app-guide-refresh`
now takes the rule table as its source.




- [ ] **`W46.date-route-image-routes` — the dating image pass beyond the gateway [S-M]** (lane: processor) (uses: build) (blocked-on: W46.date-route-pipeline-8b) — Owner, walkthrough 2026-11-13: the direct-key Gemini 3.8 route is dropped (no direct Gemini key); only the Mac 8B route remains, if W46.date-route-pipeline-8b measures it worth adding. filed by W46.date-route, 2026-11-13. Its first session (2026-11-13) found neither route measured and filed both measures, so the item waits for them; a route whose measure shows no gain is dropped, not added. Step 2 runs only through a remote gateway, as Gemini 3.7 Flash, the route W46.date-route-pipeline measured; on a direct key, OpenRouter, a Local Agent or a model on this Mac it is skipped and the sidecar says so (`image_pass`: no measured image route). 08-dating.md §9 and call 7.5: the Mac's Qwen3-VL 8B image pass at 16 GB once its quotes are shown to improve the year (item 8.1's 27B half, W46.date-route-pipeline-27b, is the nearest measure), and Gemini 3.8 on a direct key once measured on the 122. Add each route only with its measured row.
- [ ] **`W46.seg-check-context` — Check Flagged Boundaries shows more pages either side of the gap [S-M · Tier-2]** (lane: processor) (uses: build,vm) — Owner, 2026-11-13, after the W46.seg-check-time session: "This UI would be more effective if the user was shown more images on each side for context. It's hard with just two." The sheet shows only the two pages beside the gap. Show a run of pages either side (a scrolling strip, the gap's two pages larger and marked, the user's earlier answers on the neighbouring gaps drawn between pages), sized to the window, with the S/J keys and the blind question (W46.seg-check-blind) unchanged. A design question for the item: how many pages, and whether the neighbours are thumbnails or full size. The timing figure W46.seg-check-time measured (3.2 s a gap) is for the two-page sheet; the item says whether a wider sheet needs a new timing session, and if so files it as the owner's, after this ships.
- [ ] **`W46.seg-tie-borrowed-range` — the segmentation tie borrows g1's 2.4-point range for routes with none measured [S · Tier-2]** (lane: processor) (uses: build) — Owner, walkthrough 2026-11-13, on W46.seg-truth-owner-fixes' question: option (b). On the corrected Stanton and RG165 truth Gemini 3.7's g2 offset range grew from 0.3 to 5.2 points, so the shipped construction (twice the larger offset range; a route with none measured takes the largest) gives a 10.4-point tie, and three picks moved to routes about 8 points weaker (Mac 2B over Gemini on a 16 GB Mac, Claude alone over the mix on both plans, GLM-5.3 Flash over ChatGPT without a Gemini key). The 5.2 is one route's three runs on 363 pages. Change the construction: a route with no measured offset range borrows g1's 2.4 points, so a pair with one such route ties at twice the larger of its own range and 2.4 (4.8 when neither is measured), and g2's own pairs keep 10.4. Expected picks: Gemini over the Mac 2B on a 16 GB Mac, ChatGPT over GLM without a Gemini key; state what both plans and D5 pick. Update SettingsSolver.segmentationTie, settings_routes.py and settings-routes.json (--check), 07-segmentation.md §3, §4 and §9, 13-profile-tests.md, and the solver, chooser and sheet tests that assert the moved picks. The per-pair floor (each route's own range once measured; Claude's waits on W46.gateway-models-ok) replaces the borrowed figure when it lands. $0, no model call.
- [ ] **`W42.int-s3-tag-precedence` — the classifier picks the reader; Finder tags only mark clippings or break an unsure call [S · Tier-2]** (lane: processor) (uses: build) — Owner, walkthrough 2026-11-13, on W42.int-s3's question: option (c). The kind tags are the owner's own Finder tags on the corpus photographs (Handwritten, Clippings, Statistics); no part of the app writes them, and the classifier is the part that sets a page's kind consistently (144/144 in-sample, 137/141 held-out), so it decides how a page is read. W42.int-s3 shipped Phase 4's rule that a tag corrects everything and passes the 0.8 floor; with the originals' tags 7 of the 144 labelled pages went to another reader than their label's (Statistics on 4 pages labelled not a form, Clippings on 2 typewritten pages and a form). Change `PageKind.detect` and routing: (1) a Clippings tag marks the page a clipping (the kind, for the interview, the layout stage and the sidecar) but the reader and the PDF header's `Kind:` follow the classifier's hand, not print; (2) Statistics and Handwritten count only when the classifier is under 0.8, and a tag no longer lifts confidence past the floor; (3) the newspaper rule and the untagged path unchanged. Update `OCR/PageKinds.swift` (`fromFinderTags`, `routingKind`/`headerKind` for a tagged clipping), `OCRPageKindTestDriver` section 10 (the "a Finder tag corrects" and "passes the confidence gate" checks become their opposites), `scripts/segbench/page_kinds.py` and the `page-kinds.json` pin, `segbench-results/page-kinds.md`, and `execution-plans/processing-review/13-stage-rules/10-kinds-and-routing.md` (Phase 4's tag rule, with this walkthrough as its authority). Re-measure the 144 with tags and state how many of the 7 now reach their label's reader. $0, no model call.

- [ ] **`W46.layout-newspapers` — PP-DocLayoutV3 regions on newspapers in the app, for every reader [M]** (lane: processor) (uses: build) (blocked-on: W42.int-s2, W46.layout-pair-newspapers) — `execution-plans/processing-review/13-stage-rules/03-layout.md`: a layout stage on newspapers and dense multi-column print only, read in the detector's own order, for every reader (the gain is nil, not negative, for large readers); never on handwriting or registers; picture regions kept, since the app's filter kept 7 of 45 marks against 26; a whole-page fill when the regions cover too little of Vision's ink (PP reads 69.4% of L9 ink on average; the threshold measured in this item); whole page as the failed-page fallback. 794 MB RSS; time from `W46.ocr-time-like-for-like`.


- [ ] **`W46.kit-continuation-replay` — the continuation without the owner's corpus replay set [S]** (lane: segbench) (uses: light) (cluster: sherlock) — Filed by W46.kit-continuation, 2026-11-13. The measured recipe (`seg-adapt-lora.md`, k = 200) replayed three corpus windows for each correction window, from the corpus 2B's own training set; a kit user other than the owner has no such set, and the kit does not distribute it (one owner's archive). `kit_continuation.py rows --no-replay` trains on the corrections alone and records it as not the measured recipe. Measure, on the same Lincoln arms (box 1's first 200 gaps, scored on box 2, paired against the k = 200 arm and the 2B): the corrections alone, and a replay drawn from what a kit user has (the material's own accepted-gap windows, or a public set's training split); then set `rows`' default and the README's advice from it. About 1.4 GPU-hours on Sherlock (training 15 to 54 minutes an arm), no calls; the preparing session writes the size-and-necessity review first. Notes and the size review: `execution-plans/items/W46.kit-continuation-replay.md` (pack prepared 2026-11-13: arms `none` and `public`, TABME++ replay; held ready to submit).

- [ ] **`W46.kit-hands` — the handwriting fine-tune: the line-correction screen and the per-hand check [M · Tier-2]** (lane: processor,segbench) (uses: build,light) (blocked-on: W42.int-s5, W42.int-s5-hands) — Owner, 2026-11-06 (call 7): ships in this release. A line-correction screen in the Processor over the hand route's blla lines; the kraken PP-OCRv6 fine-tune (`ocr-ppocrv6-hands.md`: +1.12 at 80 corrected lines, +2.50 at 160, a tie at 240) offered from 80 corrected lines with 160 as the target, on the handwritten kind, only where kraken is the reading route; a per-hand held-out acceptance check and a manifest (none exists); the tie unit kraken's rerun floor of 0.



- [ ] **`W46.date-route-pipeline-8b` — the restated dating route with the Mac's Qwen3-VL 8B image pass [S]** (lane: segbench) (uses: light,model:10) (blocked-on: W46.date-route-pipeline-27b) — filed by W46.date-route-image-routes, 2026-11-13. Call 7.5 adds the 8B image pass at 16 GB only once its quotes are shown to improve the year. Run `date_route_pipeline.py`'s step 2 with the 8B (4-bit MLX, 1,400 px, under the heavy lock) on the same Vision-defined sets, $0, and score it beside Gemini 3.7's and the 27B's rows; its combined row goes in `13-stage-rules/08-dating.md` section 4. If the 27B's quotes do not improve the year, record that the 8B (the weaker reader) is not run and close this as not needed.


- [ ] **`W46.ent-local-shipped-prompt` — the entity prompt on the Mac and cluster models over Vision text [S-M]** (lane: segbench) (uses: light,machine) (cluster: sherlock) — Qwen3-VL 8B on the Mac and Qwen3.6 27B on the cluster, the entity prompt over the 138's Vision text, with seconds a document and peak memory; today's Mac and cluster entity figures are the old prompt on ABBYY text (`ent-truth-owner.md`), so the rows are provisional until this lands. Notes and the size review: `execution-plans/items/W46.ent-local-shipped-prompt.md`.




## The settings layer — W46.settings (owner, 2026-11-04; filed by Phase 4, 2026-11-06)

Owner, 2026-11-04: the processing review's output is a way for users to choose their settings, not the owner's
defaults. The design (`execution-plans/processing-review/12-settings-design.md`, the owner's six calls in its §1) is
two interviews, a limits-first sheet with the range view one tab away, three live-inheriting layers with every value's
source shown, and defaults only behind the interviews. Phase 4 (2026-11-06) wrote the rules it applies as one short
note per stage in `execution-plans/processing-review/13-stage-rules/` (the schema in `00-index.md`, the owner's calls in `14-owner-calls.md`, the solver's test cases
in `13-profile-tests.md`), and files its build here. These items replace the integration plan's stages 4 (the measured
table and the router) and 6 (plan this batch), which are not filed. The order is the dependency order: the table first,
since the solver, the sheet and the stage rules all read it.

Every `W46.settings-*` item has shipped; their entries are in `SUITE_TODO_DONE.md`.


## Archival containers — W47 (owner, 2026-10-21)

Repository, place, collection title, collection number, accession, series, container, folder and folder title for
every item, worked out from label photos (Route A) or a labelled folder tree (Route B), and corrected in one place,
the Reader. Every field is optional. The owner's corpus is one test case, not the design target: the owner asked
that the two common routes work for any user. The assessment, the measured corpus figures, the field list with its
Zotero mapping and the design are in `execution-plans/containers/00-plan.md`. Approved and filed 2026-10-21 (owner:
"file as drafted", with Accession and Series as fields and the two routes). This reverses the 2026-07-15 ruling
that removed the Box > Folder > Document hierarchy as out of scope. Owner gates in the plan's HOLD QUEUE:
`W47.ct-truth-owner-ok`, `W47.ct-truth-revise-owner-ok` (the second label sheet), `W47.ct-truth-final-owner-ok` (the third, short label sheet), `W47.ct-design-ok` (blocked-on: W47.ct-read, W47.ct-read-paid: the paid arm's figures go into the same review, 2026-11-06) (blocked-on: W46.p12-wording: ct-read.md's recommendations corrected before the review reads them, measurement review pass 12, P12-4), `W47.item-fields-owner-ok`. No app code is written before `W47.ct-design-ok`.

- [ ] **`W47.ct-normalise` — title case and the user's standard names for repositories and collections [S]** (lane: suite) (uses: build) (blocked-on: W47.ct-spec) — The owner's label-sheet notes (2026-11-05, filed by W47.ct-truth-revise): a value read off a label is shown in title case, acronyms and the like kept (an invented example: "BOX 12" and "JANE DOE PAPERS" show as "Box 12" and "Jane Doe Papers", "UCLA" stays); and the user can set one standard name per repository and per collection, so two labels that word the same library differently ("Special Collections, Example Library, Example University" and "Example University Library Special Collections") both show as the name they chose ("Example University, Example Library"); likewise which parts of a label go into which field. The label truth keeps values as written and W47.ct-read compares them case-folded, so this is display and editing, in ArchiveCore beside the run record, used by the Processor and the Reader. detail: execution-plans/containers/00-plan.md **2026-11-10:** use the title-case rule W40.reader-prose-structure puts in ArchiveCore (or put it there first, if this item goes first); one rule for both.
- [ ] **`W47.ct-spec` — SPEC/containers.md and the ArchiveCore model [M · Tier-2]** (lane: suite) (uses: build) (blocked-on: W47.ct-design-ok) — The run record (the nine fields, each with its source: path, label or user, and confidence), the inheritance rule (folder run inside box run inside collection; a new box clears folder fields), the per-directory container file (name, JSON format, never Spotlight content), the Route B level map stored per root, the CSL mapping (archive, archive-place, archive_collection, call-number, archive_location; accession and series in Extra). New files only; no existing file rewritten. detail: execution-plans/containers/00-plan.md — 2026-11-05, W47.ct-truth-revise: the run record has fourteen fields now, not nine (box title, series title, collection subtitle, date or time period and other identifying marks added; Series and Accession only when the label names them), as in `ct_truth.py` FIELDS_REV.
- [ ] **`W47.ct-infer` — the inference in ArchiveCore, both routes [M]** (lane: suite) (uses: build) (blocked-on: W47.ct-spec) — Route A carry-forward from markers (colour label, Box/Folder tag or classification), Route B from the level map and the name patterns in directory and file names, merging by field with user over label over path, and warnings for disagreements, reversals and long unmarked runs. Tests on scratch fixtures for both routes and the mixed case. detail: execution-plans/containers/00-plan.md **2026-11-10:** after W40.suite-item-types the Box/Folder marker is the item type, read from its tag or a root's colour setting, not the colour itself.
- [ ] **`W47.ct-folder-date` — a dated folder photo dates the undated documents inside it [M · Tier-2]** (lane: suite) (uses: build,light) (blocked-on: W47.ct-infer, W46.date-undated-fold) — Owner, 2026-10-31, in his notes on the page-date sheet (W46.date-undated-sheet, D06, D14, D18): "A date is given, so all the documents inside can be assumed to come from this date if otherwise undated." Nothing in the app, SPEC/tag-format.md or the queue does this now: an undated document gets a year estimated from its neighbours, with Date Uncertain. First measure on the agreed undated set (the 425, JPEG originals, Vision text): how many folder photos carry a date, how many undated documents sit in a dated folder, and how often the folder's year matches the year the document's own page gives where it has one ($0; no ABBYY text). Then the rule, in W47.ct-infer's run inheritance: a folder run carries the date read off its photo (a year, a range such as D14's 1965-1967, or a month), and a document in that run with no date of its own takes it. The questions this raises go to the owner at W47.ct-design-ok, not decided here: the tag a range becomes (a decade, both years, or the first year), whether an inherited date keeps Date Uncertain, and whether it fills the month. A change to what is written updates SPEC/tag-format.md and the Reader together (Tier-2). A document's own date always wins over the folder's; a dated document elsewhere in the folder does not date its neighbours by this rule. Sheet answers and notes: ~/Library/Caches/ArchiveSuiteRehearsal/date-undated/sheet/owner-notes-20261031.json.
- [ ] **`W47.ct-reader-view` — the Container column and facets in the Reader [M]** (lane: reader) (uses: build,vm) (blocked-on: W47.ct-infer) — A Container column and facets for repository, collection, accession, series and container, read from the container files and the inference; the Route B level-map sheet when a root is first added. detail: execution-plans/containers/00-plan.md
- [ ] **`W47.ct-reader-edit` — the one place to edit: the container inspector [M · Tier-2]** (lane: reader) (uses: build,vm) (blocked-on: W47.ct-reader-view) — An inspector that edits a run (every item under it follows), "set for selection" that splits runs, and the warnings list. Writes only the container file, a new write class under the Core Directive; tested on scratch copies. detail: execution-plans/containers/00-plan.md **2026-11-10:** the container inspector is a section of the Reader's Inspector (Edit Info renamed by W40.reader-commands-table), not a second panel.
- [ ] **`W47.ct-processor-capture` — Route A at capture: read the label, confirm on the card [M · Tier-2]** (lane: processor) (uses: build) (blocked-on: W47.ct-infer, W46.review-done) — Read box and folder labels on W47.ct-read's recommended route in Live Capture and Process Files, show the parsed fields on the capture card for correction, write the container file at finalize; the collection-name prompt keeps the numbers it now drops. detail: execution-plans/containers/00-plan.md
- [ ] **`W47.ct-processor-intake` — Route B in Process Files: nested folders read with the level map [M]** (lane: processor) (uses: build) (blocked-on: W47.ct-processor-capture) — Process Files reads a dropped tree recursively instead of flat, applies the level map (pre-filled, confirmed once), and writes the container file with the output. detail: execution-plans/containers/00-plan.md
- [ ] **`W47.ct-backfill` — read an existing corpus's markers and propose runs for review [M]** (lane: processor) (uses: build,paid) (blocked-on: W47.ct-processor-capture, W47.ct-reader-edit) — A command over a chosen folder that reads its marker photos and folder names and proposes runs, accepted directory by directory before any container file is written. Built and tested on scratch copies; running it on the owner's real corpus is the owner's own action from the app. A paid read over $3 asks first. detail: execution-plans/containers/00-plan.md **Measurement audit (2026-10-30, `execution-plans/processing-review/11-measurement-audit.md`):** FLD-10: the spending line is $7 (owner, 2026-10-28), not $3.
- [ ] **`W47.item-fields-build` — extract a title for every document and fill the reliable item fields [M · Tier-2]** (lane: processor) (uses: build) (blocked-on: W47.item-fields-truth, W47.ct-design-ok, W46.review-done, W47.item-fields-retruth-score, W47.item-fields-more-checks, W47.item-fields-more-score, W47.item-fields-third-score) — A title field in the tagging output, the JSON sidecar and the page-2 header (SPEC/tag-format.md and ArchiveCore together, Tier-2), and the other fields W47.item-fields-truth found reliable; a field below its bar is left empty rather than guessed. W47.ct-zotero then exports them. detail: execution-plans/containers/00-plan.md "Item fields" **Measurement audit (2026-10-30, `execution-plans/processing-review/11-measurement-audit.md`):** FLD-8: waits on W47.item-fields-retruth-score, whose verdict replaces W47.item-fields-truth's; the image-prompt test moved there. **2026-11-05, W47.item-fields-retruth-score** (`ArchiveProcessor/segbench-results/item-fields-score.md`): no field clears the fill rule for any route, by the owner-checked n (15-21 with a true value; kind 38) as much as the precision, so the verdict is "too close", not "leave empty". The image prompt (the item prompt on the page images) is the only Gemini route that gives a title; the app's call is below the bar on publication date. Waits on W47.item-fields-more-checks for the verdict it fills by. Inference (names from first names or initials, a paper from its initials) is a user-set level here (the owner's sheet notes). **2026-11-06, W47.item-fields-third-score:** with all three sheets folded the image prompt fills kind, byline, publication, publication date and recipient place by the rule; title stays too close (53/56 on the draw, stratified 0.91 [0.83, 0.94]; about 13 more right drawn pairs would fill it; its misses: a kicker line taken into the headline, a title run over two pages), so the build leaves title below the bar unless a further draw or a prompt fix for those two misses clears it. — **Measurement review pass 12 (2026-11-11, P12-2 and P12-3, `execution-plans/processing-review/measure-reviews/2026-11-11.md`):** the third sheet was sized from the second's result, so the pooled verdict is a sequential one under a fixed-n bound (a route at 0.88 fills 4% of the time on one look, 12% on two, 17% on three): a further title draw, if any, is one look sized in advance, the last, and reported as the third on these pairs; a prompt change for the kicker-line and two-page-title misses is judged on a fresh seeded draw, never on the drawn misses; kind fills by one reading's margin (36 of 38 would give 0.83), which the build's notes say. The publication date is the printed issue date: shown and exported apart from the document's date tag and never written over it (the owner's sheet value and his tag differ on 7 of 85 tagged pieces, 5 by year; W47.ct-zotero takes `issued` from the date tag).
- [ ] **`W47.ct-zotero` — the container in Notes source blocks, and the export to Zotero with all gathered metadata [M]** (lane: notes,reader) (uses: build) (blocked-on: W47.ct-infer) — Notes source blocks show the archival location. "Copy for Zotero" from a Notes source and "Export to Zotero" from a Reader selection write CSL-JSON carrying everything gathered for the item, not only its location (owner, 2026-10-21): the container fields (archive, archive-place, archive_collection, call-number, archive_location; accession and series in Extra) and the item fields the Processor already extracts (SPEC page-2 header, the JSON sidecar, the date tags): title, date (issued, with uncertainty), author, recipient, type mapped to a Zotero type (letter, newspaper or magazine article, memo or report as document or manuscript, telegram, photograph, clipping), place (author and recipient locations; the item's place where the Zotero type has one, otherwise Extra), publication name (container-title), and subjects as tags. A field the type cannot hold goes in Extra rather than being dropped; nothing invented for an empty field. Items from a corpus that predates the apps carry only what their tags and folders give. CSL-JSON file import is the route; Zotero's local API only where Zotero 10+ is present. Tested by importing the export into a scratch Zotero library and reading the fields back. Formats no citations. detail: execution-plans/containers/00-plan.md **Measurement audit (2026-10-30, `execution-plans/processing-review/11-measurement-audit.md`):** FLD-6: `issued` comes from the owner's or the app's date, not the item-field publication date.
- [ ] **`W47.gateway-key-rewrites` — find what keeps modifying the Gateway Keychain item [S]** (lane: suite) (uses: light) — 2026-11-12 walkthrough: the item (com.archiveprocessor.app / Gateway) was modified at 17:56 and again at 22:27 on 2026-11-12, each time resetting its partition list so /usr/bin/security prompts and gateway bench arms stop; the last repair (keychain-partition-fixed) is 2026-10-31. Find the writer (a Processor build or UI test re-saving the key, a test driver, a script) by reading code and logs, never by reading the secret; stop it rewriting an unchanged key, or report why it must. Do not run fix-keychain-access.sh: it needs the owner's password.

## Archive Processor — automatic segmentation (owner, 2026-10-05; before the W40 freeze)

The owner's original goal for the project, last tried in spring 2026 with a per-page method that "never got near
usability". Plan: `execution-plans/segmentation/00-plan.md` (Part 1 for the owner, Part 2 the detail). A bake-off
on the owner's five ground-truth boxes, scored by the share of pages that land in an exactly right document, then
the owner's decision, then a build only if the result is usable. The Processor ledger and journeys
(`W40.b3`, `W40.d1`-`d4`) wait on `W36.seg-decision`; `W40.a1` no longer does (2026-10-07). Items marked
OWNER sit in the plan's HOLD QUEUE.


The build, from `04-options-build.md` Part 2, has shipped: every `W36.seg-opt-*` item is in `SUITE_TODO_DONE.md`.

## Archive Processor — transcription and segmentation bake-off on OpenRouter (owner, 2026-10-11)

A socOCRbench-style bake-off on our own documents. No transcription bake-off has ever been run for Archive Processor,
and segmentation's local runs stopped at 12B. The owner's three questions, which W41.report must answer in plain terms:
1. **Users with more memory.** What the app should offer users whose Macs have more memory than ours (which local
   models, at what quantisation, for which kinds of page, at what speed), for 18, 32, 48 and 64 GB. Not a question
   about buying a Mac for this project (owner, 2026-10-11: set aside).
2. **The paid hierarchy.** For typical US archival documents, the recommended order of paid models, and whether it
   changes by kind of page: printed, typewritten, handwritten, mixed; period; forms and tables; the quality and
   resolution of the photograph; the size of the original.
3. **Segmentation.** The best approach, and whether cheaper models than Gemini or Claude segment well enough.
4. **The bulk route on FarmShare.** The owner holds more than 100,000 archival photos and about as many scanned
   newspaper pages, so paying per page, or spending a subscription on them, is a real cost. FarmShare (Stanford's
   free shared Linux cluster for coursework and unsponsored research; GPU nodes with four NVIDIA L40S each, 48 GB per
   card) could run open-weight models on all of it for nothing. Which model is best there, at the precision
   FarmShare would run it, how many pages an hour it reads, and what the whole corpus would take, set beside the
   cost per 1,000 pages of the best paid route and of the subscription route.

The API is OpenRouter: one key, Keychain service `com.archiveprocessor.app`, account `OpenRouter` (added by the owner
2026-10-11); it reaches the open-weight models and the cloud leaders alike (prices checked 2026-10-11 on
openrouter.ai/api/v1/models). Zero Data Retention is OFF by the owner's choice (2026-10-11: the images are not secret), so every listed model is reachable. OpenRouter routes each call to one of several providers, which serve open models at different precisions (bf16, fp8, fp4): pin one provider per model for a whole run and record the provider and precision in every row, or two rows of one model are not comparable. Never write to the real corpus: sample pages are COPIED to scratch. Money: each item
states its cost before calling and stops at its cap; the $3 rule (root CLAUDE.md, "Spending money") applies to each
item in total, and any item whose measured estimate passes it asks the owner first.

- [ ] **`W41.app-local-seg-publish` — publish the corpus-trained 2B's weights to Hugging Face — OWNER action [XS · ~0.1 session]** (lane: processor) (uses: light) (blocked-on: W41.app-local-seg-publish-owner-ok, W46.review-done). From W41.app-local-seg (shipped): the app's `local` approach downloads `charlesapetersen/archive-suite-seg-qwen3.5-2b-8bit` by default (`LocalSegmenter.defaultModelID`), and until that repository exists a run stops at its warm-up with the server's reason. Publishing was approved on 2026-10-17; it needs the owner's Hugging Face account. The owner runs `ArchiveProcessor/scripts/segbench/publish-seg-model/publish.sh [repo]` signed in (`hf auth login`); the model card is that folder's README.md. If the repository name differs, a session then changes `LocalSegmenter.defaultModelID` (and the script's default) to match. **Owner walkthrough, 2026-10-18:** keep `charlesapetersen/archive-suite-seg-qwen3.5-2b-8bit`; the name is settled. Upload remains an owner action and the publication gate stays open until the weights are uploaded. **Measurement audit (2026-10-30, `execution-plans/processing-review/11-measurement-audit.md`):** SEG-5: the model card does not quote the 97.6% held-out agreement as accuracy; quote the test-box and Sasha figures.
## Reader ↔ Processor — flag poor OCR and read it again with a better reader (owner, 2026-10-16)

The owner wants a reader of the archive to be able to say "this file's transcription is not good enough" and get it
read again by a better model, picked from a ranked list. The ranking depends on the kind of document, and it changes if
the user corrects the kind, for example from typewritten to handwritten. He called it an important integration between
the two apps, outlined the features, and left the design to us.

All four items shipped (W44.reocr-plan, -spec, -processor, -reader; `SUITE_TODO_DONE.md`); the contract and its design
record are `SPEC/improve-ocr.md`. One follow-up remains:


## Archive Processor — a broader benchmark corpus and the pre-release model sweep (owner, 2026-10-16)

The owner asked for two things. The first is a model sweep and more benchmarking near the end of the queue, so
that the models the app recommends are current at release. The second is a rethought benchmark corpus with more
documents, more kinds of document, more periods and more scripts, not only his own boxes. The app is built for other
researchers, and their documents will not look like his. The 96 adjudicated truth pages are all from his US archival
photographs. ArchiveOCRBench's model choices have come from the owner's four bake-off questions, not from any
leaderboard.

**What an interactive session found on 2026-10-16.** It checked the open-model chart at
`dashboard.interconnects.ai/extra#aa-open-models`, which is the Artificial Analysis Intelligence Index snapshot of
2026-10-15 with 27 models. Only two of them have been run here. Qwen3.8 27B ran on FarmShare and scored 93.10 NES,
against 95.25 for Qwen3.6 27B. GLM-5.3 Flash has been measured for segmentation only, and its OCR has never been
measured. Fourteen of the 27 take images on OpenRouter, eleven are text-only and cannot read a page, and two are not
on OpenRouter (Qwen3.8-Flash-Next and Nex-N2-Pro). That index measures text reasoning, so it is the wrong screen for
OCR. socOCRbench (`noahdasanaike.github.io/posts/sococrbench.html`, last updated 2026-07-31) is closer to our
material, but it ranks Qwen3.6 27B near its bottom (about 0.44 NES), while that model is our best open reader. An
outside table can suggest candidates, but only our own pilot can rank them.

**Order.** The corpus comes first and can start now, because research, licences and any owner adjudication take the
longest, and the sweep needs the corpus. The sweep runs last, after the integration of Vision OCR's engine and the
segmentation work, so that it sees the newest releases. It still runs before the release candidate, because its
results change the app's catalogue and model guide, and `W40.h2` has to verify that code at HEAD. `W40.h2` therefore
waits on `W43.app-guide-refresh`.

## Vision OCR's engine — newspaper rows fused across columns, moved from Vision OCR (owner, 2026-10-16)

The owner called Vision OCR's queue done on 2026-10-16 and moved its last open item here, to be worked on the engine
after it moves into this repository (`execution-plans/integration/00-plan.md`, Stage 1). Its full record, with the
measurements and what was tried, stays in `~/Claude/vision-ocr`: `ops/autonomous/QUEUE.md` (entry
`c41-newspaper-scans`) and `BUGS.md` C41 and C39. The files it names under `$STATE` are in
`~/.local/state/visionocr-autonomous/`.

**The integration stages, filed by Phase 4 (2026-11-06).** `execution-plans/integration/00-plan.md` (approved 2026-10-14)
is built as the items below: stages 1, 2, 3, 5 and 7 as the plan writes them, with the rules Phase 4 decided folded
into stages 3 and 5; stages 4 and 6 are replaced by §"The settings layer — W46.settings (owner, 2026-11-04; filed by Phase 4, 2026-11-06)". `W42.int-done` (the plan's HOLD QUEUE dependency
marker for the Processor's W40 items) now waits on `W42.int-s7`.


- [ ] **`W42.int-s5-compress` — Vision OCR's compression in the searchable form, kept through PDF/A, and its control [M · Tier-2]** (lane: processor) (uses: build) — Split from W42.int-s5-searchable (shipped 2026-11-13: the searchable form, its header in the XMP, merges of both forms, the Reader's pairing by role). The form embeds the same JPEG as image-plus-text: 2,090 / 2,168 / 2,085 KB a UIUC page (00149, 00156, 00233) against Vision OCR 1.16.0's 522 / 868 / 101 KB, the memo 128 / 16 KB. Vision OCR's size comes from a path with no Quartz in it (`OCRModel.makeSearchablePDF`, VisionOCRKit Model.swift ~1819-2900): `Flattener` rebuilds the page as JBIG2 or MRC layers, `JBIG2.assemble` hand-writes the image PDF, `SearchableWriter.compose(drawImages: false)` the text layer, `qpdf --overlay` merges them; it needs the `jbig2` and `qpdf` binaries (`Runner.locateTool`; Homebrew jbig2enc 0.32 and qpdf 12.3.2 on this Mac). Every app writer redraws through Quartz (`PDFGenerator.writeArchival`, merges, the date-evidence rewrite), which re-encodes JBIG2 (VisionOCRKit JBIG2.swift:452: 374 KB to 467 KB). Needs: a public VisionOCRKit entry that compresses one page with the app's own lines (no recognition of its own); a PDF/A-2b finish that does not redraw (the XMP with `pdfaid` and the header list, the sRGB output intent, the trailer ID), and merges and the date-evidence rewrite through qpdf, not Quartz; the uncompressed form, named in the run log, where the binaries are missing, and how the app ships or finds them (both Apache-2.0); then a control for `searchableFor` on the settings sheet's rules tab, which has none (ArchiveProcessor/KNOWN_ISSUES.md §W42.int-s5-searchable). Done when `scripts/measure-output.sh` gives searchable outputs near Vision OCR's sizes, read back through PDFKit and Core with their headers, merges included, PDF/A-2b by veraPDF.

- [ ] **`W42.int-s5-hands-publish` — publish the hand placer's download [XS · owner]** (lane: processor) (needs: owner) — Filed by W42.int-s5-hands, 2026-11-13. The app pins `hands.tgz` (286,946,670 B, sha256 `f835149bf6f4921b28becd063953b538004f6e1247a38e3ad8e7343289dc1470`; `packages/VisionOCRKit/ops/make-hands-runtime.sh`) at `https://github.com/charlesapetersen/vision-ocr/releases/download/models-1/`; the built file is `~/.local/state/archive-autonomous/model-files/hands-build/hands.tgz` (do not rebuild: tar keeps mtimes, so a new build has another hash). An engine session may not run `gh release`. Owner: `/opt/homebrew/bin/gh release upload models-1 ~/.local/state/archive-autonomous/model-files/hands-build/hands.tgz --repo charlesapetersen/vision-ocr`. Done when "Download the handwriting placer" on the settings sheet installs it (ArchiveProcessor/KNOWN_ISSUES.md §W42.int-s5-hands).

- [ ] **`W42.int-s7` — retire Vision OCR's app [S]** (lane: suite) (uses: build) (blocked-on: W42.int-s5, W42.int-s5-searchable, W42.int-s5-compress, W46.settings-sheet) — Stage 7: Vision OCR's last owner-only release shows the notice and the link, its updater stops offering versions, and the Processor reads the settings that have an equivalent at first launch. The owner cuts the release.

- [ ] **`W42.c41-newspaper-scans` — cut a Vision line where it crosses two layout regions, on whole-page newspaper scans [M · 1-2 sessions]** (lane: processor) (uses: build) (blocked-on: W42.int-s1, W46.review-done). On the five small-town newspaper scans C41 names, Vision reads some rows straight across two columns, and the accurate mode leaves them, because each model's region words are aligned onto Vision's lines (at least 30 fused rows over the five pages with the mode off, 34 with Falcon-OCR and with PaddleOCR-VL; `C41-FUSED-ACCURATE-2026-10-14.tsv`). The work is to cut a Vision line where it crosses two DocLayout-YOLO regions before alignment (the owner kept DocLayout-YOLO on 2026-10-16, after layout-compare). Judge it with the mode on (`count-fused-rows` oneRun to 0, or each row left named with what was tried), with the mode off as a regression floor, and with the five pages' `+accurate` rows in the regression set no worse. Misreads with the mode on are the model's, not this item's. A Codex attempt at local gutter search is parked as `$STATE/rescue/PARKED-c41-local-gutters-2026-10-14.patch`, not reviewed to the end. Done when, on the published PDF through PDFKit, for each of the five pages before and after: fused rows counted, and misread words and dictionary words in the paragraph C39's table used; ordinary pages across a corpus sample unchanged; a new check goes red without the change. Drag selection is not in scope (C39 closed it). Starts once Stage 1 has the engine building as a package here; `W42.int-s1` is that stage's item, filed with the other stage items.

- [ ] **`W42.stroke-weight-photographed` — type comes out heavier than the scan on photographed pages the flattener layers [M · 1 session]** (lane: processor) (uses: build) (blocked-on: W42.int-s1, W46.review-done). Owner, 2026-10-28. On Vision OCR 1.16.0 with the default settings, the owner's 733 phone photos of the Scott papers (`~/Desktop/Google Drive/Archival Photos JPEGS/Northwestern`, output in `~/Desktop/Scott new OCR`) come out with type visibly thicker and blotchier than the photo. Those pages publish as a JBIG2 stencil at the photo's full size (4080x3072) filled from a colour layer at a quarter of that, over a half-size background. Measured on `0011 — Scott` (a newspaper page; the caption under the photographs): the share of dark pixels is 0.151 in the photo, 0.215 in the published page (1.42x), and 0.140 with "Make text pages smaller" off, which publishes one full-size JPEG and no stencil. C56 (Vision OCR `BUGS.md`, fixed 2026-10-14) fixed the same symptom on 1-bit and re-gridded pages; this is the camera-photo route it did not cover. Interim, until this is done: the owner turns that setting off, at about 3x the bytes (`0001` 326 KB to 994 KB, `0011` 1.32 MB to 4.42 MB, image only). Done when, on the published PDF, ink share on a sample of these pages is within the band C56 set for the routes it fixed, file sizes are reported before and after, ordinary pages across a corpus sample are unchanged, and a new check goes red without the change. If the stencil cannot be brought to the scan's weight on this route, the alternative is to route camera photos to the plain JPEG and say what that costs. Worked on the engine once Stage 1 has it building as a package here; Archive Processor's settings will need the same choice when its output path takes the searchable-PDF writer (Stage 5).

## Autonomous daemon — use both subscriptions (owner, 2026-10-04)

Owner, 2026-10-05: one session at a time leaves the Claude five-hour window unused, because sessions spend most
of their time in builds, tests and the VM; "the point of running multiple sessions would be to actually use the
full usage window". Made the daemon's next work, ahead of everything else in the queue. Replaces the single
W35.lanes item of 2026-10-04. Research (worktrees, lock-file claims, pace-aware slot sizing, per-lane pauses,
staggered starts, the subscription policy) and the design are in the plan.

**Efficiency plan, rounds 3-4 (queued 2026-10-07).** Owner, 2026-10-07: lock less, and make more independent
items that several workers can run at once. Plan and evidence: `~/Claude/Agent Manager/EFFICIENCY-PLAN.md` and
the three `analysis/*-2026-10-07.md` files beside it. Rounds 1-2 are built. These entries are its Archive Suite
round 3 items 12 and 14 and round 4 item 17; item 16 (the W40 edges) is done, item 15 (resource pools) belongs
to the Agent Manager, and the W9.e2 and W24.cal1 splits are filed under their own sections.

- [ ] **`W35.warm-dd` — a stable worktree path per worker, re-pointed each session, so DerivedData stays warm [M · ~1-2 sessions]** (lane: ops,docs) (uses: build) (blocked-on: W35.warm-dd-measure)
  Efficiency plan item 14, second half. Measured worth building (2026-10-08: the moved-tree build saves 86-93% of
  cold, `execution-plans/parallel-workers/warm-dd-measure.md`). Each worker keeps one worktree at a fixed absolute path outside the
  primary; housekeeping keeps it instead of removing it; at session start it is moved to a fresh branch off
  origin/main only when it is clean and fully published, and otherwise preserved while the session falls back
  to a fresh path. Claims register it exactly as today. Never symlink build directories into a worktree (the
  433 MB loss: `git add -A` staged the scaffolding and a merge overwrote the real directories); DerivedData
  stays `./build/DD` inside the stable tree (gitignored) or an absolute path outside every tree. Two workers
  never share one DerivedData (concurrent builds lock its build database), and the gate keeps its own
  DerivedData as the clean-build authority, so a stale product cannot turn a gate green.
  DONE WHEN `prove-housekeeping.sh` and `prove-worker-claims.sh` show the stable tree surviving housekeeping,
  moving cleanly, and a dirty or unpublished tree preserved; the README states the path; the warm figure is
  re-measured once and added to the measure table; the entry notes it takes effect at the next owner restart. |
  ops/autonomous/ + execution-plans/parallel-workers/warm-dd-measure.md | M | med | none
## W40 — verification phase: prove the Suite works (owner-approved 2026-10-04)

The next work once the build queue above is exhausted. Plans: `execution-plans/verification-phase/00-owner-plan.md`
(the owner's version, with the open decisions) and `01-daemon-plan.md` (method, phase rules and item detail).
Order lives in the plan's `### TIER 7` block. The owner approved it on 2026-10-04 (the three owner gates are in `SUITE_TODO_DONE.md` §W40), so
`W40.a1` waits only on the owner's approval and the gate-relevant items (see the note below). Items marked OWNER sit in the plan's HOLD QUEUE and are
never auto-picked; an `-owner-ok` line ticked `DECLINED` sends its dependant to the fallback in rule 11 of the
daemon plan. Reproduced bugs this phase finds are filed here as `W40.fix-<slug>` with a severity (rule 8).

**Archive Processor's items wait for the integration (owner, 2026-10-14).** Vision OCR's engine is to be brought into
Archive Processor (plan: `execution-plans/integration/00-plan.md`), so Archive Processor is verified once, on the
integrated app. Its items (a5, b3, b4, d1-d5, e8, e12, g3, i1-i5) are `(blocked-on: W42.int-done)`, a HOLD QUEUE gate
ticked when the integration is built. Reader, Notes and the suite-wide checks carry on. Knock-on waits through their
existing edges: b5 (on b3), d11 and e4 (on d1), and h2. c1 is not held, because Notes' d9 needs it. The suite-wide
checks that run now (e1-e3, e5-e7, e13) also cover today's Archive Processor; its part of them is re-run at h2.

**Order loosened 2026-10-07 (owner: "Start the independent parts now").** The edges that encoded the feature
freeze rather than a real order are gone: `W40.a1` no longer waits on `W36.seg-decision`, `W24.cal1`,
`W22.mixed-batch-fu2` or `W12.dedup-fu1`; `W40.b0`, `d6`, `e5`, `f1` and `f2` wait on nothing; `e1`, `e6` and `e7` wait
on `a1` rather than `a3`. The freeze is now per area: only an app's ledger and journeys wait for that app's
unfinished features — Processor `b3` and `d1`-`d4` on `W36.seg-decision`, the Reader and Notes ledgers `b1`/`b2` on
`W24.cal1` (their journeys follow through `b1`/`b2`). Rule 7 of the daemon plan says the same.

- [ ] **`W40.i4` — real-iPhone pass on the owner's phone — OWNER** (lane: processor) (uses: light) (blocked-on: W40.i5, W40.i5-usb). Owner, 2026-10-29: paused before pairing; it waited for the USB route. Pack refreshed by `W40.i5-usb` 2026-10-31 (`verification/sessions/iphone-1.md`: cable first, a command-line install, two parts that may be on different days). Part A run 2026-10-31 (`iphone-1-returned.md`); its fixes shipped 2026-11-01, and the pack was refreshed for Part B on 2026-11-06 (judged time; reinstall the app first). Part B ready to run. Detail: `execution-plans/verification-phase/01-daemon-plan.md` and `00-owner-plan.md` §Decisions.
- [ ] **`W40.d1` — bulk OCR on a ground-truth collection [M]** (blocked-on: W42.int-done, W46.review-done) (lane: processor) (uses: build,vm,paid) (blocked-on: W40.b3, W40.c1, W36.seg-decision). Detail: `execution-plans/verification-phase/01-daemon-plan.md` §D.
- [ ] **`W40.d2` — Processor review dialogs driven by hand [M]** (blocked-on: W42.int-done) (lane: processor) (uses: vm) (blocked-on: W40.d1, W36.seg-decision). Detail: `execution-plans/verification-phase/01-daemon-plan.md` §D.
- [ ] **`W40.d3` — every OCR provider through the app's own client [S-M]** (blocked-on: W42.int-done, W46.review-done) (lane: processor) (uses: build,paid) (blocked-on: W40.b3, W36.seg-decision). Detail: `execution-plans/verification-phase/01-daemon-plan.md` §D.
- [ ] **`W40.d4` — one tiny real batch job per batch provider [S-M]** (blocked-on: W42.int-done, W46.review-done) (lane: processor) (uses: build,paid) (blocked-on: W40.d3, W36.seg-decision). Detail: `execution-plans/verification-phase/01-daemon-plan.md` §D.
- [ ] **`W40.d11` — the shared tag contract across apps [S-M]** (lane: suite) (uses: build,vm) (blocked-on: W40.d1, W40.d8). Detail: `execution-plans/verification-phase/01-daemon-plan.md` §D.
- [ ] **`W40.e4` — never-executed code from coverage [M]** (lane: reader,notes,processor) (uses: build) (blocked-on: W40.d1, W40.d8, W40.d9). Detail: `execution-plans/verification-phase/01-daemon-plan.md` §E.
- [ ] **`W40.g3` — Processor and capture guided-session pack [S]** (blocked-on: W42.int-done, W48.appearance-verify) (lane: processor) (uses: light) (blocked-on: W40.d1, W40.d2, W40.d5, W40.fix-processor-dark-disabled-buttons, W40.fix-processor-start-why, W40.fix-processor-live-emptied-mixed, W40.fix-processor-flagged-page-edges, W40.fix-processor-settings-fields, W40.fix-processor-settings-backend-mismatch). Detail: `execution-plans/verification-phase/01-daemon-plan.md` §G. Judge first whether it is time for the owner's session (§G "Is it time?"); the blockers being ticked is not enough.
- [ ] **`W40.g-sessions` — owner runs the guided sessions — OWNER** (lane: suite) (uses: light) (blocked-on: W40.g1). Detail: `execution-plans/verification-phase/01-daemon-plan.md` and `00-owner-plan.md` §Decisions Before each session is offered, the pack's own item judges whether it is time (§G "Is it time?"); for the Reader that is `W40.g1-refresh`, for Notes `W40.g2`. The first Notes pack, `verification/sessions/notes-1.md` (W40.g2, 2026-11-04), was run and filed on 2026-11-05; the second, `verification/sessions/notes-2.md`, is ready (W40.g2-notes-2, 2026-11-06).

- [ ] **`W40.tag-rename-suite` — rename or merge a tag across the archive and the notes, from any of the apps [M-L · Tier-2]** (lane: suite) (uses: build,vm) — Owner, 2026-11-06 walkthrough: "This is important functionality. Also, tag changes in one app should carry over to the other apps." Today (checked 2026-11-06): the Reader has Rename Tag… (menu and the tag cloud's right-click) and Find Similar Tags…, whose Merge drives the same rename; renaming into an existing tag merges into its spelling; it is one grouped undo through TagWriter (`NavigationModel.renameTag`, `RenameTagSheet`, `SimilarTagsSheet`). It covers only the files in the Reader's library, the tagged files under its granted folder. Notes has no rename or merge: a note's tags live in its front matter, mirrored onto its own `.md` by `NotesTagProjector`, and the Reader never sees or changes them. The Processor has none either (its typed tags take the vocabulary's spelling). So a rename in the Reader leaves the same tag on every note, and nothing renames a tag on notes at all. Wanted: (1) Notes gets Rename Tag… and Merge (with Find Similar Tags), over its notes and extracts, front matter first, then the projection, one undo; (2) a rename or merge in either app reaches the other app's items, so one tag means the same thing across the suite; (3) the Processor's vocabulary follows. Each app is sandboxed to its own folder, so (2) needs a design: for example a rename record in the archive root that the other app applies, after confirming, on its next open, or one app asking for access to the other's store. Design first in execution-plans/tag-rename-suite.md (where the record lives, what happens when an app is closed, undo across apps, a tag the other app spells differently, a read-only folder), then build. Tier-2: a write to every tagged file and note; SPEC/tag-format.md gains the rule; adversarial review and scratch-copy tests in all three apps.
- [ ] **`W40.h2` — re-run every journey at HEAD [M]** (lane: suite) (uses: build,vm) (blocked-on: W40.d1, W40.d2, W40.d3, W40.d4, W40.d5, W40.d6, W40.d7, W40.d8, W40.d9, W40.d10, W40.d11, W40.e1, W40.e2, W40.e3, W40.e4, W40.e5, W40.e6, W40.e7, W40.e9, W40.e10, W40.e11, W40.e12, W40.e13, W40.f1, W40.f2, W43.app-guide-refresh). Detail: `execution-plans/verification-phase/01-daemon-plan.md` §H.
- [ ] **`W40.h3` — release candidate — OWNER (Tier-3)** (lane: suite) (uses: build) (blocked-on: W40.h2). Detail: `execution-plans/verification-phase/01-daemon-plan.md` and `00-owner-plan.md` §Decisions.
- [ ] **`W40.h4` — owner acceptance pass with the ledgers — OWNER** (lane: suite) (uses: light) (blocked-on: W40.h3). Detail: `execution-plans/verification-phase/01-daemon-plan.md` and `00-owner-plan.md` §Decisions.
- [ ] **`W40.token-fix` — the token pass's fix session: read the report, fix what it found, re-arm [M · Tier-2 · standing]** (lane: ops) (uses: light) (blocked-on: W40.token-fix-due) — Standing item, never ticked (W40.token-pass, owner 2026-10-28). The weekly pass (`ops/agent/token-audit.py`, run by the upkeep hook) ticks `W40.token-fix-due` in the plan's `## RECURRING` section when an always-loaded file is over its budget or a session figure is 10% or more worse than the last pass; that makes this item runnable. The session reads `$AGENT_STATE/token-audit/latest.md` and fixes what it can in one session: a guide trimmed by hand, with every rule listed before and after and an adversarial reviewer checking that list (a rule may move but never disappear); prompt steps the engine overrides removed; a noisy script given a summary on stdout and its full output in a log; a hook that dumps a large file narrowed. Anything larger than one session is filed as its own item. It re-measures (`token-audit.py sizes` for the files; the next pass measures the sessions) and records the before and after figures in a dated `W40.token-fix-YYYYMMDD` entry appended to `SUITE_TODO_DONE.md`, in the same commit as the fix; the commit subject names `W40.token-fix` standing alone, e.g. `W40.token-fix (2026-11-05)`, because the engine counts progress only by the bare tag. Then, after the push, `ops/autonomous/plan-edit.sh "/Users/cp1/Claude/Archive Suite/.maintenance/AUTONOMOUS_PLAN.md" rearm W40.token-fix-due '<sha>: <result>'`, which makes this item wait again (the next pass reports a gate left ticked). ⛔ Never `complete` it (plan-edit.py refuses) and never move this entry: the plan and this file both keep it open, which is what keeps check-tracker-sync.sh and check-todo-stubs.sh passing.
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


## Owner ideas — deferred, NOT for the daemon queue (do not start unprompted)
Design-level ideas the owner wants recorded but explicitly de-prioritised. An autonomous session must
**skip** these: they need the owner's scoping before any code is written. They are kept in
[`FUTURE_FEATURES.md`](FUTURE_FEATURES.md) (from 2026-10-11).

### ⛔ DECLINED — settled, do NOT re-raise in Daemon Report
- **`W46.mixed-route-paid` — RETIRED by the owner 2026-11-05, not run:** Gemini 3.7 Flash drafted 20 of the 35 mark texts verbatim, so its marks arm would be scored mostly on its own text (measurement review pass 10, P10-3), and its region and body arms have no truth on these pages. The Sherlock open readers of W46.mixed-route (GLM-OCR, Qwen3.6-27B), which drafted nothing, settle the mixed-page route.
- **`W46.marks-detect-paid` — RETIRED by the owner 2026-11-05, not run:** Gemini 3.7 Flash drafted the owner core's mark boxes, so it cannot be ranked on them (measurement review pass 9, P9-10), and the gateway serves no 3.8. The public detectors' failure is measured (W46.marks-detect: YOLO11m 8-17 of 45), and W46.mixed-route, whose readers drafted nothing, decides the marks route. ⛔ Do not re-file unless the gateway serves a Gemini that is not the drafter's model.
- **`W46.layout-order-train` — RETIRED 2026-11-04, not run:** free ordering arms already reach tau 0.95 on the owner pages (W46.layout-order-marks), so a trained orderer changes no step. ⛔ Do not re-file unless a new material fails the free arms.
- **The twelve nice-to-have items behind `W46.nice-to-have` — RETIRED by the owner 2026-11-04, not run:** "Let's get rid of the items behind the gate." The DocRes arms (`W46.enh-ocr-input-ppocr`, `-marks-docres`), the remaining open readers (`W46.ocr-new-open-rest`, `-gold`), the capture ladder's remainder (`W46.capture-ladder-sherlock`, `-rest`), `W46.truth-jpeg-rest`, `W46.ocr-postcorrect-paid`, `W46.ent-robust-paid`, `W46.seg-context-paid`, `W46.seg-openpss` and `-paid`. Each was measured as changing no pick or default; records in `SUITE_TODO_DONE.md`. ⛔ Do not re-file them as review work. Four others were promoted the same day instead (efae556a).
- **The full re-run of the window method with the owner's cues (`W36.seg-window2`) — SKIPPED by the owner
  2026-10-05:** "Use only the one box so we have one small comparison. Let's skip the larger re-run." The
  one-box comparison replaced it: the cues prompt through Claude Sonnet 5.5, Claude Opus 5.5, Codex
  gpt-6.1-sol (low) and Gemini 3.8 Flash (low) on Deaver all scored 96.5% pages in an exact document, each
  with the same single false split at page 57, which is also window v1's only error there
  (`segbench-results/cues-models-Deaver.md`, `scripts/segbench/method_window_cues.py`). ⛔ Do not queue the
  three-box Claude re-run again.
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


## Archive Reader at corpus size, and the owner's notes of 2026-11-10

The owner used the Reader on the full corpus (about 91,000 PDFs) and sent fifteen points; his instruction was to fix
shared causes, not symptoms. What was read and measured, the causes, and which item answers which point:
`execution-plans/reader-owner-notes-2026-11-10.md` (delete when the last item here ships). In short: every small change
is handled as a whole-library change on the main actor; the view model does whole-corpus work in view bodies; the viewer
rebuilds everything on each file switch; the selection has no anchor or current item; shortcuts and names are written in
several places and drift; the item type is stored as a colour. The Reader's VM UITests pass on macOS 27 since
`W40.vm-macos27-reader` (2026-11-12); Reader items verify with the unit bundle, `ReaderAtSizeTests`, the render guards and
their UITests in the guest. Owner's calls, 2026-11-10: a row that drops out of a smart folder or search leaves at once and the
next row is selected (point 12); the UIUC and Bower pages are tests of the pipeline, and a bulk re-read of the corpus
waits until the pipeline is sorted out (points 6, 9).


## Archive Reader — the owner's notes of 2026-11-13

Owner, 2026-11-13: eight points on the Reader, filed as given. The first is a bug and goes first.

- [ ] **`W40.reader-field-status` — show which bibliographic and container fields the user has checked, and how confident the rest are [M-L · Tier-2]** (lane: reader) (uses: build,vm) (blocked-on: W47.ct-spec) — Owner, 2026-11-13: for bibliographic information (date, sender, format, publication) and for box, folder and archive information, the user needs to see whether each value has been confirmed by the user, and could also see when a value is lower confidence; perhaps red and yellow for unchecked model-supplied values at different confidence levels, and green once the user has checked it. Needs a per-field record of source (model, path, label or user), confidence and checked-by-user, stored beside the value (the JSON sidecar for item fields; W47's run record already carries source and confidence for container fields), so it is a SPEC/tag-format.md change with ArchiveCore and the Reader together. Editing a value in the Inspector marks it checked; a way to mark a value checked without changing it. The signal must not rely on colour alone (a symbol or label as well). Design it with W47.ct-reader-view and W47.ct-reader-edit so the container fields and the item fields show it the same way, and with the settings layer's "every value's source shown". Which confidence figures exist per field, and their cut points, come from the measured results (W47.item-fields-*), not guesses.


## Archive Notes — owner requests (2026-10-28)



## Nice-to-have, end of project — W46 (owner, 2026-10-22)

**2026-11-04:** the owner retired the twelve items that were here (not run; §"⛔ DECLINED") and promoted four into §"Document processing review — W46". The gate stays for new nice-to-have work, as root CLAUDE.md files it.

Work that places the bench against the field or extends a result already settled, rather than changing an app route,
default or recommendation. Every entry waits on `W46.nice-to-have` (the plan's HOLD QUEUE), which the owner opens
once the useful work is done. A Sherlock item judged nice-to-have at its hand-off moves here (root CLAUDE.md,
"Every Sherlock job is reviewed for size and necessity").
- [ ] **`W46.ocr-input-colour-dropout-more` — colour dropout: an owner-checked truth, a stamp cue that tells stamps from coloured print, and dropout for Vision's lines only [M]** (lane: segbench) (uses: light) (blocked-on: W46.nice-to-have) — Filed by W46.ocr-input-colour-dropout (2026-11-11, `ArchiveProcessor/segbench-results/ocr-colour-dropout.md`): on draft truth, dropout ties for Vision on the 40 stamp-class pages (+0.7) and loses for Gemini (-7.2); a probable Vision gain only on the 16 with a real coloured mark (+3.4, -0.1 to +8.4), which the colour cue cannot separate from coloured print (24 of its 40). Three things would settle it: the owner checks the gateway draft on the built sheet (`colour_dropout_sheet.py orient`, then `build`; rerun `ocr_colour_dropout.py images` first if the bench cache dropped the images; `fold` writes the truths the report prefers); a cue (or a Vision-only test) that keeps stamps and drops coloured print; and dropout used for Vision's line geometry only, the reader's text from raw (dropout's lines under the mark hold 7.9 words a line against raw's 5.0). Only if a route then wins on the stamps with no harm on the controls and the 96 does an R02 change go to the owner. Gateway spend so far $1.22 of the item's $2 cap. — **Measurement review pass 13 (2026-11-11, P13-4, `execution-plans/processing-review/measure-reviews/2026-11-11-2.md`):** the 60 pages' draft is Gemini 3.7 Flash itself (medium reasoning, both images), the scored Gemini arm's own model, so Gemini's arms are scored only on the owner-checked truth or on a drafter that is not the scored model; the ungated Gemini arm on the 96 was never read (the report's row copies raw) and is read before any row reports it; the Vision gain on the 16 is judged on the owner's sheet.
- [ ] **`W46.marks-detect-own` — a marks detector fine-tuned on our own pages [M]** (lane: segbench) (uses: light) (cluster: sherlock) (blocked-on: W46.nice-to-have) — **Reopened behind nice-to-have (owner, 2026-11-06 walkthrough)** after measurement review pass 11 (P11-1) found it was retired on a misread run condition: given the mark's own box as a second pass, LightOnOCR-3 4B reads 24 of 35 marks against 16 whole page and GLM-OCR 21 against 13 (W46.marks-two-pass: sign test p = 0.016 and 0.008 against an irrelevant second reading; the whole-page rerun identical on 32 of 32), and today's public YOLO11m boxes buy only 0-3, so a trained detector is the route to the gain. Plan as before: fine-tune the public YOLO11m (`$AGENT_STATE/artifacts/marks-detect-20261104/runs/public/best.pt`, kept for this item) on the 110 non-core marks-set pages with labels from the two drafters' box-matched agreement, saying first how many marks both missed; Sherlock size-and-necessity review before packing. Retired entry and its figures: SUITE_TODO_DONE.md, W46.marks-detect-own; results `ArchiveProcessor/segbench-results/marks-detect.md`, `mixed-route.md` "Two passes".

- [ ] **`W46.eval-new-models` — evaluate new document-reading models as they appear, starting with Inkling 2 Small [S per model]** (lane: segbench) (uses: light) (blocked-on: W46.nice-to-have) — Owner, 2026-11-06: "evaluate new models such as https://thinkingmachines.ai/news/inkling-2-small/". A standing item: when the gate opens, take the new open or gateway models that read page images and run each on both OCR sets (the owner's 96 truth pages and the 895 public pages, same settings, root CLAUDE.md "Both OCR sets, every time"), with a measurement card and ArchiveOCRBench updated. Add a candidate to this entry when one is noticed, with what it would take to run. Candidates: **Inkling 2 Small** (Thinking Machines, 2026-11-05): mixture-of-experts, 594B total and 17B active, with a 292M vision encoder; OCR is named as a strength, but no OCR benchmark is published (GDP.pdf 25.2%, CharXiv RQ 85.6%). Weights are closed for now and served only through Tinker, which is paid and falls under the paid-benchmarking hold (`W43.sweep`) and the $7 rule. Apache 2.0 weights are promised after safety testing; at that size the route is Sherlock (`(cluster: sherlock)` then), not the Mac. The first Inkling Small was tried on FarmShare through a llama.cpp GGUF build (`W43.inkling-farmshare`, DONE): pilot only, parked by the owner on 2026-10-20 with no score; read `execution-plans/inkling-farmshare-20261019.md` before planning a run.

- [ ] **`W46.gateway-google-models` — request newer Google models on the Stanford gateway and try them [S]** (lane: segbench) (uses: light,paid) (blocked-on: W46.nice-to-have) — Owner, walkthrough 2026-11-13: the gateway replaces the Processor's direct Gemini key for all bench and review work (the key's AI Studio prepay is empty and will not be topped up). At nice-to-have: draft the access request for the newer Gemini models the gateway lacks (the owner sends it), then try each one the gateway serves on the rows the direct-key items would have measured (W46.date-route-pipeline-38's dating image pass, W46.seg-tabme-a04's A04 cell, the rotation set's Gemini arm), priced under the $7 rule.

**Filed by Phase 4 of the processing review (2026-11-06):** confirmations and extensions the rule notes asked for that change no route or default today; each names the note that raised it in `execution-plans/processing-review/13-stage-rules/`.

- [ ] **`W46.seg-adapt-second-material` — the LoRA continuation on a second material [M]** (lane: segbench) (uses: light) (blocked-on: W46.nice-to-have) (cluster: sherlock) — A material unlike Lincoln (an owner box pair), a second seed and internal-start truth; tests the start-recall rule and the "one material" label the owner accepted on 2026-11-06.

- [ ] **`W46.seg-enclosure-truth` — the cover-to-enclosure truth, classes A to D [M]** (lane: segbench) (uses: light) (blocked-on: W46.nice-to-have) — So enclosure handling is scored rather than inferred from two gaps (`10-gap-audit.md`, segmentation paragraph).

- [ ] **`W46.seg-mac-8gb` — the 2B beside the app on an 8 GB Mac [S]** (lane: segbench) (uses: light,machine) (blocked-on: W46.nice-to-have) — Whether the local segmenter fits an 8 GB Mac with the app running; the sheet shows `manual` there until measured.

- [ ] **`W46.ocr-mac-27b` — a 27B-class reader on a 32 and 64 GB Mac [S]** (lane: segbench) (uses: light,machine) (blocked-on: W46.nice-to-have) — Qwen3.6 27B 4-bit (8-bit at 64 GB) on the 96, both sets, with peak memory and seconds a page, for reading, the dating image pass and trace prompt, and the entity prompt; fills the upper Mac tiers, which pick from the 16 GB rows until then. Needs hardware the lab lacks (gap audit open question 4; the owner's 32 GB Mac only if necessary).

- [ ] **`W46.layout-by-reader-size` — whole page against regions by reader size and kind [S]** (lane: segbench) (uses: light,paid) (blocked-on: W46.nice-to-have) — E-layout test 3 on the 96 and L1, L3, L4, order-free scoring (about $0.40 paid arm); settles clippings and periodicals, which read whole today.

- [ ] **`W46.layout-photo-newspapers` — the staged route on photographed newspapers [S]** (lane: segbench) (uses: light) (blocked-on: W46.nice-to-have) — E-layout test 8: the quad correction then PP-DocLayoutV3 on photographed newspaper pages, for the quad rule.

- [ ] **`W46.place-print-pp-lines` — the writer over PP-OCRv6 det lines on typed pages [M]** (lane: segbench) (uses: light,machine) (blocked-on: W46.nice-to-have) — A row beside Vision's lines on the 40 typed pages, folded and unfolded, and the largest image side at which PP-OCRv6 det fits 16 GB.

- [ ] **`W40.reader-prose-more` — more research and work to improve Copy Cleaned for Prose [M]** (lane: reader) (uses: build,model:4) (blocked-on: W46.nice-to-have) — Owner, 2026-11-12: "queue for the nice-to-have stage more research and work to improve Copy for Clean Prose". Start from W40.reader-prose-model's report (`ArchiveReader/scripts/prose-model/README.md`), whose truth was two open drafters' agreement on page 1 of 39 typed pages, which the owner did not check. Against it the rules find 6 of 20 headings and 8 of 16 list items, and their paragraph breaks have precision 0.47 (they split where both drafters see a continuation). The work: (1) a stronger truth for the structure labels (more pages, later pages, multi-column and handwritten-OCR pages, the disputed rows ruled through the gateway or by an owner sheet under the owner-sheet rules; never by Claude subagents); (2) the rules' own failures against it, fixed where a fix holds on a held-out split and passes the word guard; (3) the model routes the report's Scope left open, each only if it can beat the tuned rules: a Foundation Models adapter trained for the labels, a newer OS model, a small open model on the Mac. Every change keeps the word guard and the rules' instant copy; a model pass, if one wins, runs in the background and falls back to the rules. Report with a measurement card; the ArchiveReader/POTENTIAL_FEATURES.md reopen line moves here.


- [ ] **`W46.vision-27-rereads` — the enhancement, dewarp and dating Vision arms re-read on macOS 27.2 [S]** (lane: segbench) (uses: light,machine) (blocked-on: W46.nice-to-have) — So their cards lose the macOS 26.6 label (P8-1, P7-3); the within-OS deltas stand, the levels do not compare with 27.2.

- [ ] **`W46.rotation-direct-keys` — direct-key rotation models on the held-out pages [S]** (lane: segbench) (uses: light,paid) (blocked-on: W46.nice-to-have) — Owner, walkthrough 2026-11-13: the gemini-2.5-flash-lite arm is dropped (no direct Gemini key; W46.gateway-google-models). gpt-5.4-mini and claude-sonnet-4-6 on the 864 turns and the held-out 476; priced and asked under the $7 rule first (P9-3: no app route runs the model the cloud rotation figures measured).

- [ ] **`W46.enh-small-reader-power` — an OCR-input enhancement test with power for the small readers [S]** (lane: segbench) (uses: light) (blocked-on: W46.nice-to-have) — The minimum detectable paired effect for Qwen3-VL 8B, GLM-OCR and PP-OCRv6 from `enh-ocr-input-pages.csv` (ENH-3: about 5 NES today), then the arms most likely to help on enough pages to exclude it; the pages Vision reads as empty and the glare lead (6 pages) folded in.

- [ ] **`W46.marks-truth-independent` — an independent marks truth and a boxes test [M]** (lane: segbench) (uses: light) (blocked-on: W46.nice-to-have, W46.marks-sampling-support) — A second owner draw of pages the pre-flag did not choose (MRK-1), the 8 excluded core pages resolved, and a test of a VLM that returns boxes with its text against the owner's mark boxes; any detector ranking waits on it.

- [ ] **`W46.capture-warning` — a capture warning calibrated on real captures [M]** (lane: segbench) (uses: light) (blocked-on: W46.nice-to-have) — Real phone captures with known truth (L-capture test 10, about 40 minutes of the owner's time, or SmartDoc-QA), sharpness in Vision word boxes with a held-out cut; intermediate ladder rungs for a pixel floor and the framing check (quad against raw; 20 capture tags spot-checked) folded in. Gates any live warning in the companions.

- [ ] **`W46.kinds-mixed-truth` — a body-text truth on mixed pages, and the document prior [M]** (lane: segbench) (uses: light) (blocked-on: W46.nice-to-have) — A body-text score on mixed pages drawn at random under the owner's cut, not by a pre-flag (an owner sheet); and whether a document prior fixes any of the 16 under-floor minority pages.

- [ ] **`W46.ocr-churro-overlap` — CHURRO-DS overlap with the public set [XS]** (lane: segbench) (uses: light) (blocked-on: W46.nice-to-have) — Page-level image-hash overlap between CHURRO-DS's test pages and the 895 (OCR-15); the Gemini and Churro public rows carry the count.
