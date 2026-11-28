#if DEBUG // W40.a5: a test driver/contract, compiled out of Release
import ArchiveCore
import Darwin
import Foundation

/// Headless, no-network regression for request retry/cancellation safety. Every response is injected;
/// no URLSession request is made. Gated by `NETWORKSESSION_TEST=1` and writes a plain-text report to
/// `NETWORKSESSION_TEST_OUT`.
@MainActor
enum NetworkSessionTestDriver {
    private static var didRun = false

    private actor AttemptCounter {
        private var value = 0
        func next() -> Int { value += 1; return value }
        func count() -> Int { value }
    }

    private actor ConcurrencyProbe {
        private var active = 0
        private var peak = 0
        func enter() { active += 1; peak = max(peak, active) }
        func leave() { active -= 1 }
        func maxActive() -> Int { peak }
    }

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["NETWORKSESSION_TEST"] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    nonisolated private static func response(_ request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                        headerFields: status == 429 ? ["Retry-After": "0"] : nil)!
    }

    private static func run() async {
        var results: [String] = []
        func check(_ name: String, _ ok: Bool) {
            results.append("\(ok ? "PASS" : "FAIL"): \(name)")
            NSLog("NETWORKSESSION \(ok ? "PASS" : "FAIL"): \(name)")
        }

        var post = URLRequest(url: URL(string: "https://example.invalid/generate")!)
        post.httpMethod = "POST"
        var get = URLRequest(url: URL(string: "https://example.invalid/status")!)
        get.httpMethod = "GET"

        // An ambiguous transport failure may mean a billable POST reached the provider. Never repeat it.
        let postTransport = AttemptCounter()
        var postTransportThrew = false
        do {
            _ = try await NetworkSession.testPerformWithRetry(
                post, policy: .nonIdempotent, maxRetries: 4) { _ in
                    _ = await postTransport.next()
                    throw URLError(.networkConnectionLost)
                }
        } catch { postTransportThrew = true }
        let postTransportCount = await postTransport.count()
        check("non-idempotent POST is not retried after ambiguous transport failure",
              postTransportThrew && postTransportCount == 1)

        // Likewise, an application 5xx can arrive after the work was accepted. Surface it to the caller.
        let post503 = AttemptCounter()
        let post503Result = try? await NetworkSession.testPerformWithRetry(
            post, policy: .nonIdempotent, maxRetries: 4) { request in
                _ = await post503.next()
                return (Data(), response(request, status: 503))
            }
        let post503Count = await post503.count()
        check("non-idempotent POST is not retried after ambiguous 503",
              post503Count == 1
              && (post503Result?.1 as? HTTPURLResponse)?.statusCode == 503)

        // 429 explicitly rejects the request, so a paced retry remains safe and preserves bulk usability.
        let post429 = AttemptCounter()
        let post429Result = try? await NetworkSession.testPerformWithRetry(
            post, policy: .nonIdempotent, maxRetries: 2) { request in
                let attempt = await post429.next()
                return (Data(), response(request, status: attempt == 1 ? 429 : 200))
            }
        let post429Count = await post429.count()
        check("non-idempotent POST retries only an explicit 429 rejection",
              post429Count == 2
              && (post429Result?.1 as? HTTPURLResponse)?.statusCode == 200)

        // Idempotent reads retain the prior reliability behavior.
        let getTransport = AttemptCounter()
        let getTransportResult = try? await NetworkSession.testPerformWithRetry(
            get, policy: .idempotent, maxRetries: 2) { request in
                let attempt = await getTransport.next()
                if attempt == 1 { throw URLError(.networkConnectionLost) }
                return (Data(), response(request, status: 200))
            }
        let getTransportCount = await getTransport.count()
        check("idempotent GET retries a transient transport failure",
              getTransportCount == 2
              && (getTransportResult?.1 as? HTTPURLResponse)?.statusCode == 200)

        let get503 = AttemptCounter()
        let get503Result = try? await NetworkSession.testPerformWithRetry(
            get, policy: .idempotent, maxRetries: 2) { request in
                let attempt = await get503.next()
                return (Data(), response(request, status: attempt == 1 ? 503 : 200))
            }
        let get503Count = await get503.count()
        check("idempotent GET retries a transient 503",
              get503Count == 2
              && (get503Result?.1 as? HTTPURLResponse)?.statusCode == 200)

        // Stress the cancelled-waiter path while one real slot is occupied. Cancelled waiters must leave
        // `active` unchanged, never enter the critical section, and never strand the queue.
        let limiter = RequestLimiter(limit: 1)
        try? await limiter.acquire()   // hold the only real slot
        let probe = ConcurrencyProbe()
        let waiterCount = 40
        var waiters: [Task<Bool, Never>] = []
        for _ in 0..<waiterCount {
            waiters.append(Task {
                do {
                    try await limiter.acquire()
                    await probe.enter()
                    try? await Task.sleep(for: .milliseconds(1))
                    await probe.leave()
                    await limiter.release()
                    return true
                } catch {
                    return false
                }
            })
        }
        for _ in 0..<500 {
            let counts = await limiter.testCounts()
            if counts.waiters == waiterCount { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        let queuedCounts = await limiter.testCounts()
        let allQueued = queuedCounts.waiters == waiterCount
        for i in stride(from: 0, to: waiterCount, by: 2) { waiters[i].cancel() }
        for _ in 0..<500 {
            let counts = await limiter.testCounts()
            if counts.waiters == waiterCount / 2 { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        let afterCancel = await limiter.testCounts()
        check("cancelled waiters are removed without inflating active slots",
              allQueued && afterCancel.active == 1 && afterCancel.waiters == waiterCount / 2)

        await limiter.release()
        var succeeded = 0
        for waiter in waiters {
            if await waiter.value { succeeded += 1 }
        }
        let finalCounts = await limiter.testCounts()
        let peak = await probe.maxActive()
        check("limiter drains after cancellation without exceeding its limit",
              succeeded == waiterCount / 2 && peak <= 1
              && finalCounts.active == 0 && finalCounts.waiters == 0)

        do {
            try await paidLedger(check)
        } catch {
            check("scratch paid ledger setup: \(error.localizedDescription)", false)
        }
        await loopbackRefusedFailsFast(check)
        await tagsControllerWriteFailureSurvivesNextEdit(check)
        let passed = results.allSatisfy { $0.hasPrefix("PASS") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        let outPath = ProcessInfo.processInfo.environment["NETWORKSESSION_TEST_OUT"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("APNetworkSession-RESULT.txt").path
        try? report.write(toFile: outPath, atomically: true, encoding: .utf8)
        NSLog("NETWORKSESSION DONE: \(passed ? "ALL PASS" : "SOME FAILED") → \(outPath)")
    }

    private static func paidLedger(_ check: (String, Bool) -> Void) async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("APLedger-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        func close(_ actual: Double, _ expected: Double) -> Bool { abs(actual - expected) < 1e-9 }
        let store = SettingsLayerStore(directory: scratch)
        let alsoOpen = SettingsLayerStore(directory: scratch)
        let counter = AttemptCounter()
        let runID = UUID()
        let route = PaidRequests.Billing(provider: .openai,
            price: .init(input: 1, output: 2, imageProvider: .openai), fallback: 0.4)
        let context = PaidRequests(runID: runID, outputDirectory: scratch, limit: 0.5, store: store)
        let other = PaidRequests(outputDirectory: scratch, limit: 0.5, store: alsoOpen)
        var request = URLRequest(url: URL(string: "https://ledger.invalid/generate")!)
        request.httpMethod = "POST"
        let post = request

        NetworkSession.testTransport = { r in
            _ = await counter.next()
            if r.url?.host == "ledger.invalid" {
                try await Task.sleep(for: .milliseconds(50))
                throw URLError(.networkConnectionLost)
            }
            throw URLError(.unsupportedURL)
        }
        defer { NetworkSession.testTransport = nil }
        precondition(NetworkSession.testTransportIsActive)
        func send(_ context: PaidRequests) async -> Bool {
            await PaidRequests.$context.withValue(context) {
                (try? await NetworkSession.data(for: post, policy: .nonIdempotent, maxRetries: 0, billing: route)) != nil
            }
        }
        async let first = send(context)
        async let second = send(other)
        _ = await (first, second)
        let sends = await counter.count()
        let reopened = SettingsLayerStore(directory: scratch)
        let interrupted = reopened.paidRequestsThisMonth()
        check("concurrent scopes on two stores cannot reserve the same monthly balance",
              sends == 1 && interrupted.count == 1 && close(reopened.spentThisMonthUSD(), 0.4))
        check("reopening preserves the interrupted attempt and labels its estimate",
              interrupted.first?.paymentNote == "estimate, awaiting confirmation")

        let retries = AttemptCounter()
        NetworkSession.testTransport = { r in
            if await retries.next() == 1 { return (Data(), response(r, status: 429)) }
            return (Data(#"{"usage":{"prompt_tokens":1000,"completion_tokens":2000}}"#.utf8), response(r, status: 200))
        }
        let resumed = PaidRequests(runID: runID, outputDirectory: scratch, limit: 1, store: reopened)
        let didRetry = await PaidRequests.$context.withValue(resumed) {
            (try? await NetworkSession.data(for: post, policy: .nonIdempotent, maxRetries: 1, billing: route)) != nil
        }
        let retryCount = await retries.count()
        check("explicit 429 releases its estimate; resumed request adds only its own usage",
              didRetry && retryCount == 2 && reopened.paidRequestsThisMonth().count == 2
              && close(reopened.spentThisMonthUSD(), 0.405)
              && reopened.paidRequestsThisMonth().contains { $0.paymentNote == "list-price estimate" })

        NetworkSession.testTransport = { r in
            (Data(#"{"usage":{"cost":0.012}}"#.utf8), response(r, status: 200))
        }
        _ = await send(resumed)
        check("provider-reported dollars replace the provisional estimate",
              close(reopened.spentThisMonthUSD(), 0.417)
              && reopened.paidRequestsThisMonth().contains { $0.request?.basis == .reported })

        NetworkSession.testTransport = { r in
            (Data(#"{"choices":[{"message":{"content":"scratch"}}]}"#.utf8), response(r, status: 200))
        }
        let uncapped = PaidRequests(runID: runID, outputDirectory: scratch, store: reopened)
        _ = try await PaidRequests.$context.withValue(uncapped) {
            try await NetworkSession.data(for: post, policy: .nonIdempotent,
                billing: PaidRequests.Billing(provider: .openai, price: nil))
        }
        check("a successful reply with no known rates or usage keeps the amount unknown",
              reopened.paidRequestsThisMonth().contains { $0.paymentNote == "amount unknown" })

        NetworkSession.testTransport = { r in
            if r.httpMethod == "POST" {
                return (Data(#"{"id":"scratch-batch"}"#.utf8), response(r, status: 200))
            }
            if r.url?.path == "/results" {
                return (Data(#"{"custom_id":"file-0","result":{"type":"succeeded","message":{"content":[],"usage":{"input_tokens":1000,"output_tokens":1000}}}}"#.utf8),
                        response(r, status: 200))
            }
            return (Data(#"{"processing_status":"ended","request_counts":{"succeeded":1,"canceled":2},"results_url":"https://ledger.invalid/results"}"#.utf8),
                    response(r, status: 200))
        }
        _ = try await PaidRequests.$context.withValue(uncapped) {
            try await PaidRequests.recordBatch(post, estimate: 0.3, count: 3, provider: .anthropic) { _ in "scratch-batch" }
        }
        check("accepted batch stays reserved before any results", close(reopened.spentThisMonthUSD(), 0.717))
        let reopenedAgain = SettingsLayerStore(directory: scratch)
        let batchResume = PaidRequests(runID: runID, outputDirectory: scratch, store: reopenedAgain)
        let model = LLMModel.anthropicModels[0]
        let expected = (model.inputCostPer1M + model.outputCostPer1M) * model.batchDiscount / 1000
        let batch = AnthropicBatchClient(apiKey: "scratch", model: model, thinkingLevel: nil)
        let confirmed = await PaidRequests.$context.withValue(batchResume) {
            await batch.confirmCancellation(batchId: "scratch-batch")
        }
        _ = await PaidRequests.$context.withValue(batchResume) {
            await batch.confirmCancellation(batchId: "scratch-batch")
        }
        check("confirmed cancellation keeps the completed request, releases the cancelled pair, and is idempotent on Resume",
              confirmed && close(reopenedAgain.spentThisMonthUSD(), 0.417 + expected))

        NetworkSession.testTransport = { r in (Data(#"{}"#.utf8), response(r, status: 200)) }
        _ = try await PaidRequests.$context.withValue(batchResume) {
            try await PaidRequests.recordBatch(post, estimate: 0.2, count: 2, provider: .gemini) { _ in nil }
        }
        check("an ambiguous create with no provider ID keeps its admission estimate",
              reopenedAgain.paidRequestsThisMonth().contains {
                  $0.request?.provider == .gemini && $0.request?.jobID == nil
                      && $0.request?.basis == .unresolved && close($0.usd, 0.2)
              })

        let mergeAttempt = try batchResume.admit(provider: .gemini, estimate: 0.3, count: 3)
        mergeAttempt.settle(.unresolved, jobID: "partial-batch")
        try reopenedAgain.reconcilePaidBatch(provider: .gemini, jobID: "partial-batch", usage: ["p1": 0.01],
                                         confirmedNoCharge: 0)
        try reopenedAgain.reconcilePaidBatch(provider: .gemini, jobID: "partial-batch", usage: ["p2": 0.02],
                                         confirmedNoCharge: 0)
        try reopenedAgain.reconcilePaidBatch(provider: .gemini, jobID: "partial-batch", usage: ["p1": 0.01],
                                         confirmedNoCharge: 1)
        check("overlapping partial downloads merge by result ID instead of replacing or charging twice",
              reopenedAgain.paidRequestsThisMonth().contains {
                  $0.request?.jobID == "partial-batch" && $0.request?.basis == .estimate && close($0.usd, 0.03)
              })
    }

    /// W49.proc-mac-server-absent-wait: a refused loopback connection must fail immediately with
    /// `cannotConnectToHost` instead of waiting up to `timeoutIntervalForResource` (600 s) for connectivity.
    private static func loopbackRefusedFailsFast(_ check: (String, Bool) -> Void) async {
        check("loopback host recognition covers 127.0.0.0/8, localhost and IPv6 loopback only",
              NetworkSession.isLoopback(URL(string: "http://127.0.0.1:8080/v1/chat/completions"))
                && NetworkSession.isLoopback(URL(string: "http://127.0.0.2:8080/v1"))
                && NetworkSession.isLoopback(URL(string: "http://localhost:11434/v1"))
                && NetworkSession.isLoopback(URL(string: "http://localhost.:8080/v1"))
                && NetworkSession.isLoopback(URL(string: "http://[::1]:8080/v1"))
                && NetworkSession.isLoopback(URL(string: "http://[0:0:0:0:0:0:0:1]:8080/v1"))
                && NetworkSession.isLoopback(URL(string: "http://[::ffff:127.0.0.1]:8080/v1"))
                && !NetworkSession.isLoopback(URL(string: "https://api.openai.com/v1/responses"))
                && !NetworkSession.isLoopback(URL(string: "http://127.0.0.example.com/v1")))
        check("loopback session disables waitsForConnectivity while shared keeps it",
              !NetworkSession.loopback.configuration.waitsForConnectivity
                && NetworkSession.shared.configuration.waitsForConnectivity)

        // Reserve an ephemeral unused port on 127.0.0.1 and close it immediately so nothing listens there.
        func closedLoopbackPort() -> UInt16? {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { return nil }
            var assigned = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let got = withUnsafeMutablePointer(to: &assigned) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(fd, $0, &len)
                }
            }
            guard got == 0 else { return nil }
            return UInt16(bigEndian: assigned.sin_port)
        }

        guard let port = closedLoopbackPort(),
              let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions") else {
            check("closed ephemeral loopback port allocated", false)
            return
        }
        precondition(!NetworkSession.testTransportIsActive)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20

        let dataStart = Date()
        var dataCode: URLError.Code?
        do {
            _ = try await NetworkSession.data(for: req, policy: .nonIdempotent, maxRetries: 0)
        } catch let e as URLError {
            dataCode = e.code
        } catch {}
        let dataElapsed = Date().timeIntervalSince(dataStart)
        check("refused loopback NetworkSession.data fails immediately without waiting for connectivity",
              dataCode == .cannotConnectToHost && dataElapsed < 3.0)

        let streamStart = Date()
        let streamCode = await probeClosedLoopbackStream(req)
        let streamElapsed = Date().timeIntervalSince(streamStart)
        check("refused loopback NetworkSession.streamLines fails immediately without waiting for connectivity",
              streamCode == .cannotConnectToHost && streamElapsed < 3.0)
    }

    nonisolated private static func probeClosedLoopbackStream(_ request: URLRequest) async -> URLError.Code? {
        do {
            _ = try await NetworkSession.streamLines(for: request) { _ in true }
            return nil
        } catch let e as URLError {
            return e.code
        } catch {
            return nil
        }
    }

    /// S-062(b): a failing first record write in ProcessorTagsController must keep its warning note even when a
    /// second change is made before the first write completes (bumping `generation`).
    private static func tagsControllerWriteFailureSurvivesNextEdit(_ check: (String, Bool) -> Void) async {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("APTagsController-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let suiteName = "NetworkSessionTestDriver.S062.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            check("S-062 scratch defaults created", false)
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("Trade\nFinance", forKey: DefaultsKeys.tagVocabulary)
        let vocab = TagVocabulary(fileURL: scratch.appendingPathComponent("vocab.json"))
        _ = vocab.add(rawTags: ["Trade", "Finance"], labelNumber: nil)

        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func next() -> Int { lock.withLock { n += 1; return n } }
        }
        let calls = Counter()
        let controller = ProcessorTagsController(
            vocabulary: vocab,
            defaults: defaults,
            findArchives: { _ in [scratch] },
            recordChanges: { _, _ in
                let call = calls.next()
                if call == 1 {
                    Thread.sleep(forTimeInterval: 0.08)
                    throw CocoaError(.fileWriteNoPermission)
                }
                return 1
            }
        )
        guard let firstPlan = controller.model.inventory.renamePlan("Trade", to: "Commerce") else {
            check("S-062 first rename plan built", false)
            return
        }
        _ = controller.testPerform(firstPlan)
        // Queue a second change immediately while the first write is still in flight (bumping `generation`).
        guard let secondPlan = controller.model.inventory.renamePlan("Commerce", to: "Shipping") else {
            check("S-062 second rename plan built", false)
            return
        }
        _ = controller.testPerform(secondPlan)
        await controller.waitForPendingWrites()
        check("S-062 failing first tag-change write keeps its warning note even after a second change bumps generation",
              controller.note?.contains("The other apps were not told:") == true)

        // A clean controller whose write succeeds leaves note nil.
        let cleanSuite = "NetworkSessionTestDriver.S062.clean.\(UUID().uuidString)"
        guard let cleanDefaults = UserDefaults(suiteName: cleanSuite) else { return }
        defer { cleanDefaults.removePersistentDomain(forName: cleanSuite) }
        cleanDefaults.set("Trade\nFinance", forKey: DefaultsKeys.tagVocabulary)
        let cleanVocab = TagVocabulary(fileURL: scratch.appendingPathComponent("vocab-clean.json"))
        _ = cleanVocab.add(rawTags: ["Trade", "Finance"], labelNumber: nil)
        let clean = ProcessorTagsController(
            vocabulary: cleanVocab, defaults: cleanDefaults,
            findArchives: { _ in [scratch] },
            recordChanges: { _, _ in 1 }
        )
        if let plan = clean.model.inventory.renamePlan("Trade", to: "Commerce") {
            _ = clean.testPerform(plan)
            await clean.waitForPendingWrites()
        }
        check("S-062 successful tag-change write leaves controller.note nil", clean.note == nil)
    }
}

#endif
