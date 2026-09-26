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


## Autonomous daemon — handoff integrity (2026-08-13)


## Autonomous daemon — document budgets (owner, 2026-08-12)

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

### LOW

### Follow-ups discovered while fixing Wave 23

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
From the 2026-07-28 Daemon Report walkthrough. The headless VM lane is now shared by Reader and Notes:
`W21.vmgui-a` shipped one per-app configuration table for both entry points, `W21.vmgui-b` made its fixtures
corpus-free, and `W21.vmgui-c` made the Notes suite green. The remaining GUI gap was **Processor**, which had no
test target and carried the Keychain risk described below. Completing the lane drained that backlog off-screen
while retaining the existing Reader and Notes behavior rather than reintroducing Reader-only assumptions.

**W21.vmgui is complete — see [`SUITE_TODO_DONE.md`](SUITE_TODO_DONE.md) for its 2026-08-27 completion
record.** Reader, Notes, and Processor use the shared per-app table with corpus-free scratch fixtures and
launch safeguards; the gate rotates one route per run.
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
    off-window again. **W14.4 (c) is now deterministically covered by `W21.vmgui-c-fu`.**
  - [x] **W21.vmgui-d — Processor lane from zero, then drain the Processor GUI backlog [L]** (blocked-on:
    W21.vmgui-c). Processor previously had **no test target of any kind**, **no `schemes:` block** (it relied on
    Xcode autocreation), **zero `accessibilityIdentifier`s** in `Sources/` (vs 4 files Reader / 11 Notes), and no
    UITest launch-arg override. This item creates all four: (1) an `ArchiveProcessorUITests` target
    (`bundle.ui-testing`, `TEST_TARGET_NAME: ArchiveProcessor`, `CODE_SIGN_IDENTITY: "-"`,
    `CODE_SIGNING_REQUIRED: NO`, **`ENABLE_HARDENED_RUNTIME: NO`** — the W7.1 finding: an ad-hoc-signed runner
    can't load the xctest plugin under hardened runtime, and `settings.base` sets it YES); (2) an explicit
    `schemes:` block mirroring Notes with the UITest target `[test]`-only, so `-scheme ArchiveProcessor … build`
    keeps working for `launch.sh`, `test-smoke.sh` and `scripts/e2e-phone-mac.sh`; (3) `accessibilityIdentifier`s
    on exactly the surfaces under check (Settings provider rows + "Set up (guided)…", `ProviderKeyWizard`, the
    drop zone + Tagging panel in `OCRView`); (4) a scratch launch config (guest `mktemp` IN/OUT) — Processor is
    **not sandboxed**, so no temporary-exception entitlement is needed.
    **DONE 2026-08-27, this commit:** scratch-only Processor VM suite **4/4**, existing Reader **29/29**, and
    Notes **21/21** all passed; the sighted Processor capture is
    `~/.tart-mirror/vm-artifacts/processor/sighted.png`, its XCUITest evidence is
    `~/.tart-mirror/vm-artifacts/processor/xcuitest.log` and `processor/shots/`. The fixture never mounts a
    corpus or writes a key. **Keychain posture — why the VM is the right place, and how to keep it that way.** The host prompt comes from
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

- [ ] **W21.e2e-verify — `W21.e2e-fu2` is ticked DONE but its round-trip was never run on real hardware [S · MED · MONEY · daemon-runnable].**
  `3767702` changed how the test-only LAN READY line publishes the bearer CaptureServer authenticates, and it is
  ticked in `SUITE_TODO_DONE.md`. Its evidence is a fresh Debug build, the scratch-only Recovery driver at ALL PASS
  across all three formats, and an independent adversarial review that caught a real stderr leak and a stale guide.
  What it does NOT have is a single run of the thing it changed: `scripts/e2e-phone-mac.sh`, the only test that
  composes both real apps — emulator running the identical Android build, injecting known fixtures through the real
  capture path, to a headless Mac doing real Gemini OCR — was attempted on 2026-08-19 and never started, because the
  Keychain Gemini lookup blocked before any app, emulator, OCR request or output.
  ⚠️ **Why this is filed at all (2026-08-24):** that fact lived only in the 2026-08-19 Daemon Report entry, and the
  walkthrough that day closed that entry under a `### ✅` anchor — in a gitignored file. So a shipped-and-ticked item
  with an unrun verification had no representation in either tracker. Ticking a box on a scratch proof while the
  composed gate never fires is the vacuous-pass shape this repo keeps re-learning; the point of this item is that the
  gap is now visible to `next-queue-item.sh`.
  ✅ **The blocker is cleared.** The partition-list repair was re-run 2026-08-24 15:52:13 and Gemini reads prompt-free
  from `/usr/bin/security`, so `OCR_KEY` can stay unset and the Keychain fallback is itself part of what gets proved.
  Run `caffeinate -di scripts/e2e-phone-mac.sh` from `ArchiveProcessor` and let `KEEP_EMU` default to `onfail` so a
  failure leaves the emulator inspectable. Prereqs verified present 2026-08-24: AVD `ap_test36`, adb, emulator,
  xcodegen, and all three fixtures plus `ground_truth.json`.
  ⛔ If the Processor prompts for a provider key mid-run, click plain **Allow**, never **Always Allow** — the latter
  evicts `apple-tool:,apple:` from the partition list and breaks the CLI underneath the running test (see
  `W21.seed-fu3`). Cost is a few cents: 3 fixtures through `gemini-2.5-flash-lite`, isolated output under
  `/tmp/ap-e2e-*` at umask 077, never the real corpus. On PASS, say so in the Session Log and note that the composed
  gate has finally fired; on FAIL, the first question is whether it is the bearer change, the Keychain path, or
  emulator flake — the scratch driver passing means environment is the likelier of the three, not the certain one.
  | files: ArchiveProcessor/scripts/{e2e-phone-mac.sh,E2E-PHONE-MAC.md} | S | med | open
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
2026-07-18. **A4 is NOT recreated here:** R13d shipped the intended removal of the `ArchiveSuite` marker
surface. ⛔ Do not file A4 again. **D5** also shipped (W14.4b,
live-verified 2026-07-17).

**Phase C — safety-net & regression tooling.** These re-arm guards, so they sort with the gate work rather
than with Notes features.

✅ **Phase C is complete.** W9.c6's scale-test result is recorded in `SUITE_TODO_DONE.md`.


**Phase B — wire the built-but-dead features.** The high-value core: library code that shipped without a UI
entry point. Mostly **Tier-2** (they write note front-matter or project Finder tags).

✅ **`W9.b3` (plan B3 — note retitle + tag editing) shipped 2026-09-20.** Its completion record is in
`SUITE_TODO_DONE.md`; that one work item covered the full list affordance, title→filename projection,
inspector subjects, and audited Finder-tag sync. Do not re-file its former `W22.notes-rename` duplicate.

**Phase D — secondary UI affordances & polish.** All LOW–MED, Tier-1 unless noted, each independently
shippable. **D5 is already shipped** (W14.4b) and is not listed.

- [ ] **`W9.d2.review-folder-graph` — folder mutations can cross folder deletion [M, Tier-2].** Baseline
  `74627e1`; `OrganizationStore.renameFolder`, `moveFolder`, `createFolder`, `deleteFolder`. Concurrent
  rename/move can resume after deletion using a stale array index; child creation can commit under a parent
  after delete snapshots its children. Independently confirmed during W9.d2 review; report archived under
  `old/`. | ArchiveNotes/macOS/Sources/ArchiveNotes/Index/OrganizationStore.swift | M | low | none
- [ ] **`W9.d3` — template body editing is not routed in-app [M].** Plan D3. | Views/TemplatesManagerView.swift
  | M | low | none
- [ ] **`W9.d4` — no inline quality quick-edit [S].** Plan D4. Add a borderless quality `Menu` (None + 1–3)
  in the list/detail cell. The context-menu "Set Quality ▸" shipped with W9.d2; retain the post-W19
  Quality vocabulary. |
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
  and the tag grammar shared by `check-handoff.sh`'s `items()` and `check-tracker-sync.sh` matches
  `^[A-Za-z0-9][A-Za-z0-9._-]*` after stripping bold, so a leading `(` made `match()` fail and the item was
  dropped from BOTH guards before either could compare it. It was the 28th item invisible to the daemon and
  neither guard could ever have said so — see `W31.handoff-fp2`. **Scope it before working it:** its only
  surviving sub-bullet is DROPPED (below), so what "unified storage path" now means is undecided.
  **Moved to the plan's HOLD QUEUE 2026-09-24.** It had reached the head of the WORK QUEUE, where every daemon
  session would have spent its item guessing a scope that only the owner can set. The owner either defines it
  or closes it.
  - ~~Reader parses/**hides** `ArchiveSuite` in-UI; corpus **back-fill** + Processor **stamping**~~ — **DROPPED
    (owner 2026-07-16; R13d shipped the removal).** Nothing consumes or emits the old marker, so there is
    nothing to hide, back-fill, or stamp. This also removes the only reason for a corpus-wide tag back-fill —
    the Suite's single highest-risk operation. Do not re-propose it.

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
