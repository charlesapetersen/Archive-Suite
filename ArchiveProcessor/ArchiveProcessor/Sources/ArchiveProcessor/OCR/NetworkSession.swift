import Foundation

/// Bounds how many LLM HTTP requests are in flight at once, across ALL call sites (OCR,
/// rotation detection, tagging, batch). Every call type routes through NetworkSession, so
/// this is the single choke point that keeps us from flooding a provider's rate limit.
actor RequestLimiter {
    private let limit: Int
    private var active = 0
    private var waiters: [(id: UUID, cont: CheckedContinuation<Void, Never>)] = []

    init(limit: Int) { self.limit = limit }

    /// Acquire a slot, suspending if at capacity. Cancellation-aware so a cancelled run never
    /// leaves a caller suspended forever (which would hang the OCR TaskGroup).
    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                waiters.append((id, cont))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.cont.resume()   // hand our slot directly to the next waiter (active unchanged)
        } else {
            active = max(0, active - 1)
        }
    }

    /// Resume a still-waiting acquirer that was cancelled, granting it a (transient) slot so the
    /// caller's paired `release()` keeps the count balanced.
    private func cancelWaiter(_ id: UUID) {
        guard let idx = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: idx)
        active += 1
        waiter.cont.resume()
    }
}

/// A shared URLSession configured for reliability, with a global concurrency limit and
/// automatic retry/backoff for transient failures — both transport errors and HTTP
/// rate-limit / overload responses (429 / 503 / 529).
enum NetworkSession {
    static let shared: URLSession = {
        // Ephemeral config: no persistent caching or credential storage,
        // and critically, no reuse of stale keep-alive connections that
        // cause -1005 "network connection was lost" on cellular.
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = true
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.timeoutIntervalForResource = 600
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    /// Max concurrent LLM requests in flight. Kept modest so the OCR worker pool plus the
    /// per-image rotation calls don't collectively exceed provider limits and trigger 503s.
    private static let limiter = RequestLimiter(limit: 5)

    /// HTTP statuses for a transient rate-limit / overload — retried aggressively with backoff.
    private static let retryableStatuses: Set<Int> = [429, 503, 529]
    /// 5xx that may be non-idempotent server-side failures on a billable POST — retried at most once
    /// so a flapping backend can't multiply token cost (see performWithRetry).
    private static let limitedRetryStatuses: Set<Int> = [500, 502]

    /// Timestamp of the most recent 429 (rate-limit) retry, so the OCR UI can show a "pacing to your
    /// key's rate limit" note during bulk jobs instead of looking stalled. Write-mostly; read only for
    /// a cosmetic status line.
    nonisolated(unsafe) static var lastRateLimitedAt: Date?

    /// Perform a data request through the global limiter, retrying transient transport errors
    /// and rate-limit/overload responses with exponential backoff + jitter (honoring
    /// `Retry-After` when present).
    static func data(for request: URLRequest, maxRetries: Int = 4) async throws -> (Data, URLResponse) {
        await limiter.acquire()
        do {
            let result = try await performWithRetry(request, maxRetries: maxRetries)
            await limiter.release()
            return result
        } catch {
            await limiter.release()
            throw error
        }
    }

    private static func performWithRetry(_ request: URLRequest, maxRetries: Int) async throws -> (Data, URLResponse) {
        var lastError: Error?
        var retryAfter: Double?

        for attempt in 0...maxRetries {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(backoffDelay(attempt: attempt, retryAfter: retryAfter)))
                retryAfter = nil
            }
            guard !Task.isCancelled else { throw CancellationError() }

            do {
                // Add Connection: close to prevent the server from holding
                // keep-alive connections that go stale on cellular.
                var req = request
                req.setValue("close", forHTTPHeaderField: "Connection")
                let (data, response) = try await shared.data(for: req)

                // Retry transient rate-limit / overload statuses with full backoff; 500/502 (which on a
                // billable POST may be non-idempotent server-side failures) at most once, so a flapping
                // backend can't multiply token cost.
                if let http = response as? HTTPURLResponse, attempt < maxRetries {
                    let retryable = retryableStatuses.contains(http.statusCode)
                        || (limitedRetryStatuses.contains(http.statusCode) && attempt < 1)
                    if retryable {
                        if http.statusCode == 429 { lastRateLimitedAt = Date() }
                        retryAfter = parseRetryAfter(http)
                        lastError = URLError(.badServerResponse)
                        continue
                    }
                }
                return (data, response)
            } catch {
                lastError = error
                let code = (error as NSError).code
                let retryableTransport = code == -1005 || code == -1001 || code == -1009
                if !retryableTransport || attempt == maxRetries {
                    throw error
                }
            }
        }
        throw lastError ?? URLError(.badServerResponse)
    }

    /// Exponential backoff (base 1.5s, doubling) with jitter, capped at 30s. If the server
    /// sent a `Retry-After` that's larger, honor it.
    private static func backoffDelay(attempt: Int, retryAfter: Double?) -> Double {
        let base = min(30.0, 1.5 * pow(2.0, Double(attempt - 1)))
        let jitter = Double.random(in: 0...0.5) * base
        let computed = base + jitter
        if let ra = retryAfter { return min(60.0, max(ra, computed)) }
        return computed
    }

    /// Parse a `Retry-After` header — either delta-seconds or an HTTP-date (RFC 7231). Some gateways
    /// send the date form; without this it was dropped and we retried sooner than the server asked.
    private static func parseRetryAfter(_ http: HTTPURLResponse) -> Double? {
        guard let value = http.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty else { return nil }
        if let seconds = Double(value) { return seconds }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "GMT")
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = fmt.date(from: value) { return max(0, date.timeIntervalSinceNow) }
        return nil
    }
}
