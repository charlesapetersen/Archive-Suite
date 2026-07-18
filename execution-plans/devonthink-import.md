# Execution plan — Import the personal DEVONthink database into Archive Notes

**Status:** PLANNING (not started). Owner-requested 2026-07-17.
**Owner:** Charles. **App:** Archive Notes (+ shared `ArchiveCore`; depends on an Archive Reader root).
**Risk:** HIGH — irreplaceable personal research corpus, ~40k records, net-new model work. Treat the
whole project as **Tier-2** (adversarial review + functional tests on scratch copies) with an extra
**reconciliation gate** (§7). The owner's bar: *"absolutely bulletproof — no errors can creep in."*

> This plan is the tracker of record's index target (`SUITE_TODO.md` → Active execution plans). Delete it
> when the migration ships; git history keeps it.

---

## 0. What we're importing (ground truth from the sample)

Source: **two** DEVONthink 3 databases (`.dtBase2`; the `DEVONthink-1..10.dtMeta` files are numbered shards,
*not* "version 4"). DEVONthink 3.9.18 is installed and scriptable.
- **`Devonthink database for export.dtBase2`** — the note corpus, **7.6 GB**, database **"Meritocracy
  Project"** (~40k notes/excerpts; the import payload).
- **`Photo Database.dtBase2`** — **1.8 GB**, photo records named `NNNNN IMG — <Collection>` (e.g.
  `04157 IMG — Brown.pdf`), used by a small number of recent notes. **Not imported as notes**; extracted only
  so cross-database photo links resolve — every one of its photos also lives in the Archival Photos root, so
  we resolve by **name/ID** (§4a).

Corpus profile (measured, whole DB):

| Content | Count | Meaning |
|---|---:|---|
| `rtf` files | 29,757 | notes / excerpts (rich text) |
| `rtfd` files | 10,299 | notes / excerpts **with embedded images** |
| `txt` files | 31 | plain-text notes |
| `pdf` (standalone) | 141 | out of scope as notes (see §2) — provenance targets only |
| `html` | 32 | out of scope as notes |
| `inetloc`/`webloc`/`fileloc` | 61 / 16 / 1 | saved bookmarks — out of scope as notes |
| **≈ notes + excerpts total** | **≈ 40,087** | the import payload |

Embedded-link scheme distribution across all rich text (HYPERLINK targets):

| Scheme | Count | Role |
|---|---:|---|
| `x-devonthink-item://` | 26,116 | inter-note links: extract provenance, pointer-note lists, inline "see" refs |
| `file://` | 3,034 | archival PDFs (mostly under `…/Archival Photos/…`; many stale paths) |
| `zotero://` | 1,437 | Zotero select links (citations) |
| `https://` / `http://` | 710 / 178 | real internet URLs — **the only scheme that survives as `://`** |
| `DEVONwiki` | 6 | legacy wiki links |
| `applewebdata://` | 4 | transient WebKit junk |
| `mailto:` | 2 | email links |
| broken `file` (no scheme prefix, doubled path, trailing `%22`) | ≥1 | corrupt links to repair |

Key patterns confirmed by sampling (drive the transform rules in §5):
- **Extracts** are tagged **`0 Note Excerpts`** (confirmed by owner); everything else is a **note**. An
  extract ends with a DEVONthink link = its provenance. Quality tags `10 Good Note Excerpts` / `12 Best Note
  Excerpts` → 2★/3★ (§3d).
- **Every archival photo has a stable ID-name** `NNNNN — <Collection>` (e.g. `00140 — Swarthmore.pdf`), with
  a JPEG partner mirrored at `Archival Photos JPEGS/<Collection>/00140 — Swarthmore.jpg`. Folders get
  **renumbered over time** (a link's `05 A Initial Tagging` is now `04 A Initial Tagging` in the live root),
  so archival links resolve by **name, not path** (§4a).
- **Broken DEVONthink links** have a single space inside the UUID at a hyphen boundary, e.g.
  `x-devonthink-item://EF7851F5-6F3C-4373-90C5- BE14C6B8AAD5`. UUID is fixed `8-4-4-4-12` → deterministic repair.
- **`file://` prefix variants before `Archival%20Photos`** seen: `/Users/olduser/Google Drive/…`,
  `/Users/<user>/Desktop/Google Drive/…` (current canonical), `/Users/<user>/Google Drive/…`,
  `/Volumes/Archival Storage/…` (540 links — incl. a "Microelectronic News" journal run that **does** live in
  the root under `Complete Journals/Microelectronics News/`, so it resolves by name), and a corrupted
  `/Userolduseren/…`. Non-archival `file://` also exists (Zotero storage PDFs;
  a Desktop "D's revision" PDF). ~1,100 links point into **numbered processing folders** (`01`–`06`).
- **Dates live in DEVONthink's `Alias` field** (per-record metadata, NOT in the file body) → readable only
  via scripting. Some **titles are month-prefixed** ("Nov: …") — but on-disk filenames are sanitized, so
  title rules must run against the DEVONthink `name` property, not the filename (a filename scan found 0).
- **Replicants vs near-duplicates** — the single most important correctness distinction (§6):
  a *replicant* is one record filed in many groups (**all instances share one `uuid`**); a *near-duplicate*
  is an independent record with a **different `uuid`** and near-identical text (the owner's deliberate
  "add a space / nonsense char so DT won't dedupe" trick, used to give one idea several timeline dates).

---

## 1. Strategy — a 3-stage offline pipeline + a reconciliation gate

```
 DEVONthink 3 (read-only, on a COPY)
        │  DTI-1  EXTRACT (JXA over `contents of <db>`)
        ▼
 Canonical extraction  =  per-record JSON manifest  +  content sidecars (HTML w/ hrefs, rtfd media)
        │  DTI-2  TRANSFORM (pure, unit-tested functions — no I/O to DT or the live app)
        ▼
 Import model  =  resolved notes/extracts, link graph, dates, memberships, assets
        │  DTI-4  MATERIALIZE (write items/<uuid>/*.md + assets + organization.json)
        ▼
 A FRESH Archive Notes store  →  DTI-5 VERIFY & reconcile  →  owner adopts
```

Why this shape:
- **Extraction is decoupled from transform.** The JSON manifest is the frozen, inspectable source of truth;
  every later stage is a pure function over it, re-runnable and diffable. Bulletproofing (§7) hinges on the
  extraction being provably complete *before* any transform runs.
- **Never touch the original.** All DT reads run against a **copy** of the `.dtBase2` (repo rule: never
  write a real corpus). First action is a *File > Export > Database Archive* ZIP as an untouched safety net.
- **Never touch the live Archive Notes store.** Materialize into a **fresh store root**, verify, then the
  owner swaps it in (memory: *never mutate the live app root*).

### Extraction method — custom JXA dump (decided)
Research verdict: **script-driven per-record extraction via the DEVONthink AppleScript/JXA dictionary** is
the only lossless option. DT's built-in *File > Export* choices are all lossy for us — *Files and Folders*
**flattens replicants into duplicated files** and no menu export emits JSON or preserves the replicant
*relationship*. Only scripting yields, in one pass: stable `uuid`, the full metadata set, **and** each
record's `parents` (the replicant graph). Reference building blocks (adapt, don't adopt wholesale — none
model replicants for us): `dvcrn/mcp-server-devonthink` (JXA, fullest field coverage),
`extracts/mac-scripting` (per-record faithful exporter), DEVONtechnologies forum JSON/JXA snippets.

Per-record properties to capture: `uuid`, `id`, `reference URL`, `name`, `aliases`, `tags`, `comment`,
`label`, `rating`, `state`, `URL`, `creation/modification/addition/document date`, `location`, **`parents`**,
`number of replicants`, `number of duplicates`, `record type`, `kind`, `word count`, `content hash`,
`custom meta data`, plus content: `source`/`rich text` (and `plain text` for cross-check). **Link hrefs**:
`plain text` strips URLs, so convert each RTF/RTFD via `textutil -convert html` (retains `<a href>`) and
parse hrefs — or read `source` directly for records DT already stores as HTML/MD. rtfd embedded images are
files inside the `.rtfd` package → copy them out (in scope, §2).

---

## 2. Scope (locked with owner 2026-07-17)

**In scope:** the ~40k **text notes + excerpts** (`rtf`/`rtfd`/`txt`), **including images embedded in
notes** (rtfd media → each note's `assets/`, re-linked as markdown images).

**Out of scope as their own notes:** standalone `pdf`/`html`/`png`/`pages` records and saved
bookmarks (`webloc`/`inetloc`/`fileloc`). Archival PDFs still appear — but as **provenance targets** of
notes (durable Reader links, §5), never as imported note bodies.

**Excluded (dropped, not migrated):** DEVONthink DIY **template placeholders** — records whose title contains
**"Template"** and **"Copy"** (case-insensitive) **with no text body** (the owner's old templating method;
Archive Notes has real templates). Count logged in the report. This removes the bulk of the empty-normalizing
records (the review measured ~1,900 `copy copy…` empties).

**Image-only notes are content, not empty (owner, 2026-07-17):** a note that is just image(s) — optionally
plus a stray space/nonsense char — is imported normally (images → `assets/`). **"Empty" means no text AND no
images**; image-only records are never treated as empty and never text-merged (§6).

---

## 3. Target model & the decisions locked with the owner

Archive Notes stores one Markdown file per note (`items/<uuid-lower>/<SanitizedTitle>.md`, YAML
front-matter + block body) with a disposable rebuilt index; the folder graph + memberships live in
`organization.json`. Model: `struct Item` (`ArchiveNotes/macOS/Sources/ArchiveNotes/Store/Item.swift`),
blocks/provenance: `Block` + `SourceAnchor` (`Store/BlockParser.swift`), durable links:
`ArchiveCore/Links/DurableLink.swift`, root identity: `RootMarker` (`.archive-suite-root.json`).

| DEVONthink concept | Archive Notes target | Fit |
|---|---|---|
| Record (note) | `Item(kind:.note)` — one `items/<uuid>/*.md` | native |
| Record tagged excerpt (`0 Note Excerpt(s)`) | `Item(kind:.extract)` + `note-passage`/reader provenance block | native |
| **Replicant** (1 record, N `parents`) | **one `Item`, N folder memberships** (`VFolder`/`Membership` in `organization.json`) | native — replication is memberships, not copies |
| DT group hierarchy | `VFolder` graph | native |
| Subject tags | `Item.tags` (+ mirrored Finder tags via `NotesTagProjector`) | native |
| **Number-prefixed control tags** (`0 Note Excerpt(s)`, `10 Good…`, `12 Best…`) | drive `kind`/`quality`; **stripped from** `Item.tags`, never imported as subjects (§3d) | rule |
| **Quality control-tags** (`12 Best…`→3★, `10 Good…`→2★) | `Item.quality` on a **new 3★ scale** | **NET-NEW (§3d)** |
| Extract's trailing DT link | `SourceAnchor.noteRef` = `archivenotes://open?id=<newUUID>#block-n` | native |
| Internet URL | markdown link (only surviving `://`) | native |
| **Alias date + additional dates** | **primary date + `additional_dates[]`** | **NET-NEW (§3a)** |
| **Pointer-note link list** | **"Related notes" section** | **NET-NEW (§3b)** |
| Archival `file://` PDF | `reader-doc`/`reader-page` block, durable `archivereader://` link | native *iff* a Reader root exists (§8) |

### 3a. Multi-date — "primary + additional dates" (owner choice)
Today `Item` has exactly one date (`date`, `datePrecision`, `dateUncertain`; `Item.swift:19-21`) and the
index emits one `sortDate` (`Item.swift:39-59`). Add:
- **Model:** `additionalDates: [DateValue]` where `DateValue = {date:String, precision:DatePrecision,
  uncertain:Bool}` (factor today's three coupled fields into a reusable `DateValue`; keep the existing
  `date`/`date_precision`/`date_uncertain` as the **primary** for back-compat).
- **Front-matter:** new key `additional_dates` appended to `FrontMatterCodec.knownKeys`
  (`FrontMatterCodec.swift:156-160`). Unknown keys already round-trip, but surfacing in UI + index requires
  it to be a known key.
- **Index / timeline (the crux of "appears in multiple places"):** the decade facet + timeline read one
  `sortDate` per row today. A note with N dates must appear at **each** date → emit **one index row per
  date** (primary + each additional), or add a date-multiplicity table. This is the change that makes a
  consolidated near-duplicate show up on the timeline at every original date.
- **UI:** date editor gains add/remove additional dates; note header shows all; timeline dedupes by note id
  when a range spans several of a note's dates. (Detailed UI is a sub-task, not blocking the importer.)

### 3b. Pointer-notes — "Related notes" section (owner choice)
Notes that begin with a run of DEVONthink links to other notes/extracts become a first-class, one-way
**Related notes** list (note→note links, resolved by uuid to the imported target). Represent as either a
dedicated front-matter key `related: [<uuid>…]` or a distinct `related-notes` block; render as a labeled
section. Distinguish from extracts (which carry `note-passage` provenance, not "see also").

> **Verify the new §3a/§3b views** (per-date timeline rows, Related-notes section) with a reference-image
> snapshot (`SnapshotTests`) or the live sighted loop (`ops/gui/capture-window.sh` + `cliclick`) — see
> `ops/gui/README.md`. XCUITest asserts the a11y tree, not the rendered layout.

### 3c. Provenance blocks (existing, reused)
- Extract provenance → `note-passage` block (`SourceAnchor.notePassage`, `SourceAnchor+NotePassage.swift`).
- Archival PDF provenance → `reader-page`/`reader-doc` block with `SourceAnchor.link` = durable
  `archivereader://reveal?root=<GUID>&rel=<pct-path>[&page=n]` (`DurableLink.readerReveal`).
- Zotero → `zoteroItem`/`zoteroAttachment` block / `Item.zotero` (`ZoteroRef`) with `SourceAnchor.zoteroSelect`.

### 3d. Rating — switch 5★→3★, and map quality control-tags (owner, 2026-07-17)
Today `Item.quality` is a **1–5** star rating (`Item.swift`). **Change Archive Notes to a 3★ scale (1–3).**
Import maps the DEVONthink quality control-tags to it: **`12 Best Note Excerpts` → 3★**, **`10 Good Note
Excerpts` → 2★** (no such tag → no rating). These number-prefixed tags — like the `0 Note Excerpt(s)`
excerpt marker — are **control tags: stripped from `Item.tags`, never imported as subject tags.**
- **Broader app change (bundled into DTI-3):** the 5→3 star control + any rating filter, and a remap of any
  *existing* 4–5★ ratings already in the app (min, if any — new app). Standalone from the import mechanics but
  the import targets the 3★ scale, so it ships first.
- **Open classification question (DTI-0):** do `Good/Best Note Excerpts`-tagged records **also** carry the
  `0 Note Excerpt` marker (quality is an overlay on excerpts), or do these tags themselves mark a record as an
  excerpt? This affects note-vs-extract classification (§5) — confirm against the real DB before the bulk run.
- **Sweep for other `N …` control tags** in DTI-0 (e.g. other number-prefixed tags) and decide each explicitly
  rather than letting them leak in as subjects.

---

## 4. The link-conversion contract (the correctness core)

End state (owner's rule): **nothing survives as a `file://`, `zotero://`, or `x-devonthink-item://` link;
only genuine internet URLs remain as `://`.** Every conversion is deterministic and reported.

| Source link | Count | Transform | Failure handling |
|---|---:|---|---|
| `x-devonthink-item://UUID` → a **note** | ~26k | resolve UUID → imported note's new id. Role decides shape: **trailing** on an extract → `note-passage` provenance; **leading run** on a note → Related-notes entry; **inline** → inline `archivenotes://open?id=…` link | UUID not in manifest → **flag** (unresolved), never silently drop |
| …with a **space in the UUID** | subset | repair: remove interior space, re-validate `8-4-4-4-12`, then resolve as above | fails validation → flag |
| `x-devonthink-item://UUID` → a **Photo Database** record | small | cross-DB: look up the record's **name/ID** in the Photo Database manifest → resolve that photo **by name** in the Archival Photos root → durable `archivereader://` link (§4a) | name not found in root → **flag** |
| `x-devonthink-item://UUID` → other out-of-scope record | subset | if it maps to an archival photo, route via §4a; else flag | flag |
| `file://…/Archival Photos/…` | most of 3,034 | **resolve by name/ID (§4a), not by path** → durable `archivereader://` link into the Reader root (+ page if present) | name not found in root → **flag** (§7) |
| `file://…/Volumes/Archival Storage/…` | 540 | resolve by filename via §4a — incl. the "Microelectronic News" journal run (lives in the root under `Complete Journals/Microelectronics News/`) | filename not found in root → **flag** |
| `file://…` into a **numbered processing folder** (`01`–`06`) | ~1,100 paths | resolve by name/ID (§4a) — most now live in a permanent collection; those still **only** in a processing folder (will move out post-migration) → **flag** | flag |
| `file://…` Zotero storage PDF | subset | tie to the record's `zotero://` item as a `zoteroAttachment` if resolvable; else flag | flag |
| `file://…` other (Desktop, non-corpus) | few | **flag for owner review; default disposition = move the target into Zotero** and represent as a `ZoteroRef`/attachment (owner 2026-07-17; expected rare) | flag |
| `zotero://select/…` | 1,437 | `ZoteroRef` / `zoteroItem` block (`SourceAnchor.zoteroSelect`); **enrich to a full citation when the local Zotero DB is available, else keep the select link** (owner 2026-07-17) | keep select link even if enrichment unavailable |
| `https://` / `http://` | 888 | keep as markdown link (unchanged) | — |
| `DEVONwiki` | 6 | resolve to a note link by target name; else flag | flag |
| `applewebdata://` | 4 | drop (transient WebKit artifact), log each | logged |
| `mailto:` | 2 | keep as `mailto:` link | — |

**Corrupt links** (e.g. the observed `olduser/olduser/…Archival%20Photos/…pdf%22` — doubled segment, missing
`file:///Users/` prefix, stray `%22`): a repair pass strips the trailing `%22`, de-dupes the doubled
segment, and re-anchors on `Archival%20Photos`, then routes through §4a. Anything the repair can't
confidently fix is flagged, never guessed.

### 4a. Archival photo resolution — by stable name/ID, not path
Every archival photo carries a **stable filename** — either `NNNNN — <Collection>` (e.g. `00140 — Swarthmore`)
or, for journal runs, `YYYY — <Journal> — NNNNN` (e.g. `1981 — Microelectronic News — 00075`). The same photo
is referenced from many stale paths (old usernames, `/Volumes/…`, renumbered processing folders, the Photo
Database) but its **filename never changes**. So the importer:
1. **Builds a filename→path index** of the live Archival Photos root once (all `.pdf`, plus `.jpg`/`.jpeg`).
   Key = the normalized filename **stem** (strip extension + `.zip` bundles, collapse spacing, drop the Photo
   Database's `IMG` token, NFC) — this covers both naming conventions and is robust to **folder-name variance**
   (links say "Microelectronic News" while the folder is "Microelectronic**s** News" — we key on the file, not
   the folder). For **Photo Database** cross-DB matches the **numeric ID is authoritative** (owner-confirmed
   always accurate); normalization only absorbs formatting drift (the `IMG` token, em-dash vs hyphen, spacing,
   singular/plural collection). **Detect and report any duplicate/ambiguous match** (a number that maps to >1
   root file, or a colliding stem) — never silently pick wrong.
2. **Resolves every archival link by that key** — file:// (any prefix), `/Volumes/…`, processing-folder paths,
   and Photo Database cross-DB links all collapse to "find this filename in the root."
3. **Emits a durable `archivereader://reveal?root=<GUID>&rel=<current-relative-path>[&page=n]`** to the
   resolved file. Keyed on the **root GUID + current relative path**, so a later **root rename/move is safe**
   (§8 root-rename): Reader re-establishes the root at the new location under the same `RootMarker` GUID.
4. **JPEG partner (tracked to-do):** the matching `.jpg` sits at the mirror path under `Archival Photos JPEGS/`
   (confirmed: `…/Archival Photos JPEGS/Swarthmore/00140 — Swarthmore.jpg`). The Reader image entity — and thus
   the Notes link — should be able to reference **both** (PDF by default, JPEG on demand). **On the to-do list**
   (`SUITE_TODO.md`, owner request); not a blocker for this import (links resolve to the PDF; the JPEG is always
   derivable from the filename). **Verify** with a headless render guard that the PDF page and its JPEG partner
   both render non-blank (`RenderProbe`/`DocumentRenderGuardTests`), plus `ops/gui/` for the in-viewer switch.
5. **Unresolved → flag**, never a guessed path: filenames not found in the root (a photo still only in a
   processing folder that will move out; a truly-missing target; oddball `.docx`/`.wav`/`.jpf` targets).

---

## 5. Transform details (DTI-2)

- **Note vs extract:** by the `0 Note Excerpts` tag. Assert every record classifies as exactly one; report
  any record with neither/both. (DTI-0 confirms whether `Good/Best Note Excerpts` records also carry it — §3d.)
- **Exclusions & emptiness (§2):** drop DEVONthink template placeholders (title has *Template* + *Copy*, no
  text). A record is **empty** only if it has **neither text nor images**; **image-only** records are real
  content (import the image(s); never text-merge them — §6). Any truly-empty non-template record → **flag**
  (expected near-zero after exclusion).
- **Archival links:** resolve via the name/ID index (§4a), spanning both databases; emit durable Reader links.
- **Quality & control tags (§3d):** map `12 Best Note Excerpts`→3★, `10 Good Note Excerpts`→2★ into
  `Item.quality` (3★ scale); **strip every number-prefixed control tag** (`0/10/12 …`) from `Item.tags` so
  only real subject tags survive. Any other `N …`-prefixed tag → report for an explicit decision, never a
  silent subject tag.
- **Dates:** parse `Alias` → primary `date` + `datePrecision` (+ `dateUncertain` if the alias is fuzzy).
  Alias date grammar is discovered in DTI-0 (e.g. `1955`, `Mar 1955`, `1955-03-12`, `Nov`); the parser is a
  small, fully-tabulated, unit-tested grammar — unrecognized alias → flag, never a wrong date. **Month-prefix
  titles** ("Nov: …") on the DT `name`: move the month into a `date`/`datePrecision:.month` (only if no
  conflicting alias date) and strip the prefix from the title.
- **Body → blocks/markdown:** RTF/RTFD → markdown; preserve emphasis/lists; extract embedded rtfd images to
  `assets/` and rewrite as markdown image refs. DT item-link "images" that are really links, not media, go
  through the link contract, not asset import.
- **Links:** apply §4 in a single deterministic pass over the HTML-with-hrefs, using the uuid→new-id map.
- **Replicants → memberships** (§6). **Groups → VFolders** mirroring the DT hierarchy (filter the `/Tags`
  pseudo-groups DT models as replicants).
- **Near-duplicate consolidation** (§6) → one note carrying primary + additional dates.

All of DTI-2 is pure functions with a **fixture corpus** (hand-built tiny DT export + golden expected
output) so every rule has a regression test. No transform reaches DEVONthink or the live app.

### 5a. OCR-quality flagging & gated repair (owner, 2026-07-17)
Much of the corpus is text copied from imperfect PDF OCR, with three recurring defects: **glued words**
(`careerdidnotoccurtome`), **split spacing** (`m a g a zin e`), and **bad line breaks** (hard wraps
mid-sentence). Running all ~40k notes through a model to find these is prohibitively expensive, so detection is
free and only the flagged subset ever costs model tokens.

- **Detect — free, pure code over the extracted text (≈0 model tokens), on every note.** Per-note signals
  (validated on the owner's examples; prototype `ocr_defect_detector.py`): space-ratio (low → glued, high →
  split), a ≥18-char glued-run count, orphan short-token ratio (split), and mid-sentence-newline ratio (bad
  wraps); a local dictionary corroborates. Each note gets defect tags {glued-words, split-spacing,
  bad-line-breaks} + severity, and an **OCR report** lists counts + worst offenders. Thresholds are
  **calibrated in DTI-0** on a labeled sample (the owner's 5 examples are the seed fixtures) — tuned for high
  recall, low false-positive.
- **Repair — only the FLAGGED subset, after owner review, cheapest tier first:** (1) **deterministic (free):**
  join mid-sentence hard wraps (newline→space); de-hyphenate soft-hyphen / `word-\nfrag` splits. (2) **local
  word-segmenter (free):** a dictionary/Viterbi segmenter fixes many glued/split cases with no model
  (`careerdidnotoccurtome` → `career did not occur to me`). (3) **model tier (bounded tokens):** only the
  residue tiers 1–2 can't confidently fix, **batched** many-per-call and paced. **Transpositions**
  (`targets must past be set`) are flagged, **never auto-fixed** — owner review only (reordering is too risky).
- **Bulletproof:** the **original text is always preserved** (frozen manifest + an `original` variant on the
  note); every fix is **proposed for owner review**, never silent or irreversible. Token math: flagging ≈ free;
  only the model-tier residue of the flagged subset ever costs tokens — not "millions to scan everything."

---

## 6. Replicants vs near-duplicates (get this exactly right)

- **Replicant** — same underlying record filed in ≥2 groups. **All instances share one `uuid`**;
  `parents of <record>` lists every group. → **De-dupe by `uuid` to a single `Item`; add one `Membership`
  per real parent group** (excluding `/Tags`). This reproduces the DT filing exactly, as memberships not
  copies. `number of replicants > 0` is the gate.
- **Near-duplicate** — independent records, **different `uuid`s**, near-identical text (owner's deliberate
  space/nonsense-char trick to carry multiple timeline dates). → **consolidate into one `Item`** whose
  primary date is one occurrence's alias and whose `additional_dates` collect the others' alias dates.
  **Merge policy (owner, 2026-07-17): auto-merge only when normalized-text similarity is ≈98%+ AND the
  records' `Alias` dates differ** — the exact signature of the owner's pattern (same idea, a space/nonsense
  char apart, filed under different dates). Anything below the threshold, or with the *same* alias date, is
  **flagged for owner review, never auto-merged.** Because this is fuzzy (not exact-match), a false merge =
  irreversible data loss, so: (a) the similarity metric + exact threshold are **calibrated in DTI-0 against
  real near-dup pairs** before any bulk merge; (b) every auto-merge is logged with both source uuids, a text
  diff, and all dates; (c) near-threshold merges are additionally surfaced in the review report; (d)
  consolidation preserves the **union** of the losers' tags/links/memberships/provenance — nothing is dropped;
  and (e) a **min-length floor** guards against degenerate matches — records with **empty/below-floor
  normalized text are never text-merged**, and template placeholders are excluded upstream (§2), so
  empty-normalizing records can't mass-merge.
- **Image-only near-duplicates** — the multi-date trick also applies to image-only notes (same image, a
  space/nonsense char apart, different dates). Match these by **image content-hash** (identical image set +
  differing alias dates → merge into multi-date; else **flag**), never by text.

`uuid` is the **only** trustworthy discriminator (DT's "duplicate" flag is content-based and unreliable
for this). This distinction is the highest-severity correctness item in the project.

---

## 7. Bulletproofing — the reconciliation gate (DTI-5)

The migration is not "done" until every check passes and is reported. Nothing is destructive: the original
DB and the live Notes store are untouched; the output is a fresh store the owner adopts only after review.

1. **Count reconciliation.** `records_in == notes_out + extracts_out + merged_away`, with `merged_away`
   itemized. Cross-check against DT *Tools > Create Metadata Overview* (TSV) record/tag counts.
2. **Zero dangling links.** Assert **no** `x-devonthink-item://`, `zotero://`, or `file://` remains anywhere
   in the output (only `http(s)`/`mailto`). Any residue fails the gate.
3. **Every archival link resolves to a real file.** Probe the filesystem for each converted
   `archivereader://` target; unresolved → report (must be zero, or explicitly owner-accepted).
4. **Every extract has provenance.** No extract lands without a `note-passage`/reader/zotero source.
5. **Replicant fidelity.** For each de-duped uuid, memberships == real parent count.
6. **Round-trip spot check.** Re-parse a random N notes with `FrontMatterCodec`/`BlockParser`; must
   round-trip byte-identical.
7. **Human audit.** A generated diff/report (counts, flags, merges, unresolved) + manual UI spot-check of a
   stratified sample (a replicant, a consolidated near-dup, an extract, a pointer-note, an archival-provenance
   note) before adoption.
8. **Reversibility.** Fresh store + untouched original = re-runnable from the frozen JSON manifest at will.
9. **OCR-quality report.** The free detector's defect counts (glued/split/wrap) + worst offenders are reported;
   any note whose text is later repaired retains its verbatim **original** (§5a) — repairs are owner-reviewed,
   never silent.

Every "flag" above lands in a single report; the run **stops for owner review on any non-zero flag class**
rather than importing best-effort.

---

## 8. Owner prerequisites (the full checklist)

**Source / DEVONthink side**
1. ✅ DEVONthink 3 installed & able to open the DBs (3.9.18).
2. ✅ **Working copies of both `.dtBase2` files** (Meritocracy + Photo Database) to extract from — never the originals.
3. ✅ **A *Database Archive* (`.zip`) backup** of the originals, kept until verified & adopted.
4. ⏳ **Grant Automation (Apple Events) permission** so the extraction script can control DEVONthink —
   walkthrough provided (a TCC prompt on first run, or pre-grant in System Settings ▸ Privacy & Security ▸
   Automation). **Owner note:** Terminal currently lists only *System Events.app* under Automation — the
   DEVONthink toggle appears only **after** the script first sends an Apple Event to DEVONthink, so we grant it
   **at launch** (the one-line trigger script surfaces the prompt). Deferred until then.
5. 🔔 **Close the databases in your primary DEVONthink at launch** (or OK opening the copies in a separate
   context) — avoids the lock / shared-`uniqueId` conflict (`isOpen=true` + a `.lock` were present). *Remind at launch.*
6. ✅ **Excerpt tag = `0 Note Excerpts`** (confirmed). DTI-0 still checks whether `Good/Best Note Excerpts`
   records also carry it (§3d).
7. ✅ **Second database identified: `Photo Database`** — extracted for name-based cross-DB photo resolution
   (§4a), not imported as notes.

**Provenance / Archive Reader side**
8. ✅ **Archive Reader root over `~/Desktop/Google Drive/Archival Photos/`** (path confirmed; needs a
   `RootMarker` GUID). **Post-migration root rename is supported — see §8a.** The `01`–`06` processing folders
   may move out of the root afterward; any note resolving only into them is flagged pre-adoption (§4a/§4).
9. ✅ **`/Volumes/Archival Storage` + JPEGs understood** (see the #9 answer): archival targets resolve by
   filename (§4a), incl. the "Microelectronic News" journal run (in the root under `Complete Journals/`);
   `.jpg`/`.jpeg` targets map to `Archival Photos JPEGS/`.

**Zotero side**
10. ✅ **Zotero installed with its local library accessible** (citation enrichment + non-archival→Zotero moves).

**Target / Archive Notes side**
11. ✅ **Fresh output store root** for the import to build into (fresh-store swap, §9.7; the live store is not
    written to until you adopt).
12. ⏳ **App feature-complete before import** — multi-date, Related-notes, and the 3★ rating are **built first
    as Notes gap-closure**; this plan **assumes** them and specifies the requirements (§3a/§3b/§3d), it does
    not own building them. *("Making a plan for how to import once the app is complete.")*

**Machine / operational**
13. ✅ **Disk headroom — 45 GB free**; the two DB copies (~9.4 GB) + sidecars + fresh store fit comfortably
    (exact sizes reconfirmed in DTI-0).
14. 🔔 **A multi-hour window** with the machine free for the extraction run. *Remind when ready.*
15. ✅ **Owner availability to adjudicate the review report** (flags, borderline near-dup merges) before adoption.

### 8a. Renaming the root folder after migration (owner request)
The `Google Drive` folder name is historical (it isn't Google Drive). Renaming/moving the root **after**
migration is **low-risk by design**, because durable links don't hard-code the path: each `archivereader://`
link is `root=<GUID>&rel=<relative-path>`. Steps: (1) rename/move the folder; (2) re-point the Archive Reader
root at the new location — it keeps the same `RootMarker` GUID (`.archive-suite-root.json` travels with the
folder), so every Notes link keeps resolving. **Constraint honored:** the non-numbered collection folders keep
their structure (relative paths unchanged); only the root's own name/location changes.

---

## 9. Decisions (owner, 2026-07-17)

**Locked:**
1. **Zotero fidelity** — resolve `zotero://select` to a full `ZoteroRef` citation **when the local Zotero DB
   is available; otherwise keep the select link + item key. Never block on it.**
2. **Near-duplicate merge** — **auto-merge only when normalized-text similarity ≈98%+ AND the `Alias` dates
   differ**; everything else → owner review. Metric/threshold calibrated in DTI-0; every merge logged with a
   diff; losers' tags/links/memberships/provenance preserved as a union (see §6).
3. **Non-archival `file://`** (Zotero PDFs; misc Desktop/Volume PDFs) — **flag for owner review; default
   disposition = move the target into Zotero** and represent as a `ZoteroRef`/attachment. Expected rare.
4. **Minor schemes** — `DEVONwiki` → note-link-or-flag; `applewebdata` → drop + log; `mailto` → keep.
5. **One-time migration** — idempotent + re-runnable from the frozen manifest, but **not** an ongoing sync.
6. **Rating scale** — switch Archive Notes from 5★ to **3★**; import maps `12 Best Note Excerpts`→3★,
   `10 Good Note Excerpts`→2★; number-prefixed control tags are stripped, not imported as subjects (§3d).
7. **Adoption model** — **fresh-store swap**: build the import into a new store, verify it against the §7
   gate, then point Archive Notes at it (the prior store is left untouched → fully reversible). *No merge.*
8. **Excerpt tag** — `0 Note Excerpts` (confirmed); `10 Good` / `12 Best Note Excerpts` → 2★/3★ (§3d).
9. **Archival resolution by name/ID** (§4a), across both DBs — a note→photo link (file://, `/Volumes`,
   processing-folder path, or a **Photo Database** cross-DB link) resolves by the stable `NNNNN — <Collection>`
   name in the Archival Photos root, not by path.
10. **Numbered processing folders (`01`–`06`)** — name-resolve; a photo found only in a processing folder
    (which moves out post-migration) is **flagged**. `/Volumes` links resolve by filename (the "Microelectronic
    News" run lives in the root under `Complete Journals/`); only genuinely-absent filenames flag.
11. **Root rename after migration** — supported; durable links survive (§8a).
12. **PDF/JPEG dual reference** — a **tracked Suite feature** (Reader image entity referencing both PDF and its
    JPEG partner; PDF default, JPEG on demand) — on the to-do list (`SUITE_TODO.md`); not a blocker (§4a).
13. **Templates & empty/image-only records** — DEVONthink DIY template placeholders (title has *Template* +
    *Copy*, no text) are **excluded** from import (§2). "Empty" = no text AND no images; **image-only notes are
    content** (images imported), never text-merged; text auto-merge needs text above a min-length floor;
    image-only near-dups match by image content-hash (§6). *Closes the wave-1 empty-body mass-merge finding.*
14. **OCR-quality flagging & gated repair** — flag glued-words / split-spacing / bad-line-breaks with a **free
    pure-code detector** over all notes (§5a); repair only the flagged subset, cheapest-tier-first
    (deterministic → local segmenter → model on the residue), **after owner review, originals preserved**;
    transpositions flagged, never auto-fixed.

*All owner decisions resolved. DTI-0 discoveries (findings, not decisions): the `Alias` date grammar;
month-prefix title format; near-dup prevalence + similarity calibration; replicant counts; the name-index
normalization + any duplicate/ambiguous photo names; whether `Good/Best Note Excerpts` records also carry the
`0 Note Excerpts` marker; a sweep for other `N …` control tags.*

---

## 10. Phases & sequencing

Each phase is bounded, reviewed (Tier-2), and leaves an inspectable artifact. **DTI-3 (the model changes) is
assumed already shipped** as Notes gap-closure before the import runs (owner: "a plan for how to import once
the app is complete") — it is listed only as the dependency it is. Those shared-`ArchiveCore`/`Item` changes,
whenever built, must build **and test all three apps** (memory: shared-core changes rebuild Reader + Processor
+ Notes).

| Phase | Deliverable | Effort | Depends |
|---|---|---:|---|
| **DTI-0 — Spike & ground truth** | JXA extraction spike on **copies of both DBs** over a 300–500 record sample; **build the Archival Photos name/ID index** (§4a) + report duplicate/ambiguous names; corpus-profile report on the §9 findings (alias grammar, month-prefix, near-dup calibration, replicant counts, `Good/Best`-overlay, other control tags). De-risks everything. | M | copies of both DBs |
| **DTI-1 — Full extraction** | Complete JXA dump of **both databases** → frozen JSON manifest (all fields incl. `parents`; Photo Database → uuid→name only) + content sidecars (HTML w/ hrefs, rtfd media) + count cross-check vs Metadata Overview TSV. | L | DTI-0 |
| **DTI-2 — Transform library** | Pure, unit-tested transform: classify, dates, link contract (§4/§4a), replicant/near-dup (§6), blocks/assets. Fixture corpus + golden tests. Emits the import model + a dry-run report. | L | DTI-1 |
| **DTI-3 — Archive Notes model changes** *(prerequisite — built as Notes gap-closure, not owned here)* | Multi-date (`additional_dates` + `DateValue`, codec, **per-date index rows**, UI), Related-notes section, and the **5★→3★ rating** switch (§3d). Tier-2 shared-core; build+test all apps. | L | before DTI-4 |
| **DTI-4 — Materializer** | Write a fresh store: `items/<uuid>/*.md` + `assets/` + `organization.json` (VFolders + memberships) directly, then rebuild index. Idempotent, deterministic, resumable. | M | DTI-2, DTI-3, §8 |
| **DTI-5 — Verify & reconcile** | Run the §7 gate; produce the report; owner audits a stratified sample; adopt. | M | DTI-4 |
| **DTI-6 — OCR-quality repair (gated)** | Run the free detector over imported notes; owner reviews the OCR report; apply tier-1/2 (free) fixes + model-tier on the residue — all **proposed for review**, originals preserved (§5a). Iterative, post-adoption-safe. | M | after DTI-5 |

Tooling (extractor/transformer/materializer/verifier) lives under a dedicated dir (e.g.
`ArchiveNotes/tools/devonthink-import/`) so it doesn't bloat the app; it's deletable after the one-time run,
but keep it in git for reproducibility until adoption is final.

---

## 11. Risks

- **Silent data loss / wrong mapping** (the owner's #1 fear) → the frozen-manifest + pure-transform +
  reconciliation-gate architecture; stop-on-flag; conservative near-dup merges; nothing best-effort.
- **Replicant/near-dup confusion** → strict `uuid` discriminator (§6); highest-severity review focus.
- **Alias/date misparse** → tabulated grammar with flag-on-unknown; no guessed dates.
- **Archival links unresolvable** (stale paths, renumbered/moved folders, external volumes, cross-DB) →
  **name/ID index** (§4a) instead of path matching + a filesystem probe in the gate; unresolved → flag; §8
  prerequisite. **Ambiguous/duplicate photo names** in the root are reported, never silently picked.
- **Scale (7.6 GB / 40k)** → extraction may be slow in JXA; batch by group, checkpoint, resume; run on a copy
  so a re-run is free.
- **Live-app / live-corpus mutation** → operate on a DB copy and a fresh output store; original untouched
  (repo file-safety Core Directive + memory *never-mutate-live-app-root*).
- **Shared-core breakage** → DTI-3 rebuilds/tests all three apps.

---

## 12. Definition of done

The §7 gate passes with zero unaccepted flags; the owner has audited the stratified sample and adopted the
fresh store; multi-date + Related-notes ship in Archive Notes (all apps build/test green); `SUITE_TODO.md`
is reconciled and this plan is deleted (git history keeps it).
