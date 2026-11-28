import AppKit
import Foundation
import ArchiveCore
import ArchiveCoreUI
import CryptoKit

/// The UI façade every Notes view binds to (00-overview §16.1). It owns the single organization graph
/// (`OrganizationStore`) and — in the app path — the backing index + store-root, and exposes the
/// rendered folder tree + current scope as `@Published` state plus `async` mutation methods.
///
/// Domain-scoped methods live in sibling extension files:
/// - `NotesModel+LibraryIndex.swift`: item loading, index build/recovery, Reload Library, FTS/advanced search
/// - `NotesModel+Templates.swift`: templates CRUD, body editing/retry, metadata defaults, folder assignments
/// - `NotesModel+ItemsAndBody.swift`: new/duplicate notes, extracts, metadata edits, body/export/assets, Zotero
/// - `NotesModel+OrganizationAndTrash.swift`: folder tree, smart-folder counts, scopes, folder mutations, Trash
/// - `NotesModel+TagRename.swift` / `NotesModel+TagsWindow.swift`: tag renames & Window ▸ Tags
///
/// Concurrency (§16.9): `@MainActor`; the actor-backed I/O it calls (`NotesIndex`, `OrganizationStore`
/// awaits) is awaited from here, and published state is only mutated on the main actor.
@MainActor
final class NotesModel: ObservableObject {
    /// The single organization graph shared by both windows. Mutations persist atomically.
    let organization: OrganizationStore

    // MARK: Rendered tree state (rebuilt after every mutation / store load)

    /// Hierarchical forest of normal folders (the "Folders" section).
    @Published var normalTree: [NotesFolderNode] = []
    /// Flat list of user smart folders (the "Smart Folders" section), excluding the All-Notes root.
    @Published var smartFolders: [NotesFolderNode] = []
    /// Saved-query matches for each valid smart folder, independent of either window's current
    /// user filters. Missing keys mean the count is still computing or the query is unreadable.
    @Published var smartFolderCounts: [UUID: Int] = [:]
    var smartCountGeneration = 0
    var smartCountWorker: Task<[UUID: Int]?, Never>?
    var smartCountApply: Task<Void, Never>?
    /// Every item in the store — the badge on the "All Notes" pseudo-row, counted from the same item
    /// list All Notes shows. It was counted from folder memberships, so a note in no folder was listed
    /// but not counted (W40.fix-notes-visual-polish).
    var allNotesCount: Int { allItems.count }

    // MARK: Item list source (W6-S3)

    /// Every indexed item (the `ItemSummary` projection, §16.5), shared by both windows. Each window's
    /// `NotesNavigationModel` filters + sorts this into its own `displayed` list, so the two windows can
    /// differ by kind/sort/selection while reading one source of truth. Loaded on bootstrap and
    /// refreshable via `reloadItems()`.
    @Published var allItems: [ItemSummary] = []

    /// Bumped on every `replaceItems` (create/rename/delete/reindex). A cheap O(1) signal the extract
    /// editor uses to re-resolve provenance-chip live titles when the shared item set changes, without
    /// diffing the whole list — so a source-note rename recolors chips reactively, not only on the next
    /// re-style (W14.4 c). Monotonic; wraps harmlessly (`&+`) since only inequality is compared.
    @Published var itemsGeneration = 0

    // MARK: Templates (W6-S6)

    /// Every template on disk (id / name / kind), shared by both windows. Loaded on bootstrap and
    /// after any template mutation. Drives the folder "Template ▸" assignment menu + "New from
    /// template" (06-viewers §6). Kept out of `allItems` so templates never appear in the note list.
    @Published var templates: [Template] = []
    /// One active editor per template across the Notes and Extracts windows. Each window has an
    /// independent body buffer; admitting two would let the later save overwrite the first.
    var templateEditOwners: [UUID: UUID] = [:]
    var failedTemplateBodySaves: Set<UUID> = []
    var failedTemplateBodyLoads: Set<UUID> = []
    /// Keep the unsaved body in the shared model if its editor pane disappears after a write error.
    /// Returning to that template reloads this draft rather than the stale on-disk body.
    var failedTemplateBodyDrafts: [UUID: String] = [:]
    /// The last template-body save started per template, which the next one waits for.
    var templateBodySaveTail: [UUID: Task<Bool, Never>] = [:]
    var deletedTemplateIDs: Set<UUID> = []

    /// The notes waiting in the store's Trash, newest deletion first (W40.fix-notes-delete-undo).
    /// Loaded on bootstrap and after every delete, put-back and empty.
    @Published var trashedNotes: [TrashedNote] = []
    /// Notes this session moved to the Trash (or found already gone while trashing). A refused draft
    /// of one can never be saved, so its emergency copy becomes its home (W40.fix-notes-held-draft-reopen).
    var trashedNoteIDs: Set<UUID> = []

    // MARK: Deterministic index-ready signal (§3.4 — XCUITest polls this before FTS/relevance asserts)

    /// `true` once the initial on-disk index build has settled (app path). A pure injected test store
    /// with no background indexer surfaces ready immediately (nothing to build), so the hidden probe
    /// still resolves rather than polling forever.
    @Published var isIndexReady = false
    /// Completion token mirrored from `NotesIndexer` — flips `0 → ≥1` once the initial build settles.
    /// Surfaced to XCUITest via the hidden `an.status.indexReady` element (08-testing §3.4).
    @Published var indexGeneration = 0
    /// Why the index is degraded, when it is (`nil` = healthy) — mirrored from `NotesIndexer.failure`
    /// after the build settles. `isIndexReady` above means *settled*, not *healthy*: it has to flip
    /// even on failure or `awaitSettled()` would never resume, so this is the honest health claim, and
    /// `bootstrap()` puts its message in `statusMessage` where the sidebar shows it (W23.m9).
    @Published var indexFailure: NotesIndexer.Failure?
    /// `true` while `reloadLibrary()` runs; the menu item is disabled meanwhile.
    @Published var isReloadingLibrary = false
    /// The index-health line this model last put in `statusMessage`, so it can be retracted when the
    /// index recovers — and *only* it. Without this, a recovered index either left a false "unavailable"
    /// banner up for the rest of the session or cleared a line some other failure had posted.
    var postedIndexMessage: String?
    /// Set when the folders shown read-only from `organization.json` could not be loaded into the
    /// recovered index, so the query path stops rescheduling that reload (W40.fix-notes-index-failure-empty).
    var mirrorReloadFailed = false
    /// The in-flight post-recovery rebuild (W23.m9-fu2) — `nil` when none is running.
    var indexRecoveryTask: Task<Void, Never>?

    // MARK: Current scope (drives the item list in W6-S3/S4)

    /// The active filter scope: `nil` = All Notes (no scope). A normal folder scopes by a folder rule
    /// (`NotesAdvancedSearch.folderScope`); a smart folder applies its decoded rules, and an Advanced Search
    /// run without saving is a scope too (`runAdvancedSearch`, neither folder selected).
    @Published var scope: NotesAdvancedSearch?
    /// Highlighted normal folder (nil when All Notes / a smart folder is selected).
    @Published var selectedFolderId: UUID?
    /// Highlighted smart folder (nil when All Notes / a normal folder is selected).
    @Published var selectedSmartId: UUID?

    /// Transient, user-facing status for degradations (cycle refused, unreadable smart query, orphaned
    /// items after a folder delete). The view surfaces it and clears it.
    @Published var statusMessage: String?

    // MARK: Tag changes across the apps (W40.tag-rename-suite; `NotesModel+TagRename`)

    /// The archives Notes can reach now, each with its root marker guid: where a rename is recorded and where other
    /// apps' changes are read. Set by the app from its Reader root store; empty in a model nobody wired.
    var archiveRoots: @MainActor () -> [(guid: UUID, url: URL)] = { [] }
    /// Where the handled lists are kept: nil is the app's own settings; tests pass a throwaway suite.
    var tagChangeDefaultsSuite: String?
    /// Which library the handled lists belong to; nil is the library's guid (tests set their own).
    var tagChangeLibraryKey: String?
    /// Other apps' changes waiting for the user's Apply or Skip, and withdrawals of ones Notes applied.
    @Published var tagChangeOffers: [TagChangeOffer] = []

    // MARK: Window ▸ Tags (W40.tag-window-notes; `NotesModel+TagsWindow`)

    /// The Tags window's model, made on first use (`tagsWindow`).
    var tagsWindowModel: TagsWindowModel?
    /// The Tags window's own undo manager (its NSWindow's: Edit ▸ Undo reads that one), where its changes go. Looked up
    /// when a change is made, as the window may not be attached yet when the view is built.
    var tagsWindowUndo: @MainActor () -> UndoManager? = { nil }
    /// The Tags window's Undo and Redo steps, one after another (`enqueueTagsWindowHistory`).
    var tagsWindowHistoryTail: Task<Void, Never>?
    /// What the Tags window asks of the Archive Notes window, which takes it when it shows (opened for it if closed):
    /// a tag sheet (Review… opens Tag Changes from Other Apps), or the list filtered to one tag (Show Notes).
    @Published var pendingTagSheet: NotesTagSheet?
    @Published var pendingShowTag: String?
    /// Counts list builds, so an older build finishing late never replaces a newer list.
    var tagsWindowGeneration = 0

    // MARK: In-app navigation (W7-S3 jump-to-source; also consumes external archivenotes:// opens)

    /// A request to reveal an item (and optionally scroll to a block) in the window that features its
    /// kind. Shared across both windows via this single model (§16.1) — the only cross-window channel.
    /// `token` makes a repeat request to the SAME `(id, block)` re-fire, so jumping to the same passage
    /// twice still scrolls (the coalescing-counter idiom, cf. Reader `NavigationModel.requestScroll`).
    struct OpenRequest: Equatable, Sendable {
        let id: UUID
        let block: Int?
        let token: Int
    }
    /// The current pending open request; the featuring window observes it, selects the item + scrolls,
    /// then calls `consumeOpen()`. `nil` when nothing is pending.
    @Published private(set) var pendingOpen: OpenRequest?
    private var openToken = 0

    /// In-process navigation entry point (§16.1) — called by W7's jump-to-source chip and by the
    /// `archivenotes://open` URL router. Publishes an `OpenRequest`; the featuring window consumes it.
    /// Pure signal: resolution/degradation (deleted note, wrong kind, stale ordinal) is the observer's
    /// job via `resolvePassage`/`NotePassageResolve` — this never throws and never touches the store.
    func openItem(id: UUID, block: Int?) {
        openToken &+= 1
        pendingOpen = OpenRequest(id: id, block: block, token: openToken)
    }

    /// Reveal a note's own Markdown file in Finder. The path is derived from NoteStore, and Finder
    /// only selects the file; all note-store writes remain behind NoteStore.
    func revealInFinder(_ id: UUID) async {
        guard let noteStore else { return }
        do {
            let url = try await noteStore.mdURL(for: id)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { statusMessage = "Couldn't reveal the note in Finder." }
    }

    /// Copy a path-independent link that opens this note or extract. The single-link action writes
    /// plain text so external writing tools receive a clickable `archivenotes://open` URL.
    @discardableResult
    func copyOpenLink(for id: UUID, to pasteboard: NSPasteboard = .general) -> Bool {
        let link = DurableLink.notesOpen(id: id, block: nil).url.absoluteString
        pasteboard.clearContents()
        guard pasteboard.setString(link, forType: .string) else { return false }
        statusMessage = "Copied Notes link."
        return true
    }

    /// File ▸ New Template… with no window open (W40.fix-notes-templates): the Notes window, opened for it,
    /// clears this and shows its templates manager with the New Template sheet.
    @Published var pendingNewTemplate = false

    /// Clear the pending open request once a window has handled it.
    func consumeOpen() {
        pendingOpen = nil
    }

    /// Resolve a note-passage provenance anchor against the current item set (W7-S3 degradation logic).
    func resolvePassage(_ anchor: SourceAnchor) -> PassageResolution {
        NotePassageResolve.resolve(anchor: anchor, among: allItems)
    }

    // MARK: App-path lifecycle (nil when a test injects a pre-loaded store)

    private let ownsDataLayer: Bool
    let index: NotesIndex?
    private let rootStore: RootFolderStore?
    /// Background full-index driver (app path) — shares `index`'s sqlite handle so there is one
    /// connection to the file. Injectable for tests that exercise the disk-build / ready-signal path;
    /// `nil` for a pure injected store.
    let indexer: NotesIndexer?
    /// The only file-deleting layer (W2, §16.1). Built in `bootstrap()` on the app path; injectable for
    /// tests. `delete(_:)` moves an item dir to the store's `Trash/` (Put Back) — never `removeItem`.
    var noteStore: NoteStore?
    private var didBootstrap = false

    #if DEBUG
    /// Test-only seam to force index projections to arrive in the opposite order from their writes.
    /// Production builds contain no hook.
    var indexProjectionTestHook: (@Sendable (NoteIndexRow) async -> Void)?

    /// Awaited inside `trashItems` while the hard-delete window is open and before anything has been
    /// trashed, so a test can deterministically drive a concurrent replicate/move *into* the window
    /// (W23.h3-fu). DEBUG-only and instance-scoped — same shape as `NotesIndex.executeForTesting`.
    var hardDeleteWindowHookForTesting: (@MainActor () async -> Void)?
    #endif

    /// Where the app-lifecycle triggers for the stale-mirror retry come from (W23.m10-fu) — `.default`
    /// in the app, a private centre under test so one posted notification reaches one model.
    private let notificationCenter: NotificationCenter
    /// Kept so the observers die with the model rather than outliving it on a shared centre.
    private var mirrorRecoveryObservers: NotificationObservers?
    /// The mirror-health line this model last put in `statusMessage`, so it can be retracted when the
    /// mirror recovers — and *only* it. The `postedIndexMessage` idiom, for the other degradation.
    private var postedMirrorMessage: String?

    // MARK: Init

    /// Injection init (tests, previews): the caller provides an already-loaded `OrganizationStore`.
    ///
    /// `notificationCenter` is the seam the mirror-recovery triggers are attached to (W23.m10-fu);
    /// tests pass their own so a posted app notification reaches exactly one model.
    init(organization: OrganizationStore, notificationCenter: NotificationCenter = .default) {
        self.organization = organization
        self.ownsDataLayer = false
        self.index = nil
        self.rootStore = nil
        self.indexer = nil
        self.notificationCenter = notificationCenter
        rebuild()
        observeMirrorRecoveryTriggers()
    }

    /// Injection init with a live index — for tests that exercise FTS `search(_:)` or the W6-S5 delete
    /// path (`noteStore`). Like `init(organization:)` but routes keyword search to a real `NotesIndex`
    /// and, when a `noteStore` is supplied, the delete-last-instance path to a real (scratch) store. It
    /// still does **not** own the data layer (`bootstrap()` stays a no-op), so callers seed items via
    /// `replaceItems`.
    init(organization: OrganizationStore, index: NotesIndex, noteStore: NoteStore? = nil,
         indexer: NotesIndexer? = nil, notificationCenter: NotificationCenter = .default) {
        self.organization = organization
        self.ownsDataLayer = false
        self.index = index
        self.rootStore = nil
        self.noteStore = noteStore
        self.indexer = indexer
        self.notificationCenter = notificationCenter
        rebuild()
        observeMirrorRecoveryTriggers()
    }

    /// App init: build the real data layer (index + org store + store-root). The tree stays empty
    /// until `bootstrap()` runs (call it from a `.task` before first render) so no blocking I/O
    /// happens during `App` construction.
    convenience init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ArchiveNotes", isDirectory: true)
        let rootStore = RootFolderStore(readerRoots: ReaderRootStore.savedRootFolders())
        let index = NotesIndex(url: Self.indexDatabaseURL(
            inAppSupport: appSupport, storeRoot: rootStore.root, storeGUID: rootStore.marker?.guid))
        self.init(organization: OrganizationStore(index: index),
                  index: index,
                  rootStore: rootStore)
    }

    /// File ▸ New Library… and Open Library… (W40.fix-notes-choose-store, W49.notes-store-format). `nil` for
    /// an injected (test) store.
    lazy var storeFolderChooser: StoreFolderChooser? = {
        guard let rootStore else { return nil }
        let chooser = StoreFolderChooser(rootStore: rootStore)
#if DEBUG
        // The NSOpenPanel is the one step an XCUITest cannot drive: under the harness,
        // `-ANUITestStorePickPath` stands in for the folder a person would pick, as
        // `-ANUITestRootPickPath` does for Choose Archive Folder…. The check, confirmation, bookmark and
        // quit after it are the production path.
        if let p = UserDefaults.standard.string(forKey: "ANUITestStorePath"), !p.isEmpty,
           let pick = UserDefaults.standard.string(forKey: "ANUITestStorePickPath"), !pick.isEmpty {
            chooser.pickFolder = { URL(fileURLWithPath: pick, isDirectory: true) }
        }
        // `-ANUITestNewLibraryPath` does the same for New Library…'s Save panel.
        if let p = UserDefaults.standard.string(forKey: "ANUITestStorePath"), !p.isEmpty,
           let new = UserDefaults.standard.string(forKey: "ANUITestNewLibraryPath"), !new.isEmpty {
            chooser.pickNewLibrary = { _ in URL(fileURLWithPath: new, isDirectory: true) }
        }
#endif
        return chooser
    }()

    // MARK: The open library (W49.notes-library-ux)

    /// The library this launch opened, or nil when none is (or for an injected test store). A switch restarts the
    /// app (`StoreFolderChooser`), so this never changes while it runs.
    var libraryURL: URL? { rootStore?.root }
    /// The library's own identity, for the per-library tag change lists (W40.tag-rename-suite).
    var libraryGUID: UUID? { rootStore?.marker?.guid }
    /// A library is open and its first index pass has settled (always, for a model handed its stores).
    var isLibrarySettled: Bool { ownsDataLayer ? rootStore?.root != nil && isIndexReady : true }

    /// Whether there is a library to make notes in. An injected (test) store always counts as one.
    var isLibraryOpen: Bool { ownsDataLayer ? rootStore?.root != nil : true }

    /// The library's name as Finder shows it, for the sidebar. Not the window's subtitle: that joins the window's
    /// accessibility title ("Archive Notes – <name>"), which every UITest finds the window by.
    var libraryName: String? { libraryURL?.deletingPathExtension().lastPathComponent }

    /// File ▸ Open Recent; nil for an injected (test) store.
    var recentLibraries: RecentLibraries? { rootStore?.recentLibraries }

    /// File ▸ Reveal Library in Finder: Finder selects the library package; nothing is written.
    func revealLibraryInFinder() {
        guard let libraryURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([libraryURL])
    }

    /// The first launch has no library (there is no hidden default store; owner, 2026-11-20, call 24), so it
    /// offers the Save panel at once, with `~/Documents` proposed. Cancelling leaves the app with no library and
    /// the status line saying how to make or open one. Never under a test host: a panel there has nobody to
    /// answer it.
    private func askForFirstLibrary() {
        guard !ArchiveTestHost.isUnitTestHost, let chooser = storeFolderChooser else { return }
#if DEBUG
        if RootFolderStore.uiTestNoLibrary { return }
#endif
        // From the run loop, not a `Task`: Make Library ends in Restart and Switch, whose quit hung inside a
        // main-queue job (`StoreFolderChooser.onMainRunLoop`).
        StoreFolderChooser.onMainRunLoop {
            // A launch by double-clicking a library asks to switch to that one instead.
            guard !StoreFolderChooser.libraryArrivedFromFinder else { return }
            chooser.newLibraryWithCloudCheck(readerRoots: ReaderRootStore.savedRootFolders(), firstLaunch: true)
        }
    }

    /// The index database for a store. The folder graph lives in the index first and in the store's
    /// `organization.json` second (`OrganizationStore.load`), so two stores must never share one: the
    /// second would show the first one's folders and then write them over its own mirror. Each store gets
    /// a file named for its marker's GUID and its path together, so a store picked for the first time (one copied from another computer, or a
    /// different store later put at the same path) starts from an empty index and reads its own
    /// `organization.json` (W40.fix-notes-choose-store). The index is a rebuildable cache, so a store
    /// that moves only costs a rebuild.
    /// With no store open (`storeRoot` nil) nothing is indexed; that launch gets a name of its own, never
    /// `notes-index-v1.sqlite3`, which belonged to the container store used before W49.notes-store-format.
    nonisolated static func indexFileName(storeRoot: URL?, storeGUID: UUID?) -> String {
        func canonical(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
        guard let storeRoot else { return "notes-index-v1-no-library.sqlite3" }
        let identity = (storeGUID?.uuidString.lowercased() ?? "no-marker") + "\n" + canonical(storeRoot)
        let digest = SHA256.hash(data: Data(identity.utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "notes-index-v1-\(hex).sqlite3"
    }

    /// The content-index database URL. Normally `notes-index-v1.sqlite3` in Application Support (the
    /// app *container* when sandboxed). Under XCUITest (`-ANUITestStorePath`), a dedicated
    /// `notes-index-uitest.sqlite3` that is RESET on every launch — so a persisted organization graph
    /// can never shadow the fixture's `organization.json` across GUI runs. `OrganizationStore.load`
    /// reads the folder graph DB-first and consults `organization.json` only when the DB has zero
    /// folders (see its `load(storeRoot:)`); a stale container DB from a prior run would otherwise hide
    /// the fixture's folders/replication (the state the W8-S8 G7/G8 checks assert on). The index is a
    /// rebuildable cache — resetting it loses nothing — and the distinct filename keeps the owner's real
    /// `notes-index-v1.sqlite3` untouched. DEBUG-only: the override is compiled out of Release, so the
    /// shipping app can only ever open `notes-index-v1.sqlite3`.
    private static func indexDatabaseURL(inAppSupport appSupport: URL, storeRoot: URL?, storeGUID: UUID?) -> URL {
#if DEBUG
        if let path = UserDefaults.standard.string(forKey: "ANUITestStorePath"), !path.isEmpty {
            let fixtureRoot = URL(fileURLWithPath: path).standardizedFileURL
            let fixtureIndex = fixtureRoot.appendingPathComponent("notes-index-v1.sqlite3").standardizedFileURL
            if let requested = UserDefaults.standard.string(forKey: "ANUITestIndexPath"), !requested.isEmpty,
               URL(fileURLWithPath: requested).standardizedFileURL == fixtureIndex,
               isGeneratedNotesFixture(fixtureRoot) {
                // W23.m9-fu3: an explicit, marker-checked scratch fixture cache lets the GUI lane
                // exercise corruption and repair without opening or replacing the app-container DB.
                return fixtureIndex
            }
            let uitestURL = appSupport.appendingPathComponent("notes-index-uitest.sqlite3")
            resetUITestIndexDatabase(at: uitestURL)
            return uitestURL
        }
#endif
        return appSupport.appendingPathComponent(indexFileName(storeRoot: storeRoot, storeGUID: storeGUID))
    }

#if DEBUG
    private static func isGeneratedNotesFixture(_ root: URL) -> Bool {
        guard let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return false }
        let marker = root.appendingPathComponent(".archive-suite-root.json")
        guard let data = try? Data(contentsOf: marker),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["guid"] as? String == "a11ce5e7-1000-4000-8000-000000000001"
            && object["name"] as? String == "AN-GUI-Fixture"
            && object["kind"] as? String == "notes"
    }

    /// Delete the UITest index DB (plus its `-wal`/`-shm` sidecars) and ensure its parent directory
    /// exists, so each XCUITest launch opens a fresh, empty index. Only ever touches the
    /// `notes-index-uitest.sqlite3` triple — never the real `notes-index-v1.sqlite3`, never the store,
    /// never a corpus. Errors are non-fatal (a missing file is the desired post-state anyway).
    private static func resetUITestIndexDatabase(at url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            try? fm.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }
#endif

    private init(organization: OrganizationStore, index: NotesIndex, rootStore: RootFolderStore) {
        self.organization = organization
        self.ownsDataLayer = true
        self.index = index
        self.rootStore = rootStore
        self.indexer = NotesIndexer(index: index)   // shares the one NotesIndex handle
        self.notificationCenter = .default
        // Tree stays empty until bootstrap().
        observeMirrorRecoveryTriggers()
    }

    /// App path only: open the index and load persisted organization, then rebuild. Idempotent — safe
    /// to call from a `.task` that may re-run. A no-op for an injected (test) store.
    func bootstrap() async {
        guard ownsDataLayer, !didBootstrap else { return }
        didBootstrap = true
        guard let index, let rootStore, let root = rootStore.root else {
            // No store chosen yet: nothing to index. Still flip ready so the probe resolves.
            if rootStore?.savedRootUnavailable == true {
                statusMessage = "The chosen library can't be opened, or is not an Archive Notes library. "
                    + "Open a library with File ▸ Open Library…, or make one with File ▸ New Library…."
            } else if rootStore?.needsLibrary == true {
                statusMessage = "No library is open. Make one with File ▸ New Library…, "
                    + "or open one with File ▸ Open Library…."
                askForFirstLibrary()
            }
            rebuild(); markIndexReady(generation: max(indexGeneration, 1)); return
        }
        noteStore = NoteStore(root: root)
        do {
            try await index.open()
            do {
                try await organization.load(storeRoot: root)
            } catch {
                // `load` has left the folders on show read-only from the mirror rather than adopt a
                // graph it could not read whole (W40.fix-notes-index-failure-empty-fu1).
                report(error, "open the notes store")
            }
        } catch {
            // The folder graph lives in the index. Show it from its `organization.json` mirror rather
            // than an empty sidebar; the index failure itself is reported by the build below
            // (W40.fix-notes-index-failure-empty).
            organization.loadReadOnlyMirror(storeRoot: root)
        }
        rebuild()
        await reloadItems()          // fast first paint from whatever is already indexed
        await reloadTemplates()
        await reloadTrash()
        await buildIndexFromDisk()   // (re)build the disposable index from disk, then flip ready (§3.4)
    }

    // MARK: Pure & shared helpers

    /// A fresh, empty item shell (schema 1) — a blank new item or a new template.
    func blankItem(kind: Item.Kind, title: String) -> Item {
        let now = Date()
        return Item(id: UUID(), kind: kind, title: title, date: nil,
                    datePrecision: nil, dateUncertain: false, quality: nil, tags: [],
                    zotero: [], roundup: false, created: now, modified: now, schema: 1,
                    blocks: [], unknownFrontMatter: [], trailingBodyRaw: nil)
    }

    /// Would moving `id` under `newParent` create a cycle? True if `newParent == id` or `id` is an
    /// ancestor of `newParent`. Mirrors `OrganizationStore.wouldCreateCycle` so the view can explain a
    /// refused move; a `guardCount` cap makes it total even against a corrupt graph.
    func wouldCreateCycle(moving id: UUID, to newParent: UUID?) -> Bool {
        guard let newParent else { return false }
        if newParent == id { return true }
        let byID = Dictionary(organization.folders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var cursor: UUID? = newParent
        var guardCount = 0
        while let c = cursor, guardCount < 100_000 {
            if c == id { return true }
            cursor = byID[c]?.parentId
            guardCount += 1
        }
        return false
    }

    /// A sibling-unique folder name: returns `base` if no sibling under `parent` (other than
    /// `excluding`) already uses it (case-insensitively), else `base 2`, `base 3`, … until free.
    func uniqueSiblingName(_ base: String, parent: UUID?, excluding: UUID?) -> String {
        let taken = Set(organization.folders
            .filter { $0.parentId == parent && $0.id != excluding }
            .map { $0.name.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    /// Say so when an organization mutation committed but its durable mirror didn't (W23.m10).
    ///
    /// Called at the END of each organization-mutating path — last, so a real degradation wins over
    /// that path's own status text. The change itself DID commit (SQLite + in memory), so every caller
    /// still completes its UI work and still returns what it created: this only stops the app from
    /// presenting a half-saved change as saved. Never clears a message it didn't set (`statusMessage`
    /// is shared with other degradations), matching `adoptIndexFailure`.
    ///
    /// It also *retracts* its own line once the mirror is back in sync (W23.m10-fu). Before the
    /// recovery retry below, the only way to reach `mirrorFailure == nil` here was a later successful
    /// mutation, and leaving the warning up through it was merely untidy; now that a retry can heal the
    /// mirror with the operator doing nothing at all, a line still claiming the durable mirror is
    /// behind would be a false statement the app never takes back.
    ///
    /// While a mirror write is still pending this does nothing (W49.notes-org-export-async): the outcome
    /// on show would be the previous write's, and `onMirrorOutcome` calls back here when the pending
    /// one lands, which is still after the path's own status text.
    func adoptMirrorFailure() {
        guard !organization.isMirrorWritePending else { return }
        if let failure = organization.mirrorFailure {
            statusMessage = failure.message
            postedMirrorMessage = failure.message
        } else {
            // Only our own line — another subsystem's report must survive the mirror recovering.
            if let posted = postedMirrorMessage, statusMessage == posted { statusMessage = nil }
            postedMirrorMessage = nil
        }
    }

    /// Re-attempt a durable-mirror export that failed earlier, and update what the sidebar says
    /// (W23.m10-fu). A no-op unless `organization.isMirrorStale`, so it costs nothing on a healthy
    /// store and never rewrites `organization.json` behind the operator's back.
    ///
    /// Wired to the two moments that matter (see `observeMirrorRecoveryTriggers`), and public so the
    /// app can call it from anywhere else that turns out to be a good moment.
    ///
    /// The status line is updated by `onMirrorOutcome` when the retry's write lands
    /// (W49.notes-org-export-async). Adopting here, before it lands, would re-post the old warning over
    /// whatever another subsystem has said since, even when the retry is about to succeed.
    func retryStaleMirrorExport() {
        organization.retryStaleMirrorExport()
    }

    /// Retry the stale-mirror export when the app is **activated** and when it is about to **quit**.
    ///
    /// Activation is the moment the operator comes back to the app — the one correlated with having
    /// plugged the volume in, emptied the disk, or fixed permissions in another app — and it doubles as
    /// the re-post of a warning that was dismissed while the volume is still bad, the way a degraded
    /// index re-posts on every read (W23.m9-fu). Terminate is the last chance to write the mirror
    /// before the session ends, after which the stale file is what the next launch inherits (the DB
    /// wins at startup, so nothing else re-syncs it).
    ///
    /// Deliberately **not** a timer: this app does no background polling (the Zotero clipboard check
    /// makes the same call), and the export is a disk write — tying it to something the operator did
    /// keeps it to moments a write is expected. `queue: nil` runs the block synchronously on the
    /// poster's thread, which is what makes the terminate leg useful at all; AppKit posts both of these
    /// on the main thread, hence `assumeIsolated`.
    ///
    /// Mirror writes are coalesced and run off the main actor (W49.notes-org-export-async), so the
    /// outcome of a mutation's write arrives after the mutation's own `adoptMirrorFailure()`;
    /// `onMirrorOutcome` adopts it again when it lands. The terminate leg writes synchronously, both
    /// what is still pending and a stale mirror, because the process ends when the notification returns.
    private func observeMirrorRecoveryTriggers() {
        organization.onMirrorOutcome = { [weak self] in self?.adoptMirrorFailure() }
        let observers = NotificationObservers(center: notificationCenter)
        observers.observe(NSApplication.didBecomeActiveNotification) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryStaleMirrorExport() }
        }
        observers.observe(NSApplication.willTerminateNotification) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.organization.flushMirrorSynchronously()
                self.adoptMirrorFailure()
            }
        }
        mirrorRecoveryObservers = observers
    }

    /// Report and refuse a create while the folders are read-only; `true` means refused.
    func refuseWhileFoldersReadOnly(_ action: String) -> Bool {
        guard organization.isReadOnlyMirror else { return false }
        report(OrganizationError.readOnlyWhileIndexUnavailable, action)
        return true
    }

    /// `true` (having set the explanation) when `id` is a system folder and the caller must stop
    /// (W23.m15). The sidebar disables Rename/Delete on those rows, so this is the second of three
    /// layers — the third is `OrganizationStore`'s own throw — but it is the one that produces a
    /// sentence the user can read, since `report` would only say "Couldn't delete the folder."
    func refuseSystemFolder(_ id: UUID) -> Bool {
        guard let name = OrganizationStore.systemFolderName(id) else { return false }
        statusMessage = "“\(name)” is a built-in folder — it can't be renamed or deleted."
        return true
    }

    func report(_ error: Error, _ action: String) {
        statusMessage = "Couldn't \(action)."
        NSLog("NotesModel: failed to \(action): \(error)")
    }
}

/// Block-based notification observers whose lifetime is the object that owns this box (W23.m10-fu).
///
/// A separate, *non-isolated* class on purpose: a `@MainActor` type's `deinit` is nonisolated and so
/// cannot read main-actor state, and the observer tokens (`[any NSObjectProtocol]`, not `Sendable`)
/// count as exactly that. Parking them here keeps the un-registration automatic — without it, every
/// model ever built would keep observing the shared centre for the life of the process.
private final class NotificationObservers {
    private let center: NotificationCenter
    private var tokens: [any NSObjectProtocol] = []

    init(center: NotificationCenter) { self.center = center }

    /// `queue: nil` is the documented "run the block **synchronously on the posting thread**" form, and
    /// that guarantee is what the terminate leg rests on: a block merely *scheduled* onto a queue has
    /// no promise of running before the process exits. (Measured: `queue: .main` also runs inline when
    /// the post is already on the main queue, so today it behaves the same — this is about depending on
    /// the contract rather than on that.) AppKit posts the notifications used here on the main thread.
    func observe(_ name: Notification.Name, using block: @escaping @Sendable (Notification) -> Void) {
        tokens.append(center.addObserver(forName: name, object: nil, queue: nil, using: block))
    }

    deinit { for token in tokens { center.removeObserver(token) } }
}
