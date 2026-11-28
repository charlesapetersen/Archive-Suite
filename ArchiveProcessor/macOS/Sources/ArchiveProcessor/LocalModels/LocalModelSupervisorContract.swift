#if DEBUG // a test contract, compiled out of Release
import ArchiveCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// W49.proc-local-model-supervisor — the supervisor's arbitration, run by `LocalModelsTestDriver`
/// (`scripts/test-local-models.sh`). A stand-in worker on the system Python plays each model: it serves the same
/// protocol as `LocalModelWorker.py`, loads nothing, and takes a second to exit when stopped, so a supervisor that did
/// not wait for the exit would start the next worker beside it. Each worker reports how many others were alive when it
/// started. Loopback only, no model, no network, $0, never the corpus.
@MainActor
enum LocalModelSupervisorContract {
    /// Also the stand-in for `ManagedLocalOCRContract`: `download` writes a megabyte of weights in four steps (and fails
    /// for the repo `model-fail`), and `/v1/chat/completions` answers as the real worker's does, recording each request's
    /// options in `chat.jsonl`. A prompt holding LOOP streams a reply that repeats itself until the client closes it
    /// (recorded as `cut`), unless the request carries a repetition penalty.
    static let stub = #"""
    import json, os, signal, sys, threading, time
    from http.server import BaseHTTPRequestHandler, HTTPServer
    if sys.argv[-1] == "download":
        repo = os.environ["ARCHIVE_MODEL_REPO"]
        blobs = os.path.join(os.environ["HF_HOME"], "hub", "models--" + repo.replace("/", "--"), "blobs")
        os.makedirs(blobs, exist_ok=True)
        for i in range(4):
            with open(os.path.join(blobs, "part%d" % i), "wb") as f:
                f.write(b"x" * 250000)
            time.sleep(0.5)
        sys.exit(1 if repo == "model-fail" else 0)
    alive = os.path.join(os.environ["HOME"], "alive")
    os.makedirs(alive, exist_ok=True)
    others = len(os.listdir(alive))
    mine = os.path.join(alive, str(os.getpid()))
    open(mine, "w").close()
    def leave(*_):
        time.sleep(1)
        os.remove(mine)
        os._exit(0)
    signal.signal(signal.SIGTERM, leave)
    def watch():
        sys.stdin.buffer.read(1)
        leave()
    threading.Thread(target=watch, daemon=True).start()
    secret = os.environ.pop("ARCHIVE_MODEL_SECRET")
    class H(BaseHTTPRequestHandler):
        def do_POST(self):
            if self.headers.get("Authorization") != secret:
                self.send_error(403); return
            data = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            if self.path == "/v1/chat/completions":
                self.chat(data)
                return
            if data["prompt"] == "SLOW":
                time.sleep(2)
            text = "%s %d %d %d" % (os.environ["ARCHIVE_MODEL_REPO"], os.getpid(), others, data["max_tokens"])
            body = json.dumps({"text": text}).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def chat(self, data):
            parts = [p for m in data["messages"] for p in (m["content"] if isinstance(m["content"], list) else [{"type": "text", "text": m["content"]}])]
            prompt = " ".join(p.get("text", "") for p in parts if p["type"] == "text")
            images = sum(1 for p in parts if p["type"] == "image_url")
            options = {k: data.get(k) for k in ("max_tokens", "temperature", "enable_thinking", "stream", "repetition_penalty")}
            options["images"] = images
            options["pid"] = os.getpid()
            options["others"] = others
            log = os.path.join(os.environ["HOME"], "chat.jsonl")
            with open(log, "a") as f:
                f.write(json.dumps(options) + "\n")
            looping = "LOOP" in prompt and data.get("repetition_penalty") is None
            content = "Dear Sir, the stub read this page." if images else "STUB TEXT ANSWER"
            if data.get("stream") is not True:
                body = json.dumps({"choices": [{"index": 0, "finish_reason": "stop", "message": {"content": content}}]}).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            def event(payload):
                self.wfile.write(b"data: " + json.dumps(payload).encode() + b"\n\n")
                self.wfile.flush()
            try:
                if looping:
                    for _ in range(4000):
                        event({"choices": [{"index": 0, "delta": {"content": "The cat sat. "}}]})
                        time.sleep(0.002)
                else:
                    event({"choices": [{"index": 0, "delta": {"content": content}}]})
                event({"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                with open(log, "a") as f:
                    f.write(json.dumps({"cut": True}) + "\n")
        def log_message(self, *_):
            pass
    server = HTTPServer(("127.0.0.1", 0), H)
    print("ARCHIVE_MODEL_PORT %d" % server.server_port, flush=True)
    server.serve_forever()
    """#

    /// Optional physical-Mac proof, run under the heavy lock with an already populated scratch runtime: the label
    /// reader's reply through a supervisor on that runtime, and the worker's peak memory in bytes.
    static func realRead(jpeg: Data, scratch: URL) async -> (text: String, peakBytes: UInt64)? {
        let root = scratch.resolvingSymlinksInPath()
        guard KeychainHelper.isHeadlessTestMode, ManagedGemma.supported,
              ["/tmp", "/private/tmp"].contains(root.deletingLastPathComponent().path),
              root.lastPathComponent.hasPrefix("w49-gemma-runtime.") else { return nil }
        let supervisor = LocalModelSupervisor.forTest(root: root)
        let text = try? await supervisor.read(ManagedGemma.model, image: jpeg,
                                              prompt: ContainerLabelReader.localModelPrompt,
                                              maxTokens: ContainerLabelGemma.maxTokens, timeout: ContainerLabelGemma.timeout)
        supervisor.stopAll()
        return text.map { ($0, supervisor.lastPeakBytes) }
    }

    private struct Reply { let repo: String; let pid: Int; let others: Int; let maxTokens: Int }

    private static func parse(_ text: String?) -> Reply? {
        guard let parts = text?.split(separator: " "), parts.count == 4,
              let pid = Int(parts[1]), let others = Int(parts[2]), let cap = Int(parts[3]) else { return nil }
        return Reply(repo: String(parts[0]), pid: pid, others: others, maxTokens: cap)
    }

    /// Each check's name, whether it held, and what was seen.
    static func run() async -> [(String, Bool, String)] {
        var out: [(String, Bool, String)] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { out.append(("S " + name, ok, detail)) }
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            check("a system Python for the stand-in worker", false)
            return out
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "w49-supervisor-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appending(path: "stub.py")
        try? Data(stub.utf8).write(to: script)
        let s = LocalModelSupervisor.forTest(root: root, interpreter: python, script: script)
        defer { s.stopAll() }
        let a = LocalModelSupervisor.Model(name: "A", repo: "model-a", revision: "1", peakGB: 8, downloadGB: 1)
        let b = LocalModelSupervisor.Model(name: "B", repo: "model-b", revision: "1", peakGB: 8, downloadGB: 1)
        let huge = LocalModelSupervisor.Model(name: "Huge", repo: "model-huge", revision: "1", peakGB: 12, downloadGB: 1)
        func read(_ m: LocalModelSupervisor.Model, _ prompt: String = "p", proceed: @escaping () -> Bool = { true })
            async -> Result<Reply?, Error> {
            do { return .success(parse(try await s.read(m, image: Data([1]), prompt: prompt, maxTokens: 640,
                                                          timeout: 20, proceed: proceed))) }
            catch { return .failure(error) }
        }
        func isStopped(_ r: Result<Reply?, Error>) -> Bool {
            if case .failure(let e) = r { e as? LocalModelSupervisor.Failure == .stopped } else { false }
        }
        func reply(_ r: Result<Reply?, Error>) -> Reply? { if case .success(let v) = r { v } else { nil } }

        // 1. A model loads on its first read and stays for the next; the request carries its token cap.
        let a1 = reply(await read(a))
        let a2 = reply(await read(a))
        check("1 the first read loads the model and answers", a1?.repo == "model-a" && a1?.maxTokens == 640, "\(String(describing: a1))")
        check("1 a second read reuses the loaded worker", a1 != nil && a1?.pid == a2?.pid, "\(String(describing: a2))")

        // 2. Another model: the first is stopped and has exited before the second starts.
        let b1 = reply(await read(b))
        check("2 a read for another model loads it", b1?.repo == "model-b" && b1?.pid != a1?.pid, "\(String(describing: b1))")
        check("2 no worker was alive when the other model started", b1?.others == 0, "\(String(describing: b1))")
        let order = s.events.filter { $0.hasPrefix("load") || $0.hasPrefix("unload") }
        check("2 load A, unload A, load B, in that order", order == ["load A", "unload A", "load B"], "\(order)")
        check("2 the stopped worker's peak memory was read", s.lastPeakBytes > 0, "\(s.lastPeakBytes)")

        // 3. A model over the memory ceiling is refused, and the loaded one is not stopped for it.
        let refused = await read(huge)
        if case .failure(let e) = refused { check("3 a model over 10 GB is refused", e as? LocalModelSupervisor.Failure == .tooLarge, "\(e)") }
        else { check("3 a model over 10 GB is refused", false, "it read") }
        check("3 the loaded model stays", s.residentModel == b, "\(String(describing: s.residentModel))")

        // 4. A stage keeps its model: a read for another model waits until the stage ends, and none alternates.
        var waited: Task<Result<Reply?, Error>, Never>?
        var duringStage: [Reply?] = []
        var otherDoneDuringStage = false
        _ = try? await s.withStage(a) {
            duringStage.append(reply(await read(a)))
            waited = Task { await read(b) }
            try? await Task.sleep(for: .milliseconds(400))
            duringStage.append(reply(await read(a)))
            otherDoneDuringStage = s.events.contains("load B") && s.events.lastIndex(of: "load B")! > s.events.lastIndex(of: "stage A")!
        }
        let afterStage = reply(await waited!.value)
        check("4 the stage's reads use one loaded worker", duringStage.count == 2 && duringStage[0] != nil
              && duringStage[0]?.pid == duringStage[1]?.pid, "\(duringStage)")
        check("4 the other model waits for the stage to end", !otherDoneDuringStage, "\(s.events)")
        check("4 then it loads, alone", afterStage?.repo == "model-b" && afterStage?.others == 0, "\(String(describing: afterStage))")

        // 5. Keep-alive: short with no Live Capture, longer during one, short again after it.
        s.keepAliveIdle = .milliseconds(300)
        s.keepAliveLiveCapture = .seconds(3)
        _ = await read(b)
        try? await Task.sleep(for: .milliseconds(900))
        check("5 an idle model is stopped after the short keep-alive", s.residentModel == nil, "\(String(describing: s.residentModel))")
        let capture = NSObject()
        s.liveCaptureBegan(capture)
        _ = await read(b)
        try? await Task.sleep(for: .milliseconds(900))
        check("5 during Live Capture it stays loaded", s.residentModel == b, "\(String(describing: s.residentModel))")
        s.liveCaptureEnded(capture)
        try? await Task.sleep(for: .milliseconds(900))
        check("5 after Live Capture ends it is stopped on the short keep-alive", s.residentModel == nil,
              "\(String(describing: s.residentModel))")

        // 6. Memory pressure stops an idle model at once; a warning leaves a stage's model alone.
        s.keepAliveIdle = .seconds(30)
        _ = await read(a)
        s.simulateMemoryPressure(critical: false)
        check("6 a memory warning stops an idle model", s.residentModel == nil, "\(String(describing: s.residentModel))")
        _ = try? await s.withStage(a) {
            _ = await read(a)
            s.simulateMemoryPressure(critical: false)
            check("6 a warning leaves a stage's model loaded", s.residentModel == a, "\(String(describing: s.residentModel))")
            s.simulateMemoryPressure(critical: true)
            check("6 critical pressure stops it", s.residentModel == nil, "\(String(describing: s.residentModel))")
        }

        // 7. A waiter that is cancelled leaves at once; a read in flight when everything stops fails as stopped.
        _ = try? await s.withStage(a) {
            let cancelled = Task { await read(b) }
            try? await Task.sleep(for: .milliseconds(200))
            cancelled.cancel()
            let r = await cancelled.value
            if case .failure(let e) = r { check("7 a cancelled waiter leaves", e is CancellationError, "\(e)") }
            else { check("7 a cancelled waiter leaves", false, "it read during the stage") }
        }
        let slow = Task { await read(a, "SLOW") }
        try? await Task.sleep(for: .milliseconds(700))
        s.stopAll()
        let stopped = await slow.value
        if case .failure(let e) = stopped { check("7 a read in flight at stop fails as stopped", e as? LocalModelSupervisor.Failure == .stopped, "\(e)") }
        else { check("7 a read in flight at stop fails as stopped", false, "it answered") }
        check("7 nothing is loaded after a stop", s.residentModel == nil)
        let restarted = reply(await read(a))
        check("7 a read after the stop loads again, alone", restarted?.others == 0, "\(String(describing: restarted))")

        // 8. A reader turned off while its reads wait: they stop without loading it; and a caller that no longer wants
        //    the read once it has its turn loads nothing.
        if let pair = try? await s.withStage(a, {
            _ = await read(a)
            let waiting = Task { await read(b) }
            try? await Task.sleep(for: .milliseconds(200))
            s.evict(b)
            let loadsBefore = s.events.filter { $0 == "load B" }.count
            return (waiting, loadsBefore)
        }) {
            let r = await pair.0.value
            check("8 a read waiting for a model turned off stops", isStopped(r), "\(r)")
            check("8 and loads nothing", s.events.filter { $0 == "load B" }.count == pair.1, "\(s.events.suffix(4))")
        }
        var wantedNow = true
        if let waiting = try? await s.withStage(a, {
            _ = await read(a)
            let waiting = Task { await read(b, proceed: { wantedNow }) }
            try? await Task.sleep(for: .milliseconds(200))
            wantedNow = false
            return waiting
        }) {
            let r = await waiting.value
            check("8 a read its caller no longer wants after the wait stops", isStopped(r), "\(r)")
            check("8 and the loaded model stays", s.residentModel == a, "\(String(describing: s.residentModel))")
        }

        // 9. A stage that reads nothing (its pages went to a server outside the app) leaves a loaded model to its
        //    keep-alive; a stage that has read keeps it.
        s.keepAliveIdle = .milliseconds(300)
        _ = await read(b)
        _ = try? await s.withStage(a) {
            try? await Task.sleep(for: .milliseconds(900))
            check("9 a stage that reads nothing does not keep another model", s.residentModel == nil,
                  "\(String(describing: s.residentModel))")
            _ = await read(a)
            try? await Task.sleep(for: .milliseconds(900))
            check("9 a stage that has read keeps its model past the keep-alive", s.residentModel == a,
                  "\(String(describing: s.residentModel))")
        }

        // 10. Pressure that comes during a read is acted on when the read ends.
        s.keepAliveIdle = .seconds(30)
        let busyRead = Task { await read(a, "SLOW") }
        try? await Task.sleep(for: .milliseconds(500))
        s.simulateMemoryPressure(critical: true)
        let loadedDuring = s.residentModel == a
        _ = await busyRead.value
        check("10 pressure during a read leaves it to finish", loadedDuring)
        check("10 and stops the model when it does", s.residentModel == nil, "\(String(describing: s.residentModel))")

        // 11. S-059 (W49.proc-s059-verify): an external large-memory process (HandPlacer) evicts any resident
        //     Live Capture MLX worker before starting and blocks new MLX loads until placement finishes.
        let aliveDir = root.appending(path: "alive")
        let liveOwner = NSObject()
        s.keepAliveLiveCapture = .seconds(300)
        s.liveCaptureBegan(liveOwner)
        defer { s.liveCaptureEnded(liveOwner) }
        _ = await read(a)
        check("11 precondition: Live Capture keeps model A resident", s.residentModel == a, "\(String(describing: s.residentModel))")

        let entered = DispatchSemaphore(value: 0)
        let queuedB = DispatchSemaphore(value: 0)
        let competingB = Task { () -> Result<Reply?, Error> in
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    entered.wait()
                    cont.resume()
                }
            }
            let pending = Task { await read(b) }
            try? await Task.sleep(for: .milliseconds(150))
            queuedB.signal()
            return await pending.value
        }
        let externalObservation: (aliveAtStart: Int, aliveAtEnd: Int) = await PDFGenerator.runWorker {
            do {
                return try LocalModelSupervisor.runExternalModelSync(named: "hand-placer", supervisor: s) { _ in
                    let startCount = ((try? FileManager.default.contentsOfDirectory(atPath: aliveDir.path)) ?? []).count
                    entered.signal()
                    _ = queuedB.wait(timeout: .now() + .seconds(5))
                    let endCount = ((try? FileManager.default.contentsOfDirectory(atPath: aliveDir.path)) ?? []).count
                    return (startCount, endCount)
                }
            } catch {
                entered.signal()
                return (-1, -1)
            }
        }
        let afterExternalB = reply(await competingB.value)
        check("11 external model waits for resident Live Capture worker to exit before starting",
              externalObservation.aliveAtStart == 0 && externalObservation.aliveAtEnd == 0,
              "\(externalObservation)")
        check("11 competing MLX model loads alone only after external model finishes",
              afterExternalB?.repo == "model-b" && afterExternalB?.others == 0, "\(String(describing: afterExternalB))")
        let tail = s.events.suffix(6)
        let unloadIdx = tail.firstIndex(of: "unload A")
        let extStartIdx = tail.firstIndex(of: "external hand-placer")
        let extEndIdx = tail.firstIndex(of: "external end hand-placer")
        let loadBIdx = tail.firstIndex(of: "load B")
        check("11 supervisor order: unload A -> external -> external end -> load B",
              unloadIdx != nil && extStartIdx != nil && extEndIdx != nil && loadBIdx != nil
                && unloadIdx! < extStartIdx! && extStartIdx! < extEndIdx! && extEndIdx! < loadBIdx!,
              "\(Array(tail))")

        // 11b. End-to-end through PDFGenerator.generateOutput with a fake HandPlacer while model B is resident.
        let fm = FileManager.default
        let handsHome = root.appending(path: "hands-home")
        let handsBin = handsHome.appending(path: "Hands/bin")
        let handsModels = handsHome.appending(path: "Hands/models")
        let fakePy = handsBin.appending(path: "python3")
        let fakeScript = root.appending(path: "fake-place-hands.py")
        let seenAlive = root.appending(path: "hands-saw-alive.txt")
        let sampleJPG = root.appending(path: "hand.jpg")
        let outPDF = root.appending(path: "hand.pdf")
        do {
            try fm.createDirectory(at: handsBin, withIntermediateDirectories: true)
            try fm.createDirectory(at: handsModels, withIntermediateDirectories: true)
            try Data("m".utf8).write(to: handsModels.appending(path: "McCATMuS_nfd_nofix_V1.mlmodel"))
            try Data("# stub\n".utf8).write(to: fakeScript)
            let sh = """
            #!/bin/sh
            n=$(ls -A "\(aliveDir.path)" 2>/dev/null | wc -l | tr -d ' ')
            echo "$n" > "\(seenAlive.path)"
            cat > "$5" <<'JSON'
            {"lines":[{"text":"Dear Sir","box":[0.1,0.1,0.5,0.1]}],"confidence":0.95,"span":1,"detected":1,"reading_lines":1,"peak_rss":0}
            JSON
            """
            try Data(sh.utf8).write(to: fakePy)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakePy.path)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            if let ctx = CGContext(data: nil, width: 200, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
               let cg = ctx.makeImage(),
               let dest = CGImageDestinationCreateWithURL(sampleJPG as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cg, nil)
                CGImageDestinationFinalize(dest)
            }
            let savedHome = ProcessInfo.processInfo.environment["VISIONOCR_MODEL_HOME"]
            let savedScript = ProcessInfo.processInfo.environment["VISIONOCR_HANDS_SCRIPT"]
            setenv("VISIONOCR_MODEL_HOME", handsHome.path, 1)
            setenv("VISIONOCR_HANDS_SCRIPT", fakeScript.path, 1)
            let savedOverride = LocalModelSupervisor.testOverride
            LocalModelSupervisor.testOverride = s
            defer {
                LocalModelSupervisor.testOverride = savedOverride
                if let savedHome { setenv("VISIONOCR_MODEL_HOME", savedHome, 1) } else { unsetenv("VISIONOCR_MODEL_HOME") }
                if let savedScript { setenv("VISIONOCR_HANDS_SCRIPT", savedScript, 1) } else { unsetenv("VISIONOCR_HANDS_SCRIPT") }
            }
            check("11b precondition: model B is resident before PDFGenerator hand placement",
                  s.residentModel == b, "\(String(describing: s.residentModel))")
            let result = OCRResult(text: "Dear Sir", classification: .documentStart, errorMessage: nil, errorCode: nil)
            let output: PDFGenerator.Output? = await PDFGenerator.runWorker {
                try? PDFGenerator().generateOutput(
                    imageURL: sampleJPG, result: result, model: LLMModel.appleVisionModels[0], outputURL: outPDF,
                    pageKind: .handwritten, textLayer: PDFGenerator.TextLayerOptions(placeHandOnImage: true))
            }
            let aliveSeen = (try? String(contentsOf: seenAlive, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            check("11b PDFGenerator evicts resident MLX worker before launching HandPlacer",
                  aliveSeen == "0" && s.residentModel == nil && output?.layer.route == .handBllaCtc,
                  "aliveSeen=\(aliveSeen ?? "nil") resident=\(String(describing: s.residentModel)) route=\(String(describing: output?.layer.route))")
        } catch {
            check("11b PDFGenerator hand placement fixture", false, error.localizedDescription)
        }
        return out
    }
}
#endif
