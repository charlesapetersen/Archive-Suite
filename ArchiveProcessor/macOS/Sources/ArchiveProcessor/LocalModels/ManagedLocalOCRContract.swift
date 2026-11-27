#if DEBUG // a test contract, compiled out of Release
import AppKit
import VisionOCRKit
import Foundation

/// W49.proc-managed-local-ocr — the managed page readers, run by `LocalModelsTestDriver` (`scripts/test-local-models.sh`):
/// the install (progress, a second install waiting, cancellation, a failed download), removal, the Reader and gateway it
/// makes, and a page read through the app's own client for a model on this Mac over the supervisor's worker (the
/// request's limits, the loop stop and the second reading, a text call, one model at a time beside a label read). The
/// stand-in worker and a stand-in uv play the runtime: no model, no network, $0, never the corpus.
@MainActor
enum ManagedLocalOCRContract {
    static func run() async -> [(String, Bool, String)] {
        var out: [(String, Bool, String)] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { out.append(("M " + name, ok, detail)) }
        let fm = FileManager.default
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        let root = fm.temporaryDirectory.appending(path: "w49-managed-ocr-\(UUID().uuidString)")
        let scratch = fm.temporaryDirectory.appending(path: "w49-managed-ocr-scratch-\(UUID().uuidString)")
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: scratch) }
        let script = scratch.appending(path: "stub.py")
        try? Data(LocalModelSupervisorContract.stub.utf8).write(to: script)
        let s = LocalModelSupervisor.forTest(root: root, interpreter: python, script: script)
        defer { s.stopAll() }
        // A stand-in uv: the shared software's install step, which takes a moment and succeeds.
        func seedUV() {
            let uv = root.appending(path: "uv-aarch64-apple-darwin/uv")
            try? fm.createDirectory(at: uv.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("#!/bin/sh\nsleep 0.3\nexit 0\n".utf8).write(to: uv)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uv.path)
        }
        seedUV()
        let small = LocalModelSupervisor.Model(name: "Small", repo: "org/model-small", revision: "1", peakGB: 8,
                                               downloadGB: 0.001)
        let other = LocalModelSupervisor.Model(name: "Other", repo: "org/model-other", revision: "1", peakGB: 8,
                                               downloadGB: 0.001)
        let failing = LocalModelSupervisor.Model(name: "Fail", repo: "model-fail", revision: "1", peakGB: 8,
                                                 downloadGB: 0.001)

        // 1. An install reports its steps and the download's share, then marks the model installed.
        var steps: [LocalModelSupervisor.InstallStep] = []
        do { try await s.install(small) { steps.append($0) } } catch { check("1 the install finishes", false, "\(error)") }
        let shares = steps.compactMap { if case .model(let v) = $0 { v } else { nil } }
        check("1 the install says software, then the model's download", steps.first == .software && !shares.isEmpty,
              "\(steps.prefix(4))")
        check("1 the download's share rises above 0 and stays under 1", (shares.max() ?? 0) > 0.2 && (shares.max() ?? 1) < 1,
              "\(shares)")
        check("1 the model is installed", s.isInstalled(small) && LocalModelSupervisor.isInstalled(small, root: root))
        check("1 its downloaded bytes are counted", s.downloadedBytes(small) == 1_000_000, "\(s.downloadedBytes(small))")

        // 2. A second install waits for the first; a cancelled one leaves no marker; a failed download fails as .model.
        var secondSteps: [LocalModelSupervisor.InstallStep] = []
        let first = Task { try await s.install(other) { _ in } }
        try? await Task.sleep(for: .milliseconds(100))
        let second = Task { try await s.install(small) { secondSteps.append($0) } }
        try? await Task.sleep(for: .milliseconds(300))
        let waitedFirst = secondSteps.first == .waiting && !secondSteps.contains(.software)
        first.cancel()
        let firstResult = await first.result
        _ = await second.result
        check("2 a second install waits while one runs", waitedFirst, "\(secondSteps.prefix(3))")
        if case .failure = firstResult { check("2 a cancelled install fails", true) } else { check("2 a cancelled install fails", false) }
        check("2 and leaves its model not installed", !s.isInstalled(other))
        check("2 then the waiting install runs", secondSteps.contains(.software), "\(secondSteps.prefix(4))")
        do { try await s.install(failing) { _ in }; check("2 a failed download fails", false, "it installed") }
        catch { check("2 a failed download fails as the model's", error as? LocalModelSupervisor.Failure == .model, "\(error)") }
        check("2 and is not installed", !s.isInstalled(failing))

        // 3. The manager: download, cancel, retry and remove, and the Reader each leaves.
        let suite = "w49-managed-ocr-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let manager = ManagedLocalOCR(supervisor: s)
        let m = ManagedOCRModel.qwen3VL8B
        check("3 a model not downloaded makes no gateway", { ReaderChoice.managed(m).apply(d)
            return GatewayConfig.fromDefaults(d, managedRoot: root) == nil }())
        check("3 the Reader still names it", ReaderChoice.current(d) == .managed(m))
        ReaderChoice.appleVision.apply(d)
        manager.download(m)
        var sawShare = false
        for _ in 0..<100 {
            if case .installing(_, let share?) = manager.state(m), share > 0 { sawShare = true }
            if manager.state(m) == .installed { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        check("3 the manager shows the download's progress", sawShare)
        check("3 and then the model installed", manager.state(m) == .installed, "\(manager.state(m))")
        manager.use(m, defaults: d)
        let gateway = GatewayConfig.fromDefaults(d, managedRoot: root)
        check("3 using it makes the Reader the managed model", ReaderChoice.current(d) == .managed(m))
        check("3 its gateway is a local model the app runs",
              gateway?.isLocalModel == true && gateway?.managedOCR == m && gateway?.apiKey == LocalModelRoute.placeholderKey,
              "\(String(describing: gateway))")
        check("3 the user's own gateway fields are untouched",
              d.string(forKey: DefaultsKeys.gatewayBaseURL) == nil && !d.bool(forKey: DefaultsKeys.gatewayLocalModel))
        check("3 a stored key reads as local", GatewayConfig.readsOnThisMac(d))
        await manager.remove(m, defaults: d)
        check("3 removing it removes its files", manager.state(m) == .notInstalled && !s.isInstalled(m.model)
              && s.downloadedBytes(m.model) == 0)
        check("3 and Apple Vision becomes the Reader", ReaderChoice.current(d) == .appleVision)
        let other3 = ManagedOCRModel.qwen35_9B
        manager.download(other3)
        // Cancel once the first of the download's files has arrived.
        for _ in 0..<200 where s.downloadedBytes(other3.model) == 0 { try? await Task.sleep(for: .milliseconds(25)) }
        manager.cancel(other3)
        for _ in 0..<200 where { if case .installing = manager.state(other3) { true } else { false } }() {
            try? await Task.sleep(for: .milliseconds(25))
        }
        if case .failed(let why) = manager.state(other3) {
            check("3 a cancelled download says so and keeps what arrived", why.contains("cancelled") && s.downloadedBytes(other3.model) > 0, "\(why) bytes \(s.downloadedBytes(other3.model)) partial \(manager.partial)")
        } else { check("3 a cancelled download says so", false, "\(manager.state(other3))") }
        check("3 and offers to remove what arrived", manager.partial.contains(other3))
        manager.download(other3)
        for _ in 0..<100 where manager.state(other3) != .installed { try? await Task.sleep(for: .milliseconds(50)) }
        check("3 Download again after a cancel finishes it", manager.state(other3) == .installed, "\(manager.state(other3))")
        await manager.remove(other3, defaults: d)
        // `small` is still installed: the shared software stays for it.
        check("3 the shared software stays while another model is installed",
              fm.fileExists(atPath: root.appending(path: "uv-aarch64-apple-darwin/uv").path))

        // 3b. S-058: quitting mid-download (cancelAll + stopAll) terminates the active installer child synchronously.
        let pidFile = scratch.appending(path: "s058-uv.pid")
        let uvPath = root.appending(path: "uv-aarch64-apple-darwin/uv")
        try? Data("#!/bin/sh\necho $$ > \"\(pidFile.path)\"\nexec sleep 30\n".utf8).write(to: uvPath)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uvPath.path)
        manager.download(other3)
        var childPID: pid_t = 0
        for _ in 0..<200 {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let parsed = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), parsed > 0 {
                childPID = parsed
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        let startedAlive = childPID > 0 && kill(childPID, 0) == 0
        manager.cancelAll()
        s.stopAll()
        var exited = false
        for _ in 0..<80 {
            if childPID > 0, kill(childPID, 0) != 0 { exited = true; break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        if childPID > 0, !exited { kill(childPID, SIGKILL) }
        check("3b S-058: cancelAll + stopAll stops an active download child on quit",
              startedAlive && exited, "pid=\(childPID) startedAlive=\(startedAlive) exited=\(exited)")
        seedUV()
        try? await s.remove(small)
        check("3 removing the last model removes the shared software", !fm.fileExists(atPath: root.path))

        // 4. A page through the app's client for a model on this Mac, over the worker (the stand-in plays it).
        seedUV()
        try? await s.install(m.model) { _ in }
        LocalModelSupervisor.testOverride = s
        defer { LocalModelSupervisor.testOverride = nil }
        guard let config = GatewayConfig.managed(m, d, root: root) else {
            check("4 an installed model makes a gateway", false)
            return out
        }
        let page = scratch.appending(path: "page.jpg")
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 64, height: 64).fill(); image.unlockFocus()
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let jpeg = rep.representation(using: .jpeg, properties: [:]) { try? jpeg.write(to: page) }
        let client = OpenAICompatibleClient.gateway(config)
        let chatLog = root.appending(path: "chat.jsonl")
        func requests() -> [[String: Any]] {
            ((try? String(contentsOf: chatLog, encoding: .utf8)) ?? "").split(separator: "\n")
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
        let read = try? await client.ocr(imageURL: page)
        let r1 = requests().last
        check("4 the page is read through the worker", read?.text == "Dear Sir, the stub read this page.", "\(String(describing: read))")
        check("4 with the local route's limits", r1?["max_tokens"] as? Int == LocalModelRoute.maxTokens
              && r1?["temperature"] as? Int == 0 && r1?["enable_thinking"] as? Bool == false
              && r1?["stream"] as? Bool == true && r1?["images"] as? Int == 1, "\(String(describing: r1))")
        let looped = try? await client.ocr(imageURL: page, customPrompt: "LOOP")
        let afterLoop = requests()
        check("4 a reply that repeats itself is closed as it streams", afterLoop.contains { $0["cut"] as? Bool == true },
              "\(afterLoop.suffix(3))")
        check("4 and read once more with the repetition penalty, which answers",
              afterLoop.last?["repetition_penalty"] as? Double == LocalModelRoute.retryRepetitionPenalty
                && looped?.text == "Dear Sir, the stub read this page.", "\(String(describing: looped))")
        let text = try? await client.textCompletion(prompt: "Tag this", maxTokens: 64)
        check("4 a text call goes to the same worker, unstreamed", text == "STUB TEXT ANSWER"
              && requests().last?["images"] as? Int == 0 && requests().last?["stream"] is NSNull, "\(String(describing: text))")
        let pid = requests().last?["pid"] as? Int
        // A label read for another model between pages: the page's model is stopped first, and comes back alone.
        _ = try? await s.read(small, image: Data([1]), prompt: "p", maxTokens: 64, timeout: 20)
        _ = try? await client.ocr(imageURL: page)
        let back = requests().last
        check("4 after another model's read the page's model loads again, alone",
              back?["pid"] as? Int != pid && back?["others"] as? Int == 0, "\(String(describing: back))")
        s.evict(m.model)
        let again = try? await client.ocr(imageURL: page)
        check("4 a model stopped between pages loads again for the next", again?.text != nil, "\(String(describing: again))")

        // 6. W49.proc-managed-mac-image-calls: the Mac's page-image date search and the image half of the item-field call
        //    go to the installed Qwen3-VL 8B's worker, each with its own request and limits. The user's server address
        //    answers 503 here and is counted (nothing listens on it, and the app's session waits for connectivity); every
        //    other request goes on the wire, the stand-in worker's included.
        let serverHits = ServerHits()
        let wire = URLSession(configuration: .ephemeral)
        NetworkSession.testTransport = { request in
            guard request.url?.port == 8080 else { return try await wire.data(for: request) }
            serverHits.add(request)
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        }
        defer { NetworkSession.testTransport = nil }
        let undated = DateRoute.Input(text: "Dear Sir, nothing here says when.", near: [], pages: [(url: page, rotation: 0)])
        let beforeDate = requests().count
        let dating = await DateRoute.runLocal(undated)
        let dateCall = requests().count == beforeDate + 1 ? requests().last : nil
        check("6 the date search's page image goes to the managed worker, with its own limits",
              dateCall?["images"] as? Int == 1 && dateCall?["max_tokens"] as? Int == 700
                && dateCall?["temperature"] as? Int == 0 && dateCall?["stream"] is NSNull, "\(String(describing: dateCall))")
        check("6 and the date search names the image route", dating.route == DateRoute.localImageRoute, dating.route)
        let beforeFields = requests().count
        _ = await ItemFieldExtractor.extract(ItemFieldExtractor.Input(texts: ["Dear Sir"], pages: [(url: page, rotation: 0)]),
                                             via: .mac)
        let fieldCalls = requests().dropFirst(beforeFields)
        check("6 the item-field call's image half goes to the managed worker, with its own limits",
              fieldCalls.count == 1 && fieldCalls.first?["images"] as? Int == 1
                && fieldCalls.first?["max_tokens"] as? Int == ItemFieldExtractor.macMaxTokens
                && fieldCalls.first?["enable_thinking"] as? Bool == false, "\(Array(fieldCalls))")
        check("6 and its Qwen3.5 4B text half still goes to the server", serverHits.models == [ItemFieldExtractor.macTextModel],
              "\(serverHits.models)")
        NetworkSession.testTransport = nil

        // 5. A removal waits for a read in flight (another model's here), and a page for a removed model fails as one,
        //    without starting a worker.
        let slow = Task { try await s.read(small, image: Data([1]), prompt: "SLOW", maxTokens: 64, timeout: 20) }
        try? await Task.sleep(for: .milliseconds(600))
        let removal = Task { try await s.remove(m.model) }
        try? await Task.sleep(for: .milliseconds(300))
        let installedDuringRead = s.isInstalled(m.model)
        let slowRead = try? await slow.value
        _ = try? await removal.value
        check("5 a removal waits for the read in flight, which finishes", installedDuringRead && slowRead != nil,
              "\(installedDuringRead) \(String(describing: slowRead))")
        check("5 then the model is removed", !s.isInstalled(m.model))
        let loadsBefore = s.events.filter { $0.hasPrefix("load") }.count
        let gone = try? await client.ocr(imageURL: page)
        check("5 a page for a removed model fails, saying to download it again",
              gone?.text == nil && gone?.errorCode == "503" && (gone?.errorMessage ?? "").contains("not installed"),
              "\(String(describing: gone))")
        check("5 and starts no worker", s.events.filter { $0.hasPrefix("load") }.count == loadsBefore)
        // 6. Not installed: the date search goes to the user's own server address, as before, and starts no worker.
        let beforeServer = requests().count
        let hitsBefore = serverHits.models.count
        NetworkSession.testTransport = { request in
            serverHits.add(request)
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        }
        let undatedAfter = await DateRoute.runLocal(undated)
        NetworkSession.testTransport = nil
        check("6 with the model removed, the date search goes to the server and starts no worker",
              Array(serverHits.models.dropFirst(hitsBefore)) == [ItemFieldExtractor.macImageModel]
                && serverHits.ports.last == 8080
                && s.events.filter { $0.hasPrefix("load") }.count == loadsBefore && requests().count == beforeServer,
              "\(serverHits.models) \(undatedAfter.imageNote)")
        return out
    }

    /// The requests the contract's stand-in for the user's mlx-vlm server received: each one's model and port.
    private final class ServerHits: @unchecked Sendable {
        private let lock = NSLock()
        private var hits: [(model: String, port: Int?)] = []
        func add(_ request: URLRequest) {
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            lock.withLock { hits.append((body?["model"] as? String ?? "", request.url?.port)) }
        }
        var models: [String] { lock.withLock { hits.map(\.model) } }
        var ports: [Int?] { lock.withLock { hits.map(\.port) } }
    }

    /// The physical-Mac proof, under the heavy lock: a fresh install into an empty scratch root (uv, Python and mlx-vlm
    /// from the network; the weights from a scratch store `test-local-models.sh` was handed, or the network), then a
    /// rendered scratch page read through the app's client. Each line of the page must come back. Never the corpus.
    static func realInstallAndRead(scratch: URL, store: URL?) async -> [(String, Bool, String)] {
        var out: [(String, Bool, String)] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { out.append(("W49 " + name, ok, detail)) }
        let root = scratch.resolvingSymlinksInPath()
        guard KeychainHelper.isHeadlessTestMode, ["/tmp", "/private/tmp"].contains(root.deletingLastPathComponent().path),
              root.lastPathComponent.hasPrefix("w49-ocr-runtime."),
              (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.isEmpty == true else {
            check("managed OCR proof: an empty scratch root under /tmp", false, root.path)
            return out
        }
        let m = ManagedOCRModel.qwen3VL8B
        if let store {
            // A store of hard links to the pinned snapshot's files (made by the caller), moved in: the proof needs no
            // second 5.8 GB on this disk, and the download step still checks every file against the pinned revision.
            try? FileManager.default.createDirectory(at: root.appending(path: "model-store"), withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: store, to: root.appending(path: "model-store/hub"))
        }
        let s = LocalModelSupervisor.forTest(root: root)
        defer { s.stopAll() }
        var steps: [String] = []
        let started = ContinuousClock.now
        do {
            try await s.install(m.model) { step in
                let name = switch step { case .waiting: "waiting"; case .software: "software"; case .model: "model" }
                if steps.last != name { steps.append(name) }
            }
        } catch {
            check("managed OCR proof: the fresh install finishes", false, "\(error) after \(steps)")
            return out
        }
        let installSeconds = (ContinuousClock.now - started).components.seconds
        check("managed OCR proof: the fresh install finishes", s.isInstalled(m.model), "\(steps), \(installSeconds) s")
        let lines = ["Department of the Treasury", "Washington, March 4, 1968", "Dear Mr. Petersen:",
                     "Thank you for your letter about the archive."]
        let page = root.appending(path: "scratch-page.jpg")
        let image = NSImage(size: NSSize(width: 1200, height: 900))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1200, height: 900).fill()
        for (i, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 80, y: 760 - i * 90),
                                    withAttributes: [.font: NSFont(name: "Times New Roman", size: 44) ?? .systemFont(ofSize: 44),
                                                     .foregroundColor: NSColor.black])
        }
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) { try? jpeg.write(to: page) }
        let suite = "w49-managed-ocr-real-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        guard let config = GatewayConfig.managed(m, d, root: root) else {
            check("managed OCR proof: the installed model makes a gateway", false)
            return out
        }
        LocalModelSupervisor.testOverride = s
        defer { LocalModelSupervisor.testOverride = nil }
        let readStarted = ContinuousClock.now
        let result = try? await PageReaders.reader(provider: .openai, model: config.asLLMModel(), apiKey: config.apiKey,
                                                   thinkingLevel: nil, gateway: config, newspaperLayout: false)
            .read(PageReaderInput(imageURL: page))
        let readSeconds = (ContinuousClock.now - readStarted).components.seconds
        let text = result?.text ?? ""
        let missing = lines.filter { !text.localizedCaseInsensitiveContains($0) }
        check("managed OCR proof: the scratch page reads through the app's page reader", !text.isEmpty && missing.isEmpty,
              "\(readSeconds) s; missing \(missing); text \(text.prefix(300))")
        s.stopAll()
        try? await Task.sleep(for: .seconds(4))
        let gb = Double(s.lastPeakBytes) / 1_073_741_824
        out.append((String(format: "NOTE managed OCR install %d s, first read %d s (model load included), peak %.2f GB",
                           Int(installSeconds), Int(readSeconds), gb), true, ""))
        check("managed OCR proof: the worker peaks under the 10 GB ceiling", s.lastPeakBytes > 0
              && gb < LocalModelSupervisor.memoryCeilingGB, String(format: "%.2f GB", gb))
        return out
    }
}
#endif
