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

        let passed = results.allSatisfy { $0.hasPrefix("PASS") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        let outPath = ProcessInfo.processInfo.environment["NETWORKSESSION_TEST_OUT"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("APNetworkSession-RESULT.txt").path
        try? report.write(toFile: outPath, atomically: true, encoding: .utf8)
        NSLog("NETWORKSESSION DONE: \(passed ? "ALL PASS" : "SOME FAILED") → \(outPath)")
    }
}
