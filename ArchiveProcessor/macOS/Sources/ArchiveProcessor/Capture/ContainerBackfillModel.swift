import Foundation
import ArchiveCore

/// W47.ct-backfill — Route A for material photographed before the apps (`SPEC/containers.md` §Backfill): a folder the
/// user chooses (Tools ▸ Read Box and Folder Labels) is scanned for its box and folder photos, each is read as at
/// capture (`ContainerLabelCapture.readLabel`: Vision + parser, and GPT 5.6 Luna on the gateway or Gemma on this Mac
/// when the user asks for it), and each directory's runs are proposed for the user to accept. Nothing is written into
/// the folder until a directory is accepted; then only its `.archivesuite/containers.json` (`ContainerBackfill.accept`).
/// The corpus PDFs' own text layer is never read (owner, 2026-10-30: no ABBYY text).
@MainActor
final class ContainerBackfillModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning
        case scanned
        case reading(done: Int, total: Int)
        case reviewing
    }

    enum RowStatus: Equatable {
        case waiting
        case proposed
        case accepting
        case written
        case skipped
        case unchanged
        case failed(String)
    }

    struct Row: Identifiable, Equatable {
        var id: String { directory.relativePath }
        let directory: ContainerBackfill.Directory
        var proposal: ContainerBackfill.Proposal?
        var status: RowStatus = .waiting
        /// Shown when the folder changed after its proposal and the proposal was made again.
        var note: String?
    }

    /// Above this the read asks again before it starts (the suite's $7 line for one piece of work), counting what this
    /// window has already spent.
    static let confirmAboveDollars = 7.0
    /// Reads in flight at once: the gateway took four at once in `ct-read.md`.
    static let concurrentReads = 4

    @Published private(set) var root: URL?
    @Published var colours: ItemTypeColors = .redBoxPurpleFolder
    @Published private(set) var scan: ContainerBackfill.Scan?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var rows: [Row] = []
    @Published var useModel = false
    @Published var levelsDraft: ContainerLevelsDraft?
    @Published var levelsError: String?
    @Published private(set) var message: String?
    /// Gateway calls this window made (each about `ContainerLabelCapture.gatewayDollarsPerLabel`).
    @Published private(set) var gatewayCalls = 0

    private var task: Task<Void, Never>?
    private var scanFlag: CancelFlag?
    /// Bumped by every choose, rescan and stop: a task's results land only while it is still the current one.
    private var generation = 0
    /// Whether the last read pass used a model, and which: its proposals are made from that pass's reads.
    private var readRoute: ContainerBackfillCache.Route = .vision
    private var reads: [String: ContainerBackfillCache.Entry] = [:]
    /// Each marker's size and modification time, taken once at the scan (`ContainerBackfillCache.stamp`).
    private var stamps: [URL: String] = [:]
    private let cache: ContainerBackfillCache
    /// A test seam: the read for one marker in place of Vision and the models (UI tests in the VM).
    var readOverride: (@Sendable (ContainerBackfill.Marker) async -> ContainerBackfillCache.Entry)?

    init(cache: ContainerBackfillCache = .standard) {
        self.cache = cache
    }

    var gateway: GatewayConfig? { GatewayConfig.fromDefaults() }

    /// What "use a model" would read with: the gateway's Luna (money), else Gemma on this Mac when a server lists it.
    var modelRoute: ContainerBackfillCache.Route {
        if let g = gateway, !g.isLocalModel { return .luna }
        return .gemma
    }

    private var requestedRoute: ContainerBackfillCache.Route { useModel ? modelRoute : .vision }

    var markers: [ContainerBackfill.Marker] { scan?.directories.flatMap(\.markers) ?? [] }

    private func key(_ marker: ContainerBackfill.Marker, _ route: ContainerBackfillCache.Route) -> String {
        cache.key(path: marker.url.path, stamp: stamps[marker.url] ?? "?", route: route)
    }

    /// The markers a read would still have to read (the rest are in the read cache from an earlier pass).
    var markersToRead: Int {
        let route = requestedRoute
        return markers.filter { reads[key($0, route)] == nil }.count
    }

    /// The up-front estimate in dollars: only a gateway read costs money.
    var estimatedDollars: Double {
        requestedRoute == .luna ? Double(markersToRead) * ContainerLabelCapture.gatewayDollarsPerLabel : 0
    }

    var spentDollars: Double { Double(gatewayCalls) * ContainerLabelCapture.gatewayDollarsPerLabel }

    var needsCostConfirmation: Bool {
        estimatedDollars > 0 && spentDollars + estimatedDollars > Self.confirmAboveDollars
    }

    var isBusy: Bool {
        switch phase {
        case .scanning, .reading: return true
        default: return false
        }
    }

    // MARK: Scan

    func choose(_ folder: URL) {
        root = folder.standardizedFileURL
        rescan()
    }

    func rescan() {
        guard let root else { return }
        stopTask()
        generation += 1
        let gen = generation
        phase = .scanning
        message = nil
        rows = []
        scan = nil
        stamps = [:]
        levelsDraft = nil
        levelsError = nil
        let colours = self.colours
        let flag = CancelFlag()
        scanFlag = flag
        let cache = self.cache
        task = Task { [weak self] in
            let result = await Task.detached { () -> (ContainerBackfill.Scan, [URL: String], [String: ContainerBackfillCache.Entry], Bool)? in
                guard let found = ContainerBackfill.scan(root: root, colours: colours, isCancelled: { flag.isSet })
                else { return nil }
                var stamps: [URL: String] = [:]
                for d in found.directories { for m in d.markers { stamps[m.url] = ContainerBackfillCache.stamp(of: m.url) } }
                let offerLevels = !ContainerBackfillModel.hasLevelMap(atOrAbove: root)
                    && found.fileDirectories.contains { !$0.isEmpty }
                return (found, stamps, cache.load(), offerLevels)
            }.value
            guard let self, gen == self.generation, let (found, stamps, loaded, offerLevels) = result else { return }
            self.reads.merge(loaded) { current, _ in current }
            self.stamps = stamps
            self.scan = found
            self.rows = found.directories.filter { !$0.markers.isEmpty }.map { Row(directory: $0) }
            self.phase = .scanned
            if offerLevels {
                self.levelsDraft = ContainerLevelsDraft.make(directories: found.fileDirectories, tree: root,
                                                             treePath: root.path)
            }
            if found.markerCount == 0 {
                self.message = "No box or folder photos were found: no file has a Box or Folder tag"
                    + (colours.isNone ? "." : ", or the colours chosen for older material.")
            }
        }
    }

    /// Whether the chosen folder or a folder above it holds a level map: the nearest one wins (SPEC §The level map),
    /// so a new one here would shadow it, and one there, readable or not, is the user's.
    nonisolated static func hasLevelMap(atOrAbove folder: URL) -> Bool {
        var dir = folder.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: ContainerFileStore.levelMapURL(in: dir).path) { return true }
            let up = dir.deletingLastPathComponent()
            if up.path == dir.path { return false }
            dir = up
        }
    }

    // MARK: Read

    func startReading() {
        guard root != nil, phase == .scanned || phase == .reviewing else { return }
        generation += 1
        let gen = generation
        let toRead = rows.filter { $0.status != .written }.map(\.directory)
        let route = requestedRoute
        readRoute = route
        let gateway = route == .vision ? nil : self.gateway
        // Cache hits are resolved here, on the main actor, so the reads in flight touch nothing of this model. A
        // model's read also stands for a Vision one; a Vision read kept after a model failed to answer does not stand
        // for a model's, so that photo is tried again.
        let work = toRead.flatMap { d in
            d.markers.map { m in
                let keys = (vision: key(m, .vision), model: key(m, route))
                return (d.relativePath, m, keys, reads[keys.model])
            }
        }
        let cache = self.cache
        let total = work.count
        var left: [String: Int] = [:]
        for d in toRead { left[d.relativePath] = d.markers.count }
        let override = readOverride
        phase = .reading(done: 0, total: total)
        message = nil
        task = Task { [weak self] in
            var done = 0
            var next = 0
            var finished: [String] = []
            // Reads that land after the window closed, saved straight into the cache below: they were paid for.
            var orphans: [String: ContainerBackfillCache.Entry] = [:]
            typealias Keys = (vision: String, model: String)
            typealias Result = (dir: String, keys: Keys, entry: ContainerBackfillCache.Entry?, visionAnswered: Bool,
                                called: Bool, modelAnswered: Bool)
            await withTaskGroup(of: Result.self) { group in
                func add() {
                    guard next < work.count else { return }
                    let (dir, marker, keys, hit) = work[next]
                    next += 1
                    group.addTask {
                        if let hit { return (dir, keys, hit, false, false, false) }
                        if Task.isCancelled { return (dir, keys, nil, false, false, false) }
                        if let override { return (dir, keys, await override(marker), true, false, route != .vision) }
                        let r = await Self.read(marker, gateway: gateway, route: route)
                        return (dir, keys, r?.entry, r?.visionAnswered ?? false, r?.gatewayCalled ?? false,
                                r?.modelAnswered ?? false)
                    }
                }
                for _ in 0..<Self.concurrentReads { add() }
                while let r = await group.next() {
                    // A read that arrives after Stop is still kept and counted: it was paid for. A read is kept under
                    // a route's key only when that route answered, so a failed one is tried again next time.
                    var keep: [String: ContainerBackfillCache.Entry] = [:]
                    if let entry = r.entry {
                        if r.visionAnswered || r.modelAnswered { keep[r.keys.vision] = entry }
                        if route != .vision, r.modelAnswered { keep[r.keys.model] = entry }
                    }
                    guard let self else {
                        orphans.merge(keep) { _, new in new }
                        group.cancelAll(); continue
                    }
                    if r.called { self.gatewayCalls += 1 }
                    for (k, entry) in keep where k == r.keys.model || self.reads[k] == nil { self.reads[k] = entry }
                    let dir = r.dir
                    guard gen == self.generation, !Task.isCancelled else { group.cancelAll(); continue }
                    done += 1
                    left[dir, default: 1] -= 1
                    if left[dir] == 0 { finished.append(dir) }
                    self.phase = .reading(done: done, total: total)
                    if done % 25 == 0 { self.saveCache() }
                    add()
                    // Proposals are made between reads, never while a result is half recorded.
                    for d in finished { await self.propose(d, generation: gen) }
                    finished = []
                }
            }
            guard let self else {
                if !orphans.isEmpty { cache.merge(orphans) }
                return
            }
            self.saveCache()
            guard gen == self.generation, !Task.isCancelled else { return }
            self.phase = .reviewing
        }
    }

    /// One marker's read off the main thread: a PDF's first page rendered to a temporary JPEG (deleted after), never
    /// its text layer.
    nonisolated private static func read(_ marker: ContainerBackfill.Marker, gateway: GatewayConfig?,
                                         route: ContainerBackfillCache.Route)
        async -> (entry: ContainerBackfillCache.Entry, visionAnswered: Bool, gatewayCalled: Bool, modelAnswered: Bool)? {
        let photo = await Task.detached { PDFToImageConverter.imageURL(for: marker.url) }.value
        defer { if photo != marker.url { try? FileManager.default.removeItem(at: photo) } }
        let r = await ContainerLabelCapture.readLabel(type: marker.type, text: "", photo: photo, rotation: 0,
                                                      gateway: gateway, useModel: route != .vision)
        return (ContainerBackfillCache.Entry(fields: r.fields, text: r.visionText), r.visionAnswered, r.gatewayCalled,
                r.modelAnswered)
    }

    private func containerMarkers(_ d: ContainerBackfill.Directory, route: ContainerBackfillCache.Route) -> [ContainerMarker] {
        d.markers.map { m in
            let entry = reads[key(m, route)] ?? reads[key(m, .vision)]
            return ContainerMarker(fileName: m.fileName, type: m.type, read: entry?.fields ?? ContainerFieldSet(),
                                   text: entry?.text)
        }
    }

    private func propose(_ relativePath: String, generation gen: Int) async {
        guard let i = rows.firstIndex(where: { $0.id == relativePath }) else { return }
        let d = rows[i].directory
        let markers = containerMarkers(d, route: readRoute)
        let proposal = await Task.detached { ContainerBackfill.propose(markers, in: d.url) }.value
        guard gen == generation, let j = rows.firstIndex(where: { $0.id == relativePath }),
              rows[j].status != .written, rows[j].status != .accepting else { return }
        rows[j].proposal = proposal
        switch proposal.state {
        case .ready: rows[j].status = .proposed
        case .unchanged: rows[j].status = .unchanged
        case .blocked(let why): rows[j].status = .failed(why)
        }
    }

    /// Stop: what is read so far is kept, and its folders already proposed stay proposed.
    func cancel() {
        let wasReading: Bool
        if case .reading = phase { wasReading = true } else { wasReading = false }
        let wasScanning = phase == .scanning
        stopTask()
        generation += 1
        if wasReading {
            phase = rows.contains { $0.proposal != nil } ? .reviewing : .scanned
            message = "Stopped. The labels read so far are kept, so reading again starts where this stopped."
        } else if wasScanning {
            phase = .idle
        }
        saveCache()
    }

    private func stopTask() {
        task?.cancel()
        task = nil
        scanFlag?.set()
        scanFlag = nil
    }

    private func saveCache() {
        cache.save(reads)
    }

    // MARK: Accept

    func accept(_ id: Row.ID) {
        guard let root, let i = rows.firstIndex(where: { $0.id == id }), let proposal = rows[i].proposal,
              rows[i].status == .proposed else { return }
        rows[i].status = .accepting
        rows[i].note = nil
        let gen = generation
        Task { [weak self] in
            let outcome: ContainerBackfill.AcceptOutcome
            do {
                outcome = try await Task.detached { try ContainerBackfill.accept(proposal, root: root) }.value
            } catch {
                guard let self, gen == self.generation else { return }
                self.setStatus(id, .failed("not written: \(error.localizedDescription)"))
                return
            }
            // A new scan or a Stop meanwhile: these rows are not the ones accepted (the write itself stands).
            guard let self, gen == self.generation else { return }
            switch outcome {
            case .wrote: self.setStatus(id, .written)
            case .unchanged: self.setStatus(id, .unchanged)
            case .refused(let why): self.setStatus(id, .failed(why))
            case .changedSinceRead:
                self.setStatus(id, .waiting)
                await self.propose(id, generation: self.generation)
                if let j = self.rows.firstIndex(where: { $0.id == id }), self.rows[j].status == .proposed {
                    self.rows[j].note = "The folder's container file changed after this was proposed; this is the new proposal."
                }
            }
        }
    }

    func skip(_ id: Row.ID) {
        guard let i = rows.firstIndex(where: { $0.id == id }), rows[i].status == .proposed else { return }
        setStatus(id, .skipped)
    }

    private func setStatus(_ id: Row.ID, _ status: RowStatus) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].status = status
        rows[i].note = nil
    }

    func saveLevels(_ draft: ContainerLevelsDraft) {
        guard let root, draft.tree == root else { levelsDraft = nil; return }
        levelsError = ProcessFilesTree.saveLevels(draft)
        if levelsError == nil { levelsDraft = nil }
    }
}

/// A flag a scan off the main thread polls, set by Stop or a new scan.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// The labels read by earlier passes, so reading a folder again, or after a Stop, reads only what is new and pays for
/// no read twice. Kept app-side (Application Support), never in the corpus. Keyed by the file's path, size and
/// modification time, and by the route that read it: a model's key holds only a read the model answered.
struct ContainerBackfillCache: Sendable {
    enum Route: String, Sendable { case vision, luna, gemma }

    struct Entry: Codable, Equatable, Sendable {
        var fields: ContainerFieldSet
        var text: String
    }

    let url: URL
    /// Saves run one after another in the order they were asked for, so an older snapshot never lands last.
    private static let queue = DispatchQueue(label: "ArchiveProcessor.containerBackfillCache")

    static var standard: ContainerBackfillCache {
#if DEBUG
        if ProcessorUITestConfiguration.isActive {
            return ContainerBackfillCache(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("APUITest-container-backfill-\(ProcessInfo.processInfo.processIdentifier).json"))
        }
#endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ContainerBackfillCache(url: base.appendingPathComponent("ArchiveProcessor/container-label-reads.json"))
    }

    /// A file's size and modification time, or "?" when it cannot be read.
    static func stamp(of file: URL) -> String {
        var st = stat()
        guard stat(file.path, &st) == 0 else { return "?" }
        return "\(st.st_size)|\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
    }

    func key(path: String, stamp: String, route: Route) -> String { "\(route.rawValue)|\(stamp)|\(path)" }

    /// Adds `entries` to what is on disk (theirs win), for reads that land after the window closed.
    func merge(_ entries: [String: Entry]) {
        let url = self.url
        Self.queue.async {
            var all = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
            all.merge(entries) { _, new in new }
            guard let data = try? JSONEncoder().encode(all) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    func load() -> [String: Entry] {
        Self.queue.sync {
            guard let data = try? Data(contentsOf: url) else { return [:] }
            return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
        }
    }

    func save(_ entries: [String: Entry]) {
        let url = self.url
        Self.queue.async {
            guard let data = try? JSONEncoder().encode(entries) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
