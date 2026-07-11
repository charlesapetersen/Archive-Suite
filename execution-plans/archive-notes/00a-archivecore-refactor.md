# Archive Notes — W0: ArchiveCore extraction & suite-wide migration (FIRST WAVE)
> Status: PROPOSED · part of Archive Notes (see 00-overview.md) · Wave 0 (FIRST) · Tier-2

> ⚠️ **Canonical shared types & cross-wave APIs are defined in `00-overview.md` §16 (Interface Contract).** Where a sketch in this file differs, **the overview is authoritative.**

This plan is the expansion of the `00a` slot referenced by `00-overview.md` §13 (wave index) and §10 (the ArchiveCore decision). It is authoritative for the mechanics of W0; where it and `00-overview.md` §16 (interface contract) disagree, §16 wins for the *net-new* Notes types (`DurableLink`/`RootMarker`), and this file wins for the *extraction* mechanics.

---

## Goal & non-goals

**Goal (behavior-preserving).** Create a net-new `packages/ArchiveCore` Swift package and migrate **both shipping apps** (Archive Reader, Archive Processor) onto it, so the tag/PDF/date contract of `SPEC/tag-format.md` lives in exactly one UI-free place — including **one** audited coordinated tag-write primitive that Reader's delta-mutate and Processor's fresh-write both become thin adapters over. This is the forcing function `SPEC/tag-format.md:208-209` names ("When Archive Suite extracts the shared `ArchiveCore` package, Processor's `MacOSTagger` and Reader's `TagWriter` reconcile into one audited writer and this file becomes that package's contract doc").

**Parity is the acceptance bar, not new behavior.** "Done" for W0 = both apps build clean with **zero new warnings**, the full Reader unit suite is green, the Processor smoke (`ArchiveProcessor/test-smoke.sh`) is green, the package `swift test` is green, and a scratch-corpus tag-write functional check passes at each write-path move. No user-visible behavior changes. **This bar is only meaningful once S0 repairs the three helper scripts the earlier de-nesting silently broke (below)** — until then a "green" smoke/lint run is building/grepping the wrong (stale, pre-de-nest) tree and proves nothing.

**Non-goals (explicitly deferred — do NOT do in W0):**
- Any Notes-specific code (that is W1+; Notes merely *depends* on the shipped ArchiveCore).
- Teaching Reader to parse/**hide** the `ArchiveSuite` marker in its UI (`00-overview.md` §2 call-out R13d) — W0 *defines* the marker type; nothing consumes it yet.
- Corpus **back-fill** of `ArchiveSuite`; Processor **stamping** `ArchiveSuite` on new output.
- Mirroring date/quality into Finder tags; a fuller single unified-writer API (`00-overview.md` §15 Q2 — W0 ships the primitive + adapters, not one merged writer signature).
- Unifying the two page-2-header *builders* (`PDFGenerator.makeTextPage`) — W0 unifies only the *parser* (see §"What moves"); the compose side stays in Processor.
- A shared suite-wide storage path (`00-overview.md` §15 Q1).

---

## What moves to ArchiveCore vs stays app-specific

Destinations: **[Core]** = moves into `packages/ArchiveCore`; **[Reader]** / **[Proc]** = stays in that app; **[split]** = value/contract part moves, app-specific part stays.

| Symbol / file | Current location (file:line) | Destination | Why |
|---|---|---|---|
| `ReadState` enum | `ArchiveReader/.../Core/DocumentTags.swift:13-18` | **Core** | Read/Unread facet vocabulary — shared contract (SPEC facet table). |
| `ArchiveColor` (+ `labelNumber`/`tokenName`/`init?(labelNumber:)`) | `DocumentTags.swift:21-38` | **Core** | Red=6/Purple=3 mapping is the color contract (SPEC §Color label). `tokenName`/`labelNumber`/`init?(labelNumber:)` must be **public** (used cross-module by Reader `TagWriter.apply:79,84`). |
| `DocumentTags` struct (+ nested `Month`) + `sortDate` + `displayDate` + `topicalTags` + `dateIsSpeculative` | `DocumentTags.swift:41-111` (`sortDate` at :70-74) | **Core** | The canonical facet model + chronological sort key (`SPEC/tag-format.md:82-92`); already marked UI-free/package-ready (`DocumentTags.swift:9-10`). Notes reuses `sortDate` verbatim (`00-overview.md` §7). Nested `Month` must be **public** with public members (read cross-module). |
| `DocumentTags.parse` + `parseYear/parseMonth/parseDay/parseDecade/parsePriority` + `monthNames` | `DocumentTags.swift:119-244` | **Core** | THE parser both apps must interpret identically (`SPEC/tag-format.md:54-56`). |
| `isDateFacetLike` | `DocumentTags.swift:249-258` | **Core** | Date-facet recognition used for display suppression; part of the parse contract. |
| `TagReadResult` + `TagReading` (`read`/`readTags`) | `Core/TagReading.swift:10-46` | **Core** | The trustworthy-read primitive (SPEC invariant 3); the write primitive depends on it. |
| `TagDelta` / `TagWriteResult` / `TagWriteError` | `Core/TagWriter.swift:23-60` | **Core** | Value types of the audited write seam. `TagDelta` needs a **public** memberwise init (constructed by app code + `TagEditing`). |
| **`mutate` coordinated primitive** → `CoordinatedTagWriter.write` + `shouldRemove`/`isSameTag`/`multisetEqual`/`normalized`/`ResultBox` | `Core/TagWriter.swift:138-240` (`mutate` at :138-208) | **Core** | The single choke-point (SPEC invariants 1-5). Only the *primitive + value types + low-level helpers* move (see correction below). |
| **`TagWriter.apply` / `apply(_:to:[URL])` / `setReadState`** | `Core/TagWriter.swift:62-130` | **[Reader] — CORRECTED** | These are Reader's **delta adapter** (delta/color `.set`/`.clear`/`.restoreLabel` switch, `:68-106`, `:118-130`). They stay Reader as a thin `TagWriter` facade *over* `CoordinatedTagWriter.write`; Processor's fresh-write is a *different* adapter. (Draft routed these to Core — that contradicts the write-seam section and would pull Reader-only delta logic into the shared package. Fixed.) |
| `TagEditOp` / `TagEditing.delta` / `subjectDelta` / `monthToken` / `GroupTagSummary` | `Core/TagEditing.swift:8-124` | **Core** | Turns user intents into `TagDelta`s; pure, contract-coupled (facet-token removal rules). `GroupTagSummary` needs a **public** init. |
| `ExtractedContent` + PDF text/classification parser | Reader `Search/PDFTextExtractor.swift:5-38` **and** Proc `OCR/PDFTextExtractor.swift:5-118` | **Core (dedupe — NOT trivial)** | Two **semantically divergent** parsers of the same page-2 format (`SPEC/tag-format.md:116-140`). The unified parser must expose **both** a full-all-pages body (Reader's FTS input) **and** a header-stripped body, plus a raw cross-page `classification` string — see §dedupe and #S2 below. |
| `PDFFormatStatus` | Reader `Core/PDFFormatStatus.swift:14-43` | **Core** | Pure read-only classifier over `ExtractedContent`; travels with the shared extractor. |
| `GeneratedTags` value type: `capitalizeFirstLetters`, `allTags` emit-order, `machineDate`, `monthNumber`, `englishMonthNames`, `monthTag`, `dayNumber`, `stringField` | Proc `Tagging/TagGenerator.swift:3-98` (`allTags` at :28-42) | **Core** | The Processor **vocabulary + token formatting** (title-casing, `MM Month`, `Day N`, decade passthrough, `OCR Failed`, trailing-`Unread` ordering) that must match the parser (`SPEC/tag-format.md:184-189`). Pure `Codable` struct — no LLM deps. **Needs a `public init`** reproducing every stored property with today's exact defaults (see #S4). |
| `TagGenerator` class (`generateTags`/`generateDateOnly`/`callLLM`/`parseTagResponse`) | `TagGenerator.swift:100-290` | **Proc** | `@MainActor ObservableObject`; imports `LLMProvider`/`LLMModel`/`GatewayConfig`/`DocumentSegment`/`LLMTextClient` — Processor-only. Keeps building `GeneratedTags`; now imports it from Core. |
| `MacOSTagger` (`readTags`/`applyTags`/`applyTags(GeneratedTags)`/`finderLabelIndex`/`stampUnread`) | Proc `Tagging/MacOSTagger.swift:5-97` | **[split]** | Becomes a **thin adapter** over the Core write primitive (S5). The `stampUnread` `OSAllocatedUnfairLock` static (:11-15) and the 7-color `finderLabelIndex` (:85-96, only Red/Purple suite-meaningful) stay Processor; the array/label computation is expressed as a `transform` fed to the Core primitive. |
| `PDFGenerator` (incl. `makeTextPage` header builder) | Proc `OCR/PDFGenerator.swift:207-225` | **Proc** | The PDF *writer* (AppKit/CoreText/ImageIO, `PDFDocument.write`). Content-write, not tag-metadata; stays. Its emitted header string is the contract the Core parser reads; the *compose* side stays here (builder unification deferred, see non-goals). |
| `DocumentClassification` enum (`.displayName`, Codable rawValues) | Proc `Models/ProviderModels.swift` (SHARED HOTSPOT, persisted) | **Proc** | rawValues are persisted in JSON sidecars (`SPEC/tag-format.md:130-133`, `202-204`). Do NOT move a persisted enum into Core. Processor's extractor adapter maps the Core parser's classification **string** ↔ its enum, re-imposing the "unknown → nil" filter (see #S2/#5). |
| **New:** `DurableLink`, `RootMarker`, `RootKind`, `ArchiveSuite` marker constant + recognition helper | net-new (`00-overview.md` §16.2) | **Core (net-new)** | So W1+ Notes depends on the shipped, tested types. No shipping-app behavior change (nothing consumes them in W0). `RootMarker` needs **explicit Codable** (lowercased-UUID string + ISO-8601 date) — Swift's default `UUID`/`Date` Codable emit uppercase UUID / float date (see #S6). |

**Reader-UI-coupled — must NOT move (stay [Reader]):**
- `ArchiveFile` (`Core/ArchiveFile.swift:7-35`) — a nav-row record; its `==` exists specifically for SwiftUI `Table` diffing (`ArchiveFile.swift:24-34`). Reader-specific, references `DocumentTags` (imports Core).
- `LibraryFilter`/`LibrarySort`/`ReadFilter`/`SubjectCombine`/`SortField`/`ARSortDescriptor` (`Core/LibraryFilter.swift:9-212`) — Reader's filter/sort model over `ArchiveFile`; Notes has its own `NotesFilter` (`00-overview.md` §16.3), so this is NOT shared.
- `FileLink.swift` (`LinkFormat`/`FileLinkFormatter`, :4-60) — Reader's *clipboard* `file://`/POSIX/Markdown/HTML formatter. UI-free but a Reader feature, not the shared contract, and unrelated to the net-new `DurableLink` (the `archivereader://`/`archivenotes://` scheme). Stays Reader.
- `TagWriter.apply`/`apply(_:to:[URL])`/`setReadState` — Reader's delta adapter facade (corrected above).
- Everything under Reader `Views/`, `Search/{ArchiveLibrary,RootFolderStore,ContentIndex,ContentIndexer,NotesStore,SavedSearch}`, and Processor `Views/`, `Capture/`, `Net/`, `OCR/*Client*`, `Models/*` — SwiftUI/AppKit-coupled or app-domain-specific. **Nothing that imports SwiftUI or AppKit moves.**

---

## Package layout

```
packages/ArchiveCore/
  Package.swift
  Sources/ArchiveCore/
    Tags/
      DocumentTags.swift        # facets + parse + sortDate + isDateFacetLike + Month (from Reader Core)
      ReadState.swift           # (split out of DocumentTags for a tidy public surface — optional)
      ArchiveColor.swift        # (optional split)
      TagReading.swift          # trustworthy read (from Reader Core)
      TagWrite.swift            # TagDelta/TagWriteResult/TagWriteError + CoordinatedTagWriter primitive
                                #   + shouldRemove/isSameTag/multisetEqual/normalized/ResultBox (helpers)
      TagEditing.swift          # TagEditOp/TagEditing/GroupTagSummary (from Reader Core)
      GeneratedTags.swift       # Processor vocabulary/formatting value type (from Proc TagGenerator.swift)
    PDF/
      PDFTextExtractor.swift    # ONE shared page-2 parser → ExtractedContent (fullBody, strippedBody, classification String?, pageCount)
      PDFFormatStatus.swift     # (from Reader Core)
    Links/
      DurableLink.swift         # net-new: DurableLink, RootMarker, RootKind, ArchiveSuiteMarker
  Tests/ArchiveCoreTests/
    DocumentTagsTests.swift     # moved from Reader
    TagWriterPrimitiveTests.swift # moved SUBSET: raw CoordinatedTagWriter.write, trustworthy-read guard,
                                #   verify-by-re-read, label-drift (delta/apply tests STAY in ArchiveReaderTests)
    TagEditingTests.swift       # moved from Reader
    SubjectTokenEditTests.swift # moved from Reader (TagEditing.subjectDelta)
    PDFFormatStatusTests.swift  # moved from Reader
    GeneratedTagsTests.swift    # NET-NEW golden tests for allTags emit-order (Processor had no test target)
    PDFHeaderParserTests.swift  # NET-NEW golden round-trip vs the SPEC header + FTS body-view assertions
    DurableLinkTests.swift      # NET-NEW for the new types (explicit-Codable round-trip)
```

`Package.swift`:
```swift
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "ArchiveCore",
    platforms: [.macOS(.v14)],
    products: [ .library(name: "ArchiveCore", targets: ["ArchiveCore"]) ],
    targets: [
        .target(name: "ArchiveCore"),                                   // Foundation + PDFKit only (system)
        .testTarget(name: "ArchiveCoreTests", dependencies: ["ArchiveCore"]),
    ]
)
```
- **No third-party dependencies** (Foundation + PDFKit are system frameworks; no `dependencies:`). No SwiftUI/AppKit import anywhere in the target — a grep guard for `import SwiftUI|import AppKit` under `Sources/ArchiveCore` is added to the write-surface lint (§XcodeGen wiring).
- Swift 6 language mode is the tools-version default at 6.0. Because the package's strict-concurrency posture may be *stricter than the app targets' current build settings*, S3's verify includes a clean package build with strict concurrency; keep `ResultBox` (`TagWriter.swift:236`) **file-private to `TagWrite.swift`** (it is captured non-`Sendable` inside the `NSFileCoordinator` accessor, exactly as today), and confirm the public `transform` closure needs no `@Sendable` (it is synchronous/non-escaping in use). **No mutable statics move** (`stampUnread`'s lock stays in Processor), so the task's `nonisolated(unsafe)` concern is moot for moved code — do NOT let a session "helpfully" add annotations.
- Add `packages/ArchiveCore/.build/` to the repo `.gitignore` (SwiftPM build dir; distinct from the apps' gitignored `build/`).

**Which existing tests move in (placement CORRECTED — see #9):** because `apply`/`setReadState` stay in Reader, tests that exercise **delta application**, the color `.set`/`.clear`/`.restoreLabel` switch, and the no-op path exercise Reader-resident API and **stay in `ArchiveReaderTests`** (the package cannot import the app). Only tests hitting the raw primitive (`CoordinatedTagWriter.write` transform, trustworthy-read→abort, verify-by-re-read, label-drift) move to `ArchiveCoreTests`. `DocumentTagsTests`, `TagEditingTests`, `SubjectTokenEditTests`, `PDFFormatStatusTests` move whole. `TriageTests` `setReadState`/facet parts **stay Reader** (they call the Reader facade); split the file only if a single test straddles both. Reader-only tests referencing `ArchiveFile`/`LibraryFilter`/`LibraryChangeSignature`/`DuplicateNames`/`NavigationModel`/`ContentIndex`/`SavedSearch`/`ArchiveLibrary`/`CopyTextCleaner` stay. **No test is deleted** — total coverage across `ArchiveCoreTests` + `ArchiveReaderTests` + the Processor smoke ≥ today's ~186-191.

---

## XcodeGen + build wiring

**Relative path** from each app's XcodeGen project dir to the package: both `ArchiveReader/macOS/` and `ArchiveProcessor/macOS/` are two levels under the repo root, and the package is at `<root>/packages/ArchiveCore`, so the path is **`../../packages/ArchiveCore`** for both.

**`ArchiveReader/macOS/project.yml`** — add a top-level `packages:` block and a target dependency:
```yaml
packages:
  ArchiveCore:
    path: ../../packages/ArchiveCore
targets:
  ArchiveReader:
    # ...existing...
    dependencies:
      - package: ArchiveCore
```
**`ArchiveProcessor/macOS/project.yml`** — identical additions:
```yaml
packages:
  ArchiveCore:
    path: ../../packages/ArchiveCore
targets:
  ArchiveProcessor:
    # ...existing...
    dependencies:
      - package: ArchiveCore
```
(Reader's test target already `dependencies: - target: ArchiveReader` at `ArchiveReader/macOS/project.yml:43-44`; it transitively sees ArchiveCore through the app — no change needed, since moved tests run in the package, not the Reader scheme. See §Parity.)

**Scripts — CORRECTED (three are silently broken by the de-nesting; two are fine):**
- ⚠️ **`ArchiveReader/scripts/lint-write-surface.sh` is VACUOUS today** — `SRC="ArchiveReader/Sources/ArchiveReader"` (`:11`), but post-de-nest the code is at `ArchiveReader/macOS/Sources/ArchiveReader`. It prints `✓ write-surface lint clean` while grepping a **non-existent path**, so it currently catches none of the 3 real `setResourceValue` calls under `macOS/`. **This is the FIRST action of S0** (see below) — it must be repaired and proven to *catch* the existing writes before any move, or every W0 "lint clean" claim is meaningless.
- ⚠️ **Both `test-smoke.sh` point at the pre-de-nest inner dir.** `ArchiveReader/test-smoke.sh:16` sets `PROJ="$ROOT/ArchiveReader"` (→ `ArchiveReader/ArchiveReader/`, which has **no** `project.yml` — only a stale gitignored `.xcodeproj` + `Sources/` + `build/`, confirmed present on disk); `ArchiveProcessor/test-smoke.sh:21` sets `PROJ="$ROOT/ArchiveProcessor"` (same problem). `cd "$PROJ" && xcodegen generate` (Reader `:22`, Proc `:115`) rebuilds/tests a **stale pre-de-nest copy** or fails. These are the parity gate — **repaired in S0** to `PROJ="$ROOT/macOS"`.
- ✅ **`ArchiveReader/bootstrap.sh` — unchanged.** It finds every `project.yml` and runs `xcodegen generate` (`bootstrap.sh:30-35`); XcodeGen wires the local package into the generated (gitignored) `.xcodeproj` by relative path, and `xcodebuild` resolves it at build time. No new step.
- ✅ **`release/build-suite-dmg.sh` — unchanged and already correct.** It Release-builds each app from `ArchiveProcessor/macOS`/`ArchiveReader/macOS` (`:35-38`); each `xcodebuild` resolves the local package. One package, pulled by both apps, one DMG.
- **One TEST-harness change (not a build change):** the suite-root `./test-smoke.sh` dispatcher gains an `archivecore` step that runs `swift test` in `packages/ArchiveCore`, included in `all`. This is where the moved + net-new Core tests execute. (The apps' own smoke scripts stay as written *after S0's path repair*.)

---

## The unified write seam

**One primitive in ArchiveCore.** Expose the current `TagWriter.mutate` (`Core/TagWriter.swift:138-208`) as the public coordinated-write primitive — `CoordinatedTagWriter.write`. Signature unchanged:
```swift
public enum CoordinatedTagWriter {
  /// The ONLY code in the Suite that calls setResourceValue on tag/label keys.
  public static func write(
    _ url: URL,
    transform: ([String], Int?) -> ([String], Int?)?   // (freshTags, freshLabel) -> (newTags, newLabel)? ; nil = no-op
  ) throws -> TagWriteResult
}
```
It carries, unchanged, every guarantee already proven in Reader's `mutate`: `NSFileCoordinator(.contentIndependentMetadataOnly)` (never `.forReplacing`, which would re-save content — a Prime-Directive violation) (:144); fresh read **inside** coordination (:149-152); trustworthy-read guard — throw `TagWriteError.unreadable` on a read failure, never coerce to `[]` (:153-155); write label only when it changes + drift-restore (:164-178); verify-by-re-read multiset+label (:171-186); label-only `.restoreLabel` inverse (:188-199). The helpers `shouldRemove`/`isSameTag`/`multisetEqual`/`normalized`/`ResultBox` move with it into `TagWrite.swift`.

⚠️ **`normalized(_:)` placement (was unhandled — #7).** `normalized` is a file-private free function at `TagWriter.swift:240` used by BOTH `TagWriteResult.isNoOp` (`:53`, moving to Core) AND the Reader-resident `apply` (`:103,166,175,183-184,196`). Make it an **internal Core helper** exposed to the Reader facade *and* keep it callable from `mutate`; if Reader's facade needs it and it isn't public, add a tiny `public` re-export or a private duplicate in the Reader facade. Name this explicitly in S3 or the module fails to compile.

**Reader = a delta adapter (stays Reader).** The `TagWriter` facade keeps `apply` (:68-106) / `apply(_:to:[URL])` / `setReadState` (:118-130): it computes a `(new, label)` from `delta` against the freshly-read `current` and hands the closure to the primitive — `TagWriter.apply { … } → CoordinatedTagWriter.write(url) { current,label in … }`. Zero logic change — it *is* the code that already lives inside `mutate`, now split so the delta/color switch stays Reader-local while the coordinated I/O is shared.

**Processor = a fresh-write adapter (S5).** `MacOSTagger.applyTags(_:to:appColor:colorIsAuthoritative:)` (`MacOSTagger.swift:28-77`) is re-expressed as a transform passed to the same primitive. The transform reproduces today's exact array construction: copy-source mode passes source tags verbatim and **returns `nil` (writes nothing) when the source array is empty** (:33-38); real-tagging mode drops incoming `Unread`, dedupes the authoritative color token, appends exactly one trailing `Unread` (:42-66), and sets the label via `finderLabelIndex` or clears to 0 (:72-76). The resulting tag **multiset + label** is identical to today's; the *only* additions are the primitive's coordination, trustworthy-read guard, and verify-by-re-read.

⚠️ **This is a real semantic change on the Processor path, not "free defense-in-depth" (#12).** Today `MacOSTagger` never reads before writing; the primitive does a fresh read inside coordination and **aborts** on an unreadable read (`TagWriter.swift:149-155`), and it writes the label only when it changes (vs Processor's unconditional 0/6/3 set at `:72-76`) — end state must be identical, path is not. That semantic tightening is why S5 is last, gets adversarial review, and its parity harness must cover retag-overwrite / empty-copy-source / unreadable-target (see #S5).

**Output-parity assertion is multiset+label, NOT byte/array-identical (#11).** Reader appends additions after existing tokens; Processor builds `[color] + textTags + ["Unread"]` (`:64-66`); and macOS reorders on write (`SPEC/tag-format.md:35`). The S3/S5 harness compares **multiset(tags) + labelNumber** only — an array-`==` assertion would flag spurious regressions unattended.

**Seven invariants — where each is preserved:**
1. Prime Directive (no byte/location change) — primitive only ever touches `.tagNamesKey`/`.labelNumberKey`; no move/rename/delete/content-write anywhere in Core; enforced by the *repaired + extended* write-surface lint.
2. Single choke-point / coordinated metadata-only delta-vs-fresh-read + verify — the primitive (`mutate` body).
3. Trustworthy-read guard — `mutate:149-155` + `TagReading.read` distinguishing confirmed-empty vs failure (`TagReading.swift:29-38`); Processor's throwing `readTags` (`MacOSTagger.swift:19-22`) preserved (now delegating to Core `TagReading`).
4. Exact whole-string / case-insensitive-for-Read-Unread matching — `shouldRemove`/`isSameTag` (`TagWriter.swift:223-231`) move intact.
5. Lossless `new=(fresh−remove)+add`, no-op writes nothing — Reader `apply` compute (:94-104) + Processor transform's `nil` return.
6. `Unread` stamped last, once — Processor adapter transform (`MacOSTagger.swift:42-66`), only in real-tagging modes (`stampUnread` gate :33).
7. App-authoritative color — Processor `colorIsAuthoritative` path (:48-56) + Reader delta color logic (:74-92); a subject literally `"Red"`/`"Purple"` is never promoted.

**Future Notes projector attaches here (W2, not W0):** `NotesTagProjector` (`00-overview.md` §9) becomes a *third* transform over `CoordinatedTagWriter.write`, computing `new = (fresh − managed-tokens-it-no-longer-wants) + (subjects + "ArchiveSuite")`. W0 leaves the primitive public and the `ArchiveSuite` marker constant defined so W2 has nothing to invent.

---

## Migration order — bounded sub-tasks

Each Sn = **one fresh overnight session**, each leaves **all apps building + green**, each states its own verify + rollback. **S0 is a hard prerequisite** — it repairs the parity gate itself before any code moves. Then: pure read-side first; write path in the middle (Reader, its origin, first); Processor write convergence last.

### S0 — Repair the de-nested helper scripts + delete stale trees (PREREQUISITE — must run first)
- **Why:** the acceptance bar (lint clean + both smokes green) is currently enforced against **stale, pre-de-nest paths** — see §XcodeGen wiring landmines. No W0 verify means anything until this is fixed. This sub-task moves **no product code**.
- **Edit:**
  1. `ArchiveReader/scripts/lint-write-surface.sh:11` — `SRC="ArchiveReader/macOS/Sources/ArchiveReader"`.
  2. `ArchiveReader/test-smoke.sh:16` — `PROJ="$ROOT/macOS"`.
  3. `ArchiveProcessor/test-smoke.sh:21` — `PROJ="$ROOT/macOS"`.
  4. Delete the stale `ArchiveReader/ArchiveReader/` and `ArchiveProcessor/ArchiveProcessor/` trees (confirmed on disk: each is a gitignored stale `.xcodeproj` + `Sources/` + `build/`, 0 git-tracked files) so an overnight session can never build the wrong copy.
- **Verify (proves the gate now works):**
  - Run the repaired lint and confirm it now **FAILS**, listing the 3 real `setResourceValue` calls under `macOS/Sources/.../Core/TagWriter.swift` — i.e. it catches what it silently missed. (After S3/S5 relocate the writes it will pass again.) Baseline this "expected fail on current tree" so S3's "now clean" is meaningful.
  - Run both repaired smokes against current `macOS/Sources` → green (this is the true pre-migration baseline; record the Reader test count).
  - `git status` shows the stale trees gone; both apps clean-build via `bootstrap.sh` + `xcodebuild`.
- **Rollback:** `git revert` the S0 commit (restores script paths; stale trees are gitignored so their deletion isn't tracked — re-generate via `xcodegen` if ever needed, which nobody should).
- **Tier:** Tier-1 (no product code, no write path) — but blocking. Self-review.
- **Done + docs:** flip W0/S0 `SUITE_TODO.md` checkbox; note in `AGENTS.md`/each app README that the smoke `PROJ` and lint `SRC` are now the de-nested `macOS/` paths.

### S1 — Package scaffold + wiring + the pure facet model → Reader
- **Scope:** create `packages/ArchiveCore` (`Package.swift`, empty test target); wire both `project.yml`s (both apps must still build even though only Reader uses Core yet); move the **pure, write-free** facet model.
- **Move:** `DocumentTags.swift` (facets, `parse`, `sortDate`, `isDateFacetLike`, nested `Month`, `ReadState`, `ArchiveColor`) → `Sources/ArchiveCore/Tags/`. Make the moved types + members `public`; add an explicit **public** `DocumentTags` init (public struct's synthesized memberwise init is internal); make `Month` public with public members and `ArchiveColor.tokenName`/`.labelNumber`/`init?(labelNumber:)` public. Delete Reader's copy.
- **Callers to update:** add `import ArchiveCore` to every Reader file referencing `DocumentTags`/`ReadState`/`ArchiveColor`/`sortDate` — grep confirms `ArchiveFile.swift`, `LibraryFilter.swift`, `TagWriter.swift`, `TagEditing.swift`, `TagReading.swift`, `NavigationModel.swift`, `InlineEditCells.swift`, `SubjectTokenField.swift`, `TagEditorView.swift`, `PDFFormatStatus.swift`, etc.
- **Move tests:** `DocumentTagsTests.swift` → `ArchiveCoreTests`.
- **Verify:** `swift build && swift test` in the package; Reader clean build + `ArchiveReader/test-smoke.sh` (now correctly pathed) green (count = S0 baseline − moved `DocumentTags` tests); Processor clean build (untouched code, proves package wiring doesn't break it); **zero new warnings** both apps (clean build, not cached).
- **Rollback:** `git revert` the S1 commit — restores Reader's `DocumentTags.swift`, removes the package + `project.yml` blocks; both apps green again.
- **Tier:** Tier-1 (no write path touched) but inside a Tier-2 package — clean build + self-review.
- **Done + docs:** flip W0/S1 `SUITE_TODO.md` checkbox; note ArchiveCore in both apps' CLAUDE Implementation Maps (stub).

### S2 — Shared PDF text/header parser + PDFFormatStatus → both apps (dedupe) — parity-affecting, NOT trivial
- **Scope:** collapse the two `PDFTextExtractor`s into one Core parser; move `PDFFormatStatus`. ⚠️ **The two parsers are semantically divergent — a naive "keep Processor's parser" regresses Reader full-text search (#4/#5).**
- **The divergence, explicitly:**
  - **Body.** Reader `Search/PDFTextExtractor.swift:14-26` concatenates **every page's** text (incl. the page-2 header lines *and* any page-1 searchable text layer) into `body`, fed straight into FTS by `ContentIndexer.swift:96-100,138-142`. Processor `OCR/PDFTextExtractor.swift:20-118` reads **only page 2** (only when it begins `Extracted text.`) and `parseAppFormat` **strips the header**, returning body-below-header. SPEC warns page-1 images "often also carry a searchable text layer" (`SPEC/tag-format.md:110-112`) — dropping it makes it unsearchable.
  - **Classification.** Reader `parseClassification` (`:29-38`) scans *any line of any page* and returns the **raw value verbatim**. Processor's scan is page-2-header-only and maps to the four known `DocumentClassification` values, returning **nil for unknown** (`:70-84`).
- **Unified contract (mandated):** the Core parser returns `ExtractedContent { fullBody /* all pages, verbatim — Reader FTS input */, strippedBody /* header removed — display */, classification: String? /* raw string scanned across pages */, pageCount }`. Reader indexes `fullBody` (no search regression). Processor's **thin `OCR/PDFTextExtractor` shim** maps only the 4 exact `displayName`s to its persisted enum, everything else → `nil` — reproducing today's Processor behavior at `:75-80`; the enum stays Processor (`SPEC/tag-format.md:202-204`).
- **`PDFFormatStatus`** (`Core/PDFFormatStatus.swift`) moves and consumes Core `ExtractedContent` (via `strippedBody`/`classification`, matching its current use).
- **Callers to update (CORRECTED — #10):** Reader — add `import ArchiveCore` to `Search/ContentIndex.swift` (stores `body`/`classification` columns), `Search/ContentIndexer.swift`, and the `PDFFormatStatus` consumers `Views/DocumentViewerModel.swift` and `Views/NavigationModel.swift`. **Drop the non-existent `PDFPaneView` reference** from the draft. Processor — `OCR/OCRProcessor+OCR.swift` and the `PDFGenerator.swift` reference to `ExtractionResult`; the shim maps the classification string ↔ enum.
- **Move/add tests:** `PDFFormatStatusTests.swift` → Core; **add** `PDFHeaderParserTests.swift` — golden round-trip against the SPEC header (`SPEC/tag-format.md:116-140`) and against a string built like `PDFGenerator.makeTextPage` (`OCR/PDFGenerator.swift:213-225`); explicit cases for the **unknown-classification-value** and **body-`Classification:`-line** paths (asserting shim→nil for unknown); and an assertion that `fullBody` contains the header + page-1 text while `strippedBody` does not.
- **Verify:** package `swift test`; both apps clean build + both repaired smokes green; **plus a scratch-corpus before/after FTS token-parity check** — `mktemp -d`, copy a few real-format fixtures, index with the old vs new extractor, assert the **same tokens are findable** (proves no search regression). No tag write moved.
- **Rollback:** `git revert` the S2 commit — restores both per-app extractors + `PDFFormatStatus`; apps green.
- **Tier:** **elevated beyond Tier-1** — it changes *what the Reader can find* over the irreplaceable corpus (read-only, but corpus-facing). Not Tier-2 (no write), but requires the before/after index-parity check above, not just build+self-review.
- **Done + docs:** `SUITE_TODO.md` S2 checkbox; update `SPEC/tag-format.md` "Where each side lives" (`:181-192`) that the parser is now shared (Core), noting the full-body/stripped-body split.

### S3 — Coordinated-write primitive + TagReading + TagEditing → Reader (write seam) — SAFETY-CRITICAL
- **Scope:** move the audited write **primitive + value types + low-level helpers only** (Reader is its author — lowest-risk relocation of write code). **`apply`/`setReadState` stay Reader** (corrected).
- **Move → Core:** `TagReading.swift`; `TagDelta`/`TagWriteResult`/`TagWriteError` + the `mutate` primitive (exposed as `CoordinatedTagWriter.write`) + `shouldRemove`/`isSameTag`/`multisetEqual`/`normalized`/`ResultBox` (`TagWrite.swift`); `TagEditing.swift`.
- **Stays Reader:** the `TagWriter` facade — `apply`/`apply(_:to:[URL])`/`setReadState` — now calling `CoordinatedTagWriter.write`. No Reader call site changes.
- **Public-surface census (enumerate member-by-member — `internal` is keyword-less so grep can't see it; #8):** `public` for `TagReading.read`/`readTags`/`TagReadResult`; `TagDelta` + **public memberwise init** (used by Reader `NavigationModel`/`InlineEditCells` + `TagEditing`); `TagWriteResult`/`TagWriteError`; `CoordinatedTagWriter.write`; `TagEditOp`/`TagEditing.delta`/`subjectDelta`/`GroupTagSummary` + **public `GroupTagSummary` init**. `normalized` handled per §write-seam.
- **Callers to update:** `import ArchiveCore` in Reader `NavigationModel`, `InlineEditCells`, `SubjectTokenField`, `RenameTagSheet`, `SimilarTagsSheet`, `TagEditorView`, `TriageNavigation` callers.
- **Update the (now-working) write-surface lint** (`lint-write-surface.sh`, repaired in S0): `setResourceValue(s)`/`setxattr` must now appear **nowhere** in `ArchiveReader/macOS/Sources` (Reader calls the package); the destructive-API ban stays; add a Core-scoped check that the write API appears only in Core's `TagWrite.swift`, and that `import SwiftUI|AppKit` never appears in `Sources/ArchiveCore`. Confirm the lint that FAILED in S0 now **passes** for Reader.
- **Move tests (placement CORRECTED — #9):** to Core — only raw-primitive tests (`CoordinatedTagWriter.write` transform, trustworthy-read→abort, verify-by-re-read, label-drift) as `TagWriterPrimitiveTests`; plus `TagEditingTests`, `SubjectTokenEditTests` whole. **Stay Reader:** delta-`apply` / color-switch / no-op-path / `setReadState` / `TriageTests`-facet tests (they call the Reader facade).
- **Verify:** package `swift test` **with strict-concurrency posture matching the apps** (S3-specific — see Package.swift note); Reader clean build + smoke; **Tier-2** — adversarial review of the moved seam (refute-verify per `REVIEW.md`) + a **scratch-corpus functional check**: `mktemp -d`, copy tagged fixtures, run Reader `apply`/`setReadState` deltas, assert **multiset+label** parity (not array-`==`) and that a simulated unreadable file **aborts** (invariant 3, `TagWriteError.unreadable`), and a no-op delta **writes nothing**. Never touch a real corpus (Reader Prime Directive; memory `archive-test-run-safety`).
- **Rollback:** `git revert` the S3 commit — restores Reader-local `TagWriter`/`TagReading`/`TagEditing` and the pre-S3 lint scope; apps green.
- **Done + docs:** `SUITE_TODO.md` S3 checkbox; Reader CLAUDE Implementation Map + Safety Protocol note that `TagWriter` now delegates to `ArchiveCore.CoordinatedTagWriter`.

### S4 — GeneratedTags vocabulary/formatting → Processor
- **Scope:** move the pure `GeneratedTags` value type (title-casing, token builders, emit order); Processor keeps the LLM class.
- **Move:** `GeneratedTags` struct + statics (`TagGenerator.swift:3-98`) → `Sources/ArchiveCore/Tags/GeneratedTags.swift`, public. `TagGenerator` class (`:100-290`) stays Processor and imports `GeneratedTags` from Core.
- ⚠️ **Add a `public init` (was omitted — #8).** `GeneratedTags` is built via its synthesized memberwise init at `TagGenerator.swift:114,115,118,173,188,190,257,260` plus `OCRProcessor+Tagging`, `LiveCaptureProcessor`, `ProcessFilesTestDriver`. Once public, that init is internal → every cross-module `GeneratedTags(subjectTags:colorTag:)` / `GeneratedTags(ocrFailed:)` / `GeneratedTags()` breaks. Add a `public init` reproducing all stored properties with **today's exact defaults** (optionals default `nil`, `dateUncertain=false`, `ocrFailed=false`, `subjectTags=[]`).
- **Callers to update:** `import ArchiveCore` in Processor `TagGenerator`, `MacOSTagger` (uses `GeneratedTags.allTags`/`.colorTag`), `OCRProcessor+Tagging`, `ManualTaggingSheet`/`ManualSegmentTagView`, live-capture tagging, `ProcessFilesTestDriver`.
- **Add tests (net-new — Processor had no test target):** `GeneratedTagsTests` golden-covers `allTags` emit-order for the OCR-failed, box/folder, and dated+subjects cases (`TagGenerator.swift:28-42`), title-casing (`:21-26`), `monthTag`/`monthNumber`/`dayNumber` (`:59-85`) — the vocabulary the parser must round-trip (`SPEC/tag-format.md:63-69,168-171`).
- **Verify:** package `swift test`; Processor clean build + smoke; Reader untouched. **No tag write moved yet** (`MacOSTagger` still writes directly) — Tier-1 + self-review, but it feeds the Tier-2 S5.
- **Rollback:** `git revert` the S4 commit — restores `GeneratedTags` in `TagGenerator.swift`; Processor green.
- **Done + docs:** `SUITE_TODO.md` S4 checkbox; Processor CLAUDE Implementation Map note.

### S5 — Processor MacOSTagger fresh-write onto the primitive (write-seam convergence) — RISKIEST, LAST
- **Scope:** re-express `MacOSTagger.applyTags` as a transform over `CoordinatedTagWriter.write`; retire Processor's direct `setResourceValue` calls (`MacOSTagger.swift:36,68,73,75`).
- **Edit:** `MacOSTagger` becomes a thin adapter (`stampUnread` lock :11-15 and `finderLabelIndex` :85-96 stay Processor; array/label computation :33-76 becomes the transform, reproducing copy-source verbatim / empty→`nil`, drop-`Unread` / dedupe-color / trailing-`Unread`, label via `finderLabelIndex` else 0). `readTags` (:19-22) delegates to `ArchiveCore.TagReading` while preserving its throwing contract.
- **Callers to update:** none in signature (adapter keeps `applyTags(_:to:)`/`applyTags(GeneratedTags:to:)`); internal rewiring only.
- **Update lint:** add a Processor write-surface lint mirroring Reader's (both using the de-nested `macOS/Sources` path from S0) — `setResourceValue(s)`/`setxattr` must appear **nowhere** in `ArchiveProcessor/macOS/Sources` (writes go through the package). Keep `PDFDocument.write` allow-listed only in `PDFGenerator.swift`/`mergeDocumentPDFs` (legitimate content-writers).
- **Verify:** package `swift test`; Processor clean build + `ArchiveProcessor/test-smoke.sh` (repaired path — real headless OCR→tag→PDF on 2 scratch images, S5's functional gate) green; **Tier-2** — adversarial review + a **scratch-corpus write-parity check** asserting **multiset(tags) + labelNumber** equality (NOT array/byte — #11) between the migrated adapter and the pre-migration `MacOSTagger` (keep the old writer available or a captured golden to diff against) over identical `mktemp -d` fixtures. Fixture matrix **must include** (#12): (a) dated+subjects, box, folder, OCR-failed; (b) an output file that **already carries tags** (retag/resume overwrite); (c) copy-source with an **empty source array** (must write **nothing**); (d) incoming-`Unread` (deduped, one trailing); (e) a **simulated unreadable target** (must **abort**, not wipe); (f) subject literally `"Red"`/`"Purple"` (never promoted). Optionally the phone↔Mac E2E (`scripts/e2e-phone-mac.sh`) if the live-capture tag path is in scope.
- **Rollback:** `git revert` the S5 commit — restores `MacOSTagger`'s direct `setResourceValue` write path + removes the Processor lint; Processor green.
- **Done + docs:** `SUITE_TODO.md` S5 checkbox; `SPEC/tag-format.md:208-209` updated — the two writers have reconciled into one audited primitive; Processor CLAUDE Safety note.

### S6 — Net-new DurableLink / RootMarker / ArchiveSuite recognition (for W1+)
- **Scope:** add the net-new value types so W1 has them; **no shipping-app behavior change** (nothing consumes them in W0). Schedulable any time after S1.
- **Add (Core):** `DurableLink` (`.readerReveal(rootGUID:relativePath:page:)` / `.notesOpen(id:block:)`, `00-overview.md` §16.2), `RootMarker` (`guid: UUID`, `name`, `kind: RootKind`, `createdAt`; JSON `.archive-suite-root.json`), `RootKind{.reader,.notes}`, an `ArchiveSuiteMarker` constant (`"ArchiveSuite"`) + a recognition helper. Sendable value types.
- ⚠️ **Explicit Codable required (#13).** Swift's default `UUID` Codable emits an **uppercase** string and default `Date` Codable emits a float `timeIntervalSinceReferenceDate`. §16.2 requires a **lowercased-UUID string** and human-readable JSON. Implement explicit `CodingKeys`/`encode(to:)`/`init(from:)` (lowercased UUID string, ISO-8601 date) so the round-trip the tests assert actually holds.
- **Tests (net-new):** `DurableLinkTests` — URL parse/format round-trip for both schemes, `RootMarker` Codable round-trip (assert **lowercased**-UUID string + ISO-8601 date in the emitted JSON), marker recognition incl. the collision case (a subject literally `"ArchiveSuite"`).
- **Verify:** package `swift test`; both apps clean build (they don't reference the new types — proves no accidental coupling). Tier-1.
- **Rollback:** `git revert` the S6 commit — removes the net-new files; nothing else references them.
- **Done + docs:** `SUITE_TODO.md` S6 checkbox; note in `00-overview.md`/Notes plan that ArchiveCore ships these.

---

## Parity & test strategy

- **Baseline first (S0).** Record the true pre-migration Reader test count and green smokes **only after S0 repairs the smoke/lint paths** — the pre-S0 "green" was against stale trees and is not a valid baseline.
- **Move Reader tag/facet tests into `ArchiveCoreTests`** per the CORRECTED placement (S1/S3/S2/S4): whole moves = `DocumentTagsTests`, `TagEditingTests`, `SubjectTokenEditTests`, `PDFFormatStatusTests`; **subset move** = only raw-primitive tests from `TagWriterTests` (delta/`apply`/`setReadState`/`TriageTests`-facet **stay Reader**). They run via `swift test` in the package (wired into `./test-smoke.sh archivecore`/`all`). **No test is deleted** — total across `ArchiveCoreTests` + `ArchiveReaderTests` + Processor smoke ≥ today's ~186-191.
- **Keep both app suites green each session.** After every Sn: Reader scheme tests (`xcodebuild test`) + Processor smoke + package `swift test` all pass; **zero new warnings** (gate on a warnings delta via a **clean** build — beware a cached "0 warnings" masking pre-existing ones, per Processor CLAUDE's refactor note).
- **Golden byte checks where the SPEC pins format:** the page-2 header (`SPEC/tag-format.md:116-140`) via `PDFHeaderParserTests` incl. full-vs-stripped body + unknown-classification cases (S2); `GeneratedTags.allTags` emit order + title-casing (`SPEC/tag-format.md:63-69,168-171`) via `GeneratedTagsTests` (S4); `sortDate`/decade formula (`:82-92`) covered by the moved `DocumentTagsTests`.
- **FTS parity harness (S2):** old-vs-new extractor over identical `mktemp -d` fixtures; assert the same tokens findable (guards against the Reader-search regression #4/#5).
- **Write-parity harness (S3/S5):** pre- vs post-migration writer over identical `mktemp -d` scratch fixtures; assert identical resulting tag **multiset + labelNumber** (macOS reorders → compare as multisets, `SPEC/tag-format.md:35`) — **never array-`==`**. Cover the adversarial matrix (unreadable→abort, no-op→no write, retag-overwrite, empty-copy-source, `"ArchiveSuite"`/`"Red"` subject).
- **Scratch-corpus safety protocol (non-negotiable):** every tag-write/index test copies fixtures into `mktemp -d` first and deletes on exit; **never** the owner's corpus (Reader Prime Directive; memory `archive-test-run-safety`; `SPEC/tag-format.md:205-207`).

---

## Risks & rollback

**Per-sub-task revert:** each Sn is one commit (code + moved tests + docs together); revert = `git revert` that commit (rollback lines are stated per-Sn above). Because every Sn leaves all apps green, a revert never leaves a half-migrated tree. Do NOT batch two Sn in one commit.

**Ways a "behavior-preserving move" can SILENTLY change behavior — and the catch for each:**
- **Stale-tree / vacuous-gate (the biggest one).** The lint greps a non-existent path and both smokes build a stale pre-de-nest copy — a green run proves nothing. *Catch:* **S0** repairs all three and proves the lint now *fails* on the current tree before it can pass post-move.
- **Reader full-text search regression.** Adopting Processor's header-stripped page-2-only body would drop the header text + all page-1 text-layer content from the FTS index. *Catch:* the unified `ExtractedContent` keeps a `fullBody` all-pages view for the index; S2's before/after FTS token-parity harness.
- **Access-control drift.** Cross-module moves force `public`; a public struct's synthesized memberwise init is **internal**, so `DocumentTags(...)`/`TagDelta(...)`/`GroupTagSummary(...)`/`GeneratedTags(...)` construction silently fails to compile — and `Month`/`ArchiveColor.tokenName`/`.labelNumber`/`init?(labelNumber:)` are read cross-module. *Catch:* build failure is loud; the **member-by-member public-surface census** in S1/S3/S4 with explicit `public init`s at today's exact parameter order/defaults.
- **`normalized` two-module need.** Used by both the moved `TagWriteResult.isNoOp` and the Reader-resident `apply`. *Catch:* named explicitly in S3 (internal Core helper + Reader-facade access) — else S3 fails to compile.
- **`NSFileCoordinator` options.** The primitive **must** stay `.contentIndependentMetadataOnly` (`:144`), never `.forReplacing`. *Catch:* adversarial review reads the exact option; a scratch test asserts the data-fork is unchanged.
- **Processor gaining coordination/verify + read-before-write (S5).** A real path change (abort-on-unreadable, write-label-only-when-changed) not "free" defense-in-depth; verify could reject a macOS-reordered write, and copy-source-empty must still write nothing. *Catch:* multiset-equality verify (`:180,233`); the S5 fixture matrix incl. retag-overwrite/empty-copy-source/unreadable.
- **Byte-vs-multiset parity trap.** Reader appends after existing; Processor builds `[color]+text+[Unread]`; macOS reorders. *Catch:* all parity assertions are multiset+label, never array-`==` (prose aligned across §write-seam, S3, S5, §Parity).
- **`Sendable` / strict-concurrency in the package.** `mutate` captures non-`Sendable` `ResultBox`; the package may apply stricter defaults than the app targets. *Catch:* S3 builds the package with the apps' strict-concurrency posture; `ResultBox` stays file-private; no `@Sendable` added to the synchronous non-escaping `transform`; **no `nonisolated(unsafe)` added** (no mutable statics move — state this so a session doesn't add annotations).
- **Classification enum leakage.** The shared parser must NOT drag Processor's persisted `DocumentClassification` rawValues (`:202-204`) into Core. *Catch:* Core returns a **string**; the Processor shim maps only the 4 `displayName`s, else nil (S2).
- **`RootMarker` Codable red test (S6).** Default `UUID`/`Date` Codable won't produce lowercased-UUID/ISO-8601. *Catch:* explicit `CodingKeys`/`encode`/`init(from:)` in S6; net-new so no shipping-app risk.
- **Test-runner gap.** Moved tests silently stop running if `swift test` isn't wired into the dispatcher. *Catch:* S1 adds `./test-smoke.sh archivecore` and asserts the moved-test count appears there.
- **Lint blind spot.** After S3/S5 the write API lives in the package; the old app-scoped lint would miss an illicit write in Core. *Catch:* extend the (repaired) lint to scan `Sources/ArchiveCore` + both apps' `macOS/Sources` (S3, S5).

---

## Docs to update in W0

- **Both apps' `CLAUDE.md` Implementation Maps:** note the `Core/` tag/PDF/date types (Reader) and `Tagging/GeneratedTags` + `MacOSTagger` (adapter) + PDF extractor (Processor) now live in / delegate to `ArchiveCore`; Reader's Safety Protocol notes `TagWriter` delegates to `ArchiveCore.CoordinatedTagWriter` (the single choke-point is now the package's primitive).
- **`AGENTS.md`:** add an **ownership lane** for `packages/ArchiveCore` (the shared contract — coordinated, Tier-2) and add it to **shared hotspots** alongside the `project.yml` files (now **three** build surfaces) and `SPEC/tag-format.md`. Also record the de-nested smoke/lint paths from S0.
- **`ArchiveProcessor/CLAUDE.md` shared-hotspots list** currently ends at "the two `project.yml` files" — update to **three build surfaces plus the new `packages/ArchiveCore` lane**, and reflect the `MacOSTagger`/`GeneratedTags` adapter split (not a wholesale move).
- **Doc-sync backstop:** `.claude/.docsync-ok` shows as **deleted** in git status — confirm the doc-sync hook (`.claude/hooks/`) still fires for a package that lives **outside** both app dirs (`packages/`), so an overnight run's S1–S6 checkbox flips are enforced; fix the hook's scope if it only watches the two app trees.
- **`SPEC/tag-format.md`:** update the closing note (`:208-209`) from "When Archive Suite extracts…" (future) to "**Implemented in `ArchiveCore`** — `MacOSTagger` and `TagWriter` reconcile into one audited primitive (`CoordinatedTagWriter`); this file is that package's contract doc"; update "Where each side lives" (`:181-192`) to point at ArchiveCore for the shared rows — verifying the Processor rows (`GeneratedTags`, `MacOSTagger`) reflect the **adapter split**, not a wholesale move, and that the parser row notes the full-body/stripped-body split.
- **`SUITE_TODO.md`** (tracker of record): replace the deferred line at `:219` ("`ArchiveCore` shared-package extraction moved to POTENTIAL_FEATURES — deferred") with the live W0 item + **S0..S6** checkboxes; flip each in the **same commit** as its code; delete this plan file only when W0 fully ships (git keeps history), per `00-overview.md` §14.
- **`ArchiveProcessor/POTENTIAL_FEATURES.md`:** remove the deferred ArchiveCore wish (now realized); leave the shared-storage-path item.

---

## Open questions (non-blocking)

1. **Package tests vs app scheme.** W0 runs moved tests via `swift test` (package) + a new dispatcher step, leaving the app schemes running only app-resident tests. Acceptable, or does the owner want the package tests also surfaced under a single `xcodebuild test` (would require an aggregate test target)? Recommend the `swift test` split — simpler, faster, and it is what CI-less overnight runs already do per subsystem.
2. **Page-2 header builder unification.** W0 unifies only the *parser*; `PDFGenerator.makeTextPage` (`OCR/PDFGenerator.swift:207-225`) keeps composing the header. A follow-on could extract a shared `PageTwoHeader.build/parse` pair so compose and parse can never drift — deferred to avoid touching the CoreText writer in a parity wave. Promote if the owner wants the builder shared now.
3. **Reader `FileLink` vs net-new `DurableLink`.** Confirmed as separate concerns (Reader clipboard formatter vs the `archivereader://` scheme). Recommendation: `FileLink` stays Reader (a Reader feature, not the shared contract) even though it is UI-free. Confirm.
4. **Processor write-surface lint (S5).** Confirm `PDFDocument.write` should be allow-listed only in `PDFGenerator.swift`/`mergeDocumentPDFs` (legitimate content writers) and banned elsewhere.
5. **`finderLabelIndex` breadth.** Processor maps 7 Finder colors (`MacOSTagger.swift:85-96`) though only Red/Purple are suite-meaningful. Recommend leaving the full 7-color map in the Processor adapter (behavior-preserving) and keeping `ArchiveColor` box/folder-only in Core. Confirm.
6. **Stale-tree deletion (S0).** S0 deletes the gitignored `ArchiveReader/ArchiveReader/` and `ArchiveProcessor/ArchiveProcessor/` trees. Confirm nothing outside the repo (a personal script, Spotlight index, editor workspace) points at those paths before deletion — recommend proceeding (0 git-tracked files in either).
