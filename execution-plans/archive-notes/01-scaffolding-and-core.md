# Archive Notes — W1: Third-app scaffold, ArchiveCore package, and app skeleton
> Status: PROPOSED · part of Archive Notes (see 00-overview.md) · Wave 1

> ⚠️ **Canonical shared types & cross-wave APIs are defined in `00-overview.md` §16 (Interface Contract).** Where a sketch in this file differs — store type/name (`actor NoteStore` + `@MainActor NotesModel`/`OrganizationStore`), `DurableLink`/`RootMarker`, the single `NotesFilter` type, template-assignments-only, the index `items` projection, the `archivenotes://open?id=` grammar — **the overview is authoritative.**


> 🔄 **SUPERSEDED IN PART BY W0 (`00a-archivecore-refactor.md`).** The owner moved the **full ArchiveCore
> extraction + Reader/Processor migration** into **W0, done FIRST**. So `packages/ArchiveCore/` **already exists
> and is battle-tested** before W1 starts, and the `ArchiveSuite` marker recognition + the `SPEC/tag-format.md`
> delta land in **W0**, not here. W1 therefore reduces to: add the `ArchiveNotes/` app + scaffold + 3-pane
> skeleton that **depends on the existing ArchiveCore**, plus the root-dispatcher/DMG/docs wiring for the new
> app. Wherever this file below describes *creating/seeding* ArchiveCore or *editing the SPEC*, that is **W0's
> job** — kept here as reference for what the Notes app consumes. **W1 now depends on W0.**

## Goal
Stand up `ArchiveNotes/` as a clean third macOS app in the monorepo — mirroring the Reader's structure, XcodeGen conventions, launch/bootstrap/test-smoke scripts, root dispatcher arms, and combined-DMG packaging — and create the repo's first Swift package, `packages/ArchiveCore/` (read-side only, per 00-overview §10), seeded byte-for-byte from Reader's tested `DocumentTags`/`PDFTextExtractor` plus net-new `RootMarker`/`DurableLink`/`SuiteMarker` types. The deliverable is a buildable, launchable app skeleton: an empty 3-pane shell (Notes window + Extracts window + Settings) that links against `ArchiveCore`, builds with no new warnings, and opens via `./launch.sh notes`. No storage, editor, index, linking, or Zotero yet — those are W2–W7. This wave also lands the additive `ArchiveSuite` membership marker into `SPEC/tag-format.md` (Tier-2 coordinated change, no corpus back-fill per D4).

## Dependencies
None — W1 is the root of the dependency graph (00-overview §13). Every later wave depends on W1: W2 (storage/index) needs the app target + `ArchiveCore`; W3 (editor) needs the app shell; W4 (linking) needs `DurableLink`/`RootMarker` and the URL-scheme groundwork; W5–W8 build on all of the above. Within W1, sub-task ordering is S1 → S2 (app links the package) and S3 extends S1; S4/S5 (wiring + docs/SPEC) can follow once S2 launches.

## Design

### 0. Confirmed ground truth (verified against the repo, 2026-07-10)
- **No SwiftPM package exists anywhere** — `find . -name Package.swift` returns nothing; there is no `packages/` directory. All code is in-app today. `packages/ArchiveCore/` is **NEW**.
- Both `project.yml`s use `options.bundleIdPrefix`, `options.deploymentTarget.macOS: "14.0"`, `options.xcodeVersion: "16"`, `options.generateEmptyDirectories: true`; `settings.base` sets `SWIFT_VERSION: "6.0"`, `MACOSX_DEPLOYMENT_TARGET: "14.0"`, `ENABLE_HARDENED_RUNTIME: YES` (`ArchiveReader/macOS/project.yml:1-13`).
- Reader entitlements = `app-sandbox` + `files.user-selected.read-write` + `files.bookmarks.app-scope` (`ArchiveReader/macOS/Sources/ArchiveReader/ArchiveReader.entitlements:5-10`). Processor adds `network.client` (`ArchiveProcessor/macOS/project.yml:31-33`) — Notes needs both sets.
- `PanelDivider` **does** exist, as a `private struct` in `ArchiveReader/macOS/Sources/ArchiveReader/Views/NavigationWindowView.swift:460-491` — a self-contained draggable divider (`@Binding var width`, `panelOnLeft`, `range`). Because it is `private`, it must be **copied** into Notes, not imported.
- Reader ships an `Assets.xcassets/AppIcon.appiconset` with a full 10-image icon set (`ArchiveReader/macOS/Sources/ArchiveReader/Assets.xcassets/AppIcon.appiconset/`). `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` requires a populated set or Xcode warns — relevant to the "no new warnings" gate.
- **Inner-dir naming caveat (resolve now):** `launch.sh` uses `APPDIR="macOS"` (`ArchiveReader/launch.sh:13`) but `ArchiveReader/test-smoke.sh:16` still hardcodes the stale pre-de-nesting path `PROJ="$ROOT/ArchiveReader"`. The de-nested inner project dir is `macOS/`. **Decision: Notes uses `macOS/` consistently in *all three* scripts.** (Reader's stale line is a pre-existing bug; not fixed here — Reader is untouched this run per §10 — recorded in Open questions.)

### 1. Directory layout (NEW — mirrors Reader)
```
ArchiveNotes/
  CLAUDE.md            # app guide + Implementation Map stub (S5)
  README.md            # short app README (S5)
  AGENTS.md            # app-local lanes/hotspots (S5)
  .gitignore           # copy of ArchiveReader/.gitignore (build/, *.xcodeproj/, .maintenance/, index caches)
  bootstrap.sh         # copy of ArchiveReader/bootstrap.sh (generic: finds any project.yml)
  launch.sh            # copy of ArchiveReader/launch.sh with App name → ArchiveNotes, APPDIR="macOS"
  test-smoke.sh        # copy of ArchiveReader/test-smoke.sh with PROJ="$ROOT/macOS" (caveat fix)
  macOS/
    project.yml        # authoritative XcodeGen manifest (§2)
    Sources/ArchiveNotes/
      ArchiveNotesApp.swift        # @main; 3 scenes (Notes Window, Extracts Window, Settings)
      Info.plist
      ArchiveNotes.entitlements
      Assets.xcassets/AppIcon.appiconset/…   # placeholder icon (copy Reader's to avoid the empty-icon warning)
      Views/
        NotesShellView.swift       # the empty 3-pane shell (HStack + PanelDivider)
        PanelDivider.swift         # copied from Reader (made internal)
        NotesSettingsView.swift    # empty Settings form
    Tests/ArchiveNotesTests/
      SmokePlaceholderTests.swift  # one trivial test so `xcodebuild test` has a suite (real suites in W2+/W8)
packages/
  ArchiveCore/
    Package.swift
    Sources/ArchiveCore/
      DocumentTags.swift           # seeded from Reader (§4)
      PDFTextExtractor.swift       # seeded from Reader (§4)
      RootMarker.swift             # NEW (§4.3)
      DurableLink.swift            # NEW (§4.3)
      SuiteMarker.swift            # NEW (§4.3)
    Tests/ArchiveCoreTests/
      DocumentTagsTests.swift      # seeded from Reader (§4)
      DurableLinkTests.swift       # NEW (§4.3)
      RootMarkerTests.swift        # NEW (§4.3)
      SuiteMarkerTests.swift       # NEW (§4.3)
```

### 2. `ArchiveNotes/macOS/project.yml` (NEW — concrete)
Modeled on `ArchiveReader/macOS/project.yml:1-63`, adding the SwiftPM package reference (Reader's has none) and `network.client`:
```yaml
name: ArchiveNotes
options:
  bundleIdPrefix: com.archivenotes
  deploymentTarget:
    macOS: "14.0"
  xcodeVersion: "16"
  generateEmptyDirectories: true

settings:
  base:
    SWIFT_VERSION: "6.0"
    MACOSX_DEPLOYMENT_TARGET: "14.0"
    ENABLE_HARDENED_RUNTIME: YES

packages:
  ArchiveCore:
    # Local path is relative to THIS project.yml (…/ArchiveNotes/macOS): up two to repo root, then packages/.
    path: ../../packages/ArchiveCore

targets:
  ArchiveNotes:
    type: application
    platform: macOS
    sources:
      - Sources/ArchiveNotes
    dependencies:
      - package: ArchiveCore
        product: ArchiveCore
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.archivenotes.app
        INFOPLIST_FILE: Sources/ArchiveNotes/Info.plist
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGNING_REQUIRED: NO
        SWIFT_VERSION: "6.0"
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
    entitlements:
      path: Sources/ArchiveNotes/ArchiveNotes.entitlements
      properties:
        com.apple.security.app-sandbox: true
        com.apple.security.files.user-selected.read-write: true
        com.apple.security.files.bookmarks.app-scope: true
        com.apple.security.network.client: true   # Zotero localhost HTTP (D8/D10) — Notes-only vs Reader

  ArchiveNotesTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - Tests/ArchiveNotesTests
    dependencies:
      - target: ArchiveNotes
    settings:
      base:
        SWIFT_VERSION: "6.0"
        GENERATE_INFOPLIST_FILE: YES
        PRODUCT_BUNDLE_IDENTIFIER: com.archivenotes.tests

schemes:
  ArchiveNotes:
    build:
      targets:
        ArchiveNotes: all
        ArchiveNotesTests: [test]
    run:
      config: Debug
    test:
      config: Debug
      targets:
        - ArchiveNotesTests
```
**Edge case — XcodeGen local package + `bundleIdPrefix`:** XcodeGen resolves the local package at `xcodegen generate` time and adds it as a project package reference + product dependency; verify the generated `.xcodeproj` links `ArchiveCore` (target → Frameworks) after generate. Because entitlements enable App Sandbox, the linked package must be pure Swift with no disallowed API — `ArchiveCore` is UI-free (`Foundation`/`PDFKit` only), which the sandbox permits.

`Info.plist` (**NEW**, from `ArchiveReader/.../Info.plist:1-26`): change `CFBundleName`/`CFBundleDisplayName` → `Archive Notes`; keep `CFBundleIdentifier=$(PRODUCT_BUNDLE_IDENTIFIER)`, `LSMinimumSystemVersion=$(MACOSX_DEPLOYMENT_TARGET)`, `LSApplicationCategoryType=public.app-category.productivity`. **No `CFBundleURLTypes` in W1** — the `archivenotes://` scheme registration lands in W4 (00-overview §8.4).

`ArchiveNotes.entitlements` (**NEW**, from `ArchiveReader.entitlements:1-13`) — the same three keys plus `com.apple.security.network.client`.

### 3. App skeleton (NEW)
`ArchiveNotesApp.swift` — mirrors `ArchiveReaderApp.swift:12-47` (two `Window` scenes + `Settings`), but with a Notes window and an Extracts window (D10 — "own 3-pane windows"):
```swift
import SwiftUI
import ArchiveCore   // proves the package links; symbol used below

@main
struct ArchiveNotesApp: App {
    var body: some Scene {
        Window("Archive Notes", id: NotesWindowID.notes) {
            NotesShellView(kind: .note)
        }
        Window("Extracts", id: NotesWindowID.extracts) {
            NotesShellView(kind: .extract)
        }
        Settings { NotesSettingsView() }
    }
}

enum NotesWindowID { static let notes = "notes"; static let extracts = "extracts" }

/// Item kind the shell is scoped to (mirrors 00-overview §3.1 `kind`). Placeholder until W2 defines the store.
enum ItemKindShell: Sendable { case note, extract }
```
`NotesShellView.swift` — the empty 3-pane shell using the **copied** `PanelDivider` (genuine reuse of Reader's exact interaction), matching Reader's `HStack`+`PanelDivider` composition (`NavigationWindowView.swift:24,32`):
```swift
import SwiftUI
import ArchiveCore

struct NotesShellView: View {
    let kind: ItemKindShell
    @State private var sidebarWidth = 220.0
    @State private var detailWidth  = 360.0

    var body: some View {
        HStack(spacing: 0) {
            SidebarPane(kind: kind).frame(width: sidebarWidth)
            PanelDivider(width: $sidebarWidth, panelOnLeft: true,  range: 160...360)
            ItemListPane(kind: kind).frame(maxWidth: .infinity, maxHeight: .infinity)
            PanelDivider(width: $detailWidth, panelOnLeft: false, range: 260...560)
            DetailPane(kind: kind).frame(width: detailWidth)
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}

// Empty placeholder panes (filled in W2/W3/W6). Each just labels itself.
private struct SidebarPane:  View { let kind: ItemKindShell; var body: some View { placeholder("Folders") } }
private struct ItemListPane: View { let kind: ItemKindShell; var body: some View { placeholder("Items") } }
private struct DetailPane:   View {
    let kind: ItemKindShell
    var body: some View {
        VStack {
            placeholder(kind == .note ? "Note" : "Extract")
            // Uses an ArchiveCore symbol so the dependency is exercised at compile+link time.
            Text("Suite marker: \(SuiteMarker.token)").font(.footnote).foregroundStyle(.secondary)
        }
    }
}
private func placeholder(_ t: String) -> some View {
    ZStack { Color(nsColor: .textBackgroundColor); Text(t).foregroundStyle(.tertiary) }
}
```
`PanelDivider.swift` — copy `NavigationWindowView.swift:459-491` verbatim, change `private struct` → `struct` (file-scoped `internal`) so both windows share it. `NotesSettingsView.swift` — an empty `Form { Text("Settings — coming in W6") }` so ⌘, opens.

**Concurrency (Swift 6):** SwiftUI `App`/`View`/`Scene` are `@MainActor`-isolated by default; the shell holds only `@State` primitives — no `Sendable` obligations. `ArchiveCore`'s public types are all `Sendable` value types (§4). No actors, no `@unchecked`.

### 4. `ArchiveCore` package (NEW — read-side only, 00-overview §10)
`Package.swift` (**NEW**, first package in the repo):
```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ArchiveCore",
    platforms: [.macOS(.v14)],
    products: [ .library(name: "ArchiveCore", targets: ["ArchiveCore"]) ],
    targets: [
        .target(name: "ArchiveCore"),
        .testTarget(name: "ArchiveCoreTests", dependencies: ["ArchiveCore"]),
    ]
)
```
Swift-tools 6.0 ⇒ the package builds under Swift 6 strict concurrency, matching both apps.

**4.1 `DocumentTags.swift` (SEEDED)** — copy `ArchiveReader/.../Core/DocumentTags.swift:1-259` verbatim, then perform the **only** required change for a package API: add `public` to the types and members Notes/tests consume — `public enum ReadState`, `public enum ArchiveColor`, `public struct DocumentTags` + all its stored properties and computed vars (`sortDate`, `displayDate`, `topicalTags`, `dateIsSpeculative`), the `public static func parse(raw:labelNumber:)`, and the `public static` parse helpers (`parseYear`/`parseMonth`/`parseDay`/`parseDecade`/`parsePriority`/`isDateFacetLike`/`monthNames`). The nested `Month` struct and enum cases become `public`; add a `public init` to `DocumentTags` if the memberwise init is used cross-module (it is, inside `parse`, but `parse` returns it in-module — still, mark the memberwise init `public` for future callers). No logic changes — this is the byte-for-byte parser the SPEC blesses (00-overview §10a).

**4.2 `PDFTextExtractor.swift` (SEEDED)** — copy `ArchiveReader/.../Search/PDFTextExtractor.swift:1-39` verbatim; make `public struct ExtractedContent` (+ its stored fields + a `public init`), `public enum PDFTextExtractor`, and `public static func extract(_:)`/`parseClassification(from:)`. It imports `PDFKit` — allowed in a macOS package.

**4.3 New read-side types (NET-NEW — do not exist in the repo today):**

`SuiteMarker.swift` — the `ArchiveSuite` membership-marker recognizer (00-overview §5/§9, SPEC delta S5):
```swift
public enum SuiteMarker {
    /// The exact Finder-tag token that marks Archive-Suite membership (SPEC delta). Title-cased, one word.
    public static let token = "ArchiveSuite"
    /// Exact whole-string, case-insensitive match (mirrors Reader's Read/Unread matching discipline).
    public static func isMarker(_ tag: String) -> Bool {
        tag.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(token) == .orderedSame
    }
}
```
Note it deliberately does **not** touch `DocumentTags.parse` — the marker degrades to an ordinary subject in any parser that doesn't know it (graceful degradation; SPEC parse-order note in S5). A subject literally equal to `ArchiveSuite` is indistinguishable and acceptable because the W2 `NotesTagProjector` only ever adds/removes it idempotently as a managed token.

`RootMarker.swift` — portable root identity (00-overview §3.8/§8.1). **W1 defines the type + pure JSON codec only; no file I/O** (dropping the file at a granted root is a write and belongs to W2/W4 through an audited path):
```swift
public struct RootMarker: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case reader, notes }
    public let guid: UUID
    public let name: String
    public let createdAt: Date
    public let kind: Kind
    public static let fileName = ".archive-suite-root.json"

    public init(guid: UUID = UUID(), name: String, createdAt: Date = Date(), kind: Kind) {
        self.guid = guid; self.name = name; self.createdAt = createdAt; self.kind = kind
    }
    public static func decode(_ data: Data) throws -> RootMarker {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try d.decode(RootMarker.self, from: data)
    }
    public func encoded() throws -> Data {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }
}
```

`DurableLink.swift` — the two URL forms (00-overview §8.2), pure parse/render, no resolution (resolution is W4):
```swift
public enum DurableLink: Sendable, Equatable {
    /// archivereader://reveal?root=<GUID>&rel=<url-encoded relative path>&page=<optional int>
    case readerReveal(rootGUID: UUID, relativePath: String, page: Int?)
    /// archivenotes://open?id=<UUID>[#block-<n>]
    case notesOpen(id: UUID, block: Int?)

    public var url: URL { … }            // renders the canonical URL (percent-encodes rel; adds #block-n)
    public init?(url: URL) { … }         // tolerant parser: unknown scheme/host/params → nil (never crashes)
}
```
Design notes for `init?(url:)`: switch on `url.scheme` (`archivereader`/`archivenotes`) and `url.host` (`reveal`/`open`); read `URLComponents.queryItems`; percent-decode `rel`; parse `page`/`block` as optional `Int` (ignore malformed → nil, don't fail the whole link). Rendering uses `URLComponents` with `percentEncodedQueryItems` so `rel` (which contains `/`, spaces, the corpus's em-dash U+2014 and NBSP U+00A0 — see Reader Verified Facts) round-trips exactly. **Edge cases:** empty `rel`, `page=0`, non-numeric `page`, extra unknown query keys (preserve-and-ignore), a `rel` containing `#`/`?`. All are unit-tested (§Tests). This mirrors the SPEC's "consumers must degrade, never assume structure" ethos.

**4.4 Tests (SEEDED + NEW):** copy `ArchiveReader/.../Tests/ArchiveReaderTests/DocumentTagsTests.swift` into `ArchiveCoreTests/`, changing `@testable import ArchiveReader` → `import ArchiveCore` (types are now `public`; no `@testable` needed). Add `RootMarkerTests`, `DurableLinkTests`, `SuiteMarkerTests` (§Tests).

**What is NOT migrated (00-overview §10):** Reader and Processor keep their own `DocumentTags`/`PDFTextExtractor`/`TagWriter` copies this run. `TagWriter` (write path) is **not** placed in `ArchiveCore` — Notes gets its own `NotesTagProjector` in W2. Convergence is a later, separately-gated wave.

### 5. Scripts & suite wiring (S4)
- **`ArchiveNotes/launch.sh`** (from `ArchiveReader/launch.sh:1-58`): `APPDIR="macOS"`, `APP="$APPDIR/build/DD/Build/Products/Debug/ArchiveNotes.app"`, `EXE=".../ArchiveNotes"`, scheme `ArchiveNotes`, `pgrep -x ArchiveNotes`, build log `/tmp/an-launch-build.log`. Same build-if-stale + relaunch-if-stale logic; per-worktree `-derivedDataPath ./build/DD`.
- **`ArchiveNotes/bootstrap.sh`**: copy `ArchiveReader/bootstrap.sh` verbatim — it is generic (finds every `project.yml` under the dir and runs `xcodegen generate`), so it needs no edits beyond the trailing "open" hint (`open macOS/ArchiveNotes.xcodeproj`).
- **`ArchiveNotes/test-smoke.sh`** (from `ArchiveReader/test-smoke.sh:1-39`) **with the caveat fixed**: `ROOT="$(cd "$(dirname "$0")" && pwd)"` (= `…/ArchiveNotes`) and **`PROJ="$ROOT/macOS"`** (not `$ROOT/ArchiveNotes`), scheme `ArchiveNotes`, log prefix `smoke-notes-`. Runs `xcodegen generate && xcodebuild test -scheme ArchiveNotes -destination 'platform=macOS' -derivedDataPath ./build/DD`.
- **Root `launch.sh`** (`launch.sh:11-20`): add a case arm before the `*)` default:
  ```bash
  notes|n|ArchiveNotes)          dir="ArchiveNotes" ;;
  ```
  and add `notes → Archive Notes (write · link · extract)` to the usage text.
- **Root `test-smoke.sh`** (`test-smoke.sh:15-28`): add `run_notes(){ echo "──────── Archive Notes ────────"; bash "./ArchiveNotes/test-smoke.sh"; }`, a `notes|n|ArchiveNotes) run_notes ;;` case, and include `run_notes || rc=1` in the `all` arm (Notes is free/no-network like Reader — put it right after `run_reader`, before the paid `run_processor`).
- **`release/build-suite-dmg.sh`** (`:23-26`): add to `APPS`:
  ```bash
  "ArchiveNotes/macOS:ArchiveNotes:ArchiveNotes.app"
  ```
  The build/stage loops already iterate `APPS`, so build + staging need no other change. **Hand-edit the osascript Finder layout** (`:70-90`) — three apps + `Applications` now:
  - widen the window: `set the bounds of container window to {200, 120, 960, 520}` (760-wide content);
  - re-position: `ArchiveProcessor.app → {150, 230}`, `ArchiveReader.app → {300, 230}`, `ArchiveNotes.app → {450, 230}`, `Applications → {640, 230}`.
- **`release/make-dmg-background.swift`**: bump `W` from 640 to 760; change the subtitle to `"Drag all three apps into the Applications folder"`; move the arrow to originate right of the third icon (e.g. `x0 = 500, x1 = 596`, `midY = H/2 - 6`); re-render with `swift release/make-dmg-background.swift release/dmg-background.png`. The regenerated PNG is committed (it's not a `.dmg`, so not gitignored). GUI-verify the icon/arrow alignment against the osascript positions.

### 6. SPEC delta (S5 — Tier-2 coordinated, additive, no back-fill per D4)
Add a new section to `SPEC/tag-format.md` (after "Tag facets"), and a row to the facet table. **Exact proposed text:**

> ### Suite membership marker (`ArchiveSuite`)
> A single optional Finder-tag token, exact string **`ArchiveSuite`** (one word, that capitalization), marks a file as belonging to the Archive Suite. **In run 1 it is written only by Archive Notes, onto its own `.md` files**, through the audited `NotesTagProjector` (Notes CLAUDE §Finder-tag mirror); it is regenerable from front-matter and never source-of-truth.
> - **Class:** it is a *Subject-class literal*, not a dedicated facet — it has no parsed field. Parsers that do not know it **MUST** treat it as an ordinary subject (graceful degradation), exactly as they treat any other free-form token.
> - **Cardinality:** 0–1. Matched **exact whole-string, case-insensitive**, like `Read`/`Unread`.
> - **Parse order:** immaterial. Because it is a plain literal with no digits, it can never collide with the Year/Month/Day/Decade/Priority tests; it falls through to `subjects` in `DocumentTags.parse`. A subject *literally* equal to `ArchiveSuite` is indistinguishable from the marker — acceptable, because the only writer (`NotesTagProjector`) treats it idempotently and only ever adds/removes it as a managed token.
> - **Deferred (not in run 1):** Processor stamping `ArchiveSuite` on new output, Reader parsing/hiding it, and any corpus back-fill (Archive Notes 00-overview §2). Until then the corpus carries no `ArchiveSuite` token and no existing app behavior changes.

Add to the facet table (SPEC line ~70): `| **Suite marker** | literal `ArchiveSuite` | 0–1 | Additive; written only by Archive Notes on its own files in run 1. Consumers treat as a subject. |` Update "Divergence risk & change protocol" to note this addition is **additive and read-only for Reader/Processor in run 1** (no writer/parser change required on either shipping app), which is why it lands without touching their code — recorded as the intended relaxation of the usual three-way rule for this specific additive marker.

### 7. Docs (S5)
- **Root `AGENTS.md`**: add a `notes` ownership lane (`ArchiveNotes/ — note/extract store, editor, index, cross-app linking, Zotero`) to the table (`AGENTS.md:28-34`); add `packages/ArchiveCore/` and `ArchiveNotes/macOS/project.yml` to "Shared hotspots" (ArchiveCore is now a cross-app surface even though only Notes consumes it in run 1).
- **Root `CLAUDE.md`**: add `ArchiveNotes/` and `packages/ArchiveCore/` to the Repo map; add a one-line Archive Notes mention to the Releasing section (the combined DMG now stages three apps).
- **`ArchiveNotes/CLAUDE.md`** (NEW stub) with a Core-Directive pointer (file-safety = write only Notes' own store + `NotesTagProjector` invariants, never the corpus), a Stack & Build section (XcodeGen, `ArchiveCore` dependency, `./launch.sh notes`, `./test-smoke.sh notes`), and an **Implementation Map** seeded now and grown per wave:
  ```
  macOS/Sources/ArchiveNotes/
    ArchiveNotesApp.swift     @main; Notes + Extracts windows + Settings.
    Views/NotesShellView.swift  Empty 3-pane shell (HStack + PanelDivider).
    Views/PanelDivider.swift    Draggable divider (copied from Reader).
  packages/ArchiveCore/         Shared read-side contract (DocumentTags, PDFTextExtractor,
                                RootMarker, DurableLink, SuiteMarker) — Notes-only in run 1.
  ```
- **`SUITE_TODO.md`**: add an "Archive Notes" section under "Active execution plans" that indexes `execution-plans/archive-notes/00-overview.md` + `01`–`08`, with a W1 checklist (S1–S5 boxes) to flip as each sub-task ships.

### File-safety notes
The **only writes W1 introduces to disk** are: (a) new source files inside `ArchiveNotes/`/`packages/`, (b) the committed regenerated `release/dmg-background.png`, and (c) a *committed* docs/SPEC edit. `RootMarker` and `DurableLink` define types + pure codecs — **no filesystem writes**, no corpus access. The app skeleton reads/writes nothing (empty panes). `NotesTagProjector`, `.archive-suite-root.json` file drops, and any store I/O are **out of scope** (W2/W4). Nothing in W1 touches the Reader/Processor corpus.

## Reuse from the existing codebase
- **`ArchiveReader/macOS/Sources/ArchiveReader/Core/DocumentTags.swift:1-259`** — seed the entire parser/facet model + `sortDate`/`displayDate` into `ArchiveCore`; add `public`. Already UI-free and `Sendable` (its own header comment at :9-10 says it is package-ready for ArchiveCore convergence).
- **`ArchiveReader/macOS/Sources/ArchiveReader/Search/PDFTextExtractor.swift:1-39`** — seed verbatim; add `public`.
- **`ArchiveReader/macOS/Tests/ArchiveReaderTests/DocumentTagsTests.swift`** — seed into `ArchiveCoreTests`; swap `@testable import ArchiveReader` → `import ArchiveCore`.
- **`ArchiveReader/macOS/project.yml:1-63`** — template for the Notes manifest (targets/schemes/entitlements shape); add `packages:` + `dependencies:` (Reader has none) and `network.client`.
- **`ArchiveReader/macOS/Sources/ArchiveReader/ArchiveReader.entitlements:1-13`** — template; add `com.apple.security.network.client`.
- **`ArchiveReader/macOS/Sources/ArchiveReader/Info.plist:1-26`** — template; rename to "Archive Notes".
- **`ArchiveReader/macOS/Sources/ArchiveReader/Assets.xcassets/AppIcon.appiconset/`** — copy the 10-image set as a placeholder icon so `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` compiles warning-free (replace with Notes art later).
- **`ArchiveReader/launch.sh:1-58`** — template for `ArchiveNotes/launch.sh` (`APPDIR="macOS"`, scheme/app-name → ArchiveNotes).
- **`ArchiveReader/bootstrap.sh:1-47`** — copy verbatim (generic project.yml discovery).
- **`ArchiveReader/test-smoke.sh:1-39`** — template, but set `PROJ="$ROOT/macOS"` (fixes the stale `$ROOT/ArchiveReader` path so it works post-de-nesting).
- **`launch.sh:11-20`** and **`test-smoke.sh:15-28`** (root) — add the `notes` case arm + `run_notes`.
- **`release/build-suite-dmg.sh:23-26` and `:82-84`** — add the third `APPS` entry + re-position the four DMG icons.
- **`release/make-dmg-background.swift:9,33-52`** — widen `W`, retitle, re-place the arrow; re-render.
- **`ArchiveReader/macOS/Sources/ArchiveReader/ArchiveReaderApp.swift:12-47`** — the `@main` App / multi-`Window` / `Settings` scene pattern.
- **`ArchiveReader/macOS/Sources/ArchiveReader/Views/NavigationWindowView.swift:459-491`** — copy `PanelDivider` (it is `private`, so copy, then relax to `internal`).
- **`ArchiveReader/.gitignore`** — copy verbatim (covers `*.xcodeproj/`, `build/`, `.maintenance/`, index caches).

## Bounded sub-tasks

### S1 — Create `packages/ArchiveCore` (seed + tests) · Tier-2 (shared contract)
- **Scope:** the package skeleton + seeded parser/extractor + seeded tests. No app yet.
- **Files:** `packages/ArchiveCore/{Package.swift, Sources/ArchiveCore/DocumentTags.swift, Sources/ArchiveCore/PDFTextExtractor.swift, Tests/ArchiveCoreTests/DocumentTagsTests.swift}`.
- **Steps:** write `Package.swift` (§4); copy the two Reader source files, add `public`; copy `DocumentTagsTests.swift`, switch to `import ArchiveCore`.
- **Verify:** `swift build` and `swift test` from `packages/ArchiveCore` — **all seeded DocumentTags tests pass**, zero warnings. `swift build -Xswiftc -strict-concurrency=complete` clean (Swift 6). Confirm no `@testable` leaks.
- **Tier per §12:** Tier-2 — this is the SPEC-blessed parser; adversarial review confirms it is a byte-for-byte seed (diff against Reader's original modulo `public`) and that no logic drifted.
- **Done-criteria:** package builds+tests green; SUITE_TODO W1 box "S1 ArchiveCore seeded" flips (cite commit).

### S2 — ArchiveNotes app scaffold + skeleton that builds & launches empty · Tier-1
- **Scope:** the app target, project.yml, Info.plist/entitlements/Assets, the 3-pane shell linking `ArchiveCore`, and the app-local `launch.sh`/`bootstrap.sh` so the GUI check works.
- **Files:** `ArchiveNotes/macOS/project.yml`, `…/Sources/ArchiveNotes/{ArchiveNotesApp.swift, Info.plist, ArchiveNotes.entitlements, Assets.xcassets/…, Views/{NotesShellView,PanelDivider,NotesSettingsView}.swift}`, `Tests/ArchiveNotesTests/SmokePlaceholderTests.swift`, `ArchiveNotes/{.gitignore, launch.sh, bootstrap.sh}`.
- **Steps:** author project.yml (§2); copy entitlements/Info.plist/Assets; write the skeleton (§3, `import ArchiveCore` used in `DetailPane`); copy `PanelDivider`; add a one-line placeholder test; `./bootstrap.sh`.
- **Verify:** `cd ArchiveNotes/macOS && xcodegen generate && xcodebuild -scheme ArchiveNotes -configuration Debug -derivedDataPath ./build/DD build` → BUILD SUCCEEDED, **no new warnings**; `xcodebuild test …` runs the placeholder suite. **GUI:** `./ArchiveNotes/launch.sh` → the Notes window opens with three panes + two draggable dividers; the Extracts window opens; ⌘, opens empty Settings; the `SuiteMarker.token` footer renders (proves the package linked). Drive/verify with `cliclick` drag on a divider, or an XCUITest that asserts both windows exist (full harness is W8).
- **Tier per §12:** Tier-1 (pure UI/scaffold, no irreplaceable-data surface) — clean build + no warnings + GUI check.
- **Done-criteria:** app builds and launches empty via its own `launch.sh`; SUITE_TODO "S2 app skeleton" flips.

### S3 — `ArchiveCore` net-new read-side types + tests · Tier-2 (SPEC-adjacent)
- **Scope:** `RootMarker`, `DurableLink`, `SuiteMarker` (§4.3) + their tests. Extends S1's package.
- **Files:** `packages/ArchiveCore/Sources/ArchiveCore/{RootMarker,DurableLink,SuiteMarker}.swift`, `Tests/ArchiveCoreTests/{RootMarkerTests,DurableLinkTests,SuiteMarkerTests}.swift`.
- **Steps:** implement the three types; write the tolerant `DurableLink` parser/renderer with percent-encoding for `rel`.
- **Verify:** `swift test` green incl. the new suites; round-trip and malformed-input tests pass; no warnings; strict-concurrency clean.
- **Tier per §12:** Tier-2 — these underpin durable provenance (§8) and the marker recognizer feeds the SPEC change; adversarial review focuses on encode/parse round-trip fidelity for adversarial `rel` values (em-dash, NBSP, `#`, `?`, empty, unicode) and idempotent codec stability.
- **Done-criteria:** new types + tests land; SUITE_TODO "S3 durable-link/marker types" flips.

### S4 — Suite wiring: dispatcher, smoke, combined DMG · Tier-1
- **Scope:** root `launch.sh`/`test-smoke.sh` arms, `ArchiveNotes/test-smoke.sh`, DMG `APPS` entry + 3-icon layout + re-rendered background.
- **Files:** `launch.sh`, `test-smoke.sh`, `ArchiveNotes/test-smoke.sh`, `release/build-suite-dmg.sh`, `release/make-dmg-background.swift`, `release/dmg-background.png` (regenerated).
- **Steps:** §5 edits; re-render the PNG; sanity-run.
- **Verify:** `./launch.sh notes` launches Notes; `./test-smoke.sh notes` builds+tests Notes (PASS); `./test-smoke.sh all` runs reader→notes→processor; a headless DMG build `release/build-suite-dmg.sh 0.0.0-test` stages three `.app`s (the osascript styling may skip headless — acceptable, note it) and produces a verifiable `/tmp/ArchiveSuite-0.0.0-test.dmg` (delete after; never commit). GUI-verify the background art vs. icon positions on a Mac session.
- **Tier per §12:** Tier-1 (build/release tooling; no data surface).
- **Done-criteria:** all dispatch arms work; DMG stages three apps; SUITE_TODO "S4 suite wiring" flips.

### S5 — SPEC `ArchiveSuite` marker delta + docs · Tier-2 (SPEC change)
- **Scope:** the additive SPEC section (§6) and all W1 docs (§7).
- **Files:** `SPEC/tag-format.md`, `AGENTS.md`, `CLAUDE.md` (root), `ArchiveNotes/{CLAUDE.md, README.md, AGENTS.md}`, `SUITE_TODO.md`.
- **Steps:** insert the exact SPEC text + facet-table row + change-protocol note; write the Notes docs + Implementation Map stub; add the SUITE_TODO Archive Notes section indexing `00`–`08`.
- **Verify:** prose review; confirm the SPEC delta is strictly additive (no existing rule changed), that it correctly records Reader/Processor adoption as deferred (D4/§2), and that `SuiteMarker.token`/`isMarker` in S3 match the SPEC string exactly. No build impact.
- **Tier per §12:** Tier-2 — SPEC changes are always adversarially reviewed even when additive; the reviewer checks the marker can't be mis-parsed as a facet and that "no corpus back-fill / no Reader parser change this run" is unambiguous.
- **Done-criteria:** SPEC + docs land in the same commits as their code where applicable; SUITE_TODO "S5 SPEC + docs" flips; the doc-sync backstop passes.

## Tests
**ArchiveCore unit tests (XCTest, run via `swift test`):**
- `DocumentTagsTests` (seeded, unchanged) — all existing Reader facet/parse/sortDate cases, re-pointed to `ArchiveCore`.
- `SuiteMarkerTests` — `isMarker("ArchiveSuite")==true`; case-insensitive (`"archivesuite"`), whitespace-trimmed; `isMarker("Archive Suite")==false` (space) and `isMarker("ArchiveSuiteX")==false`; a subject literally `ArchiveSuite` recognized (documented collision).
- `RootMarkerTests` — encode→decode round-trip equality; ISO-8601 date fidelity; stable `guid`; `Kind` rawValues `reader`/`notes`; `fileName == ".archive-suite-root.json"`; decode of malformed JSON throws (not crash).
- `DurableLinkTests` — render/parse round-trip for: `readerReveal` with/without `page`; `rel` containing spaces, `/`, em-dash U+2014, NBSP U+00A0, `#`, `?`; `notesOpen` with/without `#block-<n>`; malformed inputs (wrong scheme, missing `root`, non-numeric `page`, empty `rel`) return `nil` without crashing; unknown extra query keys ignored.

**ArchiveNotes app tests:** `SmokePlaceholderTests` (one trivial assertion) so `xcodebuild test -scheme ArchiveNotes` has a runnable suite for the smoke gate; real Notes suites arrive in W2+/W8.

**GUI/behavioral checks (via `./launch.sh notes`):** Notes window shows three labeled panes with two draggable `PanelDivider`s that resize within their ranges; Extracts window opens independently; ⌘, opens Settings; the `ArchiveCore` symbol renders (link proof). Optional XCUITest asserting both windows exist is deferred to the W8 harness.

## Risks & file-safety
- **Nothing in W1 writes irreplaceable data.** No corpus access; the app skeleton reads/writes nothing; `RootMarker`/`DurableLink` are pure types (no file I/O — deferred to W2/W4). Confirmed: no `NSFileCoordinator`, `setResourceValue`, `FileManager` mutators, or store writes are introduced.
- **`ArchiveCore` drift from Reader** (the SPEC's silent-divergence risk). Mitigation: S1 is a byte-for-byte seed (diff-verified modulo `public`), ships Reader's own tests, and the SPEC remains the contract; Reader/Processor keep their copies (00-overview §10) so no shipping app changes behavior. Convergence is a later gated wave.
- **XcodeGen local-package resolution.** Risk: wrong relative `path` or an unlinked product → build fails. Mitigation: S2 verifies the generated `.xcodeproj` links `ArchiveCore` and the app imports a symbol; the `path: ../../packages/ArchiveCore` is computed from the project.yml location and checked at generate time.
- **"No new warnings" gate.** Empty `AppIcon` sets warn; mitigated by copying Reader's populated icon set. Swift-6 strict-concurrency drift in the package is caught by `swift build` at complete concurrency.
- **DMG layout regression.** Hand-editing osascript positions could overlap icons or mis-align the arrow. Mitigation: GUI-verify the styled DMG against the re-rendered background on a Mac session before any release; a headless build still produces a functional (unstyled) DMG.
- **SPEC change blast radius.** The marker is additive and read-only for the two shipping apps this run (D4); the corpus carries no `ArchiveSuite` token, so no existing read/write behavior changes. Tier-2 review confirms the additive-only scope.
- **Inner-dir caveat.** Resolved by using `macOS/` everywhere in Notes' scripts; Reader's stale `test-smoke.sh` path is not touched (Reader untouched this run) but is flagged below.

## Open questions
1. **Reader's stale `test-smoke.sh` path** (`PROJ="$ROOT/ArchiveReader"` vs. the de-nested `macOS/`) — likely broken post-de-nesting; out of scope here (Reader untouched), but worth a `KNOWN_ISSUES.md` entry and a one-line fix in a Reader-lane session.
2. **`ArchiveCore` location** — `packages/ArchiveCore/` (chosen, keeps packages grouped) vs. a top-level `ArchiveCore/`; the overview allows either (§10). Revisit at the convergence wave when Reader/Processor adopt it.
3. **Notes app-icon art** — placeholder (Reader's icons) ships now; a distinct Archive Notes icon is a later cosmetic task.
4. **Whether `SuiteMarker.isMarker` should be case-insensitive** — chosen case-insensitive to avoid duplicate tokens, but subjects are otherwise matched case-sensitively; confirm with the W2 `NotesTagProjector` design so projection is idempotent under case variants.
5. **`archivenotes://` URL-type registration** — deferred to W4; confirm Scrivener honors the custom scheme in link fields during the W4 GUI pass (overview §15.6).
