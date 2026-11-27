# Personal Repository Migration Kit — Execution Plan (`W49.personal-repository-migration-kit`)

> **Status:** Design & execution plan for 2.0 (`W50.v2-release`, Owner call 31). Planned in Mode A under owner
> authorization (2026-11-27, `ops/autonomous/gemini-orchestrator.md`). Implementation awaits `W50.v2-release`
> and owner sign-off on the open choices in §8.

## 1. Goal & relationship to `SPEC/adoption.md`

`W49.corpus-adoption-tool` (`SPEC/adoption.md`) handles one specific legacy repository: Finder tags parsed by
`DocumentTags`, Red/Purple Finder colour labels, and a mirrored/stem `Archival Photos JPEGS` tree. Other
historians, archivists, and personal researchers bring very different existing archives:

- nested folder hierarchies encoding repository, collection, box, folder, and date (`Archive/Box 12/1964-03_Memo.pdf`);
- spreadsheets or databases (CSV, TSV, XLSX, Airtable, FileMaker, Zotero CSV/BibTeX, Tropy JSON-LD, Omeka)
  joined to scans by filename, accession number, or folder;
- raw image folders (one folder per document, or numbered JPEGs/TIFFs with no PDF wrapper yet);
- Finder tags, Lightroom/Bridge XMP sidecars, IPTC/EXIF keywords, or Markdown/YAML note sidecars.

Writing bespoke importers for every personal convention does not scale. Instead, the **Personal Repository
Migration Kit** separates **format discovery** from **execution**:

1. A **deterministic, offline, read-only scanner** inventories the user's repository and summarizes its
   structure, file formats, metadata sources, and join patterns.
2. An **optional, user-gated LLM step** inspects only an explicitly disclosed, redactable preview of that
   inventory and proposes a **declarative, deterministic mapping specification (`migration-spec.json`)**.
3. The user reviews both the proposed mapping rules and a full dry-run preview of resulting catalogue records,
   refining rules or resolving flagged exceptions before anything is copied.
4. A **purely deterministic, offline, resumable importer** executes the approved `migration-spec.json` into a
   **separate derived Archive Suite copy**, reusing the exact catalogue filing, preservation, ledger, and
   verification boundaries defined in [`SPEC/catalogue.md`](../SPEC/catalogue.md) and
   [`SPEC/adoption.md`](../SPEC/adoption.md).

**Core design rule:** the language model proposes *declarative rules* for human review — it never mutates
files, never touches the source tree, and never writes unreviewed per-file facts directly into an archive.

---

## 2. Hard safety and privacy invariants

Every invariant from owner call 31, `SPEC/adoption.md`, and the Reader Core Directive binds the kit:

1. **Source files stay strictly read-only and intact.** Every stage opens source trees read-only, never writes
   or strips xattrs/tags on the source, refuses symbolic links escaping the root, never triggers cloud-provider
   placeholder downloads, and checks source SHA-256 digests and metadata again before and after import.
2. **Import into a separate derived copy only.** The destination directory must be new or empty. Source,
   optional originals, destination, and state directories must be pairwise disjoint, checked by `(dev, ino)`
   as well as canonical path (matching `SPEC/adoption.md`). Discarding a bad migration is always a safe
   deletion of the derived copy and state folder.
3. **Explicit pre-flight data disclosure before any language model runs.** Before any local or cloud model
   receives a single byte, the kit generates a human-readable **Disclosure Preview** (`llm-disclosure-preview.md`)
   plus the exact byte-for-byte payload (`llm-payload.json`) and its SHA-256 digest:
   - Names the exact route (on-Mac local model at `$0` vs a cloud provider on the user's key), exact token count,
     and hard upper-bound dollar cost (using `SPEC/adoption.md`'s cost-cap contract: refuse unlisted prices and
     require an explicit `--max-usd` cap at least equal to the worst-case estimate).
   - Shows the **exact disclosure tier** selected by the user (defaulting to the narrowest tier):
     - **Tier 0 (Structure only — default):** file extension counts, directory-depth & folder-name shape
       histograms, filename token templates (with digits/names generalized, e.g. `YYYY-MM-DD_<TEXT>_<NNN>.pdf`),
       sidecar column headers, distinct controlled-vocabulary values above a frequency floor, and zero raw
       paths, zero images, zero document text.
     - **Tier 1 (Structure + sampled metadata rows — opt-in):** Tier 0 plus up to `N` (default 20) user-selected
       sample relative paths and sidecar metadata rows, after applying any user-supplied redaction regexes
       (names, restricted collection codes, private notes).
     - **Tier 2 (Structure + sampled text excerpts — opt-in):** Tier 1 plus short plain-text excerpts (up to
       500 chars each from up to 10 user-selected files) when unstructured text or notes must be inspected to
       infer a mapping. **Raw archival page images are never sent by the mapping proposer.**
   - Requires explicit confirmation pinned to the exact approved payload digest
     (`--confirm-disclosure <sha256>` in CLI, or an inspected scrollable preview + confirm button in GUI) so no
     silent prompt expansion or unreviewed sample can ever leave the machine.
   - Offers a **zero-LLM mode** (`--offline-template`) that emits a commented starter `migration-spec.json`
     purely from deterministic heuristics for repositories with strict no-AI agreements.
4. **Provenance on every imported field.** Every field written to `*.archivesuite.json` carries
   `origin: "imported"` (never `"user"`), with `evidence` citing the rule ID in `migration-spec.json`, the
   spec digest, and the verbatim source value (path segment, CSV column+cell, XMP tag, or Finder tag).
5. **No silent coercion or overwrites.** Unmapped columns, unrecognized date strings, duplicate join keys, and
   ambiguous pairings never guess silently: they surface as review reason codes and stay unimported (or keep
   verbatim text in `subjects` only when explicitly configured) until the user decides.

---

## 3. Six-stage workflow

Each stage is an independent, resumable run storing durable artifacts in a dedicated `state/` directory under
a single-writer lock (mirroring `SPEC/adoption.md`):

| Stage | Command / Mode | Network / Cost | Inputs | Outputs in `state/` |
|---|---|---|---|---|
| 1. Inventory | `inventory` | Offline · `$0` | Source tree(s), optional sidecars/originals | `inventory.json`, `inventory-report.md` |
| 2. Disclose & Propose | `prepare-disclosure` → `propose-mapping` | Offline preview; opt-in local (`$0`) or cloud LLM (capped) | `inventory.json`, disclosure tier, redactions | `llm-disclosure-preview.md`, `llm-payload.json`, `migration-spec.json`, `mapping-rationale.md` |
| 3. Dry-Run & Review | `dry-run` / `review` / `decide` | Offline · `$0` | `inventory.json`, `migration-spec.json` | `migration-manifest.json`, `review-sheet.html`, `dry-run-report.md` |
| 4. Import | `import` | Offline · `$0` | `migration-manifest.json`, read-only source | Derived archive copy (`*.pdf`, `*.archivesuite.json`, `Preservation/`), `migration-ledger.json` |
| 5. Verify | `verify` | Offline · `$0` | Derived archive, `migration-manifest.json`, source | `verify-report.md` (exit nonzero on any mismatch) |
| 6. Containers & Receipt | `containers` | Offline · `$0` | Verified derived archive, `migration-spec.json` | `.archivesuite/containers.json` (in derived copy), `migration-receipt.md` |

### Stage 1 — Local Inventory (`inventory`)

Read-only scan producing `inventory.json` and human-readable `inventory-report.md`:

- **File census:** counts and total bytes by format (`pdf`, `jpg`/`jpeg`, `png`, `tif`/`tiff`, `heic`, `md`,
  `txt`, `csv`/`tsv`, `xlsx`, `json`, `xml`, `xmp`, other), encrypted/unreadable PDFs, cloud placeholders
  (recorded as `source-offline`, never hydrated), symlinks/hardlinks (refused cleanly).
- **Structural signature:** directory tree depth, folder-level naming patterns (detecting common `Archive /
  Collection / Box / Folder` or `YYYY / MM` layouts), filename tokenization and delimiter patterns.
- **Metadata source discovery:**
  - macOS Finder tags & colour labels (read-only xattr inspection);
  - embedded PDF Info / XMP metadata (`Title`, `Author`, `Subject`, `Keywords`, `CreationDate`);
  - image EXIF / IPTC / XMP sidecars (`*.xmp`);
  - tabular sidecars (`*.csv`, `*.tsv`, `*.json`, Zotero/Tropy exports): column headers, fill rates, candidate
    join columns (exact path, filename, stem, accession ID), and top distinct values for low-cardinality columns.
- **Image-only & pairing detection:** flags image folders without PDFs (candidate multi-page document groups)
  and candidate original-image trees matching PDF stems or mirrored relative paths.

### Stage 2 — Disclosure Preview & Mapping Proposal (`prepare-disclosure` → `propose-mapping`)

1. `prepare-disclosure --tier 0|1|2 [--redact <pattern> ...] [--samples N]` builds:
   - `llm-payload.json`: the exact JSON sent to the model;
   - `llm-disclosure-preview.md`: plain-language breakdown of every key in `llm-payload.json`, count of
     redacted spans, exact model route, token estimate, worst-case dollar cost, and the payload SHA-256.
2. The user inspects `llm-disclosure-preview.md` (and `llm-payload.json` if desired).
3. `propose-mapping --confirm-disclosure <sha256> --route <local|provider:model> --max-usd <cap>` verifies
   the SHA-256 matches `llm-payload.json` byte-for-byte, enforces the cost cap, and requests structured JSON
   conforming to `migration-spec.schema.json`.
4. Every proposed rule in `migration-spec.json` carries a plain-language `rationale`, `confidence`
   (`high`/`medium`/`low`), and `questions` for the user (e.g., *"Folder level 2 looks like Box numbers in 84%
   of folders and topic names in 16% — confirm which folders are Boxes vs Topics"*).
5. `propose-mapping --offline-template` skips the model entirely and generates a starter `migration-spec.json`
   using deterministic heuristics (existing `DocumentTags` grammar + obvious ISO-date filename patterns + direct
   sidecar column-name matches).

### Stage 3 — Dry-Run Simulation & Interactive Review (`dry-run` / `review`)

Runs `migration-spec.json` deterministically over every record in `inventory.json` (zero network, zero source
writes) and produces:

- `migration-manifest.json`: every planned output item, target relative path in the derived copy, proposed
  catalogue fields (`SPEC/catalogue.md` §"What each record owns"), provenance rule IDs, preservation pairing,
  container assignment, and any review reason codes.
- `dry-run-report.md` + optional self-contained `review-sheet.html` (following root `CLAUDE.md` sheet rules:
  notes per item, every unasked incoming field listed explicitly, upright page thumbnails for sampled visual
  checks):
  - Rule coverage table (how many files each mapping rule matched, with 3 representative before→after examples
    per rule);
  - Unmapped-data audit (every sidecar column, Finder tag, or XMP key that no rule consumed, so nothing is
    silently dropped without the user seeing it);
  - Reason-code buckets matching and extending `SPEC/adoption.md` (`date-ambiguous`, `date-incomplete`,
    `join-missing`, `join-ambiguous`, `target-path-collision`, `type-conflict`, `original-missing`,
    `original-ambiguous`, `original-shared`, `format-needs-pdf-wrap`, `source-offline`, `pdf-unreadable`,
    `already-catalogued`).
- Users iterate freely: edit `migration-spec.json` (or ask the LLM for a targeted rule revision via a fresh
  disclosed payload) and re-run `dry-run`, or bulk-decide reason groups (`decide --reason <code...> --action
  accept|skip`) just like `adopt-archive.sh`.

### Stage 4 — Journaled Import into Separate Copy (`import`)

Executes only `decision == "accept"` entries from `migration-manifest.json` into a new/empty destination root:

- **PDF inputs:** reuses `SearchableArchival.catalogueCopy` (adding only the Suite XMP identity, preserving
  original PDF bytes/pages/annotations/OCR) and writes the adjacent `*.archivesuite.json` companion via
  `CataloguePairFiler`'s journal and lock, with matched original images copied verbatim into
  `Preservation/<document UUID>/<file UUID>/`.
- **Image-only inputs (non-PDF source folders):** two explicit, spec-declared modes:
  - `wrap-image-pdf`: wraps each grouped image set into a lossless reading PDF with Suite XMP identity +
    adjacent companion + exact source image bytes in `Preservation/` (flagged `ocrPending` / un-OCRed so
    Processor can OCR later without re-scanning);
  - `stage-for-processor`: copies source images into a separate Processor intake staging folder with a
    pre-populated metadata sidecar so Processor's normal OCR + filing pipeline builds the final PDFs.
- **Directory mapping:** preserves source relative paths by default, or applies deterministic folder-template
  renaming declared in `migration-spec.json` (rejecting collisions, `..` traversal, or reserved names like
  `.archivesuite` and `Preservation` during Stage 3 dry-run).
- **Interruption safety:** reuses `SPEC/adoption.md`'s ledger (`migration-ledger.json`) freezing operation ID,
  source SHA-256, companion bytes, destination proof, and preservation map before filing. Interrupted runs
  resume cleanly without duplicate filing; any source drift since Stage 1 aborts before writing.

### Stage 5 — Independent Verification (`verify`)

Runs automatically at the end of `import` and on demand:

- Re-reads the entire derived archive through `CatalogueReader` and validates every companion against
  `SPEC/catalogue.schema.json`;
- Confirms every accepted manifest entry landed at its expected relative path with matching page count and
  every mapped field equal to the approved proposal;
- Confirms every preserved original matches its source SHA-256 byte-for-byte;
- Confirms every source file's SHA-256 and xattrs remain byte-identical to Stage 1's inventory.

### Stage 6 — Container Records & Migration Receipt (`containers`)

- Emits `.archivesuite/containers.json` inside the derived archive from the approved folder-to-container rules
  in `migration-spec.json` (reusing `SPEC/containers.md` schema and `Adoption`'s container-run builder).
- Writes `migration-receipt.md` (with counts, rule summary, `migration-spec.json` SHA-256, disclosure log
  hashes, skipped items, and verification verdict) into `state/`.

---

## 4. Declarative `migration-spec.json` contract

Keeping the mapping format small, human-editable, and deterministic ensures that LLM proposals and hand edits
share one auditable artifact:

```json
{
  "schemaVersion": 1,
  "sourceProfile": {
    "roots": ["<relative alias: primary>", "<relative alias: originals>"],
    "sidecars": [{ "id": "meta-csv", "format": "csv", "path": "metadata.csv", "encoding": "utf-8" }]
  },
  "pairing": {
    "sidecarJoins": [
      { "sidecar": "meta-csv", "column": "filename", "matchBy": "stem", "onMultiple": "review" }
    ],
    "originals": [
      { "tier": "mirrored", "originalsRoot": "originals" },
      { "tier": "stem", "originalsRoot": "originals" }
    ],
    "imageGrouping": { "mode": "folder-as-document", "sortBy": "natural-filename", "importMode": "wrap-image-pdf" }
  },
  "containers": {
    "folderRules": [
      { "id": "c-repo", "depth": 1, "field": "repository" },
      { "id": "c-box", "depth": 2, "regex": "^Box\\s+(?<box>.+)$", "field": "box" },
      { "id": "c-folder", "depth": 3, "field": "folder" }
    ]
  },
  "fieldRules": [
    { "id": "f-date", "from": "sidecar:meta-csv.date", "parser": "iso-or-decade", "to": "documentDate" },
    { "id": "f-sender", "from": "sidecar:meta-csv.from", "split": ";", "to": "senders" },
    { "id": "f-subj", "from": "finder-tags", "exclude": ["Read", "Unread"], "to": "subjects" },
    { "id": "f-read", "from": "finder-tags", "map": { "Read": "read", "Unread": "unread" }, "to": "readState" }
  ],
  "folderLayout": { "mode": "preserve-relative-paths" },
  "unmappedPolicy": { "sidecarColumns": "report-and-skip", "finderTags": "subjects" }
}
```

**Built-in deterministic parsers (no arbitrary code execution):** `migration-spec.json` may reference only an
allow-listed set of built-in parsers (`literal`, `regex-named-groups`, `iso-or-decade`, `year-only`,
`month-year`, `split-list`, `value-map`, `document-tags-grammar`, `finder-colour-map`, `xmp-dc-field`). The
LLM can **never** emit shell commands, Python/Swift snippets, or executable scripts.

---

## 5. Architecture & reuse with Archive Suite

| Component | Location (proposed for 2.0) | Reuses from 1.0 |
|---|---|---|
| Shared spec schema & docs | `SPEC/migration-kit.md`, `SPEC/migration-spec.schema.json` | `SPEC/catalogue.schema.json`, `SPEC/adoption.md`, `SPEC/containers.md` |
| Inventory + spec evaluator + dry-run engine | `packages/ArchiveCore/Sources/ArchiveCore/Migration/` (or `ArchiveProcessor/.../Migration/`) | `DocumentTags`, `ArchiveDate`, `CatalogueRecord`, `CatalogueReader`, `CataloguePairFiler`, `JPEGPartnerIndex` |
| Disclosure builder & LLM proposer | `ArchiveProcessor/.../Migration/DisclosureBuilder.swift` + `MappingProposer.swift` | Processor's existing provider client, local MLX route, cost estimator & cap guard from `Adoption/` |
| Headless CLI entry point | `ArchiveProcessor/scripts/migrate-archive.sh` | Same step-by-step CLI pattern as `ArchiveProcessor/scripts/adopt-archive.sh` |
| Optional review sheet / GUI wizard (2.0+) | Standalone HTML review sheet first; Processor sheet later | Root `CLAUDE.md` owner-sheet conventions |

**Why Swift + `ArchiveCore` for stages 1, 3, 4, 5, 6:** sharing `CataloguePairFiler`, `CatalogueReader`,
`SearchableArchival.catalogueCopy`, and `DocumentTags` directly guarantees 100% wire compatibility with
`SPEC/catalogue.md` and avoids duplicating PDF XMP identity writing or companion validation in a second
language.

---

## 6. Phased 2.0 implementation plan

Each phase is one bounded, testable work item once `W50.v2-release` opens:

1. **Phase 1 — Spec & deterministic engine (`M` · Tier-2):** Define `SPEC/migration-spec.schema.json`,
   implement Stage 1 (`inventory`: filesystem, Finder tags, PDF XMP, EXIF/IPTC/XMP sidecars, CSV/TSV/JSON
   sidecars), the allow-listed rule evaluator, Stage 3 (`dry-run` + `decide` + HTML/MD review sheet), and
   self-tests on 4 synthetic fixture archives (nested-folder PDFs, CSV-joined scans, image-only document
   folders, and Finder-tag/XMP hybrid).
2. **Phase 2 — Disclosure gate & LLM mapping proposer (`S-M`):** Implement `prepare-disclosure` (Tiers 0/1/2,
   redaction patterns, token/cost estimation, payload SHA-256 pinning) and `propose-mapping` (supporting
   on-Mac local model at `$0`, user cloud API key with hard cap, and `--offline-template`), plus unit tests
   proving unconfirmed or tampered payload digests and over-cap estimates are always refused with zero network
   calls.
3. **Phase 3 — Journaled importer, verification & containers (`M` · Tier-2):** Wire Stage 4 (`import`) onto
   `CataloguePairFiler` + `SearchableArchival.catalogueCopy` + `Preservation/` (including `wrap-image-pdf`
   and `stage-for-processor` for image-only folders), Stage 5 (`verify`), and Stage 6 (`containers`), with
   crash-recovery and source-immutability tests matching `scripts/test-adoption.sh`.
4. **Phase 4 — Real-world pilot & documentation (`S`):** Run the kit end-to-end on synthetic exports modeled
   after Zotero, Tropy, and spreadsheet-backed photo archives, document user guide + troubleshooting, and
   optionally add a thin Processor UI sheet over the CLI engine.

---

## 7. Non-goals (keep scope clean)

- **No in-place migration:** The kit never modifies source files or converts a repository in place.
- **No direct proprietary binary database parsing in v1 of the kit:** Tools like DEVONthink, FileMaker, or
  Lightroom have built-in CSV/JSON/XML/XMP exports; the kit ingests standard open interchange files (CSV, TSV,
  JSON, XML, XMP, Markdown/YAML) rather than reverse-engineering closed databases. (DEVONthink import for
  Notes remains its own separate on-hold plan: `execution-plans/devonthink-import.md`.)
- **No executable code in `migration-spec.json`:** Only declarative, allow-listed parsers run on user data.
- **No silent OCR during migration:** Image-only archives either wrap into un-OCRed PDFs with preserved
  originals or stage into Processor's normal OCR workflow so OCR cost and model selection remain explicit.

---

## 8. Open choices for the owner (when `W50.v2-release` opens)

No decision is needed now; raise these before starting Phase 1 implementation:

1. **CLI-first vs GUI-first:** Ship the headless CLI + self-contained HTML review sheet first (mirroring
   `adopt-archive.sh`, fast to test and scriptable by archivists) before building a Processor wizard UI, or
   build the Processor wizard UI in parallel? *Recommendation:* CLI + HTML review sheet first, then wrap the
   same engine in a Processor sheet once tested on real third-party repositories.
2. **Default disclosure tier:** Default `prepare-disclosure` to **Tier 0 (structure + controlled vocabularies
   only, zero sample paths/rows)** and require an explicit opt-in flag for Tier 1 sample rows, or default to
   Tier 1 with 10 anonymized sample paths? *Recommendation:* Tier 0 default (strictest privacy floor), with
   clear one-line prompt telling the user how to enable Tier 1 samples if Tier 0 lacks enough signal.
3. **Image-only repositories:** Support both `wrap-image-pdf` (instant browsable derived copy, OCR later via
   Improve OCR) and `stage-for-processor` (feed straight into Processor OCR), or start with `wrap-image-pdf`
   alone? *Recommendation:* start with `wrap-image-pdf` (keeps the derived archive immediately valid under
   `SPEC/catalogue.md` and usable in Reader), adding `stage-for-processor` only if needed.
