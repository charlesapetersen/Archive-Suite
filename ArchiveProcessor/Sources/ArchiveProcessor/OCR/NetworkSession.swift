import Foundation

/// A shared URLSession configured for reliability on both Wi-Fi and cellular connections,
/// with automatic retry for transient network errors (e.g. "network connection was lost").
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
        config.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: config)
    }()

    /// Perform a data request with automatic retry on transient network errors.
    /// Retries up to `maxRetries` times with a short delay between attempts.
    static func data(for request: URLRequest, maxRetries: Int = 2) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 0...maxRetries {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(attempt))
            }
            do {
                // Add Connection: close to prevent the server from holding
                // keep-alive connections that go stale on cellular.
                var req = request
                req.setValue("close", forHTTPHeaderField: "Connection")
                return try await shared.data(for: req)
            } catch {
                lastError = error
                let code = (error as NSError).code
                let retryable = code == -1005 || code == -1001 || code == -1009
                if !retryable || attempt == maxRetries {
                    throw error
                }
            }
        }
        throw lastError!
    }
}
