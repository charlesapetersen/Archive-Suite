# Archive Notes — W2: Storage model, front-matter I/O, virtual folders + replication, SQLite FTS5 index
> Status: PROPOSED · part of Archive Notes (see 00-overview.md) · Wave 2

> ⚠️ **Canonical shared types & cross-wave APIs are defined in `00-overview.md` §16 (Interface Contract).** Where a sketch in this file differs — store type/name (`actor NoteStore` + `@MainActor NotesModel`/`OrganizationStore`), `DurableLink`/`RootMarker`, the single `NotesFilter` type, template-assignments-only, the index `items` projection, the `archivenotes://open?id=` grammar — **the overview is authoritative.**


## Goal
Build the three persistence layers Archive Notes stands on, all inside the `ArchiveNotes/` app target created in W1: (a) **NoteStore** — the durable, tool-agnostic UUID-folder store on disk (`items/<uuid>/<Title>.md` + `assets/`) with atomic create/rename/move/delete, a security-scoped bookmark to the user-chosen root, and a dropped `.archive-suite-root.json` RootMarker; (b) a **hand-rolled strict front-matter (de)serializer** for the locked schema (00-overview §5) that preserves unknown keys verbatim, plus the block-body parser for the self-describing HTML-comment headers (§6) and the `Item` domain model; (c) the **NotesTagProjector** — a narrow, independently-audited Finder-tag mirror (subjects + `ArchiveSuite` only) reimplementing every `TagWriter` invariant on Notes' own files; (d) the **virtual folder + replication graph** (DB tables + a mutable Swift tree + `organization.json` atomic export/import); and (e) **NotesIndex** — a fork of Reader's `ContentIndex`/`ContentIndexer` with prose-tuned FTS5 columns/weights, the organizational tables, incremental build, and as-you-type search. Every write is atomic and scoped to the app's own store; the real corpus is never touched.

## Dependencies
- **W1 must land first** (per 00-overview §13 wave table): W2 requires the `ArchiveNotes/` app target (bundle `com.archivenotes.app`, entitlements: `com.apple.security.files.user-selected.read-write` + `com.apple.security.files.bookmarks.app-scope`), the `ArchiveCore` package seeded from Reader (`DocumentTags`/`sortDate`, `RootMarker`, tag-vocabulary constants, `ftsMatchExpression`-style helpers), and the empty 3-pane shell. This plan consumes `ArchiveCore.DocumentTags.sortDate` (00-overview §7) and the `ArchiveCore.RootMarker` type (§3.8/§8.1) — if W1 did not land those exact symbols, S1 below stubs them locally and files a follow-up, but the intended path is W1-provides.
- No other wave is required. W2 is a hard dependency for **W3** (editor persistence), **W4** (source blocks, `archivenotes://` resolution reads the store), **W5** (Zotero refs live in front-matter), **W6** (viewers/replication UI + delete-last-instance guard consume this model), **W7** (extracts reuse `Item`/NoteStore). So W2 is the second-most load-bearing wave; correctness here dominates the app's data safety.

## Design

### 0. Placement & module boundaries
All new files live under `ArchiveNotes/macOS/Sources/ArchiveNotes/` in these groups (mirrors Reader's `Core/` + `Search/` split so the UI-free domain stays package-ready):
```
Store/          NoteStore, FrontMatter, Item model, BlockParser, RootMarkerStore, OrganizationFile
Core/           NotesTagProjector, NotesTagVocabulary
Index/          NotesIndex (actor), NotesIndexer (@MainActor), FolderGraph model
```
`Store/` + `Core/` + `Index/` domain types are UI-free (`import Foundation` only, plus `SQLite3` in `NotesIndex`), so they can move into `ArchiveCore` at the convergence wave. `NotesIndexer` is `@MainActor` + `ObservableObject` (it drives UI progress), exactly like `ContentIndexer`.

### 1. NoteStore — the durable UUID-folder store

**On-disk layout** (00-overview §4), all under the security-scoped root `<NotesStore>/`:
```
.archive-suite-root.json    RootMarker {guid,name,kind:"notes"}
items/<uuid>/<Title>.md     one folder per Item; folder name == id.uuidString.lowercased()
items/<uuid>/assets/…       thumbnails + pasted images
Templates/…                 (W6 territory; NoteStore just exposes the URL)
organization.json           folder/membership/template graph mirror (see §4)
```

**NEW file `Store/RootMarkerStore.swift`** — the Notes analogue of Reader's `RootFolderStore.swift` (reuse its bookmark discipline verbatim; see Reuse). Responsibilities:
- `@MainActor final class RootFolderStore: ObservableObject` holding `@Published private(set) var root: URL?`, adapted from `RootFolderStore.swift:8-68`. Key `"notesStoreRootBookmark"` (distinct from Reader's `"archiveRootBookmark"` — separate app, separate defaults domain anyway, but name it clearly).
- **First-run default**: if no bookmark exists, offer the app-default `FileManager.default.url(for: .applicationSupportDirectory…)/ArchiveNotes/Store` (create it) OR let the user pick. Unlike Reader (which *requires* a corpus pick), Notes can bootstrap its own store, so `setRoot(_:)` is also called with an app-created default folder. When the user later picks a custom root, `setRoot` re-bookmarks (same code path).
- On `setRoot`, after `startAccessingSecurityScopedResource()`, call `RootMarkerStore.ensureMarker(at: root, kind: .notes)` (below).
- Preserve the two `RootFolderStore` fixes (do **not** regress): resolve MUST `startAccessingSecurityScopedResource()` and leave `root == nil` on failure (`RootFolderStore.swift:49-52`); refresh a stale bookmark **while access is still held** (`RootFolderStore.swift:56-59`).

**NEW `Store/RootMarker.swift`** (or from ArchiveCore if W1 shipped it):
```swift
struct RootMarker: Codable, Equatable, Sendable {
    let guid: String            // UUID string, lowercased
    let name: String            // human label, e.g. folder name at creation
    let createdAt: Date
    enum Kind: String, Codable, Sendable { case reader, notes }
    let kind: Kind
}
enum RootMarkerStore {
    static let fileName = ".archive-suite-root.json"
    /// Idempotent: NEVER overwrites an existing guid (00-overview §8.1). Returns the effective marker.
    static func ensureMarker(at root: URL, kind: RootMarker.Kind) throws -> RootMarker { … }
}
```
Algorithm for `ensureMarker`: coordinate a read of `<root>/.archive-suite-root.json`; if it decodes, return it unchanged (never rewrite — this preserves identity across launches and a moved install, §8.3). If absent/undecodable-as-missing, write a fresh `{guid: UUID().uuidString.lowercased(), name: root.lastPathComponent, createdAt: .now, kind}` **atomically** (`Data.write(to:options:.atomic)`). Guard: if the file exists but is *corrupt* (present, non-empty, fails decode), do **not** overwrite — throw `NoteStoreError.corruptRootMarker` and surface a "store marker unreadable" state, because silently minting a new GUID would break every durable link into this store (§8.3 anti-silent-failure ethos).

**NEW `Store/NoteStore.swift`** — `actor NoteStore` (confine all filesystem mutation to one isolation domain; makes concurrent saves from the editor safe under Swift 6). It holds the resolved root `URL` (passed in; access started by `RootFolderStore`). API:
```swift
actor NoteStore {
    enum StoreError: Error, Sendable {
        case rootUnavailable, corruptRootMarker, titleCollision(URL), writeFailed(String),
             notFound(UUID), readFailed(String), assetWriteFailed(String)
    }
    init(root: URL)

    // Directory URLs (pure, no I/O):
    func itemDir(_ id: UUID) -> URL          // <root>/items/<uuid>/
    func assetsDir(_ id: UUID) -> URL        // <root>/items/<uuid>/assets/

    // CRUD:
    func create(_ item: Item) throws -> ItemRef              // writes <uuid>/<Title>.md atomically
    func load(_ id: UUID) throws -> Item                     // finds the single .md, parses
    func save(_ item: Item) throws -> ItemRef                // retitle → rename file; body atomic write
    func delete(_ id: UUID) throws                           // moves item dir to Trash (recoverable)
    func allItemIDs() -> [UUID]                              // scan items/ dir
    func mdURL(for id: UUID) throws -> URL                   // the single .md inside the item dir

    // Assets:
    func importAsset(_ data: Data, preferredName: String, into id: UUID) throws -> String // returns rel path "assets/…"
}
struct ItemRef: Sendable { let id: UUID; let url: URL; let mtime: Double }
```

**Create** (`create`):
1. `let dir = itemDir(item.id)`; `createDirectory(withIntermediateDirectories: true)` for `dir` and `dir/assets`.
2. Compute filename: `sanitizedTitle(item.title) + ".md"` (see filename rules). If a file with that name already exists in `dir` (shouldn't on create), disambiguate.
3. Serialize: `let text = FrontMatterCodec.encode(item)` (front-matter + body, §2).
4. **Atomic write**: `try Data(text.utf8).write(to: fileURL, options: [.atomic])`. `.atomic` writes to a temp sibling then renames — the standard durability primitive; do **not** use `.forReplacing` coordination semantics (not needed; there is no external tag-metadata race on a brand-new file).
5. Return `ItemRef` with the file's post-write `contentModificationDate` (for the index mtime skip-map).

**Rename-on-retitle** (`save`): the title is the filename (D1). When `item.title` changed vs the on-disk filename:
- New name = `sanitizedTitle(newTitle).md`. If it collides with a *different* existing file in the same item dir (only possible via manual meddling — one item dir holds one `.md`), append ` (2)`, ` (3)`… Because each item has its **own** UUID dir, cross-item title collisions are impossible by construction — this is the whole point of D1 ("title=filename with no collisions"). So collision handling is only intra-dir defensive.
- Perform the rename with `FileManager.moveItem(at: oldURL, to: newURL)` **before** writing new content, then atomic-write the new body to `newURL`. If the title is unchanged, skip the move. Never delete the old file except via the rename.
- **File-safety note**: `moveItem` is a mutating API, but it operates **only** inside Notes' own `items/<uuid>/` dir, never the corpus. This is acceptable per the Core Directive scoping (00-overview §9/§12: "Notes writes only its own store"). Guard with a precondition that `oldURL` and `newURL` are both under `root/items/<id>/` (component-boundary check, mirroring `ContentIndexer` prune scoping `ContentIndexer.swift:222-225`) so a bug can never move a file outside the item dir.

**Delete** (`delete`): move the whole `items/<uuid>/` dir to the **Trash** via `FileManager.default.trashItem(at:resultingItemURL:)`, never `removeItem` — mirrors Processor's "Trash, don't rm" recovery directive (ArchiveProcessor CLAUDE.md Recovery Core Directive). This makes an errant delete recoverable. The **delete-last-membership guard** (the "sole remaining instance → this deletes the note itself" confirmation, 00-overview §3.6) lives in the FolderGraph layer (§4) and is enforced by the caller (W6 UI); `NoteStore.delete` is the low-level primitive that assumes the guard already passed. Document this contract in the doc-comment.

**Filename sanitization** (`sanitizedTitle`): map a title to a safe HFS+/APFS filename:
- Replace `/` and `:` (illegal on macOS) with `-`.
- Trim leading/trailing whitespace and dots; collapse to a non-empty fallback `"Untitled"` if empty.
- Cap length at ~200 UTF-16 units (APFS limit 255 bytes; leave headroom for `.md` + ` (2)`).
- Preserve Unicode otherwise (the corpus filenames carry em-dashes/NBSP per Reader facts; Notes titles may too). Do **not** normalize away real characters — display fidelity matters.
- The **authoritative** title is `item.title` in front-matter; the filename is a projection. On load, trust front-matter `title` over the filename, but if they diverge (manual rename in Finder), a `save` re-syncs the filename to front-matter. Note the divergence in a log line.

**Load / scan**: `allItemIDs()` lists `items/` subdirs whose name parses as a UUID (ignore strays). `mdURL(for:)` returns the first `*.md` in the item dir (there is exactly one by construction; if two exist from meddling, pick the one whose front-matter `id` matches, else the lexicographically-first, and log). `load` reads the file, `FrontMatterCodec.decode`, returns `Item`. A read failure throws `readFailed` — **never** a silent empty item (parallels the trustworthy-read guard ethos).

**Assets** (`importAsset`): write `data` to `assets/<preferredName>` (disambiguate with `-1`, `-2` on collision), atomically, return the store-relative path (`assets/foo.png`) that goes into a block header `thumb:`/image line. Used by W4 (thumbnails) and W3 (pasted images).

**Concurrency/Sendable**: `NoteStore` is an `actor`; `Item` is `Sendable` (value type of `Sendable` fields). `ItemRef` is `Sendable`. All `FileManager`/`Data.write` calls are synchronous inside actor methods (no `await` between a compute and its write, so no interleaving) — same discipline as `ContentIndex.upsertBatch` (`ContentIndex.swift:100-117`).

### 2. Front-matter (de)serializer + Item model + block parser

**Decision: hand-rolled STRICT reader/writer, NOT Yams.** Justification (per mandate + no-deps ethos, CLAUDE.md "no third-party dependencies unless explicitly justified"; Suite uses system SQLite via `import SQLite3` with no ORM):
1. The schema is **small and fully known** (00-overview §5): a fixed set of scalar keys, two list keys (`authors`, `tags`), and one nested list-of-maps (`zotero`, and later `sources`). A general YAML engine is far more surface than needed.
2. The one hard requirement — **round-trip preservation of unknown keys verbatim** — is *easier* to guarantee with a targeted parser that stashes unrecognized top-level lines than with a full YAML lib (Yams re-emits with its own formatting/quoting, reordering keys and normalizing scalars, which would churn every file and could subtly alter a value). A hand-rolled writer emits a **stable field order** and touches only keys it owns.
3. Zero dependency = simpler build, no SwiftPM addition to `project.yml`, consistent with Reader/Processor.

**Tokenizer scope (deliberately bounded — we parse the subset we emit, tolerate the rest):**
- **Document shape**: front-matter is the region between a leading `---\n` and the next `\n---\n` (or `---` at line start). Everything after is the body. If the file does not start with `---`, treat the whole file as body with an empty front-matter (graceful degradation — matches §6 "consumers must degrade"). 
- **Line model**: front-matter is parsed line-by-line into (indent, key, value) where a top-level key is `^([A-Za-z_][A-Za-z0-9_]*):`.
- **Scalars**: after `key:`, the remainder trimmed. Types recognized by target key (schema-driven, not value-guessed): `schema`/`quality` → Int; `date_uncertain`/`roundup` → Bool (`true`/`false`); `created`/`modified` → ISO-8601 `Date`; `date` → **String kept verbatim** (it may be `1968`, `1970` for a decade, `1968-03`, `1968-03-25` — the precision is carried separately in `date_precision`, so we never reformat it); `date_precision`/`kind`/`title`/`id` → String.
- **Quoting rules (writer)**: emit a scalar bare when it is safe; **double-quote** when the value is empty, begins with a YAML indicator (`` !&*?|>%@`"'#,[]{} ``, `:` `-` followed by space, leading/trailing space), or contains `: ` / ` #` / a newline. Inside quotes, escape `"` → `\"` and `\` → `\\`. Titles frequently contain `:` → they get quoted. Never emit block scalars (`|`/`>`); a title with a newline is not allowed (NoteStore strips newlines from titles).
- **Lists** `authors`, `tags`: emit **flow style** `[a, b, c]` (matches the §5 example `tags: [Silicon Valley, Intel, Corporate Culture]`). Each element quoted per the scalar rules (an element containing `,` or `[`/`]` must be quoted). Parser accepts **both** flow `[…]` and block style (`\n  - item`) on read (tolerant), always writes flow. Empty list → omit the key entirely (don't emit `tags: []`) to keep files clean; absent key ⇒ empty array on read.
- **Nested map list** `zotero` (and future `sources`): block style, list of maps:
  ```yaml
  zotero:
    - selectLink: zotero://select/library/items/ABCD1234
      itemKey: ABCD1234
      library: library
      kind: item
      citation: "Moore, Gordon E. …"
  ```
  Parser: recognize `zotero:` with an empty value, then consume subsequent lines more-indented; each `- ` starts a new map, `key: value` lines fill it. Emit with 2-space indent for the list, 4-space for map keys (as shown). Values quoted per scalar rules. This is the **one** structural nesting we support; the parser handles exactly this shape.
- **ISO dates**: `created`/`modified` use `ISO8601DateFormatter` with `[.withInternetDateTime]` (e.g. `2026-07-10T21:05:00Z`). Store/emit in UTC `Z`.

**Unknown-key preservation** (the round-trip invariant): during parse, any **top-level** key not in the known set is captured as a raw text span (its line(s), including any block continuation lines that are more-indented) into `Item.unknownFrontMatter: [(key: String, rawLines: [String])]` in first-seen order. On encode, known keys are emitted in the canonical order first, then unknown spans appended verbatim, byte-for-byte as read. This satisfies "unknown keys preserved on round-trip (never dropped)" (00-overview §5) and forward-compat for a future `schema` bump.

**NEW `Store/Item.swift`** — the domain model (Sendable value type):
```swift
struct Item: Sendable, Equatable, Identifiable {
    enum Kind: String, Sendable, Codable { case note, extract }
    enum DatePrecision: String, Sendable, Codable { case decade, year, month, day }

    var id: UUID
    var kind: Kind
    var title: String
    var authors: [String]
    var date: String?                 // verbatim; precision in datePrecision
    var datePrecision: DatePrecision?
    var dateUncertain: Bool
    var quality: Int?                  // 1...5
    var tags: [String]                 // subjects (mirrored to Finder per §9)
    var zotero: [ZoteroRef]
    var roundup: Bool
    var created: Date
    var modified: Date
    var schema: Int                    // current = 1
    // Body:
    var blocks: [Block]
    // Round-trip:
    var unknownFrontMatter: [UnknownKey]   // preserved verbatim
    var trailingBodyRaw: String?           // any body text before the first block header (freeform)

    /// Sort key reusing the SPEC formula via ArchiveCore (00-overview §7).
    var sortDate: Int? { … }               // see below
}
struct ZoteroRef: Sendable, Equatable, Codable {
    var selectLink: String; var itemKey: String; var library: String
    enum Kind: String, Sendable, Codable { case item, attachment }
    var kind: Kind; var citation: String?; var fetched: Bool?
    var unknown: [UnknownKey]              // preserve unrecognized zotero sub-keys too
}
struct UnknownKey: Sendable, Equatable { let key: String; let rawLines: [String] }
```

**`sortDate` reuse**: the item's `date`/`datePrecision` map 1:1 onto Reader's facet model (00-overview §7). Implement `Item.sortDate` by constructing an `ArchiveCore.DocumentTags`-compatible parse from `date`: split `date` into year/month/day components per `datePrecision`, then reuse the **exact** formula `year*10000 + month*100 + day` (decade → `decade*10000`). Cite `DocumentTags.sortDate` (`DocumentTags.swift:70-74`): `if let year { return year*10_000 + (month?.number ?? 0)*100 + (day ?? 0) }; if let decade { return decade*10_000 }; return nil`. Prefer calling a shared `ArchiveCore` helper `sortDate(year:month:day:decade:)` extracted from that property so the two apps cannot drift; if W1 didn't extract it, replicate the formula and add a test asserting parity with a table of known values.

**NEW `Store/FrontMatterCodec.swift`** (pure, `enum FrontMatterCodec`):
```swift
enum FrontMatterCodec {
    static func decode(_ text: String) throws -> Item      // front-matter + body → Item
    static func encode(_ item: Item) -> String             // Item → front-matter + body
    // internal: parseFrontMatter(lines) -> (known: KnownFields, unknown: [UnknownKey])
    //           parseZotero(indentedLines) -> [ZoteroRef]
}
```
Edge cases + graceful degradation:
- **No front-matter delimiters** → `Item` with defaults (`schema: 1`, `kind: note`, a *newly-minted* `id`? — NO: if there is no `id`, that is a hard error for a store item; throw `decodeFailed("missing id")`. The store never loads an item without an id. For a raw imported `.md`, W3/import path mints an id and writes it back.). Missing `kind` defaults `note`.
- **Malformed scalar** (e.g. `quality: high`) → keep the raw value in `unknownFrontMatter` for that key rather than crashing, set the typed field to nil, and log. Never lose data.
- **Duplicate key** → last wins for the typed field, but preserve the first occurrence's raw line only if it were unknown; for a known key, just take the last value (YAML semantics).
- **CRLF** line endings tolerated (split on `\r\n`/`\n`); emit `\n`.

**NEW `Store/BlockParser.swift`** — parses the body into `[Block]` per §6:
```swift
struct Block: Sendable, Equatable {
    enum Kind: String, Sendable { case freeform, readerPage="reader-page", readerDoc="reader-doc",
                                       zoteroItem="zotero-item", zoteroAttachment="zotero-attachment",
                                       notePassage="note-passage" }
    var kind: Kind
    var source: SourceAnchor?          // nil for freeform
    var markdown: String               // the block's body text (incl. the rendered ![]() image line)
    var unknownHeaderFields: [(String,String)]   // preserve unrecognized header fields verbatim (§6)
}
struct SourceAnchor: Sendable, Equatable {
    var link: String?; var display: String?; var page: Int?
    var thumbRef: String?; var zoteroSelect: String?; var noteRef: String?
}
```
Grammar (§6): a block begins at a line matching `^<!-- block: <kind>` and the header continues across lines until the closing `-->`. Fields inside are `key: value` (quoted values unquoted on read). After the header, the block body runs until the next `<!-- block:` header or EOF. Rules:
- **Absent header** → the leading region (before the first header, or the whole body if none) is a single `freeform` block. This is `Item.trailingBodyRaw` folded into a synthetic freeform block on decode; on encode, a leading freeform block with no source may be emitted *without* a header (keeps files clean, matches §6 "if the header is absent, treated as a single freeform block"). Decision: on encode, emit an explicit `<!-- block: freeform -->` for every freeform block **except** a single leading one when it is the only block — but simplest & safest is to always emit the header for freeform blocks that are preceded by another block, and allow a headerless lead. Keep this deterministic and round-trip-stable (encode∘decode∘encode == encode).
- **Unrecognized header fields preserved verbatim** (§6 round-trip rule) in `unknownHeaderFields`.
- **Thumbnail image line**: the `![display](assets/…)` line is part of the block `markdown` (so plain TextEdit/Obsidian still renders it, §5). The parser does not strip it; W3/W4 own its relationship to `thumbRef`.
- Missing optional fields tolerated; a `reader-page` with no `page` degrades to a doc-level anchor.

**Round-trip + fuzz tests**: see Tests. The core property: `decode(encode(item)) == item` for all constructed items, and `encode(decode(text))` is byte-stable for a corpus of hand-written fixtures (including files with unknown keys, block-style lists, nested zotero, CRLF, and no front-matter).

### 3. NotesTagProjector — the audited Finder-tag mirror (§9, the one file-safety surface)

Notes is authoritative in front-matter but writes a **narrow** Finder-tag projection onto **its own** `.md` files: exactly the item's subject `tags` (title-cased per the shared convention) **+** the literal marker `ArchiveSuite`, and nothing else (D2, §5). This is the sole place Notes touches the tag-metadata safety envelope, so it reimplements **every** `TagWriter` invariant. It is a **separate, independently-audited** choke-point — `TagWriter` itself is NOT shared or refactored in run 1 (00-overview §10).

**NEW `Core/NotesTagVocabulary.swift`**:
```swift
enum NotesTagVocabulary {
    static let suiteMarker = "ArchiveSuite"
    /// The set of tokens THIS projector manages for a given item = titlecased(tags) ∪ {suiteMarker}.
    static func managedTokens(for item: Item) -> Set<String>
    static func titleCased(_ subject: String) -> String   // shared convention; from ArchiveCore
}
```

**NEW `Core/NotesTagProjector.swift`** — reimplements `TagWriter.mutate` (`TagWriter.swift:138-208`) for the projection use case. It does **only** add/remove of managed tokens; it never touches color labels (Notes doesn't use Red/Purple markers), so the label-drift machinery is simplified to *never write a label* and *verify the label is unchanged*.

```swift
enum NotesTagProjector {
    enum ProjectError: Error, Sendable { case unreadable(String), verificationFailed(String), coordinationFailed(String) }

    /// Reconcile the Finder tags on `url` (an item's own .md) so that the file's tags ==
    /// (fresh − staleManaged) + desiredManaged, where desiredManaged = NotesTagVocabulary.managedTokens(item).
    /// `previousManaged` = the tokens we wrote last time (so we remove only tokens WE own that are now gone).
    static func project(_ desired: Set<String>, previouslyManaged: Set<String>, to url: URL) throws -> Set<String>
}
```

**Invariant-by-invariant, each citing `TagWriter.swift`:**
1. **Single audited choke-point + coordinated metadata-only write.** All projection goes through `project(...)`; the write is wrapped in `NSFileCoordinator().coordinate(writingItemAt:options:.contentIndependentMetadataOnly, error:)` — never `.forReplacing`. Cite `TagWriter.swift:144`. (00-overview §9.1.)
2. **Fresh read inside coordination + trustworthy-read guard.** Read `.tagNamesKey` (+ `.labelNumberKey` only to verify it doesn't drift) inside the block; a thrown read → `throw ProjectError.unreadable`, **never** coerced to `[]`. Cite `TagWriter.swift:149-155` and the rationale in `TagReading.swift:6-9`. (§9.2 — the anti-tag-wipe rule.)
3. **Lossless delta.** `remove = previouslyManaged.subtracting(desired)` (tokens we previously owned but no longer want) **plus** any managed token being replaced; `add = desired`. Then `new = fresh.filter { !remove.contains(exactMatch) } + (add not already present)`. Untouched tokens (subjects the user tagged in Finder, anything not in our managed set) are preserved verbatim and in order. Cite `TagWriter.swift:94-101`. **Crucially**, `remove` is computed from `previouslyManaged`, not from a facet predicate — so a token the projector never wrote is never removed, even if it happens to look like one of our subjects. This mirrors `DocumentTags`' "remove the verbatim winning token, not a predicate" discipline (`DocumentTags.swift:57-60`).
4. **Only ever adds/removes projected tokens.** The `remove` set ⊆ `previouslyManaged ∪ (managed tokens being changed)`; it can never contain a token outside `managedTokens`. This bounds the blast radius (§9.5). Matching is **exact whole-string** (never substring; never case-folded except we normalize our own title-casing before diffing) — cite `TagWriter.swift:229-231` (`shouldRemove`).
5. **The `ArchiveSuite` collision case** (called out in §9/§08 adversarial tests): if the user has a *subject* literally named `ArchiveSuite`, then `titleCased(tags)` may already contain it and it is also the marker. Handle by treating `suiteMarker` as always-present-if-any-managed: it's in `managedTokens`, added once, deduped by the "not already present" check (`TagWriter.swift:99`). Removing the marker only happens if the item has **zero** managed tokens AND we previously wrote the marker — but we always write the marker for a Notes file, so it's effectively sticky. Document: a subject named `ArchiveSuite` is indistinguishable from the marker in the tag array; that's acceptable because both are "managed by us" and the union dedups. The adversarial test asserts no duplication and no accidental removal.
6. **No label writes.** Never call `setResourceValue(_, forKey: .labelNumberKey)`. After writing `.tagNamesKey`, re-read and assert the label is **unchanged** (drift guard) — if the tag-array write drifted the label (it shouldn't for a Notes file with no color token), that's a verification failure, surfaced not silently fixed. (Simplification of `TagWriter.swift:164-178`.)
7. **Verify by re-read (multiset-equal).** After write, re-read tags; assert `multisetEqual(after, intended)` (sorted-array equality, order-independent) — cite `TagWriter.swift:171,180-186,233`. On mismatch → `throw verificationFailed`, no blind retry.
8. **Return value = the managed set actually present** (`desired`), so the caller persists it as the next call's `previouslyManaged`. Where is `previouslyManaged` stored? In the **index DB** `items` table column `managed_tags` (a JSON/`\x1f`-joined string), updated in the same transaction as the item upsert (§5). On a fresh index (DB wiped), `previouslyManaged` is unknown → recover it by **reading the file's current tags and intersecting with `managedTokens(currentItem) ∪ {suiteMarker}`** as a best-effort seed; since the projector only ever removes tokens in `previouslyManaged`, a conservative empty seed means "add-only" on first projection after a wipe, which is safe (never removes a user token). Prefer: seed `previouslyManaged` = the file's current tags ∩ (recomputed candidate managed set) so a since-deleted subject is still cleaned up. Document this recovery path.

**Concurrency**: `NotesTagProjector` is a `nonisolated enum` with `static` functions exactly like `TagWriter` (`TagWriter.swift:62`), callable from any isolation domain; it uses the same `ResultBox` pattern (`TagWriter.swift:236`) to hand results out of the synchronous coordination closure. The caller (NoteStore or an @MainActor model) invokes it off the main actor.

**File-safety note**: this writes **only** files under `<NotesStore>/items/<uuid>/` (guard with the component-boundary check). It never imports a move/rename/delete/content-write API (the write-surface lint from Reader should be ported to Notes in W8; note it here as a required guardrail). Tier-2 per §12 — adversarial review + functional tests on scratch copies (`mktemp`), never the real corpus (00-overview §12; Reader Prime Directive).

### 4. Virtual folders + replication (D3) — DB tables + Swift model + organization.json

The organizational graph is **app-owned** data with no natural per-file home (00-overview §3, §11), so it lives durably in the index DB **and** is exported to `organization.json` (atomic) on every change for portability + DB-wipe survival.

**DB tables** (created by `NotesIndex.open`, §5; these are NOT FTS tables):
```sql
CREATE TABLE IF NOT EXISTS folders(
  id TEXT PRIMARY KEY,            -- UUID
  name TEXT NOT NULL,
  parent_id TEXT,                 -- NULL = top level; FK to folders.id (not enforced; app-managed)
  sort_order INTEGER NOT NULL DEFAULT 0,
  template_id TEXT,               -- FK to a template (W6); nullable
  kind TEXT NOT NULL DEFAULT 'normal',   -- 'normal' | 'smart'
  query_json TEXT                 -- for kind='smart': encoded saved query (LibraryFilter-like)
);
CREATE INDEX IF NOT EXISTS folders_parent ON folders(parent_id);

CREATE TABLE IF NOT EXISTS memberships(
  item_id TEXT NOT NULL,          -- UUID of the Item
  folder_id TEXT NOT NULL,        -- UUID of the folder
  added_at REAL NOT NULL,         -- epoch seconds
  PRIMARY KEY(item_id, folder_id) -- an item is in a folder at most once
);
CREATE INDEX IF NOT EXISTS memberships_folder ON memberships(folder_id);
CREATE INDEX IF NOT EXISTS memberships_item   ON memberships(item_id);

CREATE TABLE IF NOT EXISTS template_assignments(
  folder_id TEXT PRIMARY KEY,     -- one template per folder
  template_id TEXT NOT NULL
);
```
(Note: `folders.template_id` and `template_assignments` overlap; keep `template_assignments` as the authoritative table and treat `folders.template_id` as a denormalized cache, OR drop the column and use only the table. **Decision: use only `template_assignments`; do not add `folders.template_id`** to avoid two sources of truth. Update the schema above accordingly — the `template_id` column on `folders` is removed.)

**Swift model — mutable tree** `NEW Index/FolderGraph.swift`:
```swift
struct VFolder: Sendable, Equatable, Identifiable, Codable {
    var id: UUID
    var name: String
    var parentId: UUID?
    var sortOrder: Int
    enum Kind: String, Sendable, Codable { case normal, smart }
    var kind: Kind
    var query: SmartQuery?          // non-nil iff kind == .smart
}
struct Membership: Sendable, Equatable, Codable { var itemId: UUID; var folderId: UUID; var addedAt: Date }
struct TemplateAssignment: Sendable, Equatable, Codable { var folderId: UUID; var templateId: UUID }
struct SmartQuery: Sendable, Equatable, Codable { var keyword: String; var tags: [String]; var kind: Item.Kind?; var dateFrom: String?; var dateTo: String? }

@MainActor final class FolderGraph: ObservableObject {
    @Published private(set) var folders: [VFolder]
    @Published private(set) var memberships: [Membership]
    @Published private(set) var assignments: [TemplateAssignment]

    // Tree ops (each persists to DB via NotesIndex AND re-exports organization.json):
    func addFolder(name:, parent: UUID?) -> VFolder
    func rename(_ id: UUID, to: String)
    func move(_ id: UUID, newParent: UUID?, sortOrder: Int)   // reparent; cycle-guard
    func deleteFolder(_ id: UUID)                              // orphaned memberships handled (see below)

    // Replication:
    func addMembership(item: UUID, folder: UUID)              // a replicant
    func removeMembership(item: UUID, folder: UUID) -> RemovalOutcome
    func folders(for item: UUID) -> [UUID]
    func items(in folder: UUID) -> [UUID]
    func membershipCount(item: UUID) -> Int

    // Templates:
    func assignTemplate(_ template: UUID, to folder: UUID)
    func template(for folder: UUID) -> UUID?                  // with inheritance from ancestors
}
enum RemovalOutcome: Sendable { case removed; case wouldDeleteLastInstance }  // caller confirms + calls NoteStore.delete
```

**Delete-last-membership guard** (00-overview §3.6): `removeMembership` returns `.wouldDeleteLastInstance` **without mutating** when removing the item's *only* membership. The W6 UI then shows the mandatory "sole remaining instance — this will delete the note itself" confirmation; on confirm, the caller (1) removes the last membership row, (2) calls `NoteStore.delete(id)` (Trash), (3) deletes the item's index rows (§5). This split keeps the destructive path explicit and gated (Tier-2, §12). `deleteFolder` similarly must handle members: removing a folder drops its membership rows; any item left with **zero** memberships is surfaced for the same confirmation (batch), never silently deleted or silently orphaned.

**Reparent cycle-guard** (`move`): reject a move whose `newParent` is the folder itself or a descendant (walk up `parentId` from `newParent`; if you reach `id`, refuse). Prevents a cyclic tree that would break traversal.

**`organization.json`** `NEW Index/OrganizationFile.swift`:
```json
{ "schema": 1,
  "folders":     [ {VFolder…} ],
  "memberships": [ {Membership…} ],
  "assignments": [ {TemplateAssignment…} ] }
```
- **Export**: `Codable` → `JSONEncoder` (`.prettyPrinted`, `.sortedKeys` for stable diffs), written **atomically** (`Data.write(to: <root>/organization.json, options: .atomic)`) on **every** graph mutation. Reuse the `SavedSearchStore.save()` / `ProcessingProfileStore.persist()` Codable-to-JSON pattern (`SavedSearch.swift:77-79`, `ProcessingProfileStore.swift:183-186`). Because it's the store's own file at the root (not the corpus), atomic overwrite is safe.
- **Import / reconcile**: on launch, the graph is loaded from the **DB** (fast). `organization.json` is the **durable mirror** used when the DB is absent/wiped or after a computer move: if the DB has no `folders` rows but `organization.json` exists, **rebuild the DB tables from the JSON**. If both exist and disagree (shouldn't in normal operation), the JSON at the store root is authoritative for organization (it travels with the store; the DB is the disposable cache per §3/§11) — reconcile DB ← JSON on load, then continue writing both. Add a test for the "DB wiped, rebuild from JSON" path.
- **Portability**: `organization.json` references items by **UUID** (folder-independent of disk path), so moving the whole `<NotesStore>/` folder carries the graph intact (00-overview §4).

**Authoritative-data caveat** (§11): note body/front-matter is authoritative **in the files**; memberships/folders/assignments are authoritative in **DB + organization.json** (they have no file home). The FTS mirror of body/tags is disposable. Encode this in doc-comments so no one "fixes" it later by trying to derive memberships from files.

**Sendable/@MainActor**: `FolderGraph` is `@MainActor ObservableObject` (drives the sidebar). Its value types are all `Sendable & Codable`. DB writes are dispatched to the `NotesIndex` actor via `await`.

### 5. NotesIndex + NotesIndexer — fork of ContentIndex/ContentIndexer

**NEW `Index/NotesIndex.swift`** — `actor NotesIndex`, forked from `ContentIndex.swift`. Reuse verbatim: the actor structure + `TRANSIENT` destructor (`ContentIndex.swift:23-32`), `open()`/`close()` with WAL + `synchronous=NORMAL` + `busy_timeout` (`ContentIndex.swift:34-58`, esp. lines 43-48), `existingMTimes()` (`ContentIndex.swift:73-83`), the `upsertBatch` transaction discipline (`ContentIndex.swift:103-117`), `deletePaths` batching (`ContentIndex.swift:271-300`), `performMaintenance` (`ContentIndex.swift:306-316`), `ftsMatchExpression` sanitizer (`ContentIndex.swift:319-323`), and the `exec`/`run`/`prepare`/`bindText` helpers (`ContentIndex.swift:337-363`).

**Schema differences** (prose-tuned, 00-overview §11):
```sql
-- FTS5 search table (columns tuned for prose; id UNINDEXED so we can map rows→items):
CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(
    title, tags, authors, body, linked_names, id UNINDEXED
);
-- Non-FTS items table (drives list/sort/filter without scanning FTS):
CREATE TABLE IF NOT EXISTS items(
    id TEXT PRIMARY KEY,        -- UUID
    title TEXT,
    kind TEXT,                  -- 'note' | 'extract'
    date TEXT,                  -- verbatim front-matter date string
    sort_date INTEGER,          -- Item.sortDate (nullable → sorts last)
    quality INTEGER,            -- 1..5 nullable
    mtime REAL NOT NULL,        -- file contentModificationDate epoch (skip-map)
    managed_tags TEXT           -- \x1f-joined tokens the projector last wrote (§3.8)
);
CREATE INDEX IF NOT EXISTS items_sortdate ON items(sort_date);
CREATE INDEX IF NOT EXISTS items_kind     ON items(kind);
-- Plus the folders / memberships / template_assignments tables from §4.
```
Note: the FTS table is keyed by SQLite `rowid`; map `items.id` ↔ `fts.rowid` the same way `ContentIndex` maps `files.path` ↔ `fts.rowid` via a `SELECT rowid` lookup (`ContentIndex.swift:124-128`). Store `id` as an UNINDEXED FTS column too, so a search result row yields the item id directly without a second lookup.

**bm25 weights** — Notes uses column order `(title, tags, authors, body, linked_names)` with weights **10 / 6 / 4 / 1 / 3** (00-overview §11):
```sql
SELECT id FROM fts WHERE fts MATCH ? ORDER BY bm25(fts, 10.0, 6.0, 4.0, 1.0, 3.0);
```
Adapt from `ContentIndex.swift:158-176` (Reader used name=10/classification=5/body=1 → `bm25(fts,1.0,5.0,10.0)` in its column order). Keep the `limit == nil` vs `LIMIT ?` two-query shape.

**IndexRow** (Sendable, mirrors `ContentIndex.swift:6-15`):
```swift
struct NoteIndexRow: Sendable {
    let id: String            // UUID string
    let mtime: Double
    let title: String
    let kind: String
    let date: String?
    let sortDate: Int?
    let quality: Int?
    let tagsText: String      // tags joined by space for FTS
    let authorsText: String   // authors joined by space
    let body: String          // block bodies concatenated (front-matter stripped)
    let linkedNames: String   // source-block display names joined (the "3"-weighted column)
    let managedTags: String
}
```
`upsertRow` writes the `items` row + the FTS row in one transaction (adapt `ContentIndex.swift:121-149`): delete the old FTS row by rowid, update/insert `items`, insert FTS. Same "no `await` between BEGIN and COMMIT" invariant (`ContentIndex.swift:100-102`).

**Search API** (adapt `ContentIndex.search` `ContentIndex.swift:158-176`):
- `func search(_ query: String, limit: Int? = nil) -> [UUID]` — sanitize via `ftsMatchExpression`, bm25-ordered.
- Additional non-FTS query methods for the list/filter, all prepared-statement based like `ContentIndex.formatFlags` (`ContentIndex.swift:205-219`): `itemsSorted(by sort: NoteSort, kind: Item.Kind?) -> [ItemSummary]`, `items(in folderId: UUID) -> [UUID]`, `folderTree() -> [VFolder]`, etc. `ItemSummary` = `{id, title, kind, date, sortDate, quality}` for fast list rendering without loading files.
- Folder/membership CRUD methods (`addFolder`, `setMembership`, `deleteMembershipsForItem`, `replaceOrganization(folders:memberships:assignments:)`) invoked by `FolderGraph`; each is a small transaction.

**NEW `Index/NotesIndexer.swift`** — `@MainActor final class NotesIndexer: ObservableObject`, forked from `ContentIndexer.swift`. Reuse: the `@Published progress` + `task`/`pending`/`generation` coalescing state machine (`ContentIndexer.swift:6-50`), the `launch` parallel build with `withTaskGroup` at `workers = max(1, activeProcessorCount - 2)` (`ContentIndexer.swift:52-163`), the mtime skip-map partition (`ContentIndexer.swift:61-66`), 500-row batching (`ContentIndexer.swift:78-124`), `performMaintenance` call (`ContentIndexer.swift:159`), and the gated `pruneIfSettled` two-emission machinery (`ContentIndexer.swift:191-257`).

**Differences from Reader's indexer:**
- **DB location** (00-overview §4): `~/Library/Application Support/ArchiveNotes/notes-index-v1.sqlite3` (mirror `ContentIndexer.swift:22-30`; `-v1` since it's new — bump the filename on any future schema change, per the disposable-cache doctrine).
- **Input unit**: instead of `[ArchiveFile]` (PDFs), the indexer takes `[ItemRef]` (from `NoteStore.allItemIDs()` → `mdURL` + mtime). The per-file work in each task-group child is: read the `.md`, `FrontMatterCodec.decode`, build a `NoteIndexRow` (concatenate block bodies for `body`, join tags/authors, gather source display names for `linkedNames`). This replaces `PDFTextExtractor.extract` (`ContentIndexer.swift:96`) with `FrontMatterCodec`-based extraction — a pure, off-actor operation returning a `Sendable NoteIndexRow`.
- **Incremental mtime-skip**: identical to `ContentIndexer.swift:61-66`, keyed by **item id (UUID string)** instead of path, comparing file `contentModificationDate`.
- **Prune scoping**: prune uses **item id** set diff (index rows whose id is absent from the live `allItemIDs()` set) rather than a path-prefix. Keep the two-emission confirmation gate (`ContentIndexer.swift:196-252`) — but note that for Notes, deletions are *explicit* (user deletes an item), so prune is a **secondary** safety net for out-of-band file removals (a user deleting an item dir in Finder). Because the DB `items`/FTS rows are a disposable cache, over-eager prune loses nothing recoverable. Keep the gate anyway for cheapness/correctness parity.
- **Organizational tables are NOT pruned** by mtime — they're app-owned durable data (§4). Only `items`+`fts` rows follow the mtime/prune lifecycle. `FolderGraph` mutations write folders/memberships/assignments directly.

**As-you-type search** (00-overview §11): reuse Reader's `NavigationModel` search UX pattern — 150 ms debounce + generation-token coalescing + auto-`.relevance` sort while a query is active. The debounce/generation-token pattern is the same `generation` epoch idea already in `ContentIndexer` (`ContentIndexer.swift:18-20,44,260,265`). The **UI wiring** (the search field, debounce timer, auto-relevance) lands in W6's viewer; W2 delivers the `NotesIndexer.search(_:) async -> [UUID]` primitive (adapt `ContentIndexer.swift:166-169`) plus a documented note that the 150 ms debounce + generation token live in the view model. Provide a small `SearchGeneration` token helper so W6 doesn't reinvent it. (Do not build the SwiftUI field here — that's W6.)

**Concurrency/Sendable notes (Swift 6):** `NotesIndex` is an actor (single SQLite handle, `ContentIndex.swift:23`). `NoteIndexRow`/`ItemSummary`/`VFolder`/`Membership` are `Sendable` value types. `NotesIndexer` is `@MainActor` and launches `Task.detached(priority: .utility)` for builds (`ContentIndexer.swift:58`), capturing only `Sendable` primitives into task-group children (`ContentIndexer.swift:89-107`) — the child reads a file + decodes off-actor, returns a `Sendable NoteIndexRow`; DB writes serialize through the actor via `upsertBatch`. The `ftsMatchExpression` sanitizer is `nonisolated` (`ContentIndex.swift:319`).

**File-safety note**: the index DB is a disposable cache **outside** the store (§4) and outside the corpus; deleting it loses nothing except memberships — which are also in `organization.json`. No index operation writes the corpus. The only writes are: the SQLite file in Application Support (app data), `organization.json` (store root, atomic), and — via `NotesTagProjector` only — Finder tags on Notes' own `.md` files.

## Reuse from the existing codebase
- **`ArchiveReader/.../Search/RootFolderStore.swift:8-68`** — copy the security-scoped-bookmark lifecycle wholesale into `RootFolderStore` (Notes): `setRoot` (`:18-33`) with re-bookmark + start/stop-access swap, `resolveSaved` (`:41-63`) with the two shipped fixes (start-scope-or-nil at `:49-52`; refresh-while-held at `:56-59`). Change the defaults key to `"notesStoreRootBookmark"` and add the first-run app-default-folder branch + `RootMarkerStore.ensureMarker` call.
- **`ArchiveReader/.../Core/TagWriter.swift:138-208`** — the `mutate` template is the blueprint for `NotesTagProjector.project`. Reuse: coordinated metadata-only write (`:144`), fresh-read-inside guard (`:149-155`), lossless compute (`:94-101`), the `ResultBox` hand-out pattern (`:236`), verify-by-re-read multiset equality (`:171,180-186,233`), exact whole-string remove matching (`:229-231`). **Do not** import or modify `TagWriter` itself (00-overview §10 — the writer is not shared in run 1); reimplement narrowly.
- **`ArchiveReader/.../Core/TagReading.swift:6-9,29-38`** — the trustworthy-read doctrine (confirmed-empty vs unreadable; never request `.documentIdentifierKey`). `NotesTagProjector` re-reads inside coordination but reuses this exact "throw ⇒ abort, never coerce to []" logic.
- **`ArchiveReader/.../Core/DocumentTags.swift:70-74`** — `sortDate` formula, reused verbatim for `Item.sortDate` (00-overview §7); ideally via a shared `ArchiveCore` helper. `:57-60` — the "remove the verbatim winning token, not a facet predicate" principle informs the projector's `previouslyManaged`-based removal. `:249-258` `isDateFacetLike` may help W6's date UI (not W2).
- **`ArchiveReader/.../Search/ContentIndex.swift`** — fork the entire actor: schema/WAL (`:47-53`), `existingMTimes` (`:73-83`), `upsert`/`upsertBatch`/`upsertRow` transaction discipline (`:87-149`), `search`+bm25 (`:158-176`), `deletePaths` (`:271-300`), `performMaintenance` (`:306-316`), `ftsMatchExpression` (`:319-323`), SQLite helpers (`:337-363`). Change columns to `(title,tags,authors,body,linked_names,id)`, weights to `10/6/4/1/3`, key by UUID not path, add the `items` + organizational tables.
- **`ArchiveReader/.../Search/ContentIndexer.swift`** — fork the `@MainActor` indexer: coalescing state machine (`:6-50`), parallel `withTaskGroup` build at `cores-2` (`:52-163`), mtime partition (`:61-66`), 500-row batching + progress (`:78-128`), maintenance (`:159`), gated `pruneIfSettled` (`:191-257`), and `search` (`:166-169`). Swap `PDFTextExtractor.extract` for `FrontMatterCodec`-based `NoteIndexRow` building; key by UUID.
- **`ArchiveReader/.../Search/SavedSearch.swift:5-10,77-79`** — the `Codable` struct + `JSONEncoder`→UserDefaults pattern; adapt for `SmartQuery` and for the `organization.json` encode (but write to the **store file** atomically, not UserDefaults). The `uniqueName` disambiguation (`:63-69`) is a good pattern for folder-name uniqueness within a parent (optional).
- **`ArchiveReader/.../Search/NotesStore.swift:14-55`** — a clean `@MainActor ObservableObject` + Codable-dictionary-in-UserDefaults reference (note: this is *Reader's* per-file annotation store, unrelated to *Notes'* NoteStore; cited only as a persistence-shape reference, and to avoid a naming collision — Archive Notes' store is `Store/NoteStore.swift`, an actor).
- **`ArchiveProcessor/.../Models/ProcessingProfileStore.swift:17-44,183-192`** — `ProfileValue` shows the forward-compatible "typed Codable enum that round-trips losslessly through JSON" pattern; useful if `SmartQuery`/organization needs a heterogeneous value later. `:183-186` persist-on-mutation is the same atomic-export cadence `organization.json` uses.
- **NEW (does not exist in the repo today), to be built in W2**: `NoteStore` (actor + UUID-folder CRUD + atomic writes + rename-on-retitle), `FrontMatterCodec` (hand-rolled strict YAML subset), `BlockParser` (§6 headers), `Item`/`Block`/`SourceAnchor`/`ZoteroRef` models, `RootMarker`/`RootMarkerStore`, `NotesTagVocabulary`, `NotesTagProjector`, `FolderGraph` + `VFolder`/`Membership`/`TemplateAssignment`/`SmartQuery`, `OrganizationFile`, `NotesIndex`, `NotesIndexer`, `NoteIndexRow`/`ItemSummary`. The `ArchiveSuite` Finder-tag marker recognition is net-new to the SPEC (00-overview §D4/§10) but the SPEC edit itself is W1's job — W2 only *writes* the marker via the projector.

## Bounded sub-tasks
Each is sized to one fresh overnight session (own worktree; build clean, no new warnings; commit + push + flip the `SUITE_TODO.md` Archive Notes W2 checkbox for that sub-task + update `execution-plans/archive-notes/02-*.md` progress; remove worktree). "GUI check" uses `./launch.sh notes` (added in W1). Tests run via the Notes `test-smoke.sh` (added in W1; if not, run `xcodebuild test` directly).

**S1 — Item model + front-matter codec + block parser (pure, no I/O).**
- Scope: `Store/Item.swift`, `Store/FrontMatterCodec.swift`, `Store/BlockParser.swift`, `Store/RootMarker.swift`. No filesystem, no DB. Wire `Item.sortDate` to the shared `sortDate` formula (from ArchiveCore if present, else replicate + parity test).
- Steps: define the models; implement the tokenizer (scalars/lists/nested zotero/quoting/ISO dates per §2); implement unknown-key preservation; implement `BlockParser` for §6 headers; add `FrontMatterCodec.encode`/`decode`.
- Verify: clean build (`xcodegen generate` in the Notes worktree + `xcodebuild -scheme ArchiveNotes -derivedDataPath ./build/DD build`, no new warnings). Unit tests: `FrontMatterCodecTests`, `BlockParserTests`, `ItemSortDateTests` (see Tests). No GUI (pure). 
- Tier: **Tier-1** (pure, no irreplaceable-data surface) per §12 — but with thorough round-trip/fuzz tests because everything downstream depends on it.
- Done: codec round-trips all fixtures byte-stably; unknown keys preserved; `decode(encode(x))==x`; `sortDate` parity with `DocumentTags.sortDate` table. Flip the "W2·S1 front-matter I/O" checkbox.

**S2 — NoteStore (UUID folders, atomic CRUD, rename, delete-to-Trash, assets) + RootFolderStore + RootMarker.**
- Scope: `Store/NoteStore.swift` (actor), `Store/RootMarkerStore.swift`, `Store/RootFolderStore.swift` (Notes). Depends on S1 (uses `Item`/`FrontMatterCodec`).
- Steps: implement `create`/`load`/`save`(retitle→rename)/`delete`(Trash)/`allItemIDs`/`importAsset`; atomic `Data.write(.atomic)`; component-boundary guards; `RootFolderStore` bookmark lifecycle (copy from Reader) + first-run default folder; `RootMarkerStore.ensureMarker` (idempotent, corrupt-guard).
- Verify: clean build; unit tests `NoteStoreTests` (create/read/rename/move/delete round-trips, collision handling, asset import, Trash-not-rm assertion) all on a `mktemp -d` scratch store — **never a real corpus**. GUI: `./launch.sh notes`, confirm the app resolves/creates a store root and drops `.archive-suite-root.json` (verify via a temporary debug menu or a log line; cliclick to grant a folder if a panel appears).
- Tier: **Tier-2** (atomic writers + delete path — irreplaceable-data-adjacent even though it's Notes' own store) per §12. Adversarial review of the rename/delete/atomic-write paths; functional test on scratch copies.
- Done: all `NoteStoreTests` green; delete goes to Trash (asserted); marker idempotent (asserted: second `ensureMarker` returns the same GUID). Flip "W2·S2 NoteStore + root marker".

**S3 — NotesTagProjector (the file-safety surface) + NotesTagVocabulary.**
- Scope: `Core/NotesTagVocabulary.swift`, `Core/NotesTagProjector.swift`. Depends on S1 (Item) + S2 (writes files NoteStore created).
- Steps: implement `managedTokens`/`titleCased`; implement `project(desired:previouslyManaged:to:)` reimplementing every invariant (§3) with `TagWriter.swift` citations in comments; component-boundary guard restricting writes to `items/<uuid>/`.
- Verify: clean build; unit + property tests `NotesTagProjectorTests` on scratch `.md` copies (`mktemp`): tag-wipe attempt (unreadable file ⇒ abort, tags untouched), concurrent third-party tag added between calls preserved, lossless delta (unmanaged subject survives add/remove), `ArchiveSuite`-named-subject collision (no dup, no accidental removal), verify-by-re-read failure surfaced. GUI: create a note in the app, confirm its `.md` gets exactly `titlecased(tags)` + `ArchiveSuite` in Finder (`mdls`/`xattr` on the scratch file, or the app's own tag readback).
- Tier: **Tier-2** (the §9 projector — non-negotiable) per §12. Adversarial review by independent skeptic agents trying to break the invariants; the four §9/§08 adversarial cases are the functional test, on scratch copies only.
- Done: all adversarial tests green; a code-review confirms no move/rename/delete/content-write API and no non-managed-token removal. Flip "W2·S3 NotesTagProjector".

**S4 — NotesIndex actor (FTS5 + items + organizational tables) + NotesIndexer build/search/prune.**
- Scope: `Index/NotesIndex.swift`, `Index/NotesIndexer.swift`, `Index/NoteIndexRow`/`ItemSummary`. Depends on S1 (decode for row extraction) + S2 (`allItemIDs`/`mdURL`/mtime).
- Steps: fork `ContentIndex`→`NotesIndex` (schema/weights/UUID keying/organizational tables); fork `ContentIndexer`→`NotesIndexer` (DB path `notes-index-v1.sqlite3`, `ItemRef` input, `FrontMatterCodec` extraction, mtime skip, 500-row batches, `cores-2` task group, maintenance, gated prune by UUID); `search(_:) async -> [UUID]` + `SearchGeneration` helper.
- Verify: clean build; unit tests `NotesIndexTests` (upsert/search bm25 ordering with title>tags>authors>body precedence, sanitizer safety on adversarial query strings, incremental mtime-skip, prune two-emission gate, `wal_checkpoint(TRUNCATE)` shrinks the WAL). GUI: `./launch.sh notes`, create several notes, confirm search returns them relevance-ordered (temporary debug search field or log). Build a scratch store of ~1k synthetic notes and confirm incremental re-index skips unchanged.
- Tier: **Tier-1** (disposable cache, no irreplaceable-data surface) per §12 — but clean build, no warnings, unit tests, GUI check required.
- Done: `NotesIndexTests` green; bm25 order matches spec; incremental skip works; sanitizer never errors. Flip "W2·S4 NotesIndex".

**S5 — FolderGraph + memberships/replication + organization.json export/import + delete-last-instance guard.**
- Scope: `Index/FolderGraph.swift`, `Index/OrganizationFile.swift`, plus the `NotesIndex` folder/membership CRUD methods (some added in S4; finalize here). Depends on S4 (DB tables) + S2 (NoteStore.delete for the last-instance path).
- Steps: implement `FolderGraph` tree ops (add/rename/move with cycle-guard, deleteFolder with orphan handling), replication (`addMembership`/`removeMembership`→`RemovalOutcome`, `membershipCount`), template assignment with ancestor inheritance; `organization.json` atomic export on every mutation; import/reconcile (DB←JSON on wipe); wire the DB persistence for each op.
- Verify: clean build; unit tests `FolderGraphTests` (replicant add/remove, last-membership returns `.wouldDeleteLastInstance` without mutating, reparent cycle-guard refuses, deleteFolder orphan handling), `OrganizationFileTests` (round-trip encode/decode; rebuild DB from JSON after simulated wipe; atomic write). GUI: create folders + drag a note into two folders (if W6 sidebar exists yet it won't — so verify via a debug harness/log that memberships persist and `organization.json` updates; a full sidebar GUI test defers to W6).
- Tier: **Tier-2** (the delete-last-instance path is destructive; organization.json atomic export) per §12. Adversarial review of the last-instance guard + reconcile-on-wipe; functional test on scratch store.
- Done: all graph/org tests green; `organization.json` survives a DB wipe (rebuild verified); last-instance guard never auto-deletes. Flip "W2·S5 folders + replication + organization.json".

(Order: S1 → S2 → {S3, S4 can run in parallel after S2} → S5 after S4. Five sessions, within the §13 "~3–6 sessions per wave" estimate.)

## Tests
Unit tests (Notes test target `ArchiveNotesTests`, `xcodebuild test`). All file-touching tests use a `mktemp -d` scratch store; **none** touches the real corpus (§12).
- **`FrontMatterCodecTests`**: `roundTripKnownSchema`, `preservesUnknownTopLevelKeys`, `preservesUnknownZoteroSubKeys`, `quotesTitlesWithColons`, `parsesFlowAndBlockLists_emitsFlow`, `parsesNestedZoteroList`, `isoDatesUTC`, `noFrontMatter_wholeFileIsBody`, `malformedScalar_keptRawNotCrash`, `crlfTolerated`, `encodeDecodeStable` (byte-stable on a fixtures dir), and a **fuzz** test `fuzzRoundTrip` (randomly assembled front-matter incl. weird whitespace/quotes/unknown keys; assert decode∘encode idempotent + no data loss).
- **`BlockParserTests`**: `parsesReaderPageHeader`, `freeformNoHeader`, `preservesUnknownHeaderFields`, `thumbnailImageLineStaysInBody`, `multipleBlocksRoundTrip`, `missingOptionalFieldsDegrade`.
- **`ItemSortDateTests`**: `sortDateParityWithDocumentTags` (table of decade/year/month/day → asserts equals `DocumentTags.sortDate`), `uncertainStillSortsByDate`, `undatedSortsLast`.
- **`NoteStoreTests`**: `createReadRoundTrip`, `retitleRenamesFile`, `deleteGoesToTrashNotRm`, `assetImportReturnsRelPath`, `titleWithSlashSanitized`, `loadFailureThrowsNotEmpty`, `rootMarkerIdempotent`, `corruptMarkerRefusesOverwrite`, `writesNeverEscapeItemDir` (guard).
- **`NotesTagProjectorTests`** (adversarial, scratch copies): `unreadableFileAborts_tagsUntouched`, `losslessPreservesUserSubject`, `removesOnlyPreviouslyManaged`, `archiveSuiteSubjectCollisionNoDup`, `verifyByReReadCatchesMismatch`, `neverWritesLabel`, `concurrentThirdPartyTagPreserved`.
- **`NotesIndexTests`**: `bm25TitleOutranksBody`, `tagsOutrankAuthorsOutrankBody`, `sanitizerNeverThrowsOnAdversarialQuery`, `incrementalMtimeSkip`, `pruneRequiresTwoEmissions`, `walCheckpointTruncates`, `searchReturnsItemIDs`.
- **`FolderGraphTests`**: `replicantAddRemove`, `lastMembershipReturnsGuardOutcome`, `reparentCycleRefused`, `deleteFolderHandlesOrphans`, `templateInheritanceFromAncestor`.
- **`OrganizationFileTests`**: `roundTrip`, `rebuildDBFromJSONAfterWipe`, `atomicWriteNoPartialFile`.

GUI/behavioral checks (per sub-task, via `./launch.sh notes` + cliclick where a panel needs a click): store-root grant + marker drop (S2); a created note's Finder tags == subjects + `ArchiveSuite` on a scratch store (S3); relevance-ordered search over several created notes (S4); memberships persist + `organization.json` updates (S5, debug-harness until W6 sidebar). Full XCUITest GUI harness is W8; W2's GUI checks are lightweight confirmations.

## Risks & file-safety
- **The projector is the one corpus-safety-shaped surface.** Mitigation: it reimplements every `TagWriter` invariant (§3), writes only files under `<NotesStore>/items/<uuid>/` (component-boundary guard), never imports a move/rename/delete/content-write API, and is Tier-2 adversarially reviewed. All projector tests run on `mktemp` scratch `.md` files. **Confirmed: nothing in W2 writes the Reader/Processor corpus** — Notes only ever writes its own store (Finder tags on its own `.md` via the projector), `organization.json` at its store root (atomic), the disposable SQLite cache in Application Support, and item files/assets under `items/<uuid>/`.
- **Data-loss via non-atomic write / interrupted rename.** Mitigation: all body writes use `Data.write(.atomic)` (temp+rename); rename-on-retitle does `moveItem` then atomic content write; a crash mid-op leaves either the old or new file, never a truncated one. `organization.json` is atomic. The index is disposable (crash ⇒ re-index).
- **Front-matter round-trip dropping user data.** Mitigation: unknown-key preservation (top-level + zotero sub-keys) with byte-stable re-emit; the fuzz + `encodeDecodeStable` tests gate this. A malformed scalar is preserved raw rather than lost.
- **Delete-last-membership silently deleting a note.** Mitigation: `removeMembership` returns `.wouldDeleteLastInstance` **without mutating**; the actual file delete goes to **Trash** (recoverable) and only after the W6 confirmation. Tier-2.
- **Organization graph lost on DB wipe.** Mitigation: `organization.json` at the store root is the durable mirror; rebuild-from-JSON path is tested. Moving the store folder carries UUID-keyed memberships intact.
- **RootMarker GUID churn breaking durable links.** Mitigation: `ensureMarker` is idempotent and never overwrites an existing GUID; a corrupt marker refuses overwrite and surfaces an error rather than minting a new identity (§8.3 anti-silent-failure).
- **Swift 6 data races.** Mitigation: `NoteStore`/`NotesIndex` are actors (single mutable-resource confinement); `NotesIndexer`/`FolderGraph`/`RootFolderStore` are `@MainActor`; all cross-domain payloads (`Item`, `NoteIndexRow`, `ItemSummary`, `VFolder`, `Membership`) are `Sendable` value types; task-group children capture only `Sendable` primitives (the `ContentIndexer` discipline). No `await` between BEGIN and COMMIT in DB transactions.

## Open questions
1. **`sources` at item level** (00-overview §3.1 "convenience union of block sources") — is it *stored* in front-matter (denormalized, risking drift with block headers) or *derived* on load? Lean derived (single source of truth = block headers); confirm in W4 when source blocks are built.
2. **Title-casing convention for the Finder-tag mirror** (§5 "title-cased per the shared convention") — exact algorithm (per-word capitalize? preserve acronyms like "DP"?) should come from `ArchiveCore`/the SPEC so Notes and any future consumer agree; W2 uses a documented `titleCased` and flags it for SPEC alignment.
3. **`managed_tags` seed after a DB wipe** — the conservative "add-only" recovery (§3.8) leaves a since-deleted subject's Finder tag on the file until the next full projection with a known baseline. Acceptable? Or should a post-wipe reconcile pass recompute `previouslyManaged` from files? Deferred; low blast radius (extra tag, never a lost user tag).
4. **Smart-folder query language** (`SmartQuery`) — W2 stores it as a struct; the *evaluation* (running it against the index as a scoped root, mirroring Reader's smart-folder-as-scope) is W6. Confirm the field set matches W6's needs before locking `query_json`.
5. **`organization.json` conflict policy** if a user edits it by hand while the app runs — currently the app overwrites on next mutation. A merge/reload-on-external-change is a possible later refinement (non-blocking).
