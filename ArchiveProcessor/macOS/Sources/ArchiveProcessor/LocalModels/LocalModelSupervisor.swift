import CryptoKit
import Darwin
import Foundation

/// W49.proc-local-model-supervisor — the one owner of the models this app downloads and runs on the Mac. Everything
/// that starts, keeps or stops such a model goes through it (`scripts/check-local-model-seam.sh` fails on a Python
/// or MLX lifecycle anywhere else), so these hold for every caller at once:
///
/// - **One runtime.** uv, a pinned Python and a pinned mlx-vlm are installed once under `root`; each model adds only
///   its pinned weights. `LocalModelWorker.py` serves whichever model the supervisor names.
/// - **One large model resident.** A read for a model that is not loaded first stops the loaded one and waits for its
///   process to exit before the next starts, so two large models are never in memory together. A model whose
///   measured peak passes `memoryCeilingGB` is refused, and one read runs at a time.
/// - **Keep-alive by context.** A loaded model stays `keepAliveLiveCapture` after its last read while a Live Capture
///   session is receiving (a model load costs seconds on every label otherwise), `keepAliveIdle` when none is. Memory
///   pressure unloads an idle model at once.
/// - **Stage batching.** A stage that reads many pages with one model (`withStage`) keeps that model loaded until the
///   stage ends, and a read for another model waits for it, so pages never alternate between two models.
@MainActor
final class LocalModelSupervisor {
    struct Model: Hashable, Sendable {
        let name: String
        let repo: String
        let revision: String
        /// The peak memory measured while it reads, in GB.
        let peakGB: Double
        /// What its pinned weights take to download, in GB (the download's progress is measured against it).
        let downloadGB: Double
    }

    /// The box and folder label reader (W47.ct-capture-gemma): 8.95 and 9.00 GB lifetime peak footprint through this
    /// supervisor on the 18 GB M3 Pro, one synthetic label each (8.04 GB in `segbench-results/ct-read.md`, outside the app).
    static let gemma3_12b = Model(name: "Gemma 3 12B", repo: "mlx-community/gemma-3-12b-it-4bit",
                                  revision: "86cc6a8dedbc456dd0e4af01a9d09f396f77e558", peakGB: 9.0,
                                  downloadGB: 8.0)

    /// No model may need more. The Agent Manager stops a session past 65% of this 18 GB Mac (11.7 GB) under memory
    /// pressure, and the app itself needs some of what is left.
    static let memoryCeilingGB = 10.0
    static let keepAliveLiveCapture: Duration = .seconds(300)
    static let keepAliveIdle: Duration = .seconds(30)
    /// A first read also loads the model (about 8 GB from disk).
    static let loadTimeout: Duration = .seconds(90)

    nonisolated static let defaultRoot = URL.applicationSupportDirectory.appending(
        path: "ArchiveProcessor/Local Models/v1", directoryHint: .isDirectory)
    static let shared = LocalModelSupervisor(root: defaultRoot)

#if DEBUG
    /// A contract's own supervisor, used in place of `shared` by the clients that read through one.
    static var testOverride: LocalModelSupervisor?
    static var serving: LocalModelSupervisor { testOverride ?? shared }
#else
    static var serving: LocalModelSupervisor { shared }
#endif

    enum Failure: Error, Equatable {
        case runtime, installer, software, model, tooLarge, unload, start, reader, stopped, installing
    }

    /// Which part of an install is running; the model's download says how much of it has arrived (0 to 1).
    enum InstallStep: Sendable, Equatable { case waiting, software, model(Double) }

    private static let uvURL = URL(string: "https://github.com/astral-sh/uv/releases/download/0.11.21/uv-aarch64-apple-darwin.tar.gz")!
    private static let uvDigest = "1f921d491ba5ffeea774eb04d6681ecee379101341cbb1500394993b541bf3f4"

    let root: URL
    private let interpreterOverride: URL?
    private let scriptOverride: URL?
    var keepAliveLiveCapture = LocalModelSupervisor.keepAliveLiveCapture
    var keepAliveIdle = LocalModelSupervisor.keepAliveIdle
    private let session: URLSession
    private var pressure: DispatchSourceMemoryPressure?

    private final class Worker {
        let model: Model
        let process = Process()
        let parent = Pipe()
        let output = Pipe()
        let secret = UUID().uuidString
        var line = ""
        var port: UInt16?
        init(model: Model) { self.model = model }
    }

    private var resident: Worker?
    /// Stopped workers whose processes may not have exited yet. Nothing loads until they have.
    private var retiring: [Worker] = []
    private var busy = false
    /// `used` once a read in the stage has run: only then does the stage hold its model loaded.
    private var stage: (model: Model, depth: Int, used: Bool)?
    /// Bumped when a model's reader is turned off, so reads already waiting for it stop.
    private var evictions: [Model: Int] = [:]
    /// Memory pressure that came while a read ran or a stage held the model: acted on when they finish. True if critical.
    private var pendingPressure: Bool?
    private var waiters: [(id: UUID, cont: CheckedContinuation<Void, Error>)] = []
    private var liveCaptures: Set<ObjectIdentifier> = []
    private var idle: Task<Void, Never>?
    private var generation = 0
    /// One install at a time: two would write the shared runtime together.
    private var installingModel: Model?
    /// A removal is deleting files: installs and reads wait for it.
    private var removing = false

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private init(root: URL, interpreter: URL? = nil, script: URL? = nil) {
        self.root = root
        interpreterOverride = interpreter
        scriptOverride = script
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            let critical = source?.data.contains(.critical) ?? false
            MainActor.assumeIsolated { self?.memoryPressure(critical: critical) }
        }
        source.resume()
        pressure = source
    }

    // MARK: - The runtime

    private var python: URL { interpreterOverride ?? root.appending(path: "env/bin/python") }
    private var script: URL? { scriptOverride ?? Bundle.main.url(forResource: "LocalModelWorker", withExtension: "py") }

    private func environment(_ model: Model) -> [String: String] {
        [
            "HOME": root.path, "PATH": "/usr/bin:/bin", "LC_CTYPE": "UTF-8",
            "UV_CACHE_DIR": root.appending(path: "uv-cache").path,
            "UV_PYTHON_INSTALL_DIR": root.appending(path: "python").path,
            "UV_SYSTEM_CERTS": "true",
            "HF_HOME": root.appending(path: "model-store").path,
            "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1",
            "HF_HUB_DISABLE_TELEMETRY": "1",
            "HF_HUB_DISABLE_PROGRESS_BARS": "1",
            // Plain downloads into the model's own folder: the progress shown is measured there, and Xet's chunk cache
            // would hold a second copy of the weights on disk.
            "HF_HUB_DISABLE_XET": "1",
            "ARCHIVE_MODEL_REPO": model.repo, "ARCHIVE_MODEL_REVISION": model.revision,
        ]
    }

    nonisolated private static func marker(_ model: Model, root: URL) -> URL {
        root.appending(path: "installed/\(model.repo.replacingOccurrences(of: "/", with: "--"))@\(model.revision)")
    }

    private func marker(_ model: Model) -> URL { Self.marker(model, root: root) }

    func isInstalled(_ model: Model) -> Bool { Self.isInstalled(model, root: root) }

    /// Whether the model's install finished under `root`; readable off the main actor, for the settings a run is built from.
    nonisolated static func isInstalled(_ model: Model, root: URL = defaultRoot) -> Bool {
        FileManager.default.fileExists(atPath: marker(model, root: root).path)
    }

    /// The model's own folder in the download store (Hugging Face's layout: its blobs and the snapshot pointing at them).
    private func store(_ model: Model) -> URL {
        root.appending(path: "model-store/hub/models--\(model.repo.replacingOccurrences(of: "/", with: "--"))")
    }

    /// The bytes of the model's weights on disk so far, partial files included.
    func downloadedBytes(_ model: Model) -> UInt64 {
        guard let files = FileManager.default.enumerator(at: store(model),
                                                         includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return 0
        }
        var total: UInt64 = 0
        for case let file as URL in files {
            // The snapshot's entries are links to the blobs: counted once, as blobs.
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += UInt64(values.fileSize ?? 0)
        }
        return total
    }

    /// Installs the shared runtime if it is missing, then the model's pinned weights. `step` says which part is running
    /// and how far the download has come. One install runs at a time; another waits (`.waiting`) until it ends.
    func install(_ model: Model, step: @escaping (InstallStep) -> Void) async throws {
        guard model.peakGB <= Self.memoryCeilingGB else { throw Failure.tooLarge }
        guard let script else { throw Failure.runtime }
        if installingModel != nil || removing { step(.waiting) }
        while installingModel != nil || removing { try await wait() }
        installingModel = model
        defer {
            installingModel = nil
            wakeAll()
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let uv = root.appending(path: "uv-aarch64-apple-darwin/uv")
        if !FileManager.default.isExecutableFile(atPath: uv.path) {
            let archive = root.appending(path: "uv.tar.gz")
            let (data, response) = try await URLSession.shared.data(from: Self.uvURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == Self.uvDigest else {
                throw Failure.installer
            }
            try data.write(to: archive, options: .atomic)
            try await run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archive.path, "uv-aarch64-apple-darwin/uv"],
                          model: model, timeout: 30, failure: .installer)
        }

        step(.software)
        if !FileManager.default.isExecutableFile(atPath: python.path) {
            try await run(uv, ["venv", "--no-config", "--no-project", "--managed-python", "--python", "3.12.13",
                               root.appending(path: "env").path], model: model, timeout: 600, failure: .software)
        }
        try await run(uv, ["pip", "install", "--no-config", "--default-index", "https://pypi.org/simple",
                           "--python", python.path, "--only-binary", ":all:",
                           "--exclude-newer", "2026-11-22T17:00:00Z", "mlx-vlm==0.7.4"],
                      model: model, timeout: 1200, failure: .software)
        step(.model(0))
        let share = { [weak self] in
            min(0.99, Double(self?.downloadedBytes(model) ?? 0) / max(1, model.downloadGB * 1_000_000_000))
        }
        let progress = Task { @MainActor in
            while !Task.isCancelled {
                step(.model(share()))
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { progress.cancel() }
        try await run(python, ["-I", script.path, "download"], model: model, timeout: 7200, failure: .model)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: marker(model).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data().write(to: marker(model), options: .atomic)
    }

    /// Removes the model's weights and its install marker, stopping it first if it is loaded. With no other model left
    /// installed and no install running, the shared runtime goes too, so nothing of the app's models stays on disk.
    /// Refused while this model is being installed.
    /// It takes the supervisor's turn first: no read or stage runs while it deletes, no install starts, and a read
    /// waiting for the model afterwards finds it not installed. Another model's install may go on meanwhile.
    func remove(_ model: Model) async throws {
        guard installingModel != model else { throw Failure.installing }
        evict(model)
        while busy || removing || stage != nil { try await wait() }
        guard installingModel != model else { throw Failure.installing }
        busy = true
        removing = true
        defer {
            removing = false
            release()
        }
        // A read queued before the removal may have loaded it again meanwhile.
        evict(model)
        try await drainRetiring()
        let fm = FileManager.default
        if fm.fileExists(atPath: marker(model).path) { try fm.removeItem(at: marker(model)) }
        if fm.fileExists(atPath: store(model).path) { try fm.removeItem(at: store(model)) }
        let others = (try? fm.contentsOfDirectory(atPath: root.appending(path: "installed").path)) ?? []
        if others.isEmpty, installingModel == nil, resident == nil, fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
    }

    private func run(_ binary: URL, _ arguments: [String], model: Model, timeout: TimeInterval,
                     failure: Failure) async throws {
        try Task.checkCancellation()
        let result = await LocalAgentClient.runAsync(binaryPath: binary.path, args: arguments, stdinText: "",
                                                     timeout: timeout, currentDirectory: root,
                                                     environment: environment(model))
        try Task.checkCancellation()
        guard result.exitCode == 0, !result.timedOut else { throw failure }
    }

    // MARK: - Reading

    /// One image and prompt through `model`, loading it first (and stopping another) if needed. The reply's text,
    /// empty when the reply reached `maxTokens`. `proceed` is asked again once the read has its turn and once the model
    /// is loaded (the caller's reader may have been turned off meanwhile); false fails the read as `stopped`.
    func read(_ model: Model, image: Data, prompt: String, maxTokens: Int, timeout: TimeInterval,
              proceed: @escaping () -> Bool = { true }) async throws -> String {
        try await withWorker(model, proceed: proceed) { child, wanted in
            guard let port = child.port else { throw Failure.reader }
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/read")!, timeoutInterval: timeout)
            request.httpMethod = "POST"
            request.setValue(child.secret, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "image": image.base64EncodedString(), "prompt": prompt, "max_tokens": maxTokens,
            ])
            let (data, response) = try await session.data(for: request)
            guard wanted() else { throw Failure.stopped }
            guard (response as? HTTPURLResponse)?.statusCode == 200, resident === child,
                  let text = (try JSONSerialization.jsonObject(with: data) as? [String: String])?["text"] else {
                throw Failure.reader
            }
            return text
        }
    }

    /// The model's worker as an OpenAI-compatible chat-completions server (W49.proc-managed-local-ocr), for the clients
    /// that already speak that API to a model on this Mac: `body` gets the endpoint and the per-launch secret to send as
    /// the Authorization header, and runs with the model loaded and the supervisor's turn held, so no other read starts
    /// beside it. A transport failure (the worker died, or the request timed out with the worker still writing) stops
    /// the worker, so the next request starts a fresh one.
    func withEndpoint<T: Sendable>(_ model: Model, proceed: @escaping () -> Bool = { true },
                                   _ body: @Sendable (URL, String) async throws -> T) async throws -> T {
        // A model removed (or never installed) is not started: there is nothing on disk for it to load.
        guard isInstalled(model) else { throw Failure.runtime }
        return try await withWorker(model, proceed: { self.isInstalled(model) && proceed() }) { child, wanted in
            guard let port = child.port else { throw Failure.reader }
            let value = try await body(URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!, child.secret)
            guard wanted() else { throw Failure.stopped }
            return value
        }
    }

    /// Takes the turn for `model`, loading it first (and stopping another) if needed, then runs `body` with its worker.
    /// `wanted` is false once the read is no longer wanted (stopped, turned off, or `proceed` says so).
    private func withWorker<T>(_ model: Model, proceed: @escaping () -> Bool,
                               _ body: @MainActor (Worker, () -> Bool) async throws -> T) async throws -> T {
        let started = generation
        let evicted = evictions[model, default: 0]
        let wanted = { started == self.generation && evicted == self.evictions[model, default: 0] && proceed() }
        try await acquire(model)
        defer { release() }
        guard wanted() else { throw Failure.stopped }
        let child: Worker
        do { child = try await worker(for: model, wanted: wanted) } catch Failure.tooLarge {
            throw Failure.tooLarge
        } catch {
            try? await unload()
            throw wanted() ? error : Failure.stopped
        }
        do {
            try Task.checkCancellation()
            guard wanted() else { throw Failure.stopped }
            return try await body(child, wanted)
        } catch {
            if resident === child { try? await unload() }
            throw wanted() ? error : Failure.stopped
        }
    }

    /// Keeps `model` loaded for the whole of `body` once a read in it has run, and reads for another model wait until
    /// it returns. For a stage that reads many pages with one model. A stage that reads nothing (its pages went to a
    /// server outside the app) leaves whatever is loaded to its keep-alive.
    func withStage<T>(_ model: Model, _ body: () async throws -> T) async throws -> T {
        while let pinned = stage, pinned.model != model { try await wait() }
        stage = (model, (stage?.depth ?? 0) + 1, stage?.used ?? false)
        note("stage \(model.name)")
        defer { endStage() }
        return try await body()
    }

    private func endStage() {
        guard let pinned = stage else { return }
        stage = pinned.depth > 1 ? (pinned.model, pinned.depth - 1, pinned.used) : nil
        if stage == nil {
            note("stage end \(pinned.model.name)")
            wakeAll()
            scheduleIdle()
            applyPendingPressure()
        }
    }

    // MARK: - Live Capture and stopping

    /// A Live Capture session started receiving: a loaded model stays longer between labels.
    func liveCaptureBegan(_ owner: AnyObject) {
        liveCaptures.insert(ObjectIdentifier(owner))
        scheduleIdle()
    }

    func liveCaptureEnded(_ owner: AnyObject) {
        liveCaptures.remove(ObjectIdentifier(owner))
        scheduleIdle()
    }

    /// Stops `model` if it is loaded (its reader was turned off); reads waiting for it fail as `stopped`.
    func evict(_ model: Model) {
        evictions[model, default: 0] += 1
        guard let child = resident, child.model == model else { return }
        resident = nil
        retire(child)
    }

    /// Stops everything at once (the app is quitting). A read in flight fails as `stopped`.
    func stopAll() {
        generation += 1
        idle?.cancel()
        idle = nil
        if let child = resident {
            resident = nil
            retire(child)
        }
    }

    /// A warning stops an idle model unless a stage is holding it; critical pressure stops it either way. Pressure that
    /// comes during a read (or a warning during a stage) waits for it to finish: the source fires once per change.
    private func memoryPressure(critical: Bool) {
        guard let child = resident else { pendingPressure = nil; return }
        if busy || (!critical && holds(child)) {
            pendingPressure = critical || pendingPressure == true
            return
        }
        pendingPressure = nil
        note("pressure \(child.model.name)")
        resident = nil
        retire(child)
    }

    private func applyPendingPressure() {
        guard let critical = pendingPressure else { return }
        pendingPressure = nil
        memoryPressure(critical: critical)
    }

    /// A stage that has read with this worker's model keeps it.
    private func holds(_ child: Worker) -> Bool {
        guard let stage else { return false }
        return stage.used && stage.model == child.model
    }

    // MARK: - Arbitration

    private func acquire(_ model: Model) async throws {
        while busy || (stage.map { $0.model != model } ?? false) { try await wait() }
        busy = true
        if stage?.model == model { stage?.used = true }
        idle?.cancel()
        idle = nil
    }

    private func release() {
        busy = false
        wakeAll()
        scheduleIdle()
        applyPendingPressure()
    }

    private func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { cont.resume(throwing: CancellationError()) } else { waiters.append((id, cont)) }
            }
        } onCancel: {
            Task { @MainActor in self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).cont.resume(throwing: CancellationError())
    }

    /// Each waiter checks again in turn; the first that can go takes the turn and the rest wait again, in order.
    private func wakeAll() {
        let woken = waiters
        waiters = []
        for waiter in woken { waiter.cont.resume() }
    }

    private func scheduleIdle() {
        idle?.cancel()
        idle = nil
        guard let child = resident, !busy, !holds(child) else { return }
        let wait = liveCaptures.isEmpty ? keepAliveIdle : keepAliveLiveCapture
        let started = generation
        idle = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, !self.busy, started == self.generation,
                  let child = self.resident, !self.holds(child) else { return }
            self.note("idle \(child.model.name)")
            self.resident = nil
            self.retire(child)
        }
    }

    // MARK: - Workers

    private func worker(for model: Model, wanted: () -> Bool) async throws -> Worker {
        if let resident, resident.model == model, resident.process.isRunning, resident.port != nil { return resident }
        guard model.peakGB <= Self.memoryCeilingGB else { throw Failure.tooLarge }
        try await unload()
        // Stopped or turned off while the old worker exited: load nothing.
        guard wanted() else { throw Failure.stopped }
        guard let script else { throw Failure.runtime }
        let child = Worker(model: model)
        child.process.executableURL = python
        child.process.arguments = ["-I", script.path, "serve"]
        child.process.currentDirectoryURL = root
        child.process.environment = environment(model).merging([
            "ARCHIVE_MODEL_SECRET": child.secret, "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
        ]) { _, new in new }
        child.process.standardInput = child.parent
        child.process.standardOutput = child.output
        child.process.standardError = FileHandle.nullDevice
        let secret = child.secret
        child.output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor [weak self] in self?.acceptAnnouncement(data, secret: secret) }
        }
        do { try child.process.run() } catch {
            child.output.fileHandleForReading.readabilityHandler = nil
            throw Failure.start
        }
        resident = child
        note("load \(model.name)")
        let deadline = ContinuousClock.now + Self.loadTimeout
        while child.port == nil, resident === child, child.process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard resident === child, child.process.isRunning, child.port != nil else { throw Failure.start }
        return child
    }

    private func acceptAnnouncement(_ data: Data, secret: String) {
        guard let worker = resident, worker.secret == secret, worker.port == nil else { return }
        worker.line += String(decoding: data, as: UTF8.self)
        // Only complete lines count. Keep at most an incomplete trailing line.
        if let newline = worker.line.lastIndex(of: "\n") {
            for line in worker.line[...newline].split(separator: "\n") where line.hasPrefix("ARCHIVE_MODEL_PORT ") {
                if let port = UInt16(line.dropFirst("ARCHIVE_MODEL_PORT ".count)), port != 0 { worker.port = port }
            }
            worker.line.removeSubrange(...newline)
        }
        if worker.line.count > 4096 { worker.line = "" }
    }

    /// Stops the loaded worker and waits until no stopped worker's process is left.
    private func unload() async throws {
        idle?.cancel()
        idle = nil
        if let child = resident {
            resident = nil
            retire(child)
        }
        try await drainRetiring()
    }

    /// Waits until no stopped worker's process is left.
    private func drainRetiring() async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while retiring.contains(where: { $0.process.isRunning }), ContinuousClock.now < deadline {
            await Self.pause(milliseconds: 50)
        }
        retiring.removeAll { !$0.process.isRunning }
        // A process that outlived SIGKILL still holds its memory: load nothing beside it.
        guard retiring.isEmpty else { throw Failure.unload }
    }

    /// SIGTERM now, SIGKILL after 3 s; closing stdin also ends an idle worker by itself.
    private func retire(_ child: Worker) {
        if let peak = Self.lifetimePeak(child.process) { lastPeakBytes = peak }
        child.output.fileHandleForReading.readabilityHandler = nil
        try? child.parent.fileHandleForWriting.close()
        LocalAgentClient.ProcessCanceller.stop(child.process)
        retiring.removeAll { !$0.process.isRunning }
        retiring.append(child)
        note("unload \(child.model.name)")
    }

    /// Not cut short by cancellation, so a cancelled read still waits for the process it stopped.
    private static func pause(milliseconds: Int) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds)) { cont.resume() }
        }
    }

    /// The most memory the worker's process has held (its lifetime peak physical footprint, GPU memory included).
    private static func lifetimePeak(_ process: Process) -> UInt64? {
        guard process.isRunning else { return nil }
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(process.processIdentifier, RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? info.ri_lifetime_max_phys_footprint : nil
    }

    /// The lifetime peak of the last worker stopped, in bytes.
    private(set) var lastPeakBytes: UInt64 = 0

#if DEBUG
    /// What the supervisor did, in order, for the contract.
    private(set) var events: [String] = []
    private func note(_ event: String) { events.append(event) }

    /// A supervisor of its own for a contract: a scratch root, and a stand-in interpreter and worker if given.
    static func forTest(root: URL, interpreter: URL? = nil, script: URL? = nil) -> LocalModelSupervisor {
        LocalModelSupervisor(root: root, interpreter: interpreter, script: script)
    }

    var residentModel: Model? { resident?.model }
    func simulateMemoryPressure(critical: Bool) { memoryPressure(critical: critical) }
    var residentPID: pid_t? { resident?.process.processIdentifier }
#else
    private func note(_ event: String) {}
#endif
}
