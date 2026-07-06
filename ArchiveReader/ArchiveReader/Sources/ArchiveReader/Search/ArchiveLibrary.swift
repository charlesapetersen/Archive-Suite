import Foundation
import Combine

/// Discovers the tagged-PDF universe via Spotlight (`NSMetadataQuery`) and keeps it live-updated.
///
/// The master predicate is "has a Read or Unread tag" — the set of files Archive Reader cares about.
/// Each result carries its tags/name/type/dates from the Spotlight index, so building the list needs
/// no per-file disk I/O (the fast path at 150k). Tag facets here are for display/sort/filter only;
/// the authoritative read for a write is done inside `TagWriter`.
@MainActor
final class ArchiveLibrary: ObservableObject {
    @Published private(set) var files: [ArchiveFile] = []
    @Published private(set) var isGathering = false
    @Published private(set) var scopeDescription = "No folder selected"

    private let query = NSMetadataQuery()

    /// Display-only overrides that pin the *verified* on-disk tags of a just-written file, so a laggy
    /// Spotlight reload can't momentarily revert it. After a tag write, Spotlight fires `…DidUpdate`
    /// (the xattr changed) but frequently re-emits the OLD `kMDItemUserTags` until it re-indexes —
    /// which was clobbering the correct value with no guaranteed self-heal. An override renders
    /// `TagWriter`'s verified `.after` for that URL until Spotlight *value-converges* to it (then we
    /// trust Spotlight again) or a generous TTL leak-guard elapses (bounding how long a genuine
    /// third-party edit could be masked). This NEVER touches disk — it is pure in-memory reconciliation
    /// of Spotlight's tag-index lag: no write, and not even a read, so it cannot lose or mangle a tag.
    struct PendingWrite: Sendable { let after: [String]; let afterLabel: Int?; let deadline: Date }
    private var pending: [URL: PendingWrite] = [:]
    /// One coalesced non-repeating timer: guarantees a reload eventually fires to expire an override
    /// even if Spotlight goes completely silent. Nil (and none scheduled) whenever `pending` is empty.
    private var settleTimer: Timer?
    /// Leak-guard only, not the normal convergence path. Chosen well above observed Spotlight lag
    /// (seconds) so it essentially only fires for a genuinely-stuck index or a real external edit —
    /// where trusting Spotlight is then correct. Convergence normally drops the override far sooner.
    private static let overrideTTL: TimeInterval = 600

    init() {
        query.predicate = NSPredicate(format: "(kMDItemUserTags == %@) || (kMDItemUserTags == %@)",
                                      ReadState.read.rawValue, ReadState.unread.rawValue)
        query.valueListAttributes = [
            NSMetadataItemPathKey, NSMetadataItemFSNameKey, NSMetadataItemContentTypeKey,
            NSMetadataItemFSContentChangeDateKey, "kMDItemUserTags", "kMDItemFSLabel",
        ]
        let nc = NotificationCenter.default
        nc.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        nc.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    /// Start (or restart) discovery within a scope. `nil` scope searches the whole Mac (future use);
    /// v1 passes the user-granted archive root.
    func start(scope: URL?) {
        query.stop()
        if let scope {
            query.searchScopes = [scope]
            scopeDescription = scope.lastPathComponent
        } else {
            query.searchScopes = [NSMetadataQueryLocalComputerScope]
            scopeDescription = "This Mac"
        }
        files = []           // clear prior results so the "processing" spinner shows during (re)gather
        pending.removeAll(); settleTimer?.invalidate(); settleTimer = nil   // no override may leak across roots
        isGathering = true
        query.start()
    }

    /// Reflect a batch of *verified* `TagWriter` results in the model immediately (so rows leave a
    /// filtered view at once) and pin them against Spotlight's index lag until it catches up. Pass only
    /// verified (non-throwing) results — a failed write must not move its row (Safety §11). The pinned
    /// value is `TagWriter`'s re-read `.after`/`.afterLabel` (ground truth), never a reconstruction from
    /// the model's own possibly-stale tags. Display-only: no disk write, no disk read.
    func applyVerifiedWrites(_ results: [TagWriteResult]) {
        guard !results.isEmpty else { return }
        let deadline = Date(timeIntervalSinceNow: Self.overrideTTL)
        for r in results { pending[r.url] = PendingWrite(after: r.after, afterLabel: r.afterLabel, deadline: deadline) }
        let byURL = pending                       // snapshot for one O(N) pass, one @Published emit
        files = files.map { f in
            guard let p = byURL[f.url] else { return f }
            return Self.rebuilt(f, after: p.after, afterLabel: p.afterLabel)
        }
        armSettleTimer()
    }

    private static func rebuilt(_ f: ArchiveFile, after: [String], afterLabel: Int?) -> ArchiveFile {
        ArchiveFile(url: f.url, name: f.name, fileType: f.fileType,
                    tags: DocumentTags.parse(raw: after, labelNumber: afterLabel), contentModified: f.contentModified)
    }

    /// Order-independent, case-insensitive tag-multiset equality — Spotlight and disk agree on tag case
    /// in practice, but comparing case-insensitively guarantees an override converges (drops) rather
    /// than being pinned until the TTL over a mere case/order difference. (macOS may reorder tags.)
    private static func sameTags(_ a: [String], _ b: [String]) -> Bool {
        a.map { $0.lowercased() }.sorted() == b.map { $0.lowercased() }.sorted()
    }
    private static func sameLabel(_ a: Int?, _ b: Int?) -> Bool { (a ?? 0) == (b ?? 0) }   // nil == 0 (no label)

    /// Pure reconciliation for one Spotlight-reported row that has a pending override. Returns the
    /// tags/label to DISPLAY and whether the override should be *kept* for the next reload:
    /// - Spotlight has value-converged to our verified write  → drop, trust Spotlight (identical value).
    /// - TTL leak-guard elapsed                                → drop, trust Spotlight (bounds masking).
    /// - otherwise (Spotlight still stale / not yet converged) → keep showing the verified `.after`.
    /// It only ever drops on convergence or expiry, so it can never *backslide* a correct row to a
    /// stale value within the TTL. No I/O — pure, hence unit-testable without a live Spotlight query.
    static func overrideDecision(spotlightTags: [String], spotlightLabel: Int?, pending p: PendingWrite,
                                 now: Date) -> (tags: [String], label: Int?, keep: Bool) {
        let converged = sameTags(spotlightTags, p.after) && sameLabel(spotlightLabel, p.afterLabel)
        if converged || now >= p.deadline { return (spotlightTags, spotlightLabel, false) }
        return (p.after, p.afterLabel, true)
    }

    /// (Re)arm a single non-repeating timer for the earliest pending deadline so an override still
    /// expires if Spotlight never sends another update. Invalidated (and left nil) once `pending` drains.
    /// Added in `.common` mode so it fires during table scrolling / splitter drags too.
    private func armSettleTimer() {
        settleTimer?.invalidate(); settleTimer = nil
        guard let earliest = pending.values.map(\.deadline).min() else { return }
        let t = Timer(timeInterval: max(1, earliest.timeIntervalSinceNow + 0.1), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        RunLoop.main.add(t, forMode: .common)
        settleTimer = t
    }

    private func reload() {
        query.disableUpdates()
        defer { query.enableUpdates() }

        let hasPending = !pending.isEmpty       // steady state: this whole overlay path is skipped
        var nextPending: [URL: PendingWrite] = [:]
        let now = Date()
        var out: [ArchiveFile] = []
        out.reserveCapacity(query.resultCount)
        for i in 0..<query.resultCount {
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            let url = URL(fileURLWithPath: path)
            let name = (item.value(forAttribute: NSMetadataItemFSNameKey) as? String) ?? url.lastPathComponent
            var tagArray = (item.value(forAttribute: "kMDItemUserTags") as? [String]) ?? []
            var label = item.value(forAttribute: "kMDItemFSLabel") as? Int
            let uti = item.value(forAttribute: NSMetadataItemContentTypeKey) as? String
            let modified = item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
            // Overlay a just-written, verified value over Spotlight's laggy echo until it converges or
            // the TTL fires. Only URLs still overriding are carried into `nextPending`, so converged /
            // expired / vanished-from-results entries are all GC'd in this same pass (no leak).
            if hasPending, let p = pending[url] {
                let d = Self.overrideDecision(spotlightTags: tagArray, spotlightLabel: label, pending: p, now: now)
                tagArray = d.tags; label = d.label
                if d.keep { nextPending[url] = p }
            }
            out.append(ArchiveFile(
                url: url, name: name, fileType: Self.shortType(uti: uti, url: url),
                tags: DocumentTags.parse(raw: tagArray, labelNumber: label), contentModified: modified))
        }
        if hasPending { pending = nextPending; armSettleTimer() }
        files = out
        isGathering = false
    }

    private static func shortType(uti: String?, url: URL) -> String {
        if uti == "com.adobe.pdf" { return "PDF" }
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? "File" : ext
    }
}
