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

- [ ] **`W46.measure-review` — the standing measurement review: read the new results, refute-check, rework the queue, re-arm [M · standing]** (lane: segbench) (uses: light) (effort: xhigh) (blocked-on: W46.measure-review-due) — Owner, 2026-10-30: after W47.item-fields-truth scored the app against a weak model-built truth, a standing review on the strongest model. The Agent Manager registry sets the lead model for each agent. Standing, never ticked. ops/agent/measure-review.py (the upkeep hook) ticks W46.measure-review-due in ## RECURRING after 12 items finish with a result, not counting the review's own corrections (owner, 2026-11-11; it was 8 items from 2026-11-04, and 8 result commits or a week with one before that); the session follows ops/autonomous/README.md §"The measurement review" (status and cards, the six flaw classes, an independent refute-check, a dated note under execution-plans/processing-review/measure-reviews/, the queue reworked through plan-edit.sh with SUITE_TODO in step, owner sheets as gates, retirements and nice-to-have moves asked in the Daemon Report), then measure-review.py done <sha> and plan-edit.sh rearm W46.measure-review-due. Why: execution-plans/processing-review/11-measurement-audit.md.
  Latest pass: 2026-11-22 pass 18, `execution-plans/processing-review/measure-reviews/2026-11-22.md`, through dbb10584. Independent GPT-6.2 Astra review of twelve results, $0. Six follow-ups cover newspaper warning counts, local field precision and sampling, attempted-page pricing, Advanced reader comparisons, mixed-page routing, and detector/vendor wording. Both newspaper app items carry the corrected comparison as a prerequisite.








- [ ] **W46.ocr-family-coverage — readers from families never measured, on both sets [M]** (lane: segbench) (uses: light) (cluster: sherlock) — Owner review of the pipeline doc, 2026-11-17: stop same-family comparisons and measure what is significantly different: DeepSeek-OCR-2, olmOCR-2, MinerU2.5, dots.ocr and Chandra-2 (licence now allowed), plus CHURRO on the strata it skipped. Pilot first and size the Sherlock job per the review rule; also run table-cell reading on forms L4 beyond its 3-page pilot (split into W46.ocr-cells-l4-more: it needs new truth first). Progress and the size review: `execution-plans/items/W46.ocr-family-coverage.md`.

- [ ] **W46.ocr-gemma3-12b — Benchmark Gemma 3 12B for full-page OCR on the Mac [M]** (lane: segbench) (uses: light,machine) — Owner, 2026-11-24, regular queue before Nice to Have. Test the pinned 4-bit MLX build used by Processor for box and folder labels, using the page-transcription prompt and frozen images from the OCR benchmark. Run locally for $0 on the owner's 96 archival pages and the 895 public pages, with the same settings for both sets. Pilot under the shared heavy-work lock, then save results per page so both runs can resume. Report transcription accuracy including failed pages, completion, seconds per page and peak memory. Compare on matched pages with existing Apple Vision and local OCR results where available, including by page kind. Record the build and settings, add the measurement card and update ArchiveOCRBench. Use the results to assess whether Gemma is a candidate for the app's on-computer page OCR.

- [ ] **W46.ocr-cells-l4-more — more forms-L4 pages with cell truth, then the cell reading beyond the 3-page bank [M]** (lane: segbench) (uses: light,paid) (cluster: sherlock) (blocked-on: W50.v2-release) — Split from W46.ocr-family-coverage, 2026-11-17. The only L4 cell truth is the frozen bank's 3 register pages (27 fields; whole 17, table 20, cell 12 of 27, `segbench-results/bench-corpus/regions-cells-20261025.md`). Draw about 20 more L4 ledger/form pages from the 895 at random, draft per-cell truth through the gateway with two readers not under test (2026-10-30: no session reads pages as data), owner rules the disagreements on a sheet built to the 2026-11-05 sheet rules (size his time first), freeze a second bank with `regions_cells.py` (relax its one-capability-page check), then read whole/table/cell on Sherlock with Qwen3.6 27B and, if W46.ocr-family-coverage is scored by then, its best reader. The $7 rule applies to the drafting. Progress: `execution-plans/items/W46.ocr-cells-l4-more.md`. **Behind nice-to-have (owner, 2026-11-18); moved to 2.0 (`W50.v2-release`, owner, 2026-11-24):** the cell sheet was declined, not answered; the owner does not know the forms material well enough to rule it. Drafts ($0.27) and the sheet stay in the bench cache and ~/Downloads/cells-l4-sheet-20261118/.



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





- [ ] **W46.seg-check-context-time — Time the wider flagged-boundary sheet with the owner [S · Tier-2]** (lane: processor) (uses: build) (blocked-on: W46.seg-check-context, W46.seg-check-context-time-owner-ok) — Owner timing session, after the context strip ships. The existing 3.2 s/gap (92 gaps) was measured on the two-page sheet and is not a measurement of this wider view. Run `ArchiveProcessor/scripts/time-flagged-checks.sh` interactively at the owner's normal pace ($0, cached images, no model or key); it rebuilds a pair-only pack with up to three images either side and orientations, retains old logs, and prints the gate-approval command when Done. The owner answers the gaps and adds notes; after he approves the gate with the run path, the engine scores the new log, states practice/repeated-material limits, records the new result and adjusts `SettingsSolver.checkSeconds` only to the measured figure. Do not repeat the old pair-only timing pack or run a human session unattended. Measurement review pass 15 (P15-7): also score wrong and unsure answers and achieved exactness on known truth, apart from ideal/perfect-correction after-checking figures; seconds alone do not measure achieved accuracy.






- [ ] **`W46.post-read-flag-readers` — a read-poorly flag for the readers other than Apple Vision [M]** (lane: processor,segbench) (uses: light) (blocked-on: W46.capture-warning) — W46.post-read-quality-flag (2026-11-18) shipped the flag for Vision's own readings only: disagreement with Vision ranks the other readers' errors on plain photographs (LightOnOCR 82% caught at 5% false alarms, cross-validated) but a cut fitted there flags 21% of Gemini's good readings of damaged images, and no Swift route returns token log-probabilities. Fit a per-reader rule on real captures (W46.capture-warning) with the open readers' ladder readings beside them (not on the Mac; a Sherlock collection may hold them), or have the local routes return log-probabilities; same 5% ceiling, same report (`post_read_flag.py`). **Since then (measurement review pass 17):** W47.wh-read-flag-readers (2026-11-19) shipped a per-reader cut for 14 readers fitted on the 96 plain photographs (Gemini 3.7 Flash also on the ladder's 480 defect images); what remains here is fitting and checking them on real captures.
- [ ] **`W46.gateway-gpt-claude-readers` — GPT and Claude readers through the gateway on both sets [S-M]** (lane: segbench) (uses: light,paid) (blocked-on: W46.gateway-budget-reset) — Owner review of the pipeline doc, 2026-11-17: GPT was read only through OpenRouter on the 96 (Luna 93.56, 5.4 Mini 94.81) and neither family has a public-set figure. List the gateway's current models first; run the strongest GPT and Claude readers on the 96 and the 895 (forms stratum L4 included) through the gateway key; give the ChatGPT plan its reading row. The $7 rule applies. **1.0 on Dec 1 (`W46.gateway-budget-reset`, owner, 2026-11-24).**









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

### Processor settings and interface design review

- [ ] **W49.proc-ui-design-review — Produce a Settings-only redesign proposal for owner review [M]** (lane: processor) (uses: build,vm) (agents: claude, codex) — Owner, 2026-11-23, re-scoped 2026-11-24. Run the review on GPT-6.2 Astra or Claude Fable. Either provider is eligible. Verify `AGENT_MODEL` before starting. For Claude, also check the assistant model IDs in `$AGENT_WORKER_STATE/last-session.log` before reviewing and again before filing the plan or follow-ups. If the model cannot be confirmed or the session switches to another model, end the attempt with the item open for an eligible session and report the routing problem.
  - **Settings-only proposal first (owner, 2026-11-24):** The owner rejected the current 8-tab Settings UI and will not do hands-on feedback until the new Settings is built; he wants a **Settings proposal alone for review first**, followed by the larger hands-on review (`W40.g3`) after the new Settings ships.
  - Inspect the current macOS Processor Settings in the off-screen GUI with scratch data and compare it against the Nov 4 Shape-A workbench mock-up (`execution-plans/processing-review/settings-design/prototype.template.html` and `12-settings-design.md`). Challenge the underlying settings architecture itself — do NOT assume the ~75 legacy `@AppStorage` controls or the 8-tab layout survive. Compare (A) restoring the unified Shape-A workbench as a true replacement vs. (B) a preset-first Basic/Standard surface (3–4 clear workflows: Fast & Free Mac / High-Accuracy Local / Cloud / Cluster) writing one unified `ResolvedRunConfig` (eliminating the 3 overlapping config surfaces in `OCRProcessor`), with the Pareto frontier & per-kind solver in an optional Advanced Advisor view.
  - **Delete when you replace:** Every proposed screen must explicitly delete the legacy controls it supersedes (never stack solver cards on top of legacy pickers). Put brief optional explanations behind accessible help/tooltips and move long comparisons/caveats to the handbook or bench website.
  - Write the Settings proposal under `execution-plans/` with before-and-after examples, sample copy, the list of legacy controls deleted, dependencies and acceptance checks. File the ordered implementation items in `SUITE_TODO.md` and the live WORK QUEUE with default model routing, **every one of them `(blocked-on: W49.proc-settings-design-ok)`** so no Settings code is written before the owner approves the proposal. Add a Daemon Report entry pointing the owner to the proposal for `W49.proc-settings-design-ok`.

### Archive Processor — pipeline simplification, unification & architecture (owner, 2026-11-24)

- [ ] **W49.proc-pipeline-prune-apply — Apply the six owner-approved pipeline simplifications from W49.proc-pipeline-prune [M]** (lane: processor) (uses: build,vm) — Owner, 2026-11-24 (`W49.proc-pipeline-prune-ok`, `execution-plans/processor-pipeline-prune.md`): (1) default `place.hand_on_image` (`hand-blla-ctc`) to OFF as an opt-in Advanced on-demand download (clean text page default in 1.0); (2) simplify per-kind OCR routing to one clean 2-way split (Typed/Printed vs. Handwriting) for both Mac and Cloud cost-saving, dropping the 4-way matrix and deferring the mixed-page switch to 2.0; (3) restrict the app's bundled runtime `settings-routes.json` to runnable/supported app routes (keeping all 119 rows on ArchiveOCRBench); (4) unify the solver tie rule across Reading (`0.5` NES pts practical floor for both cloud and local) and Segmentation (`2.0` pts practical floor), displaying 95% CIs without letting underpowered CIs force ties; (5) add a collection-level numeric date-order setting (`MM/DD` US default vs. `DD/MM` International) so `DD/MM/YYYY` is not silently misread; (6) make rotation fallback use the user's configured OCR model (retiring the separate unmeasured direct-key rotation list). Neutral prompt examples land in `W49.proc-metadata-consolidate`. Verify clean Debug build, settings/solver tests, and `test-settings-routes.sh`.
- [ ] **W49.proc-metadata-consolidate-sherlock-prep — Prepare Sherlock pack for unified structured metadata benchmark [S]** (lane: segbench) (uses: light) (cluster: sherlock) — Owner, 2026-11-24 (front-load Sherlock work early due to long Slurm queue times). Mac-side pack prep only ($0, no dependencies): design the unified structured metadata prompt/schema (combining Tagging + traceable Dating with quotes + Entities + Item fields + route-independent enclosure proposals, free of US/owner-corpus prompt priors) and build the Sherlock batch pack for Qwen3.6 27B on the existing 138 correspondence + item-field documents (with size-and-necessity review in `execution-plans/items/W49.proc-metadata-consolidate-sherlock-prep.md`). Hold ready for the owner to submit in the same Sherlock session that collects `W46.ocr-family-coverage`.
- [ ] **W49.proc-metadata-consolidate-lead — The unified metadata call on the lead cloud models, with the Sherlock fold and the VLM-reader image-pass test [S-M]** (lane: segbench) (uses: light,paid) (blocked-on: W46.gateway-budget-reset) — Filed by W49.proc-metadata-consolidate, 2026-11-24. The Gemini 3.8 Flash arm (`segbench-results/metadata-unified.md`) ran on the personal key; the owner's lead models (Claude Fable, GPT-6.2 Astra) need the gateway, whose budget resets on 1 Dec. Run `metadata_unified.PROMPT` on the strongest Claude and GPT the gateway serves on the 299 (text only, as the pack sends it) and, as a second arm, with the page images the item-field call sends (1,600 px), since the text-only call lost title, byline and publication date to the image-reading item-field call; give the prompt the entity call's place-format rule (city, then the state or country) first, since the as-written place cost the sending-place field its normalised form. `metadata_unified_score.py` scores any `replies/<arm>/` folder of the metadata-unified cache. Fold the Sherlock Qwen3.6 27B replies when the owner's session returns them (`metadata_unified.py collect`). The VLM-reader question: read the 122 unprinted-year documents' first two pages (W46.date-image's set) with the gateway's Gemini OCR (about $0.40) and count the owner's years the VLM text carries that Vision's lacks, against the image pass's 56 (`metadata-unified.md` §"The image pass under a VLM reader"). Priced under the $7 rule. Ends with the go/no-go for `W49.proc-metadata-unified-apply` in the Daemon Report.
- [ ] **W49.proc-metadata-unified-apply — One post-OCR metadata call in the Processor [M · Tier-2]** (lane: processor) (uses: build,vm) (blocked-on: W49.proc-metadata-consolidate-lead) — Filed by W49.proc-metadata-consolidate, 2026-11-24: the implementation, if the lead-model arm confirms Gemini 3.8 Flash's result (sender, recipient and the year tie the separate calls; a third of the cost, a fifth of the time; the image-carrying arm has to hold title, byline and publication date). One call after OCR, with the page images, in place of the tagging, trace, entity and item-field calls: `metadata_unified.PROMPT` with the place-format rule; the reply's quotes through the existing evidence checks (`EntityExtractor.evidence`, `DateRoute.evidenceCheck`); `ItemFieldPolicy`'s fill verdicts and `EntityRunPolicy` applied to the one reply; the enclosure proposal (`announces`, `sent_with_previous` with its quote) written on every reading route, which closes the W37.dual-date limitation (`ArchiveProcessor/KNOWN_ISSUES.md`); the collection's numeric date-order setting (W49.proc-pipeline-prune-apply, point 5) for all-numeric dates; the same call on the local route (the Sherlock 27B row says whether the open model holds up). `prompts.md` gains the call and retires §5, §8, §9's trace and §10; `scripts/test-date-route.sh`'s cases move to the new call.
- [ ] **W49.proc-local-model-supervisor — Single local-model supervisor with memory arbitration and stage batching [M · Tier-2]** (lane: processor) (uses: build,machine) — Owner, 2026-11-24. Build one `LocalModelSupervisor` actor and one managed Python/MLX runtime before `W49.proc-managed-local-ocr`: strict single-resident-large-model arbitration (explicit unload/stop before loading a different model so two large VLMs are never co-resident; verify `<10 GB` peak under the shared heavy lock so Agent Manager's 11.7 GB guard never stops it), sensible idle keep-alive during active Live Capture (replacing ManagedGemma's 20 s teardown), and stage-level batching (avoiding per-page model swapping). Migrate `ManagedGemma` onto `LocalModelSupervisor` and add a seam lint (`scripts/check-local-model-seam.sh`) forbidding uncoordinated Python/MLX server lifecycles.
- [ ] **W49.proc-unified-pipeline-1 — Extract one shared PostOCRFinalizer for fresh, resumed and batch runs [M · Tier-2]** (lane: processor) (uses: build,vm) — Owner, 2026-11-24. Absorb `W49.proc-finalize-helpers` and `W49.proc-resume-tagging-progress`. Extract one shared `PostOCRFinalizer` used by `startProcessing`, `resumeRun`, and `resumeBatch` in `OCRProcessor+Pipeline.swift`, unifying rotation review, classification headers, capture quality tags, tagging/review flow, and per-segment tagging-progress persistence on resume. Add a seam lint (`scripts/check-pipeline-seam.sh`) preventing duplicated post-OCR/organize tails. Tier-2 adversarial review + scratch-copy/resume regressions.
- [ ] **W49.proc-unified-pipeline-2 — Defer PDF/A-2b and catalogue-identity generation to PostOCRFinalizer [M · Tier-2]** (lane: processor) (uses: build,vm) (blocked-on: W49.proc-unified-pipeline-1) — Owner, 2026-11-24. Stop eagerly generating full PDF/A-2b + `jbig2`/`qpdf` files during Phase 1 (OCR) in Process Files. Persist OCR results durably in `pending_run.json` (unchanged crash-resume safety), render lightweight thumbnails for review sheets, and write each final PDF/A-2b with its `CataloguePDFIdentity` once in `PostOCRFinalizer` after rotation, segmentation, tagging and merge decisions complete. Eliminates 4–5× redundant PDF rewrites and aligns Process Files Page-2 headers with Live Capture. Tier-2 adversarial review + scratch-copy/resume/batch regressions.
- [ ] **W49.proc-catalogue-cutover — Finish Processor-internal cutover to CatalogueRecord [M · Tier-2]** (lane: processor) (uses: build,vm) (blocked-on: W49.proc-unified-pipeline-2) — Owner, 2026-11-24. Complete Processor-internal single-source-of-truth cleanup without breaking cross-app contracts: default legacy `enableSegmentJSON = false` (explicit export opt-in only), build `CatalogueRecord` quality directly from typed run fields instead of scraping `job.appliedTags`, and ensure Process Files and Live Capture write identical Page-2 provenance headers. Leave cross-app `ImproveOCRFlagStore` / `OCR Poor` Finder tag migration to `W49.storage-finder` (`SPEC/improve-ocr.md`). Tier-2 scratch-copy verification.
- [ ] **W49.proc-arch-review — Standing delta architecture and anti-drift review for Processor [S-M · standing]** (lane: processor) (uses: light) (agents: claude, codex) (blocked-on: W49.proc-arch-review-due) — Owner, 2026-11-24. Standing delta-only review on lead model (Claude Fable or GPT-6.2 Astra), modeled on `W46.measure-review` (never whole-project `lean-review` fan-outs, which stay paused). Triggered via `## RECURRING` every ~10–12 completed Processor code items and at milestone gates (including Gate B right before `W40.g3`). Reviews only commits since last review SHA against 5 failure classes: (1) multi-path drift across fresh/resume/batch/Live Capture, (2) uncoordinated local-model subprocesses or >10 GB memory regressions, (3) additive-only UI bolted beside legacy controls, (4) new inline `#if DEBUG` `*TestDriver.swift` files in the app target, (5) silent failure swallowing. Files focused follow-ups and rearms `W49.proc-arch-review-due`.
- [ ] **W49.proc-vision-page-cache — Shared per-page Vision analysis cache across pipeline stages [M · Tier-1]** (lane: processor) (uses: build) — Owner, 2026-11-24 (Phase 3 pre-release optimization, post-`W40.g3`). Produce one per-page `PageVisionSnapshot` (lines, boxes, text, slope, feature print) per image orientation and reuse it across page-kind classification, rotation, cascade word count, read-quality disagreement, straightening slope, and searchable text-layer placement, eliminating 5–6× redundant `VNRecognizeTextRequest` passes per page.
- [ ] **W49.proc-unit-test-target — Extract Processor pure logic and new tests out of inline `#if DEBUG` app drivers [M · Tier-1]** (lane: processor) (uses: build) — Owner, 2026-11-24 (Phase 3 pre-release hygiene, post-`W40.g3`). Add an `ArchiveProcessorTests` XCTest target (or testable core Swift module, matching Reader and Notes) so new non-UI tests stop bloating the 40,734-line inline `#if DEBUG` harness footprint (35.6% of the app target); migrate existing drivers lazily as files are touched.


## Archival containers — W47 (owner, 2026-10-21)

Repository, place, collection title, collection number, accession, series, container, folder and folder title for
every item, worked out from label photos (Route A) or a labelled folder tree (Route B), and corrected in one place,
the Reader. Every field is optional. The owner's corpus is one test case, not the design target: the owner asked
that the two common routes work for any user. The assessment, the measured corpus figures, the field list with its
Zotero mapping and the design are in `execution-plans/containers/00-plan.md`. Approved and filed 2026-10-21 (owner:
"file as drafted", with Accession and Series as fields and the two routes). This reverses the 2026-07-15 ruling
that removed the Box > Folder > Document hierarchy as out of scope. Owner gates in the plan's HOLD QUEUE:
`W47.ct-truth-owner-ok`, `W47.ct-truth-revise-owner-ok` (the second label sheet), `W47.ct-truth-final-owner-ok` (the third, short label sheet), `W47.ct-design-ok` (blocked-on: W47.ct-read, W47.ct-read-paid: the paid arm's figures go into the same review, 2026-11-06) (blocked-on: W46.p12-wording: ct-read.md's recommendations corrected before the review reads them, measurement review pass 12, P12-4), `W47.item-fields-owner-ok`. No app code is written before `W47.ct-design-ok`.


## The withheld features — the owner's calls of 2026-11-19 (W47.wh)

The owner answered the withheld-features sheet on 2026-11-19 (`execution-plans/processing-review/13-stage-rules/14-owner-calls.md` call 15; the entries are `16-withheld-review.md`). One item for each feature he released, and one for the work each "ask again later" waits on, except where an open item already is that work (W46.enh-small-reader-power for glare, W46.capture-warning for the retake warning, both behind nice-to-have at his word). The eight he kept withheld need no work.

- [ ] **`W47.settings-trained-label` — a trained model's Advanced reason says what its gate measured [S]** (lane: processor) (uses: build) (blocked-on: W49.proc-settings-design-ok) — Measurement review 2026-11-19 pass 17, P17-7(e); a check on W47.settings-level-switch (shipped). `SettingsLevels.why` (`Settings/SettingsLevels.swift`) gives every after-training route "a trained model checked on a small held-out set" whatever its manifest's `gate.label` says, and states no rate, where the kit README (`scripts/segbench/institutional-compute/README.md`, the gate section) says a candidate 3.5 points worse passes about a quarter of the time on two documents (W46.kit-gate-docs). Say "small held-out set" only when the loaded model's `gate.label` does, with that rate; otherwise the held-out figure the manifest gives (`heldout.gate_gaps`, `gate_documents`). Test in `scripts/test-settings-panels.sh`.
- [ ] **`W47.wh-seg-magazine` — the magazine figure for the older prompts and the students, made a fair comparison [S]** (lane: segbench) (uses: light,paid) (blocked-on: W46.nice-to-have) — **Behind W46.nice-to-have until the gateway resets on 1 December (owner's rule of 2026-11-18 for gateway-only work): checkpoint 1 (94349c44) hit the spent November budget, and its two models have no other route.** Owner, 2026-11-19 (call 15): ask again after the named work. Run c1 with the article-within-issue rule through the gateway (W46.gateway-models-ok is answered), priced first under the $7 rule, and score it on the magazine box; for the students, name a magazine box they were not trained on or say that none exists and what building one takes (`07-segmentation.md` l.69-78). It ends by asking the owner in the Daemon Report (needs you) with the new figures and what the user would gain or lose (call 13); nothing is released or withheld by the item itself.

## Processor local OCR setup

- [ ] **W49.proc-managed-local-ocr — Download and run selected local OCR models in Processor [L]** (lane: processor) (uses: build,machine) (blocked-on: W49.proc-local-model-supervisor, W46.ocr-gemma3-12b) — Owner, 2026-11-23 (updated 2026-11-24 to build on `LocalModelSupervisor` and wait for `W46.ocr-gemma3-12b`): Processor handles both the download and the local model runtime through `LocalModelSupervisor`. Start with a curated set of named OCR models supported by the Mac and justified by the existing measurements (including Gemma 3 12B if `W46.ocr-gemma3-12b` qualifies it). Show disk and memory needs before download, support progress, cancellation, retry and removal, and keep Apple Vision available if a model is unavailable or setup fails. Validate that a fresh supported Mac can download and read a scratch page without a separately installed model or server.
- [ ] **W49.proc-local-ocr-onboarding — Keep Vision as default and offer specific model downloads in the first-run wizard [M]** (lane: processor) (uses: build,vm) (blocked-on: W49.proc-managed-local-ocr) — Owner, 2026-11-23: Apple Vision remains the default for speed. The initial wizard lets users choose optional, named app-managed model downloads and skip them while keeping Vision. Put the existing bring-your-own-server connection in Advanced Settings and preserve existing configurations. Verify fresh setup, the skip path, choosing a supported model, and reaching the server controls through Advanced Settings.

## Known limits are queued, accepted or asked (owner, 2026-11-19)

Owner, 2026-11-19 walkthrough: the Luna label cost sat in ArchiveProcessor/KNOWN_ISSUES.md with no item, found only
because the owner asked. "It's important to not just let problems like this accumulate." The rule is in CLAUDE.md,
"Definition of done": every KNOWN_ISSUES bullet carries a disposition, `(queued: TAG)`, `(accepted: reason)` or
`(asked: GATE)`.

- [ ] **`W49.proc-gemma-request-adopt` — Make the verified Gemma label request the default [S]** (lane: processor) (uses: build) (blocked-on: W49.proc-gemma-request-adopt-owner-ok) — W49.proc-gemma-request-verify measured the revised request (prompt first; the upright JPEG file itself when it needs no turn or scaling) through the app: set `ContainerLabelGemma.style` default to the owner's answer and server scope, update the contract and `SPEC/containers.md` if it names the request. Results: `ArchiveProcessor/segbench-results/ct-gemma-request-verify.md`.
- [ ] **`W49.proc-gemma-swap-time` — time Gemma label reads beside a local OCR model [S]** (lane: processor) (uses: build) (blocked-on: W46.ocr-gemma3-12b) — Switching between Gemma 3 12B for labels and a local OCR model for pages can delay Live Capture. On this 18 GB Mac, Agent Manager stopped the automatic-switching attempts at 13.0 GB and 12.0 GB against the 11.7 GB limit. Owner session, 2026-11-24: those two stops are the result for the server's automatic switch on this Mac, so do not run it again. mlx-vlm 0.7.4 keeps the outgoing model while it loads the next one, so Gemma and the OCR model are resident together and the session crosses the guard's limit. Record that the automatic switch does not fit an 18 GB Mac, with the 13.0 GB (Qwen3-VL 8B) and 12.0 GB (Qwen3.5 4B) stops as its figures. Then measure the switch the app can use instead: stop the server, or unload the model, before loading the next one, so only one model is resident at a time. With Qwen3.5 4B, time the cold load, a warm read and the full switch in each direction, save each row as it completes, and record each step's peak footprint. Run it under the shared heavy lock with no other model job running; the item waits for W46.ocr-gemma3-12b, which loads the same Gemma. Stop and report if any single step passes 10 GB. The recovered script, results note and item note are in the newest retired worktree (`refs/agent-manager/recovered/20261123-170330-wt_resume-W49.proc-gemma-swap-time-s6bgop3x-gni8lpac`) and in `$AGENT_STATE/rescue/20261123-170325-wt_resume-W49.proc-gemma-swap-time-s6bgop3x`. Change `ct_gemma_swap.py` to restart the server between models instead of relying on its automatic switch. The same rescue holds uncommitted Live Capture and label-capture Swift changes; keep them only if the measurements support them, as their own commit. Then evaluate the Vision + parser fallback or batching from the saved measurements, reporting each configuration separately.ver and configuration separately. Covers §W47.ct-processor-capture “Gemma beside a local OCR model swaps models.” Filed by W49.ki-audit-processor.
- [ ] **`W49.proc-chatgpt-real-signin` — the ChatGPT plan route checked against OpenAI's real servers [S]** (lane: processor) (uses: build) (blocked-on: W49.proc-chatgpt-real-signin-owner-ok) — The route is proven only against an in-process fake. With the owner signed in once with a real ChatGPT account, run one real segmentation window and check inline `input_image` parts are accepted (else `subscription_sharing_unsupported_capability`), `reasoning.effort` is accepted, and the client id behaves when a different account signs in after sign-out; fix what fails. Covers §W36.seg-opt-siwc "Built and tested against a fake only". Filed by W49.ki-audit-processor. **Owner, 2026-11-19 walkthrough: yes, he will sign in once after the plan's weekly reset on Sat 21 Nov 13:25 (call 19). It is the Processor's own Sign in with ChatGPT; the Codex login does not carry over. Held in the plan until he has signed in.**
- [ ] **`W49.proc-manual-repoint-relation` — the manual tag sheet re-points an enclosure at another letter [S]** (lane: processor) (uses: build) (blocked-on: W46.nice-to-have) — The manual tag sheet can clear a proposed enclosure relation or type a date but cannot re-point it at another letter. Add a picker over the run's letters. Tier-2 (tag output). Covers §W37.dual-date "The manual sheet can clear a proposed relation…". Filed by W49.ki-audit-processor.
- [ ] **`W49.notes-html-block-starts` — Notes keeps the Returns after a `<div>` block that holds an unclosed opener line [XS]** (lane: notes) (uses: build) (blocked-on: W46.nice-to-have) — Filed by W49.notes-lines-after-html, which keeps Returns after an HTML block but drops them, as before, after one a blank line does not end (an unclosed `<!--`, `<pre>` …). Apple gives adjacent HTML blocks as one run without the blank lines between them, so `MarkdownBridge.htmlBlockEndsAtABlankLine` counts any opener line with no end after it as open, and a `<div>` block holding `<!-- x` loses its Returns too. Find where each block starts from the source lines (the Styler already has them when parsed with source positions) and judge only the last block. Rare: raw HTML comes only from files written outside Notes. Tests: the editor-lines unit tests. Covers ArchiveNotes/KNOWN_ISSUES.md §W49.notes-lines-after-html "Also dropped".
- [ ] **`W49.proc-backfill-classify-optin` — backfill can find label photos by the classifier, opt-in with its cost [S]** (lane: processor) (uses: build) (blocked-on: W49.corpus-adoption-tool) — Owner calls 21 and 31: offer the label classifier in the adoption tool as an optional pass over files with no tag or colour marks. Show estimated time and cost before it runs. [Adoption scope](old/W49.corpus-specific-audit-20261121.md#decision-and-queue).
- [ ] **W49.corpus-adoption-tool — one scratch-first adoption tool for the pre-app archive [L · Tier-2]** (lane: suite) (uses: build) (blocked-on: W49.storage-processor) — Owner call 31: combine legacy colour conversion, named PDF/JPEG pairing and old-label backfill. Start with a read-only inventory, review ambiguous matches and verify a derived scratch copy before retiring the legacy paths. Keep general folder maps, trusted OCR reuse, live label reading and explicit original links. Use the approved preservation layout and eventual catalogue format for the derived archive. [Audit and trial plan](old/W49.corpus-specific-audit-20261121.md#one-time-adoption-scope).
- [ ] **W49.personal-repository-migration-kit — plan an LLM-assisted migration kit for other archives [M]** (lane: suite) (uses: light) (blocked-on: W50.v2-release) — Owner call 31: plan a reusable kit that helps users inventory their own formats and propose field and folder mappings for review before importing into a separate copy. Keep source files intact and show which data the language model would see before use.
- [ ] **W49.proc-reocr-preservation — Reread matching full-resolution Preservation Copies in Improve OCR [M · Tier-2]** (lane: processor) (uses: build,vm) (blocked-on: W49.preservation-copies-build, W49.proc-unified-pipeline-2) — Owner call 34 (2026-11-22). Prefer the verified full-resolution intake source for each OCR page, including the mapped page of a multi-page source. Follow the existing reader's request constraints and the collection's sharing settings. When the original is absent or cannot be verified, identify the fallback to the reading PDF. Keep the Preservation Copy read-only. Verify mapping, availability, orientation, same-name conflicts and recovery on scratch files. [Preservation format](SPEC/catalogue.md#preservation-copies).
- [ ] **W49.proc-item-fields-rerun — Keep catalogue corrections through Improve OCR and restore [M · Tier-2]** (lane: processor) (uses: build) (blocked-on: W49.proc-item-fields-rerun-owner-ok, W49.item-fields-home, W49.storage-processor, W49.proc-unified-pipeline-2) — Owner calls 24 and 32. Advance the content revision while preserving current corrections, clears and checks. Carry new observations as evidence, preserve unresolved conflicts and test restoring older PDF bytes after a Reader correction.
- [ ] **`W49.proc-glyphless-font-measure` — measure a glyphless fixed-pitch text layer against the current one in PDFKit [S]** (lane: processor) (uses: build) (blocked-on: W50.v2-release) — Owner, 2026-11-19 walkthrough of 21:58 (call 23), from Vision OCR's FEATURES.md 'A glyphless font and a second knob for the text layer' (costed 2026-08-16): build one fixture both ways and score extraction in PDFKit (Preview, Quick Look, Spotlight) with the engine's width and weld scores; only if it wins, ask the owner about the full package (embedded CID font, width by horizontal scale, no vertical squash, the invariant-3 campaign).
- [ ] **`W49.proc-footnote-links` — clickable footnote and endnote links in output PDFs, research first [M]** (lane: processor) (uses: light) (blocked-on: W50.v2-release) — Owner, 2026-11-19 walkthrough of 21:58 (call 23), from Vision OCR's FEATURES.md 'Clickable footnote and endnote links' (2026-08-13): how markers (small raised glyphs, from the engine's boxes) and their notes would be found, whether a model is needed to pair them, and the link-writing plumbing it shares with annotation preservation; ends with a short report and a question to the owner. No build.
- [ ] **`W49.proc-intel-compression` — the compression tools built for Intel Macs too, and the Apple-silicon-only downloads hidden there [S]** (lane: processor) (uses: build) (blocked-on: W46.nice-to-have) — Owner, 2026-11-19 (call 22, the accepted-issues sheet's second round; `execution-plans/processing-review/17b-accepted-review-round2.json` entry `p-intel-tools`, answers in `answers/17b-accepted-review-round2-answers-20261119.json`): both, behind nice-to-have (his note: "Put this behind Nice to Have"). No app code: install jbig2enc and qpdf with an Intel Homebrew under Rosetta, lipo each tool and library with its arm64 twin, teach bundle-compression-tools.py to do it (handle mismatched library versions), test the x86_64 slices under Rosetta; hide the handwriting, newspaper-layout and local-model downloads on Intel with a line saying why.
- [ ] **`W49.proc-read-flag-newspaper-app` — the read-poorly flag on newspaper pages read in regions [S]** (lane: processor) (uses: build,machine) (blocked-on: W46.p18-newspaper-flag-counts, W46.nice-to-have) — **Deferred to 1.1 (owner, 2026-11-24, `W49.proc-pipeline-prune-ok`):** wait until photographed newspapers (`W46.newspaper-photo-truth`) are calibrated too. W49.proc-read-flag-newspaper's app half (`ArchiveProcessor/segbench-results/post-read-flag-newspaper.md`). For a page read in regions, Vision reads each image the plan hands the reader (regions, then outside crops), their texts are joined in that order and compared with the reading by `ReadQualityDisagreement.similarity`; flag at 0.45 or more, one cut for every reader but Vision (pooled over 27 region readers on the 15 L9 scans; a system left out of the fit held 6% at the lower fitted cut). The run summary says "15 scanned newspaper pages, 14 from one collection". First check the cut on the app's own masked crops: dump the 15 L9 plans (`layout_partition_plans.sh`), read their images with Vision and score the cached PaddleOCR-VL partition reads (`layout-partition-score/reads/partition`) as `post_read_flag_newspaper.py` does; if the good ones go over 5% there, report it rather than ship. Measure the time Vision adds a page. Pass 18: give scan-only evidence (14 of 15 from one collection), distinguish photographed pages whose false-alarm rate is unknown, and use the eligible-region baseline from W46.p18-newspaper-flag-counts.
- [ ] **`W49.proc-read-flag-newspaper-whole-app` — the read-poorly flag on newspaper scans read whole, against Vision on 3 x 3 tiles [S]** (lane: processor) (uses: build,machine) (blocked-on: W46.p18-newspaper-flag-counts, W46.nice-to-have) — **Deferred to 1.1 (owner, 2026-11-24, `W49.proc-pipeline-prune-ok`):** wait until photographed newspapers (`W46.newspaper-photo-truth`) are calibrated too. W49.proc-read-flag-newspaper-whole's app half (`ArchiveProcessor/segbench-results/post-read-flag-newspaper-whole.md`). For a newspaper page read whole (Qwen3.6 27B always; any reader when the layout model is missing, the detector fails or the kind is uncertain), cut the image into 3 x 3 equal tiles, read each with Vision, join the lines and compare with the reading by NewsBench's bag-of-words F1 (risk 1 - F1); flag at 0.20 or more, one cut for every reader, in place of the reader's whole-page cut on those pages (pooled over 12 whole-page readers on the 15 L9 scans: 0/53 good flagged, 104/109 answered poor caught; refitting by page and by system tests the fitting procedure, with the 0.20 cutoff selected on these scans). Port the bag-of-words F1 into Swift with a parity test against `ocr_scorers.newsbench`. First check the cut on the image the app hands Vision (it may be downscaled from the frozen original); if good readings go over 5% there, report it rather than ship. Measure the time it adds a page (about 2 s on the bench). The run summary says "15 scanned newspaper pages, 14 from one collection". Pass 18: check the designated Qwen3.6 27B reader explicitly against the tile partner, first using any existing matched reads with the endpoint and image preparation identified. Report the per-reader false alarms and misses, the number of scorable pages and any route mismatch. If matched deployed-route evidence is unavailable, say so and report the unresolved check before claiming calibration for that reader. Gemini’s three pages and the 27B’s separate FarmShare truth score cannot establish it. Distinguish photographed newspapers, whose rate is unknown. This condition authorizes no new uploads or paid calls.
- [ ] **`W49.zotero-library-sweep` — the Zotero library re-OCR sweep, moved from Vision OCR [M]** (lane: processor) (uses: light,machine) (blocked-on: W46.nice-to-have) — Owner, 2026-11-20 walkthrough of 06:07 (call 24): move it here from Vision OCR's TODO.md §2 "The Zotero library sweep" (step 1 surveyed 15,901 attachments on 2026-08-13; superseded, re-run needed). Re-run the read-only survey with the Processor's own classifier, report which scans are worth re-OCRing and the space and time, and ask the owner before anything is written. The library is read-only to the survey.
- [ ] **`W49.reader-fuzzy-search` — fuzzy OCR text search in the Reader [M]** (lane: reader) (uses: build) (blocked-on: W46.nice-to-have) — Owner, 2026-11-20 (call 25): queue it behind nice-to-have, from ArchiveReader/POTENTIAL_FEATURES.md "Fuzzy OCR text search" (deferred 2026-07-09). Tolerate typos and OCR misreads so a misspelled query still finds the document: measure FTS5 prefix/NEAR, a trigram tokenizer and an edit-distance layer over candidates on the Reader's own index for recall, ranking with bm25 and index size, then build the winner (Search/ContentIndex.swift, Views/NavigationModel.swift).
- [ ] **W49.storage-drop-dead-copies — Retire redundant generated date copies after the handoff [S]** (lane: processor) (uses: build) (blocked-on: W49.storage-one-home-owner-ok, W49.storage-export) — Retire only date copies confirmed redundant after all consumers and export use the canonical record. Preserve separately consumed sidecar evidence, historical provenance and the distinct optional segment export.
- [ ] **W49.storage-notes-zotero — Use the same source facts in Notes and Zotero [M · Tier-2]** (lane: suite) (uses: build) (blocked-on: W49.storage-reader, W49.proc-item-fields-rerun) — Resolve the exact linked occurrence read-only. Keep Notes library metadata separate and share CSL and Zotero Connector mappings for dates, names, containers and attachments. Compare payloads and test root moves and ambiguous links. [Design](execution-plans/storage-simplify.md).
- [ ] **W49.storage-export — Export the PDF and its catalogue facts together [M · Tier-2]** (lane: suite) (uses: build) (blocked-on: W49.storage-notes-zotero) — Verify lossless pair/subset transfer, including facts owned by another file in a split. Label snapshots and settle disclosure and personal-state choices before setting export defaults. [Design](execution-plans/storage-simplify.md).
- [ ] **W49.storage-finder — Decide and verify optional Finder tag mirrors [M · Tier-2]** (lane: suite) (uses: build) (blocked-on: W49.storage-notes-zotero) — Ask about Finder defaults, external edits and cleanup before changing behavior. Verify any approved projection through the coordinated tag writer and keep Notes preferences distinct. [Design](execution-plans/storage-simplify.md).
- [ ] **W49.storage-spotlight — Decide and verify optional Spotlight publishing [M · Tier-2]** (lane: suite) (uses: build) (blocked-on: W49.storage-notes-zotero) — Ask about publishing defaults and archive privacy before changing behavior. Verify any approved backfill, rebuild, cleanup and result opening. Cover all four Finder/Spotlight combinations if both are adopted. [Design](execution-plans/storage-simplify.md).
- [ ] **W49.storage-pilot — Verify the catalogue rollout and rollback on scratch roots [M · Tier-2]** (lane: suite) (uses: build) (blocked-on: W49.storage-export, W49.storage-finder, W49.storage-spotlight, W49.storage-drop-dead-copies, W49.reader-root-movable, W49.corpus-adoption-tool) — Pilot new output and representative scratch copies of the pre-app archive. Prove links, byte preservation, interrupted filing, portable transfer and verified export of the latest edits for rollback. Real archive writes need separate approval. [Design](execution-plans/storage-simplify.md).
- [ ] **`W49.notes-editor-constructs` — tables, footnotes, task lists, strikethrough and inline HTML in the Notes styled editor [M]** (lane: notes) (uses: build) (blocked-on: W46.nice-to-have) — Owner, 2026-11-20 walkthrough of 08:05 (call 27): behind nice-to-have. He asked whether this can be borrowed from existing work: Notes' editor is its own Markdown bridge (`Editor/MarkdownBridge.swift`, no library). A parser such as Apple's swift-markdown (cmark-gfm) reads tables, strikethrough and task lists, but the styled editor's write-back that keeps the lines the user typed is ours either way. When the gate opens, say first what can be borrowed and what it saves before building.
- [ ] **`W49.bench-more-kinds` — bench charts for clippings, tables and table forms [S]** (lane: segbench) (uses: light) (blocked-on: W46.nice-to-have) — Owner, 2026-11-20 (call 27, the audit of earlier walkthroughs): behind nice-to-have, from ArchiveOCRBench/POTENTIAL_FEATURES.md "More kinds and tags". The groups CSVs already tag these kinds; chart each reader on them from scores already held, $0. Mixed pages (2 of 96) stay too few to chart.
- [ ] **`W49.proc-run-queue` — a processing queue: add files while a run goes, processed one after another in the background [L]** (lane: processor) (uses: build) (blocked-on: W46.nice-to-have) (blocked-on: W49.proc-resume-standard-runs) — Owner, 2026-11-20 (call 27, the audit of earlier walkthroughs): behind nice-to-have and after the resume item, from ArchiveProcessor/POTENTIAL_FEATURES.md "Queue system".
- [ ] **`W49.proc-review-undo` — undo and redo across the Processor's review dialogs [M]** (lane: processor) (uses: build) (blocked-on: W46.nice-to-have) — Owner, 2026-11-20 (call 27, the audit of earlier walkthroughs): behind nice-to-have, from ArchiveProcessor/POTENTIAL_FEATURES.md. ⌘Z steps back through review decisions (splits, dates, tags, fields) across dialogs until the files are filed; today only the tagging step has a redo loop.
- [ ] **`W49.proc-table-csv` — export a form or table page as CSV [M]** (lane: processor) (uses: build) (blocked-on: W50.v2-release) — Owner, 2026-11-20 (call 28, the Backlog review sheet). From ArchiveProcessor/POTENTIAL_FEATURES.md "Table extraction". Depends on cell reading measured well enough to trust (W46.ocr-cells-l4-more).
- [ ] **`W49.proc-nearby-subjects` — measure whether neighbouring documents improve subject tags [S]** (lane: processor) (uses: light) (blocked-on: W50.v2-release) — Owner, 2026-11-20 (call 28, the Backlog review sheet). From ArchiveProcessor/POTENTIAL_FEATURES.md. The tagger sees up to three neighbours but uses them for dates only. A bench comparison first, through the gateway; build only if it helps without spreading one document's subjects onto its neighbours.
- [ ] **`W49.shortcuts-actions` — Apple Shortcuts actions for the three apps [M]** (lane: suite) (uses: build) (blocked-on: W50.v2-release) — Owner, 2026-11-20 (call 28, the Backlog review sheet). From ArchiveProcessor/POTENTIAL_FEATURES.md "Apple Shortcuts integration": App Intents such as process a folder (Processor), open or search (Reader), new note (Notes).
- [ ] **`W49.notes-block-ids` — stable block identities and "extracts made from this note" [M]** (lane: notes) (uses: build) (blocked-on: W50.v2-release) — Owner, 2026-11-20 (call 28, the Backlog review sheet). From ArchiveNotes/POTENTIAL_FEATURES.md "Per-block stable GUIDs + reverse back-index". Extracts stay snapshots (call 27).
- [ ] **`W49.notes-preview-scroll` — scroll within a merged PDF from a source-block preview [S]** (lane: notes) (uses: build) (blocked-on: W46.nice-to-have) — Owner, 2026-11-20 (call 28, the Backlog review sheet). From ArchiveNotes/POTENTIAL_FEATURES.md "Page-within-merged-PDF scroll navigation".
- [ ] **`W49.reader-cloud-drives` — cloud-drive support: placeholders, conflict copies and Finder-tag survival [M]** (lane: reader) (uses: build) (blocked-on: W50.v2-release) — Owner, 2026-11-20 walkthrough of 08:05 (call 27): behind nice-to-have (moved to 2.0, 2026-11-24), from ArchiveReader/POTENTIAL_FEATURES.md. First measure whether Finder tags survive a round trip through iCloud Drive and Google Drive, then plan conflict-copy handling and a download policy for placeholders. Until it ships, W49.cloud-drive-first-launch-warning tells users to keep material on local disk.
- [ ] **`W49.bench-news-chart` — a fifth bench chart for newspapers from the NewsBench scores [S]** (lane: segbench) (uses: light) (blocked-on: W46.nice-to-have) — Owner, 2026-11-20 walkthrough of 08:05 (call 27): behind nice-to-have, from ArchiveOCRBench/POTENTIAL_FEATURES.md. Chart the readers' existing NewsBench scores (W41.farmshare-news-layout's truth set) on the bench page; no new runs, $0.
- [ ] **`W49.bench-seg-check-chart` — a checking chart for segmentation on the bench page [S]** (lane: segbench) (uses: light) (blocked-on: W46.nice-to-have) — Owner, 2026-11-20 walkthrough of 08:05 (call 27): behind nice-to-have, from ArchiveOCRBench/POTENTIAL_FEATURES.md. Plot checks per 100 pages against pages right after checking for each segmentation route; label the routes that fall on one point (Claude only, Claude with ChatGPT). $0.

- [ ] **W49.proc-fix-s045 — Name a Live Capture document whose tagging call failed [S · S2]** (lane: processor) (uses: build) — S-045, independently confirmed (W49.proc-s045-check, Claude Opus 5.5, `645c7845`). In Live Capture, Automatic tagging that gets an HTTP 500 (or a reply that is not the tag JSON) files the PDF with its OCR text, date and Unread tag but no subjects, while the row shows success and Finish says "Finalized 1 collection · 2 files moved." with no warning. Use `generateTagsReporting` in `LiveCaptureProcessor.computeTags` and carry the failure reason to the document's row and to the Finish summary (so `summaryReportsProblem` is true and the document is named), as W49.proc-fix-s042 did for Process Files. Keep filing the complete OCR PDF. Turn `scripts/repro-live-tagging-failure.sh` into the regression: the refused document is named with its reason in its row and in Finish, the control stays clean. The probe's 10-second staging wait can expire on a cold first launch, so allow for that. Tier-2 (Capture/). [Evidence](verification/evidence/processor/W49.proc-s045-verify.md).
- [ ] **W49.proc-fix-live-names-sidecars-off — Live Capture's names with sidecars off: align the self-test and the names estimate [S]** (lane: processor) (uses: build) — Filed by W47.wh-ent-8k-apply, 2026-11-24, from a failure on pristine origin/main (15074631): `scripts/test-entity-feature.sh` fails `6 Live, sidecars off: tagged, no entity call` (the entity call runs on L, V and F). W49.storage-processor (f6d0cf31, 2026-11-22) removed `liveEntities`' `config.enableSegmentJSON` guard on purpose ("document fields and eligible names also feed the catalogue"), so the check, and `3 names estimate: sidecars off is zero` (`EntityRunPolicy.estimatedCallShare`'s sidecars input), still describe the old rule: with names ranked and sidecars off, Live Capture now pays for the call while the estimate says $0. Confirm the intended rule from f6d0cf31 and the catalogue plan, check Process Files (`OCRProcessor+Tagging`) behaves the same, then make the estimate count the call and the Live check expect it (or restore the guard if the catalogue does not read names). Processor build clean; `test-entity-feature.sh` ALL PASS.
- [ ] **W49.proc-fix-solver-b1-image-pass — The settings solver's B1 dating step 2 picks the 8B image pass [S]** (lane: processor) (uses: build) — Filed by W47.wh-ent-8k-apply, 2026-11-24, from a failure on pristine origin/main (15074631): `scripts/test-settings-solver.sh` fails `B1 dating step 2: no image pass (the 8B's quotes add no year, W46.date-route-pipeline-8b)`, got `qwen3-vl-8b-image-mac`. Find the commit that changed the pick (the routes table, `settings_routes.py`, or the solver), decide from W46.date-route-pipeline-8b's figures whether the row or the test is stale, and fix that one. Processor build clean; `test-settings-solver.sh` ALL PASS.
- [ ] **W49.proc-s047-cover-select — Let document review name the cover of an enclosure a window split cut off [S · S3]** (lane: processor) (uses: build) — S-047, independently confirmed (W49.proc-s047-check, Claude Opus 5.5, `732f5920`). Owner call 33: when window segmentation splits the cover letter the OCR proposed and the enclosure relation drops, document review offers an optional choice of the actual covering document. The chosen document's final date becomes the enclosure's Sent With and the enclosure keeps its own date; a blank choice leaves the relation and Sent With unset. Never infer the cover from adjacency, and offer only document segments in the same folder before the enclosure. Carry the choice through rebuilds, resume and the manual tag sheet, and extend `SegmentationReviewTestDriver` §9b and `DualDateTestDriver` into the regression (blank → no Sent With; page 2 chosen → its date). Tier-2 (file-writing tag output). [Evidence](verification/evidence/processor/W49.proc-s047-verify.md).

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






- [ ] **`W42.int-s7-standalone` — Vision OCR's own retirement: the notice and link, the updater shutdown and the final release [S · owner]** (lane: suite) (uses: build) (blocked-on: W40.h4) (needs: owner) — split from W42.int-s7 by the owner, 2026-11-17: leave Vision OCR's GitHub pages, releases and updater as they are until the replacement (Archive Processor) is complete and released. Then an interactive cross-project session does the work in `execution-plans/items/W42.int-s7-standalone.md` (the notice and link, and the updater shutdown) in ~/Claude/vision-ocr and the owner cuts the release. There is nothing to import or reuse: Archive Suite treats Vision OCR users as new users. No engine session writes the vision-ocr repository or anything public for Vision OCR.


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
- [ ] **`W40.d11` — the shared tag contract across apps [S-M]** (lane: suite) (uses: build,vm) (blocked-on: W40.d1, W40.d8). Detail: `execution-plans/verification-phase/01-daemon-plan.md` §D.
- [ ] **`W40.e4` — never-executed code from coverage [M]** (lane: reader,notes,processor) (uses: build) (blocked-on: W40.d1, W40.d8, W40.d9). Detail: `execution-plans/verification-phase/01-daemon-plan.md` §E.
- [ ] **`W40.g3` — Redo the Processor and Live Capture guided walkthrough with Claude [S]** (blocked-on: W42.int-done, W48.appearance-verify, W41.app-openrouter-any, W41.app-claude-plan-reading) (lane: processor) (uses: light) (agent: claude) (blocked-on: W49.proc-gemma-request-verify, W49.proc-gemma-swap-time, W49.proc-managed-local-ocr, W49.proc-local-ocr-onboarding, W49.proc-ui-design-review, W49.proc-pair-compress-hands, W49.proc-reocr-preservation, W49.proc-item-fields-rerun, W49.proc-read-flag-newspaper-app, W49.proc-read-flag-newspaper-whole-app, W47.wh-ent-8k-apply, W40.fix-processor-resume-reviews, W49.proc-fix-s026, W40.fix-processor-pending-run-caption, W49.proc-s050-check, W49.proc-fix-s018, W47.settings-trained-label, W49.proc-fix-s048) (owner session, 2026-11-24: the walkthrough moves after the current Processor queue; owner-gated items, work behind Nice to Have, and Processor items that wait on suite-wide work stay outside it; no Processor fix is Codex-only today, so the exception for fixes that wait on Codex applies to none) (blocked-on: W40.fix-live-finish-settle, W40.fix-processor-keychain-prompts, W40.fix-processor-local-notice, W40.fix-processor-general-padding, W40.fix-processor-reading-scan, W40.fix-processor-collection-prompt-intake, W40.fix-processor-preservation-names, W40.fix-android-launcher-icon) (blocked-on: W40.d1, W40.d2, W40.d5, W40.fix-processor-dark-disabled-buttons, W40.fix-processor-start-why, W40.fix-processor-live-emptied-mixed, W40.fix-processor-flagged-page-edges, W40.fix-processor-settings-fields, W40.fix-processor-settings-backend-mismatch, W40.fix-processor-evidence-rewrite-name, W40.fix-processor-non-reading-reply, W40.fix-processor-review-keys, W40.fix-processor-review-classification-stale) (blocked-on: W47.settings-level-switch, W47.wh-readers-lost, W47.wh-post-correction, W47.wh-date-8b-image, W47.wh-names-small-mac, W47.wh-yolo-scans, W47.wh-whole-page-large, W47.wh-mixed-preflag, W47.ct-folder-date-live, W42.stroke-weight-processor, W49.proc-tree-folder-docs, W49.proc-tree-depth-say, W49.proc-label-read-turned, W49.proc-plan-read-meter, W49.proc-openrouter-gone-warn, W49.proc-child-cancel, W49.proc-runlog-all-paths, W49.proc-reocr-layer-review, W49.proc-date-paths-rest, W49.proc-reocr-dialog, W49.proc-training-warn-capture, W49.proc-ledger-limit-stop, W49.proc-request-failure-codes, W49.proc-claude-stored-key-cost, W49.proc-header-date-lines, W49.proc-batch-resume-approach, W49.proc-gemma-offer-download, W49.proc-training-deny-per-job, W49.proc-openrouter-list-image-priced, W49.proc-unread-page-files-image, W49.proc-reocr-searchable, W49.proc-reocr-allow-more, W49.proc-kind-sample-pdf, W49.proc-settings-rules-proper, W47.wh-item-fields-mac-fill, W49.proc-read-flag-wiring, W49.proc-openrouter-rotation) (blocked-on: W49.proc-fix-s024, W49.preservation-copies-build, W49.proc-tree-sheet-vm, W49.proc-fix-s032, W49.proc-s046-review-toggle, W40.fix-processor-collection-name-filing, W40.fix-processor-copy-label-tags, W49.proc-fix-s021, W49.proc-fix-s038, W49.proc-fix-s039, W49.proc-ledger-track-paid) (blocked-on: W49.proc-fix-s027, W49.proc-fix-s029, W49.proc-fix-s030, W40.fix-processor-merged-classification-stale, W49.folder-date-stamp-first) (blocked-on: W49.proc-fix-s025, W49.proc-openrouter-claude-live, W49.proc-s048-check, W49.proc-s047-check, W49.proc-s045-check). **Owner, 2026-11-22: Tier P is reserved for this pack and its unfinished direct and indirect prerequisites. The live plan editor keeps Tier P in sync when dependencies change.** Detail: `execution-plans/verification-phase/01-daemon-plan.md` §G. Judge first whether it is time for the owner's session (§G "Is it time?"); the blockers being ticked is not enough. Owner, 2026-11-23: Claude prepares the repeat and leads the owner through it when available. Give the wired Finish stall first priority in the Processor queue.
  [Readiness and remaining rehearsal checks](execution-plans/items/W40.g3.md).
- [ ] **`W40.g-sessions` — owner runs the guided sessions — OWNER** (lane: suite) (uses: light) (blocked-on: W40.g1). Detail: `execution-plans/verification-phase/01-daemon-plan.md` and `00-owner-plan.md` §Decisions Before each session is offered, the pack's own item judges whether it is time (§G "Is it time?"); for the Reader that is `W40.g1-refresh`, for Notes `W40.g2`. The first Notes pack, `verification/sessions/notes-1.md` (W40.g2, 2026-11-04), was run and filed on 2026-11-05; the second, `verification/sessions/notes-2.md`, is ready (W40.g2-notes-2, 2026-11-06).

- [ ] **`W40.tag-rename-suite` — rename or merge a tag across the archive and the notes, from any of the apps [M-L · Tier-2]** (lane: suite) (uses: build,vm) — Owner, 2026-11-06 walkthrough: "This is important functionality. Also, tag changes in one app should carry over to the other apps." Today (checked 2026-11-06): the Reader has Rename Tag… (menu and the tag cloud's right-click) and Find Similar Tags…, whose Merge drives the same rename; renaming into an existing tag merges into its spelling; it is one grouped undo through TagWriter (`NavigationModel.renameTag`, `RenameTagSheet`, `SimilarTagsSheet`). It covers only the files in the Reader's library, the tagged files under its granted folder. Notes has no rename or merge: a note's tags live in its front matter, mirrored onto its own `.md` by `NotesTagProjector`, and the Reader never sees or changes them. The Processor has none either (its typed tags take the vocabulary's spelling). So a rename in the Reader leaves the same tag on every note, and nothing renames a tag on notes at all. Wanted: (1) Notes gets Rename Tag… and Merge (with Find Similar Tags), over its notes and extracts, front matter first, then the projection, one undo; (2) a rename or merge in either app reaches the other app's items, so one tag means the same thing across the suite; (3) the Processor's vocabulary follows. Each app is sandboxed to its own folder, so (2) needs a design: for example a rename record in the archive root that the other app applies, after confirming, on its next open, or one app asking for access to the other's store. Design first in execution-plans/tag-rename-suite.md, which also designs the Tags window below (owner, 2026-11-14) (where the record lives, what happens when an app is closed, undo across apps, a tag the other app spells differently, a read-only folder), then build. Tier-2: a write to every tagged file and note; SPEC/tag-format.md gains the rule; adversarial review and scratch-copy tests in all three apps.
- [ ] **W40.tag-window-core — one Tags window, built once and shared by the three apps: every tag in use, with rename, merge and remove [M · Tier-2]** (lane: suite) (uses: build) — Owner, 2026-11-14: "we need a single place in each app, or in a small separate app, where the user can see all tags in use and make changes", merging tags and editing names among them, usable across the apps. Today no app has that place: the Reader spreads it over the tag cloud, Tags ▸ Rename Tag… and Find Similar Tags… (`RenameTagSheet`, `SimilarTagsSheet`), and Notes and the Processor have nothing. Decided here: a window inside each app, not a fourth app. Each app is sandboxed to its own store and writes it through its own audited writer (the Reader through TagWriter, Notes front matter first and then `NotesTagProjector`); a separate app would need grants to both stores and would write notes while Notes has them open, which breaks that safety model, and it would need its own signing and consents. So the shared part is the code: a tag inventory model in ArchiveCore (each tag, its spelling variants, how many items carry it, the similar-tag clusters `TagSimilarity` already finds) and one SwiftUI Tags window in a shared target (ArchiveCore stays UI-free, so a small sibling target or package beside it), which each app feeds with its own items and its own writer. The window: a searchable, sortable list of every subject tag with counts; Rename (into an existing tag merges, as the Reader does now), Merge of several selected tags into one spelling, Remove from every item with a confirmation that names the count, Find Similar as a filter of the same list, and a click that shows the items carrying the tag. Every change is one grouped undo. Facet tokens the suite writes itself (Quality, dates, read state, flags) are listed apart and are not renamed here. Tests: the model and its change plans on in-memory items, and a scratch-copy write test of rename, merge and remove through a fake writer. Design note in execution-plans/tag-rename-suite.md (the window's section) before the code.
- [ ] **W40.tag-window-reader — the Reader's Window ▸ Tags, over its library [M · Tier-2]** (lane: reader) (uses: build,vm) (blocked-on: W40.tag-window-core) — The shared Tags window in the Reader, fed by its library (the tagged files under its granted folder) and writing through TagWriter. Tags ▸ Rename Tag… and Find Similar Tags… and the tag cloud's right-click open it on the tag in question, and `RenameTagSheet` and `SimilarTagsSheet` retire into it. Remove from every item is new here. Clicking a tag filters the navigation list to it. Tier-2: a write to every file that carries the tag; scratch-copy tests at corpus size (116k rows) for the list's speed and for a rename's main-thread cost; VM UITests for rename, merge, remove and undo.
- [ ] **W40.tag-window-notes — Notes gets the Tags window, over its notes and extracts [M · Tier-2]** (lane: notes) (uses: build,vm) (blocked-on: W40.tag-window-core, W40.tag-rename-suite) — The shared Tags window in Notes, fed by its notes and extracts and writing front matter first, then the projection, through Notes' own writer. W40.tag-rename-suite gives Notes its rename and merge and carries a change to the other apps; this item is the place to see and use them. Tier-2: a write to every note that carries the tag; scratch-copy tests; VM UITests.
- [ ] **W40.tag-window-processor — the Processor's Tags window, over the tags it offers and writes [S-M · Tier-2]** (lane: processor) (uses: build,vm) (blocked-on: W40.tag-window-core, W40.tag-rename-suite) — The Processor keeps no library, so its window lists the tags it offers when the user types one (its vocabulary) and those on the outputs in its output folder, with the same rename, merge and remove; a change reaches the other apps through W40.tag-rename-suite's record, and a change made elsewhere updates its vocabulary. Which of the two lists it shows, or both, is settled in the design note. Tier-2 where it writes output files.
- [ ] **`W40.h2` — re-run every journey at HEAD [M]** (lane: suite) (uses: build,vm) (blocked-on: W40.d1, W40.d2, W40.d3, W40.d4, W40.d5, W40.d6, W40.d7, W40.d8, W40.d9, W40.d10, W40.d11, W40.e1, W40.e2, W40.e3, W40.e4, W40.e5, W40.e6, W40.e7, W40.e9, W40.e10, W40.e11, W40.e12, W40.e13, W40.f1, W40.f2, W43.app-guide-refresh). Detail: `execution-plans/verification-phase/01-daemon-plan.md` §H.
- [ ] **`W40.h3` — release candidate — OWNER (Tier-3)** (lane: suite) (uses: build) (blocked-on: W40.h2, W49.proc-pdfium-notices). Detail: `execution-plans/verification-phase/01-daemon-plan.md` and `00-owner-plan.md` §Decisions.
- [ ] **`W40.h4` — owner acceptance pass with the ledgers — OWNER** (lane: suite) (uses: light) (blocked-on: W40.h3). Detail: `execution-plans/verification-phase/01-daemon-plan.md` and `00-owner-plan.md` §Decisions.
- [ ] **`W40.token-fix` — the token pass's fix session: read the report, fix what it found, re-arm [M · Tier-2 · standing]** (lane: ops) (uses: light) (blocked-on: W40.token-fix-due) — Standing item, never ticked (W40.token-pass, owner 2026-10-28). The weekly pass (`ops/agent/token-audit.py`, run by the upkeep hook) ticks `W40.token-fix-due` in the plan's `## RECURRING` section when an always-loaded file is over its budget or a session figure is 10% or more worse than the last pass; that makes this item runnable. The session reads `$AGENT_STATE/token-audit/latest.md` and fixes what it can in one session: a guide trimmed by hand, with every rule listed before and after and an adversarial reviewer checking that list (a rule may move but never disappear); prompt steps the engine overrides removed; a noisy script given a summary on stdout and its full output in a log; a hook that dumps a large file narrowed. Anything larger than one session is filed as its own item. It re-measures (`token-audit.py sizes` for the files; the next pass measures the sessions) and records the before and after figures in a dated `W40.token-fix-YYYYMMDD` entry appended to `SUITE_TODO_DONE.md`, in the same commit as the fix; the commit subject names `W40.token-fix` standing alone, e.g. `W40.token-fix (2026-11-05)`, because the engine counts progress only by the bare tag. Then, after the push, `ops/autonomous/plan-edit.sh "/Users/cp1/Claude/Archive Suite/.maintenance/AUTONOMOUS_PLAN.md" rearm W40.token-fix-due '<sha>: <result>'`, which makes this item wait again (the next pass reports a gate left ticked). ⛔ Never `complete` it (plan-edit.py refuses) and never move this entry: the plan and this file both keep it open, which is what keeps check-tracker-sync.sh and check-todo-stubs.sh passing.
- [ ] **W40.fix-processor-resume-reviews — Show applicable reviews when resuming processing [S · S2 · Tier-2]** (lane: processor) (uses: build,vm) (blocked-on: W49.proc-s050-check) — S-035, independently reproduced at `bdfe3274`. Call 30 allows Resume to omit only reviews the user explicitly skipped. The paid-batch Resume path must restore the applicable whole-run page, box/folder and final reviews. Ordinary Resume shares the rule: W49.proc-s050-check independently confirmed S-050 (2026-11-24), so restore the whole-run page review (unless explicitly skipped) and the box/folder confirmation there too. Keep both VM journeys as regressions. [Evidence](verification/evidence/processor/W49.proc-suspects-filing-check.md).
- [ ] **`W40.fix-processor-batch-stop-contract` — the run-quit-resume contract's two batch-Stop checks fail on main [S · S3]** (lane: processor) (uses: build) — Found by `W40.fix-processor-pending-run-caption` 2026-11-24, failing identically on pristine main (ea20505f): `scripts/test-run-quit-resume.sh` FAILs "Stop during a batch submission waits, then cancels the recorded job" and "a quit after Stop still cancels the job, then quits". After the cancel request the processor now also GETs `batches/quit-test` and keeps the batch journal, where the checks expect exactly create + cancel and the journal gone. Find which commit added the post-cancel status read (candidates: `W49.storage-processor`, `W49.proc-batch-resume-approach`, `W49.proc-fix-s051`) and decide from its record whether the app regressed (fix it) or the contract is stale (update the expectation and say why). The gate's coverage of this script should be checked too, since it went red unnoticed.
- [ ] **`W40.reader-plain-pdf` — show ordinary PDFs as ordinary pages [M · Tier-2]** (lane: reader,suite) (uses: build,vm) — Owner's Reader notes, 2026-11-17: a PDF not made by the Processor (e.g. a scanned dissertation, every page real) opens with page 2 in the OCR text pane and Next stepping two pages. packages/ArchiveCore PDFPageRole.roles(of:) (PDF/ExtractedContent.swift:110-136) falls back to image/text pairs whenever the XMP carrier list is missing. Pair only when an odd page parses with a SPEC header; otherwise treat every page as its own page with no text pane, in the viewer and the index (PDFHeaderParser.extract, :146-178). Tests with a plain multi-page PDF fixture.
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
> Drive-relay cloud transport: integrated 2026-07-07; the record moved to `SUITE_TODO_DONE.md` §"History moved from SUITE_TODO.md (doc-fix, 2026-11-20)".

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



## Archive Notes — owner requests (2026-10-28)



## Nice-to-have (1.1 release) & 2.0 release — W46 / W50 (owner, 2026-10-22; split 2026-11-24)

**2026-11-04:** the owner retired the twelve items that were here (not run; §"⛔ DECLINED") and promoted four into §"Document processing review — W46".
**2026-11-24:** separated into three gates: **`W46.gateway-budget-reset`** (1.0 items waiting only for the Dec 1 Stanford gateway budget reset), **`W46.nice-to-have`** (1.1 release), and **`W50.v2-release`** (2.0 release: major new platforms/features and heavy R&D / new truth campaigns).

- [ ] **`W46.owner-set-grow` — grow the owner's reading set by about 200 random English pages [M]** (lane: segbench) (uses: light,paid) — Owner review of the pipeline doc, 2026-11-17: the 96 resolve about 3 NES; 730-2,303 pages are needed for 1 point. Draw at random under the JPEG-originals rules, draft truth with a reader not under test (through the gateway), owner rules disputed words on a sheet; prepare the sheet and size the owner's time before asking. The $7 rule applies. (blocked-on: W46.owner-set-grow-owner-ok, W50.v2-release)
- [ ] **`W46.newspaper-photo-truth` — a small truth set of photographed newspapers [M]** (lane: segbench) (uses: light) (blocked-on: W46.gateway-budget-reset) — Owner review of the pipeline doc, 2026-11-17: no photographed newspaper with truth exists (L9 is 15 scans). Check the 12 pages the sorter called newspaper in the 2,000-page draw (mixed-def.md:10), find more in the corpus, draft truth through the gateway, owner sheet on disputes; size the owner's time first. **1.0 on Dec 1 (`W46.gateway-budget-reset`, owner, 2026-11-24).**
- [ ] **`W46.cyrillic-print` — printed Cyrillic as a reading stratum [S-M]** (lane: segbench) (uses: light,paid) (blocked-on: W46.gateway-budget-reset) — Owner, 2026-11-17 (review follow-up): the only Cyrillic stratum is N2, early-1700s handwriting (Digital Peter), far harder than typical material. Find a public printed Cyrillic set with transcriptions (e.g. the Civil-font set in arXiv 2510.06743, C-ocr.md:147; 20th-century Russian or Ukrainian print), freeze about 40 pages as a new stratum, and run the current routes on it. The $7 rule applies. Waits for 1 Dec, all of it: `execution-plans/items/W46.cyrillic-print.md`. **1.0 on Dec 1 (`W46.gateway-budget-reset`, owner, 2026-11-24).**
- [ ] **`W47.item-fields-inference` — the owner's inference level for item fields and names, measured before it is a setting [M]** (lane: processor) (uses: build) (blocked-on: W50.v2-release) — The owner's sheet notes ask for inference as a user-set level: a name from a first name or initials, a paper from its initials. The shipped item-field prompt says "Do not guess from general knowledge" and is the only one measured (W47.item-fields-build), so a level that loosens it is a new prompt: measure it on the item-field truth set (both OCR sets where the field applies) and fill by the same rule before it becomes a setting; inferred values are marked inferred, as the entity feature's are. detail: `ArchiveProcessor/segbench-results/item-fields-score.md` §"The fold".
- [ ] **`W46.ocr-input-colour-dropout-more` — colour dropout: an owner-checked truth, a stamp cue that tells stamps from coloured print, and dropout for Vision's lines only [M]** (lane: segbench) (uses: light) (blocked-on: W50.v2-release) — Filed by W46.ocr-input-colour-dropout (2026-11-11, `ArchiveProcessor/segbench-results/ocr-colour-dropout.md`): on draft truth, dropout ties for Vision on the 40 stamp-class pages (+0.7) and loses for Gemini (-7.2); a probable Vision gain only on the 16 with a real coloured mark (+3.4, -0.1 to +8.4), which the colour cue cannot separate from coloured print (24 of its 40). Three things would settle it: the owner checks the gateway draft on the built sheet (`colour_dropout_sheet.py orient`, then `build`; rerun `ocr_colour_dropout.py images` first if the bench cache dropped the images; `fold` writes the truths the report prefers); a cue (or a Vision-only test) that keeps stamps and drops coloured print; and dropout used for Vision's line geometry only, the reader's text from raw (dropout's lines under the mark hold 7.9 words a line against raw's 5.0). Only if a route then wins on the stamps with no harm on the controls and the 96 does an R02 change go to the owner. Gateway spend so far $1.22 of the item's $2 cap. — **Measurement review pass 13 (2026-11-11, P13-4, `execution-plans/processing-review/measure-reviews/2026-11-11-2.md`):** the 60 pages' draft is Gemini 3.7 Flash itself (medium reasoning, both images), the scored Gemini arm's own model, so Gemini's arms are scored only on the owner-checked truth or on a drafter that is not the scored model; the ungated Gemini arm on the 96 was never read (the report's row copies raw) and is read before any row reports it; the Vision gain on the 16 is judged on the owner's sheet.
- [ ] **`W46.marks-detect-own` — a marks detector fine-tuned on our own pages [M]** (lane: segbench) (uses: light) (cluster: sherlock) (blocked-on: W50.v2-release) — **Reopened behind nice-to-have (owner, 2026-11-06 walkthrough); moved to 2.0 (2026-11-24)** after measurement review pass 11 (P11-1) found it was retired on a misread run condition: given the mark's own box as a second pass, LightOnOCR-3 4B reads 24 of 35 marks against 16 whole page and GLM-OCR 21 against 13 (W46.marks-two-pass: sign test p = 0.016 and 0.008 against an irrelevant second reading; the whole-page rerun identical on 32 of 32), and today's public YOLO11m boxes buy only 0-3, so a trained detector is the route to the gain. Plan as before: fine-tune the public YOLO11m (`$AGENT_STATE/artifacts/marks-detect-20261104/runs/public/best.pt`, kept for this item) on the 110 non-core marks-set pages with labels from the two drafters' box-matched agreement, saying first how many marks both missed; Sherlock size-and-necessity review before packing. Retired entry and its figures: SUITE_TODO_DONE.md, W46.marks-detect-own; results `ArchiveProcessor/segbench-results/marks-detect.md`, `mixed-route.md` "Two passes".

- [ ] **`W46.eval-new-models` — evaluate new document-reading models as they appear, starting with Inkling 2 Small [S per model]** (lane: segbench) (uses: light) (blocked-on: W46.nice-to-have) — Owner, 2026-11-06: "evaluate new models such as https://thinkingmachines.ai/news/inkling-2-small/". A standing item: when the gate opens, take the new open or gateway models that read page images and run each on both OCR sets (the owner's 96 truth pages and the 895 public pages, same settings, root CLAUDE.md "Both OCR sets, every time"), with a measurement card and ArchiveOCRBench updated. Add a candidate to this entry when one is noticed, with what it would take to run. Candidates: **Inkling 2 Small** (Thinking Machines, 2026-11-05): mixture-of-experts, 594B total and 17B active, with a 292M vision encoder; OCR is named as a strength, but no OCR benchmark is published (GDP.pdf 25.2%, CharXiv RQ 85.6%). Weights are closed for now and served only through Tinker, which is paid and falls under the paid-benchmarking hold (`W43.sweep`) and the $7 rule. Apache 2.0 weights are promised after safety testing; at that size the route is Sherlock (`(cluster: sherlock)` then), not the Mac. The first Inkling Small was tried on FarmShare through a llama.cpp GGUF build (`W43.inkling-farmshare`, DONE): pilot only, parked by the owner on 2026-10-20 with no score; read `execution-plans/inkling-farmshare-20261019.md` before planning a run.

- [ ] **`W46.gateway-google-models` — request newer Google models on the Stanford gateway and try them [S]** (lane: segbench) (uses: light,paid) (blocked-on: W46.gateway-budget-reset) — Owner, walkthrough 2026-11-13: the gateway replaces the Processor's direct Gemini key for all bench and review work (the key's AI Studio prepay is empty and will not be topped up). **1.0 on Dec 1 (`W46.gateway-budget-reset`, owner, 2026-11-24):** draft the access request for the newer Gemini models the gateway lacks (the owner sends it), then try each one the gateway serves on the rows the direct-key items would have measured (W46.date-route-pipeline-38's dating image pass, W46.seg-tabme-a04's A04 cell, the rotation set's Gemini arm), priced under the $7 rule.

**Filed by Phase 4 of the processing review (2026-11-06):** confirmations and extensions the rule notes asked for that change no route or default today; each names the note that raised it in `execution-plans/processing-review/13-stage-rules/`.

- [ ] **`W46.seg-adapt-second-material` — the LoRA continuation on a second material [M]** (lane: segbench) (uses: light) (blocked-on: W50.v2-release) (cluster: sherlock) — A material unlike Lincoln (an owner box pair), a second seed and internal-start truth; tests the start-recall rule and the "one material" label the owner accepted on 2026-11-06.

- [ ] **`W46.seg-enclosure-truth` — the cover-to-enclosure truth, classes A to D [M]** (lane: segbench) (uses: light) (blocked-on: W50.v2-release) — So enclosure handling is scored rather than inferred from two gaps (`10-gap-audit.md`, segmentation paragraph).

- [ ] **`W46.seg-mac-8gb` — the 2B beside the app on an 8 GB Mac [S]** (lane: segbench) (uses: light,machine) (blocked-on: W46.nice-to-have) — Whether the local segmenter fits an 8 GB Mac with the app running; the sheet shows `manual` there until measured.

- [ ] **`W46.ocr-mac-27b` — a 27B-class reader on a 32 and 64 GB Mac [S]** (lane: segbench) (uses: light,machine) (blocked-on: W46.nice-to-have) — Qwen3.6 27B 4-bit (8-bit at 64 GB) on the 96, both sets, with peak memory and seconds a page, for reading, the dating image pass and trace prompt, and the entity prompt; fills the upper Mac tiers, which pick from the 16 GB rows until then. Needs hardware the lab lacks (gap audit open question 4; the owner's 32 GB Mac only if necessary).

- [ ] **`W46.layout-by-reader-size` — whole page against regions by reader size and kind [S]** (lane: segbench) (uses: light,paid) (blocked-on: W50.v2-release) — E-layout test 3 on the 96 and L1, L3, L4, order-free scoring (about $0.40 paid arm); settles clippings and periodicals, which read whole today.

- [ ] **`W46.licence-freed-rest` — the licence-freed models W46.licence-freed-sweep did not pilot [S]** (lane: segbench) (uses: light,machine) (blocked-on: W50.v2-release) — Filed by W46.licence-freed-sweep, 2026-11-18 (`ArchiveProcessor/segbench-results/licence-freed-sweep.md` §"Not run"). LayoutLMv3 as a layout detector: its published head is a detectron2 PubLayNet fine-tune, and detectron2 has no Mac wheel, so pilot it off the Mac on L9 and the 96 against PP-DocLayoutV3 (layout_photo.py). The restorers DE-GAN, DocEnTr and DocDiff, as enh_ocr_input.py arms on the 96 for Apple Vision and one small reader, against raw. More readers on BLN600 (licence_sweep.py bln600, Vision 0.947 on 40 excerpts) if a newspaper reader pick is ever in question. Pilot first; run in full only what could change a pick. Pass 16 (P16-7), 2026-11-18: also the gated YOLOv8s signature detector itself (needs the owner to accept its Hugging Face terms; the Conditional DETR stand-in tied it, 2/45 against 6/45 at IoU 0.5, p 0.27), HunyuanOCR-1.5's 895-page half (the 96 ran, −0.038 behind LightOnOCR-3 4B 8-bit; the both-sets rule wants the half filed), and DocTr++ once its authors publish `DocTrP.pth` (the wrapper in `dewarp_extra_arms.py` is written and untested).

- [ ] **`W46.layout-photo-newspapers` — the staged route on photographed newspapers [S]** (lane: segbench) (uses: light) (blocked-on: W46.newspaper-photo-truth) — E-layout test 8: the quad correction then PP-DocLayoutV3 on photographed newspaper pages, for the quad rule.

- [ ] **`W46.place-print-pp-lines` — the writer over PP-OCRv6 det lines on typed pages [M]** (lane: segbench) (uses: light,machine) (blocked-on: W50.v2-release) — A row beside Vision's lines on the 40 typed pages, folded and unfolded, and the largest image side at which PP-OCRv6 det fits 16 GB.
- [ ] **`W46.place-line-ctc-writer` — a third hand-layer writer: one run per line, each word at its CTC position [M]** (lane: segbench) (uses: light,machine) — Owner, 2026-11-18, after reading W46.gutenocr-lines-ref: queue "the third design for the writer and relevant tests" behind W46.nice-to-have (moved to 2.0, 2026-11-24). The two writers scored so far split by collection. The lab writer (`place_functional`, one level run per line, font fitted, the app's SearchableWriter) beats one run per word by +8.4 (+1.2 to +15.1) on the owner's hands and loses −10.2 (−21.7 to +0.6) on Bentham (`place-hands-lines.md`). On the owner's hands the truth's own lines pass 85% (404/475) of drags through the lab writer and 34% through the word writer. GutenOCR-3B lines with the word writer pass 70.1 on Bentham against 39.8 for the shipped placer with the lab writer, and tie it on the owner's hands (43.6 against 44.0) (`licence-freed-sweep.md`). The design `place-hands-lines.md` names as not built: keep one run per line, so line-by-line selection still works, but place each word where the CTC alignment (`place_hands.py align … ctc-mccatmus`) put it, by horizontal scaling or spacing inside the run instead of one font fitted to the whole line. Build it as a third value of `place_hands_lines.WRITERS`, in the same Swift writer (`place_geom_writer.swift`) so the drag scorer reads it like the other two, and record how it degrades where CTC has no position for a word. Tests: (1) a headless proof on an invented page that the run is one per line, that each word's glyph box falls on its CTC span within a stated tolerance, and that PDFKit's line selection returns the line's text in order; (2) the line-pass table of `place-hands-lines.md` with three writers, same truth, same drag, paired page bootstrap (2,000 draws, seed 46), on both collections, for the shipped placer (blla + McCATMuS conf), GutenOCR-3B from its kept line cache (no rerun of the model) and PP-OCRv6 det lines on Bentham, with the truth and Qwen3.6-27B readings (the non-drafter); (3) the truth's own lines through the new writer, the ceiling beside 85% and 34%; (4) the shipped placer's 244 stored rows replay equal. A measurement card per root CLAUDE.md. A pick changes only if the new writer resolves ahead of the lab writer on the owner's hands without a resolved loss on Bentham; if it does, file the writer change for the app and the GutenOCR rescore as their own items. No money, no model calls beyond cached hypotheses. (blocked-on: W50.v2-release) — 2026-11-18: owner, 2026-11-18: Nice to Have; 2026-11-24: 2.0
- [ ] **`W46.truth-96-human-keyed` — the 96's reading truth keyed by two people from the image, with their differences settled [M-L]** (lane: segbench) (uses: light) — Owner, 2026-11-18: queue "the full work, with two readers and settling disagreement, on the 96 truth pages", behind W46.nice-to-have (moved to 2.0, 2026-11-24); the owner may have student workers do the reading. Why: the 96's truth was drafted by Claude Opus 5.5 and Gemini 3.8 Flash and adjudicated where they differed, so those families are scored against their own drafts (OCR-1, `ocr-truth-bias.md`). A truth keyed blind by people removes that. Size (counted 2026-11-18 from the truth files, numbers only): 99 pages, about 31,000 words; typewritten 50 pages (median 296 words), printed 28 (448), handwritten 19 (135), mixed 2 (111). At an assumed 25 words a minute for typed and printed and 10 for handwriting [I, not measured], one keying is about 24 hours, two about 48, plus the settling. Build: (1) transcription rules for a person, written from the conventions `ocr_truth.py` and the scorer already use (line breaks, hyphenation, struck and inserted text, illegible marks, tables as " | " cells, what normalisation the scorer does so readers need not), with a worked example per kind, on invented or public pages only; (2) a blind keying sheet in the style of the existing review sheets: one page image, zoomable, a text box, no model reading shown anywhere, saves to a file per reader and page, resumes across sittings, records each reader's time a page; (3) a compare step that aligns the two keyings word by word and writes their differences into the existing dispute sheet for a third person (the owner or a lead reader) to settle against the image; (4) the result as a new truth version beside the current one, never overwriting it, with the agreement rate between the two readers before settling (by kind) and the settling time. Then (5) rescore every saved reading of the 96 on the human truth with `ocr_rescore.py`, no new model call, and report how each route's NES moves against the drafted truth, the Gemini and Claude rows first; a ranking change is reported (no decision) for the owner, not applied to the app's picks. Tests: the sheet saves and resumes on invented pages; the compare step on two invented keyings with known differences; the rescore replays the current truth's figures exactly before the new one is used. The owner supplies the readers and decides their access to the pages; no Claude session reads the pages or the keyed text (code, aggregates and plans only). The readers' time a page, measured, replaces the assumed rates above in the report. (blocked-on: W50.v2-release) — 2026-11-18: owner, 2026-11-18: Nice to Have; 2026-11-24: 2.0

- [ ] **`W40.reader-prose-more` — more research and work to improve Copy Cleaned for Prose [M]** (lane: reader) (uses: build,model:4) (blocked-on: W46.nice-to-have) — Owner, 2026-11-12: "queue for the nice-to-have stage more research and work to improve Copy for Clean Prose". Start from W40.reader-prose-model's report (`ArchiveReader/scripts/prose-model/README.md`), whose truth was two open drafters' agreement on page 1 of 39 typed pages, which the owner did not check. Against it the rules find 6 of 20 headings and 8 of 16 list items, and their paragraph breaks have precision 0.47 (they split where both drafters see a continuation). The work: (1) a stronger truth for the structure labels (more pages, later pages, multi-column and handwritten-OCR pages, the disputed rows ruled through the gateway or by an owner sheet under the owner-sheet rules; never by Claude subagents); (2) the rules' own failures against it, fixed where a fix holds on a held-out split and passes the word guard; (3) the model routes the report's Scope left open, each only if it can beat the tuned rules: a Foundation Models adapter trained for the labels, a newer OS model, a small open model on the Mac. Every change keeps the word guard and the rules' instant copy; a model pass, if one wins, runs in the background and falls back to the rules. Report with a measurement card; the ArchiveReader/POTENTIAL_FEATURES.md reopen line moves here.


- [ ] **`W46.vision-27-rereads` — the enhancement, dewarp and dating Vision arms re-read on macOS 27.2 [S]** (lane: segbench) (uses: light,machine) (blocked-on: W50.v2-release) — So their cards lose the macOS 26.6 label (P8-1, P7-3); the within-OS deltas stand, the levels do not compare with 27.2.

- [ ] **`W46.enh-small-reader-power` — an OCR-input enhancement test with power for the small readers [S]** (lane: segbench) (uses: light) (blocked-on: W50.v2-release) — The minimum detectable paired effect for Qwen3-VL 8B, GLM-OCR and PP-OCRv6 from `enh-ocr-input-pages.csv` (ENH-3: about 5 NES today), then the arms most likely to help on enough pages to exclude it; the pages Vision reads as empty and the glare lead (6 pages) folded in. **Owner, 2026-11-19 (call 15):** DocRes cleaning on glare pages stays here at nice-to-have (moved to 2.0, 2026-11-24); when the larger glare test has figures, ask him again whether to offer it (call 13).

- [ ] **`W46.marks-truth-independent` — an independent marks truth and a boxes test [M]** (lane: segbench) (uses: light) (blocked-on: W50.v2-release, W46.marks-sampling-support) — A second owner draw of pages the pre-flag did not choose (MRK-1), the 8 excluded core pages resolved, and a test of a VLM that returns boxes with its text against the owner's mark boxes; any detector ranking waits on it.

- [ ] **`W46.capture-warning` — a capture warning calibrated on real captures [M]** (lane: segbench) (uses: light) (blocked-on: W50.v2-release) — Real phone captures with known truth (L-capture test 10, about 40 minutes of the owner's time, or SmartDoc-QA), sharpness in Vision word boxes with a held-out cut; intermediate ladder rungs for a pixel floor and the framing check (quad against raw; 20 capture tags spot-checked) folded in. Gates any live warning in the companions. **Owner, 2026-11-19 (call 15):** "Keep this in Nice to Have." Moved to 2.0 (2026-11-24). When the warning is calibrated, ask him again whether to offer it (call 13).
- [ ] **`W47.wh-cascade-disagree` — a larger test of the two-reader disagreement trigger for the cascade [M]** (lane: segbench) (uses: light,paid) (blocked-on: W50.v2-release) — Owner, 2026-11-19 (call 15): "Put this in Nice to Have" (moved to 2.0, 2026-11-24). The disagreement trigger on enough unseen pages to show a consistent gain or none, with log-probability as a second trigger where a route returns it (`10-kinds-and-routing.md` l.50, `ocr-logprob.md`). It ends by asking the owner in the Daemon Report (needs you) with the new figures and what the user would gain or lose (call 13); nothing is released or withheld by the item itself.

- [ ] **`W46.kinds-mixed-truth` — a body-text truth on mixed pages, and the document prior [M]** (lane: segbench) (uses: light) (blocked-on: W50.v2-release) — A body-text score on mixed pages drawn at random under the owner's cut, not by a pre-flag (an owner sheet); and whether a document prior fixes any of the 16 under-floor minority pages.

- [ ] **`W46.ocr-churro-overlap` — CHURRO-DS overlap with the public set [XS]** (lane: segbench) (uses: light) (blocked-on: W46.nice-to-have) — Page-level image-hash overlap between CHURRO-DS's test pages and the 895 (OCR-15); the Gemini and Churro public rows carry the count.
