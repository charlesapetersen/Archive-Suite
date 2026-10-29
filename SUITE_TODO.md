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
- `processing-review/` — **PLANNED 2026-10-20 (W46, Archive Processor)**: a review of segmentation, dating, OCR,
  enhancement, layout, text placement and entities against the current literature and model releases, for each user
  profile (laptop, cheap API, premium API, cluster, coding agent), ending in the processing work queue. `00-plan.md`;
  progress in `STATE.md`. Every pre-review processing item waits on `W46.review-done`; the Phase 3 experiments
  (`W46.*`, filed 2026-10-21) are in §"Document processing review — W46".
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
`W46.mixed-def-owner-ok`, `W46.seg-boxes-named-ok`, `W46.seg-boxes-owner-ok`, `W46.marks-core-owner-ok`,
`W46.rta-gold-ok`, `W46.macos27-ok`, `W46.date-audit-owner-ok`.

- [ ] **W46.ocr-regions-cells — L4 table-region-only and per-cell reading [M]** (lane: segbench) (uses: light) (cluster: sherlock) (needs: owner) (blocked-on: W46.ocr-regions) — The unmeasured part of gap-audit §5 item 7: compare table-region crops and cell crops with the page-level results, using the forms benchmark's correct split and frozen region/cell truth. Baseline ce0aa207, `corpus/regions_cluster.py::crops_for` has detector-region and tile arms only; the collected pack has no cell boxes or per-cell truth. Prepare a bounded pilot and Sherlock necessity/size review before handoff; include the 96's tables as well as the relevant L4 slice. Results and limits: `ArchiveProcessor/segbench-results/bench-corpus/regions-20261021.md`.
  Prepared 2026-10-25: frozen 9-page/72-field bank; only 2 capability pages / 40 requests / 3 jobs proposed. Owner-attended Sherlock submission and collection remain. Handoff and necessity review: `execution-plans/items/W46.ocr-regions-cells.md`.
- [ ] **`W46.fix-marks-set-draft` — draft the 150-page marks set and the owner's 40-page core [M]** (lane: segbench) (uses: light,paid) (cluster: sherlock) (needs: owner) (blocked-on: W46.cluster-waves, W46.mixed-def-owner-ok) — VLM pre-flag over a few thousand corpus pages, 150 chosen across the five collections, boxes and classes drafted by open models, Azure Read line flags on 50 pages (about $0.08, personal key); the 40-page core goes to the owner (gate W46.marks-core-owner-ok, 6-7 h, STATE Phase 2 decision 2), the rest is model-audited. detail: execution-plans/processing-review/10-gap-audit.md §5 item 8 Starts with `mixed_def.py score --answers ~/Library/Caches/ArchiveSuiteRehearsal/mixed-def/sheet/answers.json` (W46.fix-marks-set): the owner's cut and the corpus share it gives, in segbench-results/mixed-def-score.json.
  Progress and remaining work: `execution-plans/items/W46.fix-marks-set-draft.md`.
- [ ] **`W46.fix-marks-set-score` — fold the owner's marks core into the set and freeze it [S]** (lane: segbench) (uses: light) (blocked-on: W46.marks-core-owner-ok) — Freeze the marks set before any new call; it serves the mark-survival check, the order test on annotated pages and the mixed-page routing test. detail: execution-plans/processing-review/10-gap-audit.md §5 item 8
- [ ] **`W46.enh-ocr-input-marks` — the enhancement methods on the marks set, with the mark-region ink check [S]** (lane: segbench) (uses: build) (cluster: sherlock) (blocked-on: W46.cluster-waves, W46.enh-ocr-input, W46.fix-marks-set-score) — The marks arm of W46.enh-ocr-input: whether any method may touch the reading copy. detail: execution-plans/processing-review/10-gap-audit.md §5 item 11
- [ ] **`W46.date-traceable-paid` — Gemini on the class C and D residue [S]** (lane: segbench) (uses: light,paid) (blocked-on: W46.date-traceable, W46.gateway-models-ok) — The gateway arm of W46.date-traceable, three variants, about $1.60; the stated-confidence rerun dropped or in batch. detail: execution-plans/processing-review/10-gap-audit.md §5 item 14
- [ ] **`W46.date-enclosure-paid` — Gemini as relation classifier, with images [S]** (lane: segbench) (uses: light,paid) (blocked-on: W46.date-enclosure, W46.gateway-models-ok) — The gateway arm of W46.date-enclosure, about 150 pages, $1.50-2.50. detail: execution-plans/processing-review/10-gap-audit.md §5 item 15
- [ ] **`W46.date-image` — dates on the page that are not in the text [M]** (lane: segbench) (uses: light,model:10) (cluster: sherlock) (blocked-on: W46.cluster-waves, W46.fix-date-truth-score) — The 131 unprinted-year documents, the 21 none-class first, through Qwen3-VL 235B (cluster) and Qwen3-VL 8B (Mac) with and without the ABBYY text; look-alike retrieval; the handwritten-date reader only if many dates are handwritten. detail: execution-plans/processing-review/10-gap-audit.md §5 item 16
- [ ] **`W46.date-image-paid` — Gemini on the unprinted-year documents, and the typeface probe [S]** (lane: segbench) (uses: light,paid) (blocked-on: W46.date-image, W46.gateway-models-ok) — The gateway arm of W46.date-image, 131 documents by two variants, about $1.50-2.50, plus the typeface probe under $0.20. detail: execution-plans/processing-review/10-gap-audit.md §5 item 16
- [ ] **`W46.layout-photo` — whether DocLayout-YOLO collapses on our photographs [M]** (lane: segbench) (uses: build) (cluster: sherlock) (blocked-on: W46.cluster-waves, W46.fix-ocr-scorers, W46.enh-dewarp) — Four detectors feeding GLM-OCR on the 96, L9 and L4, Real5's warp and skew folders, and the handwriting strata; no paid arm. detail: execution-plans/processing-review/10-gap-audit.md §5 item 17
- [ ] **`W46.ocr-new-open` — the untested open readers under about 10B [M]** (lane: segbench) (uses: light,machine) (cluster: sherlock) (blocked-on: W46.cluster-waves) — Unlimited-OCR, OvisOCR2, Xiaomi-OCR-0, TeleOCR, PaddleOCR-VL-1.6, Qwen3.8-27B, MiniCPM-V 4.7, Nemotron-Parse 2.0, granite-docling, dots.ocr, Chandra-2, Churro-3B on the 895 and the 96 (both sets), Mac seconds and memory for MLX builds, boxes saved for W46.place-print; two sessions, one per model group. detail: execution-plans/processing-review/10-gap-audit.md §5 item 18 — Sherlock results collected 2026-10-24; Mac scoring remains (execution-plans/items/W46.ocr-new-open.md).
- [ ] **`W46.ocr-new-open-sherlock` — Infinity-Parser2-Pro 35B on the 895 and the 96 [S]** (lane: segbench) (uses: light) (cluster: sherlock) (blocked-on: W46.cluster-waves, W46.sherlock-ok, W46.ocr-new-open) — The Sherlock arm of W46.ocr-new-open; it may fit FarmShare on two L40S, so a session may test that first and run it there. detail: execution-plans/processing-review/10-gap-audit.md §5 item 18
- [ ] **`W46.ocr-ppocrv6-hands` — kraken PP-OCRv6 as the laptop handwriting route [M]** (lane: segbench) (uses: light,machine) (cluster: sherlock) (blocked-on: W46.cluster-waves, W46.fix-place-truth, W46.fix-place-truth-fu) — On blla and Vision lines over L1-L3 and the owner's hands, fine-tuned on 20-240 corrected lines of one hand, MPS against CPU; Qwen few-line prompting on the cluster. detail: execution-plans/processing-review/10-gap-audit.md §5 item 19
- [ ] **`W46.ocr-ppocrv6-hands-paid` — Gemini prompted with a hand's corrected lines [S]** (lane: segbench) (uses: light,paid) (blocked-on: W46.ocr-ppocrv6-hands, W46.gateway-models-ok) — The gateway arm of W46.ocr-ppocrv6-hands, about 60 pages by three conditions, under $1. detail: execution-plans/processing-review/10-gap-audit.md §5 item 19
- [ ] **`W46.kit-gate` — the kit's held-out gate and the teacher audit [M]** (lane: segbench,processor) (uses: light,build) (cluster: sherlock) (blocked-on: W46.cluster-waves, W46.fix-seg-scorers) — train_seg.py check, the bootstrap of the held-out set size, the manifest, LocalSegmenter refusing a model without an anchor score, the teacher split on the test boxes and the 80-gap checkpack (owner answers already saved, label-clean-owner-answers.csv), an end-to-end kit dry run. detail: execution-plans/processing-review/10-gap-audit.md §5 item 20 Folds in W41.seg-label-clean-fu1 (owner, 2026-10-21). — Plan-route arm held for the gateway (owner, 2026-10-21; CLAUDE.md "Plan routes wait for the gateway").
- [ ] **`W46.place-print` — placement on print, measured [M]** (lane: segbench) (uses: build) (blocked-on: W46.fix-place-truth, W46.ocr-new-open) — Vision word boxes and the saved readings placed through alignedReading, the box-emitting readers, three PDF writings on four viewers, veraPDF; the owner's 20-minute Acrobat check is filed by this item with plan-edit block when ready; Gemini line boxes only if the open models fail, then as W46.place-print-paid behind the gateway gate. detail: execution-plans/processing-review/10-gap-audit.md §5 item 21
- [ ] **`W46.place-geom` — whether a straightened reading copy, made after OCR, makes the text layer easier to select [M]** (lane: segbench) (uses: build) (blocked-on: W46.place-print) — Owner, 2026-10-28. W46.enh-dewarp and W46.enh-dewarp-paid settled that no crop or dewarp helps OCR, so OCR stays on the raw photograph and the layer on the unaltered image; they did not ask whether the user can select text better. What is known: carried back through the saved grid, a straight run on a curled original misses its line by a UVDoc sagitta of 4.8 px median, 14.0 px p95 (7% of lines more than a quarter of a line height); the quad's homography is exact (sagitta 0). Deskew alone (rotation) was never a separate arm. Test, after OCR on the raw image: arms raw (today's layer), deskew only, Apple quad plus perspective, UVDoc after the quad; each arm's words carried forward through its saved homography or lattice and the layer written on that arm's image. Score on the skew-, perspective- and curl-tagged pages of the 96, Real5's warp and skew folders, and the placement truth set mapped the same way, with W46.place-print's three scores and its viewer harness: line-by-line drag selection share, Find highlight overlap, and words lost at the crop edge (quad cut 44 truth words on 11 pages, UVDoc 429 on 45, which the reading-copy rule forbids unless recovered). Decides whether a straighten-after-OCR option for the reading copy is offered, and for which tags. Free, on the Mac. detail: segbench-results/enh-dewarp.md §Line boxes carried back; execution-plans/processing-review/F-placement.md §6.5
- [ ] **`W46.marks-detect` — whether marks can be found and read [M]** (lane: segbench) (uses: light) (cluster: sherlock) (blocked-on: W46.cluster-waves, W46.fix-marks-set-score) — A YOLO11m on AnnoPage, SignverOD and synthetic crops (trained on the cluster, Core ML export) against Qwen3.6 27B boxes and the signature detector; inline region tags from Claude through the plan at $0. detail: execution-plans/processing-review/10-gap-audit.md §5 item 24 — Plan-route arm held for the gateway (owner, 2026-10-21; CLAUDE.md "Plan routes wait for the gateway").
- [ ] **`W46.marks-detect-paid` — Gemini boxes and inline tags on the marks set [S]** (lane: segbench) (uses: light,paid) (blocked-on: W46.marks-detect, W46.gateway-models-ok) — The gateway arm of W46.marks-detect, about $1.55. detail: execution-plans/processing-review/10-gap-audit.md §5 item 24
- [ ] **`W46.mixed-route` — whole page against region-routed reading on mixed pages [M]** (lane: segbench) (uses: build) (cluster: sherlock) (blocked-on: W46.cluster-waves, W46.fix-marks-set-score, W46.marks-detect) — Open readers and Vision whole page against typed and handwritten regions; per-line kind from Vision against the Azure flags W46.fix-marks-set-draft saved; marks in the layer checked with the Reader's Find and Spotlight. detail: execution-plans/processing-review/10-gap-audit.md §5 item 25
- [ ] **`W46.mixed-route-paid` — Gemini on mixed pages, whole and by region [S]** (lane: segbench) (uses: light,paid) (blocked-on: W46.mixed-route, W46.gateway-models-ok) — The gateway arm of W46.mixed-route, about $1.70. detail: execution-plans/processing-review/10-gap-audit.md §5 item 25
- [ ] **`W46.mixed-route-bands` — mixed-page routing by handwriting amount, with cost and time [M]** (lane: segbench) (uses: light) (blocked-on: W46.mixed-route) — Owner, 2026-10-28: report W46.mixed-route (and W46.mixed-route-paid once it has run) by the four handwriting bands in ArchiveProcessor/segbench-results/mixed-def-score.md: signature, initials or date only; under about 10 words; 10-29 words; 30 or more. Per band and route: body NES of the typed text, the marks transcription rate, and seconds and cost per page. Say whether sending signature-only or few-correction pages through the handwriting reader lowers typed-text accuracy or adds cost or time, and recommend whether users get a choice (for example: read signatures and marginal handwriting, yes/no) or a note of the trade-off; a user-facing setting is filed as its own item. W46.fix-marks-set-draft must draft enough pages in each band to score them. detail: ArchiveProcessor/segbench-results/mixed-def-score.md
- [ ] **`W46.kind-atrium` — ATRIUM's page classifier against our kind classifier [S]** (lane: segbench) (uses: light,machine) — Zero-shot on the 144, the 96, the 895 and the 2,000; a small head on its embeddings; seconds and memory on the M3 Pro; if the Mac pass is too slow, the 2,895-page pass waits for W46.cluster-waves. detail: execution-plans/processing-review/10-gap-audit.md §5 item 26
- [ ] **`W46.capture-ladder` — which capture defects cost which reader how much, reduced to FarmShare scale [M]** (lane: segbench) (uses: build) (cluster: sherlock) (blocked-on: W46.cluster-waves, W46.fix-ocr-scorers, W46.fix-capture-tags) — Augraphy and OpenCV defects on the 96 at every setting and a two-severity subset of the 895 for the cheap readers, a 100-page 27B sample, capture-time signals, SmartDoc-QA letters; two sessions; the full 895 ladder is W46.capture-ladder-sherlock. detail: execution-plans/processing-review/10-gap-audit.md §5 item 27
- [ ] **`W46.capture-ladder-paid` — Gemini on the worst defects, and its own quality verdict [S]** (lane: segbench) (uses: light,paid) (blocked-on: W46.capture-ladder, W46.gateway-models-ok) — The gateway arm of W46.capture-ladder, about $2.00. detail: execution-plans/processing-review/10-gap-audit.md §5 item 27
- [ ] **`W46.layout-order-train` — Orli zero-shot, kraken `rotrain` and an Orli fine-tune, only if the owner pages need them [S]** (lane: segbench) (uses: light) (cluster: sherlock) (blocked-on: W46.layout-order-marks) — The trained-orderer and Orli arms of W46.layout-order, held back because geometry already orders public print (the app region sort 0.991, rows-first XY-cut 0.990, PP-DocLayoutV3 native 0.999 on the multi-column benchmark pages). Decide from W46.layout-order-marks: if no geometric or native order reaches tau 0.95 on the 30 annotated owner pages, prepare the Sherlock pack (Orli bf16, kraken 7 plugin, weights Zenodo 10.5281/zenodo.20558179; rotrain and the Orli fine-tune on 20-50 owner-corrected PAGE-XML pages, scored on held-out pages with layout_order.py); otherwise move it behind W46.nice-to-have. Orli could not be tried on the Mac unattended (no network installs). detail: ArchiveProcessor/segbench-results/layout-order.md
- [ ] **`W46.layout-order-marks` — the ordering stage on 30 annotated marks-set pages [S]** (lane: segbench) (uses: light) (cluster: sherlock) (blocked-on: W46.cluster-waves, W46.layout-order, W46.fix-marks-set-score) — The annotated-page arm of W46.layout-order. detail: execution-plans/processing-review/10-gap-audit.md §5 item 28
- [ ] **`W46.layout-order-paid` — Gemini asked for boxes in reading order [S]** (lane: segbench) (uses: light,paid) (blocked-on: W46.layout-order, W46.layout-order-marks, W46.gateway-models-ok) — The gateway arm of W46.layout-order on about 85 pages, under $0.50. detail: execution-plans/processing-review/10-gap-audit.md §5 item 28
- [ ] **`W46.truth-edits` — two truth corrections found against the JPEG originals [XS]** (lane: segbench) (uses: light) (blocked-on: W46.truth-edits-owner-ok) — Found by W46.truth-jpeg-upgrade's check of the 15 swapped pages (13 hold): p088's handwritten "don't" is in the truth twice (the page has it once; drop the trailing "don t"); p025's "San Francisco 4, California" may be "6" (a 6-like shape on the original, ambiguous on the PDF image). Not applied: the truth is the owner's adjudication, and its hash is frozen in every panel manifest (ocr_panel.manifest() refuses a changed truth), so applying them means re-freezing those manifests and rescoring every route on the two pages. Owner: apply p088, p025, both or neither?
- [ ] **`W46.ocr-postcorrect-paid` — Gemini as image-grounded corrector [S]** (lane: segbench) (uses: light,paid) (blocked-on: W46.ocr-postcorrect, W46.gateway-models-ok) — The gateway arm of W46.ocr-postcorrect, about 150 pages, under $1. detail: execution-plans/processing-review/10-gap-audit.md §5 item 29
- [ ] **`W46.ent-score` — what the entity fields the app extracts are worth [S]** (lane: segbench) (uses: light) (blocked-on: W46.fix-ent-truth) — Cached replies, GLiNER2.5 and NLTagger scored exact, overlap and edit-distance-2; names found nowhere in the prompt classified with the images, doubtful ones audited by a second model family. detail: execution-plans/processing-review/10-gap-audit.md §5 item 31 — Plan-route arm held for the gateway (owner, 2026-10-21; CLAUDE.md "Plan routes wait for the gateway").
- [ ] **`W46.ent-score-paid` — Gemini with a dedicated entity prompt [S]** (lane: segbench) (uses: light,paid) (blocked-on: W46.ent-score, W46.gateway-models-ok) — The gateway arm of W46.ent-score, about 150 documents, about $0.60. detail: execution-plans/processing-review/10-gap-audit.md §5 item 31
- [ ] **`W46.ent-robust` — at what OCR error level entity extraction stops paying [M]** (lane: segbench) (uses: light) (cluster: sherlock) (blocked-on: W46.cluster-waves, W46.ent-score, W46.fix-date-truth-score) — Extractors on truth text and each route's text by kind, G17's Business Letters through the pinned 27B and Claude through the plan, the Wikidata office probe for dating. detail: execution-plans/processing-review/10-gap-audit.md §5 item 32 — Plan-route arm held for the gateway (owner, 2026-10-21; CLAUDE.md "Plan routes wait for the gateway").
- [ ] **`W46.ent-robust-paid` — Gemini on the scans and on G17 [S]** (lane: segbench) (uses: light,paid) (blocked-on: W46.ent-robust, W46.gateway-models-ok) — The gateway arm of W46.ent-robust, about $0.50. detail: execution-plans/processing-review/10-gap-audit.md §5 item 32
- [ ] **`W46.seg-context` — what collection facts buy the window and tagging prompts [M]** (lane: segbench) (uses: light) (cluster: sherlock) (blocked-on: W46.cluster-waves, W46.fix-seg-scorers, W46.seg-lincoln-cloud) — A collection block for the 2B student and the 27B teacher on CREST, Lincoln and the test boxes; a 2B LoRA with the block in training. detail: execution-plans/processing-review/10-gap-audit.md §5 item 33
- [ ] **`W46.seg-context-paid` — Gemini with and without the collection block, in batch [S]** (lane: segbench) (uses: light,paid) (blocked-on: W46.seg-context, W46.gateway-models-ok) — The gateway arm of W46.seg-context, batch only as scoped (about $1.40; $2.70 at list). detail: execution-plans/processing-review/10-gap-audit.md §5 item 33
- [ ] **`W46.seg-tabme-paid` — Gemini on TABME++ at A04's settings [S]** (lane: segbench) (uses: light,paid) (blocked-on: W46.seg-tabme, W46.gateway-models-ok) — The paid arm of W46.seg-tabme: Gemini 3.1 Flash-Lite text-only at K=7 (about $1.09) and the 500-page image arm (about $1.80); the K=2 arm dropped. detail: execution-plans/processing-review/10-gap-audit.md §5 item 34
- [ ] **`W46.kit-mac-lora` — whether the kit can train on a Mac at all [S]** (lane: segbench) (uses: machine) (cluster: sherlock) (blocked-on: W46.cluster-waves) — mlx_vlm.lora on the shipped 2B base, peak memory and seconds a step on the 18 GB M3 Pro; adapters against the merged FarmShare 2B; the 32 GB arm only if the owner says such a Mac exists (audit owner question 4). detail: execution-plans/processing-review/10-gap-audit.md §5 item 35
- [ ] **`W46.fix-seg-boxes` — draft the truth for two new locked segmentation boxes [S]** (lane: segbench) (uses: light) (blocked-on: W46.seg-boxes-named-ok) — One clippings-heavy and one handwritten box, named by the owner; boundaries from the per-document folders, truth by the 02-truth-check.md procedure; the ruling sheet of teacher-tag disagreements for the owner (gate W46.seg-boxes-owner-ok, about an hour a box, offered only when the timing rule allows). detail: execution-plans/processing-review/10-gap-audit.md §5 item 36
- [ ] **`W46.fix-seg-boxes-lock` — fold in the owner's rulings and freeze the two boxes [S]** (lane: segbench) (uses: light) (blocked-on: W46.seg-boxes-owner-ok) — Freeze both boxes before any new call against them. detail: execution-plans/processing-review/10-gap-audit.md §5 item 36
- [ ] **`W46.seg-window-modality` — window size and text-only windows on photographs, open arms [M]** (lane: segbench) (uses: light) (cluster: sherlock) (blocked-on: W46.cluster-waves, W46.fix-seg-scorers) — K in 3, 5, 7, 10 and whole folder, text-only against image-plus-text, the 2B on the development boxes; majority vote for the 2B, 4B and teacher. detail: execution-plans/processing-review/10-gap-audit.md §5 item 37
- [ ] **`W46.seg-window-modality-paid` — the full 551-page Gemini window sweep (owner-approved over $3) [S]** (lane: segbench) (uses: light,paid) (blocked-on: W46.seg-window-modality, W46.gateway-models-ok) — Owner approved 2026-10-21 at about $8 list, $4 batch (STATE Phase 2 decision 6): item cap $8.00, ITEM_CAP_USD 8.00 in the runner, batch where the route offers it; past the cap, ask first. detail: execution-plans/processing-review/10-gap-audit.md §5 item 37
- [ ] **`W46.r6-spot` — vendor layout, HTR and splitter spot checks with personal keys [S]** (lane: segbench) (uses: light,paid) — Azure Document Intelligence and Textract on 25 of the 96, Transkribus if credits exist, a price read of the custom splitters, one vendor date entity; about $1.50, personal keys (root CLAUDE.md: what the gateway cannot serve). detail: execution-plans/processing-review/10-gap-audit.md §5 item 39
- [ ] **`W46.r1-foundation` — the macOS 27 on-device model as a free first reader [S]** (lane: segbench) (uses: build) (blocked-on: W46.macos27-ok) — Image attachments on the 96 and 100 of the 895, text-only segmentation on one development box; needs a macOS 27 Mac with Apple Intelligence. detail: execution-plans/processing-review/10-gap-audit.md §5 item 40

## Archival containers — W47 (owner, 2026-10-21)

Repository, place, collection title, collection number, accession, series, container, folder and folder title for
every item, worked out from label photos (Route A) or a labelled folder tree (Route B), and corrected in one place,
the Reader. Every field is optional. The owner's corpus is one test case, not the design target: the owner asked
that the two common routes work for any user. The assessment, the measured corpus figures, the field list with its
Zotero mapping and the design are in `execution-plans/containers/00-plan.md`. Approved and filed 2026-10-21 (owner:
"file as drafted", with Accession and Series as fields and the two routes). This reverses the 2026-07-15 ruling
that removed the Box > Folder > Document hierarchy as out of scope. Owner gates in the plan's HOLD QUEUE:
`W47.ct-truth-owner-ok`, `W47.ct-design-ok`. No app code is written before `W47.ct-design-ok`.

- [ ] **`W47.ct-truth` — the label truth set, the owner's disagreement sheet and a folder-tree test set [S]** (lane: segbench) (uses: light) — About 120 box and 120 folder marker photos from the corpus, stratified by repository (read-only; copies only), each with the nine fields drafted by two open models and marked where they disagree; the owner's sheet shows only the disagreements, with a box around each label region (root CLAUDE.md, owner check sheets), for gate W47.ct-truth-owner-ok, offered only when the timing rule allows. Also a Route B set: about 30 synthetic folder trees in the conventions the plan names (Repository/Collection/Box N/Folder M, B17F8, "Box 10 - Folder 3", filenames carrying box and folder, workflow levels to skip) with their expected fields, plus the owner's own tree's level-1 and level-2 names. detail: execution-plans/containers/00-plan.md
- [ ] **`W47.ct-read` — reading the labels and the trees, scored per field [M]** (lane: segbench) (uses: light,machine) (blocked-on: W47.ct-truth-owner-ok) — On the truth set, per field: the existing text layer plus a parser, Apple Vision accurate mode plus the parser, and one or two open vision models on the Mac. The Route B name patterns scored on the tree set. Carry-forward measured on the corpus (box-number gaps and reversals within a directory, so how often a box change went unphotographed), and how often Purple is a folder label rather than a divider or document start. No plan-route arm (root CLAUDE.md, plan routes wait for the gateway). Ends with the recommended route per field and the price of reading the corpus's ~4,500 markers. detail: execution-plans/containers/00-plan.md
- [ ] **`W47.ct-read-paid` — the gateway arm of the label read [S]** (lane: segbench) (uses: light,paid) (blocked-on: W47.ct-read, W46.gateway-models-ok) — The cheapest capable gateway vision model on the same truth set, under $0.50. detail: execution-plans/containers/00-plan.md
- [ ] **`W47.ct-spec` — SPEC/containers.md and the ArchiveCore model [M · Tier-2]** (lane: suite) (uses: build) (blocked-on: W47.ct-design-ok) — The run record (the nine fields, each with its source: path, label or user, and confidence), the inheritance rule (folder run inside box run inside collection; a new box clears folder fields), the per-directory container file (name, JSON format, never Spotlight content), the Route B level map stored per root, the CSL mapping (archive, archive-place, archive_collection, call-number, archive_location; accession and series in Extra). New files only; no existing file rewritten. detail: execution-plans/containers/00-plan.md
- [ ] **`W47.ct-infer` — the inference in ArchiveCore, both routes [M]** (lane: suite) (uses: build) (blocked-on: W47.ct-spec) — Route A carry-forward from markers (colour label, Box/Folder tag or classification), Route B from the level map and the name patterns in directory and file names, merging by field with user over label over path, and warnings for disagreements, reversals and long unmarked runs. Tests on scratch fixtures for both routes and the mixed case. detail: execution-plans/containers/00-plan.md
- [ ] **`W47.ct-reader-view` — the Container column and facets in the Reader [M]** (lane: reader) (uses: build,vm) (blocked-on: W47.ct-infer) — A Container column and facets for repository, collection, accession, series and container, read from the container files and the inference; the Route B level-map sheet when a root is first added. detail: execution-plans/containers/00-plan.md
- [ ] **`W47.ct-reader-edit` — the one place to edit: the container inspector [M · Tier-2]** (lane: reader) (uses: build,vm) (blocked-on: W47.ct-reader-view) — An inspector that edits a run (every item under it follows), "set for selection" that splits runs, and the warnings list. Writes only the container file, a new write class under the Core Directive; tested on scratch copies. detail: execution-plans/containers/00-plan.md
- [ ] **`W47.ct-processor-capture` — Route A at capture: read the label, confirm on the card [M · Tier-2]** (lane: processor) (uses: build) (blocked-on: W47.ct-infer, W46.review-done) — Read box and folder labels on W47.ct-read's recommended route in Live Capture and Process Files, show the parsed fields on the capture card for correction, write the container file at finalize; the collection-name prompt keeps the numbers it now drops. detail: execution-plans/containers/00-plan.md
- [ ] **`W47.ct-processor-intake` — Route B in Process Files: nested folders read with the level map [M]** (lane: processor) (uses: build) (blocked-on: W47.ct-processor-capture) — Process Files reads a dropped tree recursively instead of flat, applies the level map (pre-filled, confirmed once), and writes the container file with the output. detail: execution-plans/containers/00-plan.md
- [ ] **`W47.ct-backfill` — read an existing corpus's markers and propose runs for review [M]** (lane: processor) (uses: build,paid) (blocked-on: W47.ct-processor-capture, W47.ct-reader-edit) — A command over a chosen folder that reads its marker photos and folder names and proposes runs, accepted directory by directory before any container file is written. Built and tested on scratch copies; running it on the owner's real corpus is the owner's own action from the app. A paid read over $3 asks first. detail: execution-plans/containers/00-plan.md
- [ ] **`W47.item-fields-truth` — title, publication and type fields: a truth set and how well they are filled now [S]** (lane: segbench) (uses: light) (blocked-on: W46.fix-ent-truth) — Extends W46's entity truth set rather than building a second one (owner, 2026-10-21). Adds about 60 clippings, articles and reports to its letters, memos and telegrams, drafted by two open model families and model-adjudicated, and labels on every document: title (a stated title or headline; for a letter, none, since Zotero composes one), byline, publication name, publication date, document type as the Zotero item type (letter, newspaper or magazine article, memo or report as document or manuscript, telegram, clipping, photograph) and recipient place. Scores what the current tagging call and the JSON sidecar already give (publication_name, format, author and recipient locations) per field: fill rate, exact and edit-distance-2 match, wrong-when-filled; plus one cheap open extractor as a comparison. No plan-route arm (root CLAUDE.md). Ends with which fields are reliable enough to fill and which should stay empty. detail: execution-plans/containers/00-plan.md "Item fields"
- [ ] **`W47.item-fields-build` — extract a title for every document and fill the reliable item fields [M · Tier-2]** (lane: processor) (uses: build) (blocked-on: W47.item-fields-truth, W47.ct-design-ok, W46.review-done) — A title field in the tagging output, the JSON sidecar and the page-2 header (SPEC/tag-format.md and ArchiveCore together, Tier-2), and the other fields W47.item-fields-truth found reliable; a field below its bar is left empty rather than guessed. W47.ct-zotero then exports them. detail: execution-plans/containers/00-plan.md "Item fields"
- [ ] **`W47.ct-zotero` — the container in Notes source blocks, and the export to Zotero with all gathered metadata [M]** (lane: notes,reader) (uses: build) (blocked-on: W47.ct-infer) — Notes source blocks show the archival location. "Copy for Zotero" from a Notes source and "Export to Zotero" from a Reader selection write CSL-JSON carrying everything gathered for the item, not only its location (owner, 2026-10-21): the container fields (archive, archive-place, archive_collection, call-number, archive_location; accession and series in Extra) and the item fields the Processor already extracts (SPEC page-2 header, the JSON sidecar, the date tags): title, date (issued, with uncertainty), author, recipient, type mapped to a Zotero type (letter, newspaper or magazine article, memo or report as document or manuscript, telegram, photograph, clipping), place (author and recipient locations; the item's place where the Zotero type has one, otherwise Extra), publication name (container-title), and subjects as tags. A field the type cannot hold goes in Extra rather than being dropped; nothing invented for an empty field. Items from a corpus that predates the apps carry only what their tags and folders give. CSL-JSON file import is the route; Zotero's local API only where Zotero 10+ is present. Tested by importing the export into a scratch Zotero library and reading the fields back. Formats no citations. detail: execution-plans/containers/00-plan.md

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

- [ ] **`W41.app-local-seg-publish` — publish the corpus-trained 2B's weights to Hugging Face — OWNER action [XS · ~0.1 session]** (lane: processor) (uses: light) (blocked-on: W41.app-local-seg-publish-owner-ok, W46.review-done). From W41.app-local-seg (shipped): the app's `local` approach downloads `charlesapetersen/archive-suite-seg-qwen3.5-2b-8bit` by default (`LocalSegmenter.defaultModelID`), and until that repository exists a run stops at its warm-up with the server's reason. Publishing was approved on 2026-10-17; it needs the owner's Hugging Face account. The owner runs `ArchiveProcessor/scripts/segbench/publish-seg-model/publish.sh [repo]` signed in (`hf auth login`); the model card is that folder's README.md. If the repository name differs, a session then changes `LocalSegmenter.defaultModelID` (and the script's default) to match. **Owner walkthrough, 2026-10-18:** keep `charlesapetersen/archive-suite-seg-qwen3.5-2b-8bit`; the name is settled. Upload remains an owner action and the publication gate stays open until the weights are uploaded.
## Reader ↔ Processor — flag poor OCR and read it again with a better reader (owner, 2026-10-16)

The owner wants a reader of the archive to be able to say "this file's transcription is not good enough" and get it
read again by a better model, picked from a ranked list. The ranking depends on the kind of document, and it changes if
the user corrects the kind, for example from typewritten to handwritten. He called it an important integration between
the two apps, outlined the features, and left the design to us.

**What exists (checked 2026-10-16).**
- **No link between the apps.** The Reader and the Processor share only the files, with their Finder tags and PDF
  headers. Reader has a URL scheme (`archivereader://`, used by Notes' citations). Processor has none.
- **No OCR quality in the Reader.** Its "Quality" is your Q1-Q3 importance rating, not OCR quality. The only
  OCR-related tag is the Subject `OCR Failed`.
- **Ranked readers already exist in the Processor.** The page-kind classifier (`OCR/PageKindClassifier.swift`: handwritten,
  typewritten, printed, forms) and the ranked picks per kind (`OCR/OCRPageGuidance.swift`, reading
  `segbench-results/ocr-page-guidance.json`, best first by NES) supply the ranked list.
- **The page kind is not stored.** It is kept only in run history (`PageReaderRecord`), not in the PDF or the tags.
- **Re-OCR mode would read the wrong page.** The Processor's "Re-OCR multi-page PDF" mode reads every page of a PDF, so
  on a processed two-page file (image plus text) it would also read the text page.

**The design (decided here, per the owner's "do it however seems best").**
- **The dialog lives in the Processor.** The Processor holds the API keys, the model catalogue, the ranked guidance,
  prices and the OCR engine. The Reader gets the easy way in: flag a file, and "Improve OCR…", which opens the Processor
  at that dialog with the files selected.
- **A flag the user sets** is stored with the file, so it survives without either app open. It can be set in a moment
  while reading, filtered on in the Reader, and dealt with in a batch later.

Four items, in order. Each later one waits on the one before.

- [ ] **`W44.reocr-plan` — design the flag, the hand-off and the rewrite of a file's text page [S · ~1 session]** (lane: suite) (uses: light) (blocked-on: W43.sweep-owner-ok, W46.review-done). Owner, 2026-10-16. Write `execution-plans/reocr/00-plan.md` and index it above. Settle each of these with the reason: **Parked 2026-10-20 (owner): waits on `W43.sweep-owner-ok`, so it resumes when the paid sweep is approved.**
  - **The flag.** A new Finder tag (proposed `OCR Poor`, a Subject like `OCR Failed`) in SPEC/tag-format.md, set by a person and never by a model, and cleared when a re-read is accepted.
  - **The page kind.** Record it in the page-2 header, as a `Kind:` line beside `Classification:`, so a user's correction persists and the Reader can show it. Give its values and how the shared `PDFHeaderParser` reads it. Add a provider/model parse to `PDFHeaderParser`, so either app can say which reader made the current text.
  - **The hand-off.** A Processor URL scheme (`archiveprocessor://improve-ocr?…`) for one or a few files. For a larger selection, a hand-off file in a shared app-group or Application Support location. Say which, and how a sandbox or TCC limit affects it. The Processor must already be installed; say what the Reader shows if it is not.
  - **The rewrite.** Replace only the text page and keep everything else: the image page byte for byte, the file's path (Notes' `archivereader://` citations and the Reader's durable links depend on it), its Finder tags and dates. Keep the previous version recoverable (a sibling backup, or the app's own versions folder with an undo) until the user accepts the new text. Use the same write path as the tag writer's atomic, crash-safe replace. This is a write to the user's files and is Tier-2 throughout; tests run on scratch copies only, never the real corpus.
  - **Which pages are read.** For a processed two-page PDF, only the image page is read, not the old text page. Name how a multi-page original is handled.
  - **The record.** Keep each flag and re-read (old reader, new reader, kind before and after, the user's verdict) as a local record. These are pages a person judged bad, and a later bench can use them as a difficulty signal.

  End with an owner gate only if a choice is genuinely his, for example in-place replacement against writing a new file. Otherwise the plan decides.
- [ ] **`W44.reocr-spec` — the flag, the Kind line and the header parse in SPEC and ArchiveCore [S-M · ~1 session · Tier-2]** (lane: suite) (uses: build) (blocked-on: W44.reocr-plan, W46.review-done). Change SPEC/tag-format.md and `packages/ArchiveCore` as the plan says, so both apps read and write the same thing: the `OCR Poor` tag, the header's `Kind:` line, and provider/model parsing. The Processor writes `Kind:` on every new text page from the classifier, or from the user's choice. No migration: nothing has been produced. Tests in ArchiveCore and both apps' tag and header round trips.
- [ ] **`W44.reocr-processor` — "Improve OCR" in the Processor: the ranked choice and the rewrite [M-L · ~2-3 sessions · Tier-2]** (lane: processor) (uses: build) (blocked-on: W44.reocr-spec, W46.review-done). Build it as the plan says.
  - **The dialog** opens from the URL scheme or hand-off, from the Files tab, and from a "files flagged OCR Poor" picker over a chosen folder. It shows each file: its current reader (from the header), its kind (from the header, else the classifier on the image page), and a kind picker the user can change.
  - **The ranked list** comes from `OCRPageGuidance` for the chosen kind and re-ranks when the kind changes. Each row shows the model's NES for that kind, its price per 1,000 pages and the estimated cost for these pages. It also says whether the model is ready (keyed, a local model on this Mac, an institutional computing run). The current reader is marked as such, and models the app cannot offer are left out. Mixed selections are grouped by kind.
  - **The result.** Read the image pages, rewrite the text pages as specified, and show the old and new text side by side to accept or roll back. Accepting clears the flag and records the re-read.
  - **Tests.** Scratch PDFs only. Cover a two-page file keeping its image page and tags byte for byte, a crash mid-rewrite leaving the old file intact, and a kind change re-ranking the list. Then the adversarial review.
- [ ] **`W44.reocr-reader` — flag poor OCR in the Reader and hand it to the Processor [M · ~1-2 sessions · Tier-2]** (lane: reader) (uses: build,vm) (blocked-on: W44.reocr-processor, W46.review-done). Put it in the row menu, the document window and the menu bar with a keyboard shortcut, for one or many selected files:
  - **Flag as poor OCR, and unflag.** This writes the tag through the shared tag writer, under the Reader's file-safety Core Directive.
  - **A filter for flagged files.**
  - **The page kind,** shown where the provider is shown.
  - **"Improve OCR…",** which hands the selection to the Processor's dialog. When the Processor rewrites a file, the Reader picks up the new text through its existing re-scan, with the document window refreshed if it is open.
  - **Tests.** VM UI tests for flag, filter and hand-off, on the fixture only.

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

- [ ] **`W43.app-guide-refresh` — the sweep's results into the Processor's catalogue and model guide [S-M · ~1 session]** (lane: processor) (uses: build) (blocked-on: W43.sweep, W46.review-done). Make the changes the sweep lists: models added or retired in `ProviderModels.swift` with their pinned providers and prices, the page-kind model guide's picks, the local-model presets by memory size, and the cascade's defaults. Change only what the measured results support. Republishing ArchiveOCRBench is left to an interactive session, and the commit says it is behind. `W40.h2` waits on this item.

## Vision OCR's engine — newspaper rows fused across columns, moved from Vision OCR (owner, 2026-10-16)

The owner called Vision OCR's queue done on 2026-10-16 and moved its last open item here, to be worked on the engine
after it moves into this repository (`execution-plans/integration/00-plan.md`, Stage 1). Its full record, with the
measurements and what was tried, stays in `~/Claude/vision-ocr`: `ops/autonomous/QUEUE.md` (entry
`c41-newspaper-scans`) and `BUGS.md` C41 and C39. The files it names under `$STATE` are in
`~/.local/state/visionocr-autonomous/`.

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

- [ ] **`W40.i5` — borrowed-iPhone session pack [S]** (blocked-on: W42.int-done) (lane: docs) (uses: light) (blocked-on: W40.i3, W40.i3-fu-shots) (blocked-on: W40.i-sim-ui, W40.fix-live-vision-drops-card-tags, W40.fix-processor-live-emptied-mixed, W40.fix-live-finalize-failure-silent). Detail: `execution-plans/verification-phase/01-daemon-plan.md` §I. Judge first whether it is time for the owner's session (§G "Is it time?"); the blockers being ticked is not enough. Progress: `execution-plans/items/W40.i5.md`.
- [ ] **`W40.i4` — real-iPhone pass on a borrowed phone — OWNER** (blocked-on: W42.int-done) (lane: processor) (uses: light) (blocked-on: W40.i5). Detail: `execution-plans/verification-phase/01-daemon-plan.md` and `00-owner-plan.md` §Decisions.
- [ ] **`W40.d1` — bulk OCR on a ground-truth collection [M]** (blocked-on: W42.int-done, W46.review-done) (lane: processor) (uses: build,vm,paid) (blocked-on: W40.b3, W40.c1, W36.seg-decision). Detail: `execution-plans/verification-phase/01-daemon-plan.md` §D.
- [ ] **`W40.d2` — Processor review dialogs driven by hand [M]** (blocked-on: W42.int-done) (lane: processor) (uses: vm) (blocked-on: W40.d1, W36.seg-decision). Detail: `execution-plans/verification-phase/01-daemon-plan.md` §D.
- [ ] **`W40.d3` — every OCR provider through the app's own client [S-M]** (blocked-on: W42.int-done, W46.review-done) (lane: processor) (uses: build,paid) (blocked-on: W40.b3, W36.seg-decision). Detail: `execution-plans/verification-phase/01-daemon-plan.md` §D.
- [ ] **`W40.d4` — one tiny real batch job per batch provider [S-M]** (blocked-on: W42.int-done, W46.review-done) (lane: processor) (uses: build,paid) (blocked-on: W40.d3, W36.seg-decision). Detail: `execution-plans/verification-phase/01-daemon-plan.md` §D.
- [ ] **`W40.d11` — the shared tag contract across apps [S-M]** (lane: suite) (uses: build,vm) (blocked-on: W40.d1, W40.d8). Detail: `execution-plans/verification-phase/01-daemon-plan.md` §D.
- [ ] **`W40.e4` — never-executed code from coverage [M]** (lane: reader,notes,processor) (uses: build) (blocked-on: W40.d1, W40.d8, W40.d9). Detail: `execution-plans/verification-phase/01-daemon-plan.md` §E.
- [ ] **`W40.g2` — Notes guided-session pack [S]** (lane: notes) (uses: light) (blocked-on: W40.d9, W40.d10, W40.fix-notes-return-paragraph, W40.fix-notes-zotero-csljson-crash, W40.fix-notes-row-clip, W40.fix-notes-chips-overdrawn, W40.fix-notes-choose-store, W40.fix-notes-unclosed-header, W40.fix-notes-narrow-window, W40.fix-notes-asset-write-silent, W40.fix-notes-failed-save-close, W40.e11, W40.fix-notes-stale-body-on-switch, W40.fix-notes-list-overrun, W40.fix-notes-chip-inline-layout, W40.fix-notes-preview-popover-text, W40.fix-notes-editor-squeezed, W48.notes-stacked-layout-verify). Detail: `execution-plans/verification-phase/01-daemon-plan.md` §G. Judge first whether it is time for the owner's session (§G "Is it time?"); the blockers being ticked is not enough. **Judged 2026-10-15, after d9 and d10 landed: not time.** Ten Notes items are open and queued. Each would get in the way of a session task or is about to change what one reviews: typed paragraphs merge on reopen (writing), Auto-fill crashes against a real Zotero (citing), list rows are clipped (every browse), file chips are overdrawn (Reader extracts), there is no Choose Store Folder so the pack cannot point Notes at the rehearsal store, the rehearsal store's unclosed-header notes gain a line on each save, and `W40.e11` is about to review every Notes screen. The other three are narrow-window, asset-write-silent and failed-save-close. All are S or S-M and unblocked. The only Notes problem expected to stay open a while is `W40.fix-notes-inspector-jitter` (it waits on `W40.e13`), and the pack lists it as known, touching every note-switch task. When these land, judge again from the open items then, and write `verification/sessions/notes-1.md`. `W40.e11` (2026-10-16) added five blockers, each in the way of a session task: a large note's header shown over the previous body (writing), list text drawn across columns (every browse), page chips on the wrong line (Reader extracts), the cut preview instruction, and the squeezed extract editor.
- [ ] **`W40.g3` — Processor and capture guided-session pack [S]** (blocked-on: W42.int-done) (lane: processor) (uses: light) (blocked-on: W40.d1, W40.d2, W40.d5, W40.fix-processor-dark-disabled-buttons, W40.fix-processor-start-why, W40.fix-processor-live-emptied-mixed, W40.fix-processor-flagged-page-edges, W40.fix-processor-settings-fields, W40.fix-processor-settings-backend-mismatch). Detail: `execution-plans/verification-phase/01-daemon-plan.md` §G. Judge first whether it is time for the owner's session (§G "Is it time?"); the blockers being ticked is not enough.
- [ ] **`W40.g1-refresh` — refresh the Reader guided-session pack once the known Reader bugs are fixed, and judge whether it is time [S]** (lane: reader) (uses: light) (blocked-on: W40.fix-reader-narrow-window, W40.fix-reader-preview-sheet-oversize, W40.fix-reader-read-toggle, W40.fix-reader-sent-with-date, W40.fix-reader-inline-keys, W40.fix-reader-tag-quarantine, W40.fix-reader-list-recompute-at-size, W40.fix-reader-fts-snippet-stall, W40.fix-reader-long-name-overrun, W40.fix-reader-doc-find-focus, W40.fix-reader-tag-editor-chips, W40.fix-reader-tagcloud-width, W40.fix-reader-phantom-selection, W40.fix-reader-selected-row-contrast). Owner, 2026-10-15: run `verification/sessions/reader-1.md` after these eight fixes, not before, so the session goes on problems nobody knows about yet. FIRST JUDGE WHETHER IT IS TIME, as `01-daemon-plan.md` §G "Is it time?" says; the blockers being ticked is not the answer. Read each fix's result and every Reader item filed or reopened since 2026-10-15, and ask of each task in the pack whether a known defect would get in its way, or whether queued work is about to change what it reviews. If it is not time, name what it waits for, block this item on it, and report that in the Daemon Report (no decision); do not hand the pack over. If it is: revise the pack. Keep in "Problems we already know about" only what is still open, with which tasks it touches. Re-check every task against the Reader as it now is (the Read column toggle and Sent-With in ⌘I change tasks 4 and 5). The copy step must replace `reader-session-1/`, made on 2026-10-15 for the postponed session, with a fresh copy. Then say in the Daemon Report that the Reader session is ready and what changed since the first pack. Detail: `execution-plans/verification-phase/01-daemon-plan.md` §G.
- [ ] **`W40.g-sessions` — owner runs the guided sessions — OWNER** (lane: suite) (uses: light) (blocked-on: W40.g1). Detail: `execution-plans/verification-phase/01-daemon-plan.md` and `00-owner-plan.md` §Decisions Before each session is offered, the pack's own item judges whether it is time (§G "Is it time?"); for the Reader that is `W40.g1-refresh`.
- [ ] **`W40.h2` — re-run every journey at HEAD [M]** (lane: suite) (uses: build,vm) (blocked-on: W40.d1, W40.d2, W40.d3, W40.d4, W40.d5, W40.d6, W40.d7, W40.d8, W40.d9, W40.d10, W40.d11, W40.e1, W40.e2, W40.e3, W40.e4, W40.e5, W40.e6, W40.e7, W40.e9, W40.e10, W40.e11, W40.e12, W40.e13, W40.f1, W40.f2, W43.app-guide-refresh). Detail: `execution-plans/verification-phase/01-daemon-plan.md` §H.
- [ ] **`W40.h3` — release candidate — OWNER (Tier-3)** (lane: suite) (uses: build) (blocked-on: W40.h2). Detail: `execution-plans/verification-phase/01-daemon-plan.md` and `00-owner-plan.md` §Decisions.
- [ ] **`W40.h4` — owner acceptance pass with the ledgers — OWNER** (lane: suite) (uses: light) (blocked-on: W40.h3). Detail: `execution-plans/verification-phase/01-daemon-plan.md` and `00-owner-plan.md` §Decisions.
- [ ] **`W40.token-pass` — a weekly token-efficiency pass that measures the engine's sessions and fixes what it finds [M · Tier-2]** (lane: ops) (uses: light) (blocked-on: W40.docs-startup-size) — Owner, 2026-10-28: the engine assesses its own token efficiency at a regular cadence, and the assessment includes fixing the problems it finds, not only reporting them. Build three parts. (1) `ops/agent/token-audit.py`, free and deterministic: from this project's session transcripts since the last pass (the ~/.claude/projects folders for the primary checkout and for ~/Claude/.worktrees/archive-suite/*) and the engine ledger it reports the first-call context per session (today about 56k tokens), context per call and tokens per finished item with their trend against the last pass, the always-loaded files against a budget (each app guide 20 KB, CLAUDE.md, the session prompt, ~/Claude/CLAUDE.md and the memory index each named with a figure set from W40.docs-startup-size's result), the files sessions read whole most often with their size, tool results over 20k characters by command, and the same file read whole twice in one session. It writes the report to the state folder, not the repo. (2) The cadence: the upkeep hook runs it at most once every 7 days (a dated O_EXCL stamp, as cluster-reach.py does) and only when at least 20 sessions have run since the last pass, so a quiet week costs nothing. When a budget is passed or a figure is 10% or more worse than the last pass, it opens the fix item; otherwise it records the figures and stops. Choose a filing for the repeating item that passes check-tracker-sync.sh and check-todo-stubs.sh, and say which in the DONE entry. (3) The fix session the pass opens reads the report and fixes what it can in one session: guides trimmed by hand with every rule listed before and after and an adversarial reviewer checking that list, prompt steps the engine overrides removed, a noisy script given a summary on stdout and its full output in a log, a hook that dumps a large file narrowed. It re-measures and records the before and after figures. Anything larger than one session is filed as its own item. A rule may move but never disappear. Ship the audit's unit tests (a synthetic transcript folder with known figures) and run one real pass as the item's proof.
- [ ] **`W40.token-fix` — the token pass's fix session: read the report, fix what it found, re-arm [M · Tier-2 · standing]** (lane: ops) (uses: light) (blocked-on: W40.token-fix-due) — Standing item, never ticked (W40.token-pass, owner 2026-10-28). The weekly pass (`ops/agent/token-audit.py`, run by the upkeep hook) ticks `W40.token-fix-due` in the plan's `## RECURRING` section when an always-loaded file is over its budget or a session figure is 10% or more worse than the last pass; that makes this item runnable. The session reads `$AGENT_STATE/token-audit/latest.md` and fixes what it can in one session: a guide trimmed by hand, with every rule listed before and after and an adversarial reviewer checking that list (a rule may move but never disappear); prompt steps the engine overrides removed; a noisy script given a summary on stdout and its full output in a log; a hook that dumps a large file narrowed. Anything larger than one session is filed as its own item. It re-measures (`token-audit.py sizes` for the files; the next pass measures the sessions) and records the before and after figures in a dated `W40.token-fix-YYYYMMDD` entry appended to `SUITE_TODO_DONE.md`, in the same commit as the fix; the commit subject names `W40.token-fix` standing alone, e.g. `W40.token-fix (2026-11-05)`, because the engine counts progress only by the bare tag. Then, after the push, `ops/autonomous/plan-edit.sh "/Users/cp1/Claude/Archive Suite/.maintenance/AUTONOMOUS_PLAN.md" rearm W40.token-fix-due '<sha>: <result>'`, which makes this item wait again (the next pass reports a gate left ticked). ⛔ Never `complete` it (plan-edit.py refuses) and never move this entry: the plan and this file both keep it open, which is what keeps check-tracker-sync.sh and check-todo-stubs.sh passing.
- [ ] **`W40.fix-notes-choose-store` — wire File ▸ Choose Store Folder… in Notes [S · Tier-2]** (lane: notes) (uses: build,vm). Owner ruling 2026-10-12 walkthrough on ledger row N-48: wire it (the recommendation to drop it was declined). The guides promise a user-picked Notes store remembered across relaunches, so a store copied from another Mac can be adopted where it lies; `RootFolderStore.setRoot` exists but nothing calls it and there is no menu item. Add the item, persist the choice (security-scoped bookmark under the sandbox), adopt an existing store in place, and ship the test that failed before it: pick a folder holding a store, relaunch, and the notes read from it. Then mark N-48 live in `verification/notes.md`.
- [ ] **`W40.fix-reader-read-toggle` — click and right-click the Read column again [S · Tier-2]** (lane: reader) (uses: build,vm). Owner ruling 2026-10-12 walkthrough on ledger row R-25: wire it (the recommendation to drop it was declined). Clicking a row's Read cell flips Unread↔Read and a right-click sets or clears it (the only live route to clearing read state), in the AppKit table's Read column, writing through the same tag path as ⌘R/⌘U. Delete the dead `ReadStateCell` in `Views/InlineEditCells.swift` once the column carries it. Tier-2 because it writes tags; guard against a stray click by acting on the cell only, not the row. Ship the test that failed before it, then mark R-25 live in `verification/reader.md`.
- [ ] **`W40.fix-reader-sent-with-date` — Sent-With in the ⌘I sheet; delete the dead inline date cell [S · Tier-2]** (lane: reader) (uses: build,vm). Owner ruling 2026-10-12 walkthrough on ledger row R-26, option (b): the ⌘I sheet is the one date editor. Add a Sent-With date field to it, delete `DateCell` from `Views/InlineEditCells.swift`, and mark R-26 dropped (inline) in `verification/reader.md`; `W40.b5` corrects the guides that promise inline date editing. Ship the test that failed before it: set a Sent-With date in the sheet and read it back.
- [ ] **`W40.fix-reader-date-ambiguity` — flag a file with two same-facet date tags (two Years, Months or Sent With values) as ambiguous in the Reader [S · Tier-2]** (lane: reader) (uses: build,vm). Owner ruling 2026-10-16 walkthrough on ledger row R-47 (found by `W40.e5`): show the flag; the promise in `CLAUDE.md` §Edge cases and `SPEC/tag-format.md` stays. The last-wins rule is unchanged. Today `DocumentTags.sentWithIsAmbiguous` exists but no app reads it, and nothing detects two Years or two Months. Add that detection in ArchiveCore beside `sentWithIsAmbiguous` (Tier-2: ArchiveCore and the SPEC wording), show the flag on the file in the Reader list and its ⌘I sheet, naming the tag the rule set aside, and make it filterable so the user can find every such file to review. Ship the test that failed before it: a file tagged with two Years shows the flag and the filter finds it. Then mark R-47 `works` in `verification/reader.md` on runtime evidence.
- [ ] **`W40.fix-reader-inline-keys` — the list's bare keys fire inside the inline tag editor, and Return does not commit there [S · S2 · Tier-2]** (lane: reader) (uses: build,vm). Found by `W40.d8` 2026-10-14; reproduction: `ArchiveReaderUITests/TriageJourneyUITests` steps 2a and 2 in the VM, evidence `verification/evidence/reader/W40.d8-triage.md` (screenshot of the Preview sheet opened by a typed space). The `.onKeyPress(.space)` (Preview) and `[`/`]`/`\` (triage) handlers sit on the `AppKitTableView` (`Views/NavigationWindowView.swift:140-157`), and the inline `TagTokenCellView` token field lives inside that table, so SwiftUI counts the list as focused while you type in it. Typing "W40d8 Inline" wrote the tag `W40d8`: the space opened Preview and cut the edit. `[`, `]` and `\` sit in the same handler block; whether they fire there too (`\` would run Mark Read & Advance, a tag write) is suspect `S-015`, not yet reproduced. Separately, Return does not commit the inline edit; the tag is written only when the field is left (R-23 promises both). S2: multi-word subjects, the norm in the corpus, cannot be typed inline. Fix: have the handlers return `.ignored` while the key window's first responder is a text view (the field editor), and end editing on Return. Then remove the two `XCTExpectFailure` blocks naming this tag in `TriageJourneyUITests` (they are the test that failed before it), and move R-20/R-23 in `verification/reader.md` to `fixed-pending-recheck`.
- [ ] **`W40.fix-reader-tag-quarantine` — every Reader tag write adds `com.apple.quarantine` to the file [S · S3 · Tier-2]** (lane: reader) (uses: build,vm). Found by `W40.d8` 2026-10-14; reproduction: `ArchiveReaderUITests/TriageJourneyUITests` (every write step) in the VM, evidence `verification/evidence/reader/W40.d8-triage.md`. A file with no quarantine xattr gains `com.apple.quarantine = 0086;<hex time>;ArchiveReader;` from Mark Read, the inline editor and the ⌘I sheet, and on the real-corpus sample a file that already carried another app's stamp (PDFpen, Preview) had that stamp rewritten. Content, the tag xattr's other entries, colours and `com.apple.FinderInfo` are unchanged. This breaks R-45's "only Finder tags ever change", and on the real corpus every triaged PDF would carry it (the W40.c2 sample shows none from ArchiveReader yet, but 3,500+ from Preview, Photos and PDFpen, so macOS stamps edits by sandboxed apps). Likely cause [I, not checked]: the App Sandbox quarantines files a sandboxed app writes, and `NSURL.setResourceValue(_:forKey: .tagNamesKey)` (`packages/ArchiveCore/Sources/ArchiveCore/Tags/TagWrite.swift:278`) counts as a write. First establish what is possible: whether a sandboxed app may remove the quarantine xattr it just added (only when it was absent before the write, never one another app put there), or whether a different write primitive avoids it, and whether the Processor's and Notes' tag writes do the same. If nothing can avoid it, the decision (accept and amend the R-45 promise, or not) goes to the Daemon Report. S3: recoverable (`xattr -d`), no data lost. Ship the test that failed before it by removing the `XCTExpectFailure` naming this tag in `TriageJourneyUITests`.
- [ ] **`W40.fix-reader-undo-partial` — a partly failed undo is reported as complete, and the failed file's undo is lost [S · S3 · Tier-2]** (lane: reader) (uses: build). Found by `W40.f1` 2026-10-16; reproduction: `ArchiveReaderTests/UndoDurabilityTests.testAPartlyFailedUndoIsReportedAsComplete` (two files marked Read as one step, one removed, ⌘Z: the other is restored and the status says `Undid 1 change.`), evidence `verification/evidence/reader/W40.f1-undo.md`. `NavigationModel.undoLast` (`Views/NavigationModel.swift:1096-1113`) wraps each inverse write in `try?`, counts only what succeeded and has already popped the batch, so the user is not told a file could not be undone and cannot retry it. Safety §11 requires partial failures be surfaced, as `mark` does (`Marked 1; 1 could not update.`). Progress in `W40.audit-ledger-undo` (checkpoint e4fe101c): failures are counted, named and announced; the strict expected-failure wrapper is removed. Durable undo consumes the whole group before any inverse so an interrupted occurrence inverse cannot replay. **Remaining scope:** decide and implement whether a failed member whose cause may pass can be retried safely, with per-member durable accounting; an identity mismatch must never retry against a replacement. Do not repeat the reporting fix or remove the group-consumption safety guard.
- [ ] **`W40.fix-reader-list-recompute-at-size` — at corpus size every tag edit and every sort change stalls the Reader's main thread for one to five seconds [M · S2]** (lane: reader) (uses: build,machine). Found by `W40.d7` 2026-10-15; reproduction: `ops/scale/run-reader-at-size.sh --optimized --only synthetic` (`ArchiveReaderTests/ReaderAtSizeTests.testListAtOneHundredFiftyThousandFiles`, needs the 150k tree from `ops/scale/run-scale-verify.sh --keep`), evidence `verification/evidence/reader/W40.d7-at-size.md`. At 115,999 listed rows, `-O`: one tag edit, as `ArchiveLibrary.applyVerifiedWrites` makes it (Mark Read, inline and group edit, rename, undo), reassigns `files`, and `NavigationModel.libraryDidChange` then runs in full on the main thread: 1,561 ms before the table's own 107 ms per-change refresh. `recompute()` alone is 1,021 ms; `LibrarySort.sorted` is 0.96 s for the default sort and 4.0–5.5 s by date, quality, read state, type or file tags. Breaks R-13's "stays smooth at 40k rows or more". Measured causes: `localizedStandardCompare` about two million times per sort (the default sort's ~1 s), and the final tiebreak `a.url.path.localizedStandardCompare(b.url.path)`, which rebuilds both path strings on every tied comparison (the slow sorts, on a tree whose rows mostly tie on the key). Likely remedies [I, not tried]: precomputed sort keys (a collation key, or a decorated array) in `LibrarySort.sorted`; a single-row update path that moves one row instead of re-sorting 116k; sorting off the main actor. Ship it with a threshold assertion in `ReaderAtSizeTests` that fails before the fix (rule 8). The table-side costs in the same evidence (per-change id-map rebuild 107 ms, `syncSelection` 40 ms walking every id) belong here too.
- [ ] **`W40.fix-reader-fts-snippet-stall` — a multi-word OCR search containing common words takes 42 s at corpus size, and blocks every later query behind it [S-M · S2]** (lane: reader) (uses: build,machine). Found by `W40.d7` 2026-10-15; reproduction: `ops/scale/run-reader-at-size.sh --optimized --only sample` (`ReaderAtSizeTests.testIndexSearchAndHealthOnTheRealSample`, needs the `W40.c2` sample), evidence `verification/evidence/reader/W40.d7-at-size.md`. `ContentIndex.searchRanked("Bureau of the Budget")` takes 2.2 s over the 5,268-file sample (11 hits) and 41.7 s over the sample's text replicated to 102,478 rows (215 hits); single distinctive terms take 11–146 ms there. `ContentIndex` is an actor, so the window does not freeze, but every later search and every other call on the actor queues behind the slow one. Measured: the MATCH itself is not the cost — paths-only `search()` for that query takes 24 ms at 102k; the other ~42 s is `snippetMap`, i.e. `snippet()` over the top hits, about 200 ms per hit when the phrase's terms (`of`, `the`) occur thousands of times in a long OCR body [the per-hit cost is I: total ÷ hits]. Likely remedies [I, not tried]: snippets only for the rows on screen, a cheaper fragment builder, dropping stop-word terms from the snippet expression, or a time budget. Breaks R-11 at corpus size. Ship it with a threshold assertion on that query in `ReaderAtSizeTests` that fails before the fix (rule 8).
- [ ] **`W40.fix-notes-return-paragraph` — a Return typed in the styled editor is saved as one newline, so typed paragraphs merge into one on reopen [S · S2 · Tier-2]** (lane: notes) (uses: build,vm). Found by `W40.d9` 2026-10-15; reproduction: `ArchiveNotesUITests/WritingJourneyUITests.testTypingAutosavesAndSurvivesQuitWithinDebounceAndRelaunch` (step 3) in the VM, evidence `verification/evidence/notes/W40.d9-writing.md`. Two paragraphs typed with `typeText("\n…")` after the fixture note's last paragraph are written one newline apart (`…no source blocks.\nTyped by hand…\nQuit straight…`); Markdown reads that as one paragraph, and after a relaunch the styled editor shows one. No text is lost, but every paragraph break typed in the styled editor is lost on the next open. Likely cause [I, not checked]: `MarkdownBridge.serializeBodySegment` (`Editor/MarkdownBridge.swift:413-443`) splits paragraphs by runs of `.noteBlockKind` (`collectParagraphs`, `:453`); a typed paragraph inherits `.plain` from the one before it, so both are one run and the Return is written as a bare newline. Fix so a Return in plain styled text serializes as a paragraph break and the round trip through reopen keeps it (keep `W3.notes-editor-blankline-collapse` and the list/heading cases green). Ship a unit test on `MarkdownBridge` plus removing the `XCTExpectFailure` naming this tag in `WritingJourneyUITests`; move N-12 in `verification/notes.md` to `fixed-pending-recheck`. Tier-2: it changes what every Notes save writes.
- [ ] **`W40.fix-notes-asset-write-silent` — a pasted image whose bytes cannot be written is only logged; the note keeps a reference to a file that never lands [S · S3]** (lane: notes) (uses: build,vm). Found by `W40.d9` 2026-10-15; reproduction: `ArchiveNotesUITests/WritingJourneyUITests.testFailedImageWriteIsReportedToTheUser` in the VM (the note's `assets/` made read-only), evidence `verification/evidence/notes/W40.d9-writing.md`. The paste reports `ok`, the `.md` gains `![](assets/pasted-….png)`, no file lands, and nothing is shown: `ItemAssetStore.addAsset` (`Editor/InlineImageAttachment.swift:355`) only `NSLog`s the write failure. Recorded as residual (a) of the W7-S5 entry in `ArchiveNotes/KNOWN_ISSUES.md`. S3: the image is lost but can be pasted again, if the user notices. Fix: report the failure through `NotesModel.statusMessage` (the sidebar status line), and consider removing the dangling reference. Ship the test that failed before it by removing the `XCTExpectFailure` naming this tag.
- [ ] **`W40.fix-notes-failed-save-close-fu1` — a refused template body is still lost on quit [S · S2 · Tier-2]** (lane: notes) (uses: build). Found by the W40.fix-notes-failed-save-close review 2026-10-15. `TemplateBodyEditorPane` saves through the plain `save` seam (`NotesModel.setTemplateBody`), whose Bool the editor discards: `NoteBodyEditorModel.persist` marks the buffer clean, `EditorFlushRegistry.flushAll` reports success and `TerminateFlushCoordinator` lets quit proceed, while the refused body lives only in `NotesModel.failedTemplateBodyDrafts` (memory; reloaded on return, gone with the process). Make the template save report its refusal (a checked seam, or `save` returning the Bool into `persist`) so the template pane keeps the draft, copies it to the `UnsavedDraftVault` and refuses quit exactly as note panes do; the pane's teardown must then close through `paneClosed`, not `deregister`. Scratch functional test: refuse the template write (read-only `templates/` folder), type, quit, restore, prove the body is recoverable.
- [ ] **`W40.fix-notes-zotero-csljson-crash` — Auto-fill from Zotero crashes Notes against a real Zotero's local API [S · S2]** (lane: notes) (uses: build,vm). Found by `W40.d10` 2026-10-15; reproduction: `ArchiveNotesUITests/IntegrationJourneyUITests.testD10_2_AutoFillFromRealZotero` (`NOTES_JOURNEY=integrations ops/gui/vm-gui-runner.sh notes xcuitest`), evidence `verification/evidence/notes/W40.d10-integrations.md`. Zotero 10.0.6's `GET /api/users/0/items/<key>?include=csljson` returns `"csljson"` as a **string** holding a JSON **array** (`"[\n\t{\n\t\t\"id\": …}]"`), not an object. `ZoteroClient.fetchCSLviaLocalAPI` (`Zotero/ZoteroClient.swift:318-332`) passes that string to `JSONSerialization.data(withJSONObject:)`, which raises an Objective-C exception, and the app aborts (crash report: `+[NSJSONSerialization dataWithJSONObject:options:error:]` ← `ZoteroClient.fetchCSLviaLocalAPI` ← `fetchCSL`). Every Auto-fill without Better BibTeX takes this path. The stub (`ZoteroUITestTransport`) and `ZoteroClientTests` both return an object, which is why nothing caught it. Fix: accept the string-of-array shape (decode it with the existing `parseCSLArray`), keep the object shape, and never hand an unvalidated value to `data(withJSONObject:)`. The same body writes the date as strings, `"issued": {"date-parts": [["1843"]]}`, and `ZoteroCSLItem.CSLDate.dateParts` is `[[Int]]?` (`Zotero/ZoteroClient.swift:59`), so once the crash is gone the synthesized decode would throw on it and Auto-fill would still fail [I, from the code; the body is measured]: decode date parts that are numbers or numeric strings. Ship a `ZoteroClientTests` case with Zotero's real response body (in the evidence file), and remove the `XCTExpectFailure` naming this tag; move N-44 in `verification/notes.md` to `fixed-pending-recheck`.
- [ ] **`W40.fix-core-classification-from-body` — the page-2 classification is read from any `Classification:` line on the page, the OCR body included [S · S3]** (lane: suite) (uses: build). Found by `W40.e6` 2026-10-20; reproduction: `ArchiveCoreTests/ParserFuzzTests.testClassificationIsReadOnlyFromTheHeaderKnownIssue` (a strict `XCTExpectFailure`; detail `verification/evidence/core/W40.e6-parser-robustness.md`). `PDFHeaderParser.parseClassification` (`packages/ArchiveCore/Sources/ArchiveCore/PDF/ExtractedContent.swift`) and `extract` take the first `Classification:` line on any page: a header with no classification borrows a body line such as an OCR'd `Classification: Top Secret` marking, and a file name starting with the word wins over the real header line. Read it only from the app-format header block on page 2 (between `Extracted text.` and the first blank line, after the provider line). First check what the corpus's older Processor formats put on page 2, since the scan-every-page behaviour may exist for them; then delete the expectation.
- [ ] **`W40.fix-mut-tagwriter-tests` — five tag-writer mutants survive the ArchiveCore suite [S · S3]** (lane: suite) (uses: build). Found by `W40.e7` 2026-10-20; reproduction: `ops/verify/mutation-sample.sh core --only C02,C06,C07,C11,C12` reports each `survived`, with its object file proved changed (detail `verification/evidence/core/W40.e7-mutation-sample.md`). Add the tests that kill them: a write whose target has lost its identity (deleted after `FileIdentity.capture`) must throw `identityMismatch` (C02); the verify-after-write must be seen to fire, for tags and for the label (C06, C07: inject a re-read that differs, or call the verify step directly); removing subject `Smith` must leave `Smithson` (C11, the "never substring" promise in `shouldRemoveTag`'s doc comment); `multisetEqual(["A","A"], ["A"])` is false (C12). Done when that command reports all five `killed`. Tests only; no product change.
- [ ] **`W40.fix-mut-processor-trash-tests` — six finalize/Trash mutants survive the Processor drivers [S-M · S3]** (lane: processor) (uses: build). Found by `W40.e7` 2026-10-20; reproduction: `MUT_DRIVERS=all ops/verify/mutation-sample.sh processor --only P01,P02,P06,P08,P11,P12` (detail `verification/evidence/core/W40.e7-mutation-sample.md`). The worst is P01: `CaptureSession.trashOrRemove` replaced by a hard `removeItem` that returns `true` passes recovery Test 4, which says it checks "not a hard rm" but only checks that the file left its path, so the originals' recoverability is unguarded. Kill it by finding the file in the Trash (`resultingItemURL`) or by a recording `FileManager`. Then: a failed `trashItem` falls back and returns `false` (P02); `commitPreparedClear` refuses a stale token (P06); a run where every group files but a move failed is not `allFiled` (P08); a destination collision in `move(_:to:fm:)` sends the displaced file to the Trash (P11); a failed move does not count as landed (P12). P02, P08 and P12 need a move or Trash failure injected into a driver. Done when the command reports all six `killed`.
- [ ] **`W40.fix-mut-reader-undo-tests` — four undo mutants survive the Reader suite [S · S3]** (lane: reader) (uses: build). Found by `W40.e7` 2026-10-20; reproduction: `ops/verify/mutation-sample.sh reader --only R03,R06,R08,R09` (detail `verification/evidence/core/W40.e7-mutation-sample.md`). R08 is the plainest: `undoLast` taking `undoGroups.first` (the OLDEST change) passes all 15 tests that call it, because none has two undoable groups and checks which was reversed. R09: no test points undo at a file outside the current archive root. R03, R06: `TagWriter.applyOccurrence`'s removal budget and addition-budget decrement — needs undo cases where the budget is strictly between 0 and the listed count (one copy already removed, or re-added by hand, since the change). Done when the command reports all four `killed`.

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


## Archive Notes — owner requests (2026-10-28)

- [ ] **`W48.notes-stacked-layout` — a view mode with the note list above the note and a horizontal divider between them [M · Tier-2]** (lane: notes) (uses: build,vm) — Owner, 2026-10-28. Notes offers only the side-by-side layout (`NotesBrowserView`: tree │ list │ detail, two vertical `PanelDivider`s). Add a stacked mode for the Notes and Extracts windows: the folder tree stays on the left, the item list sits on top of the right-hand area and the note below it, with a horizontal divider that drags, clamps and persists its height (a new `an.*` key read through `NotesLayoutSettings`, clamped like the widths). The mode is a View menu choice (side by side / list above note), remembered across relaunches, and switching keeps the selection, the open note's unsaved edits and the scroll position. The divider is the same accessible splitter as the vertical one (role splitter, value, increment and decrement), oriented horizontally. Verification, per `execution-plans/verification-phase/01-daemon-plan.md` rule 7 (owner-requested features): a Notes ledger row `unproven` for the stacked mode, the divider and the persisted choice; layout unit tests for the new clamp and key; a VM UI test that switches modes with a note being edited and checks nothing is lost; `AccessibilityAuditUITests` and `VisualReviewUITests` extended to run every screen they already cover in both modes, light and dark (VoiceOver order list then note, keyboard focus across the divider, narrow and tall windows); the writing journey (`W40.d9`) run once in the stacked mode; the whole Notes UITest suite green in the VM before it ships. The independent re-check is W48.notes-stacked-layout-verify.
- [ ] **`W48.notes-stacked-layout-verify` — re-check the stacked layout at HEAD, by a session that did not build it [S]** (lane: notes) (uses: build,vm) (blocked-on: W48.notes-stacked-layout) — Rule 6 and rule 7 of `execution-plans/verification-phase/01-daemon-plan.md`. Read the ledger rows W48.notes-stacked-layout added and write each expected outcome from the promise before reading the code. At HEAD, in the VM: the whole Notes UITest suite, the accessibility audit and visual review in both layouts, light and dark, and the writing journey in the stacked layout. Check by hand-scripted runs what the tests may not reach: switching layouts in both windows, relaunch restores the layout and the divider, a note being edited survives a switch, the divider at its limits, the Extracts window. Move each row to `works` with its evidence under `verification/evidence/notes/`, or file `W40.fix-notes-*` with a severity. The Notes guided-session pack W40.g2 waits on this item.


## FarmShare extensions — owner, 2026-10-19


- [ ] **W43.seg-date-public — test the frozen combined model on both public segmentation boxes [S · ~0.2 session]** (lane: segbench) (uses: light) (blocked-on: W43.sweep-owner-ok, W46.review-done). Owner19Oct: queue the combined model on frozen CREST128/Lincoln261 pages, same prompts/scorer beside the three completed public model rows. Use existing combined weights; no retraining, no private locked-test repeat and no revised adoption decision. **Resume/retrieve the already-submitted recorded job, never submit a duplicate.** Report numeric scores, refresh benchmark and reconcile trackers. Notes: `execution-plans/farmshare-extensions-20261019.md` and durable `Long term storage/FarmShare-20261019`. **Parked 2026-10-20 (owner): waits on `W43.sweep-owner-ok`, so it resumes when the paid sweep is approved.**

## Nice-to-have, end of project — W46 (owner, 2026-10-22)

Work that places the bench against the field or extends a result already settled, rather than changing an app route,
default or recommendation. Every entry waits on `W46.nice-to-have` (the plan's HOLD QUEUE), which the owner opens
once the useful work is done. A Sherlock item judged nice-to-have at its hand-off moves here (root CLAUDE.md,
"Every Sherlock job is reviewed for size and necessity").

- [ ] **`W46.truth-jpeg-rest` — the other routes on the 15 JPEG-original truth pages [S]** (lane: segbench) (uses: light,paid) (blocked-on: W46.nice-to-have) — W46.truth-jpeg-upgrade swapped 15 truth pages to their JPEG originals and reran the five free or near-free routes (Apple Vision, the three MLX readers, Gemini 3.7 Flash on the gateway): no route reads the originals better, the 96-page means move 0.6 points at most (Apple Vision) and 0.2 or less otherwise, so the rest is nice-to-have. Left: the OpenRouter local and cloud panels (ocr_panel.py, ocr_cloud_full.py; a scratch OCR_PANEL_CACHE as truth_jpeg_upgrade.py pack makes, cents to about $1 for 15 pages, in paid-runs-deferred.md), the cluster readers on Sherlock (the engine packs the 15 images, the owner submits), and the 96-page arms of the jobs queued on 2026-10-22, which kept the PDF images. Score each with truth_jpeg_upgrade.py score (extend ROUTES). detail: ArchiveProcessor/segbench-results/truth-jpeg-upgrade.md
- [ ] **`W46.seg-openpss` — OpenPSS through the students and the teacher, on a stream sample, on Sherlock [M]** (lane: segbench) (uses: light) (cluster: sherlock) (blocked-on: W46.cluster-waves, W46.sherlock-ok, W46.fix-seg-scorers) — Owner, 2026-10-22: not the whole 141,668-page mirror. Use LONG's test split (25.7k pages; its 63.8k training pages are left out) and SHORT, sampled by stream (stratified by stream length) to a stated target: boundary F1 within about ±2 points at 95% (stream bootstrap); freeze and record the sample. First confirm which split and scoring doc-split-v1's 0.859 / 0.585 and the specialist's 0.83 / 0.76 used (page 0 forced, boundary F1) and score the same way. Prepare a one-stream pilot per model (both students, the 27B teacher); its timings give the GPU-hour estimate for the sample, written in the item notes before the hand-over. Dutch, so the prompt's domain cues do not apply; the "other" licence allows measurement. The Gemini arm is W46.seg-openpss-paid (its 1,000 pages come from the same sample). (blocked-on: W46.nice-to-have) detail: execution-plans/processing-review/10-gap-audit.md §5 item 38
- [ ] **`W46.seg-openpss-paid` — Gemini windows on a 1,000-page OpenPSS subset, in batch [S]** (lane: segbench) (uses: light,paid) (blocked-on: W46.seg-openpss, W46.gateway-models-ok) — The gateway arm of W46.seg-openpss, batch only (about $1.81; $3.61 at list). (blocked-on: W46.nice-to-have) detail: execution-plans/processing-review/10-gap-audit.md §5 item 38
- [ ] **`W46.seg-adapt-lora` — LoRA continuation of the 2B on a user's corrected gaps, across boxes of one new material [M]** (lane: segbench) (uses: light) (cluster: sherlock) (blocked-on: W46.seg-adapt-curve) — The LoRA arm of W46.seg-adapt-curve, judged nice-to-have at its 2026-10-23 hand-off: the cheap refit leaves the 2B's confident Lincoln over-splits, but Lincoln (260 gaps, one box) cannot measure a 200-gap LoRA, and the route answer (a cloud voter, Claude 90.0%) is in hand. The test worth running needs a second box of a Lincoln-like material, corrections from the first scored on the second. Review and recipe: execution-plans/items/W46.seg-adapt-lora.md. (blocked-on: W46.nice-to-have) detail: execution-plans/processing-review/10-gap-audit.md §5 item 13
- [ ] **`W46.seg-tabme` — whether the students' 79% is the material or the model, on TABME++ [M]** (lane: segbench) (uses: light) (cluster: sherlock) (blocked-on: W46.cluster-waves, W46.fix-seg-scorers) — Students and the 27B teacher over TABME++'s 6,236-decision test set against A05's Table 4. (blocked-on: W46.nice-to-have) detail: execution-plans/processing-review/10-gap-audit.md §5 item 34
- [ ] **`W46.capture-ladder-sherlock` — the full 895-page capture ladder [M]** (lane: segbench) (uses: light) (cluster: sherlock) (blocked-on: W46.cluster-waves, W46.sherlock-ok, W46.capture-ladder) — About 24 variants by 991 pages for all four readers, the 27B share alone about 360 GPU-hours. Owner, 2026-10-22: conditional, not the full grid. After W46.capture-ladder reports, the preparing session names the question it leaves open (a defect, reader or severity whose effect the 96 and the two-severity subset could not settle) and runs only the variants and readers that question needs; if none is open, it closes this item with that finding instead. A pilot sets the GPU-hour estimate, written in the item notes before the hand-over; the filed grid (about 24 variants by 991 pages, the 27B alone about 360 GPU-hours) is the ceiling, not the plan. (blocked-on: W46.nice-to-have) detail: execution-plans/processing-review/10-gap-audit.md §5 item 27
- [ ] **`W46.enh-ocr-input-ppocr` — PP-OCRv6 on the two DocRes arms of W46.enh-ocr-input [XS]** (lane: segbench) (uses: light) (cluster: sherlock) (blocked-on: W46.enh-ocr-input) — Sherlock's PP-OCRv6 job (49137314) read a list made before DocRes's images existed, so its rows lack DocRes appearance and deshadow (192 images, about 70 s on one GPU at that job's rate). Nice-to-have: DocRes moved no other reader beyond noise (Vision +0.7/+0.3, Qwen3-VL 8B −1.0/+0.5, GLM-OCR +0.1/+0.1), so the answer is unlikely to change the no-enhancement default. The images are in `sherlock-results/enh-ocr-input-20261022/images/docres-*`; `enh_ocr_input.py` reads the result once `READER_ARMS['ppocrv6']` is dropped. (blocked-on: W46.nice-to-have) detail: segbench-results/enh-ocr-input.md
- [ ] **`W46.ocr-new-open-gold` — Chandra 2 and Infinity-Parser2-Pro through Reading the Archive's scorer [S]** (lane: segbench) (uses: light) (cluster: sherlock) (blocked-on: W46.cluster-waves, W46.ocr-new-open, W46.rta-gold-ok) — The gold arm of W46.ocr-new-open, once the owner's request for the gated HHTR and Jacob gold is granted; Infinity-Parser2-Pro joins once W46.ocr-new-open-sherlock has run it. (blocked-on: W46.nice-to-have) detail: execution-plans/processing-review/10-gap-audit.md §5 item 18
