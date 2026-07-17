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

Source: `Test Files/Devonthink database/Devonthink database for export.dtBase2` — a **DEVONthink 3**
database (`.dtBase2`; the `DEVONthink-1..10.dtMeta` files are numbered shards, *not* "version 4"),
**7.6 GB**, database name **"Meritocracy Project"**. DEVONthink 3.9.18 is installed and scriptable.

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
- **Extracts** are tagged `0 Note Excerpt` **or** `0 Note Excerpts` (exact string(s) TBD in DTI-0);
  everything else is a **note**. An extract ends with a DEVONthink link = its provenance.
- **Broken DEVONthink links** have a single space inside the UUID at a hyphen boundary, e.g.
  `x-devonthink-item://EF7851F5-6F3C-4373-90C5- BE14C6B8AAD5`. UUID is fixed `8-4-4-4-12` → deterministic repair.
- **`file://` prefix variants before `Archival%20Photos`** seen: `/Users/olduser/Google Drive/…`,
  `/Users/<user>/Desktop/Google Drive/…` (current canonical, matches the live corpus at
  `~/Desktop/Google Drive/Archival Photos/`), `/Users/<user>/Google Drive/…`,
  `/Volumes/Archival Storage/…`, and a corrupted `/Userolduseren/…`. Non-archival `file://` also exists
  (Zotero storage PDFs; a Desktop "D's revision" PDF).
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
| Record tagged excerpt | `Item(kind:.extract)` + `note-passage`/reader provenance block | native |
| **Replicant** (1 record, N `parents`) | **one `Item`, N folder memberships** (`VFolder`/`Membership` in `organization.json`) | native — replication is memberships, not copies |
| DT group hierarchy | `VFolder` graph | native |
| Tags | `Item.tags` (+ mirrored Finder tags via `NotesTagProjector`) | native |
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

### 3c. Provenance blocks (existing, reused)
- Extract provenance → `note-passage` block (`SourceAnchor.notePassage`, `SourceAnchor+NotePassage.swift`).
- Archival PDF provenance → `reader-page`/`reader-doc` block with `SourceAnchor.link` = durable
  `archivereader://reveal?root=<GUID>&rel=<pct-path>[&page=n]` (`DurableLink.readerReveal`).
- Zotero → `zoteroItem`/`zoteroAttachment` block / `Item.zotero` (`ZoteroRef`) with `SourceAnchor.zoteroSelect`.

---

## 4. The link-conversion contract (the correctness core)

End state (owner's rule): **nothing survives as a `file://`, `zotero://`, or `x-devonthink-item://` link;
only genuine internet URLs remain as `://`.** Every conversion is deterministic and reported.

| Source link | Count | Transform | Failure handling |
|---|---:|---|---|
| `x-devonthink-item://UUID` → a **note** | ~26k | resolve UUID → imported note's new id. Role decides shape: **trailing** on an extract → `note-passage` provenance; **leading run** on a note → Related-notes entry; **inline** → inline `archivenotes://open?id=…` link | UUID not in manifest → **flag** (unresolved), never silently drop |
| …with a **space in the UUID** | subset | repair: remove interior space, re-validate `8-4-4-4-12`, then resolve as above | fails validation → flag |
| `x-devonthink-item://UUID` → a **PDF/other** record | subset | that record is out-of-scope-as-note but may be an archival PDF → treat as archival provenance if it maps to a `file://` under Archival Photos | else flag |
| `file://…/Archival Photos/…` | most of 3,034 | normalize everything **before** `Archival%20Photos` to the canonical corpus root → compute path relative to the **Reader root** → durable `archivereader://` link (+ page if present) | path not found on disk after normalization → **flag** (must resolve to a real PDF, §7) |
| `file://…` Zotero storage PDF | subset | tie to the record's `zotero://` item as a `zoteroAttachment` if resolvable; else flag | flag |
| `file://…` other (Desktop, `/Volumes/…`) | subset | resolve to a Reader link only if under a Reader root; else record as unresolved-source in the report | flag |
| `zotero://select/…` | 1,437 | `ZoteroRef` / `zoteroItem` block (`SourceAnchor.zoteroSelect`); optional citation enrichment (§ open decision) | keep select link even if enrichment unavailable |
| `https://` / `http://` | 888 | keep as markdown link (unchanged) | — |
| `DEVONwiki` | 6 | resolve to a note link by target name; else flag | flag |
| `applewebdata://` | 4 | drop (transient WebKit artifact), log each | logged |
| `mailto:` | 2 | keep as `mailto:` link | — |

**Corrupt links** (e.g. the observed `olduser/olduser/…Archival%20Photos/…pdf%22` — doubled segment, missing
`file:///Users/` prefix, stray `%22`): a repair pass strips the trailing `%22`, de-dupes the doubled
segment, and re-anchors on `Archival%20Photos`, then routes through the archival rule. Anything the repair
can't confidently fix is flagged, never guessed.

---

## 5. Transform details (DTI-2)

- **Note vs extract:** by the excerpt tag(s) confirmed in DTI-0. Assert every record classifies as exactly
  one; report any record with neither/both.
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

---

## 6. Replicants vs near-duplicates (get this exactly right)

- **Replicant** — same underlying record filed in ≥2 groups. **All instances share one `uuid`**;
  `parents of <record>` lists every group. → **De-dupe by `uuid` to a single `Item`; add one `Membership`
  per real parent group** (excluding `/Tags`). This reproduces the DT filing exactly, as memberships not
  copies. `number of replicants > 0` is the gate.
- **Near-duplicate** — independent records, **different `uuid`s**, near-identical text (owner's deliberate
  space/nonsense-char trick to carry multiple timeline dates). → **consolidate into one `Item`** whose
  primary date is one occurrence's alias and whose `additional_dates` collect the others' alias dates.
  Merge policy is **conservative by default**: only auto-merge when the two bodies are byte-identical after
  a defined normalization (collapse whitespace runs, strip trailing non-alphanumeric noise, NFC-normalize);
  anything below exact-normalized-match is **flagged for owner review, never auto-merged**. Merges are
  logged with both source uuids + all dates so every consolidation is auditable and reversible.

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

Every "flag" above lands in a single report; the run **stops for owner review on any non-zero flag class**
rather than importing best-effort.

---

## 8. Owner prerequisites (must be true before DTI-4)

1. **Archive Reader root over the archival corpus.** Durable-link provenance requires a Reader root (with a
   `RootMarker` GUID) over `~/Desktop/Google Drive/Archival Photos/`. Confirm one exists (or create it); the
   materializer needs its GUID + the corpus's on-disk location to compute relative paths.
2. **A copy of the `.dtBase2`** to extract from, and a *Database Archive* ZIP backup of the original.
3. **Fresh Archive Notes store root** for output (not the live store).
4. Decisions in §9 resolved (or explicitly deferred to DTI-0 discovery).

---

## 9. Open decisions for the owner (defaults proposed)

1. **Zotero fidelity** — resolve `zotero://select` to full `ZoteroRef` citations (needs the local Zotero
   DB / Better BibTeX), or keep the select link + item key only? *Default: keep select link + enrich to a
   citation when the Zotero DB is available; never block on it.*
2. **Near-duplicate merge aggressiveness** — confirm the conservative exact-normalized-match-only policy
   (§6), everything else flagged. *Default: yes, conservative.*
3. **Non-archival `file://`** (Zotero PDFs, misc Desktop/Volume PDFs) — enrich Zotero ones as attachments;
   flag the rest for manual disposition? *Default: yes.*
4. **Minor schemes** — `DEVONwiki`→note-link-or-flag, `applewebdata`→drop+log, `mailto`→keep. *Default as
   stated.*
5. **Adoption model** — build a fresh store the owner swaps in wholesale (vs merge into an existing store).
   *Default: fresh store, wholesale adoption after the §7 gate.*
6. **One-time vs repeatable** — assume a **one-time** migration (idempotent + re-runnable, but not an ongoing
   sync). *Confirm.*

DTI-0 discoveries that are *findings*, not decisions: exact excerpt tag string(s); the `Alias` date
grammar; the month-prefix title format; near-duplicate prevalence; replicant counts.

---

## 10. Phases & sequencing

Each phase is bounded, reviewed (Tier-2), and leaves an inspectable artifact. Shared-`ArchiveCore`/`Item`
changes (DTI-3) must build **and test all three apps** (memory: shared-core changes rebuild Reader +
Processor + Notes), not just Notes.

| Phase | Deliverable | Effort | Depends |
|---|---|---:|---|
| **DTI-0 — Spike & ground truth** | JXA extraction spike on a **copy**, run over a 300–500 record sample; corpus-profile report answering §9 findings (excerpt tag, alias grammar, month-prefix, replicant/near-dup prevalence). De-risks everything. | M | copy of DB |
| **DTI-1 — Full extraction** | Complete JXA dump → frozen JSON manifest (all fields incl. `parents`) + content sidecars (HTML w/ hrefs, rtfd media) + count cross-check vs Metadata Overview TSV. | L | DTI-0 |
| **DTI-2 — Transform library** | Pure, unit-tested transform: classify, dates, link contract (§4), replicant/near-dup (§6), blocks/assets. Fixture corpus + golden tests. Emits the import model + a dry-run report. | L | DTI-1 |
| **DTI-3 — Archive Notes model changes** | Multi-date (`additional_dates` + `DateValue`, codec, **per-date index rows**, UI) and Related-notes section. Tier-2 shared-core; build+test all apps. | L | (parallel w/ DTI-2) |
| **DTI-4 — Materializer** | Write a fresh store: `items/<uuid>/*.md` + `assets/` + `organization.json` (VFolders + memberships) directly, then rebuild index. Idempotent, deterministic, resumable. | M | DTI-2, DTI-3, §8 |
| **DTI-5 — Verify & reconcile** | Run the §7 gate; produce the report; owner audits a stratified sample; adopt. | M | DTI-4 |

Tooling (extractor/transformer/materializer/verifier) lives under a dedicated dir (e.g.
`ArchiveNotes/tools/devonthink-import/`) so it doesn't bloat the app; it's deletable after the one-time run,
but keep it in git for reproducibility until adoption is final.

---

## 11. Risks

- **Silent data loss / wrong mapping** (the owner's #1 fear) → the frozen-manifest + pure-transform +
  reconciliation-gate architecture; stop-on-flag; conservative near-dup merges; nothing best-effort.
- **Replicant/near-dup confusion** → strict `uuid` discriminator (§6); highest-severity review focus.
- **Alias/date misparse** → tabulated grammar with flag-on-unknown; no guessed dates.
- **Archival links unresolvable** (stale paths, Reader root missing) → normalization table + filesystem
  probe in the gate; §8 prerequisite.
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
