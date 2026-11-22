import ArchiveCore
import Combine
import CryptoKit
import Foundation

/// Downloads the pinned reader after consent and owns the child that reads photos on this Mac.
@MainActor
final class ManagedGemma: ObservableObject {
    static let shared = ManagedGemma()
    static let sizeNote = "About 8 GB to download, 10 GB of disk space with its software, and 8 GB of memory while reading."
    static let requirements = "The app's download needs an Apple silicon Mac with at least 16 GB of memory."
    static var supported: Bool {
#if arch(arm64)
        ProcessInfo.processInfo.physicalMemory >= 16 * 1024 * 1024 * 1024
#else
        false
#endif
    }

    private static let offerSeenKey = "managedGemmaOfferSeen"
    private static let uvURL = URL(string: "https://github.com/astral-sh/uv/releases/download/0.11.21/uv-aarch64-apple-darwin.tar.gz")!
    private static let uvDigest = "1f921d491ba5ffeea774eb04d6681ecee379101341cbb1500394993b541bf3f4"

    @Published private(set) var offerVisible = false
    @Published private(set) var installStatus: String?
    @Published private(set) var runtimeStatus: String?
    @Published private(set) var installed: Bool
    private(set) var installing = false
    private var installation: Task<Void, Never>?
    private let root: URL
    private let readerSlot = RequestLimiter(limit: 1)
    private let session: URLSession
    private var worker: Worker?
    private var idle: Task<Void, Never>?
    private var nextStart = Date.distantPast
    private var stopGeneration = 0

    private final class Worker {
        let process = Process()
        let parent = Pipe()
        let output = Pipe()
        let secret = UUID().uuidString
        var line = ""
        var port: UInt16?
    }

    private enum Failure: Error {
        case runtime, installer, software, model, reader
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private init(root: URL = URL.applicationSupportDirectory.appending(path: "ArchiveProcessor/Label Reader/v1",
                                                                      directoryHint: .isDirectory)) {
        self.root = root
        installed = FileManager.default.fileExists(atPath: root.appending(path: "installed").path)
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    private var python: URL { root.appending(path: "env/bin/python") }
    private var script: URL? { Bundle.main.url(forResource: "ManagedGemmaWorker", withExtension: "py") }

    private var environment: [String: String] {
        [
            "HOME": root.path, "PATH": "/usr/bin:/bin", "LC_CTYPE": "UTF-8",
            "UV_CACHE_DIR": root.appending(path: "uv-cache").path,
            "UV_PYTHON_INSTALL_DIR": root.appending(path: "python").path,
            "UV_SYSTEM_CERTS": "true",
            "HF_HOME": root.appending(path: "model-store").path,
            "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1",
            "HF_HUB_DISABLE_TELEMETRY": "1",
            "HF_HUB_DISABLE_PROGRESS_BARS": "1",
        ]
    }

    func offerIfNeeded() {
        guard Self.supported, ContainerLabelCapture.enabled, !installed, !installing, !offerVisible,
              !KeychainHelper.isHeadlessTestMode, !UserDefaults.standard.bool(forKey: Self.offerSeenKey) else { return }
        offerVisible = true
    }

#if DEBUG
    func showOfferForUITest() {
        if KeychainHelper.isHeadlessTestMode { offerVisible = true }
    }

    /// Optional physical-Mac proof, run under the heavy lock with an already populated scratch runtime.
    static func testRead(jpeg: Data, scratch: URL) async -> String? {
        let root = scratch.resolvingSymlinksInPath()
        guard KeychainHelper.isHeadlessTestMode, Self.supported,
              ["/tmp", "/private/tmp"].contains(root.deletingLastPathComponent().path),
              root.lastPathComponent.hasPrefix("w49-gemma-runtime.") else { return nil }
        let reader = ManagedGemma(root: root)
        defer { reader.stop() }
        return await reader.readOne(jpeg)
    }
#endif

    func dismissOffer() {
        if !KeychainHelper.isHeadlessTestMode { UserDefaults.standard.set(true, forKey: Self.offerSeenKey) }
        offerVisible = false
    }

    func download() {
        guard Self.supported, ContainerLabelCapture.enabled, (!installed || runtimeStatus != nil), !installing,
              !KeychainHelper.isHeadlessTestMode else { return }
        dismissOffer()
        installing = true
        installStatus = "Preparing the local label reader…"
        installation = Task {
            defer { installation = nil }
            do {
                try await install()
                installing = false
                installed = true
                nextStart = .distantPast
                runtimeStatus = nil
                installStatus = nil
            } catch {
                installing = false
                installStatus = Task.isCancelled ? "Download paused. Resume it in Settings → Capture."
                    : Self.installFailure(error)
            }
        }
    }

    func dismissStatus() {
        if !installing { installStatus = nil }
    }

    func pauseDownload() { installation?.cancel() }

    func stop() {
        stopGeneration += 1
        nextStart = .distantPast
        pauseDownload()
        stopWorker()
        offerVisible = false
    }

    private static func installFailure(_ error: Error) -> String {
        let reason: String
        switch error as? Failure {
        case .runtime, .installer: reason = "The label reader installer could not be prepared."
        case .software: reason = "The local reader's software could not be installed."
        case .model: reason = "The Gemma model could not be downloaded."
        default: reason = "The local label reader could not be set up."
        }
        return reason + " Check your connection and free disk space, then try again in Settings → Capture."
    }

    private func install() async throws {
        guard let script else { throw Failure.runtime }
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
            try await run(URL(fileURLWithPath: "/usr/bin/tar"),
                          ["-xzf", archive.path, "uv-aarch64-apple-darwin/uv"], timeout: 30, failure: .installer)
        }

        installStatus = "Installing the local reader’s software…"
        if !FileManager.default.isExecutableFile(atPath: python.path) {
            try await run(uv, ["venv", "--no-config", "--no-project", "--managed-python", "--python", "3.12.13",
                               root.appending(path: "env").path], timeout: 600, failure: .software)
        }
        try await run(uv, ["pip", "install", "--no-config", "--default-index", "https://pypi.org/simple",
                           "--python", python.path, "--only-binary", ":all:",
                           "--exclude-newer", "2026-11-22T17:00:00Z", "mlx-vlm==0.7.4"],
                      timeout: 1200, failure: .software)
        installStatus = "Downloading Gemma 3 12B (about 8 GB)…"
        try await run(python, ["-I", script.path, "download"], timeout: 7200, failure: .model)
        try Task.checkCancellation()
        try Data().write(to: root.appending(path: "installed"), options: .atomic)
    }

    private func run(_ binary: URL, _ arguments: [String], timeout: TimeInterval, failure: Failure) async throws {
        try Task.checkCancellation()
        let result = await LocalAgentClient.runAsync(binaryPath: binary.path, args: arguments, stdinText: "",
                                                     timeout: timeout, currentDirectory: root, environment: environment)
        try Task.checkCancellation()
        guard result.exitCode == 0, !result.timedOut else { throw failure }
    }

    func read(jpeg: Data) async -> String? {
        guard installed, !installing, ContainerLabelCapture.enabled, Self.supported, !KeychainHelper.isHeadlessTestMode,
              !NetworkSession.testTransportIsActive else { return nil }
        do { try await readerSlot.acquire() } catch { return nil }
        let text = await readOne(jpeg)
        await readerSlot.release()
        return text
    }

    private func readOne(_ jpeg: Data) async -> String? {
        guard !installing, ContainerLabelCapture.enabled, !Task.isCancelled, Date() >= nextStart else { return nil }
        let generation = stopGeneration
        idle?.cancel()
        do {
            let child = try getWorker()
            let deadline = ContinuousClock.now + .seconds(60)
            while child.port == nil, worker === child, child.process.isRunning, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard worker === child, child.process.isRunning, ContainerLabelCapture.enabled,
                  let port = child.port else { throw Failure.reader }
            try Task.checkCancellation()
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/read")!,
                                     timeoutInterval: ContainerLabelGemma.timeout)
            request.httpMethod = "POST"
            request.setValue(child.secret, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "image": jpeg.base64EncodedString(), "prompt": ContainerLabelReader.localModelPrompt,
            ])
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, worker === child else { throw Failure.reader }
            runtimeStatus = nil
            idle = Task {
                try? await Task.sleep(for: .seconds(20))
                if !Task.isCancelled { stopWorker() }
            }
            return (try JSONSerialization.jsonObject(with: data) as? [String: String])?["text"]
        } catch {
            stopWorker()
            if generation == stopGeneration, !Task.isCancelled {
                nextStart = Date().addingTimeInterval(ContainerLabelGemma.rememberFor)
                runtimeStatus = "Gemma could not complete a read on this Mac. You can retry its setup here."
            }
            return nil
        }
    }

    private func getWorker() throws -> Worker {
        if let worker, worker.process.isRunning { return worker }
        stopWorker()
        guard let script else { throw Failure.runtime }
        let child = Worker()
        child.process.executableURL = python
        child.process.arguments = ["-I", script.path, "serve"]
        child.process.currentDirectoryURL = root
        child.process.environment = environment.merging([
            "ARCHIVE_GEMMA_SECRET": child.secret, "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
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
        do { try child.process.run() }
        catch {
            child.output.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        worker = child
        return child
    }

    private func acceptAnnouncement(_ data: Data, secret: String) {
        guard let worker, worker.secret == secret, worker.port == nil else { return }
        worker.line += String(decoding: data, as: UTF8.self)
        // Only complete lines count. Keep at most an incomplete trailing line.
        if let newline = worker.line.lastIndex(of: "\n") {
            for line in worker.line[...newline].split(separator: "\n") where line.hasPrefix("ARCHIVE_GEMMA_PORT ") {
                if let port = UInt16(line.dropFirst("ARCHIVE_GEMMA_PORT ".count)), port != 0 { worker.port = port }
            }
            worker.line.removeSubrange(...newline)
        }
        if worker.line.count > 4096 { worker.line = "" }
    }

    private func stopWorker() {
        idle?.cancel()
        idle = nil
        guard let child = worker else { return }
        worker = nil
        child.output.fileHandleForReading.readabilityHandler = nil
        try? child.parent.fileHandleForWriting.close()
        LocalAgentClient.ProcessCanceller.stop(child.process)
    }
}
