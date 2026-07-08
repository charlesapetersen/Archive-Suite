# Archive Suite — Adversarial Audit Report

**Date:** 2026-07-08
**Scope:** Leaner 8-finder run over the highest-risk surfaces plus tonight's 14 commits. Every finding was adversarially verified (refute-by-default): only defects that survived a hostile re-read are reported as CONFIRMED.

---

## 1. Executive Summary

**Confirmed defects: 10** — 0 critical, 1 high, 7 medium, 2 low.
**Uncertain (owner triage): 0.**

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High     | 1 |
| Medium   | 7 |
| Low      | 2 |

**Overall health:** No critical/crash-class or unbounded-data-destruction defects surfaced in this pass. The one **high** finding is a genuine Core-Directive violation in the Reader: a facet classification drives a destructive multi-token tag removal, silently destroying a collision subject or a second date token on a routine inline edit. The **medium** cluster is dominated by the Processor's batch/standard **resume lifecycle** — the very path batch mode is built around (quit/relaunch during long turnaround) is not faithfully mirrored from the interactive path, so resumed runs mis-file outputs, drop the dual-output image half, and can wedge the UI on a transient network blip. The Reader's OCR/full-text search surface has several silent wrong-result bugs (5000-row cap, stale scope after root switch). The two low-severity items are a cosmetic count mismatch and a loopback OAuth hardening gap (PKCE + client_secret bound the impact to sign-in DoS).

Recommended priority order: (1) the Reader tag-loss bug (irreplaceable tagging), (2) the Processor resume-lifecycle trio (paid batch results mis-filed / lost outputs / UI wedge), (3) the Reader search-correctness bugs, then (4) the two low items.

---

## 2. Confirmed Findings

Ranked critical → low, grouped by app.

### Archive Processor

#### P-1 (medium) — Resumed batch/standard runs silently drop the dual-output exported original image (and its tags)
**File:** `ArchiveProcessor/ArchiveProcessor/Sources/ArchiveProcessor/OCR/OCRProcessor+Pipeline.swift:379`
**Finder:** proc-tagging-write · **Category:** correctness / lost-output

**Failure scenario:** With the default "Output image file" setting ON (dual output: PDF + renamed sized original JPG, each tagged), the interactive `startProcessing` sets `exportOriginals = outputImageFile`, calls `exportOriginalImages()` (Pipeline:1082), and threads `exportedImageMap` into `organizeOutput` (Pipeline:1099) — both halves written and filed. But when a run completes via **resume** (the normal lifecycle for batch mode, and the recovery path for any interrupted standard run), `resumePendingBatch`/`resumePendingRun` (OCRView.swift:830-865) restore taggingMode/rotationMode/mergeDocuments but never set `processor.exportOriginals`, and `resumeBatch`/`resumeRun` never call `exportOriginalImages()` and call `organizeOutput` WITHOUT `exportedImageMap`. `exportOriginals` defaults to false (OCRProcessor.swift:41) and is not persisted in the pending manifest, so after relaunch it is false: no exported JPGs are produced. Result: the resumed run emits **PDFs only** — the exported original-image half and its mirrored Unread/subject/date/color tags are silently missing, no error or log.

**Suggested fix:** Mirror `startProcessing` exactly: (1) in `resumePendingBatch`/`resumePendingRun` set `processor.exportOriginals = outputImageFile`; and (2) in `resumeBatch`/`resumeRun` call `await exportOriginalImages()` before `performDocumentMerging(...)` and pass `exportedImageMap:` into the `organizeOutput(...)` calls (Pipeline:379 and :649). Persisting `exportOriginals` in PendingBatch/PendingRun would make it robust across relaunch rather than relying on the live @AppStorage value.

---

#### P-2 (medium) — Batch resume persists ephemeral temp-JPEG paths for PDF inputs, breaking cross-relaunch resume
**File:** `ArchiveProcessor/ArchiveProcessor/Sources/ArchiveProcessor/OCR/OCRProcessor+OCR.swift:367`
**Finder:** proc-ocr-batch-resume · **Category:** correctness

**Failure scenario:** `startProcessing` (Pipeline:920) calls `convertPDFInputs(files)`, which renders each PDF input to a temp JPEG named `<UUID>.jpg` under `FileManager.default.temporaryDirectory` (PDFToImageConverter.swift:59-60), and passes that converted list as `imageURLs` into `performBatchOCR`. `performBatchOCR` then persists the batch manifest with `fileURLs = imageURLs` (the temp JPEG paths) and computes `runFingerprint` over those temp paths (OCR.swift:365-379) — asymmetric with the non-batch `PendingRun`, which persists the ORIGINAL files (Pipeline:948) and re-runs `convertPDFInputs` on resume (Pipeline:444). For a batch containing any PDF, after relaunch (the whole point of resume) and Resume Batch, `resumeBatch` (Pipeline:268) builds jobs from `pending.fileURLs` = the temp JPEG paths. Those temp files have been purged by the OS, so: (a) every output PDF is named after a random UUID instead of the original base name; (b) `processBatchResults` uses the missing temp JPEG as the page-1 image, producing a blank/failed image page; and (c) `pendingBatchMatches()` can never return true because the stored fingerprint is over ephemeral UUID temp paths that no re-selection of the original PDFs can reproduce, so auto-resume matching silently fails. The already-paid server-side batch results are effectively mis-filed.

**Suggested fix:** Persist the ORIGINAL input files in PendingBatch (mirror PendingRun): thread the original `files` into `performBatchOCR` alongside the converted `imageURLs`, store `files` in the manifest and compute the fingerprint over `files`, and in `resumeBatch` re-run `convertPDFInputs(pending.fileURLs)` to regenerate temp JPEGs while building jobs from the original URLs — exactly as `resumeRun` does at Pipeline:444.

---

#### P-3 (medium) — resumeBatch leaves isProcessing=true on a transient poll interruption, wedging the UI until relaunch
**File:** `ArchiveProcessor/ArchiveProcessor/Sources/ArchiveProcessor/OCR/OCRProcessor+Pipeline.swift:288`
**Finder:** proc-ocr-batch-resume · **Category:** correctness

**Failure scenario:** `resumeBatch` sets `isProcessing = true` (line 254) and `pendingBatchInfo = nil` (line 255). If `pollBatchUntilComplete` hits a transient network streak (>=10 consecutive errors) or the 1500-poll safety timeout, it sets `batchPollInterrupted = true` and returns without a terminal state. `resumeBatch` then runs `if batchPollInterrupted { activeBatch = nil; return }` (line 288) WITHOUT resetting `isProcessing` — the exact case `startProcessing` handles correctly with `isProcessing = false; return` (line 943). Result: `isProcessing` stays true for the session, so every Start/Resume button (`.disabled(... || processor.isProcessing)`, OCRView.swift:266/287) is permanently disabled, and because `pendingBatchInfo` was cleared the "Pending Batch" GroupBox (OCRView.swift:255) is also hidden. A user who hits a brief Wi-Fi drop while resuming is fully stuck — no visible Resume control, all actions disabled — until quit/relaunch, even though the paid batch is still valid and resumable on disk. (The interrupted path also skips `deletePendingBatch()`, so relaunch does correctly re-detect it.)

**Suggested fix:** On the transient-interruption early return, mirror `startProcessing`: set `isProcessing = false` before returning, and restore the banner, e.g. `if batchPollInterrupted { activeBatch = nil; isProcessing = false; checkForPendingBatch(); return }`.

---

#### P-4 (medium) — Relay session-complete marker is not epoch/token-validated, unlike photos and segments
**File:** `ArchiveProcessor/ArchiveProcessor/Sources/ArchiveProcessor/Net/FileRelayReceiver.swift:220`
**Finder:** proc-net-protocol · **Category:** correctness / run-isolation

**Failure scenario:** In `scanOnce`, photo objects (lines 152-153) and segment-complete objects (line 199) are gated on `meta["token"] == token && meta["epoch"] == epoch`. The session-complete branch (lines 220-234) never reads the object body — it acts purely on the fixed filename `_session.complete.json`. The relay/Drive folder is keyed only by the STABLE token, while `epoch = sessionId` changes on any fresh (non-recovered) launch. A prior run that shut down before its session-complete fired (e.g. deferred because a segment/page was still undrained) leaves a stale `_session.complete.json` (old epoch) in the folder; the orphan `sweep()` hits `default: break` for `.sessionComplete`, so it never ages out. When a NEW session (same token, new epoch) reaches a moment where its own sidecars are drained and no segments are deferred (`!anyUnprocessed && report.segmentsDeferred.isEmpty`), the stale marker fires: it calls `completeAllOpenDocGroups()` — force-surfacing Mac tag cards for document segments the operator has NOT yet ended — and posts "Phone finished capturing", then deletes the marker. This defeats the per-run epoch guard the other object kinds enforce. (Most-severe impact requires pages already streamed/ingested but the segment not yet ended when the marker fires — a reachable but narrower window; otherwise harm is a spurious completion status.)

**Suggested fix:** Parse the session-complete body and require token+epoch to match before acting, exactly as the segment branch does: `guard let data = store.readData(n), let meta = RelayObjectFormat.parse(data), meta["token"] == token, meta["epoch"] == epoch else { continue }`. A non-matching/foreign marker should be left alone, never acted on or deleted.

---

#### P-5 (low) — OAuth loopback redirect listener binds all interfaces and accepts an unsolicited code (no state)
**File:** `ArchiveProcessor/ArchiveProcessor/Sources/ArchiveProcessor/Net/DriveAuth.swift:127`
**Finder:** proc-net-protocol · **Category:** security

**Failure scenario:** `LoopbackRedirectServer.start()` creates `NWListener(using: .tcp)` with no host constraint, binding to ALL local interfaces (0.0.0.0/::), even though the `redirect_uri` handed to Google is `http://127.0.0.1:<port>` (RFC 8252 §7.3 requires loopback-only binding). During the sign-in window the ephemeral port is reachable from the LAN. The handler sends no `state` parameter (lines 83-92) and accepts the first inbound request carrying any `?code=` value, firing `onCode(code)` once and stopping the listener. A malicious local app or same-LAN device can therefore (a) race a forged `GET /?code=BOGUS`, stopping the listener and aborting the legitimate redirect (sign-in DoS), and (b) force a token exchange with an attacker-chosen code. PKCE + client_secret prevent actual token theft, so impact is bounded to sign-in abort/DoS and accepting unsolicited input on a needlessly-exposed socket.

**Suggested fix:** Bind loopback only — construct `NWParameters` with `requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)` — and add a random `state` query item to the authorize URL, verifying it on the redirect before exchanging the code.

---

### Archive Reader

#### R-1 (high) — Facet-replacing edits remove EVERY raw token that parses as that facet, silently dropping a collision subject or a second date token
**File:** `ArchiveReader/ArchiveReader/Sources/ArchiveReader/Core/TagEditing.swift:26`
**Finder:** reader-tagwriter · **Category:** data-loss

**Failure scenario:** A file's Finder tags are `["1980", "Jerry Brown", "1984"]`, where 1980 is the real year and "1984" is a subject (a document about the book/topic 1984) — exactly the subject-vs-facet collision CLAUDE.md's Verified Facts call out. `DocumentTags.parse()` classifies BOTH "1980" and "1984" as the year facet (last one wins; "1980" is invisible). The user sets the year to 1981 via the inline Date popover (InlineEditCells.swift:78 → `applyEdit(.setYear(1981))`). `TagEditing.delta` builds `remove = tokens(in: tags){ parseYear($0) != nil } = ["1980","1984"]`, `add = ["1981"]`. `TagWriter` faithfully applies `new = fresh − {"1980","1984"} + {"1981"}`: the subject "1984" AND the original year "1980" are both destroyed by a single year edit. Identical loss occurs on `setYear(nil)` (Clear), on `setPriority` when a subject is literally "P8", on `setMonth` with two month-shaped tokens, and `setDay` with two "Day N" tokens. This directly violates the Core Directive ("MUST NOT lose any tag unintentionally" / "facet classification is display-only and must never drive a destructive write"): the parser's facet classification is being used to compute the remove-set.

**Suggested fix:** Do not build the remove-set from a facet predicate over ALL raw tokens. Have `DocumentTags.parse` record the exact raw token(s) it actually consumed per single-valued facet (yearToken/monthToken/dayToken/priorityToken), route any ADDITIONAL facet-shaped tokens into `subjects` so they stay visible, and in `TagEditing` remove only that one recorded token for the facet being replaced (or minimally the single currently-classified token, not every token that could parse as the facet).

---

#### R-2 (medium) — Full-text search silently truncates at 5000 rows, dropping matches on a large corpus
**File:** `ArchiveReader/ArchiveReader/Sources/ArchiveReader/Search/ContentIndex.swift:94`
**Finder:** reader-core · **Category:** correctness

**Failure scenario:** `search(_:)` runs `SELECT path FROM fts WHERE fts MATCH ? LIMIT ?` with a default limit of 5000, and the sole caller passes no limit, so the cap always applies. On the production scale (~150,000 PDFs) a common OCR term easily matches more than 5000 documents; with no `ORDER BY`, SQLite FTS5 returns the first 5000 by rowid (insertion order — unrelated to relevance or the active tag filter), and the LIMIT is applied before the tag filter is intersected. `NavigationModel.recompute()` filters `base` by `ftsPaths.contains(path)` AND-combined with tag/priority/read filters, so a document that genuinely contains the term AND satisfies the tag filter is silently omitted purely because its FTS rowid fell past the 5000th match. No truncation indicator exists (the search glyph only tests `ftsPaths != nil`). A historian concludes a term/document is absent when it is not.

**Suggested fix:** Since the result is used only for set-membership AND-ing, return all matching paths (stream all matching rowids) rather than capping — or raise the cap well above max corpus size, or track whether the limit was hit and surface a "showing first N of many" indicator so results are never silently incomplete.

---

#### R-3 (medium) — Changing the archive root leaves stale ftsPaths active, showing wrong/empty OCR-search results
**File:** `ArchiveReader/ArchiveReader/Sources/ArchiveReader/Views/NavigationModel.swift:437`
**Finder:** reader-core · **Category:** correctness

**Failure scenario:** With a non-empty OCR search active (`fullTextQuery` set, `ftsPaths` holding matching absolute paths from the current corpus), the user picks a new archive root via `chooseRoot()`. `chooseRoot` (lines 437-449) resets `filter.pathPrefix` and restarts the library, but never clears `fullTextQuery`/`ftsPaths` nor re-runs `runFullTextSearch()`. When the new scope finishes gathering, `libraryDidChange → recompute()` filters the new files by the stale `ftsPaths` (paths from the OLD root), so essentially no new-root file matches and the list shows empty (or, under root overlap, a stale subset) — while the search box still displays the query text and the FTS indicator stays lit. No caller re-derives `ftsPaths` until the user manually re-submits or clears the search.

**Suggested fix:** In `chooseRoot()` (after adopting the new scope) either clear the OCR search (`fullTextQuery = ""; ftsPaths = nil`) or call `runFullTextSearch()` so `ftsPaths` is recomputed against the new corpus. Mirror this in any other scope-change path.

---

#### R-4 (medium) — applySaved(_:) doesn't sanitize a stale pathPrefix, silently showing an empty list
**File:** `ArchiveReader/ArchiveReader/Sources/ArchiveReader/Views/NavigationModel.swift:147`
**Finder:** reader-core · **Category:** correctness

**Failure scenario:** A user saves a smart folder while scoped to a subfolder, so `search.filter.pathPrefix` = e.g. `/Volumes/RootA/Box3`. Later they switch the archive root to `/Volumes/RootB` (or the same folder is re-granted at a different path) and click the saved smart folder. `applySaved` does `filter = search.filter` verbatim, restoring the RootA pathPrefix. In `recompute()`, `LibraryFilter.matches` rejects every RootB file, so the nav list, tag cloud, and status bar all go empty (activeFilterSummary shows a weak "folder: Box3" hint, but the folder isn't in the current tree). `restoreViewState()` (lines 279-282) already contains the exact guard that drops a pathPrefix not under the current root — `applySaved` just doesn't apply it, so the two entry points into the same filter state disagree.

**Suggested fix:** Factor the `restoreViewState` pathPrefix-vs-root check into a helper (e.g. `sanitizedPathPrefix(_:against: rootStore.root)`) and call it inside `applySaved` before assigning `filter`, dropping a pathPrefix that is neither the current root nor a `root + "/"`-prefixed subtree. Optionally surface a status message when a stale scope was dropped.

---

#### R-5 (low) — needsAttentionCount is corpus-wide and never pruned, so it over-counts after a root switch
**File:** `ArchiveReader/ArchiveReader/Sources/ArchiveReader/Search/ContentIndex.swift:151`
**Finder:** reader-core · **Category:** correctness

**Failure scenario:** `needsAttentionCount()` runs `SELECT count(*) FROM files WHERE readable = 0 OR has_text = 0` over the entire SQLite index (`content-index-v2.sqlite3`, a single shared DB in Application Support that is never pruned). Rows for files removed from the corpus, or belonging to a previously-selected root, remain forever; a root switch only cancels the in-flight pass. Meanwhile the `needsAttentionOnly` filter this count drives is path-scoped to the current library. So after a root switch (or deleting/moving flagged files), the "N need attention" badge reports more than the filter can actually surface — a cosmetic count mismatch, not a data-safety issue.

**Suggested fix:** Scope the count to the current library — pass the current path set and count only `readable=0`/`has_text=0` rows among those paths (as `formatFlags` already does per-path), or prune index rows whose path is no longer in the active scope before counting.

---

### Cross-app

No cross-app findings in this pass.

---

## 3. Uncertain — Owner Triage

None. Every finding that surfaced in this run either survived adversarial verification (reported above) or was refuted and dropped.

---

## 4. Methodology Note

All findings are model-generated. Each of the 10 confirmed findings above was adversarially verified against the source (refute-by-default: the verifier actively tried to disprove the claim and traced every link in the failure chain through the cited code before confirming).
