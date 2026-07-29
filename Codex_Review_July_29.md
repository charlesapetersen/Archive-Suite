# Codex Review — July 29, 2026

## Scope and baseline

- Reviewed the exact current remote `main` revision, `bfcb38e119268e50015b19721391eaa4e5ec823a`, after verifying `origin/main` immediately before writing this report.
- Scope covered Archive Processor (macOS, Android, and only severe parity issues in the parked iOS companion), Archive Reader, Archive Notes, the shared `packages/ArchiveCore`, and suite-level scripts/release tooling.
- This was a static, read-only review. No bugs were fixed, no source code was changed, no project was generated or built, and no real archive/Notes store/device was exercised.
- Severity reflects likely user impact, irreversibility, and reachability. “High” is reserved for silent data loss, destructive cleanup, or archival output that can be accepted while missing the source image.

## Deduplication

The findings below were checked against:

- `SUITE_TODO.md`
- each app’s `KNOWN_ISSUES.md`, `CLAUDE.md`, `AGENTS.md`, and feature notes
- `execution-plans/archive-notes/00-overview.md`
- `execution-plans/archive-notes/09-gap-closure.md`
- `execution-plans/devonthink-import.md`
- the existing ignored maintenance review/progress/autonomous-plan material

Items already queued, deliberately deferred, parked, or closed were not re-reported. Notable exclusions include Processor W3.cap-r1…r6 and W3.net-r1; W16/W17/W19/W20/W21/W22 work; the owner-closed immutable-staging-generation proposal; Notes W9 gap-closure work; DEVONthink import work; the fixed ArchiveCore tag lost-update/duplicate-tag work; known Notes asset-write failures; and the parked iOS backlog. A related known item is mentioned below only where a currently shipping path was left uncovered.

## Confirmed findings, most important first

### 1. High — Processor startup cleanup can recursively hard-delete recovery and relay content

**Affected code:** `ArchiveProcessor/macOS/Sources/ArchiveProcessor/Capture/CaptureSession.swift:317-334,357-364,398-418,854-872`

`CaptureSession` runs `pruneEmptySessions` at every launch over the user-visible `~/Pictures/Archive Processor Live Capture` root. The function treats every child directory as an app session, recognizes only a top-level `.jpg` or a narrow set of files directly under `_processed`, and otherwise calls recursive `FileManager.removeItem` on the entire directory. It does not first prove that the directory is an Archive Processor session or that all unknown content is disposable.

This also reaches app-owned data when the offline/test local-relay transport is used: its default location is `<backupRoot>/_relay/<token>`. `_relay` itself contains a nested token directory rather than a top-level JPEG, so launch pruning can classify it as empty and hard-delete pending relay objects. An operator-created folder containing only HEIC files, notes, nested recovery material, or an unrecognized journal has the same fate.

**Queue check:** no current task or known-issue entry covers `pruneEmptySessions`, `_relay` exclusion, or positive identification of session directories.

### 2. High — Concurrent edits to the same Notes item silently overwrite one another

**Affected code:** `ArchiveNotes/macOS/Sources/ArchiveNotes/Core/NotesModel.swift:13-18,575-588`; `ArchiveNotes/macOS/Sources/ArchiveNotes/Store/NoteStore.swift:19,72-77`; `ArchiveNotes/macOS/Sources/ArchiveNotes/Core/ExtractBuilder.swift:238-245`

Every body/date/quality edit performs separate actor calls to load the whole item and later save the whole item. `NoteStore` serializes each individual call, but it does not serialize the complete read-modify-write transaction. Because `NotesModel` is main-actor isolated but reentrant at each `await`, two tasks can both load the same old item, apply different edits, and save in either order. The last whole-item save silently drops the other task’s body, metadata, or source blocks.

This is reachable through two windows showing the same item, body autosave racing a metadata edit, or `ExtractBuilder.append` racing an ordinary item mutation.

**Queue check:** the existing lost-update work is W15.tu3/tu4 for Finder-tag metadata, not Notes’ own `.md` item transaction. Existing editor tests cover cross-item selection/autosave races, not concurrent edits to one item.

### 3. High — Confirming a stale folder-removal alert can trash a note that still has a valid membership

**Affected code:** `ArchiveNotes/macOS/Sources/ArchiveNotes/Index/OrganizationStore.swift:165-184`; `ArchiveNotes/macOS/Sources/ArchiveNotes/Core/NotesNavigationModel.swift:264-282`

`removeMembership(item:folder:)` decides `.wasLastInstance` solely from the item’s total membership count. It does not first verify that the requested `(item, folder)` membership still exists. The confirmation path then force-removes that stale pair and unconditionally trashes the note.

A normal two-window sequence triggers this: a delete alert opens for the sole membership in folder A; the other window moves the note from A to B; the user confirms the stale A alert. The fresh count is one because B exists, so the stale removal is called “last instance”; force-removing A is a no-op, and the note is moved to Trash despite its valid B membership.

**Queue check:** the existing test covers adding B while A remains, producing a count of two. No queue item or test covers A being removed or moved while the alert is open.

### 4. High — Android can permanently delete an unuploaded capture without confirmation

**Affected code:** `ArchiveProcessor/ArchiveCapture/app/src/main/java/com/archiveprocessor/capture/ui/CaptureScreen.kt:206-219`; `ArchiveProcessor/ArchiveCapture/app/src/main/java/com/archiveprocessor/capture/capture/CaptureViewModel.kt:390-423,581-595`

The Android thumbnail gesture wires directly to a select → arm → delete cycle. The final tap deletes the local file and model item regardless of whether the photo is pending, uploading, or failed, and it neither confirms the destructive action nor cancels/joins the item’s upload job. If deletion wins before the upload coroutine opens the file, no Mac copy can be created.

**Queue check:** Processor’s known issue and autonomous-review record at `ArchiveProcessor/KNOWN_ISSUES.md:1144-1156` cover and fix this bug class only in the iOS companion. Android has no corresponding guard or queued parity item.

### 5. High — Live Capture can accept a placeholder-only PDF as successfully archived and then retire the source image

**Affected code:** `ArchiveProcessor/macOS/Sources/ArchiveProcessor/OCR/PDFGenerator.swift:9-26`; `ArchiveProcessor/macOS/Sources/ArchiveProcessor/Capture/LiveCaptureProcessor.swift:625-656,976-1019,1100-1159`; `ArchiveProcessor/macOS/Sources/ArchiveProcessor/Capture/CaptureSession.swift:599-610`

When the source image cannot be decoded or embedded, `PDFGenerator` inserts a visible placeholder page and still returns a successfully written PDF. Live Capture treats existence of that PDF as a complete page, includes it in the filed set, and finalization moves the corresponding raw capture to Trash/removes it from the active session.

A source that becomes unreadable after OCR, or that is regenerated from a cached OCR result after its image bytes become corrupt/unsupported, can therefore produce an apparently filed archival document whose image page contains no scan. The recovery source is retired even though output-content validity was never established.

**Queue check:** W17.stg1 covers staging-manifest integrity, not validation that each authoritative PDF actually embeds its source image. The closed immutable-generation proposal does not address malformed bytes.

### 6. Medium — Re-pairing Capture can leave an upload owned by the old Mac and delete the phone copy after the wrong acknowledgement

**Affected code:** Android `ArchiveProcessor/ArchiveCapture/app/src/main/java/com/archiveprocessor/capture/capture/CaptureViewModel.kt:201-210,246-255,295-302,409-423,574-623`; parked iOS parity at `ArchiveProcessor/ArchiveCaptureiOS/Sources/ArchiveCaptureiOS/Capture/CaptureViewModel.swift:148-157,418-456,500-509,532-544`

Disconnect/re-pair clears the current client but does not cancel upload jobs or invalidate `inFlightUploads`. A newly paired client therefore refuses to enqueue the same item, while the existing coroutine continues using its captured old client. If the old Mac remains reachable and acknowledges the upload, the current model marks the item uploaded and schedules removal of the phone file even though the newly selected Mac/session never received it.

The result is a silent destination mismatch: the operator has paired to one Mac, but the only desktop copy can be stranded on the Mac they left. The old Mac has acknowledged a durable copy, so this is not classified as data loss; it is still a serious ownership/routing failure.

**Queue check:** the existing re-pair known issue covers Mac QR/status/USB user experience, not endpoint-generation ownership. This also contradicts the Capture requirement that disconnected items re-upload to the new endpoint.

### 7. Medium — Reader cannot display or find pages 3 and later in Processor’s intentional merged-PDF format

**Affected code:** `ArchiveProcessor/macOS/Sources/ArchiveProcessor/OCR/PDFGenerator.swift:417-440`; `ArchiveProcessor/macOS/Sources/ArchiveProcessor/OCR/OCRProcessor+Tagging.swift:828-850`; `ArchiveReader/macOS/Sources/ArchiveReader/Views/DocumentViewerModel.swift:42-43,67-73`; `ArchiveReader/macOS/Sources/ArchiveReader/Core/DocumentFind.swift:3-6,67-84`

Processor intentionally merges multi-page documents as `image1, text1, image2, text2, …` and its ordinary merge path transfers Finder tags to the merged PDF. Reader, however, exposes only PDF pages 0 and 1. Its next/previous actions move between selected file URLs rather than between internal page pairs, and in-document Find explicitly discards every match on PDF page index 2 or later.

Opening a merged document with two or more source pages therefore makes later scans and OCR pages inaccessible in Reader, even though Reader’s full-text index extracts all pages.

**Queue check:** W18 concerns switching between PDF and separately exported JPEG references. No current item covers navigation within an intentional interleaved multi-page PDF. The SPEC/TODO explicitly says consumers must not hard-assume two pages.

### 8. Medium — Notes inline-image resolution can escape the current item and read another item’s asset

**Affected code:** `ArchiveNotes/macOS/Sources/ArchiveNotes/Editor/MarkdownBridge.swift:200-229,242-246`; `ArchiveNotes/macOS/Sources/ArchiveNotes/Editor/InlineImageAttachment.swift:108-124,234-237`; `ArchiveNotes/macOS/Sources/ArchiveNotes/Core/NotePassageSource.swift:126-133`

Markdown image paths are passed unchanged to `ItemAssetStore.resolveAsset`, which appends the value to the item directory and only checks whether the resulting path exists. There is no `assets/` restriction, component-boundary check, or canonical/symlink containment check.

A raw or synced note containing `![](../OTHER_UUID/assets/private.png)` can render another note’s image; further `..` components can leave `items/` wherever the active sandbox grant permits. Copy/extract code can then snapshot those bytes into a different item, corrupting provenance as well as the visual boundary between notes.

**Queue check:** existing Notes asset items cover asynchronous write failure and same-name write reservation. The path-traversal tests protect the write seam, not this read seam.

### 9. Medium — Reader page-level durable links are broken at command, creation, and reveal time

**Affected code:** `ArchiveReader/macOS/Sources/ArchiveReader/ArchiveReaderCommands.swift:17-19,137-144`; `ArchiveReader/macOS/Sources/ArchiveReader/Views/NavigationWindowView.swift:79-88`; `ArchiveReader/macOS/Sources/ArchiveReader/Views/PreviewSheet.swift:6-30`; `ArchiveReader/macOS/Sources/ArchiveReader/Views/DocumentWindowView.swift:31-34`; `ArchiveReader/macOS/Sources/ArchiveReader/Views/DocumentViewerModel.swift:209-220`; `ArchiveReader/macOS/Sources/ArchiveReader/Views/NavigationModel.swift:639-681`

Three independent defects break the feature end to end:

1. “Copy Archive Link to This Page” requires both focused `NavigationModel` and `DocumentViewerModel`. The full document window publishes only the viewer, so the command is disabled in the place where the user reads a document. It may become reachable only inside the navigation window’s Preview sheet, where a focused viewer is nested under the navigation scene.
2. Direct invocation always writes `page=1`, regardless of the focused text/image pane.
3. Incoming links store `page` in `pendingRevealPage`, then clear it after selecting a row without ever opening the viewer or navigating to that page.

**Queue check:** `execution-plans/archive-notes/00-overview.md:289-292` is the shipped contract and requires the page to be passed to reveal. This is an implementation regression/incomplete implementation against that contract, but no current fix task covers it. W20 is test isolation; W18 is dual-reference behavior.

### 10. Medium — Process Files claims Finder tags were applied after silently discarded tag-write failures

**Affected code:** `ArchiveProcessor/macOS/Sources/ArchiveProcessor/OCR/OCRProcessor+Tagging.swift:253-271,500-519,731-749`; `ArchiveProcessor/macOS/Sources/ArchiveProcessor/OCR/OCRProcessor+OCR.swift:1088-1117`; `ArchiveProcessor/macOS/Sources/ArchiveProcessor/OCR/OCRProcessor+Pipeline.swift:1080-1095`

Automatic tagging, both manual tagging paths, and copy-source tag pass-through discard `MacOSTagger.applyTags` errors with `try?`, then populate `jobs[].appliedTags` as though the output were tagged. On an xattr, coordination, verification, permission, or filesystem failure, the PDF succeeds and the UI/model reports tags that are absent on disk. Reader can then omit the file from tag-driven triage without any warning.

**Queue check:** W3.cap-r1’s swallowed-write task is explicitly scoped to the three Live Capture call sites in `LiveCaptureProcessor.swift`. The ordinary Process Files call sites above remain unqueued; the warning/result mechanism planned for W3.cap-r1 could be shared.

### 11. Medium — Reader can emit durable links using a root GUID that was never persisted

**Affected code:** `packages/ArchiveCore/Sources/ArchiveCore/Links/RootMarker.swift:94-131,145-196`; `ArchiveReader/macOS/Sources/ArchiveReader/Search/RootFolderStore.swift:86-95`; `ArchiveReader/macOS/Sources/ArchiveReader/Views/NavigationModel.swift:1041-1053`

`RootMarker.read` converts every non-ENOENT, non-decoding read failure into “marker absent.” `RootMarker.ensure` then returns its newly generated in-memory marker after any write failure or failed confirmation. Reader accepts that value as a normal `rootMarker` and uses it to create archive links.

On a read-only root, disk-full condition, permission failure, or transient marker I/O error, copied links carry a GUID that changes after relaunch and cannot resolve. A transient failure reading an existing marker can also be mistaken for absence before a replacement write is attempted. The declared `RootMarkerError.readOnly` is never used.

**Queue check:** historical W4 material describes read-only operation as degraded, but no live task makes Reader distinguish a transient marker from a durable one or surface that degradation.

### 12. Medium — Mac tag-card Apply/Skip starts finalization before proving the manifest decision is durable

**Affected code:** `ArchiveProcessor/macOS/Sources/ArchiveProcessor/Capture/CaptureSession.swift:647-653,712-723,779-794`; `ArchiveProcessor/macOS/Sources/ArchiveProcessor/Views/LiveCaptureView.swift:698-701,835-838`

Apply/Skip mutates `macTags` and `resolvedGroupIds`, schedules `liveProcessor.segmentResolved`, and discards the Boolean result of `writeManifest`. The card disappears immediately because it is derived from the in-memory resolved set, and the UI has no failure channel.

If the manifest replacement fails and the app then crashes, recovery reloads the old unresolved state. Stage-for-later loses the operator’s decision; live processing may already have baked or staged output from volatile tags while relaunch resurfaces the group as unresolved, leaving recovered state inconsistent with the produced artifact and potentially asking for a second decision.

**Queue check:** the fixed B9 known issue claims Apply/Skip persistence but did not handle this ignored failure. Neighboring sender controls already roll memory back when their manifest write fails.

### 13. Medium — Android’s crash-durable SessionStore silently ignores current-manifest publication failure

**Affected code:** `ArchiveProcessor/ArchiveCapture/app/src/main/java/com/archiveprocessor/capture/data/ManifestFileWriter.kt:14-35`; `ArchiveProcessor/ArchiveCapture/app/src/main/java/com/archiveprocessor/capture/data/SessionStore.kt:11-65`; `ArchiveProcessor/ArchiveCapture/app/src/main/java/com/archiveprocessor/capture/capture/CaptureViewModel.kt:98-139,174-199`

`ManifestFileWriter` reports replacement failure, but `SessionStore.save` returns no result, ignores that Boolean, and swallows exceptions. The conflated writer therefore cannot tell the view model that the current snapshot was not committed.

After an I/O failure and app termination, a new raw JPEG absent from the old manifest is re-adopted into a fresh default Document group. Box/folder classification, group boundaries, priority/date/tags, replacement provenance, and segment-completion state can be lost; known files can return with stale metadata.

**Queue check:** the existing Android manifest fix preserves the previous valid manifest when replacement fails. It does not propagate failure of the new snapshot or prevent lossy orphan adoption.

### 14. Medium — Reader and Notes indexers report successful completion after SQLite failures

**Affected code:** Reader `ArchiveReader/macOS/Sources/ArchiveReader/Search/ContentIndexer.swift:53-163,166-197` and `ContentIndex.swift:35-55`; Notes `ArchiveNotes/macOS/Sources/ArchiveNotes/Index/NotesIndexer.swift:56-127`, `NotesIndex.swift:23-96`, and `ArchiveNotes/macOS/Sources/ArchiveNotes/Core/NotesModel.swift:251-272`

Both indexers suppress `open` and batch-upsert errors with `try?`, then unconditionally finish. Notes subsequently reloads the partial index and marks it Ready; Reader clears progress and serves partial/empty search and format-health results.

There is a second failure mode in both SQLite actors: after `sqlite3_open_v2` succeeds, a PRAGMA, migration, or schema-creation error leaves `db` non-nil. Every future `open()` returns immediately without completing setup or closing the handle, poisoning the index until process restart.

**Queue check:** Notes W9 C6 is a scale harness, and Reader’s existing index work covers scheduling/pruning. Neither queues error propagation, partial-batch reporting, or recovery of a half-open database.

### 15. Medium — `organization.json` export failure is silently reported as a successful organization change

**Affected code:** `ArchiveNotes/macOS/Sources/ArchiveNotes/Index/OrganizationFile.swift:3-24`; `ArchiveNotes/macOS/Sources/ArchiveNotes/Index/OrganizationStore.swift:87-117,151-174,220-234,282-287`

`organization.json` is documented as the authoritative durable mirror that survives DB wipes and computer moves. Its export function returns `Void` and suppresses both encode and atomic-write failures. Organization mutations commit SQLite/in-memory first and then call this nonthrowing exporter.

On a full, read-only, or unavailable Notes volume, the UI reports folder, membership, and template-assignment changes as successful while the durable mirror remains stale. A later DB loss or migration restores obsolete organization state.

**Queue check:** the existing DB-first shadowing note concerns which source wins at startup/under test. It does not cover export failure after an interactive mutation.

### 16. Medium — The global inline-image cache can display another note’s same-named image

**Affected code:** `ArchiveNotes/macOS/Sources/ArchiveNotes/Editor/InlineImageAttachment.swift:82-124`; `ArchiveNotes/macOS/Sources/ArchiveNotes/Editor/MarkdownBridge.swift:242-246`

The static app-wide thumbnail cache is keyed only by the markdown-relative path, normally `assets/name.png`. Item identity or the resolved absolute URL is not part of the key. If note A and note B each own different `assets/x.png`, rendering A first caches its thumbnail and rendering B can display A’s image without reading B’s bytes.

Same-named assets across different item directories are normal and explicitly supported by the store, so this is not dependent on malformed data.

**Queue check:** no current thumbnail-cache/cross-note-image issue exists. W9 B4 concerns generating Reader-page thumbnails, not Notes item asset cache identity.

### 17. Medium — A failed move-to-Trash still removes the surviving note from the index

**Affected code:** `ArchiveNotes/macOS/Sources/ArchiveNotes/Core/NotesModel.swift:736-771`

`trashItems` logs each `NoteStore.delete` failure but then deletes every requested ID from `NotesIndex` and reloads the list. A note whose directory remains on disk therefore disappears from All Notes for the rest of the run; there is no watcher to restore it, and the full disk rebuild runs only at bootstrap.

This contradicts the method’s stated safety invariant that a trash failure leaves the note on disk and discoverable under All Notes.

**Queue check:** no current Notes task covers trash failure followed by unconditional index deletion.

### 18. Medium — Several multi-step Notes organization operations can leave partial state after a failure

**Affected code:** `ArchiveNotes/macOS/Sources/ArchiveNotes/Index/OrganizationStore.swift:120-152`; `ArchiveNotes/macOS/Sources/ArchiveNotes/Core/NotesModel.swift:368-380`; `ArchiveNotes/macOS/Sources/ArchiveNotes/Core/NotesNavigationModel.swift:302-319`

The Notes façade claims organization mutations are atomic, but several operations span independent awaited writes with no transaction or rollback:

- `deleteFolder` mutates each child in memory before its individual DB update, then separately deletes memberships, assignments, and the folder. A later SQLite failure leaves a partially reparented/deleted graph in memory and on disk.
- `deleteTemplate` clears every folder assignment before attempting to move the template to Trash. If Trash fails, the template survives but its assignments are lost.
- `move` adds the target membership first, then suppresses source-removal failure. The UI reports a move while the item is actually replicated in both folders.

**Queue check:** no active item covers fault-atomicity or rollback for these multi-step organization operations.

### 19. Medium — Resolving a missing Reader link can synchronously scan the full archive on the main actor

**Affected code:** `ArchiveNotes/macOS/Sources/ArchiveNotes/Links/ReaderLinkResolver.swift:19-23,36-64,86-98`

`ReaderLinkResolver` is main-actor isolated. When an exact relative path is missing, `resolve` synchronously enumerates every descendant of the granted Reader root to find a matching basename. Clicking one broken or moved source link can therefore freeze all Notes UI for the duration of a 100k–150k-file archive walk, with no cancellation.

The basename fallback itself is part of the intended behavior; performing the unbounded filesystem search synchronously on the UI actor is the defect.

**Queue check:** Notes W9 C6 covers Notes-index scale, not Reader-root fallback scanning. No matching performance item is queued.

### 20. Medium — Deleting the Inbox or Extracts system folder creates permanent ghost memberships

**Affected code:** `ArchiveNotes/macOS/Sources/ArchiveNotes/Views/NotesFolderTreeView.swift:51-60,163-173`; `ArchiveNotes/macOS/Sources/ArchiveNotes/Index/OrganizationStore.swift:63-82,124-152,157-163,269-280`; `ArchiveNotes/macOS/Sources/ArchiveNotes/Core/NotesModel.swift:383-410,442-456`; `ArchiveNotes/macOS/Sources/ArchiveNotes/Index/NotesIndex.swift:69-95`

Every normal folder, including the fixed-ID Inbox and Extracts folders, receives Rename and Delete actions. `deleteFolder` accepts those IDs. System folders are reseeded only when the entire folder table is empty, so deleting one is permanent.

New notes and extracts nevertheless continue filing memberships under the deleted fixed IDs. `addMembership` does not verify that the folder exists, and SQLite declares no foreign key. The graph accumulates memberships to a folder that can no longer appear in the tree or be restored by normal startup.

**Queue check:** no current item protects/reseeds the two system folders or rejects membership to a nonexistent folder.

### 21. Low — Notes’ Reader-link containment check can be bypassed through a symlink

**Affected code:** `ArchiveNotes/macOS/Sources/ArchiveNotes/Links/ReaderLinkResolver.swift:41-54`; `ArchiveNotes/macOS/Sources/ArchiveNotes/Views/ReaderPreviewPopover.swift:56-63`

The resolver uses `standardizedFileURL`, which normalizes `..` lexically but does not resolve symlinks. It then calls `fileExists`, which follows them. A symlink under the granted Reader root that points to an otherwise accessible PDF outside the root is returned as `.resolved`, violating the resolver’s stated granted-root containment contract.

The app sandbox may independently deny some external targets, so this is a semantic scope bypass rather than a claim that every symlink escapes the sandbox.

**Queue check:** tests cover `../../` traversal but not symlink/real-path containment; no current issue queues it.

### 22. Low — Cancelled prune tasks can still defeat the two-emission absence gate

**Affected code:** Reader `ArchiveReader/macOS/Sources/ArchiveReader/Search/ContentIndexer.swift:205-263`; Notes `ArchiveNotes/macOS/Sources/ArchiveNotes/Index/NotesIndexer.swift:143-176`

Starting a prune cancels the prior detached task, but cancellation is cooperative. After the old task’s final cancellation check, it can still read `pendingPrune`, delete rows, and later overwrite pending state in separate main-actor hops. A newer emission can interleave during that window, so an old task can compare against stale absence state and delete after what is effectively only one current consecutive absence.

The source files are safe because these are disposable indexes, but search results can disappear until reindexing. This requires a narrow interleaving; the missing post-cancellation generation gate is confirmed by inspection, but this review did not run a deterministic race fixture.

**Queue check:** W6.1b and the Notes prune work are marked fixed by cancellation plus a two-emission gate. This is a residual race in that fix, not a duplicate open item.

### 23. Low — Concurrent first-time root-marker creation can orphan newly copied links

**Affected code:** `packages/ArchiveCore/Sources/ArchiveCore/Links/RootMarker.swift:145-196`

`RootMarker.ensure` checks for absence before entering write coordination, generates a UUID, and then blindly writes it. Two processes can both observe absence and serialize writes of different markers. Process A can re-read and return A before process B writes B as the final disk value, allowing A-based links to be copied even though the root ultimately identifies as B.

Sequential idempotency and the final re-read do not close this cross-process check-then-write race.

**Queue check:** no current task covers concurrent root-marker creation. W15’s per-path serialization is specific to Finder-tag writes and in-process callers.

### 24. Low — Notes accepts impossible day-precision calendar dates

**Affected code:** `ArchiveNotes/macOS/Sources/ArchiveNotes/Views/NoteMetadataInspector.swift:66-85,117-137`; `ArchiveNotes/macOS/Sources/ArchiveNotes/Store/Item.swift:45-60,65-99`

The UI and normalization logic validate month as 1…12 and day as 1…31 independently. They do not validate the combination against a calendar. Values such as `2026-02-31` are therefore persisted as day-precision dates and receive a normal chronological sort key.

**Queue check:** no current Notes date-validation item covers impossible month/day combinations.

## Reviewed candidates intentionally not reported as bugs

- A proposed “non-ASCII filenames exceed APFS because the cap is UTF-16” issue was refuted on the current macOS filesystem and by the actual UTF-16 slicing logic; it is not included.
- Processor receiver stale-callback ordering was not shown reachable through the supported Start/Stop UI, so it is not included.
- ArchiveCore partial Finder-tag mutation is already documented in Processor’s verification plan and is not duplicated here.
- Reader header stripping, case-only tag-overlay convergence, and smart-folder flattening matched intentional/tested behavior.
- Stable-name staging overwrite concerns are part of the explicitly closed/deferred immutable-generation redesign and were not re-promoted.

No additional suite-root release/tooling defect survived validation at a material enough level to include.
