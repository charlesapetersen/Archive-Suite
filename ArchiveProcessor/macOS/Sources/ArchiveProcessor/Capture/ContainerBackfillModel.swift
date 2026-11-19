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

    /// Above this the read asks again before it starts (the suite's $7 line for one piece of work).
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
    /// Whether the last read pass used a model: its proposals are made from that pass's reads.
    private var readWithModel = false
    private var reads: [String: ContainerBackfillCache.Entry] = [:]
    private let cache: ContainerBackfillCache
    /// A test seam: the read for one marker in place of Vision and the models (UI tests in the VM).
    var readOverride: (@Sendable (ContainerBackfill.Marker) async -> ContainerBackfillCache.Entry)?

    init(cache: ContainerBackfillCache = .standard) {
        self.cache = cache
    }

    var gateway: GatewayConfig? { GatewayConfig.fromDefaults() }

    /// What "use a model" would read with: the gateway's Luna (money), else Gemma on this Mac when a server lists it.
    enum ModelRoute: Equatable { case gateway, localModel }
    var modelRoute: ModelRoute {
        if let g = gateway, !g.isLocalModel { return .gateway }
        return .localModel
    }

    var markers: [ContainerBackfill.Marker] { scan?.directories.flatMap(\.markers) ?? [] }

    /// The markers a read would still have to read (the rest are in the read cache from an earlier pass).
    var markersToRead: Int {
        markers.filter { reads[cache.key(for: $0.url, withModel: useModel)] == nil }.count
    }

    /// The up-front estimate in dollars: only a gateway read costs money.
    var estimatedDollars: Double {
        useModel && modelRoute == .gateway ? Double(markersToRead) * ContainerLabelCapture.gatewayDollarsPerLabel : 0
    }

    var needsCostConfirmation: Bool { estimatedDollars > Self.confirmAboveDollars }

    var isBusy: Bool {
        switch phase {
        case .scanning, .reading: return true
        default: return false
        }
    }

    // MARK: Scan

    func choose(_ folder: URL) {
        cancel()
        root = folder.standardizedFileURL
        rescan()
    }

    func rescan() {
        guard let root else { return }
        cancel()
        phase = .scanning
        message = nil
        rows = []
        scan = nil
        let colours = self.colours
        task = Task { [weak self] in
            let found = await Task.detached { ContainerBackfill.scan(root: root, colours: colours) }.value
            guard let self, !Task.isCancelled, let found else { return }
            self.reads = await Task.detached { [cache] in cache.load() }.value
            self.scan = found
            self.rows = found.directories.filter { !$0.markers.isEmpty }.map { Row(directory: $0) }
            self.phase = .scanned
            if ContainerFileStore.loadLevelMap(root: root) == .missing, found.fileDirectories.contains(where: { !$0.isEmpty }) {
                self.levelsDraft = ContainerLevelsDraft.make(directories: found.fileDirectories, tree: root,
                                                             treePath: root.path)
            }
            if found.markerCount == 0 {
                self.message = "No box or folder photos were found: no file has a Box or Folder tag"
                    + (colours.isNone ? "." : ", or the colours chosen for older material.")
            }
        }
    }

    // MARK: Read

    func startReading() {
        guard root != nil, phase == .scanned || phase == .reviewing else { return }
        let toRead = rows.map(\.directory)
        let withModel = useModel
        readWithModel = withModel
        let gateway = withModel ? self.gateway : nil
        let total = toRead.reduce(0) { $0 + $1.markers.count }
        phase = .reading(done: 0, total: total)
        message = nil
        task = Task { [weak self] in
            guard let self else { return }
            var done = 0
            var left: [String: Int] = [:]
            for d in toRead { left[d.relativePath] = d.markers.count }
            // Cache hits are resolved here, on the main actor, so the reads in flight touch nothing of this model.
            let work = toRead.flatMap { d in
                d.markers.map { m in (d.relativePath, m, self.reads[self.cache.key(for: m.url, withModel: withModel)]) }
            }
            let override = self.readOverride
            var next = 0
            await withTaskGroup(of: (String, ContainerBackfill.Marker, ContainerBackfillCache.Entry, Bool)?.self) { group in
                func add() {
                    guard next < work.count else { return }
                    let (dir, marker, hit) = work[next]
                    next += 1
                    group.addTask {
                        if let hit { return (dir, marker, hit, false) }
                        guard !Task.isCancelled else { return nil }
                        if let override { return (dir, marker, await override(marker), false) }
                        return await Self.read(marker, gateway: gateway, withModel: withModel)
                            .map { (dir, marker, $0.entry, $0.gatewayCalled) }
                    }
                }
                for _ in 0..<Self.concurrentReads { add() }
                while let result = await group.next() {
                    if Task.isCancelled { group.cancelAll(); continue }
                    if let (dir, marker, entry, called) = result {
                        self.reads[self.cache.key(for: marker.url, withModel: withModel)] = entry
                        if called { self.gatewayCalls += 1 }
                        left[dir, default: 1] -= 1
                        if left[dir] == 0 { await self.propose(dir) }
                    }
                    done += 1
                    self.phase = .reading(done: done, total: total)
                    if done % 25 == 0 { self.saveCache() }
                    add()
                }
            }
            self.saveCache()
            guard !Task.isCancelled else { return }
            self.phase = .reviewing
        }
    }

    /// One marker's read off the main thread: a PDF's first page rendered to a temporary JPEG (deleted after), never
    /// its text layer.
    nonisolated private static func read(_ marker: ContainerBackfill.Marker, gateway: GatewayConfig?,
                                         withModel: Bool) async -> (entry: ContainerBackfillCache.Entry, gatewayCalled: Bool)? {
        let photo = await Task.detached { PDFToImageConverter.imageURL(for: marker.url) }.value
        defer { if photo != marker.url { try? FileManager.default.removeItem(at: photo) } }
        guard !Task.isCancelled else { return nil }
        let r = await ContainerLabelCapture.readLabel(type: marker.type, text: "", photo: photo, rotation: 0,
                                                      gateway: gateway, useModel: withModel)
        return (ContainerBackfillCache.Entry(fields: r.fields, text: r.visionText), r.gatewayCalled)
    }

    private func containerMarkers(_ d: ContainerBackfill.Directory, withModel: Bool) -> [ContainerMarker] {
        d.markers.map { m in
            let entry = reads[cache.key(for: m.url, withModel: withModel)]
            return ContainerMarker(fileName: m.fileName, type: m.type, read: entry?.fields ?? ContainerFieldSet(),
                                   text: entry?.text)
        }
    }

    private func propose(_ relativePath: String) async {
        guard let i = rows.firstIndex(where: { $0.id == relativePath }) else { return }
        let d = rows[i].directory
        let markers = containerMarkers(d, withModel: readWithModel)
        let proposal = await Task.detached { ContainerBackfill.propose(markers, in: d.url) }.value
        guard let j = rows.firstIndex(where: { $0.id == relativePath }) else { return }
        rows[j].proposal = proposal
        switch proposal.state {
        case .ready: rows[j].status = .proposed
        case .unchanged: rows[j].status = .unchanged
        case .blocked(let why): rows[j].status = .failed(why)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if case .reading = phase {
            phase = rows.contains { $0.proposal != nil } ? .reviewing : .scanned
            message = "Stopped. The labels read so far are kept, so reading again starts where this stopped."
        } else if phase == .scanning {
            phase = .idle
        }
        saveCache()
    }

    private func saveCache() {
        let snapshot = reads
        let cache = self.cache
        Task.detached { cache.save(snapshot) }
    }

    // MARK: Accept

    func accept(_ id: Row.ID) {
        guard let root, let i = rows.firstIndex(where: { $0.id == id }), let proposal = rows[i].proposal,
              rows[i].status == .proposed else { return }
        Task { [weak self] in
            let outcome: ContainerBackfill.AcceptOutcome
            do {
                outcome = try await Task.detached { try ContainerBackfill.accept(proposal, root: root) }.value
            } catch {
                self?.setStatus(id, .failed("not written: \(error.localizedDescription)"))
                return
            }
            guard let self else { return }
            switch outcome {
            case .wrote: self.setStatus(id, .written)
            case .unchanged: self.setStatus(id, .unchanged)
            case .refused(let why): self.setStatus(id, .failed(why))
            case .changedSinceRead:
                await self.propose(id)
                if let j = self.rows.firstIndex(where: { $0.id == id }) {
                    self.rows[j].note = "The folder's container file changed after this was proposed; this is the new proposal."
                }
            }
        }
    }

    func skip(_ id: Row.ID) { setStatus(id, .skipped) }

    private func setStatus(_ id: Row.ID, _ status: RowStatus) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].status = status
        rows[i].note = nil
    }

    func saveLevels(_ draft: ContainerLevelsDraft) {
        levelsError = ProcessFilesTree.saveLevels(draft)
        if levelsError == nil { levelsDraft = nil }
    }
}

/// The labels read by earlier passes, so reading a folder again, or after a Stop, reads only what is new and pays for
/// no read twice. Kept app-side (Application Support), never in the corpus. Keyed by the file's path, size and
/// modification time, and by whether a model read it.
struct ContainerBackfillCache: Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var fields: ContainerFieldSet
        var text: String
    }

    let url: URL

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

    func key(for file: URL, withModel: Bool) -> String {
        var st = stat()
        let path = file.standardizedFileURL.path
        let stamp = stat(path, &st) == 0 ? "\(st.st_size)|\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)" : "?"
        return "\(withModel ? "model" : "vision")|\(stamp)|\(path)"
    }

    func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    func save(_ entries: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
