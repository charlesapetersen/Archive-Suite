# Archive Notes — W4: Source blocks, page thumbnails, and cross-app linking (Notes ⇄ Reader)
> Status: PROPOSED · part of Archive Notes (see 00-overview.md) · Wave 4

> ⚠️ **Canonical shared types & cross-wave APIs are defined in `00-overview.md` §16 (Interface Contract).** Where a sketch in this file differs — store type/name (`actor NoteStore` + `@MainActor NotesModel`/`OrganizationStore`), `DurableLink`/`RootMarker`, the single `NotesFilter` type, template-assignments-only, the index `items` projection, the `archivenotes://open?id=` grammar — **the overview is authoritative.**


## Goal
Build the provenance backbone: the durable-link machinery (root-GUID + root-relative path + page) that both apps share via ArchiveCore; page-thumbnail rendering + a two-tier cache sized for 100k pages; the Reader-side additions (`archivereader://` URL scheme, deep-link router, a public `revealAndSelect(paths:)` on the existing select+scroll primitive, a multi-representation "Copy Archive Link(s)" command, and the root-marker drop-on-grant); and the Notes-side additions (paste-to-source-blocks, a per-block reveal-in-Reader button, a quick preview popover, and the `archivenotes://` scheme). Everything that touches the Reader corpus is **read-only** (per 00-overview §8.4, §12); the only writes are to Notes' own store and to the shared disk thumbnail cache in Application Support.

## Dependencies
- **W1** (`01`) must land first: it creates the `ArchiveCore` package (00-overview §10) and the `ArchiveNotes/` app scaffold. W4's durable-link types, `RootMarker`, and `PDFThumbnailer` all live in ArchiveCore, and the Notes-side UI attaches to the W1 3-pane shell.
- **W2** (`02`) must land first for the Notes side only: `NotesStore` (UUID-folder I/O, `assets/` writes, front-matter block model) and the block source-header parser/writer (00-overview §6) are what the paste handler produces. The **Reader-side** sub-tasks (S1–S4) depend only on W1 + the *existing shipped Reader*, so they can proceed even if W2 slips.
- No dependency on W3 (editor) for the link/thumbnail plumbing; the Notes paste handler inserts blocks through the W2 store model, and W3's editor renders them. If W3 hasn't landed, S6/S7 verify against the raw `.md` on disk instead of the WYSIWYG view.

## Design

### 0. Where each piece lives
```
ArchiveCore/Sources/ArchiveCore/           # shared, UI-free (imports Foundation + PDFKit only)
  Links/
    RootMarker.swift            NEW   RootMarker struct + read/write/ensure at a root URL
    DurableLink.swift           NEW   ArchiveReaderLink / ArchiveNotesLink encode+parse
    ArchiveLinkPayload.swift    NEW   Codable pasteboard JSON payload + UTI constant
  Thumbnails/
    PDFThumbnailer.swift        NEW   actor: render PDF page → PNG Data + disk cache
    ThumbnailCacheKey.swift     NEW   pure key derivation (link+page+mtime → filename)
ArchiveReader/macOS/Sources/ArchiveReader/
  Info.plist                    MOD   add CFBundleURLTypes (archivereader)
  ArchiveReaderApp.swift        MOD   inject DeepLinkRouter, .onOpenURL, openWindow(navigation)
  Core/DeepLinkRouter.swift     NEW   ObservableObject; parse+dispatch archivereader:// URLs
  Views/NavigationModel.swift   MOD   public revealAndSelect(paths:) + copyArchiveLinks()
  Search/RootFolderStore.swift  MOD   drop/ensure RootMarker on setRoot; expose rootMarker + resolve(guid:)
  Core/ArchiveLinkWriter.swift  NEW   builds the multi-representation NSPasteboardItem
ArchiveNotes/macOS/Sources/ArchiveNotes/   # (paths mirror Reader; final tree fixed in W1)
  Info.plist                    MOD   add CFBundleURLTypes (archivenotes)
  App/ArchiveNotesApp.swift     MOD   inject NotesDeepLinkRouter + .onOpenURL
  Links/NotesDeepLinkRouter.swift  NEW open?id=UUID[#block-n] → reveal item in Notes
  Links/ReaderRootStore.swift   NEW   Notes' own security-scoped bookmarks to Reader roots, keyed by GUID
  Links/ReaderLinkResolver.swift NEW  DurableLink → file URL within a granted Reader-root scope
  Sources/SourceBlockPaster.swift NEW pasteboard → [SourceBlock] → NotesStore inserts + assets/
  Views/SourceBlockView.swift   NEW   per-block header UI: thumbnail, reveal button, preview popover
  Views/ReaderPreviewPopover.swift NEW lightweight PDFKit 2-up preview over the resolved file URL
```

### 1. Durable links & root markers (ArchiveCore — the shared contract)

**`RootMarker`** (00-overview §3.8, §8.1). A tiny JSON file `.archive-suite-root.json` written at the top of a granted root:
```swift
public struct RootMarker: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case reader, notes }
    public let guid: UUID          // stable portable identity
    public let name: String        // human label (root folder's lastPathComponent at creation)
    public let kind: Kind
    public let createdAt: Date

    static let fileName = ".archive-suite-root.json"

    /// Idempotent: read an existing marker if present (never overwrite its guid); else create one.
    /// - Parameter directory: the granted root URL. Access scope must already be started.
    /// Uses NSFileCoordinator(.contentIndependentMetadataOnly for read / default for the one-time
    /// create write). Returns the effective marker. A malformed existing file is left untouched and
    /// surfaced as `.malformed` (never silently overwritten — that file could be the user's).
    public static func ensure(at directory: URL, kind: Kind, name: String) throws -> RootMarker
    public static func read(at directory: URL) throws -> RootMarker?   // nil = absent
}
```
- The create-write is the **one** benign write into a Reader root: it drops a dotfile the corpus never had. This is *not* a corpus-content mutation and never touches an existing file's bytes/tags, but it IS a write into the user's granted archive folder, so it goes through `NSFileCoordinator`, is idempotent (never rewrites an existing marker), and is Tier-2 reviewed. Writing it is what makes links portable; alternative (a sidecar in Application Support keyed by path) breaks on a computer move, which is the whole point of D5.
- **Edge case / graceful degradation:** if the root is read-only (e.g. a locked volume), `ensure` catches the write error and returns a **transient in-memory marker** (guid derived deterministically? no — a random guid held only for this session) *and* logs; links created this session still resolve same-machine via the path, and the app surfaces "couldn't write a portable marker to this archive (read-only?) — links may not survive a move." Never crash, never block reading.

**`DurableLink`** (00-overview §8.2). Two link families, both round-trippable:
```swift
public enum DurableLink: Sendable, Equatable {
    /// archivereader://reveal?root=<GUID>&rel=<pct-encoded root-relative path>&page=<int?>
    case reader(rootGUID: UUID, relativePath: String, page: Int?)
    /// archivenotes://open?id=<UUID>[#block-<n>]
    case notes(id: UUID, blockIndex: Int?)

    public var url: URL { … }                 // canonical encoder
    public init?(_ url: URL)                  // tolerant parser; nil on scheme/shape mismatch
}
```
Encoding rules (locked, versioned implicitly by the scheme host):
- `rel` is the path **relative to the marker's directory**, computed exactly like Reader's `buildFolderTree` root-relative math (NavigationModel.swift L569-577: strip `root + "/"` prefix, keep forward-slash components) — no leading slash, forward slashes only, each component percent-encoded via `URLComponents`/`addingPercentEncoding(withAllowedCharacters:)` so em-dash (U+2014), NBSP (U+00A0), and spaces survive (same correctness bar as `FileLinkFormatter`, FileLink.swift L20-23).
- `page` is 1-based to match the SPEC's human page numbering and the front-matter example (00-overview §5 shows `page=41`); the resolver converts to PDFKit's 0-based index. Absent `page` ⇒ `reader-doc` block; present ⇒ `reader-page`.
- Parser is **tolerant** (00-overview §6 round-trip rule): unknown query items ignored, missing `page` ⇒ nil, malformed `root` GUID ⇒ `init?` returns nil (caller surfaces "unrecognized link"), never a force-unwrap.

**Resolution** (`ReaderLinkResolver`, Notes-side; 00-overview §8.3). Input: `DurableLink.reader(...)`. Steps:
1. Look up `rootGUID` in `ReaderRootStore` (Notes' own bookmark store keyed by GUID). Hit ⇒ start the security scope, get the root URL.
2. **New-machine / unknown-GUID:** miss ⇒ return `.needsRootGrant(guid, suggestedName?)`. The UI shows a guided open-panel ("This link points at an archive root that isn't set up on this Mac — choose it?"). On grant, Notes reads the chosen folder's `RootMarker`; if `guid` matches, it stores the bookmark keyed by that guid and retries. If the chosen folder has a *different* guid, warn and don't store (wrong folder). Never silent failure (00-overview §8.3).
3. Join `rel` under the root URL; verify existence within scope. Fallbacks in order: exact `rel` → same basename found elsewhere under the root (offer, don't auto-open) → `.notFound` message. **Never** open a file outside the granted scope (mirrors the Reader Core Directive's containment; the resolved URL must have the root as a path-component-boundary prefix — reuse the `LibraryFilter.matches` boundary test, LibraryFilter.swift L45-48).

```swift
enum LinkResolution: Sendable {
    case resolved(URL)                       // within a live security scope (caller stops it when done)
    case needsRootGrant(guid: UUID)
    case renamedCandidate(URL)               // basename match elsewhere — needs user confirm
    case notFound
}
```
Concurrency: `ReaderLinkResolver` is `@MainActor` (it drives open panels and mutates `ReaderRootStore`, an `ObservableObject`). Pure encode/parse in `DurableLink` is `nonisolated`/`Sendable` so it's unit-testable off-main.

### 2. Page-thumbnail rendering + cache (ArchiveCore — NET-NEW)

Confirmed net-new: `grep` for `thumbnail|NSBitmapImageRep|.draw(|cgImage|dataWithPDF` across `ArchiveReader/Sources` returns **nothing** — no PDFPage→image path exists anywhere in the Suite today.

**`PDFThumbnailer`** — an `actor` returning **PNG `Data`** (Sendable), never `NSImage` (NSImage is non-Sendable; returning Data sidesteps the Swift 6 boundary and lets the disk write happen off-main):
```swift
public actor PDFThumbnailer {
    public struct Spec: Sendable, Hashable {
        var pointWidth: CGFloat = 220     // display width in the source-block header
        var scale: CGFloat = 2            // @2x for retina; final px width = 440
    }
    public init(cacheDirectory: URL, diskBudgetBytes: Int = 500 * 1024 * 1024)

    /// Render (or fetch cached) a PNG for page `page` (1-based) of the PDF at `fileURL`.
    /// `linkKey` is the canonical archivereader:// string; `mtime` is the source's
    /// contentModificationDate. Returns nil if the page can't be rendered (degrade: caller shows a
    /// placeholder + the text display label, never crashes).
    public func png(fileURL: URL, page: Int, spec: Spec,
                    linkKey: String, mtime: Date) async -> Data?
}
```
Rendering algorithm (adapt PDFPaneView's isolation pattern, PDFPaneView.swift L145-156):
1. Compute the disk cache filename via `ThumbnailCacheKey`: `sha256("\(linkKey)#p\(page)@\(mtime.timeIntervalSince1970)@\(spec.pointWidth)x\(spec.scale)") + ".png"`. Including `mtime` + `spec` in the key means a re-OCR/replacement of the source (new mtime) or a spec change naturally invalidates without an explicit purge.
2. On-disk hit ⇒ read + return Data (touch the file's access time / update an LRU index row).
3. Miss ⇒ `PDFDocument(url: fileURL)` (guard nil → return nil, like DocumentViewerModel.swift L112), `doc.page(at: page-1)` (guard nil → nil). **Copy the page into a throwaway one-page `PDFDocument`** exactly as PDFPaneView does (`page.copy() as? PDFPage` → `doc.insert(copy, at: 0)`) so we never detach the page from a document another part of the app might hold. Render:
   - Primary: `copy.thumbnail(of: CGSize(width: pointWidth*scale, height: pointWidth*scale*aspect), for: .cropBox)` → an `NSImage`; then `NSBitmapImageRep(data: image.tiffRepresentation!)?.representation(using: .png, properties: [:])` → PNG Data.
   - This all runs inside the actor (off the main actor). PDFKit page rendering off-main is safe for `PDFDocument`/`PDFPage` (no `PDFView` involved). If a future macOS asserts main-thread affinity, fall back to a dedicated serial `DispatchQueue` hop — noted as an open question, not expected.
4. Write PNG to disk atomically (`Data.write(to:, options: .atomic)`) under `cacheDirectory`; update the LRU index; return Data.
5. **Disk budget / 100k scale:** the cache is bounded, not per-note. Maintain a tiny `ThumbnailCacheIndex` (a plist or the Notes SQLite index carrying `{filename, bytes, lastAccess}`) and evict least-recently-accessed files when total > `diskBudgetBytes`. At 440px PNGs (~40–80 KB each), 500 MB holds ~7–12k thumbnails hot; the rest re-render on demand in <30 ms. Eviction runs opportunistically after writes (batched, like Reader's index maintenance) — never blocks a render.

**In-memory tier** (`ThumbnailImageCache`, `@MainActor`, in the Notes app not ArchiveCore, because `NSImage` is non-Sendable and lives on the UI side):
```swift
@MainActor final class ThumbnailImageCache {
    private let cache = NSCache<NSString, NSImage>()   // countLimit ~300; totalCostLimit ~64 MB (cost = px area)
    func image(for key: NSString) -> NSImage?
    func set(_ image: NSImage, for key: NSString, cost: Int)
}
```
Flow for a block view: check in-memory NSCache → miss → `await thumbnailer.png(...)` (actor, disk or render) → decode `NSImage(data:)` on main → insert into NSCache. `NSCache` auto-evicts under memory pressure, so a 100k-note window never holds more than a few hundred decoded images.

**Reuse in Reader (Copy path):** Reader also uses `PDFThumbnailer.png(...)` to produce the base64 PNG it ships in the pasteboard payload (§3), so the common Reader→paste flow needs **zero** rendering in Notes and zero re-grant — the image travels in the clipboard. Notes only renders itself when a link is pasted as plain text without a payload, or when regenerating.

### 3. Reader-side additions (Tier-2, read-only w.r.t. corpus)

**Info.plist (MOD)** — add `CFBundleURLTypes` (none today; confirmed via read of Info.plist L1-30):
```xml
<key>CFBundleURLTypes</key>
<array><dict>
  <key>CFBundleURLName</key><string>com.archivereader.reveal</string>
  <key>CFBundleURLSchemes</key><array><string>archivereader</string></array>
</dict></array>
```
Register in `project.yml`'s Info generation, not a hand-edited pbxproj.

**`DeepLinkRouter` (NEW, `@MainActor ObservableObject`)** — parses an incoming URL to `DurableLink`, dispatches:
```swift
@MainActor final class DeepLinkRouter: ObservableObject {
    weak var nav: NavigationModel?               // set once the nav scene exists
    func handle(_ url: URL) {
        guard case .reader(let guid, let rel, let page)? = DurableLink(url) else { return }
        // Reader is single-root today; verify guid matches the current root's marker (else surface a
        // "this link is for a different archive — choose it in File ▸ Choose Archive Folder…" status).
        nav?.revealAndSelect(rootGUID: guid, relativePath: rel, page: page)
    }
}
```
**App wiring (ArchiveReaderApp.swift MOD, scenes L20-33):** attach `.onOpenURL { router.handle($0) }` to the nav `Window` scene, `NSApp.activate(ignoringOtherApps: true)`, and `openWindow(id: WindowID.navigation)` to raise the nav window (WindowID.navigation exists, L45). Inject the router as `@StateObject` and pass to `NavigationWindowView` (which already `@StateObject`s the model, NavigationWindowView.swift L5) so the router can hold a weak ref.

**`NavigationModel.revealAndSelect(...)` (NEW, public method)** — built on the *existing* select+scroll primitive, not a new one:
```swift
func revealAndSelect(rootGUID: UUID, relativePath: String, page: Int?) {
    // 1. Resolve rel → absolute path under the current root (root-relative join is the inverse of
    //    buildFolderTree's math, L569-577). If the guid ≠ current root marker, set statusMessage and return.
    guard let root = rootStore.root, rootStore.rootMarker?.guid == rootGUID else {
        statusMessage = "This link points at a different archive. Choose it in File ▸ Choose Archive Folder…"; return
    }
    let path = root.appendingPathComponent(relativePath).path
    pendingReveal = path                       // NEW @Published private var
    clearUserFilters()                         // exit any narrowing (L219-230) so the target is visible
    if scope != nil { setFolderScope(nil) }    // exit smart-folder scope (existing method L550)
    applyPendingRevealIfPossible()
}
```
`applyPendingRevealIfPossible()` implements the **`restoreSelectionIfNeeded` deferral pattern** (NavigationModel.swift L306-313): the target file may not be in `library.files` yet while Spotlight is still gathering. So:
- If `library.isGathering` **or** the path isn't yet in `library.files`, stash `pendingReveal` and return; hook `libraryDidChange()` (L522-540, already fires on every `library.$files` emission) to retry `applyPendingRevealIfPossible()` after each gather tick, giving up after a bounded number of settled emissions (reuse the "two-emission absence" idea from pruning) with a "document not found in the current archive" status (00-overview §8.3 fallback tier).
- On success: find the `ArchiveFile.ID` for the path, set `selection = [id]` (the published selection setter, L32) and `requestScroll(to: id)` (the existing private primitive, L672 — promote to internal or add a thin `func revealScroll(to:)`), which bumps `scrollRequest`/`scrollTargetID` (L66-67). `AppKitTableView.updateNSView` already turns that into `scrollRowToVisible` (L171-176), so the row scrolls into view with no new view code.
- **`page` handling:** if `page != nil`, after selection, open/raise the document window on that file and jump to the page. Minimal for W4: set the selection + a `pendingPage` on the opened `DocumentViewerModel` so it lands on the page-1 image; full "scroll the OCR pane to page N" is deferred (documents are 2-page; `page` here identifies *which source PDF*, which is the file itself — page-within-a-merged-PDF navigation is a nice-to-have, tracked in Open questions).

Concurrency/Swift-6 notes: `revealAndSelect` is `@MainActor` (whole model is, L19). The deferral uses the existing Combine `library.$files` sink (L79-85) which already `assumeIsolated`s onto main. No new actor. `pendingReveal`/`pendingPage` are plain stored vars on the MainActor model.

**Copy Archive Link(s) (NEW).** A new command + toolbar button + context-menu item, parallel to the existing `copyLinks()` (which writes plain file:// text, NavigationModel.swift L874-881) — this one writes a **multi-representation** pasteboard item:
- `NavigationModel.copyArchiveLinks()`:
```swift
func copyArchiveLinks() {
    let files = selectedFiles                 // whole-library resolved selection (L471)
    guard !files.isEmpty, let root = rootStore.root, let marker = rootStore.rootMarker else {
        statusMessage = "Choose an archive folder first."; return
    }
    Task { // rendering is async (thumbnailer actor); build the item off the render, then set pb on main
        let item = await ArchiveLinkWriter.pasteboardItem(for: files, root: root, marker: marker,
                                                          thumbnailer: sharedThumbnailer)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
        statusMessage = "Copied \(files.count) archive link\(files.count == 1 ? "" : "s")."
    }
}
```
- `ArchiveLinkWriter.pasteboardItem(...)` builds an `NSPasteboardItem` with **two** representations:
  1. `.string` — newline-joined `archivereader://reveal?...` URLs (so pasting into Scrivener/TextEdit yields working links; mirrors `FileLinkFormatter.clipboardString`, FileLink.swift L52).
  2. Custom UTI `"com.archivesuite.archive-links"` — JSON `Data`:
     ```swift
     struct ArchiveLinkPayload: Codable, Sendable {           // ArchiveCore
       struct Entry: Codable, Sendable {
         var link: String        // canonical archivereader:// url
         var display: String     // stable label: "<name> — p.<page>" or "<name>"
         var page: Int?
         var thumbPNGBase64: String?   // rendered by Reader for reader-page entries
       }
       var version = 1
       var entries: [Entry]
     }
     ```
     `display` is derived from the file name (deletingPathExtension, like FileLink.swift L57-59) plus `— p.N` when a page is known. For a page link, Reader renders the thumbnail via `PDFThumbnailer` and base64-encodes it into `thumbPNGBase64`. For a whole-doc link, thumb is nil (Notes shows a doc glyph).
     - **Per-file page choice for the Copy command:** the nav selection is file-level, so Copy defaults to `reader-doc` links (no page). A page-level link is produced from the *document window* (a "Copy Archive Link to This Page" in the Document menu that knows the current page) — added here as a small Document-menu command using `DocumentViewerModel`'s current index. This keeps the nav Copy simple and gives page anchors where the page is actually known.
- **UTI declaration:** custom pasteboard types don't strictly require an Info.plist declaration to round-trip between two apps we control, but we add a matching `UTExportedTypeDeclarations` for `com.archivesuite.archive-links` (conforms to `public.data`) in **both** apps' Info.plist for cleanliness and Universal-Clipboard safety.
- **Menu/shortcut (ArchiveReaderCommands.swift MOD):** add `Button("Copy Archive Link(s)") { nav?.copyArchiveLinks() }.keyboardShortcut("l", modifiers: [.command, .shift])` to the Selection menu (⌘⇧L; ⌘⇧C stays the plain-link copy, L58-59). Add a toolbar button in `NavigationWindowView.toolbarContent` (L348-417) next to "Copy Links" (L393). Add a context-menu item + trampoline: extend `buildNSContextMenu()` (L124-147) with "Copy Archive Link(s)" and `ContextMenuActions` (L552-568) with `@objc func copyArchiveLinks() { model.copyArchiveLinks() }`.

**RootMarker drop-on-grant (RootFolderStore.swift MOD).** In `setRoot(_:)` (L18-33), after the bookmark is persisted and the scope is started (L26-27), call `RootMarker.ensure(at: url, kind: .reader, name: url.lastPathComponent)` and store the result on a new `@Published private(set) var rootMarker: RootMarker?`. Also compute it in `resolveSaved()` (L41-63) so a relaunch has the marker without re-prompting. Add `func rootMarker(for guid: UUID) -> Bool` convenience for the router's guid check. **Safety:** this is the only write into a Reader root; it's coordinated, idempotent, never overwrites, and Tier-2. On failure it logs (like the existing `NSLog` sites, L31/L48) and leaves `rootMarker = nil` — the app still reads normally; Copy-Archive-Link just falls back to a path-only link (degraded portability) with a status note.

### 4. Notes-side additions

**`archivenotes://` scheme (Info.plist MOD + `NotesDeepLinkRouter` NEW).** Register `archivenotes` in the Notes Info.plist (same CFBundleURLTypes shape). Router parses `DurableLink.notes(id:, blockIndex:)`, activates the app, opens/raises the note-viewer window on that item id, and (if `blockIndex` present) scrolls to `#block-<n>`. This is the Scrivener round-trip target (00-overview §1 step 5, §8.2) and the internal-link target. Uses the same `.onOpenURL` + `NSApp.activate` + `openWindow` wiring as Reader. The Notes viewer/selection API is W6; for W4, the router lands with a minimal "select item by id and bring window forward" that W6's viewer refines.

**`SourceBlockPaster` (NEW) — paste → N source blocks (00-overview §3.2-3.3, §6).** A paste handler invoked from the Notes editor's paste command and a "Paste as Source Block(s)" menu item:
```swift
@MainActor struct SourceBlockPaster {
    /// Inspect the general pasteboard; produce source blocks and insert them into `item` via NotesStore.
    /// Returns the number of blocks created (0 = nothing recognized → fall through to normal paste).
    func pasteSources(into itemID: UUID, at insertionIndex: Int, store: NotesStore) async -> Int
}
```
Algorithm:
1. Read the custom UTI first: `NSPasteboard.general.data(forType: NSPasteboard.PasteboardType("com.archivesuite.archive-links"))` → decode `ArchiveLinkPayload`. Hit ⇒ one block per `Entry`.
2. Miss ⇒ read `.string`; scan for `archivereader://` URLs (line-split + `DurableLink(url)` parse). Each valid URL ⇒ one entry with `display` synthesized from `rel`'s last component, `thumbPNGBase64 = nil`.
3. For each entry, build a `SourceBlock` (00-overview §3.3 `SourceAnchor`): `type` = `.readerPage` if `page != nil` else `.readerDoc`; `link` = canonical url; `display`; `page`.
4. **Thumbnail into `assets/`:** if `thumbPNGBase64 != nil`, decode and write `assets/p<page>-thumb.png` (00-overview §5 example: `assets/p41-thumb.png`) via `NotesStore`'s asset writer (W2). If nil and it's a page link, attempt `ReaderLinkResolver.resolve(link)` → on `.resolved(url)` call `PDFThumbnailer.png(...)` and write it; on `.needsRootGrant`/`.notFound`, **skip the image** and keep the text header only (graceful degradation — 00-overview §6 "consumers must degrade"). The block still carries `link`+`display`, so provenance is intact without the picture.
5. Write the block header + rendered image line through the W2 block-writer so the raw `.md` matches 00-overview §5/§6 exactly (HTML-comment header + `![display](assets/…)` line for sourced blocks).

**File-safety:** all writes here are inside the Notes store's own UUID folder (`items/<uuid>/assets/…`) via the W2 audited atomic writer — never the Reader corpus. Thumbnail cache writes go to `~/Library/Application Support/ArchiveNotes/thumb-cache/`. No `TagWriter`/`NotesTagProjector` involvement in W4 (subject-tag projection is W2/§9; source blocks don't add Finder tags).

**`SourceBlockView` (NEW) — per-block header UI:**
- Renders the cached thumbnail (via `ThumbnailImageCache` → `PDFThumbnailer`) for page/doc blocks, the `display` label, and:
- **Reveal-in-Reader button:** `NSWorkspace.shared.open(DurableLink.url)` for the block's `archivereader://reveal…` (select-not-open semantics: Reader's `revealAndSelect` selects the row and scrolls, it does **not** force-open the document window unless `page` is set). This is the Notes→Reader jump.
- **Quick-preview popover:** an `NSPopover`/SwiftUI `.popover` containing `ReaderPreviewPopover`.

**`ReaderPreviewPopover` (NEW) — the in-Notes preview.** Decision (the mandate offers two options): implement a **lightweight PDFKit preview in Notes over the resolved file URL within granted scope** (not shelling the scheme), because (a) it keeps the reader-context lightweight and doesn't steal focus to the Reader app, and (b) it reuses the proven read-only `PDFPaneView` isolation pattern. Concretely:
- Resolve the block's link via `ReaderLinkResolver`. On `.resolved(url)` (scope started), load `PDFDocument(url:)` and show the page: reuse the **exact** `PDFPaneView` + `PDFPaneController(persists: false)` preview pattern from `PreviewSheet`/`DocumentViewerModel(persists:false)` (PreviewSheet.swift L12, DocumentViewerModel.swift L18-21, PDFPaneView.swift). `PDFPaneView` is provably read-only (no write path), satisfying the corpus safety envelope. Copy `PDFPaneController`/`PDFPaneView` into ArchiveNotes (or, better, into ArchiveCore's UI-free… no — PDFPaneView imports SwiftUI, so it stays app-side; copy it into ArchiveNotes for W4 and note the future convergence to share it).
- On `.needsRootGrant` show a "Set up this archive on this Mac" button that runs the guided grant; on `.notFound`/`.renamedCandidate`, show the message + the offer. Stop the security scope when the popover closes.
- For a **`page` link** the popover shows just that page (`doc.page(at: page-1)` guarded, DocumentViewerModel.swift L54-58 style); for a **doc** link it shows page 0 with a "reveal in Reader for full read" affordance.

Swift 6 / Sendable notes: `SourceBlockPaster`, `SourceBlockView`, `ReaderPreviewPopover`, `ThumbnailImageCache`, routers, and `ReaderLinkResolver` are all `@MainActor`. `PDFThumbnailer` is an `actor` and returns `Data`. `ArchiveLinkPayload`/`DurableLink`/`RootMarker` are `Sendable` value types. The only cross-actor hop is `await thumbnailer.png(...)` returning Sendable `Data`, decoded to `NSImage` back on main.

## Reuse from the existing codebase
- **Select+scroll primitive** — `NavigationModel.selection` (`Views/NavigationModel.swift:32`), `requestScroll(to:)` (`:672`), `scrollTargetID`/`scrollRequest` (`:66-67`); `AppKitTableView` already converts a `scrollRequest` bump into `scrollRowToVisible` (`Views/AppKitTableView.swift:171-176`) and pushes selection via `syncSelection` (`:213-222`). Build `revealAndSelect` on these — **no new scroll code**.
- **Deferred-until-gathered pattern** — `restoreSelectionIfNeeded()` (`Views/NavigationModel.swift:306-313`) called from `libraryDidChange()` (`:522-540`); copy its "wait for `library.files` to be non-empty / settled, then apply" structure for `applyPendingRevealIfPossible()`.
- **Filter/scope exit** — `clearUserFilters()` (`Views/NavigationModel.swift:219-230`) and `setFolderScope(nil)` (`:550-556`) to make a revealed target visible.
- **Root-relative path math** — `buildFolderTree` (`Views/NavigationModel.swift:569-577`): strip `root + "/"`, forward-slash components; invert it to join `rel` back to an absolute path. Boundary-prefix containment check from `LibraryFilter.matches` (`Core/LibraryFilter.swift:45-48`).
- **Copy-to-pasteboard + link formatting** — `NavigationModel.copyLinks()` (`Views/NavigationModel.swift:874-881`); `FileLinkFormatter` percent-encoding via Foundation `URL` (`Core/FileLink.swift:20-23`, `clipboardString` `:52`) as the correctness bar for encoding em-dash/NBSP/space in `rel`.
- **Security-scoped bookmark create/resolve** — `RootFolderStore.setRoot`/`resolveSaved` (`Search/RootFolderStore.swift:18-63`): the exact template for Notes' `ReaderRootStore` (keyed by GUID) and for the marker-drop insertion point.
- **Read-only PDF page isolation** — `PDFPaneView.loadPage` `page.copy() as? PDFPage` into a throwaway `PDFDocument` (`Views/PDFPaneView.swift:145-156`); `PDFPaneController(persists:false)` (`:20-27`). Adapt for both `PDFThumbnailer` rendering and `ReaderPreviewPopover`.
- **Preview harness** — `PreviewSheet` (`Views/PreviewSheet.swift`, whole file) + `DocumentViewerModel(persists:false)` (`Views/DocumentViewerModel.swift:12,18-21`); the 2-page/degrade handling (`:51-68`) and `PDFPage(image:)` image fallback (`:115-121`) inform `ReaderPreviewPopover`'s degrade paths.
- **Format degradation** — `PDFFormatStatus.classify` (`Core/PDFFormatStatus.swift:20-33`) for "unreadable / no text layer" states when a preview/thumbnail source is bad.
- **App scene + URL entry point** — `ArchiveReaderApp` scenes (`ArchiveReaderApp.swift:20-33`), `WindowID.navigation` (`:45`), `DocumentSelection` (`:52-54`); attach `.onOpenURL` here. `Info.plist` has **no** `CFBundleURLTypes` today (`Info.plist:1-30`) — net-new.
- **Menu/toolbar/context-menu wiring** — `ArchiveReaderCommands` Selection menu (`ArchiveReaderCommands.swift:47-71`), `NavigationWindowView.toolbarContent` (`:348-417`), `buildNSContextMenu` + `ContextMenuActions` trampoline (`:124-147`, `:552-568`) — the three sites to add "Copy Archive Link(s)".
- **DurableLink/RootMarker/PDFThumbnailer/payload** — **net-new** in ArchiveCore; nothing comparable exists in the repo.

## Bounded sub-tasks
Each sized to one fresh overnight session (own worktree → clean build, no new warnings → tests → GUI check → commit with docs → push → remove worktree). Tier per 00-overview §12.

**S1 — ArchiveCore: `DurableLink` + `RootMarker` + `ArchiveLinkPayload`.** *(Tier-2: shared-contract type + a benign root write.)*
- Files: `ArchiveCore/Sources/ArchiveCore/Links/{DurableLink,RootMarker,ArchiveLinkPayload}.swift` (NEW) + tests.
- Steps: implement the encoders/parsers (tolerant), `RootMarker.ensure/read` with `NSFileCoordinator`, the Codable payload + UTI constant. Percent-encoding via `URLComponents`.
- Verify: `swift test` (ArchiveCore package) — the new unit tests below; clean build of the package. No GUI. Done-criteria: round-trip tests green; flip the W4/S1 checkbox in `SUITE_TODO.md` + this plan.

**S2 — ArchiveCore: `PDFThumbnailer` + `ThumbnailCacheKey` + disk LRU.** *(Tier-1: read-only render + Application-Support cache; no corpus write.)*
- Files: `ArchiveCore/.../Thumbnails/{PDFThumbnailer,ThumbnailCacheKey}.swift` (NEW) + tests.
- Steps: implement the actor (render via `page.copy()` isolation → PNG Data), disk read/write, key derivation, LRU eviction under a byte budget.
- Verify: `swift test` renders a scratch 2-page PDF (generate one in the test via `PDFDocument` + `PDFPage(image:)`), asserts non-nil PNG, cache-hit second call skips render (spy/flag), eviction respects the budget. Clean build. Done: checkbox flip.

**S3 — Reader: URL scheme + `DeepLinkRouter` + `revealAndSelect`.** *(Tier-2: deep-link reveal path, 00-overview §12.)*
- Files: `Info.plist` (MOD), `ArchiveReaderApp.swift` (MOD), `Core/DeepLinkRouter.swift` (NEW), `Views/NavigationModel.swift` (MOD: `revealAndSelect`, `pendingReveal`, `applyPendingRevealIfPossible`, promote `requestScroll`), `Search/RootFolderStore.swift` (MOD: `rootMarker`).
- Steps: register scheme, wire `.onOpenURL` + activate + openWindow, implement `revealAndSelect` on the existing primitive with the gather-deferral, drop/read `RootMarker` on grant.
- Verify: `xcodegen generate && xcodebuild -scheme ArchiveReader … build` (per-worktree DerivedData), unit tests `RevealAndSelectTests`; **GUI via `./launch.sh reader`** then `open "archivereader://reveal?root=<GUID>&rel=<path>"` from Terminal (cliclick not needed — the OS delivers the URL) and confirm the row selects + scrolls into view. Done: checkbox flip + KNOWN_ISSUES note if any partial (e.g. page-within-merged-PDF deferred).

**S4 — Reader: Copy Archive Link(s) + multi-rep pasteboard.** *(Tier-2: pasteboard payload + thumbnail render on the read path.)*
- Files: `Core/ArchiveLinkWriter.swift` (NEW), `Views/NavigationModel.swift` (MOD: `copyArchiveLinks`, shared thumbnailer), `ArchiveReaderCommands.swift` (MOD: ⌘⇧L + Document-menu "Copy Link to This Page"), `NavigationWindowView.swift` (MOD: toolbar + context menu + trampoline), both `Info.plist`s (MOD: `UTExportedTypeDeclarations`).
- Steps: build the `NSPasteboardItem` with `.string` + custom-UTI JSON (base64 thumb for page entries via S2), wire the three UI sites.
- Verify: build + `ArchiveLinkWriterTests`; GUI: select rows, ⌘⇧L, then `pbpaste` (plain text = archivereader:// URLs) and a tiny test reader for the custom UTI (or assert in a unit test that the item vends both types). Done: checkbox flip.

**S5 — Notes: `archivenotes://` scheme + `NotesDeepLinkRouter` + `ReaderRootStore`/`ReaderLinkResolver`.** *(Tier-2: cross-app resolution incl. re-grant; read-only w.r.t. corpus.)*
- Files: Notes `Info.plist` (MOD), `App/ArchiveNotesApp.swift` (MOD), `Links/{NotesDeepLinkRouter,ReaderRootStore,ReaderLinkResolver}.swift` (NEW) + tests.
- Steps: register scheme; router opens item by id; `ReaderRootStore` (GUID-keyed bookmarks, modeled on RootFolderStore); resolver with same-machine/new-machine/fallback tiers.
- Verify: build Notes; `ReaderLinkResolverTests` on a scratch root (mktemp copy with a `RootMarker`) covering resolve/re-grant-needed/renamed-candidate/not-found; GUI `./launch.sh notes` + `open "archivenotes://open?id=<uuid>"` selects the item. Done: checkbox flip.

**S6 — Notes: paste → source blocks (`SourceBlockPaster`).** *(Tier-2: writes blocks + assets into the Notes store; W2 dependency.)*
- Files: `Sources/SourceBlockPaster.swift` (NEW), hook into the editor paste command + a menu item + tests.
- Steps: read custom UTI then plain text; build blocks; write thumbnail into `assets/`; insert via W2 store; degrade when no payload/scope.
- Verify: build; `SourceBlockPasterTests` on a scratch NotesStore — synthesize a pasteboard with the payload, assert N blocks + a `assets/p<page>-thumb.png` + the raw `.md` header matches 00-overview §6. GUI: copy from Reader (S4), paste into a Notes note, confirm the block + thumbnail render. **Never write the real corpus** (scratch store only). Done: checkbox flip.

**S7 — Notes: `SourceBlockView` reveal button + `ReaderPreviewPopover`.** *(Tier-1: read-only UI; corpus reads within granted scope.)*
- Files: `Views/{SourceBlockView,ReaderPreviewPopover}.swift` (NEW), copy `PDFPaneView`/`PDFPaneController` into ArchiveNotes, `ThumbnailImageCache.swift` (NEW).
- Steps: render thumbnail (in-mem NSCache → S2 actor), reveal-in-Reader button (`NSWorkspace.open`), preview popover via `PDFPaneView(persists:false)`.
- Verify: build; GUI `./launch.sh notes`: click reveal on a block → Reader front + row selected/scrolled (needs S3); open preview popover → page shows; degrade path (unknown root) shows the grant affordance. Done: checkbox flip; if W3 editor absent, verify against the block list view instead.

## Tests
Unit (name them):
- `DurableLinkTests` — encode/parse round-trips (reader doc/page, notes open/#block); percent-encoding of em-dash/NBSP/space in `rel`; tolerant parse of unknown query items, missing `page`, bad GUID → nil; 1-based↔0-based page.
- `RootMarkerTests` — `ensure` creates once, is idempotent (guid stable across calls), never overwrites an existing/malformed file, read-only-volume path returns a transient marker without throwing.
- `PDFThumbnailerTests` — renders a page to PNG; cache hit avoids re-render; mtime change invalidates; disk budget eviction; nil for a corrupt/out-of-range page (degrade).
- `ThumbnailCacheKeyTests` — key stability + sensitivity to link/page/mtime/spec.
- `RevealAndSelectTests` (Reader) — selection + scrollRequest bump for a present path; deferral when gathering then applies after a `library.files` emission; guid-mismatch → status, no selection; missing path → not-found status after settling.
- `ArchiveLinkWriterTests` — pasteboard item vends both `.string` (all URLs) and custom-UTI JSON; JSON decodes to `ArchiveLinkPayload`; page entries carry a base64 PNG, doc entries don't.
- `ReaderLinkResolverTests` (Notes) — resolved within scope; unknown GUID → `needsRootGrant`; renamed basename → `renamedCandidate`; outside-scope path refused; not-found.
- `SourceBlockPasterTests` (Notes) — payload → N blocks + assets + `.md` header (§6); plain-text fallback; no-payload/no-scope degrade (text-only block, no image).

GUI/behavioral (via `./launch.sh reader|notes`, `open <url>`, and where needed cliclick/XCUITest — folded into W8's harness):
- Reader: `open archivereader://reveal?...` selects + scrolls the target row (also while a filter/scope is active → it exits and reveals).
- Copy Archive Link(s) (⌘⇧L / toolbar / context menu) → `pbpaste` shows the URLs.
- Notes: paste from Reader creates a source block with a live thumbnail; reveal button raises Reader on the row; preview popover shows the page; unknown-root shows the guided grant.
- Scrivener round-trip (00-overview §15.6): validate `archivenotes://open?id=…` fires from a Scrivener link during the W4 GUI pass on the owner's machine.

## Risks & file-safety
- **The one Reader-root write is the root marker.** Mitigation: `RootMarker.ensure` is coordinated (`NSFileCoordinator`), idempotent, never overwrites an existing/malformed file, and touches no corpus file's bytes/tags. It is the *only* thing W4 writes into a granted Reader root; Tier-2 review + a test that a pre-existing marker/other dotfile is never clobbered. On a read-only root it degrades to path-only links, never throws.
- **Never write the corpus.** All Notes writes are inside `items/<uuid>/` (blocks + assets) via the W2 atomic writer; thumbnails go to Application Support. No `PDFDocument.write`, move, rename, or delete anywhere — the thumbnailer and preview only *read* source PDFs and copy pages into throwaway documents (PDFPaneView pattern). Dev/test uses mktemp scratch copies of any PDF/store (Reader Prime Directive; memory `archive-test-run-safety`), never the owner's data.
- **Scope containment.** `ReaderLinkResolver` refuses any resolved path not under the granted root (component-boundary check), so a crafted `rel` (`../../`) can't escape the sandbox scope. Percent-decoding is done by Foundation `URL`, and the joined path is re-validated against the root prefix before any read.
- **Stale/duplicate paths.** Reveal defers until Spotlight settles and bounds its retries so a bad link ends in a clear "not found," never a spin. Basename-fallback offers, never auto-opens a different file.
- **Concurrency.** Thumbnailer is an actor returning Sendable `Data`; NSImage stays MainActor-side; no data races. Reveal reuses the model's existing MainActor Combine pipeline — no new isolation surface.
- **Pasteboard payload trust.** `SourceBlockPaster` treats the custom-UTI JSON as untrusted: decode-guard, validate each `link` via `DurableLink(url)`, size-cap `thumbPNGBase64`, and never execute anything from it. A malformed payload falls through to plain-text scanning, then to normal paste.

## Open questions (non-blocking)
1. **Page-within-a-merged-PDF navigation.** A `reader-page` link identifies the source file and a page number; for the corpus's usual 2-page PDFs the "page" is the document itself. Scrolling a >2-page merged PDF to page N in the Reader document window is deferred (Reader documents are page-per-view today) — tracked for a later iteration.
2. **Shared `PDFPaneView`.** W4 copies `PDFPaneView`/`PDFPaneController` into ArchiveNotes; whether these UI helpers should move into a shared UI module is part of the deferred ArchiveCore convergence (00-overview §10, §13).
3. **Thumbnail spec for print/export.** The 220pt@2x PNG is tuned for on-screen blocks; a higher-res export path (e.g. for printing a note) may want a second spec — the cache key already includes spec, so this is additive.
4. **Universal Clipboard.** The custom UTI is declared for cross-device paste, but cross-Mac paste still needs the target Mac to have the root granted; the same `needsRootGrant` flow covers it. Confirm behavior during W8 if the owner uses Handoff.
5. **Multi-root Reader.** Reader is single-root today; the guid check assumes the current root. Multi-root support (00-overview §2 deferred list) would let a link resolve against any granted root by guid — the resolver is already guid-keyed, so this is mostly a Reader-side lookup change later.
