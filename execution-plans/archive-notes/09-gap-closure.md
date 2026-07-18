# Archive Notes — Gap-Closure Execution Plan (post-ship reconciliation)

**Status: PROPOSED** · Created 2026-07-16 · Owner: (unassigned)

This plan closes the deltas found by a complete plan-vs-build review of the Archive Notes plan set
(`execution-plans/archive-notes/00-overview.md` + `00a` + `01`–`08`) against the shipped source under
`ArchiveNotes/macOS/`. Waves W0–W8 are all marked `[x]` in `SUITE_TODO.md`; the review confirmed the
build is **substantially complete and data-safe** (all five tag-safety invariants, the delete-last-instance
guard, atomic writes, and autosave/flush are clean), but a set of deliverables that the plans promised —
and that the checkboxes imply shipped — are **absent, partial, or built-but-unwired**. Nothing here is a
data-safety defect; the largest items are *dead library code that never got its UI entry point*.

Severity legend: **HIGH** (headline feature unreachable) · **MED** (real feature/tooling gap) ·
**LOW** (polish/coverage/cosmetic) · **DOC** (tracker/doc hygiene).

**Addendum — 2026-07-17 spec-vs-build pass.** Everything above (A1–A10, B1–B7, C1–C5, D1–D12) came from a
*plan-vs-build* review (the internal wave plans `00a`/`01`–`08` vs the shipped source). A follow-up
*spec-vs-build* pass — comparing the **original Archive Notes product spec** against the build — found four
deltas the plan-vs-build pass could not see, because they are spec intent that never entered the wave plans:
**A11** (author/date/quality → Finder-tags durability reconciliation), **B8** (manual author editing — notes
**and** extracts), **B9** (outbound *Copy Link to Note/Extract* — the Scrivener round-trip originator), and
**C6** (a 100k-note / 2M-word scale-acceptance harness). They are folded into their phases below and verified
under Phase E like every other item. Most other original-spec items were **already tracked** here — page
thumbnails (B4), note-level Zotero attach/citation/auto-fill (B1/B2), round-ups (D6), template body editing
(D3), title/tag editing (B3), extract image bytes on the menu path (B6), guided root re-grant (B7), inbound
`archivenotes://open` (B5) — or are plan-stated deferrals (quick-preview *page* navigation = the
"page-within-merged-PDF scroll navigation" deferral in the out-of-scope list); those are **not** re-flagged.

**Addendum — 2026-07-17 W14.4 live GUI-verification pass.** A sighted GUI drive (`ops/gui/capture-window.sh`
+ `cliclick`, on the scratch `AN-GUI-Fixture` only) verified the shipped W14.4 polish cluster end-to-end and
reconciled it against this plan: **(b)** window-raise on Jump-to-Source (→ Notes window fronts + source
selected) and on Create Extract (→ Extracts window fronts + new extract selected); **(c)** reactive
provenance-chip refresh (changing the source note's year in the Notes window relabeled the extract's chip in
the Extracts window with no reopen, cross-window; the raw-markdown snapshot stayed unchanged); **(d)**
per-window Sources column default (Note window hides it, Extracts shows it). Three reconciliations came out of
that pass: **D5 is already shipped** by W14.4b (annotated below — not an open gap); **B3's title-rename gap is
now live-confirmed** (annotated below); and one new **cosmetic** item (chip-scroll visibility) is folded into
**D12**.

**Addendum — 2026-07-18 GUI sweep (PARTIAL — cut short at the session usage limit).** A broader sighted
GUI sweep of Notes (scratch fixture) was started to empirically confirm which Phase-B/D features are actually
reachable vs. "built but dead" (i.e. execute the Phase-E2 drive-at-runtime pass early). Two **CANDIDATE**
findings surfaced before the session limit stopped the sweep — both need a confirming pass (GUI-driving
imprecision is not fully ruled out), so they are recorded as candidates, not confirmed gaps:
- **NEW-ITEM CREATION may be unreachable from the obvious affordances (CANDIDATE, verify first).** With the
  app focused on the scratch fixture, **⌘N created no note** (item count unchanged on disk across two
  attempts), and a click on the toolbar **"New" pencil button also created nothing**. Note there is **no
  `File` menu** at all (menu bar is Apple · Archive Notes · Edit · View · Format · Note · Extract · Debug ·
  Window · Help), so ⌘N appears unbound; the impl-map says the toolbar "New" is a menu (`New <kind> ⌘N` +
  `New from Template ▸`). *Possible benign explanations to rule out:* the New menu may need a real folder
  selected (I was on the "All Notes" pseudo-row), or a new empty note may be created in-memory/index and not
  flushed to a `.md` until first edit, or my click missed the split-button. **Action:** confirm whether a
  brand-new note can be created at all from the GUI (and whether ⌘N should be bound). If creation is genuinely
  unreachable, this is **HIGH** (a note app you can't add a note to); if it's the folder-scope/flush nuance,
  downgrade to a small UX note. Ties into **B3** (no in-app retitle) — if both hold, notes can be neither
  created nor renamed in-app.
- **Pasted note-passage provenance block renders as a RAW `<!-- block: note-passage … -->` comment
  (CANDIDATE).** After a W14.3 copy-passage→paste-into-extract, the pasted passage's provenance chip showed as
  the literal HTML-comment source in the extract's **styled** editor (the surrounding heading + image rendered
  styled), and it persisted after a reselect/reload. Pre-existing note-passage chips render correctly (verified
  in W14.4b/c), so this may be specific to the **freshly-pasted** block not being re-styled into a chip.
  **Action:** confirm on a clean paste; if real, the paste path should re-run the chip styling (or the pasted
  block's on-disk form differs from what `MarkdownBridge` chip-parses). Low data risk (bytes import correctly —
  W14.3 confirmed); this is a rendering gap. Fold into **D12** if confirmed.

The rest of the systematic sweep (note delete + delete-last-instance guard, tag editing **B3**, quality
quick-edit **D4**, manual author **B8**, keyword FTS + quality/tag/date filters, folder create/rename/delete +
move/reorder **D1** + move/replicate, templates **D3**, context menu **D2**, Zotero attach/auto-fill **B1/B2**,
source-block paste, **Copy Link B9**, deep-link **B5**, smart folders, empty-state **D8**) is **still
outstanding** — it is exactly the Phase-E2 runtime-drive pass and should be finished in a fresh session.

---

## Summary of gaps by phase

| Phase | Theme | Items | Top severity |
|---|---|---|---|
| A | Doc & tracker reconciliation | A1–A11 | DOC |
| B | Wire the built-but-dead features | B1–B9 | HIGH |
| C | Safety-net & regression tooling | C1–C6 | MED (functional) |
| D | Secondary UI affordances & polish | D1–D12 | LOW–MED |
| E | Verification review (confirm A–D actually shipped + wired) | E1–E4 | — |

Recommended order: **A** (cheap, clears the "docs move with the code" debt and stops the checkboxes from
lying) → **B** (restores the headline value that's already 90% built) → **C** (re-arms the guards that keep
the corpus safe) → **D** (polish, as budget allows) → **E** (verify every closed item is real, then retire
this plan). Each item is independently shippable in its own worktree per the repo loop; Tier per item below.

---

## Phase A — Doc & tracker reconciliation (DOC; do first, one commit each or batched)

**A1. Write `ArchiveNotes/README.md`. — ✅ DONE (W9 Phase A docs, 2026-07-18).** — planned in `01` S5 Files + layout sketch; never existed.
- *Files:* NEW `ArchiveNotes/README.md`. *Steps:* mirror `ArchiveReader/README.md` / `ArchiveProcessor/README.md` (what the app is, build/run via `./launch.sh notes` + `bootstrap.sh`, pointer to `CLAUDE.md`/`GUI_SAFETY.md`). *Verify:* prose review; links resolve. *Tier-1. Done:* file exists; matches peer-app README shape.

**A2. Add Archive Notes to the root `README.md`. — ✅ DONE (W9 Phase A docs, 2026-07-18).** — root README currently has zero mention of Notes (describes a two-app suite). *Shipped:* intro "Two"→"Three", a third app-table row, the "three separate apps" prose (Notes builds on Reader's durable links), the `packages/ArchiveCore` + `ArchiveNotes/` repo-layout entries, the `./launch.sh notes` dispatcher line, and the per-app README link.
- *Files:* `README.md`. *Steps:* add the third app to the suite intro + any app list/table. *Verify:* prose review. *Tier-1.*

**A3. Decide & resolve `ArchiveNotes/AGENTS.md`. — ✅ DONE (W9 Phase A docs, 2026-07-18).** — planned in `01` S5 Files; absent. Peers have one; root `AGENTS.md:5` routes readers to `ArchiveNotes/CLAUDE.md` instead (worked around). *Decision:* created the app-local lane doc like the peers (both peers ship one), and fixed root `AGENTS.md:5` to route to `ArchiveNotes/AGENTS.md`.
- *Files:* NEW `ArchiveNotes/AGENTS.md` **or** an explicit note in `CLAUDE.md`/root `AGENTS.md` folding the lane in. *Steps:* either create the app-local lane doc like the peers, or record the decision to keep it in root `AGENTS.md` and fix the plan's expectation. *Verify:* the routing in root `AGENTS.md` matches reality. *Tier-1.*

**A4. Complete the SPEC `ArchiveSuite` marker delta.** — `01` S5/§6: the facet-table row landed (`SPEC/tag-format.md:71`), but the dedicated prose section and the change-protocol relaxation note did not.
- *Files:* `SPEC/tag-format.md`. *Steps:* add the "### Suite membership marker (`ArchiveSuite`)" section (Class / Cardinality / Parse-order / **Deferred: not consumed by Reader/Processor in run 1**); add the additive/read-only exception note to "Divergence risk & change protocol" (~line 205) explaining why this landed without a three-way change. *Verify:* delta is strictly additive; no existing rule altered. **Tier-2** (SPEC change — adversarial prose review).

**A5. Shipped execution plans — DONE (`78e9b46`).** The per-wave plans (`00a`, `01`–`08`) were pruned on ship; only `00-overview.md` is retained (the authoritative interface contract) alongside this plan.
- *Remaining verify (folds into E4):* confirm nothing in `SUITE_TODO.md`/docs points at a deleted plan file, and that `00-overview.md` + `09-gap-closure.md` are the only files left under `execution-plans/archive-notes/`. *Tier-1.*

**A6. Fix stale `SUITE_TODO.md` entries.** — W1's "S5 docs" reads shipped despite A1–A4; line ~485 has a stale "ArchiveCore extraction … deferred, 2026-07-08" contradicting W0 `[x]`.
- *Files:* `SUITE_TODO.md`. *Steps:* correct the W1 docs note to cite what actually shipped (and reference this plan for the remainder); remove the stale deferred line; add an index entry for this plan. *Verify:* every `[x]` matches reality. *Tier-1.*

**A7. Refresh both apps' `CLAUDE.md` Implementation Maps for the ArchiveCore move (W0 doc-sync).** — `ArchiveReader/CLAUDE.md:~324` still lists `DocumentTags`/`TagReading`/`TagEditing`/`PDFFormatStatus` under `Core/` ("package-ready → future ArchiveCore"); `ArchiveProcessor/CLAUDE.md:~251` hotspot list stops at "the two `project.yml` files."
- *Files:* `ArchiveReader/CLAUDE.md`, `ArchiveProcessor/CLAUDE.md`. *Steps:* move the shared types to an ArchiveCore section; add the "TagWriter/MacOSTagger delegates to `ArchiveCore.CoordinatedTagWriter`" safety note; list the `packages/ArchiveCore` build lane. *Verify:* maps match the tree. *Tier-1.*

**A8. Add `ArchiveNotes/SMOKE_TEST.md`. — ✅ DONE (W9 Phase A docs, 2026-07-18).** — `08` S9 Files lists it; Reader has one, Notes doesn't (purpose currently served by the `test-smoke.sh` header + `CLAUDE.md` + `GUI_SAFETY.md`). *Shipped:* mirrors `ArchiveReader/SMOKE_TEST.md` (safety block, legend, resumable step checklist A–P), cross-refs `GUI_SAFETY.md` + `scripts/GUI-HARNESS.md` (DRY — links the G0–G11 catalog, doesn't duplicate it); steps `[ ]` pending the first GUI-on run.
- *Files:* NEW `ArchiveNotes/SMOKE_TEST.md`. *Steps:* mirror `ArchiveReader/SMOKE_TEST.md`, cross-referencing `GUI_SAFETY.md` and the scratch-only rule. *Verify:* cross-refs resolve. *Tier-1.*

**A9. Drop `@testable` from `DocumentTagsTests`.** — `01` S1 Verify required plain `import ArchiveCore` (types are `public`); `packages/ArchiveCore/Tests/ArchiveCoreTests/DocumentTagsTests.swift:2` still uses `@testable`.
- *Files:* that test. *Steps:* change to `import ArchiveCore`; `swift test` still green. *Verify:* package tests pass. *Tier-1.*

**A10. Confirm doc-sync hook covers `packages/`.** — the W0 plan asked to prove the doc-sync backstop fires for a package outside both app dirs; `.claude/hooks/docsync-*.sh` contain no `packages/ArchiveCore` reference.
- *Files:* `.claude/hooks/docsync-*.sh` (+ their config). *Steps:* verify/extend scope so a `packages/ArchiveCore` code change without a doc touch is caught. *Verify:* a dry-run trips the hook. **Tier-2** (autonomous-setup change — prove the mechanism before install).

**A11. Reconcile the original spec's "author/date/quality → macOS Finder tags" durability intent.** — **DOC**
(spec-vs-build). The original spec's durability section says "other metadata, e.g. **author and date**, should
go in macOS tags," and its tags section wants a **quality** ordering "akin to the priority tag in Reader …
**not** a regular tag" — and Reader's priority *is* a projected Finder tag. The build instead keeps `authors`,
`date`, and `quality` in the note's `.md` YAML **front-matter** (durable plain text) and projects **only
subjects** to Finder tags. The plan's out-of-scope list already defers "mirroring date/quality into Finder
tags" but **omits author** and doesn't cite the original-spec rationale, so a future spec reviewer will re-flag it.
- *Files:* this plan (out-of-scope/deferrals section) + optionally `ArchiveNotes/CLAUDE.md` / `SPEC/tag-format.md`.
- *Steps:* record the deliberate deviation — front-matter (not Finder tags) carries author/date/quality, which
  still satisfies "durable against this program no longer being developed" via plain-text YAML in the `.md` —
  **and** get the owner decision on whether to *additionally* mirror author/date/quality to Finder tags for
  cross-app (Reader/Processor) parity. Extend the deferral entry to name **author** explicitly and reference
  the original-spec clauses. *Verify:* the deferral record matches the original spec's language; no code change
  unless the owner opts to mirror (then it becomes a **Tier-2** tag-projection change routed through
  `NotesTagProjector`, with the five tag-safety invariants). *Tier-1 (doc).*

---

## Phase B — Wire the built-but-dead features (the high-value core)

These are the review's headline finding: substantial, well-tested subsystems that ship in the binary but
have **no UI entry point**, so a `[x]` overstates them. Most of the work is wiring, not new subsystems.

**B1. Zotero auto-fill action — fetch + confirmation sheet + write.** — **HIGH** — `05` S3/S4/D.5.
`ZoteroClient.fetchCSL`/`fetchCitation`, `ZoteroAutoFillModel`, `AutoFillPlan` are complete and tested but
never called outside tests; there is no menu command and zero `.sheet(` in `Sources/`.
- *Files:* `ArchiveNotes/.../ArchiveNotesCommands.swift`, `.../Editor/EditorFormatting.swift`, `.../Zotero/ZoteroAutoFillModel.swift`, a new confirmation sheet view, `.../Views/NoteEditorPane.swift`.
- *Steps:* add `Note ▸ Auto-fill from Zotero` (and/or a chip button) that resolves the focused/attached `ZoteroRef` → `client.fetchCSL` → builds `AutoFillPlan` → presents a `ZoteroAutoFillModel`-backed confirmation sheet (fill-empty policy) → saves via the audited store path. Route citation through `fetchCitation(styleID:)` so `zoteroCSLStyleID` (D2) takes effect.
- *Verify:* with a stub transport (as in `ZoteroLocalServerTests`), the command fetches, the sheet shows the diff, Confirm writes front-matter, Cancel is a no-op; Zotero-down degrades gracefully. **Tier-2** (writes note front-matter). *Done:* `ZoteroAutoFillModel` reachable from the UI; `zoteroCSLStyleID` observably affects output.

**B2. Note-level Zotero citation chips + an attach-at-note-level path.** — **HIGH/MED** — `05` S4/D.5.
`ZoteroChipView` is defined and presentation-tested but never instantiated, and nothing in production writes
`item.zotero`.
- *Files:* `.../Zotero/ZoteroChipView.swift`, `.../Views/NoteMetadataInspector.swift` (or `LocationsInspector`), `.../Editor/EditorFormatting.swift`.
- *Steps:* render `ZoteroChipView` for `selectedItem.zotero` in the inspector; add an "attach at note level" path (extend "Attach Zotero Link…" or a new inspector affordance) that populates `item.zotero` via `mutateItem`. Feed the clipboard-detect dedup the note's existing links (fixes the empty-`attachedLinks` banner, D-item).
- *Verify:* attaching a ref shows a note-level chip; the chip's spinner/⚠︎ states exercise via stub. **Tier-2** (front-matter write). *Done:* S4 "chips clickable at note **and** block level" met.

**B3. Add note retitle + tag editing.** — **MED** — overview §16.1. No `setTitle`/`setTags` exist; the
metadata inspector edits only date/quality; the table tags column is read-only and its comment falsely
claims editing lives in the inspector.
- *Files:* `.../Core/NotesModel.swift` (+`mutateItem`), `.../Views/NoteMetadataInspector.swift`, `.../Views/NotesTableView.swift` (comment), optionally `.../Views/NotesContextMenu.swift`.
- *Steps:* add `setTitle(_:to:)` and `setTags(_:to:)` on `NotesModel` routed through the audited `mutateItem` path; `setTitle` triggers the store's title→filename re-sync; `setTags` must run the front-matter write **and** `NotesTagProjector` so Finder tags stay in sync (Tier-2 write seam). Add a title field + a tag editor to the inspector; correct the `NotesTableView` comment.
- *Verify:* rename persists + renames the `.md`; tag edits update front-matter *and* the projected Finder tags with all safety invariants (assert on a scratch store). **Tier-2** (tag projection + rename). *Done:* a note can be retitled and re-tagged in-app; `NotesTagProjectorSafetyTests`-style assertions extended.
- *Live-confirmed (2026-07-17 GUI drive, scratch fixture):* the title half of this gap was verified end-to-end — there is **no in-app note-title rename path today**: the detail-pane title is a static (non-focusable) label (clicking it focuses the list table), list rows are not inline-editable (double-click and Return do nothing), and there is no Rename in the Edit menu, the Note menu, or the item-row context menu. So `setTitle` + a title editor is a real, reachable-by-users gap, not just missing library code. (The W14.4(c) reactive chip refresh was still verified by mutating the source's *year* — the same `itemsGeneration` re-style path — so only the *editing* affordance is missing, not the reactive plumbing.)

**B4. Wire page-thumbnail rendering end-to-end.** — **MED** — `04` S2/S4/S6. `PDFThumbnailer` +
`ThumbnailImageCache` are built/tested but never instantiated; Reader passes `thumbnailer: nil` at every
`ArchiveLinkWriter` site, and Notes has no render-on-demand fallback on paste.
- *Files (Reader):* `ArchiveReader/.../Core/ArchiveLinkWriter.swift`, `.../Views/NavigationModel.swift:~1028`, `.../Views/DocumentViewerModel.swift:~220`. *Files (Notes):* `.../Editor/MarkdownEditorView.swift` (`handleSourceBlockPaste`), `.../Views/ThumbnailImageCache.swift`.
- *Steps:* instantiate a shared `PDFThumbnailer` in Reader and pass it to `ArchiveLinkWriter.pageLink` (populate `thumbPNGBase64`) — including the batch "Copy Archive Link(s)" path, which currently hardcodes `nil`. In Notes, when a pasted page-entry has `thumbnailData == nil`, resolve within granted scope and render via `PDFThumbnailer`, else skip (as planned).
- *Verify:* the W8 acceptance "paste from Reader → source block with a live thumbnail" passes; cache LRU/eviction exercised. Add a headless render guard (the `RenderProbe`/`DocumentRenderGuardTests` pattern over `PDFThumbnailer`) so a **blank** thumbnail fails a test, not just the eye. **Tier-2** (spans both apps + the Reader copy path). *Done:* pasted page-links show a rendered thumbnail; `PDFThumbnailer` has a production caller.

**B5. Consume `archivenotes://open` to select/raise the note.** — **MED** — `04` S5. `NotesDeepLinkRouter.pendingOpen`
is published but nothing observes it, so an external `archivenotes://open?id=<uuid>` activates the app
without selecting the note.
- *Files:* `.../Links/NotesDeepLinkRouter.swift`, `.../ArchiveNotesApp.swift`, `.../Views/NotesBrowserView.swift` (or the nav model).
- *Steps:* add a consumer that observes `pendingOpen`, selects the id in the list, raises the Notes window, then `clearPending`. Reuse the W7 `NotesModel.openItem` jump channel if convenient, but drive it from the router.
- *Verify:* `open "archivenotes://open?id=<known-uuid>"` selects the item (fixture-based). **Tier-1** (read/navigation only). *Done:* the plan's inbound-link GUI criterion is met. **(The full Scrivener round-trip also needs B9 — the outbound Copy-Link that originates the URL; B5 alone is only the inbound half.)**

**B6. Embed image bytes on the extract command path.** — **MED** — `07` S1/S2. `EditorFormatting.makeNotePassageSource`
passes `assetStore: nil` though `ItemAssetStore` (W7-S5) shipped, so ⌘⌥E Create-Extract / Append copy the
`![](assets/…)` reference without the bytes → dangling image refs in the new extract.
- *Files:* `.../Editor/EditorFormatting.swift` (`FormattingContext`, `makeNotePassageSource`), `.../Views/NoteEditorPane.swift:~249` (has the store).
- *Steps:* thread the source note's `ItemAssetStore` into `FormattingContext` and on into `makeNotePassageSource` so the builder's byte-copy runs (the copy→paste path already does this correctly).
- *Verify:* a menu-created extract from a passage with an inline image has its own `assets/` copy (snapshot-independent, D7); source never mutated. **Tier-1** (uses audited store; no new write surface). *Done:* image passages via the menu embed bytes.

**B7. Wire guided root re-grant.** — **MED** — overview G1. `ReaderLinkResolver.grantAndResolve` is
code-complete and tested but only tests call it; when a source's root has moved, the preview popover only
tells the user to open Reader.
- *Files:* `.../Views/ReaderPreviewPopover.swift`, `.../Links/ReaderLinkResolver.swift`, `.../Links/ReaderRootStore.swift`.
- *Steps:* on `needsRootGrant`/`renamedCandidate`, offer an in-app folder-picker that calls `grantAndResolve` (GUID-verified), persists the security-scoped bookmark, and retries resolution.
- *Verify:* moving a fixture root then choosing it re-resolves the link; wrong-folder is rejected. **Tier-2** (security-scoped bookmark grant). *Done:* a moved source can be re-granted without leaving Notes.

**B8. Manual author editing (notes *and* extracts).** — **MED** — (spec-vs-build). The original spec lists
author as a first-class field on both a note ("a single file with an **author**, title, and date") and an
extract ("the extract has its own title, date, and **author**"). `Item.authors: [String]` is stored,
front-matter-round-tripped (`FrontMatterCodec`), and FTS-indexed (`NotesIndex` authors column, bm25 weight 4),
but the **only** writer is `ZoteroAutoFillModel` — which is itself dead (see **B1**) *and* only applies to
Zotero-tracked documents. There is **no** way to set an author on a note/extract that isn't in Zotero:
`NoteMetadataInspector` edits only date + quality, and `NotesModel` exposes `setDate`/`setQuality`/`setBody`
but no `setAuthors`. Neither B1 (Zotero auto-fill) nor B3 (retitle + tags) covers **manual** author entry.
- *Files:* `.../Core/NotesModel.swift` (+`mutateItem`), `.../Views/NoteMetadataInspector.swift`.
- *Steps:* add `NotesModel.setAuthors(_:for:)` routed through the audited `mutateItem` path (load-fresh →
  atomic `.md` save → one-row re-index → publish); add an authors editor (multi-value/line field) to the
  inspector alongside date/quality. Authors stay **front-matter only** (not projected to Finder tags unless
  A11's owner decision says otherwise). Works for both windows (notes and extracts share the `Item` model).
- *Verify:* setting/clearing authors persists to front-matter and updates the FTS `authors` column (assert on a
  scratch store); an extract's author edit never mutates its source note. **Tier-1** (front-matter only; no new
  Finder-tag write surface). *Done:* a note **and** an extract can have their author set in-app without Zotero.

**B9. Outbound "Copy Link to Note/Extract" — the Scrivener round-trip originator.** — **HIGH (for interop)** —
(spec-vs-build). The original spec's word-processor interop requires the user to "insert hyperlinks in the word
processor that link to specific notes or extracts, so they can click and go straight to the note in Notes."
Nothing in production copies a note's/extract's *own* durable link to the pasteboard: `DurableLink.notesOpen(id:block:).url`
is minted only to embed an extract's provenance anchor (`Store/SourceAnchor+NotePassage.swift:25`) and is parsed
**inbound** (`Links/NotesDeepLinkRouter.swift`); `NotesContextMenu`/`ArchiveNotesCommands` have no copy-link
action; a grep for `Copy Link` / `Copy Archive Link` / `copyArchiveLink` outside `Tests/` returns none. **B5
(consume `archivenotes://open`) is only the *inbound* half — without B9 the user can never originate the link,
so B5's "Scrivener round-trip target … met" Done criterion is unreachable on its own.** (D2's parenthetical
"(Copy Archive Link stays W4)" refers to copying the *Reader* source link off a source block, **not** minting a
note's own `archivenotes://` link — a different feature; grep confirms no such Notes-side action exists.)
- *Files:* `.../Views/NotesContextMenu.swift`, `.../ArchiveNotesCommands.swift`, `.../Core/NotesModel.swift` (helper).
- *Steps:* add a "Copy Link" affordance (item-row context menu + a `Note`/`Extract` menu command) that, for the
  selected item, writes `DurableLink.notesOpen(id:block:).url.absoluteString` as a plain-text (`.string`)
  pasteboard item (mirroring Reader's `copyLinks()` idiom) so it pastes into Scrivener as a clickable
  `archivenotes://open?id=…` hyperlink. GUID-based / path-independent → durable across computers.
- *Verify:* Copy Link on a fixture item puts the correct `archivenotes://open?id=<uuid>` URL on the pasteboard;
  pasting it back and opening it selects/raises that item (round-trips with **B5**). **Tier-1** (read/pasteboard
  only). *Done:* the outbound half of the Scrivener round-trip exists; update **B5**'s Done to require B9.

---

## Phase C — Safety-net & regression tooling (MED/functional; re-arms the guards)

**C1. Add the `archivecore` smoke/regression step.** — **MED (functional)** — `00a` S1. The 100 ArchiveCore
tests run only via a manual `swift test`; nothing in the gate runs them.
- *Files:* root `test-smoke.sh`. *Steps:* add an `archivecore` case running `swift test` in `packages/ArchiveCore`; include it in `all` (before the apps that depend on it). *Verify:* `./test-smoke.sh archivecore` passes; `all` runs it. *Tier-1.*

**C2. Create the Processor write-surface lint.** — **MED (functional)** — `00a` S5. No
`ArchiveProcessor/scripts/lint-write-surface.sh` exists.
- *Files:* NEW `ArchiveProcessor/scripts/lint-write-surface.sh`. *Steps:* mirror Reader's; ban `setResourceValue(s)`/`setxattr` over `ArchiveProcessor/macOS/Sources`, allow-list `PDFDocument.write` in `PDFGenerator.swift`/`mergeDocumentPDFs`. *Verify:* clean on current tree; trips on a planted violation. **Tier-2** (guards the irreplaceable-data write path).

**C3. Extend the write-surface / UI-import lint to ArchiveCore (and run it on Notes).** — **MED (functional)** —
`00a` S3 + `08` §1.3. The Reader lint scans only Reader; it never scans `packages/ArchiveCore` and has no
`import SwiftUI|AppKit` guard — which is why `packages/ArchiveCore/.../Thumbnails/PDFThumbnailer.swift:4`
imports AppKit into the UI-free Core uncaught. The Notes sources were also never linted.
- *Files:* `ArchiveReader/scripts/lint-write-surface.sh` (or a shared lint), a Notes lint invocation.
- *Steps:* scan `Sources/ArchiveCore` — write API only in `TagWrite.swift`, and **no** `import SwiftUI|AppKit`; add a Notes scan. Then decide `PDFThumbnailer`'s AppKit dependency: either move it behind a Core-safe boundary / into an app target (see §16.7 deviation) or carve a documented exception.
- *Verify:* lint flags the current `PDFThumbnailer` AppKit import (then the chosen fix clears it); Notes scan clean. **Tier-2.**

**C4. Scope the Notes smoke gate to unit tests.** — **MED** — `08` §2. `ArchiveNotes/test-smoke.sh` runs
`xcodebuild test -scheme ArchiveNotes` without `-only-testing:ArchiveNotesTests`, so the GUI target is built
and (if the fixture is present) driven by the "free" gate.
- *Files:* `ArchiveNotes/test-smoke.sh`. *Steps:* add `-only-testing:ArchiveNotesTests`; keep the GUI target opt-in. *Verify:* the smoke run no longer invokes `ArchiveNotesUITests`. *Tier-1.*

**C5. (Optional) Fix the tag-projector concurrent lost-update race.** — **LOW-MED (documented)** — `08` S2 /
`KNOWN_ISSUES.md`. Two concurrent same-file projections can drop a subject; not currently triggered because
the projector isn't driven concurrently. Only worth doing if B3 (or any future feature) can enqueue
concurrent projections for one item.
- *Files:* `.../Core/NotesTagProjector.swift`. *Steps:* serialize per-item projection (e.g., an item-keyed actor/queue) so the read-modify-write is atomic; restore the plan's `concurrentProjectionsNeverCorrupt` "loses nothing" assertion. *Verify:* the strengthened concurrency test passes on a scratch store. **Tier-2.** *Done:* KNOWN_ISSUES entry closed.

**C6. Scale-acceptance harness — 100k notes / 2M words.** — **MED (functional)** — (spec-vs-build). The original
spec: "operate at the scale of **100,000 notes and 2 million words** without being slow. **Build for scale from
the beginning.**" The architecture *is* built for scale (FTS5 + bm25, WAL/`synchronous=NORMAL`/`busy_timeout`,
DB-backed org-graph, virtualized `NSTableView`, 150ms-debounced + generation-coalesced search, incremental
off-main indexing with mtime-skip) — but **nothing proves the target**: the only perf test, `EditorPerfTests`,
stresses a single ~50k-word *document*, not a 100k-note *corpus*; there are no `measure`/scale tests.
- *Files:* NEW `ArchiveNotes/macOS/Tests/ArchiveNotesTests/NotesScalePerfTests.swift` + a fixture generator in `ArchiveNotes/scripts/`.
- *Steps:* generate a **scratch** store (mktemp/`TESTOUT` — **never the real Notes store**, per the Reader Prime
  Directive + the never-mutate-live-app-root rule) of ~100k UUID-folder `.md` notes totalling ~2M words, then
  assert bounded wall-times for (a) `buildIndexFromDisk` full incremental index build, (b) an FTS search
  round-trip, (c) `allSummaries()` load + one `NotesNavigationModel.recompute()`/sort. Env-gate it (opt-in flag)
  so `swift test` / CI aren't slowed. **Follow-up (conditional):** if `recompute()`'s in-memory
  `NotesFilter.matches` scan + sort exceeds a frame budget at 100k on `@MainActor`, move it off-main (return a
  `Sendable [UUID]`) — the one scale item the current in-memory-filter design leaves unproven.
- *Verify:* the harness runs on the scratch corpus and the assertions hold (or reveal the first bottleneck); it
  **never** touches the real store (assert the scratch-path guard). **Tier-2** (generates a large scratch
  corpus; must honor the scratch-only guard). *Done:* the spec's 100k/2M scale target has a repeatable
  acceptance test.

---

## Phase D — Secondary UI affordances & polish (LOW–MED; as budget allows)

Each is small and independently shippable; Tier-1 unless noted.

- **D1. Folder move/reorder & drag-to-reparent UI** (MED) — `06` S2. Wire `.onMove` (sibling reorder) + folder-onto-folder drop → `model.moveFolder` (cycle-guard exists). *Files:* `.../Views/NotesFolderTreeView.swift`.
- **D2. Flesh out the item-row context menu** (LOW-MED) — `06` S3. Add Open / Reveal in Finder / New from Template / Set Quality ▸ / Delete… (Copy Archive Link stays W4). *Files:* `.../Views/NotesContextMenu.swift`.
- **D3. Template body editing in-app** (LOW-MED) — `06` S6. Route template selection through `NoteStore` template load/save into `NoteEditorPane`. *Files:* `.../Views/TemplatesManagerView.swift`.
- **D4. Quality quick-edit** (LOW) — `06` S7. Add the inline borderless quality `Menu` (None + 5–1) to the list/detail cell and a context-menu "Set Quality ▸". *Files:* `.../Views/QualityControl.swift`, `NotesTableView.swift`.
- **D5. Raise/select a newly created extract** — **DONE (shipped in W14.4b; live-verified 2026-07-17).** `07` S2. `createExtract`/`appendToExtract` now route through `NotesModel.openItem`, which raises the Extracts window and selects the new/updated extract. GUI drive confirmed it end-to-end: with the Notes window frontmost and a passage selected, Create Extract flipped the front window Notes→Extracts and the new extract was selected. No further work. *Files (shipped):* `.../Core/NotesModel.swift`, `.../Editor/EditorFormatting.swift`.
- **D6. `roundup` date field: UI or removal** (LOW-MED) — overview/`06`–`07`. Field persists + round-trips but has no UI and is always `false`. Either add the "round to year / circa" affordance in the date inspector or remove the field + its codec handling. *Files:* `.../Views/NoteMetadataInspector.swift`, `.../Store/Item.swift`, `FrontMatterCodec.swift`.
- **D7. Raw→styled parse-failure banner / stay-in-raw** (LOW) — `03` §6. Detect a genuine parse failure in `switchMode` and surface the non-destructive banner instead of degrading silently. *Files:* `.../Editor/MarkdownEditorView.swift`.
- **D8. Empty-state UI** (LOW) — overview G2. Add an empty state for an empty note list / empty folder. *Files:* `.../Views/NotesBrowserView.swift`.
- **D9. Smart-folder live match-count badge** (LOW) — `06` S2/S3. Compute the count for smart rows (search already exists). *Files:* `.../Core/NotesFolderNode.swift`, `NotesFolderTreeView.swift`.
- **D10. Extract inspector provenance summary** (LOW) — `07` S4. Detail-pane list of distinct source notes + counts (aggregate count column already exists). *Files:* `.../Views/NoteMetadataInspector.swift` / a new inspector section.
- **D11. Editor large-paste off-main parse** (LOW-MED perf) — `03` S6. `MarkdownBridge` is `@MainActor` and `insertLargeTextAsync` parses inside `MainActor.run`; either make the parse produce a Sendable AST off-main (as designed) or drop the "pure nonisolated" header claim + stale comment. *Files:* `.../Editor/MarkdownBridge.swift`, `EditorTextView.swift`.
- **D12. Small correctness/coverage/cosmetic** (LOW): block-header chip thumbnail render (`03` §8); ordered-list renumber-from-first (`03`); focus-on-appear focus-token (`03` §1); drop move-vs-copy cursor + AppKit drop reliability (`06` §5); wrap Trash delete in `NSFileCoordinator` (`06` §5 — intent already met); extract paste degradation status string (`07` §5); e2e-durable-links.sh step-5 negative parity (`08` §4.5); delete vestigial `NoteBody`/`NoteBlock` dead types (`03`); add `nestedListMixed` + debounce/snapshot unit tests (`03`/`06`). Retire or extract the `SearchGeneration` helper (`02`) and add the filename↔front-matter divergence log line (`02`). **Provenance-chip initial visibility (2026-07-17 GUI drive):** on item selection — and after a raw⇄styled toggle — the compact detail-pane editor can render scrolled past block 0, so an extract's note-passage provenance chip is hidden until a manual scroll-to-top; scroll the editor to its top on item load so the chip (the whole point of an extract) is visible without interaction. *Files:* `.../Views/NoteEditorPane.swift` / `.../Editor/MarkdownEditorView.swift`.

---

## Phase E — Verification review (do LAST; gates deleting this plan)

**Why this phase exists:** this plan was only necessary because the W0–W8 checkboxes overstated completion —
whole subsystems were marked shipped while their UI entry point was never wired. Do not repeat that mistake
on the fixes. When Phases A–D are done, run a dedicated verification pass that *proves* each closed item is
real end-to-end **before** flipping any checkbox. Follow the paced method in `REVIEW.md` (one subsystem per
session, refute-verify — **never** one giant fan-out).

**E1. Re-run the plan-vs-build gap analysis on every A–D item.** Use the same method that produced this plan
(a reviewer per affected area; **open the source and confirm behavior, not filename existence**). For each
Phase B/C item specifically, prove there is a **production caller** — grep each type/view/command referenced
outside `Tests/` — so nothing regressed back into "built but dead." *Verify:* each A–D item is CONFIRMED,
with `file:line` evidence. *Done:* a written pass/fail per item; any FAIL loops back to its phase.

**E2. Drive the wired features at runtime.** For B1–B9 and the Phase D UI items, actually exercise them in
the running app (or via `ArchiveNotesUITests` / `scripts/gui-drive-notes.sh` + the `an.editor.test.*` DEBUG
seams against the **scratch fixture only**): auto-fill writes front-matter; note-level chips render; a note
retitles/re-tags and the Finder-tag projection follows; **a note *and* an extract get their author set in-app
without Zotero, persisted to front-matter + FTS (B8)**; a pasted page-link shows a thumbnail;
`archivenotes://open?id=…` selects the note; **Copy Link puts the item's `archivenotes://open` URL on the
pasteboard and pasting it back selects/raises that item — the full Scrivener round-trip (B9 ⇄ B5)**; a
menu-created extract embeds its image bytes; a moved source re-grants in-app. Anything needing a human (real
Zotero/Reader/Scrivener install) is owner-eye — flag it, don't claim it. **Tooling:** use headless render guards
(`RenderProbe`) for pixel truth (a thumbnail / PDF pane actually drew) and `ops/gui/capture-window.sh` → read the
shot for chip / empty-state / banner rendering — see `ops/gui/README.md`. *Done:* each behavior observed, not inferred.

**E3. Prove the safety-net actually bites.** Confirm the new guards fail on a planted violation, not just
pass on the clean tree: `./test-smoke.sh archivecore` runs and is in `all`; the Processor lint trips on a
planted `setResourceValue`; the ArchiveCore lint trips on an `import AppKit` in Core; the Notes smoke gate no
longer builds/invokes the UI target. Then re-run `./test-smoke.sh all` + `swift test` (packages + apps) —
all green, **no new warnings** — and re-assert the tag-safety invariants + delete-last-instance guard on a
scratch store. **Confirm the C6 scale harness runs on a scratch corpus, asserts its bounded wall-times, and
never touches the real Notes store (scratch-path guard holds).** *Done:* guards demonstrably bite; whole suite green.

**E4. Prove docs/tracker match reality, then retire this plan.** Verify Phase A landed: both READMEs +
`ArchiveNotes/AGENTS.md` + `SMOKE_TEST.md` exist and read right; the SPEC marker section is complete; the
shipped plans are deleted; no `SUITE_TODO.md` checkbox or `CLAUDE.md` Implementation Map contradicts the
tree; the doc-sync hook covers `packages/`. **Only after E1–E4 all pass:** flip the `SUITE_TODO.md`
"W9 (gap-closure)" checkbox to `[x]` (cite commits) and `git rm execution-plans/archive-notes/09-gap-closure.md`
in the same commit — the docs move with the code. *Tier per the items reviewed (SPEC/write-seam items stay Tier-2).*

---

## Explicitly out of scope (plan-stated deferrals — NOT gaps)

Recorded here so a future reviewer doesn't re-flag them: Reader/Processor *consuming* the `ArchiveSuite`
marker + corpus back-fill (D4); Processor stamping the marker; mirroring date/quality into Finder tags; a
single merged unified-writer signature; unifying the page-2 header *builder*; a shared suite-wide storage
path; page-within-merged-PDF scroll navigation; editor tables/footnotes/task-lists/strikethrough/HTML and
undo-across-raw-toggle; per-block stable GUIDs and the reverse "N extracts derive from this note" index;
Scrivener round-trip confirmation; extract re-snapshot/refresh; author inheritance; `zotero://open-pdf`
page-anchored links; Zotero write-back; multi-root Reader; Universal-Clipboard cross-Mac confirmation
(owner-eye, W8); and the GUI checks documented as owner-eye in `scripts/GUI-HARNESS.md` (G2 typing gesture,
G6 real Reader launch, G11 real Zotero launch, chip-button click gestures — all with their dispatch
auto-asserted via spies/DEBUG seams).

## Deviations to record (done differently, functionally sound — no work required)

`CoordinatedTagWriter` shared across all three apps (vs. `02` §10 "don't share in run 1"); `NotesFilter`
dates as `Int?` not `SortDate?` (`SortDate` never created, §16.3); `Item.sortDate` reimplements the SPEC
formula under a parity test rather than calling `ArchiveCore.DocumentTags.sortDate`; `PDFThumbnailer` placed
in ArchiveCore (§16.7 said app target — see C3); source-block UI realized as an editor chip attachment +
`ReaderPreviewPopover` rather than a standalone `SourceBlockView`; unit suites use swift-testing `@Test`
rather than the sketched XCTest; and the `FolderGraph→OrganizationStore` / `SmartQuery→VFolder.queryJSON`
renames (authorized by overview §16).
